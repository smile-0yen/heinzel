#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/runtimes/local.sh — the local runtime backend.
#
# It starts a process on this machine, holds it to a wall clock, and writes down
# what it observed. It does not know what an engine is, what a role is, or what
# any of the arguments it passes on mean. Everything it needs arrives as JSON
# (docs/RUNTIME-BACKENDS.md §8.4).
#
#   runtime_local_run_batch <launch.json> <run.json> <collected.json>
#
# launch.json     schema_version, executable, argv[], env{}   (the Agent Driver
#                 writes it; see lib/engines.sh)
# run.json        schema_version, cwd, timeout_sec, kill_after_sec,
#                 stdout_path, stderr_path, output_path
# collected.json  schema_version, exit_code, duration_sec, and the three paths
#                 it wrote to, so a later reader does not have to remember them
#
# Requires lib/common.sh and lib/watchdog.sh.

runtime_register local

# `([0] | implode)` is jq for one NUL byte. It is written that way rather than
# as a unicode escape because the escape is invisible in a diff, and an editor
# that mangled it would produce a launch that still looked right.
runtime_local_run_batch() {
  local launch=$1 run=$2 collected=$3
  local executable cwd tmo kill_after stdout_path stderr_path output_path
  local rc started ended prev_pwd arg
  local -a cmd

  executable=$(jq -r '.executable // ""' "${launch}" 2>/dev/null) || return 1
  [ -n "${executable}" ] || { err "launch spec names no executable"; return 1; }

  # This backend cannot carry a launch environment yet. Refusing beats dropping
  # it: a backend that silently honours half a launch spec is worse than one
  # that says plainly it cannot honour all of it (§8.1).
  if [ "$(jq -r '.env | length' "${launch}" 2>/dev/null)" != 0 ]; then
    err "the local runtime does not carry a launch environment yet"
    return 1
  fi

  cwd=$(jq -r '.cwd // ""' "${run}" 2>/dev/null) || return 1
  tmo=$(jq -r '.timeout_sec // 3600' "${run}")
  kill_after=$(jq -r '.kill_after_sec // 30' "${run}")
  stdout_path=$(jq -r '.stdout_path' "${run}")
  stderr_path=$(jq -r '.stderr_path' "${run}")
  output_path=$(jq -r '.output_path' "${run}")

  # argv is restored NUL-delimited through process substitution, never split on
  # newlines and never rebuilt with eval: an argument may hold anything a byte
  # can hold except NUL itself, which is exactly why NUL is the separator. A
  # `while` at the end of a pipe would run in a subshell and the array would not
  # survive it (§8.4).
  cmd=()
  while IFS= read -r -d '' arg; do
    cmd[${#cmd[@]}]="${arg}"
  done < <(jq -j -r '.argv[] | ., ([0] | implode)' "${launch}")
  [ ${#cmd[@]} -gt 0 ] || { err "launch spec has an empty argv"; return 1; }

  started=$(now_epoch)

  # cd here rather than wrapping the command in a subshell: `( cd x && cmd ) &`
  # would make $! the subshell's pid, and killing that leaves the engine itself
  # running as an orphan. stdin is closed because codex exec treats a non-TTY
  # stdin as additional input and waits for EOF, which hangs forever under
  # launchd even when the prompt was passed as an argument.
  prev_pwd=${PWD}
  cd "${cwd}" || { err "cannot cd to ${cwd}"; return 1; }
  hzl_timeout "${kill_after}" "${tmo}" "${executable}" "${cmd[@]}" \
    >"${stdout_path}" 2>"${stderr_path}" </dev/null
  rc=$?
  cd "${prev_pwd}" || true

  ended=$(now_epoch)

  # Same directory, then rename: a reader never sees half a record, and the
  # rename is the moment the run became observable (§8.4).
  jq -n \
    --argjson exit_code "${rc}" \
    --argjson duration_sec "$((ended - started))" \
    --arg stdout_path "${stdout_path}" \
    --arg stderr_path "${stderr_path}" \
    --arg output_path "${output_path}" \
    '{schema_version: 1, exit_code: $exit_code, duration_sec: $duration_sec,
      stdout_path: $stdout_path, stderr_path: $stderr_path,
      output_path: $output_path}' >"${collected}.tmp" || return 1
  mv "${collected}.tmp" "${collected}" || return 1

  return "${rc}"
}
