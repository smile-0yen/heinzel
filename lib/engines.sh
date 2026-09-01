#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/engines.sh — the Agent Driver: the only file that knows how to start an
# agent CLI, plus the local supervision that engine_run still performs itself.
#
# The runner knows two things and no more: engine_run, and the normalised
# result.json it leaves behind. Adding an engine touches this file only.
#
# The file is in two halves, and the line between them is the point
# (docs/RUNTIME-BACKENDS.md §7):
#
#   Agent Driver          knows engines, knows nothing about processes. It
#                         turns an engine and a role into a launch spec, and a
#                         collected output back into a result.
#   local supervision     knows processes, knows nothing about engines. It
#                         starts the executable a launch spec names, under the
#                         watchdog, and records what it left behind.
#
# The launch is structured data — executable, argv array, env — never a shell
# command string, so that a runtime that is not this shell can start it
# (§7, §8.4). Phase 2 moves the supervision half to lib/runtimes/local.sh
# behind the backend registry; keeping the boundary here first means that move
# is a move rather than a rewrite.
#
# Public contract:
#
#   engine_available    <engine>                      -> 0/1
#   engine_auth_ok      <engine>                      -> 0/1
#   engine_is_auth_error <engine> <rc> <errfile>      -> 0/1
#   engine_build_launch <engine> <role> <io-mode> <workdir> <promptfile>
#                       <outdir> <spec.json>
#   engine_normalize_result <spec.json> <collected.json> <result.json>
#   engine_run <engine> <role> <workdir> <promptfile> <outdir> [timeout_sec]
#
# engine_run leaves in <outdir>:
#   raw            the engine's own output (claude: JSON, codex: JSONL)
#   last.txt       the final message, in the same place for every engine
#   stderr         standard error; the input to auth-failure detection
#   result.json    the engine-independent result. Callers read only this.
#   launch.json    the launch spec that was used
#   collected.json what supervision observed: exit code, duration, paths
#   dry-run.cmd    with HEINZEL_DRY_RUN=1: the command, NUL-separated so that
#                  a multi-line argument stays one argument
#
# Requires lib/common.sh and lib/watchdog.sh.

# --- availability and authentication ---------------------------------------

engine_available() { have "$1"; }

engine_auth_ok() {
  case $1 in
    claude)
      # Authentication may come from settings or the environment, and there is
      # no cheap offline probe that does not risk a false negative. Report ok
      # and let doctor check the environment separately.
      return 0
      ;;
    codex)
      # `codex login status` writes its message to stderr and exits 0 either
      # way, so reading with 2>/dev/null always looks like "not logged in".
      codex login status 2>&1 | grep -qi "logged in"
      ;;
    *) return 1 ;;
  esac
}

# Deciding this per engine is not fussiness. codex prints MCP HTTP 401s to
# stderr on runs that succeeded; reusing claude's pattern would halt the whole
# tool the first time codex exited non-zero for any unrelated reason.
engine_is_auth_error() {
  local engine=$1 rc=$2 errfile=$3
  # A successful run is never an auth failure, whatever it printed.
  [ "${rc}" -eq 0 ] && return 1
  [ -r "${errfile}" ] || return 1
  case ${engine} in
    claude)
      grep -qiE '401|403|unauthorized|forbidden|expired|invalid_token|authentication failed|credentials' \
        "${errfile}"
      ;;
    codex)
      grep -vE 'rmcp::|mcp-client|models_manager' "${errfile}" |
        grep -qiE 'not logged in|codex login|401 unauthorized|refresh token|token expired'
      ;;
    *) return 1 ;;
  esac
}

# --- Agent Driver: the launch ----------------------------------------------

# Throughout this file, `([0] | implode)` is jq for one NUL byte. It is written
# that way rather than as a unicode escape because the escape is invisible in a
# diff and an editor that mangled it would produce a launch that still looked
# right.
#
# Build the launch spec for one engine in one role. This is the whole of what
# Heinzel knows about agent CLIs: the subcommand, the flag order, which tools
# are withheld, which sandbox is asked for. A runtime backend must never need
# to know any of it (§7).
#
# The arguments beyond §7's sketch are the launch's real inputs: codex takes
# the working directory and an output path on its command line, and the prompt
# is an argument rather than something written to stdin.
engine_build_launch() {
  local engine=$1 role=$2 io_mode=$3 workdir=$4 promptfile=$5 outdir=$6 spec=$7
  local prompt model effort executable profile
  local -a argv

  case ${io_mode} in
    # One-shot batch is all Phase 1 runs. An unsupported mode is refused rather
    # than quietly served as batch: a caller that asked for an interactive
    # session and got a batch one would be told it succeeded.
    batch) ;;
    *) err "unsupported io mode: ${io_mode}"; return 1 ;;
  esac

  prompt=$(cat "${promptfile}") || return 1

  case ${engine} in
    claude)
      executable=claude
      model=${HEINZEL_MODEL}
      effort=${HEINZEL_EFFORT}
      argv=(-p "${prompt}"
            --output-format json
            --setting-sources user
            --settings "${HEINZEL_ROOT}/etc/heinzel-settings.json")
      if [ "${role}" = reviewer ]; then
        # The reviewer has no way to write. A classifier deciding not to write
        # is not the same guarantee as not having the tool.
        profile=review-read-only-v1
        argv+=(--permission-mode dontAsk
               --disallowedTools Write Edit NotebookEdit Bash
               --json-schema "$(cat "${HEINZEL_ROOT}/etc/review-schema.json")")
      else
        # dontAsk, not auto. auto approves whatever its classifier judges to
        # match the request, which measurably included writing outside the
        # working directory. dontAsk denies anything not pre-approved, and the
        # sandbox in the settings file substitutes for the prompt on Bash, so
        # the agent still runs arbitrary commands inside the working directory
        # while everything outside it is refused by the OS.
        # git push is deliberately NOT disallowed here since 2026-09-01: the
        # release ritual (docs/RELEASING.md) has the agent push its own work
        # and tags to origin. The settings file still denies force pushes and
        # the sandbox network allowlist limits it to github.com.
        profile=execute-workspace-write-v1
        argv+=(--permission-mode dontAsk
               --disallowedTools "Bash(sudo *)" "Bash(sudo)")
      fi
      [ -n "${model}" ] && argv+=(--model "${model}")
      [ -n "${effort}" ] && argv+=(--effort "${effort}")
      [ -n "${HEINZEL_MAX_BUDGET_USD:-}" ] &&
        argv+=(--max-budget-usd "${HEINZEL_MAX_BUDGET_USD}")
      ;;
    codex)
      executable=codex
      model=${HEINZEL_CODEX_MODEL}
      effort=${HEINZEL_CODEX_EFFORT}
      argv=(exec --skip-git-repo-check -C "${workdir}" --json
            -o "${outdir}/last.txt")
      if [ "${role}" = reviewer ]; then
        # read-only is enforced by the OS sandbox, not by the model.
        profile=review-read-only-v1
        argv+=(-s read-only --output-schema "${HEINZEL_ROOT}/etc/review-schema.json")
      else
        profile=execute-workspace-write-v1
        argv+=(-s workspace-write)
      fi
      [ -n "${model}" ] && argv+=(-m "${model}")
      [ -n "${effort}" ] && argv+=(-c "model_reasoning_effort=\"${effort}\"")
      [ "${HEINZEL_CODEX_IGNORE_USER_CONFIG}" = 1 ] && argv+=(-c "ignore_user_config=true")
      argv+=("${prompt}")
      ;;
    *)
      err "unknown engine: ${engine}"
      return 1
      ;;
  esac

  # The argv goes in NUL-delimited and comes back out NUL-delimited, which is
  # the only separator no argument can contain. Not `jq --args`: jq keeps
  # reading arguments that begin with a dash as its own options, and every
  # engine launch here starts with one. Not a hand-built JSON array either — an
  # argument may hold a newline, a quote or a backslash, since the reviewer's
  # --json-schema is a whole file, and jq is what knows how to encode all three.
  #
  # security_profile is recorded, not enforced: it names the profile these
  # flags are meant to add up to, so that a later phase's launch attestation
  # (§18.1) has something to compare them against.
  printf '%s\0' "${argv[@]}" |
  jq -Rs \
    --arg engine "${engine}" \
    --arg role "${role}" \
    --arg executable "${executable}" \
    --arg io_mode "${io_mode}" \
    --arg profile "${profile}" \
    --arg model "${model}" \
    --arg effort "${effort}" \
    '{schema_version: 1, engine: $engine, agent_kind: $engine,
      executable: $executable, role: $role,
      argv: (split(([0] | implode))[:-1]), env: {},
      io_mode: $io_mode, security_profile: $profile,
      model: $model, effort: $effort}' >"${spec}.tmp" || return 1
  mv "${spec}.tmp" "${spec}"
}

# Render a launch spec the way a shell would have to be handed it: the
# executable, then each argument, each one NUL-terminated. This is what
# HEINZEL_DRY_RUN leaves behind, and the reason it is not a command string is
# that a multi-line argument would stop being one argument.
engine_render_launch() {
  local spec=$1
  jq -j -r '.executable, ([0] | implode), (.argv[] | ., ([0] | implode))' \
    "${spec}"
}

# --- Agent Driver: the result ----------------------------------------------

# rc 124/137 come from the watchdog and mean the wall clock ran out.
engine_verdict() {
  local engine=$1 rc=$2 errfile=$3 rawfile=$4
  case ${rc} in
    124|137) printf timeout; return ;;
  esac
  if engine_is_auth_error "${engine}" "${rc}" "${errfile}"; then
    printf auth
    return
  fi
  [ "${rc}" -ne 0 ] && { printf error; return; }
  # claude reports a failed run inside a successful process exit.
  if [ "${engine}" = claude ] && [ -r "${rawfile}" ]; then
    if jq -e '.is_error == true' "${rawfile}" >/dev/null 2>&1; then
      printf error
      return
    fi
  fi
  printf ok
}

_engine_result_claude() {
  local raw=$1
  # `model` and `effort` are what we asked for; models_used is what actually
  # ran. They differ when an inherited setting overrides the request, and
  # without recording both there is no way to find that out afterwards.
  jq -c '{
    session_id: (.session_id // null),
    cost_usd: (.total_cost_usd // null),
    turns: (.num_turns // 0),
    tokens_in: (.usage.input_tokens // 0),
    tokens_out: (.usage.output_tokens // 0),
    models_used: ((.modelUsage // {}) | keys),
    text: (.result // "")
  }' "${raw}" 2>/dev/null || printf '{}'
}

_engine_result_codex() {
  local raw=$1
  # codex emits JSONL events; there is no USD figure in its telemetry.
  jq -s -c '{
    session_id: (map(.session_id // empty) | last // null),
    cost_usd: null,
    turns: 0,
    tokens_in: (map(.usage.input_tokens // empty) | last // 0),
    tokens_out: (map(.usage.output_tokens // empty) | last // 0),
    models_used: [],
    text: ""
  }' "${raw}" 2>/dev/null || printf '{}'
}

# Turn what the runtime collected into the engine-independent result. The
# engine is read from the launch spec rather than passed again, so the two
# cannot disagree about which engine produced the output being read.
engine_normalize_result() {
  local spec=$1 collected=$2 result=$3
  local engine role model effort rc duration rawfile errfile lastfile
  local parsed="" verdict

  engine=$(jq -r '.engine' "${spec}" 2>/dev/null) || return 1
  role=$(jq -r '.role' "${spec}")
  model=$(jq -r '.model // ""' "${spec}")
  effort=$(jq -r '.effort // ""' "${spec}")
  rc=$(jq -r '.exit_code' "${collected}" 2>/dev/null) || return 1
  duration=$(jq -r '.duration_sec' "${collected}")
  rawfile=$(jq -r '.stdout_path' "${collected}")
  errfile=$(jq -r '.stderr_path' "${collected}")
  lastfile=$(jq -r '.output_path' "${collected}")

  case ${engine} in
    claude)
      parsed=$(_engine_result_claude "${rawfile}")
      # claude reports its final message inside its own JSON; codex was told to
      # write it out itself. Both end up in the same file.
      printf '%s' "${parsed}" | jq -r '.text // ""' >"${lastfile}" 2>/dev/null
      ;;
    codex)
      parsed=$(_engine_result_codex "${rawfile}")
      ;;
  esac
  [ -n "${parsed}" ] || parsed='{}'

  verdict=$(engine_verdict "${engine}" "${rc}" "${errfile}" "${rawfile}")

  jq -n \
    --arg engine "${engine}" --arg role "${role}" \
    --arg model "${model}" --arg effort "${effort}" \
    --argjson exit_code "${rc}" --arg verdict "${verdict}" \
    --argjson duration_sec "${duration}" \
    --argjson parsed "${parsed}" \
    --rawfile text "${lastfile}" \
    '{engine: $engine, role: $role, model: $model, effort: $effort,
      models_used: ($parsed.models_used // []),
      exit_code: $exit_code, verdict: $verdict, duration_sec: $duration_sec,
      session_id: ($parsed.session_id // null),
      cost_usd: ($parsed.cost_usd // null),
      tokens_in: ($parsed.tokens_in // 0), tokens_out: ($parsed.tokens_out // 0),
      turns: ($parsed.turns // 0), text: $text}' >"${result}.tmp" || return 1
  mv "${result}.tmp" "${result}"
}

# --- local supervision -----------------------------------------------------
#
# Nothing below this line knows what an engine is.

# Start what a launch spec names, under the watchdog, and record what it left
# behind. Returns the process's own status; the collected record carries it too,
# because the caller of a real backend will read the file rather than $?.
_engine_collect_local() {
  local spec=$1 collected=$2 workdir=$3 outdir=$4 tmo=$5
  local executable rc started ended prev_pwd arg
  local -a cmd

  executable=$(jq -r '.executable' "${spec}" 2>/dev/null) || return 1
  case ${executable} in
    ""|null) err "launch spec names no executable"; return 1 ;;
  esac

  # Phase 1 never sets a launch environment. Refusing beats dropping it: a
  # backend that silently ignores half a launch spec is worse than one that
  # says plainly it cannot honour it (§8.1).
  if [ "$(jq -r '.env | length' "${spec}" 2>/dev/null)" != 0 ]; then
    err "the local runtime does not carry a launch environment yet"
    return 1
  fi

  # argv is restored NUL-delimited through process substitution, never split on
  # newlines and never rebuilt with eval: an argument may hold anything a byte
  # can hold except NUL itself, which is exactly why NUL is the separator. A
  # `while` at the end of a pipe would run in a subshell and the array would
  # not survive it (§8.4).
  cmd=()
  while IFS= read -r -d '' arg; do
    cmd[${#cmd[@]}]="${arg}"
  done < <(jq -j -r '.argv[] | ., ([0] | implode)' "${spec}")
  [ ${#cmd[@]} -gt 0 ] || { err "launch spec has an empty argv"; return 1; }

  started=$(now_epoch)

  # cd here rather than wrapping the command in a subshell: `( cd x && cmd ) &`
  # would make $! the subshell's pid, and killing that leaves the engine itself
  # running as an orphan. stdin is closed because codex exec treats a non-TTY
  # stdin as additional input and waits for EOF, which hangs forever under
  # launchd even when the prompt was passed as an argument.
  prev_pwd=${PWD}
  cd "${workdir}" || { err "cannot cd to ${workdir}"; return 1; }
  hzl_timeout 30 "${tmo}" "${executable}" "${cmd[@]}" \
    >"${outdir}/raw" 2>"${outdir}/stderr" </dev/null
  rc=$?
  cd "${prev_pwd}" || true

  ended=$(now_epoch)

  # Same-directory temp file and rename, so a reader never sees half a record.
  jq -n \
    --argjson exit_code "${rc}" \
    --argjson duration_sec "$((ended - started))" \
    --arg stdout_path "${outdir}/raw" \
    --arg stderr_path "${outdir}/stderr" \
    --arg output_path "${outdir}/last.txt" \
    '{schema_version: 1, exit_code: $exit_code, duration_sec: $duration_sec,
      stdout_path: $stdout_path, stderr_path: $stderr_path,
      output_path: $output_path}' >"${collected}.tmp" || return 1
  mv "${collected}.tmp" "${collected}" || return 1

  return "${rc}"
}

# --- the facade ------------------------------------------------------------

# Unchanged from the outside: same arguments, same exit status, same
# result.json. Inside, it is now Agent Driver -> supervision -> Agent Driver.
engine_run() {
  local engine=$1 role=$2 workdir=$3 promptfile=$4 outdir=$5
  local tmo=${6:-3600}
  local rc spec collected

  mkdir -p "${outdir}" || return 1
  : >"${outdir}/stderr"
  : >"${outdir}/raw"
  : >"${outdir}/last.txt"

  spec=${outdir}/launch.json
  collected=${outdir}/collected.json

  engine_build_launch "${engine}" "${role}" batch "${workdir}" \
    "${promptfile}" "${outdir}" "${spec}" || return 1

  if [ "${HEINZEL_DRY_RUN:-0}" = 1 ]; then
    engine_render_launch "${spec}" >"${outdir}/dry-run.cmd" || return 1
    jq -n --arg engine "${engine}" --arg role "${role}" \
       '{engine: $engine, role: $role, verdict: "ok", exit_code: 0,
         dry_run: true, duration_sec: 0, text: ""}' >"${outdir}/result.json"
    return 0
  fi

  _engine_collect_local "${spec}" "${collected}" "${workdir}" "${outdir}" "${tmo}"
  rc=$?

  # No collected record means supervision never got as far as running anything;
  # there is nothing to normalise, and its failure is the caller's answer.
  [ -r "${collected}" ] || return 1

  engine_normalize_result "${spec}" "${collected}" "${outdir}/result.json" ||
    return 1

  return "${rc}"
}
