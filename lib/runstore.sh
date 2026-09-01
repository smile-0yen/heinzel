#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/runstore.sh — the durable per-run store.
#
# One directory per run under `HEINZEL_HOME`, which is the point: the agent is
# denied that path wholesale, so a record kept there is a record the thing being
# recorded cannot edit (docs/RUNTIME-BACKENDS.md §14.1).
#
#   ~/.heinzel/runs/<run-id>/
#     workflow.json    the current snapshot. Recovery reads this and nothing else
#     events.jsonl     append-only, one line per thing that happened
#
# Two files because they answer two questions. *What is true now* has to be
# replaceable, so it is one small document rewritten whole. *What happened* has
# to be unforgeable after the fact, so it is only ever appended to. A snapshot
# that grew a history would eventually be too big to rewrite atomically, and a
# log that had to be rewritten to answer "where is this run now" would stop
# being an audit trail the first time it was compacted.
#
#   runstore_new_id                             -> a sortable run id
#   runstore_dir      <run-id>                  -> the path, or a refusal
#   runstore_init     <run-id>                  -> creates it
#   runstore_snapshot <run-id> <json>           -> replaces workflow.json
#   runstore_read     <run-id>                  -> the snapshot on stdout
#   runstore_event    <run-id> <kind> [message] -> appends one line
#   runstore_runs                               -> the run ids, oldest first
#
# The store is additive to everything that was already written: the day log,
# `runs.jsonl`, the notes and the exec directory are untouched and still hold
# what they held. Nothing here is load-bearing yet — a run whose store cannot be
# written is a run that still happens, and says so in the log.
#
# Requires lib/common.sh.

RUNSTORE_SCHEMA=1

# A run id is a timestamp and a random suffix (§14.2):
#
#   r-20260902T031500-k7w3m2
#
# Sortable, because the timestamp is fixed-width and comes first, so the ids
# sort chronologically as plain strings and `ls` is in run order.
#
# Distinct from a task id, because `h-0007` and a run id must never be mistaken
# for one another: the ledger's own id allocator reads `<letters>-<digits>` and
# nothing else, and this shape cannot match it.
#
# Random, because a second is not fine enough to key a durable store by. The
# existing second-precision `RUN_ID` stays exactly as it is — it is what the
# ledger's `run:` provenance and `runs.jsonl` are written in, and this store
# records it rather than replacing it.
runstore_new_id() {
  local stamp suffix
  stamp=$(date +%Y%m%dT%H%M%S)
  # tr takes a SIGPIPE when head has had enough, which is why the result is
  # checked for shape rather than the pipeline for status.
  suffix=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6)
  case ${suffix} in
    [a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;;
    # No /dev/urandom, or a tr that gave up early. Still six characters, still
    # from the same alphabet, and still different between two runs in a second.
    *) suffix=$(printf '%06x' $(( ((RANDOM * 32768) + RANDOM) % 16777216 ))) ;;
  esac
  printf 'r-%s-%s' "${stamp}" "${suffix}"
}

# The directory for a run, and the one place a run id becomes a path. A id that
# is not the shape this file writes is refused rather than joined onto
# HEINZEL_HOME: `.` is not in the permitted set, so `..` cannot be spelled.
runstore_dir() {
  local id=$1
  case ${id} in
    ""|*[!a-zA-Z0-9_-]*)
      err "not a usable run id: '${id}'"
      return 1
      ;;
  esac
  printf '%s/runs/%s' "${HEINZEL_HOME}" "${id}"
}

runstore_init() {
  local id=$1 dir
  dir=$(runstore_dir "${id}") || return 1
  mkdir -p "${dir}" || return 1
  chmod 700 "${dir}" 2>/dev/null
  return 0
}

# Replace the snapshot. Validated first and renamed into place, so a reader
# either sees the whole of the previous snapshot or the whole of this one and
# never the space between them: the temp file is in the same directory as the
# target, which is what makes the rename atomic rather than a copy (§14.1).
#
# A snapshot that does not parse is refused and the previous one is left
# standing. The alternative — truncating the file and then discovering the new
# content is unusable — destroys the only record of where the run had got to,
# at the exact moment something is already going wrong.
runstore_snapshot() {
  local id=$1 json=$2 dir tmp
  dir=$(runstore_dir "${id}") || return 1
  [ -d "${dir}" ] || return 1
  tmp=$(mktemp "${dir}/.workflow.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null; then
    chmod 600 "${tmp}" && mv -f "${tmp}" "${dir}/workflow.json" && return 0
  fi
  rm -f "${tmp}"
  return 1
}

runstore_read() {
  local id=$1 dir
  dir=$(runstore_dir "${id}") || return 1
  [ -r "${dir}/workflow.json" ] || return 1
  cat "${dir}/workflow.json"
}

# Append one event. The line is built whole before the file is opened for
# appending, so the failure that would tear a line — a process that dies
# half-way through composing one — cannot happen after the write has started.
runstore_event() {
  local id=$1 kind=$2 message=${3:-} dir line
  dir=$(runstore_dir "${id}") || return 1
  [ -d "${dir}" ] || return 1
  line=$(jq -c -n \
    --argjson schema_version "${RUNSTORE_SCHEMA}" \
    --arg at "$(iso_at)" \
    --arg kind "${kind}" \
    --arg message "$(oneline "${message}")" \
    '{schema_version: $schema_version, at: $at, kind: $kind,
      message: $message}') || return 1
  printf '%s\n' "${line}" >>"${dir}/events.jsonl"
}

# The runs that have a store, oldest first — which is plain lexicographic order,
# because that is what the id shape is for.
runstore_runs() {
  local d
  [ -d "${HEINZEL_HOME}/runs" ] || return 0
  for d in "${HEINZEL_HOME}"/runs/*/; do
    [ -d "${d}" ] || continue
    d=${d%/}
    printf '%s\n' "${d##*/}"
  done | sort
}
