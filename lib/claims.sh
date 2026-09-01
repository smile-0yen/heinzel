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
#   claims_generation <identity> <task-id>           -> the fencing generation
#   claims_of_run   <identity> <run-id>              -> its task ids
#   claims_runs     <identity>                       -> every run holding one
#   claims_reconcile <identity> <run-id>             -> releases exactly its own
#   claims_rollback_run <identity> <backlog> <run-id>  -> release + unmark
#
# Requires lib/common.sh.

CLAIMS_SCHEMA=1

# What "the same workspace" means. Host and absolute path today; a worktree or
# a remote checkout will need more, which is why callers pass an identity string
# around rather than a path (§13.4).
claims_workspace_identity() {
  local workdir=$1 host
  [ -n "${workdir}" ] || return 1
  host=$(hostname -s 2>/dev/null)
  [ -n "${host}" ] || host=localhost
  printf '%s:%s' "${host}" "$(abspath "${workdir}")"
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

# Take a task for a run. A task already held by *another* run is refused: that
# is the whole point of a claim, and a run that took one anyway would be the
# second writer in a workspace built for one.
#
# The same run re-acquiring its own claim succeeds and bumps the generation.
# Retaking a claim you already hold is not a conflict, and the generation is
# what a later fencing check compares against (§14.3).
claims_acquire() {
  local id=$1 task=$2 run=$3 f dir holder gen tmp
  [ -n "${run}" ] || return 1
  f=$(_claims_file "${id}" "${task}") || return 1
  dir=$(dirname "${f}")
  mkdir -p "${dir}" || return 1
  chmod 700 "${dir}" 2>/dev/null

  gen=1
  if [ -r "${f}" ]; then
    holder=$(jq -r '.run_id // ""' "${f}" 2>/dev/null)
    if [ -n "${holder}" ] && [ "${holder}" != "${run}" ]; then
      return 1
    fi
    gen=$(($(claims_generation "${id}" "${task}") + 1))
  fi

  tmp=$(mktemp "${dir}/.claim.XXXXXX") || return 1
  if jq -n \
       --argjson schema_version "${CLAIMS_SCHEMA}" \
       --arg workspace_identity "${id}" \
       --arg task_id "${task}" \
       --arg run_id "${run}" \
       --argjson generation "${gen}" \
       --arg claimed_at "$(iso_at)" \
       '{schema_version: $schema_version,
         workspace_identity: $workspace_identity, task_id: $task_id,
         run_id: $run_id, generation: $generation,
         claimed_at: $claimed_at}' >"${tmp}" 2>/dev/null; then
    chmod 600 "${tmp}" && mv -f "${tmp}" "${f}" && return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Release one claim, and only if this run is the one holding it. A release that
# did not check would be the blanket rollback again, one file at a time.
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
