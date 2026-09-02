#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/cancel.sh — stopping a run, and the two things that have to be true before
# anything acts on the fact that it stopped.
#
# `hzl off` has stopped a run by sending it a signal and, after thirty seconds,
# a stronger one. Then it printed a summary and returned 0. Nothing checked that
# the process was gone, nothing recorded that it had been asked to go, and the
# claims and the writer lease the run was holding were given back by the run's
# own EXIT trap — which does not run when the run is killed outright. Three
# faults live in that gap (docs/RUNTIME-BACKENDS.md §9.2, §14.4, §14.5):
#
#   the intent      a stop request has to outlive both the run and the command
#                   that made it. A `hzl off` that is itself interrupted between
#                   the signal and the confirmation leaves nothing behind saying
#                   a stop was ever asked for, so the next reader sees a run that
#                   died for no reason rather than one that was cancelled.
#   the barrier     soft interrupt, bounded grace, force stop, and *then* an
#                   observation that the target is gone. Ownership is released on
#                   the strength of that observation and on nothing else.
#   the freeze      a stop that is confirmed is the moment the working directory
#                   stops moving. Every later check is evidence about that state,
#                   so it is digested and the digest is kept: evidence gathered
#                   against a workspace that has since moved is not reused.
#
#   cancel_request   <run-id> <reason> [pid]  -> save the intent, once
#   cancel_state     <run-id>                 -> none|requested|confirmed
#   cancel_requested <run-id>                 -> 0 when one has been asked for
#   cancel_reason    <run-id>                 -> off|travel|ttl|deadline|cancel
#   cancel_confirm   <run-id> <how>           -> the receipt: it stopped
#   cancel_pending                            -> runs asked to stop, unconfirmed
#   cancel_stop  <pid> [grace] [kill] [tree]  -> the barrier. 0 gone, 1 unknown
#
#   workspace_digest  <workdir>               -> what the tree looks like now
#   quiesce_freeze    <run-id> <identity> <workdir> -> the freeze. Prints the
#                                                      generation
#   quiesce_digest    <run-id>                -> the frozen digest
#   quiesce_generation <run-id>
#   quiesce_unchanged <run-id> <workdir>      -> 0 when evidence may be reused
#
# The intent and the receipt are the same shape as `lib/finalize.sh`'s, for the
# same reason: an intent with no receipt beside it is the only record that says
# a thing was asked for and may not have happened. Here that record is what
# `ORPHANED` means — not a failure, and not a success, but a stop that cannot be
# shown to have taken effect, during which claims, the worksheet and the writer
# lease are all kept and no new writer is started (§9.2).
#
# Requires lib/common.sh, lib/watchdog.sh and lib/runstore.sh.

CANCEL_SCHEMA=1

# The barrier's two windows, per process. Long enough for an engine to finish
# writing the file it is in the middle of, short enough that `hzl off` is not
# mistaken for a hang.
CANCEL_GRACE_SEC=30
CANCEL_KILL_SEC=10

# The window `hzl off` gives a runner, which is a different number because a
# runner that has been asked to stop runs this same barrier against its own
# engine before it exits. The barrier above has to outlast the one below it: an
# `off` that waited less than the runner needs would call a stop unconfirmed
# that was seconds away from confirming, and keep a checkout hostage for it.
CANCEL_RUNNER_GRACE_SEC=$((CANCEL_GRACE_SEC + CANCEL_KILL_SEC + 10))

_cancel_intent_file()  { local d; d=$(runstore_dir "$1") || return 1; printf '%s/cancel.intent.json' "${d}"; }
_cancel_receipt_file() { local d; d=$(runstore_dir "$1") || return 1; printf '%s/cancel.receipt.json' "${d}"; }

# Where a stop got to. `confirmed` means something observed the target gone;
# `requested` means it was asked for and nothing says it happened.
cancel_state() { # run-id
  local i r
  i=$(_cancel_intent_file "$1") || return 1
  r=$(_cancel_receipt_file "$1") || return 1
  if [ -r "${r}" ]; then printf confirmed
  elif [ -r "${i}" ]; then printf requested
  else printf none
  fi
}

cancel_requested() { # run-id
  case $(cancel_state "$1" 2>/dev/null) in
    requested|confirmed) return 0 ;;
    *) return 1 ;;
  esac
}

cancel_reason() { # run-id
  local f
  f=$(_cancel_intent_file "$1" 2>/dev/null) || return 1
  [ -r "${f}" ] || return 1
  jq -r '.reason // empty' "${f}" 2>/dev/null
}

# Save the stop request, before anything is signalled. Written whole and renamed
# into place, like every other durable record here.
#
# An intent that is already there is left exactly as it is. The first cause is
# the true one: a run cancelled by `off` and then hurried along by a deadline was
# still cancelled by `off`, and a second request that overwrote the first would
# turn the record of why into the record of what happened last.
cancel_request() { # run-id reason [pid]
  local run=$1 reason=$2 pid=${3:-0} f dir tmp json
  [ -n "${reason}" ] || return 1
  f=$(_cancel_intent_file "${run}") || return 1
  dir=$(dirname "${f}")
  [ -d "${dir}" ] || return 1
  [ -e "${f}" ] && return 0
  case ${pid} in ""|*[!0-9]*) pid=0 ;; esac
  json=$(jq -n \
    --argjson schema_version "${CANCEL_SCHEMA}" \
    --arg run_id "${run}" \
    --arg reason "${reason}" \
    --argjson target_pid "${pid}" \
    --argjson requested_by_pid "$$" \
    --arg requested_at "$(iso_at)" \
    '{schema_version: $schema_version, run_id: $run_id, reason: $reason,
      target_pid: $target_pid, requested_by_pid: $requested_by_pid,
      requested_at: $requested_at}') || return 1
  tmp=$(mktemp "${dir}/.cancel.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && ln "${tmp}" "${f}" 2>/dev/null; then
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  # Lost the race to another canceller, which means an intent is there and the
  # first cause won. That is the outcome this function wanted.
  [ -e "${f}" ]
}

# The receipt: the target was observed to be gone, and here is what observed it.
# Only this file makes it safe to release what the run was holding.
cancel_confirm() { # run-id how
  local run=$1 how=$2 f dir tmp json
  f=$(_cancel_receipt_file "${run}") || return 1
  dir=$(dirname "${f}")
  [ -d "${dir}" ] || return 1
  json=$(jq -n \
    --argjson schema_version "${CANCEL_SCHEMA}" \
    --arg run_id "${run}" \
    --arg reason "$(cancel_reason "${run}" 2>/dev/null)" \
    --arg confirmed_by "$(oneline "${how}")" \
    --arg confirmed_at "$(iso_at)" \
    '{schema_version: $schema_version, run_id: $run_id, reason: $reason,
      confirmed_by: $confirmed_by, confirmed_at: $confirmed_at}') || return 1
  tmp=$(mktemp "${dir}/.receipt.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# The runs that were asked to stop and were never confirmed stopped. What a
# reconcile looks at, and the list a human is owed in the morning.
cancel_pending() {
  local run
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "$(cancel_state "${run}")" = requested ] || continue
    printf '%s\n' "${run}"
  done <<EOF
$(runstore_runs)
EOF
}

# --- the barrier ------------------------------------------------------------

# Wait for a pid to go away, and answer whether it did. Never longer than it was
# given: a barrier that waited indefinitely for a process that is not coming
# back is the hang this exists to bound.
_cancel_wait_gone() { # pid seconds
  local pid=$1 secs=$2 i=0
  case ${secs} in ""|*[!0-9]*) secs=0 ;; esac
  while [ "${i}" -lt "${secs}" ]; do
    pid_alive "${pid}" || return 0
    sleep 1
    i=$((i + 1))
  done
  pid_alive "${pid}" && return 1
  return 0
}

# Soft interrupt, bounded grace, force stop, then look (§14.5). Returns 0 only
# when the target was observed gone — a signal delivered is not a stop, and this
# is the difference the whole of `ORPHANED` rests on.
#
# The fourth argument asks for the process *group* rather than the process. It
# is not the default: `kill -- -N` addresses a group, and a pid that never became
# a group leader is some other group's id, so signalling one on the strength of a
# pid alone would be signalling strangers. Pass it only where the target is known
# to lead its group — `hzl_timeout` puts every engine it starts at the head of
# one — and leave it off for a runner, whose own trap carries the stop down.
cancel_stop() { # pid [grace] [kill-grace] [tree]
  local pid=$1 grace=${2:-${CANCEL_GRACE_SEC}} hard=${3:-${CANCEL_KILL_SEC}} tree=${4:-}
  pid_alive "${pid}" || return 0
  if [ -n "${tree}" ]; then
    hzl_signal_tree TERM "${pid}"
  else
    kill -TERM "${pid}" 2>/dev/null
  fi
  _cancel_wait_gone "${pid}" "${grace}" && return 0
  if [ -n "${tree}" ]; then
    hzl_signal_tree KILL "${pid}"
  else
    kill -KILL "${pid}" 2>/dev/null
  fi
  _cancel_wait_gone "${pid}" "${hard}"
}

# --- the freeze -------------------------------------------------------------

QUIESCE_SCHEMA=1

# The names a workspace digest never descends into — the list `hzl-changeset`
# prunes, for the same reasons and one more. `.git` because a repository's state
# is HEAD and its status, not the bytes of its object store; the build and cache
# directories because a digest that moved every time a test wrote a `.pyc` would
# report every review as stale; and `.heinzel` because the run's own worksheet is
# scaffolding it wrote itself, not somebody else's edit.
QUIESCE_PRUNE=".git node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .heinzel"

# What the working directory looks like, as lines that change when it does.
#
# Repositories at most two levels down answer with HEAD and the porcelain
# status, because that is what a repository's state *is* and because it is one
# process for a tree of any size. Everything else answers with `cksum`: content,
# length and path in a single pass. Content and not a timestamp, deliberately —
# an mtime that moved without the bytes moving would report a change that did not
# happen, and a check that cries stale on every run is a check nobody keeps.
_workspace_listing() { # workdir
  local root=$1 d name
  local expr=()
  for d in "${root}" "${root}"/*/ "${root}"/*/*/; do
    [ -d "${d}/.git" ] || continue
    d=${d%/}
    printf 'git\t%s\t%s\t%s\n' "${d}" \
      "$(git -C "${d}" rev-parse HEAD 2>/dev/null || printf none)" \
      "$(git -C "${d}" status --porcelain 2>/dev/null | cksum | tr -d ' \n')"
  done 2>/dev/null | sort
  for name in ${QUIESCE_PRUNE}; do
    expr+=(-name "${name}" -prune -o)
  done
  find "${root}" "${expr[@]}" -type f -exec cksum {} + 2>/dev/null | sort
}

workspace_digest() { # workdir
  local root=$1 v=""
  [ -n "${root}" ] && [ -d "${root}" ] || return 1
  if have shasum; then
    v=$(_workspace_listing "${root}" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
  fi
  case ${v} in
    [0-9a-f][0-9a-f]*) printf 'sha256:%s' "${v}" ;;
    *) printf 'cksum:%s' "$(_workspace_listing "${root}" | cksum | tr -d ' \n')" ;;
  esac
}

_quiesce_file() { local d; d=$(runstore_dir "$1") || return 1; printf '%s/quiesce.json' "${d}"; }

# Freeze the workspace. Called once the writer has been confirmed gone, which is
# the only moment the answer means anything: a digest taken while an engine is
# still writing is a digest of a file half way through being saved.
#
# Prints the generation, and the generation goes up every time. A fix pass is a
# new writer under the same lease, so what it leaves behind is a new state to be
# evidence about and not a second reading of the first one (§9.2).
quiesce_freeze() { # run-id identity workdir
  local run=$1 id=$2 wd=$3 f dir tmp gen json digest
  f=$(_quiesce_file "${run}") || return 1
  dir=$(dirname "${f}")
  [ -d "${dir}" ] || return 1
  gen=0
  if [ -r "${f}" ]; then
    gen=$(jq -r '.generation // 0' "${f}" 2>/dev/null)
    case ${gen} in ""|*[!0-9]*) gen=0 ;; esac
  fi
  gen=$((gen + 1))
  digest=$(workspace_digest "${wd}") || return 1
  [ -n "${digest}" ] || return 1
  json=$(jq -n \
    --argjson schema_version "${QUIESCE_SCHEMA}" \
    --arg run_id "${run}" \
    --arg workspace_identity "${id}" \
    --arg workdir "${wd}" \
    --arg workspace_digest "${digest}" \
    --argjson generation "${gen}" \
    --arg frozen_at "$(iso_at)" \
    '{schema_version: $schema_version, run_id: $run_id,
      workspace_identity: $workspace_identity, workdir: $workdir,
      workspace_digest: $workspace_digest, generation: $generation,
      frozen_at: $frozen_at}') || return 1
  tmp=$(mktemp "${dir}/.quiesce.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
    printf '%s' "${gen}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

quiesce_digest() { # run-id
  local f
  f=$(_quiesce_file "$1" 2>/dev/null) || return 1
  [ -r "${f}" ] || return 1
  jq -r '.workspace_digest // empty' "${f}" 2>/dev/null
}

quiesce_generation() { # run-id
  local f v
  f=$(_quiesce_file "$1" 2>/dev/null) || { printf 0; return 1; }
  [ -r "${f}" ] || { printf 0; return 1; }
  v=$(jq -r '.generation // 0' "${f}" 2>/dev/null)
  case ${v} in
    ""|*[!0-9]*) printf 0 ;;
    *) printf '%s' "${v}" ;;
  esac
}

# May evidence gathered since the freeze still be used? Only if the working
# directory is the one that was frozen (§13.2). A tree that moved underneath a
# reviewer means its verdict is about a state that no longer exists, and a
# verdict about a state that no longer exists is not evidence about this one —
# in either direction, because a rejection would revert real work on the
# strength of it just as an approval would keep bad work.
#
# A run with no frozen digest answers yes. There is nothing to invalidate: the
# store is allowed to fail and the run happens anyway, and a check that failed
# closed on a missing freeze would refuse the work of every run whose bookkeeping
# broke. A workdir that has gone away answers no — that is a change, and the
# largest one available.
quiesce_unchanged() { # run-id workdir
  local run=$1 wd=$2 was now
  was=$(quiesce_digest "${run}" 2>/dev/null) || return 0
  [ -n "${was}" ] || return 0
  now=$(workspace_digest "${wd}") || return 1
  [ "${was}" = "${now}" ]
}
