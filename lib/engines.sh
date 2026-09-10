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
#   raw            the engine's own output, in the engine's own format, which
#                  depends on the role as well as the engine: JSONL for the
#                  claude executor, codex and opencode, one JSON object for the
#                  claude reviewer. Nothing outside this file parses it.
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
    opencode)
      # A provider may be authenticated by OpenCode's credential store or by
      # its environment, and an empty model means OpenCode chooses the provider
      # too. There is no offline yes/no probe that covers those combinations.
      # The launch's structured error stream is classified below instead.
      return 0
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
    opencode)
      grep -qiE 'unauthorized|forbidden|authentication|not authenticated|invalid api key|api key.*(missing|invalid)|credentials.*(missing|invalid)' \
        "${errfile}"
      ;;
    *) return 1 ;;
  esac
}

# --- usage: how much of the account's limit is left ------------------------
#
# Asked of each CLI the way a person asks it, so that Heinzel never holds a key
# or names a provider's host: `claude -p /usage` prints the same lines as the
# interactive /usage, and the codex app-server's account/rateLimits/read is the
# call behind the interactive /status. `codex exec /status` is not: exec hands
# the text to the model as a prompt, and that spends a turn to say nothing.
#
#   engine_usage <engine> -> one line per limit: label TAB used-percent TAB resets
#
# Exit 0 with at least one line, 1 when the CLI answered with no limits (its
# first line of output goes to stderr, as the reason), 2 for an engine that
# has no such question.

ENGINE_USAGE_TIMEOUT=30

engine_usage() {
  case $1 in
    claude) _engine_usage_claude ;;
    codex) _engine_usage_codex ;;
    *) return 2 ;;
  esac
}

# "Current session: 5% used · resets Sep 11 at 2:19am (Asia/Tokyo)"
# The separator before "resets" is matched loosely: it is a middle dot today
# and nothing here depends on which character it is.
_engine_usage_claude() {
  local out lines
  out=$(hzl_timeout 5 "${ENGINE_USAGE_TIMEOUT}" claude -p /usage 2>&1)
  lines=$(printf '%s\n' "${out}" |
    sed -nE 's/^Current ([^:]+): ([0-9]+)% used(.*resets (.*))?$/\1	\2	\4/p')
  if [ -z "${lines}" ]; then
    printf '%s\n' "${out}" | grep -m1 . >&2
    return 1
  fi
  printf '%s\n' "${lines}"
}

# The app-server exits on end of input without answering what it has already
# read, so the request side stays open until the answer is in, and no longer.
# Reading the file the other end of the pipe writes is the point (SC2094).
# shellcheck disable=SC2094
_engine_usage_codex_ask() { # outfile
  local out=$1 i=0
  {
    printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"heinzel","version":"'"${HEINZEL_VERSION}"'"}}}' \
      '{"jsonrpc":"2.0","method":"initialized"}' \
      '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}'
    while [ "${i}" -lt $((ENGINE_USAGE_TIMEOUT * 5)) ] &&
      ! grep -q '"id":2[,}]' "${out}" 2>/dev/null; do
      sleep 0.2
      i=$((i + 1))
    done
  } | codex app-server >"${out}" 2>/dev/null
}

_engine_usage_codex() {
  local out rows label used at
  out=$(mktemp "${TMPDIR:-/tmp}/hzl-usage.XXXXXX") || return 1
  hzl_timeout 5 $((ENGINE_USAGE_TIMEOUT + 5)) _engine_usage_codex_ask "${out}"
  # One bucket per limit_id; the account-wide `codex` bucket first. A window
  # is named by its length, which is what the interactive /status does too.
  rows=$(jq -r '
    def win: if . == null then "window"
      elif . == 10080 then "week"
      elif . % 1440 == 0 then "\(. / 1440)d"
      elif . % 60 == 0 then "\(. / 60)h"
      else "\(.)m" end;
    select(.id == 2) | .result // empty
    | (.rateLimitsByLimitId // {codex: .rateLimits}) | [.[]]
    | sort_by(.limitId != "codex") | .[]
    | (.limitName // "all models") as $n
    | (.primary, .secondary) | select(. != null)
    | [(.windowDurationMins | win) + " (" + $n + ")",
       (.usedPercent | tostring), (.resetsAt // "" | tostring)]
    | @tsv' "${out}" 2>/dev/null)
  if [ -z "${rows}" ]; then
    jq -r 'select(.id == 2) | .error.message // empty' "${out}" 2>/dev/null |
      grep -m1 . >&2 || printf 'codex app-server did not answer\n' >&2
    rm -f "${out}"
    return 1
  fi
  rm -f "${out}"
  while IFS='	' read -r label used at; do
    [ -n "${at}" ] && at=$(short_at "${at}")
    printf '%s\t%s\t%s\n' "${label}" "${used}" "${at}"
  done <<EOF
${rows}
EOF
}

# OpenCode reads permissions from its ordinary config, including project files
# in the worktree. Heinzel therefore adds a uniquely named agent in the inline
# config, which is loaded after project config, and launches that agent by
# name. Its rules are last and cannot be relaxed by an opencode.json the agent
# can edit during a self-hosted run.
#
# The generated Claude settings remain the source of truth for path and shell
# denials. Translating them here means `hzl install`, the runner's stale-file
# check and `hzl doctor` keep describing the protection every engine receives.
_engine_opencode_rule_map() { # settings.json Read|Edit|Bash default-action
  local settings=$1 tool=$2 default_action=$3
  jq -c --arg tool "${tool}" --arg default "${default_action}" '
    reduce ((.permissions.deny // [])[]
      | select(startswith($tool + "(") and endswith(")"))
      | .[($tool | length) + 1:-1]
      # Claude carries both current Bash wildcard spellings. OpenCode uses the
      # space form, so discard the duplicate colon form.
      | select(($tool != "Bash") or (endswith(":*") | not))
      # A Claude absolute path begins //; OpenCode takes an ordinary absolute
      # path. Leave ~/ patterns as they are: both expand them.
      | if ($tool != "Bash") and startswith("//") then .[1:] else . end
    ) as $pattern ({"*": $default}; .[$pattern] = "deny")' "${settings}"
}

_engine_opencode_config() { # role -> inline opencode config on stdout
  local role=$1 settings="${HEINZEL_ROOT}/etc/heinzel-settings.json"
  local read_rules edit_rules bash_rules permission agent

  [ -r "${settings}" ] || {
    err "missing ${settings} - cannot build the opencode permission profile"
    return 1
  }
  jq -e . "${settings}" >/dev/null 2>&1 || {
    err "${settings} is not valid JSON - cannot build the opencode permission profile"
    return 1
  }

  read_rules=$(_engine_opencode_rule_map "${settings}" Read allow) || return 1
  # OpenCode's own provider config and credential record are read by the CLI,
  # not through an agent tool. Deny the model a second route to the same keys.
  read_rules=$(printf '%s' "${read_rules}" | jq -c '
    .["~/.config/opencode/**"] = "deny"
    | .["~/.local/share/opencode/auth.json"] = "deny"') || return 1

  if [ "${role}" = reviewer ]; then
    agent=heinzel-reviewer
    permission=$(jq -cn --argjson read "${read_rules}" '
      {"*":"deny", read:$read, glob:"allow", grep:"allow", list:"allow",
       lsp:"deny", webfetch:"deny", websearch:"deny",
       edit:"deny", bash:"deny", task:"deny", skill:"deny",
       external_directory:"deny", question:"deny", doom_loop:"deny",
       plan_enter:"deny", plan_exit:"deny"}') || return 1
  else
    agent=heinzel-executor
    edit_rules=$(_engine_opencode_rule_map "${settings}" Edit allow) || return 1
    edit_rules=$(printf '%s' "${edit_rules}" | jq -c '
      .["~/.config/opencode/**"] = "deny"
      | .["~/.local/share/opencode/**"] = "deny"') || return 1
    bash_rules=$(_engine_opencode_rule_map "${settings}" Bash allow) || return 1
    permission=$(jq -cn \
      --argjson read "${read_rules}" \
      --argjson edit "${edit_rules}" \
      --argjson bash "${bash_rules}" '
      {"*":"deny", read:$read, edit:$edit, bash:$bash,
       glob:"allow", grep:"allow", list:"allow", lsp:"deny",
       todowrite:"allow", webfetch:"deny", websearch:"deny", skill:"allow",
       task:"deny", external_directory:"deny", question:"deny",
       doom_loop:"deny", plan_enter:"deny", plan_exit:"deny"}') || return 1
  fi

  jq -cn --arg agent "${agent}" --argjson permission "${permission}" '
    {"$schema":"https://opencode.ai/config.json", share:"disabled",
     agent:{($agent):{
       description:"Heinzel unattended agent",
       mode:"primary",
       permission:$permission
     }}}' || return 1
}

# --- Agent Driver: the launch ----------------------------------------------

# Model choice belongs to a role, not to an executable. The legacy settings
# remain the fallback for callers and configurations written before v0.5.0.
_engine_role_model() { # engine role
  engine_role_model "$1" "$2"
}

_engine_role_effort() { # engine role
  engine_role_effort "$1" "$2"
}

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
  local prompt model effort executable profile opencode_config opencode_agent
  local -a argv format

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
      model=$(_engine_role_model "${engine}" "${role}")
      effort=$(_engine_role_effort "${engine}" "${role}")
      # The executor streams, so that a person can watch a run that is still
      # going: `stream-json` writes one event per line as it happens, and
      # `raw` becomes a file `tail -f` has something to say about, instead of
      # one JSON object that appears whole when it is already too late to
      # watch (docs/RUNBOOK.md, "Watching a run that is still going").
      # `--verbose` is not optional decoration: the CLI refuses
      # `--output-format stream-json` under `-p` without it.
      #
      # The executor and nothing else. Named rather than written as "not the
      # reviewer", because the roles are not two: `fixer` (§9.2, the one-shot
      # repair pass under `HEINZEL_REVIEW_ON_REVISE=fix-once`) is neither, and
      # under the negative form it would have started streaming as a side
      # effect of a change nobody made for it. A role added later joins the
      # `json` side too, which is the half where an unexamined format is
      # merely dull to watch rather than a surprise.
      #
      # The reviewer stays on the single-object `json` form for a reason of
      # its own. Whether `--json-schema` survives being combined with
      # `stream-json` is not known here, and a reviewer whose schema was
      # quietly dropped would return prose where the runner parses a verdict —
      # a worse failure than a review nobody can watch. Deciding it needs a
      # live reviewer run (docs/VERIFICATION.md), not a guess.
      if [ "${role}" = executor ]; then
        format=(--output-format stream-json --verbose)
      else
        format=(--output-format json)
      fi
      argv=(-p "${prompt}"
            "${format[@]}"
            --setting-sources user
            --settings "${HEINZEL_ROOT}/etc/heinzel-settings.json")
      if [ "${role}" = reviewer ] || [ "${role}" = planner ]; then
        # Read-only roles have no way to write. A classifier deciding not to
        # write is not the same guarantee as not having the tool.
        if [ "${role}" = planner ]; then
          profile=plan-read-only-v1
        else
          profile=review-read-only-v1
        fi
        argv+=(--permission-mode dontAsk
               --disallowedTools Write Edit NotebookEdit Bash)
        if [ "${role}" = reviewer ]; then
          argv+=(--json-schema "$(cat "${HEINZEL_ROOT}/etc/review-schema.json")")
        fi
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
      model=$(_engine_role_model "${engine}" "${role}")
      effort=$(_engine_role_effort "${engine}" "${role}")
      argv=(exec --skip-git-repo-check -C "${workdir}" --json
            -o "${outdir}/last.txt")
      if [ "${role}" = reviewer ] || [ "${role}" = planner ]; then
        # read-only is enforced by the OS sandbox, not by the model.
        if [ "${role}" = planner ]; then
          profile=plan-read-only-v1
          argv+=(-s read-only)
        else
          profile=review-read-only-v1
          argv+=(-s read-only --output-schema "${HEINZEL_ROOT}/etc/review-schema.json")
        fi
      else
        profile=execute-workspace-write-v1
        argv+=(-s workspace-write)
      fi
      [ -n "${model}" ] && argv+=(-m "${model}")
      [ -n "${effort}" ] && argv+=(-c "model_reasoning_effort=\"${effort}\"")
      [ "${HEINZEL_CODEX_IGNORE_USER_CONFIG}" = 1 ] && argv+=(-c "ignore_user_config=true")
      argv+=("${prompt}")
      ;;
    opencode)
      executable=opencode
      model=$(_engine_role_model "${engine}" "${role}")
      effort=$(_engine_role_effort "${engine}" "${role}")
      opencode_config=$(_engine_opencode_config "${role}") || return 1
      if [ "${role}" = reviewer ]; then
        profile=review-read-only-v1
        opencode_agent=heinzel-reviewer
      else
        profile=execute-workspace-write-v1
        opencode_agent=heinzel-executor
      fi
      # --pure disables external plugins, whose code runs in the OpenCode
      # process rather than through a permission-gated tool. `run` rejects
      # permission prompts in non-interactive mode; every capability needed by
      # the selected agent is therefore stated explicitly in the inline config.
      argv=(--pure run --dir "${workdir}" --format json
            --agent "${opencode_agent}")
      [ -n "${model}" ] && argv+=(--model "${model}")
      [ -n "${effort}" ] && argv+=(--variant "${effort}")
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
    --arg opencode_config "${opencode_config:-}" \
    '{schema_version: 1, engine: $engine, agent_kind: $engine,
      executable: $executable, role: $role,
      argv: (split(([0] | implode))[:-1]),
      env: (if $engine == "opencode" then {
        OPENCODE_CONFIG_CONTENT: $opencode_config,
        OPENCODE_DISABLE_AUTOUPDATE: "true",
        OPENCODE_DISABLE_LSP_DOWNLOAD: "true",
        OPENCODE_AUTO_SHARE: "false"
      } else {} end),
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

# claude's `raw` has two shapes, because its two roles are launched with two
# output formats: the reviewer's `json` is one object, the executor's
# `stream-json` is one object per line. Both end in the same object — the one
# the CLI marks `"type": "result"` — and it is the only one anything here
# reads. So there is one reader for both, and no caller has to know which role
# wrote the file it is holding.
#
# Twice, because the two readings fail on different files and neither alone is
# enough:
#
#   -s   jq's own parser over the whole file. It reads one object however many
#        lines it is pretty-printed across, and a JSONL file as the sequence of
#        objects it is. Right for every file that was written to the end.
#   -Rs  line by line, dropping with `fromjson?` whatever will not parse. This
#        is for the file that is still being written, or was cut off at the
#        deadline: one half-written last line makes the first reading reject
#        the *whole* input, losing the hundred complete events before it.
#
# The fallbacks within each are ordered by how much is known: the result object
# if there is one, else the last object that parsed — which is what reads the
# reviewer's single object, and what leaves an interrupted stream naming the
# session it got as far as. Nothing at all reads as nothing, not as an object
# of defaults: an empty, absent or unreadable file must stay distinguishable
# from a run that reported zeroes.
_engine_claude_result_json() {
  local raw=$1 out
  out=$(jq -s -c '(map(select(.type? == "result")) | last) // last // empty' \
        "${raw}" 2>/dev/null)
  [ -n "${out}" ] || out=$(jq -R -s -c '
    [splits("\n") | select(length > 0) | fromjson?]
    | (map(select(.type? == "result")) | last) // last // empty' \
    "${raw}" 2>/dev/null)
  printf '%s' "${out}"
}

# OpenCode emits one JSON object per line. Read it line by line so a watchdog
# cut in the middle of the final write does not discard all complete events
# before it.
_engine_opencode_events() {
  jq -R -s -c '[splits("\n") | select(length > 0) | fromjson?]' \
    "$1" 2>/dev/null || printf '[]'
}

_engine_opencode_has_error() {
  _engine_opencode_events "$1" |
    jq -e 'any(.[]; .type == "error")' >/dev/null 2>&1
}

_engine_opencode_has_auth_error() {
  _engine_opencode_events "$1" |
    jq -e '
      [.[] | select(.type == "error") | (.error // .)]
      | any(.[]; tostring
          | test("auth|unauthorized|forbidden|api[ _-]?key|credential|token expired"; "i"))' \
      >/dev/null 2>&1
}

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
  if [ "${engine}" = opencode ] && [ -r "${rawfile}" ]; then
    if [ "${rc}" -ne 0 ] && _engine_opencode_has_auth_error "${rawfile}"; then
      printf auth
      return
    fi
    # The current CLI sets a non-zero process status for an error event. Keep
    # the event check as well: it is the engine's structured statement, and a
    # future CLI must not turn one into a collected success by changing only
    # its process-exit convention.
    if _engine_opencode_has_error "${rawfile}"; then
      printf error
      return
    fi
  fi
  [ "${rc}" -ne 0 ] && { printf error; return; }
  # claude reports a failed run inside a successful process exit, in the same
  # result object the telemetry is read from. Reading the file rather than its
  # last line matters now that the executor streams: the run's own `is_error`
  # is the one on that object, and a stream is a hundred events that are not
  # it.
  if [ "${engine}" = claude ] && [ -r "${rawfile}" ]; then
    if _engine_claude_result_json "${rawfile}" |
       jq -e '.is_error == true' >/dev/null 2>&1; then
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
  local raw=$1 final
  # Every figure below comes from the one result object, whichever shape the
  # file has. A stream that ended without one — killed at the deadline, or
  # still being written — falls back to the last event that parsed, and the
  # defaults then say plainly what that event did not carry: no cost, no
  # turns, no text.
  final=$(_engine_claude_result_json "${raw}")
  # Nothing parsed at all: an empty, absent or unreadable file. Report nothing
  # rather than a shape full of defaults, so the caller's own default applies
  # and `last.txt` is left empty instead of holding the newline an empty
  # message still renders as.
  [ -n "${final}" ] || return 0
  # `model` and `effort` are what we asked for; models_used is what actually
  # ran. They differ when an inherited setting overrides the request, and
  # without recording both there is no way to find that out afterwards.
  printf '%s' "${final}" | jq -c '{
    session_id: (.session_id // null),
    cost_usd: (.total_cost_usd // null),
    turns: (.num_turns // 0),
    tokens_in: (.usage.input_tokens // 0),
    tokens_out: (.usage.output_tokens // 0),
    models_used: ((.modelUsage // {}) | keys),
    text: (.result // "")
  }' 2>/dev/null || printf '{}'
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

_engine_result_opencode() {
  local raw=$1
  _engine_opencode_events "${raw}" | jq -c '
    . as $events
    | [$events[] | select(.type == "step_finish") | .part] as $steps
    | {
        session_id: ([$events[] | .sessionID // empty] | last // null),
        cost_usd: (if ($steps | length) == 0 then null
                   else ([$steps[] | .cost // 0] | add) end),
        turns: ($steps | length),
        tokens_in: ([$steps[] | .tokens.input // 0] | add // 0),
        tokens_out: ([$steps[] | .tokens.output // 0] | add // 0),
        models_used: [],
        text: ([$events[] | select(.type == "text") | .part.text // empty]
               | last // "")
      }' 2>/dev/null || printf '{}'
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
      #
      # A message that exists is written with the trailing newline a text file
      # ends in; no message writes no file. Not `jq -r`, which would end an
      # absent message with a newline too, and leave `text` as "\n" — a run
      # cut off before it said anything would then be recorded as having said
      # one blank line, which is not the same thing as having said nothing.
      printf '%s' "${parsed}" |
        jq -j '(.text // "") | if . == "" then . else . + "\n" end' \
        >"${lastfile}" 2>/dev/null
      ;;
    codex)
      parsed=$(_engine_result_codex "${rawfile}")
      ;;
    opencode)
      parsed=$(_engine_result_opencode "${rawfile}")
      # Unlike codex, OpenCode has no output-file flag. Put its final completed
      # text part in the common location before the engine-independent record
      # is assembled.
      printf '%s' "${parsed}" |
        jq -j '(.text // "") | if . == "" then . else . + "\n" end' \
        >"${lastfile}" 2>/dev/null
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
