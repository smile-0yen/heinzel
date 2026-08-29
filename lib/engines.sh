#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/engines.sh — the only file that knows how to start an agent CLI.
#
# The runner knows two things and no more: engine_run, and the normalised
# result.json it leaves behind. Adding an engine touches this file only.
#
# Public contract:
#
#   engine_available    <engine>                      -> 0/1
#   engine_auth_ok      <engine>                      -> 0/1
#   engine_is_auth_error <engine> <rc> <errfile>      -> 0/1
#   engine_run <engine> <role> <workdir> <promptfile> <outdir> [timeout_sec]
#
# engine_run leaves in <outdir>:
#   raw            the engine's own output (claude: JSON, codex: JSONL)
#   last.txt       the final message, in the same place for every engine
#   stderr         standard error; the input to auth-failure detection
#   result.json    the engine-independent result. Callers read only this.
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

# --- result normalisation --------------------------------------------------

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
  local raw=$1 last=$2
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

# --- running ---------------------------------------------------------------

engine_run() {
  local engine=$1 role=$2 workdir=$3 promptfile=$4 outdir=$5
  local tmo=${6:-3600}
  local rc started ended prompt model effort
  local -a cmd

  mkdir -p "${outdir}" || return 1
  : >"${outdir}/stderr"
  : >"${outdir}/raw"
  : >"${outdir}/last.txt"

  prompt=$(cat "${promptfile}") || return 1

  case ${engine}:${role} in
    claude:*)
      model=${HEINZEL_MODEL}
      effort=${HEINZEL_EFFORT}
      cmd=(claude -p "${prompt}"
           --output-format json
           --setting-sources user
           --settings "${HEINZEL_ROOT}/etc/heinzel-settings.json")
      if [ "${role}" = reviewer ]; then
        # The reviewer has no way to write. A classifier deciding not to write
        # is not the same guarantee as not having the tool.
        cmd+=(--disallowedTools Write Edit NotebookEdit Bash
              --json-schema "$(cat "${HEINZEL_ROOT}/etc/review-schema.json")")
      else
        cmd+=(--permission-mode auto
              --disallowedTools "Bash(sudo *)" "Bash(sudo)" "Bash(git push *)")
      fi
      [ -n "${model}" ] && cmd+=(--model "${model}")
      [ -n "${effort}" ] && cmd+=(--effort "${effort}")
      [ -n "${HEINZEL_MAX_BUDGET_USD:-}" ] && cmd+=(--max-budget-usd "${HEINZEL_MAX_BUDGET_USD}")
      ;;
    codex:*)
      model=${HEINZEL_CODEX_MODEL}
      effort=${HEINZEL_CODEX_EFFORT}
      cmd=(codex exec --skip-git-repo-check -C "${workdir}" --json
           -o "${outdir}/last.txt")
      if [ "${role}" = reviewer ]; then
        # read-only is enforced by the OS sandbox, not by the model.
        cmd+=(-s read-only --output-schema "${HEINZEL_ROOT}/etc/review-schema.json")
      else
        cmd+=(-s workspace-write)
      fi
      [ -n "${model}" ] && cmd+=(-m "${model}")
      [ -n "${effort}" ] && cmd+=(-c "model_reasoning_effort=\"${effort}\"")
      [ "${HEINZEL_CODEX_IGNORE_USER_CONFIG}" = 1 ] && cmd+=(-c "ignore_user_config=true")
      cmd+=("${prompt}")
      ;;
    *)
      err "unknown engine: ${engine}"
      return 1
      ;;
  esac

  if [ "${HEINZEL_DRY_RUN:-0}" = 1 ]; then
    printf '%s\0' "${cmd[@]}" >"${outdir}/dry-run.cmd"
    jq -n --arg engine "${engine}" --arg role "${role}" \
       '{engine: $engine, role: $role, verdict: "ok", exit_code: 0,
         dry_run: true, duration_sec: 0, text: ""}' >"${outdir}/result.json"
    return 0
  fi

  started=$(now_epoch)

  # cd here rather than wrapping the command in a subshell: `( cd x && cmd ) &`
  # would make $! the subshell's pid, and killing that leaves the engine itself
  # running as an orphan. stdin is closed because codex exec treats a non-TTY
  # stdin as additional input and waits for EOF, which hangs forever under
  # launchd even when the prompt was passed as an argument.
  local prev_pwd=${PWD}
  cd "${workdir}" || { err "cannot cd to ${workdir}"; return 1; }
  hzl_timeout 30 "${tmo}" "${cmd[@]}" >"${outdir}/raw" 2>"${outdir}/stderr" </dev/null
  rc=$?
  cd "${prev_pwd}" || true

  ended=$(now_epoch)

  local parsed verdict
  case ${engine} in
    claude)
      parsed=$(_engine_result_claude "${outdir}/raw")
      printf '%s' "${parsed}" | jq -r '.text // ""' >"${outdir}/last.txt" 2>/dev/null
      ;;
    codex)
      parsed=$(_engine_result_codex "${outdir}/raw" "${outdir}/last.txt")
      ;;
  esac
  [ -n "${parsed}" ] || parsed='{}'

  verdict=$(engine_verdict "${engine}" "${rc}" "${outdir}/stderr" "${outdir}/raw")

  jq -n \
    --arg engine "${engine}" --arg role "${role}" \
    --arg model "${model}" --arg effort "${effort}" \
    --argjson exit_code "${rc}" --arg verdict "${verdict}" \
    --argjson duration_sec "$((ended - started))" \
    --argjson parsed "${parsed}" \
    --rawfile text "${outdir}/last.txt" \
    '{engine: $engine, role: $role, model: $model, effort: $effort,
      models_used: ($parsed.models_used // []),
      exit_code: $exit_code, verdict: $verdict, duration_sec: $duration_sec,
      session_id: ($parsed.session_id // null),
      cost_usd: ($parsed.cost_usd // null),
      tokens_in: ($parsed.tokens_in // 0), tokens_out: ($parsed.tokens_out // 0),
      turns: ($parsed.turns // 0), text: $text}' >"${outdir}/result.json" ||
    return 1

  return "${rc}"
}
