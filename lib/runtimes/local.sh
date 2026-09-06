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
  local rc started ended prev_pwd arg key value bad
  local -a cmd envp cmdline

  executable=$(jq -r '.executable // ""' "${launch}" 2>/dev/null) || return 1
  [ -n "${executable}" ] || { err "launch spec names no executable"; return 1; }

  # Schema validation, before anything is started (§8.4). Two things a launch
  # spec can hold that a process cannot be given: a NUL byte anywhere in argv or
  # in an environment value — no OS argv or environ entry can carry one, and it
  # is also the delimiter the restores below use, so an argument holding one
  # would arrive as two — and an environment name outside `[A-Za-z_][A-Za-z0-9_]*`,
  # which `env` would read as part of a value or refuse outright. Refusing beats
  # honouring half a launch spec (§8.1).
  bad=$(jq -r '
      def nul: ([0] | implode);
      if ((.argv // []) | any(type != "string")) then
        "launch spec has an argument that is not a string"
      elif ((.argv // []) | any(contains(nul))) then
        "launch spec has an argument holding a NUL byte"
      elif ((.env // {}) | type) != "object" then
        "launch spec has an env that is not an object"
      elif ((.env // {}) | keys_unsorted
             | any(test("^[A-Za-z_][A-Za-z0-9_]*$") | not)) then
        "launch spec has an environment name that is not a variable name"
      elif ((.env // {}) | to_entries | any(.value | type != "string")) then
        "launch spec has an environment value that is not a string"
      elif ((.env // {}) | to_entries | any(.value | contains(nul))) then
        "launch spec has an environment value holding a NUL byte"
      else "" end' "${launch}" 2>/dev/null) || return 1
  [ -z "${bad}" ] || { err "${bad}"; return 1; }

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

  # env comes back the same way, name and value alternating, for the same
  # reason: a value may hold a newline or an `=` and still be one value.
  envp=()
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    envp[${#envp[@]}]="${key}=${value}"
  done < <(jq -j -r \
    '(.env // {}) | to_entries[] | .key, ([0] | implode), .value, ([0] | implode)' \
    "${launch}")

  # `env KEY=VALUE ... command` (§8.4), and nothing at all when there is no
  # environment to carry. `env` execs the command in its own process, so the pid
  # the watchdog holds is still the agent's own and the process group it signals
  # is unchanged.
  cmdline=()
  if [ ${#envp[@]} -gt 0 ]; then
    cmdline=(env "${envp[@]}")
  fi
  cmdline[${#cmdline[@]}]="${executable}"
  cmdline+=("${cmd[@]}")

  started=$(now_epoch)

  # cd here rather than wrapping the command in a subshell: `( cd x && cmd ) &`
  # would make $! the subshell's pid, and killing that leaves the engine itself
  # running as an orphan. stdin is closed because codex exec treats a non-TTY
  # stdin as additional input and waits for EOF, which hangs forever under
  # launchd even when the prompt was passed as an argument.
  prev_pwd=${PWD}
  cd "${cwd}" || { err "cannot cd to ${cwd}"; return 1; }
  hzl_timeout "${kill_after}" "${tmo}" "${cmdline[@]}" \
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
