#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/engines.sh — the Agent Driver: the only file that knows how to start an
# agent CLI.
#
# The runner knows two things and no more: engine_run, and the normalised
# result.json it leaves behind. Adding an engine touches this file only.
#
# This file knows engines and knows nothing about processes
# (docs/RUNTIME-BACKENDS.md §7). It turns an engine and a role into a launch
# spec, and a collected output back into a result. Starting anything, holding it
# to a wall clock and collecting what it wrote belongs to a runtime backend —
# lib/runtimes/local.sh today — which in turn knows nothing about engines.
#
# The launch is structured data — executable, argv array, env — never a shell
# command string, so that a runtime that is not this shell can start it
# (§7, §8.4).
#
# Public contract:
#
#   engine_available    <engine>                      -> 0/1
#   engine_auth_ok      <engine>                      -> 0/1
#   engine_is_auth_error <engine> <rc> <errfile>      -> 0/1
#   engine_build_launch <engine> <role> <io-mode> <workdir> <promptfile>
#                       <outdir> <spec.json>
#   engine_attempt_outcome        <verdict>              -> the outcome name
#   engine_normalize_result <spec.json> <collected.json> <result.json> [backend]
#   engine_run <engine> <role> <workdir> <promptfile> <outdir> [timeout_sec]
#
# and three readers, which accept a result.json from any schema this project
# has written:
#
#   engine_result_schema_version  <result.json>
#   engine_result_backend         <result.json>
#   engine_result_attempt_outcome <result.json>
#
# engine_run leaves in <outdir>:
#   raw            the engine's own output (claude: JSON, codex: JSONL)
#   last.txt       the final message, in the same place for every engine
#   stderr         standard error; the input to auth-failure detection
#   result.json    the engine-independent result. Callers read only this.
#   launch.json    the launch spec handed to the runtime backend
#   run.json       where to run it, how long to allow, where the streams go
#   collected.json what the backend observed: exit code, duration, paths
#   dry-run.cmd    with HEINZEL_DRY_RUN=1: the command, NUL-separated so that
#                  a multi-line argument stays one argument
#
# Requires lib/common.sh and lib/runtimes.sh.

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

# The attempt-level outcome, derived from the same evidence as the verdict and
# named so that it cannot be mistaken for one.
#
# `verdict: ok` has always meant "the attempt ran and its output was collected",
# and it will keep meaning that — but read at a glance it looks like a statement
# that the work was right, which no runtime is in a position to make (§8.3: the
# observation vocabulary deliberately has no `success` in it). So the same
# judgement is also written down under a name with no such reading, ready for
# the `workflow_outcome` that Phase 4 puts beside it (§9.3, §13.7). There is no
# value here that means the task was done.
#
# The vocabulary is COLLECTED, TIMED_OUT, AUTH_FAILED, FAILED and UNKNOWN, plus
# NOT_STARTED for a dry run — which this mapping never produces, because a dry
# run has no verdict to map from and engine_run writes that one itself.
engine_attempt_outcome() {
  case $1 in
    ok) printf COLLECTED ;;
    timeout) printf TIMED_OUT ;;
    auth) printf AUTH_FAILED ;;
    error) printf FAILED ;;
    *) printf UNKNOWN ;;
  esac
}

# --- reading a result, of either schema ------------------------------------
#
# A result.json written before v2 has none of the three new fields. It is read
# as v1, as having run on `local` — the only backend that existed when it was
# written — and as an outcome derived from the verdict it does have. None of
# these open the file for writing: an old record is read where it lies (§13.7).

engine_result_schema_version() {
  local v
  v=$(jq -r '.schema_version // 1' "$1" 2>/dev/null)
  case ${v} in
    ""|*[!0-9]*) printf 1 ;;
    *) printf '%s' "${v}" ;;
  esac
}

engine_result_backend() {
  local v
  v=$(jq -r '.backend // "local"' "$1" 2>/dev/null)
  [ -n "${v}" ] && [ "${v}" != null ] || v=local
  printf '%s' "${v}"
}

engine_result_attempt_outcome() {
  local v
  v=$(jq -r '.attempt_outcome // ""' "$1" 2>/dev/null)
  if [ -n "${v}" ] && [ "${v}" != null ]; then
    printf '%s' "${v}"
    return 0
  fi
  engine_attempt_outcome "$(jq -r '.verdict // ""' "$1" 2>/dev/null)"
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
# cannot disagree about which engine produced the output being read. The
# backend is the one argument that cannot be read back out of either file: it
# is the caller's choice of where this ran, and it defaults to `local` for the
# three-argument callers that predate the field.
engine_normalize_result() {
  local spec=$1 collected=$2 result=$3 backend=${4:-local}
  local engine role model effort rc duration rawfile errfile lastfile
  local parsed="" verdict outcome native

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
  outcome=$(engine_attempt_outcome "${verdict}")

  # 124, 137 and 125 are Heinzel's own codes, not the command's (SPEC §9.3):
  # the watchdog ended it, or refused to start it. `exit_code` keeps carrying
  # them because a decade of readers expect a number there, and
  # `native_exit_code` says plainly that the process's own status is not known.
  # The same field is null for a backend whose agent settles without a process
  # exit at all, which is the case it exists for (§13.7).
  case ${rc} in
    124|137|125) native=null ;;
    *) native=${rc} ;;
  esac

  # v2. Every v1 field is still here, in the same place, with the same meaning:
  # the four additions are additions, and a reader that knows only v1 cannot
  # tell the difference (§13.7).
  #
  # `runtime_state` is `EXITED` for every batch run, whatever the backend: the
  # batch contract is run-to-completion, so a collected record existing at all
  # is the observation that the process terminated. The states that are not
  # `EXITED` — `SETTLED`, `LOST`, `UNREACHABLE` (§9.1) — belong to an agent that
  # outlives the call that started it, and arrive with the backend that has one.
  jq -n \
    --argjson schema_version "${HEINZEL_RESULT_SCHEMA}" \
    --arg backend "${backend}" \
    --arg engine "${engine}" --arg role "${role}" \
    --arg model "${model}" --arg effort "${effort}" \
    --argjson exit_code "${rc}" --arg verdict "${verdict}" \
    --argjson native_exit_code "${native}" \
    --arg attempt_outcome "${outcome}" \
    --argjson duration_sec "${duration}" \
    --argjson parsed "${parsed}" \
    --rawfile text "${lastfile}" \
    '{schema_version: $schema_version,
      engine: $engine, role: $role, model: $model, effort: $effort,
      models_used: ($parsed.models_used // []),
      exit_code: $exit_code, verdict: $verdict, duration_sec: $duration_sec,
      session_id: ($parsed.session_id // null),
      cost_usd: ($parsed.cost_usd // null),
      tokens_in: ($parsed.tokens_in // 0), tokens_out: ($parsed.tokens_out // 0),
      turns: ($parsed.turns // 0), text: $text,
      backend: $backend, runtime_state: "EXITED",
      native_exit_code: $native_exit_code,
      attempt_outcome: $attempt_outcome}' >"${result}.tmp" || return 1
  mv "${result}.tmp" "${result}"
}

# --- the facade ------------------------------------------------------------

# Unchanged from the outside: same arguments, same exit status, same
# result.json. Inside, it is Agent Driver -> runtime backend -> Agent Driver.
#
# The backend is named by a string. There is one, `local`, and a misspelling is
# refused by the registry rather than quietly served by it. Which one it is is
# `runtime_selected`'s answer — the session's, not this process's environment.
engine_run() {
  local engine=$1 role=$2 workdir=$3 promptfile=$4 outdir=$5
  local tmo=${6:-3600}
  local rc spec run collected backend
  backend=$(runtime_selected)

  mkdir -p "${outdir}" || return 1
  : >"${outdir}/stderr"
  : >"${outdir}/raw"
  : >"${outdir}/last.txt"

  # These two are removed rather than truncated. An outdir can be reused, and a
  # launch that fails before the backend writes anything would otherwise leave
  # the previous run's collected.json in place to be normalised into this run's
  # result.json — a success that nobody ran. Absent is the honest state.
  rm -f "${outdir}/collected.json" "${outdir}/result.json"

  spec=${outdir}/launch.json
  run=${outdir}/run.json
  collected=${outdir}/collected.json

  engine_build_launch "${engine}" "${role}" batch "${workdir}" \
    "${promptfile}" "${outdir}" "${spec}" || return 1

  if [ "${HEINZEL_DRY_RUN:-0}" = 1 ]; then
    engine_render_launch "${spec}" >"${outdir}/dry-run.cmd" || return 1
    # A dry run is a result.json of the same schema saying that nothing ran.
    # The v1 fields keep the shape a reader expects — `verdict: ok`, exit 0 —
    # and the v2 ones refuse to pretend: no process, so no native status, no
    # runtime state anyone observed, and nothing collected.
    jq -n --arg engine "${engine}" --arg role "${role}" \
       --argjson schema_version "${HEINZEL_RESULT_SCHEMA}" \
       --arg backend "${backend}" \
       '{schema_version: $schema_version,
         engine: $engine, role: $role, verdict: "ok", exit_code: 0,
         dry_run: true, duration_sec: 0, text: "",
         backend: $backend, runtime_state: "UNKNOWN",
         native_exit_code: null, attempt_outcome: "NOT_STARTED"}' \
       >"${outdir}/result.json"
    return 0
  fi

  # Where to run it, how long to allow, and where the three streams go. The
  # backend is told; it does not go looking in an output directory it was never
  # given the layout of.
  jq -n \
    --arg cwd "${workdir}" \
    --argjson timeout_sec "${tmo}" \
    --arg stdout_path "${outdir}/raw" \
    --arg stderr_path "${outdir}/stderr" \
    --arg output_path "${outdir}/last.txt" \
    '{schema_version: 1, cwd: $cwd, timeout_sec: $timeout_sec,
      kill_after_sec: 30, stdout_path: $stdout_path,
      stderr_path: $stderr_path, output_path: $output_path}' \
    >"${run}.tmp" || return 1
  mv "${run}.tmp" "${run}" || return 1

  runtime_run_batch "${backend}" "${spec}" "${run}" "${collected}"
  rc=$?

  # No collected record means the backend never got as far as running anything;
  # there is nothing to normalise, and its failure is the caller's answer.
  [ -r "${collected}" ] || return 1

  engine_normalize_result "${spec}" "${collected}" "${outdir}/result.json" \
    "${backend}" || return 1

  return "${rc}"
}
