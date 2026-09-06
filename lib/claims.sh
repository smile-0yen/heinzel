#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/claims.sh — who is allowed to work on which task, and which run said so.
#
# The ledger's `[~]` marker has been doing two jobs: telling a human what is
# being worked on, and being the record of it. It cannot do the second one. It
# lives in a file inside the agent's write radius, it carries no run id that
# anything checks, and rolling it back has been all-or-nothing — one blanket
# pass that puts every `[~]` in the file back to `[ ]`, whoever set it.
#
# So the record moves to `HEINZEL_HOME`, which the agent cannot write, and the
# marker becomes what it is good at: display (docs/RUNTIME-BACKENDS.md §13.4).
#
#   ~/.heinzel/claims/<workspace-hash>/<task-id>.json
#
# A claim names the workspace, the task, the run holding it and a generation.
# Everything here is scoped to one run: acquiring, releasing and reconciling
# take a run id and touch that run's claims and nobody else's. That is the whole
# reason the file exists — the blanket rollback it replaces cannot coexist with
# two runs, and cannot tell a claim a human should look at from one that is
# simply stale.
#
#   claims_workspace_identity <workdir>              -> host:path
#   claims_workspace_hash     <identity>             -> a short digest
#   claims_dir                <identity>             -> the directory
#   claims_acquire  <identity> <task-id> <run-id>    -> 0, or 1 if held
#   claims_release  <identity> <task-id> <run-id>    -> only this run's claim
#   claims_holder   <identity> <task-id>             -> the run id, or empty
#   claims_generation <identity> <task-id>           -> the claim's generation
#   claims_of_run   <identity> <run-id>              -> its task ids
#   claims_runs     <identity>                       -> every run holding one
#   claims_reconcile <identity> <run-id>             -> releases exactly its own
#   claims_rollback_run <identity> <backlog> <run-id>  -> release + unmark
#
# Requires lib/common.sh.

CLAIMS_SCHEMA=1

# What "the same workspace" means. Host and physical path today; a worktree or
# a remote checkout will need more, which is why callers pass an identity string
# around rather than a path (§13.4).
#
# Physical, not merely absolute: `cd -P` resolves every symlink on the way,
# including the last component, which `abspath` does not — it canonicalises the
# parent and keeps the name. One directory reached as itself and as a symlink to
# it would otherwise be two identities with two claims directories, and neither
# would see the other's claims. That is a workspace claimed twice at once, which
# is the one thing a claim exists to prevent.
#
# A workdir that is not there falls back to `abspath`: there is nothing to
# resolve, and refusing would turn "no such directory" into "no identity" for
# every caller that only wanted to name one.
claims_workspace_identity() {
  local workdir=$1 host path
  [ -n "${workdir}" ] || return 1
  host=$(hostname -s 2>/dev/null)
  [ -n "${host}" ] || host=localhost
  path=$(cd -P "${workdir}" 2>/dev/null && pwd)
  [ -n "${path}" ] || path=$(abspath "${workdir}")
  printf '%s:%s' "${host}" "${path}"
}

# A directory name that cannot contain a path separator, whatever the identity
# was. Short enough to read in `ls`, long enough not to collide.
claims_workspace_hash() {
  local id=$1 v=""
  [ -n "${id}" ] || return 1
  if have shasum; then
    v=$(printf '%s' "${id}" | shasum -a 256 2>/dev/null | cut -c1-16)
  fi
  case ${v} in
    [0-9a-f][0-9a-f]*) ;;
    # No shasum: still deterministic, still collision-resistant enough to
    # separate the two or three checkouts one machine works on.
    *) v=$(printf '%s' "${id}" | cksum | tr -d ' \n' | cut -c1-16) ;;
  esac
  printf '%s' "${v}"
}

claims_dir() {
  local id=$1 hash
  hash=$(claims_workspace_hash "${id}") || return 1
  [ -n "${hash}" ] || return 1
  printf '%s/claims/%s' "${HEINZEL_HOME}" "${hash}"
}

# A task id becomes a filename, so it is checked the way a run id is: `.` is not
# in the permitted set, so `..` cannot be spelled.
_claims_file() {
  local id=$1 task=$2 dir
  case ${task} in
    ""|*[!a-zA-Z0-9_-]*)
      err "not a usable task id: '${task}'"
      return 1
      ;;
  esac
  dir=$(claims_dir "${id}") || return 1
  printf '%s/%s.json' "${dir}" "${task}"
}

claims_holder() {
  local f
  f=$(_claims_file "$1" "$2" 2>/dev/null) || return 1
  [ -r "${f}" ] || return 1
  jq -r '.run_id // ""' "${f}" 2>/dev/null
}

# The generation the claim standing right now was issued at, and 0 when nothing
# holds it. What a fencing check compares against.
claims_generation() {
  local f v
  f=$(_claims_file "$1" "$2" 2>/dev/null) || return 1
  [ -r "${f}" ] || { printf 0; return 1; }
  v=$(jq -r '.generation // 0' "${f}" 2>/dev/null)
  case ${v} in
    ""|*[!0-9]*) printf 0 ;;
    *) printf '%s' "${v}" ;;
  esac
}

_claims_gen_file() { # identity task
  local f
  f=$(_claims_file "$1" "$2") || return 1
  printf '%s.generation' "${f%.json}"
}

# The fencing counter for one task in one workspace. It only goes up, and it
# outlives the claim it was issued for — that is the difference between a
# generation and a retry count. A holder that comes back after its claim was
# released and retaken compares the generation it was issued against the one in
# force and finds itself old (§14.3); a counter kept in the claim file itself
# went away with it and started again at 1, so the run that took over was handed
# a number the previous holder already had and the two were indistinguishable.
# `lib/locks.sh` keeps its lease generation the same way, for the same reason.
#
# It is bumped before the claim is taken, so a run that loses the race has still
# consumed a number. Generations must be unique and increasing, not gapless.
_claims_bump_generation() { # identity task -> the new generation
  local id=$1 task=$2 f v g dir tmp
  f=$(_claims_gen_file "${id}" "${task}") || return 1
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

_claims_record() { # identity task run-id generation
  jq -c -n \
    --argjson schema_version "${CLAIMS_SCHEMA}" \
    --arg workspace_identity "$1" \
    --arg task_id "$2" \
    --arg run_id "$3" \
    --argjson generation "$4" \
    --arg claimed_at "$(iso_at)" \
    '{schema_version: $schema_version,
      workspace_identity: $workspace_identity, task_id: $task_id,
      run_id: $run_id, generation: $generation,
      claimed_at: $claimed_at}' 2>/dev/null
}

# Create the file holding this claim, or fail because somebody else already did.
# Written whole into a temp file in the same directory, then `ln`: link refuses
# an existing name, and the refusal is the filesystem's, so of two runs that
# both found the task free exactly one ends up holding it. `mv` would not do —
# it replaces, which is how a check-then-write lets both callers believe they
# won.
#
# This is the technique `_lock_take` in lib/locks.sh uses, spelled out again
# rather than shared: locks.sh already depends on this file for the workspace
# hash, and a dependency the other way as well would make the two impossible to
# source in either order.
_claims_take() { # file json
  local f=$1 json=$2 dir tmp
  dir=$(dirname "${f}")
  tmp=$(mktemp "${dir}/.claim.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
     chmod 600 "${tmp}" && ln "${tmp}" "${f}" 2>/dev/null; then
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Take a task for a run. A task already held by *another* run is refused: that
# is the whole point of a claim, and a run that took one anyway would be the
# second writer in a workspace built for one.
#
# A free task is taken by creating its file, which the filesystem allows exactly
# one caller to do. Reading the file and then writing it would let two runs that
# both found it free both write it and both return 0, and the second would
# overwrite the first's record of holding it — the claim would say one run held
# a task two were working on. That the short locks happen to serialise today's
# only caller is not the claim keeping its own promise.
#
# The same run re-acquiring its own claim succeeds and bumps the generation.
# Retaking a claim you already hold is not a conflict, and only the holder takes
# this path, so replacing the file it already owns is safe.
claims_acquire() {
  local id=$1 task=$2 run=$3 f dir holder gen json tmp
  [ -n "${run}" ] || return 1
  f=$(_claims_file "${id}" "${task}") || return 1
  dir=$(dirname "${f}")
  mkdir -p "${dir}" || return 1
  chmod 700 "${dir}" 2>/dev/null

  if [ -e "${f}" ]; then
    holder=$(jq -r '.run_id // ""' "${f}" 2>/dev/null)
    [ "${holder}" = "${run}" ] || return 1
    gen=$(_claims_bump_generation "${id}" "${task}") || return 1
    json=$(_claims_record "${id}" "${task}" "${run}" "${gen}") || return 1
    [ -n "${json}" ] || return 1
    tmp=$(mktemp "${dir}/.claim.XXXXXX") || return 1
    if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null &&
       chmod 600 "${tmp}" && mv -f "${tmp}" "${f}"; then
      return 0
    fi
    rm -f "${tmp}"
    return 1
  fi

  gen=$(_claims_bump_generation "${id}" "${task}") || return 1
  json=$(_claims_record "${id}" "${task}" "${run}" "${gen}") || return 1
  [ -n "${json}" ] || return 1
  _claims_take "${f}" "${json}"
}

# Release one claim, and only if this run is the one holding it. A release that
# did not check would be the blanket rollback again, one file at a time.
#
# The generation file stays. It is the task's counter, not this claim's, and it
# is worth nothing if it resets: the next holder would be issued a number the
# last one already had.
claims_release() {
  local id=$1 task=$2 run=$3 f holder
  f=$(_claims_file "${id}" "${task}") || return 1
  [ -e "${f}" ] || return 1
  holder=$(jq -r '.run_id // ""' "${f}" 2>/dev/null)
  [ "${holder}" = "${run}" ] || return 1
  rm -f "${f}"
}

# The task ids a run is holding, in ledger order rather than filesystem order.
claims_of_run() {
  local id=$1 run=$2 dir f holder
  dir=$(claims_dir "${id}") || return 1
  [ -d "${dir}" ] || return 0
  for f in "${dir}"/*.json; do
    [ -r "${f}" ] || continue
    holder=$(jq -r '.run_id // ""' "${f}" 2>/dev/null)
    [ "${holder}" = "${run}" ] || continue
    f=${f##*/}
    printf '%s\n' "${f%.json}"
  done | sort
}

# Every run holding at least one claim here, deduplicated. What a reconcile
# iterates over.
claims_runs() {
  local id=$1 dir f
  dir=$(claims_dir "${id}") || return 1
  [ -d "${dir}" ] || return 0
  for f in "${dir}"/*.json; do
    [ -r "${f}" ] || continue
    jq -r '.run_id // empty' "${f}" 2>/dev/null
  done | sort -u
}

# Release exactly one run's claims, and print how many. Nothing else in the
# workspace is touched — not another run's claims, and not a claim a human is
# looking at. Prints 0 and succeeds when that run holds none, because a
# reconcile that found nothing to do did its job.
claims_reconcile() {
  local id=$1 run=$2 task n=0
  [ -n "${run}" ] || { printf 0; return 1; }
  while IFS= read -r task; do
    [ -n "${task}" ] || continue
    claims_release "${id}" "${task}" "${run}" && n=$((n + 1))
  done <<EOF
$(claims_of_run "${id}" "${run}")
EOF
  printf '%s' "${n}"
}

# The rollback, run-scoped: put this run's `[~]` lines back to `[ ]` and drop
# its claims. The marker is a projection of the claim, so the two move together
# and in that order — a marker cleared while the claim survived would show a
# task as free that nothing may take.
#
# Only `[~]` is touched. A task the run had claimed and the merge has since
# marked `[x]` or `[!]` keeps that marker: the work happened, and the claim
# going away is what the release is for.
claims_rollback_run() {
  local id=$1 backlog=$2 run=$3 task marker n=0
  while IFS= read -r task; do
    [ -n "${task}" ] || continue
    if [ -n "${backlog}" ] && [ -w "${backlog}" ]; then
      marker=$(backlog_marker_of_id "${backlog}" "${task}")
      if [ "${marker}" = "~" ]; then
        backlog_set_state "${backlog}" "${task}" " " "" && n=$((n + 1))
      fi
    fi
    claims_release "${id}" "${task}" "${run}"
  done <<EOF
$(claims_of_run "${id}" "${run}")
EOF
  printf '%s' "${n}"
}
