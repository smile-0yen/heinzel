#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/locks.sh — what a run holds while it works, and for how long.
#
# There was one lock. `bin/hzl-run` re-executed itself under
# `lockf -t 0 -k ~/.heinzel/run.lock` and held it from the first gate to the
# last line, so three different facts were spelled the same way: *another runner
# is running*, *the ledger is being written*, and *this checkout has a writer*.
# One lock for three questions is fine while there is exactly one synchronous
# run and nothing else touches the ledger. It stops being fine as soon as a run
# outlives the process that started it, which is what Phase 2 is for
# (docs/RUNTIME-BACKENDS.md §14.3). So the three came apart, and `run.lock`
# itself is gone — what is here is the whole of what it was saying:
#
#   backlog lock    a short global lock, held around a ledger mutation and
#                   released immediately. Never held across an engine call.
#   per-run lock    one run, one advancer. Held for as long as something is
#                   moving that run forward.
#   writer lease    one writer per `workspace_identity`, durable, with a
#                   fencing generation. Outlives the process that took it,
#                   which is the whole point: a controller that died still owns
#                   the checkout until something confirms it stopped.
#
#   lock_acquire  <name> [timeout-sec]     -> 0 held, 1 not
#   lock_release  <name>                   -> only if this process holds it
#   lock_holder   <name>                   -> the pid, or empty
#   lock_reclaim  <name>                   -> breaks a dead holder's lock
#   lock_with     <name> <timeout> <cmd…>  -> acquire, run, release
#   with_backlog_lock <cmd…>               -> one ledger or session mutation
#
#   lease_acquire <identity> <run-id> [pid] -> 0 held, 1 held by another run
#   lease_release <identity> <run-id>       -> only this run's lease
#   lease_holder  <identity>                -> the run id, or empty
#   lease_pid     <identity>                -> the holding process
#   lease_generation <identity>             -> the fencing generation
#   lease_renew   <identity> <run-id>       -> heartbeat, same generation
#   lease_reclaim <identity>                -> breaks a dead holder's lease and
#                                              prints the run id it broke
#
# Why not `lockf(1)` for these. lockf holds a kernel lock for the lifetime of a
# command it execs, and the kernel drops it when that command dies — which is
# exactly right for the one thing it already guards, a whole run. It cannot
# guard a section of *this* shell, and every mutation named above is a shell
# function in the calling process. So the primitive here is an atomic create:
# the record is written whole into a temp file beside the target and hard-linked
# into place, because `ln` fails when the target exists and does it in one
# operation. There is no moment where a lock exists without naming its holder,
# and no moment where a second taker sees a half-written one. `mv` would have
# overwritten whoever was there, which is the opposite of what a lock is for.
#
# What that costs is staleness: a process that dies holding one of these leaves
# the file behind, where the kernel would have dropped a lockf. That is a
# feature for the lease — ownership *must* survive the process, or a killed
# controller would silently release a checkout it is still writing to (§14.3,
# invariant 14) — and a liability for the locks, so both are recoverable, and
# only ever by the same rule: a holder whose pid is not alive can be broken, and
# nothing else can.
#
# Requires lib/common.sh and lib/claims.sh (for the workspace identity).

LOCKS_SCHEMA=1

# How long a caller waits for the backlog lock by default. Long enough to sit
# out a ledger mutation, far too short to sit out an engine call — a caller that
# waited minutes here would be waiting for something that is not a ledger write.
LOCK_WAIT_SEC=10

# The name of the short global lock. Session state and the ledger move together
# — a completion counted in `state.json` but not in the ledger is the same bug
# either way round — so they are one lock, not two.
LOCK_BACKLOG=backlog

# --- the primitive ----------------------------------------------------------

# One field out of a lock or lease record. Missing file, missing field and
# unparseable file all read as empty, because every caller here is asking "is
# this what I think it is" and the answer to all three is no.
_lock_field() { # file jq-path
  local f=$1 p=$2
  [ -r "${f}" ] || return 1
  jq -r "${p} // empty" "${f}" 2>/dev/null
}

# Create the file holding this record, or fail because somebody else already
# did. See the header: written whole, then `ln`, never `mv`.
_lock_take() { # file json
  local f=$1 json=$2 dir tmp
  dir=$(dirname "${f}")
  mkdir -p "${dir}" || return 1
  chmod 700 "${dir}" 2>/dev/null
  tmp=$(mktemp "${dir}/.take.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && ln "${tmp}" "${f}" 2>/dev/null; then
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Break a lock or lease whose holder is gone, and nothing else.
#
# A live holder is never broken, whatever it is doing and however long it has
# been doing it: this is the rule that keeps "recoverable" from meaning "takeable
# from underneath". Then the record is moved aside under a name only this
# process can have written, and the moved copy is checked to be the one that was
# looked at — a rename is one operation, so of two processes that both saw the
# same corpse exactly one moves it, and a taker that got in between is put back
# rather than deleted.
#
# The window that leaves: between the move and the restore, the path is free,
# so a third process taking the lock in that instant would keep it and the one
# being restored would lose a lock it believes it holds. It needs two breakers
# and a taker inside the same few milliseconds, against a holder that has just
# died. It is smaller than the window that exists today, which is the whole of
# every ledger mutation with no lock at all.
_lock_break() { # file -> 0 broken
  local f=$1 pid at aside
  [ -e "${f}" ] || return 1
  pid=$(_lock_field "${f}" .pid)
  at=$(_lock_field "${f}" .acquired_at)
  [ -n "${pid}" ] || return 1
  pid_alive "${pid}" && return 1
  aside="${f}.dead.$$"
  mv "${f}" "${aside}" 2>/dev/null || return 1
  if [ "$(_lock_field "${aside}" .pid)" = "${pid}" ] &&
     [ "$(_lock_field "${aside}" .acquired_at)" = "${at}" ]; then
    rm -f "${aside}"
    return 0
  fi
  ln "${aside}" "${f}" 2>/dev/null
  rm -f "${aside}"
  return 1
}

# --- the short locks --------------------------------------------------------

# A lock name becomes a filename, so it is checked the way a run id is: `.` is
# not in the permitted set, so `..` cannot be spelled.
lock_file() {
  local name=$1
  case ${name} in
    ""|*[!a-zA-Z0-9_-]*)
      err "not a usable lock name: '${name}'"
      return 1
      ;;
  esac
  printf '%s/locks/%s.lock' "${HEINZEL_HOME}" "${name}"
}

lock_holder() {
  local f
  f=$(lock_file "$1" 2>/dev/null) || return 1
  _lock_field "${f}" .pid
}

# Take the lock, waiting up to the timeout for whoever has it. A timeout of 0 is
# one attempt, which is what a caller that has something else to do wants.
lock_acquire() { # name [timeout-sec]
  local name=$1 timeout=${2:-${LOCK_WAIT_SEC}} f deadline json
  f=$(lock_file "${name}") || return 1
  case ${timeout} in
    ""|*[!0-9]*) timeout=${LOCK_WAIT_SEC} ;;
  esac
  deadline=$(( $(now_epoch) + timeout ))
  while :; do
    json=$(jq -c -n \
      --argjson schema_version "${LOCKS_SCHEMA}" \
      --arg name "${name}" \
      --argjson pid "$$" \
      --arg acquired_at "$(iso_at)" \
      '{schema_version: $schema_version, name: $name, pid: $pid,
        acquired_at: $acquired_at}') || return 1
    _lock_take "${f}" "${json}" && return 0
    # A holder that is not there any more is not a holder. Break it and try
    # again immediately rather than waiting out the timeout for a corpse.
    _lock_break "${f}" && continue
    [ "$(now_epoch)" -ge "${deadline}" ] && return 1
    sleep 1
  done
}

# Release the lock, and only if this process is the one holding it. A release
# that did not check is a release of somebody else's lock.
lock_release() { # name
  local name=$1 f
  f=$(lock_file "${name}") || return 1
  [ -e "${f}" ] || return 1
  [ "$(_lock_field "${f}" .pid)" = "$$" ] || return 1
  rm -f "${f}"
}

# Break a lock left by a process that is gone, and print the pid it belonged to.
# Prints nothing and fails when the holder is alive, which is the answer a
# caller needs to tell "I have recovered this" from "somebody is using it".
lock_reclaim() { # name
  local name=$1 f pid
  f=$(lock_file "${name}") || return 1
  pid=$(_lock_field "${f}" .pid) || return 1
  [ -n "${pid}" ] || return 1
  _lock_break "${f}" || return 1
  printf '%s' "${pid}"
}

# Hold the lock for exactly one command and no longer. The command is run in
# this shell, so it can be a function — which is the reason this file exists at
# all. Exit 75 when the lock could not be taken, which is `lockf`'s own
# EX_TEMPFAIL and already what the runner's gate 1 reports.
lock_with() { # name timeout cmd...
  local name=$1 timeout=$2 rc
  shift 2
  lock_acquire "${name}" "${timeout}" || return 75
  "$@"
  rc=$?
  lock_release "${name}"
  return ${rc}
}

# One ledger or session mutation, under the short global lock, spelled the same
# way everywhere. The point of the single spelling is that "is this mutation
# guarded" becomes a question about one name rather than about whether a caller
# remembered the right lock and the right timeout.
#
# A caller that needs several mutations to be one transaction wraps the sequence
# in a function and passes that — the command runs in this shell, so it can be
# one. Nothing here is reentrant: a caller already inside the lock must not use
# it again, which is why `finalize_commit` and `finalize_recover`, which take the
# lock themselves, are called without it.
#
# Failing to take it is loud. Ten seconds is far longer than a ledger mutation,
# so a refusal means something is holding the lock that is not one, and the
# mutation silently not happening is how a completion goes missing.
with_backlog_lock() { # cmd...
  local rc
  lock_with "${LOCK_BACKLOG}" "${LOCK_WAIT_SEC}" "$@"
  rc=$?
  [ ${rc} -eq 75 ] &&
    err "could not take the ${LOCK_BACKLOG} lock in ${LOCK_WAIT_SEC}s: '$1' did not run"
  return ${rc}
}

# --- the workspace writer lease ---------------------------------------------
#
# One writer per checkout (§14.3, invariant 13). Two runs in different Herdr
# namespaces, or one run and one controller, are still two writers in one
# working tree, and the working tree is what they would both be editing.

LEASE_SCHEMA=1

lease_file() { # identity
  local id=$1 hash
  hash=$(claims_workspace_hash "${id}") || return 1
  [ -n "${hash}" ] || return 1
  printf '%s/workspace-leases/%s.json' "${HEINZEL_HOME}" "${hash}"
}

_lease_gen_file() { # identity
  local f
  f=$(lease_file "$1") || return 1
  printf '%s.generation' "${f%.json}"
}

# The fencing counter for one workspace. It only goes up, and it outlives the
# lease it was issued for — that is the difference between a generation and a
# retry count. A holder that comes back after being fenced out compares the
# generation it was issued against the one in force and finds itself old (§14.3);
# a counter that reset when the lease was broken would hand the same number to
# the run that took over, and the two would be indistinguishable.
_lease_bump_generation() { # identity -> the new generation
  local id=$1 f v g dir tmp
  f=$(_lease_gen_file "${id}") || return 1
  dir=$(dirname "${f}")
  mkdir -p "${dir}" || return 1
  chmod 700 "${dir}" 2>/dev/null
  v=0
  [ -r "${f}" ] && v=$(head -1 "${f}" 2>/dev/null | tr -dc '0-9')
  case ${v} in
    ""|*[!0-9]*) v=0 ;;
  esac
  g=$((v + 1))
  tmp=$(mktemp "${dir}/.gen.XXXXXX") || return 1
  if printf '%s\n' "${g}" >"${tmp}" && chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
    printf '%s' "${g}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

_lease_record() { # identity run-id pid generation acquired-at
  jq -c -n \
    --argjson schema_version "${LEASE_SCHEMA}" \
    --arg workspace_identity "$1" \
    --arg run_id "$2" \
    --argjson pid "$3" \
    --argjson generation "$4" \
    --arg acquired_at "$5" \
    --arg renewed_at "$(iso_at)" \
    '{schema_version: $schema_version,
      workspace_identity: $workspace_identity, run_id: $run_id,
      pid: $pid, generation: $generation,
      acquired_at: $acquired_at, renewed_at: $renewed_at}'
}

lease_holder() {
  local f
  f=$(lease_file "$1" 2>/dev/null) || return 1
  _lock_field "${f}" .run_id
}

lease_pid() {
  local f
  f=$(lease_file "$1" 2>/dev/null) || return 1
  _lock_field "${f}" .pid
}

lease_generation() {
  local f v
  f=$(lease_file "$1" 2>/dev/null) || { printf 0; return 1; }
  v=$(_lock_field "${f}" .generation)
  case ${v} in
    ""|*[!0-9]*) printf 0 ;;
    *) printf '%s' "${v}" ;;
  esac
}

# Take the writer lease for a workspace. A lease held by another run is refused
# whether or not that run is still alive: a dead holder is recovered on purpose,
# by `lease_reclaim`, and never as a side effect of somebody wanting the lease.
# The difference matters because it is the same difference as between a run that
# stopped and a run that cannot be reached (invariant 10).
#
# The same run retaking its own lease succeeds and moves the generation on,
# exactly as a claim does: retaking what you already hold is not a conflict.
lease_acquire() { # identity run-id [pid]
  local id=$1 run=$2 pid=${3:-$$} f holder gen json dir tmp
  [ -n "${run}" ] || return 1
  f=$(lease_file "${id}") || return 1
  if [ -e "${f}" ]; then
    holder=$(_lock_field "${f}" .run_id)
    [ "${holder}" = "${run}" ] || return 1
    gen=$(_lease_bump_generation "${id}") || return 1
    json=$(_lease_record "${id}" "${run}" "${pid}" "${gen}" "$(iso_at)") || return 1
    dir=$(dirname "${f}")
    tmp=$(mktemp "${dir}/.lease.XXXXXX") || return 1
    if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
       chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
      return 0
    fi
    rm -f "${tmp}"
    return 1
  fi
  gen=$(_lease_bump_generation "${id}") || return 1
  json=$(_lease_record "${id}" "${run}" "${pid}" "${gen}" "$(iso_at)") || return 1
  _lock_take "${f}" "${json}"
}

# The heartbeat: same holder, same generation, a fresh `renewed_at`. A renewal
# that bumped the generation would fence the holder out of its own lease.
lease_renew() { # identity run-id
  local id=$1 run=$2 f gen pid at json dir tmp
  f=$(lease_file "${id}") || return 1
  [ -e "${f}" ] || return 1
  [ "$(_lock_field "${f}" .run_id)" = "${run}" ] || return 1
  gen=$(lease_generation "${id}")
  pid=$(_lock_field "${f}" .pid)
  at=$(_lock_field "${f}" .acquired_at)
  json=$(_lease_record "${id}" "${run}" "${pid:-0}" "${gen}" "${at}") || return 1
  dir=$(dirname "${f}")
  tmp=$(mktemp "${dir}/.lease.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Release, and only this run's lease. The generation file stays: it is the
# workspace's counter, not this lease's, and it is worth nothing if it resets.
lease_release() { # identity run-id
  local id=$1 run=$2 f
  f=$(lease_file "${id}") || return 1
  [ -e "${f}" ] || return 1
  [ "$(_lock_field "${f}" .run_id)" = "${run}" ] || return 1
  rm -f "${f}"
}

# Recover a lease whose holder is gone, and print the run id it belonged to, so
# that the recovery can be reported as what it is: a named run that stopped
# without giving the checkout back. A live holder is left exactly where it is
# and this prints nothing.
lease_reclaim() { # identity
  local id=$1 f run
  f=$(lease_file "${id}") || return 1
  run=$(_lock_field "${f}" .run_id) || return 1
  [ -n "${run}" ] || return 1
  _lock_break "${f}" || return 1
  printf '%s' "${run}"
}
