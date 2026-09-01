#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# tests/test.sh — the regression suite: the backlog ledger, the worksheet, and
# the engine layer.
#
# One entry point (DESIGN §7): CI runs this file and nothing else. Everything
# here is pure shell against fixture files in a temp directory — no real engine
# is called, no network is touched, and HEINZEL_HOME is redirected before
# lib/common.sh is sourced, so a test run cannot see, let alone write, the real
# ~/.heinzel. The engine tests run against a stand-in `claude` / `codex` on a
# temporary PATH, so they are free and work offline.
#
# Stock /bin/bash 3.2: no associative arrays, no `mapfile`, no `${var^^}`.

set -uo pipefail

# CONTRIBUTING.md documents `--live` as the flag that additionally exercises the
# reviewer engine. The engine tests below use a fake engine and never call a
# real one, so the flag is still refused rather than accepted and ignored: a
# contributor who ran it and saw a green suite would believe the reviewer had
# been exercised.
while [ $# -gt 0 ]; do
  case $1 in
    --live)
      printf 'tests/test.sh: --live is not implemented yet (the engine tests use a fake engine)\n' >&2
      exit 2
      ;;
    *)
      printf 'tests/test.sh: unknown option %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

TEST_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HEINZEL_ROOT=${TEST_ROOT}
export HEINZEL_ROOT

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/hzl-test.XXXXXX") || exit 1
trap 'rm -rf "${TMPROOT}"' EXIT

# Set before sourcing, not after: every state path in common.sh is derived from
# HEINZEL_HOME at source time, so a suite that redirected it afterwards would
# still be pointing at the live install.
HEINZEL_HOME=${TMPROOT}/home
export HEINZEL_HOME
mkdir -p "${HEINZEL_HOME}"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/common.sh
. "${TEST_ROOT}/lib/common.sh"
# shellcheck source=../lib/runstore.sh
. "${TEST_ROOT}/lib/runstore.sh"

# Read back what common.sh actually resolved, through `:-` so that a state path
# it failed to define reads as empty and is refused rather than skipped. If
# either is not in the temp tree the suite stops, instead of running one
# assertion against a real installation.
case ${HEINZEL_HOME:-} in
  "${TMPROOT}"/*) ;;
  *)
    printf 'refusing to run: HEINZEL_HOME resolved to %s, not under %s\n' \
      "${HEINZEL_HOME:-}" "${TMPROOT}" >&2
    exit 1
    ;;
esac
case ${STATE_FILE:-} in
  "${TMPROOT}"/*) ;;
  *)
    printf 'refusing to run: STATE_FILE resolved to %s, not under %s\n' \
      "${STATE_FILE:-}" "${TMPROOT}" >&2
    exit 1
    ;;
esac

# --- assertions ------------------------------------------------------------

PASS=0
FAIL=0

group() { printf '\n%s\n' "$1"; }

t_eq() { # name expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"
  fi
}

t_ok() { # name status (0 passes)
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected success, got status %s\n' "$1" "$2"
  fi
}

t_fails() { # name status (non-zero passes)
  if [ "$2" -ne 0 ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected failure, got status 0\n' "$1"
  fi
}

t_has() { # name file fixed-string
  if grep -qF -- "$3" "$2"; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       %s does not contain: %s\n' "$1" "$2" "$3"
  fi
}

t_lacks() { # name file fixed-string
  if grep -qF -- "$3" "$2"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       %s unexpectedly contains: %s\n' "$1" "$2" "$3"
  else
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
  fi
}

# Line number of the first line containing a fixed string; 0 when absent, so a
# missing line fails an ordering assertion instead of erroring out of it.
line_of() {
  local n
  n=$(grep -nF -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1)
  case ${n} in
    ""|*[!0-9]*) printf 0 ;;
    *) printf '%s' "${n}" ;;
  esac
}

printf 'tests/test.sh — heinzel %s, bash %s\n' \
  "${HEINZEL_VERSION:-unknown}" "${BASH_VERSION}"

# --- backlog_scan: the TSV contract ----------------------------------------
#
# Every other function in this file is derived from these five fields, so the
# shape of a row is asserted directly. The row that matters is the one with no
# id: reading the TSV with `IFS=<tab> read` collapses its empty field, the text
# arrives in the id column, and the merge then discards a new task as out of
# scope while reporting a plausible-looking count. DESIGN §6.3, SPEC §8.1.

group 'backlog_scan'

SCAN_LEDGER=${TMPROOT}/scan.md
cat >"${SCAN_LEDGER}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) a task with an id
- [ ] a task the agent split off, with no id yet
FIXTURE

SCAN_ROW=$(backlog_scan "${SCAN_LEDGER}" | sed -n 2p)
t_eq "a row has five fields" \
  5 "$(printf '%s\n' "${SCAN_ROW}" | awk -F'\t' '{print NF}')"
t_eq "an id-less row keeps an empty id field rather than shifting left" \
  "" "$(printf '%s' "${SCAN_ROW}" | cut -f4)"
t_eq "an id-less row keeps its text in field 5" \
  "a task the agent split off, with no id yet" \
  "$(printf '%s' "${SCAN_ROW}" | cut -f5)"

# --- backlog_assign_ids ----------------------------------------------------

group 'backlog_assign_ids'

IDS_LEDGER=${TMPROOT}/assign-ids.md
cat >"${IDS_LEDGER}" <<'FIXTURE'
# Backlog

Tasks are written like this:

```
## P1
- [ ] an example, inside a fence, which is documentation and not work
```

## P1
- [ ] a real task with no id yet
- [ ] (id:h-0007) a task that already has one
FIXTURE

backlog_assign_ids "${IDS_LEDGER}"
t_ok "backlog_assign_ids succeeds" "$?"
t_has "an id-less task is numbered from the highest id in use" \
  "${IDS_LEDGER}" '- [ ] (id:h-0008) a real task with no id yet'
t_has "a fenced example is left exactly as written" \
  "${IDS_LEDGER}" '- [ ] an example, inside a fence, which is documentation and not work'
t_eq "exactly two ids exist afterwards" \
  2 "$(grep -cF '(id:h-' "${IDS_LEDGER}")"

# --- worksheet_write -------------------------------------------------------

group 'worksheet_write'

WS_LEDGER=${TMPROOT}/ws-ledger.md
cat >"${WS_LEDGER}" <<'FIXTURE'
# Backlog

Tasks are written like this:

```
## P1
- [ ] (id:h-0099) an example, inside a fence, which is not work
```

## P1
- [ ] (id:h-0001) the first task
      note: a continuation line the agent needs
- [x] (id:h-0002) already closed <!-- done:2026-08-30T01:00:00+09:00 run:20260830-010000 -->

## P2
- [ ] (id:h-0003) a second-priority task

## P3
- [ ] (id:h-0004) a third-priority task
FIXTURE

WS_OUT=${TMPROOT}/worksheet.md
WS_IDS=$(worksheet_write "${WS_LEDGER}" 2 "${WS_OUT}" | tr '\n' ' ' | sed 's/ *$//')
t_eq "the id list carries only this run's ids, in ledger order" \
  "h-0001 h-0003" "${WS_IDS}"
t_has "the task text is carried across" \
  "${WS_OUT}" '- [ ] (id:h-0001) the first task'
t_has "continuation lines are carried across verbatim" \
  "${WS_OUT}" '      note: a continuation line the agent needs'
t_lacks "a fenced example never reaches the worksheet" \
  "${WS_OUT}" 'h-0099'
t_lacks "a closed task never reaches the worksheet" \
  "${WS_OUT}" 'h-0002'
t_lacks "a task beyond this run's budget is left in the ledger" \
  "${WS_OUT}" 'h-0004'
t_has "the priority heading of a carried task comes with it" "${WS_OUT}" '## P1'
t_has "so does the second one" "${WS_OUT}" '## P2'
t_lacks "a priority with no carried task gets no heading" "${WS_OUT}" '## P3'

worksheet_write "${WS_LEDGER}" 0 "${TMPROOT}/never.md" >/dev/null 2>&1
t_fails "a budget of zero is refused" "$?"

WS_EMPTY=${TMPROOT}/ws-empty.md
cat >"${WS_EMPTY}" <<'FIXTURE'
# Backlog

## P1
- [x] (id:h-0001) everything here is finished <!-- done:2026-08-30T01:00+09:00 -->
FIXTURE
worksheet_write "${WS_EMPTY}" 3 "${TMPROOT}/never.md" >/dev/null 2>&1
t_fails "a ledger with nothing to do is refused" "$?"

# --- worksheet_merge -------------------------------------------------------
#
# The four counts are a contract: bin/hzl-run splits this line with `cut -d' '`
# and logs `N worksheet line(s) ignored` from the fourth field. Asserting the
# resulting ledger alone would let the counts drift out from under the runner.

group 'worksheet_merge'

MG_RUN=20260901-030005
MG_LEDGER=${TMPROOT}/merge-ledger.md
MG_WS=${TMPROOT}/merge-worksheet.md
MG_IDS=${TMPROOT}/merge-ids.txt

cat >"${MG_LEDGER}" <<'FIXTURE'
# Backlog

## P1
- [~] (id:h-0001) close me <!-- run:20260901-030005 -->
- [~] (id:h-0002) block me <!-- run:20260901-030005 -->
- [~] (id:h-0003) leave me untouched <!-- run:20260901-030005 -->
      note: a note that must stay with h-0003
- [ ] (id:h-0004) never went to the agent
- [~] (id:h-0006) keep a backslash \ and a percent %s intact <!-- run:20260901-030005 -->

## P2
- [~] (id:h-0005) a second-priority task <!-- run:20260901-030005 -->
FIXTURE

cat >"${MG_WS}" <<'FIXTURE'
# Worksheet

## P1
- [x] (id:h-0001) close me
- [!] (id:h-0002) block me <!-- reason: needs a decision on retention -->
- [ ] (id:h-0003) leave me untouched
- [x] (id:h-0004) an id this run was never given
- [x] (id:h-0006) keep a backslash \ and a percent %s intact
- [ ] a task split off from h-0001, keeping \ and 100% intact

## P2
- [x] (id:h-0005) a second-priority task
- [ ] a second-priority task split off, with no id
FIXTURE

cat >"${MG_IDS}" <<'FIXTURE'
h-0001
h-0002
h-0003
h-0005
h-0006
FIXTURE

MG_COUNTS=$(worksheet_merge "${MG_WS}" "${MG_LEDGER}" "${MG_RUN}" "${MG_IDS}")
t_eq "the counts are 'done blocked new ignored', as bin/hzl-run parses them" \
  "3 1 2 1" "${MG_COUNTS}"

MG_H1=$(grep -F '(id:h-0001)' "${MG_LEDGER}")
case ${MG_H1} in
  "- [x] (id:h-0001) close me <!-- done:"*" run:${MG_RUN} -->") MG_ST=0 ;;
  *) MG_ST=1 ;;
esac
t_ok "[x] closes the task with done: and the run id" "${MG_ST}"

MG_H2=$(grep -F '(id:h-0002)' "${MG_LEDGER}")
case ${MG_H2} in
  "- [!] (id:h-0002) block me <!-- blocked:"*" reason:needs a decision on retention run:${MG_RUN} -->") MG_ST=0 ;;
  *) MG_ST=1 ;;
esac
t_ok "[!] records the reason taken from the trailing comment" "${MG_ST}"

t_eq "an untouched task goes back to [ ] with its metadata cleared" \
  "- [ ] (id:h-0003) leave me untouched" \
  "$(grep -F '(id:h-0003)' "${MG_LEDGER}")"
t_has "its continuation line stays with it" \
  "${MG_LEDGER}" '      note: a note that must stay with h-0003'

t_eq "an id that was never on the worksheet is left exactly as it was" \
  "- [ ] (id:h-0004) never went to the agent" \
  "$(grep -F '(id:h-0004)' "${MG_LEDGER}")"

t_has "a backslash and a percent sign in the task text survive a merge" \
  "${MG_LEDGER}" '- [x] (id:h-0006) keep a backslash \ and a percent %s intact <!-- done:'

t_has "an id-less line becomes a new task, backslash and percent intact" \
  "${MG_LEDGER}" '- [ ] a task split off from h-0001, keeping \ and 100% intact'
t_has "and so does one under a second priority" \
  "${MG_LEDGER}" '- [ ] a second-priority task split off, with no id'

MG_P1NEW=$(line_of "${MG_LEDGER}" 'a task split off from h-0001')
MG_P2HEAD=$(line_of "${MG_LEDGER}" '## P2')
MG_P2NEW=$(line_of "${MG_LEDGER}" 'a second-priority task split off')
[ "${MG_P1NEW}" -gt 0 ] && [ "${MG_P1NEW}" -lt "${MG_P2HEAD}" ]
t_ok "a new task is inserted at the end of its own priority section" "$?"
[ "${MG_P2NEW}" -gt "${MG_P2HEAD}" ]
t_ok "a new P2 task lands under P2, not P1" "$?"

# The ignored line is the one assertion that makes scope structural rather
# than requested: the agent wrote [x] beside h-0004 and the ledger does not
# care, because the runner never put h-0004 on the id list.
t_eq "an out-of-scope [x] is counted as ignored, not applied" \
  1 "$(printf '%s' "${MG_COUNTS}" | cut -d' ' -f4)"

MG_MISSING=$(worksheet_merge "${TMPROOT}/no-such-worksheet.md" "${MG_LEDGER}" \
  "${MG_RUN}" "${MG_IDS}")
MG_ST=$?
t_eq "an unreadable worksheet still prints four counts" "0 0 0 0" "${MG_MISSING}"
t_fails "and reports failure" "${MG_ST}"

# --- the engine layer ------------------------------------------------------
#
# Everything below is a characterization test: it pins the behaviour that
# lib/engines.sh and lib/watchdog.sh have today, so that the extraction of an
# Agent Driver and a LocalRuntime (docs/RUNTIME-BACKENDS.md §7, §8) can be
# judged by whether anything observable moved. It asserts what is, not what
# ought to be.
#
# No real engine is ever started. `claude` and `codex` are shell stand-ins on a
# temp PATH entry, so a test run costs nothing and works offline.

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/watchdog.sh
. "${TEST_ROOT}/lib/watchdog.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/runtimes.sh
. "${TEST_ROOT}/lib/runtimes.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/engines.sh
. "${TEST_ROOT}/lib/engines.sh"

# Set here, not through hzl_load_conf: the golden argv must be the same on a
# machine with an etc/heinzel.conf as on one without.
HEINZEL_MODEL="test-model"
HEINZEL_EFFORT="test-effort"
HEINZEL_CODEX_MODEL="test-codex-model"
HEINZEL_CODEX_EFFORT="test-codex-effort"
HEINZEL_CODEX_IGNORE_USER_CONFIG=0

# --- hzl_timeout -----------------------------------------------------------

group 'hzl_timeout'

WD_DIR=${TMPROOT}/watchdog
mkdir -p "${WD_DIR}"

t_status() { # name expected-status actual-status
  t_eq "$1" "$2" "$3"
}

hzl_timeout 5 5 /bin/bash -c 'exit 7'
t_status "the command's own exit status is passed through" 7 "$?"

hzl_timeout 5 5 /bin/bash -c 'exit 0'
t_status "and so is success" 0 "$?"

hzl_timeout 5 1 sleep 30
t_status "exceeding the wall clock is 124" 124 "$?"

# A child that ignores TERM must still be gone: 137 is the promise that the
# wall-clock budget cannot be declined by the thing being budgeted.
cat >"${WD_DIR}/deaf.sh" <<'DEAF'
#!/bin/bash
trap '' TERM
while :; do sleep 1; done
DEAF
chmod +x "${WD_DIR}/deaf.sh"
hzl_timeout 1 1 /bin/bash "${WD_DIR}/deaf.sh"
t_status "a command that ignores TERM is killed, and that is 137" 137 "$?"

t_eq "HEINZEL_ENGINE_PID is cleared once the run is over" "" "${HEINZEL_ENGINE_PID}"

hzl_timeout 5 5
t_status "no command at all is a usage error, 125" 125 "$?"

hzl_timeout 5 not-a-number sleep 0
t_status "a non-numeric timeout is refused, not rounded" 125 "$?"

# The reason the child is never wrapped in `( cd x && cmd )`: an engine's own
# subprocesses must die with it. A grandchild that survives keeps billing.
cat >"${WD_DIR}/spawner.sh" <<'SPAWN'
#!/bin/bash
sleep 30 &
printf '%s\n' "$!" >"$1"
wait
SPAWN
chmod +x "${WD_DIR}/spawner.sh"
WD_PIDFILE=${WD_DIR}/grandchild.pid
hzl_timeout 2 1 /bin/bash "${WD_DIR}/spawner.sh" "${WD_PIDFILE}"
t_status "a child that spawns its own child still times out" 124 "$?"

WD_GRANDCHILD=$(cat "${WD_PIDFILE}" 2>/dev/null)
WD_I=0
while [ ${WD_I} -lt 20 ]; do
  kill -0 "${WD_GRANDCHILD}" 2>/dev/null || break
  sleep 0.1
  WD_I=$((WD_I + 1))
done
kill -0 "${WD_GRANDCHILD}" 2>/dev/null
t_fails "the whole process group dies, not just the child" "$?"
kill -KILL "${WD_GRANDCHILD}" 2>/dev/null

# --- the fake engine -------------------------------------------------------
#
# One script under two names. It records the argv it was called with, plays
# back canned output, and exits with a canned status. Everything it does is
# driven by FAKE_* in the environment, so a case sets up its engine by
# exporting variables rather than by rewriting the script.

FAKE_BIN=${TMPROOT}/bin
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/claude" <<'FAKE'
#!/bin/bash
# A stand-in for an agent CLI, for tests/test.sh. It never touches a network.
[ -n "${FAKE_ARGV:-}" ] && printf '%s\0' "$@" >"${FAKE_ARGV}"
[ -n "${FAKE_LAST_FILE:-}" ] && printf '%s' "${FAKE_LAST_TEXT:-}" >"${FAKE_LAST_FILE}"
[ -n "${FAKE_OUT_FILE:-}" ] && cat "${FAKE_OUT_FILE}"
[ -n "${FAKE_ERR_FILE:-}" ] && cat "${FAKE_ERR_FILE}" >&2
[ "${FAKE_SLEEP:-0}" != 0 ] && sleep "${FAKE_SLEEP}"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "${FAKE_BIN}/claude"
cp "${FAKE_BIN}/claude" "${FAKE_BIN}/codex"
PATH=${FAKE_BIN}:${PATH}
export PATH

FAKE_ARGV=""
FAKE_LAST_FILE=""
FAKE_LAST_TEXT=""
FAKE_OUT_FILE=""
FAKE_ERR_FILE=""
FAKE_SLEEP=0
FAKE_RC=0
export FAKE_ARGV FAKE_LAST_FILE FAKE_LAST_TEXT FAKE_OUT_FILE FAKE_ERR_FILE \
       FAKE_SLEEP FAKE_RC

fake_reset() {
  FAKE_ARGV=""
  FAKE_LAST_FILE=""
  FAKE_LAST_TEXT=""
  FAKE_OUT_FILE=""
  FAKE_ERR_FILE=""
  FAKE_SLEEP=0
  FAKE_RC=0
}

# --- argv: what engine_run actually builds ---------------------------------
#
# The launch is compared as a NUL-separated byte stream, not as a line-per-
# argument rendering: the reviewer's --json-schema is a whole file, newlines
# and all, and a comparison that split on newlines would pass while the real
# argv fell apart into thirty arguments.

group 'engine_run argv'

ARGV_WORK=${TMPROOT}/argv-workdir
ARGV_PROMPT=${TMPROOT}/argv-prompt.txt
mkdir -p "${ARGV_WORK}"
# A trailing newline, because `prompt=$(cat ...)` strips it and the engine must
# therefore receive the prompt without it.
printf 'do the thing\n\nand explain why\n' >"${ARGV_PROMPT}"

REVIEW_SCHEMA=$(cat "${TEST_ROOT}/etc/review-schema.json")
SETTINGS=${TEST_ROOT}/etc/heinzel-settings.json
PROMPT_ARG='do the thing

and explain why'

# Renders a NUL-separated argv one argument per numbered line, for a failure
# message a reader can act on.
argv_show() {
  awk 'BEGIN{RS="\0"} {printf "         [%d] %s\n", NR-1, $0}' "$1"
}

t_argv() { # name actual-file expected-arg...
  local name=$1 got=$2
  shift 2
  local want=${TMPROOT}/expected.cmd
  printf '%s\0' "$@" >"${want}"
  if cmp -s "${want}" "${got}"; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "${name}"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       want:\n%s       got:\n%s' \
      "${name}" "$(argv_show "${want}")" "$(argv_show "${got}")"
    printf '\n'
  fi
}

# A dry run must not start anything: the argv it records is the whole output.
dry_run() { # engine role outdir
  fake_reset
  FAKE_ARGV=${3}/must-not-exist.argv
  HEINZEL_DRY_RUN=1 engine_run "$1" "$2" "${ARGV_WORK}" "${ARGV_PROMPT}" "$3"
}

AR_CE=${TMPROOT}/argv-claude-executor
dry_run claude executor "${AR_CE}"
t_ok "a dry run of the executor succeeds" "$?"
t_argv "claude executor: the launch, argument for argument" \
  "${AR_CE}/dry-run.cmd" \
  claude -p "${PROMPT_ARG}" \
  --output-format json \
  --setting-sources user \
  --settings "${SETTINGS}" \
  --permission-mode dontAsk \
  --disallowedTools 'Bash(sudo *)' 'Bash(sudo)' \
  --model test-model --effort test-effort
[ -e "${AR_CE}/must-not-exist.argv" ]
t_fails "a dry run starts no engine" "$?"

AR_CR=${TMPROOT}/argv-claude-reviewer
dry_run claude reviewer "${AR_CR}"
t_argv "claude reviewer: no write tools, and the schema as one argument" \
  "${AR_CR}/dry-run.cmd" \
  claude -p "${PROMPT_ARG}" \
  --output-format json \
  --setting-sources user \
  --settings "${SETTINGS}" \
  --permission-mode dontAsk \
  --disallowedTools Write Edit NotebookEdit Bash \
  --json-schema "${REVIEW_SCHEMA}" \
  --model test-model --effort test-effort

AR_XE=${TMPROOT}/argv-codex-executor
dry_run codex executor "${AR_XE}"
t_argv "codex executor: workspace-write, and the prompt last" \
  "${AR_XE}/dry-run.cmd" \
  codex exec --skip-git-repo-check -C "${ARGV_WORK}" --json \
  -o "${AR_XE}/last.txt" \
  -s workspace-write \
  -m test-codex-model \
  -c 'model_reasoning_effort="test-codex-effort"' \
  "${PROMPT_ARG}"

AR_XR=${TMPROOT}/argv-codex-reviewer
dry_run codex reviewer "${AR_XR}"
t_argv "codex reviewer: read-only, by the sandbox and not by the model" \
  "${AR_XR}/dry-run.cmd" \
  codex exec --skip-git-repo-check -C "${ARGV_WORK}" --json \
  -o "${AR_XR}/last.txt" \
  -s read-only \
  --output-schema "${TEST_ROOT}/etc/review-schema.json" \
  -m test-codex-model \
  -c 'model_reasoning_effort="test-codex-effort"' \
  "${PROMPT_ARG}"

AR_XI=${TMPROOT}/argv-codex-ignore-conf
HEINZEL_CODEX_IGNORE_USER_CONFIG=1
dry_run codex executor "${AR_XI}"
HEINZEL_CODEX_IGNORE_USER_CONFIG=0
t_argv "codex: ignore_user_config goes in before the prompt" \
  "${AR_XI}/dry-run.cmd" \
  codex exec --skip-git-repo-check -C "${ARGV_WORK}" --json \
  -o "${AR_XI}/last.txt" \
  -s workspace-write \
  -m test-codex-model \
  -c 'model_reasoning_effort="test-codex-effort"' \
  -c 'ignore_user_config=true' \
  "${PROMPT_ARG}"

AR_CB=${TMPROOT}/argv-claude-budget
HEINZEL_MAX_BUDGET_USD=1.50
export HEINZEL_MAX_BUDGET_USD
dry_run claude executor "${AR_CB}"
unset HEINZEL_MAX_BUDGET_USD
t_argv "claude: a budget cap is passed through when one is configured" \
  "${AR_CB}/dry-run.cmd" \
  claude -p "${PROMPT_ARG}" \
  --output-format json \
  --setting-sources user \
  --settings "${SETTINGS}" \
  --permission-mode dontAsk \
  --disallowedTools 'Bash(sudo *)' 'Bash(sudo)' \
  --model test-model --effort test-effort \
  --max-budget-usd 1.50

AR_DRY=$(jq -c '{engine, role, verdict, exit_code, dry_run}' "${AR_CE}/result.json")
t_eq "a dry run still leaves a result.json, marked as one" \
  '{"engine":"claude","role":"executor","verdict":"ok","exit_code":0,"dry_run":true}' \
  "${AR_DRY}"

HEINZEL_DRY_RUN=1 engine_run nosuchengine executor "${ARGV_WORK}" \
  "${ARGV_PROMPT}" "${TMPROOT}/argv-unknown" 2>/dev/null
t_fails "an unknown engine is refused" "$?"

# --- the launch spec -------------------------------------------------------
#
# The spec is what a runtime backend is handed instead of a command string
# (RUNTIME-BACKENDS §7). Its shape is a contract between the Agent Driver and
# every backend, so it is asserted directly rather than only through the argv
# that happens to be rendered from it.

group 'engine_build_launch'

SPEC=${TMPROOT}/launch-spec.json
engine_build_launch codex reviewer batch "${ARGV_WORK}" "${ARGV_PROMPT}" \
  "${TMPROOT}/spec-out" "${SPEC}"
t_ok "a launch spec is built" "$?"
t_eq "it names the engine, the executable, the role and the profile" \
  '{"schema_version":1,"engine":"codex","agent_kind":"codex","executable":"codex","role":"reviewer","io_mode":"batch","security_profile":"review-read-only-v1","model":"test-codex-model","effort":"test-codex-effort","env":{}}' \
  "$(jq -c '{schema_version, engine, agent_kind, executable, role, io_mode,
             security_profile, model, effort, env}' "${SPEC}")"
t_eq "argv is an array of arguments, not a command string" \
  array "$(jq -r '.argv | type' "${SPEC}")"
t_eq "and it does not repeat the executable" \
  exec "$(jq -r '.argv[0]' "${SPEC}")"

# The prompt is one argument however many lines it has. A spec that split it
# would still launch, and the engine would be given four arguments of prose.
t_eq "a multi-line argument survives as a single element" \
  "${PROMPT_ARG}" "$(jq -r '.argv[-1]' "${SPEC}")"

engine_build_launch claude executor interactive "${ARGV_WORK}" \
  "${ARGV_PROMPT}" "${TMPROOT}/spec-out" "${TMPROOT}/never-spec.json" 2>/dev/null
t_fails "an io mode the driver cannot build is refused, not served as batch" "$?"

# The executor profile is the one that may write. Naming it in the spec is how
# a later phase can compare what was asked for against what was launched.
engine_build_launch claude executor batch "${ARGV_WORK}" "${ARGV_PROMPT}" \
  "${TMPROOT}/spec-out" "${SPEC}"
t_eq "the executor asks for the writing profile" \
  execute-workspace-write-v1 "$(jq -r '.security_profile' "${SPEC}")"

# --- engine_is_auth_error --------------------------------------------------
#
# Per engine, deliberately: codex prints MCP 401s on runs that succeeded, and
# claude's pattern applied to codex would halt the tool on the first unrelated
# non-zero exit.

group 'engine_is_auth_error'

AUTH_ERR=${TMPROOT}/auth-stderr
printf 'API error: 401 Unauthorized\n' >"${AUTH_ERR}"
engine_is_auth_error claude 1 "${AUTH_ERR}"
t_ok "claude: a 401 on a failed run is an auth error" "$?"

engine_is_auth_error claude 0 "${AUTH_ERR}"
t_fails "a run that exited 0 is never an auth error, whatever it printed" "$?"

printf 'error: could not read file\n' >"${TMPROOT}/plain-stderr"
engine_is_auth_error claude 1 "${TMPROOT}/plain-stderr"
t_fails "an unrelated failure is not an auth error" "$?"

engine_is_auth_error claude 1 "${TMPROOT}/no-such-stderr-file"
t_fails "an unreadable stderr is not an auth error" "$?"

printf 'ERROR rmcp::service: 401 Unauthorized from an MCP server\n' \
  >"${TMPROOT}/codex-mcp-stderr"
engine_is_auth_error codex 1 "${TMPROOT}/codex-mcp-stderr"
t_fails "codex: an MCP transport 401 is not the agent's own auth failure" "$?"

printf 'You are not logged in. Run codex login.\n' >"${TMPROOT}/codex-auth-stderr"
engine_is_auth_error codex 1 "${TMPROOT}/codex-auth-stderr"
t_ok "codex: not being logged in is" "$?"

engine_is_auth_error nosuchengine 1 "${AUTH_ERR}"
t_fails "an unknown engine is never diagnosed as an auth failure" "$?"

# --- engine_verdict --------------------------------------------------------

group 'engine_verdict'

VD_RAW=${TMPROOT}/verdict-raw.json
printf '{"is_error":false,"result":"fine"}\n' >"${VD_RAW}"
VD_RAW_ERR=${TMPROOT}/verdict-raw-error.json
printf '{"is_error":true,"result":"not fine"}\n' >"${VD_RAW_ERR}"

t_eq "124 from the watchdog is a timeout" \
  timeout "$(engine_verdict claude 124 "${TMPROOT}/plain-stderr" "${VD_RAW}")"
t_eq "so is 137" \
  timeout "$(engine_verdict claude 137 "${TMPROOT}/plain-stderr" "${VD_RAW}")"
t_eq "an auth failure outranks a plain error" \
  auth "$(engine_verdict claude 1 "${AUTH_ERR}" "${VD_RAW}")"
t_eq "any other non-zero exit is an error" \
  error "$(engine_verdict claude 1 "${TMPROOT}/plain-stderr" "${VD_RAW}")"
t_eq "a clean run is ok" \
  ok "$(engine_verdict claude 0 "${TMPROOT}/plain-stderr" "${VD_RAW}")"
# claude reports a failed run inside a successful process exit.
t_eq "claude's is_error inside a zero exit is still an error" \
  error "$(engine_verdict claude 0 "${TMPROOT}/plain-stderr" "${VD_RAW_ERR}")"
t_eq "the same body from codex is not read that way" \
  ok "$(engine_verdict codex 0 "${TMPROOT}/plain-stderr" "${VD_RAW_ERR}")"

# --- engine_run against the fake engine ------------------------------------

group 'engine_run'

RUN_WORK=${TMPROOT}/run-workdir
RUN_PROMPT=${TMPROOT}/run-prompt.txt
mkdir -p "${RUN_WORK}"
printf 'run this\n' >"${RUN_PROMPT}"

CLAUDE_OK_RAW=${TMPROOT}/claude-ok.json
cat >"${CLAUDE_OK_RAW}" <<'RAWJSON'
{"session_id":"sess-1","total_cost_usd":0.25,"num_turns":4,
 "usage":{"input_tokens":11,"output_tokens":22},
 "modelUsage":{"claude-opus-5":{"inputTokens":11},"claude-haiku-4-5":{"inputTokens":1}},
 "is_error":false,
 "result":"first line\nsecond line"}
RAWJSON

RUN_CE=${TMPROOT}/run-claude-ok
fake_reset
FAKE_OUT_FILE=${CLAUDE_OK_RAW}
FAKE_ARGV=${TMPROOT}/run-claude.argv
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_CE}" 60
t_status "a clean claude run returns 0" 0 "$?"

t_argv "the argv on a real run is the argv of the dry run" \
  "${TMPROOT}/run-claude.argv" \
  -p 'run this' \
  --output-format json \
  --setting-sources user \
  --settings "${SETTINGS}" \
  --permission-mode dontAsk \
  --disallowedTools 'Bash(sudo *)' 'Bash(sudo)' \
  --model test-model --effort test-effort

RUN_FIELDS=$(jq -c '{engine, role, model, effort, verdict, exit_code,
                     session_id, cost_usd, tokens_in, tokens_out, turns,
                     models_used}' "${RUN_CE}/result.json")
t_eq "result.json carries the normalised run, field for field" \
  '{"engine":"claude","role":"executor","model":"test-model","effort":"test-effort","verdict":"ok","exit_code":0,"session_id":"sess-1","cost_usd":0.25,"tokens_in":11,"tokens_out":22,"turns":4,"models_used":["claude-haiku-4-5","claude-opus-5"]}' \
  "${RUN_FIELDS}"

# What was asked for and what actually ran are recorded separately, so an
# inherited setting that overrode the request can be found afterwards.
t_eq "models_used is what ran, not what was asked for" \
  "claude-haiku-4-5 claude-opus-5" \
  "$(jq -r '.models_used | join(" ")' "${RUN_CE}/result.json")"

t_eq "the final message is extracted to last.txt" \
  "$(printf 'first line\nsecond line')" "$(cat "${RUN_CE}/last.txt")"
t_eq "and reaches result.json with its trailing newline intact" \
  "$(printf 'first line\nsecond line\n' | od -An -c | tr -s ' ')" \
  "$(jq -j '.text' "${RUN_CE}/result.json" | od -An -c | tr -s ' ')"
t_eq "the engine's own output is kept verbatim" \
  "$(cat "${CLAUDE_OK_RAW}")" "$(cat "${RUN_CE}/raw")"
t_ok "duration_sec is recorded" \
  "$(jq -e '.duration_sec >= 0' "${RUN_CE}/result.json" >/dev/null; printf %s $?)"

RUN_CIE=${TMPROOT}/run-claude-is-error
fake_reset
FAKE_OUT_FILE=${VD_RAW_ERR}
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_CIE}" 60
t_status "claude exiting 0 on a failed run still returns 0" 0 "$?"
t_eq "but the verdict is error" \
  '{"verdict":"error","exit_code":0}' \
  "$(jq -c '{verdict, exit_code}' "${RUN_CIE}/result.json")"

RUN_CF=${TMPROOT}/run-claude-fail
fake_reset
FAKE_RC=3
FAKE_ERR_FILE=${TMPROOT}/plain-stderr
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_CF}" 60
t_status "a non-zero engine exit is propagated to the caller" 3 "$?"
t_eq "and recorded as an error with that exit code" \
  '{"verdict":"error","exit_code":3}' \
  "$(jq -c '{verdict, exit_code}' "${RUN_CF}/result.json")"
t_eq "stderr is kept, because it is the input to auth detection" \
  "$(cat "${TMPROOT}/plain-stderr")" "$(cat "${RUN_CF}/stderr")"
t_eq "an unparseable body degrades to empty fields, not to a broken result" \
  '{"session_id":null,"cost_usd":null,"tokens_in":0,"tokens_out":0,"turns":0,"text":""}' \
  "$(jq -c '{session_id, cost_usd, tokens_in, tokens_out, turns, text}' \
      "${RUN_CF}/result.json")"

RUN_CA=${TMPROOT}/run-claude-auth
fake_reset
FAKE_RC=1
FAKE_ERR_FILE=${AUTH_ERR}
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_CA}" 60
t_status "an auth failure is propagated as the engine's own exit code" 1 "$?"
t_eq "and named in the verdict, so the runner can stop rather than retry" \
  auth "$(jq -r '.verdict' "${RUN_CA}/result.json")"

RUN_CT=${TMPROOT}/run-claude-timeout
fake_reset
FAKE_SLEEP=30
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_CT}" 1
t_status "a run over its wall clock returns 124" 124 "$?"
t_eq "and is a timeout, not an error" \
  '{"verdict":"timeout","exit_code":124}' \
  "$(jq -c '{verdict, exit_code}' "${RUN_CT}/result.json")"

CODEX_OK_RAW=${TMPROOT}/codex-ok.jsonl
cat >"${CODEX_OK_RAW}" <<'RAWJSONL'
{"type":"session.created","session_id":"cx-1"}
{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":6}}
RAWJSONL

RUN_XE=${TMPROOT}/run-codex-ok
fake_reset
FAKE_OUT_FILE=${CODEX_OK_RAW}
FAKE_LAST_FILE=${RUN_XE}/last.txt
FAKE_LAST_TEXT="codex had the last word"
mkdir -p "${RUN_XE}"
engine_run codex reviewer "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_XE}" 60
t_status "a clean codex run returns 0" 0 "$?"
t_eq "codex telemetry is folded into the same shape, with no cost figure" \
  '{"engine":"codex","role":"reviewer","verdict":"ok","session_id":"cx-1","cost_usd":null,"tokens_in":5,"tokens_out":6,"turns":0,"models_used":[]}' \
  "$(jq -c '{engine, role, verdict, session_id, cost_usd, tokens_in,
             tokens_out, turns, models_used}' "${RUN_XE}/result.json")"
t_eq "the last message codex wrote for itself is the one reported" \
  "codex had the last word" "$(jq -r '.text' "${RUN_XE}/result.json")"

# --- availability and authentication ---------------------------------------

group 'engine_available / engine_auth_ok'

engine_available claude
t_ok "an engine on PATH is available" "$?"
engine_available definitely-not-an-engine
t_fails "one that is not, is not" "$?"

engine_auth_ok claude
t_ok "claude is reported authenticated: there is no cheap offline probe" "$?"

fake_reset
FAKE_OUT_FILE=${TMPROOT}/codex-logged-in.txt
printf 'Logged in using ChatGPT\n' >"${FAKE_OUT_FILE}"
engine_auth_ok codex
t_ok "codex login status is read from stdout and stderr together" "$?"

FAKE_OUT_FILE=${TMPROOT}/codex-no-status.txt
printf 'codex: unexpected failure\n' >"${FAKE_OUT_FILE}"
engine_auth_ok codex
t_fails "and a message that says nothing about a session is not a yes" "$?"
fake_reset

engine_auth_ok nosuchengine
t_fails "an unknown engine is never authenticated" "$?"

# --- the runtime backend registry ------------------------------------------
#
# A backend is a key, a file and a registration — never an arm in a case
# statement (RUNTIME-BACKENDS §8.4). These assertions are what stops the second
# backend from being added the other way.

group 'runtime registry'

t_eq "the local backend is registered, and it is the only one" \
  local "$(runtime_backends | tr '\n' ' ' | sed 's/ *$//')"

runtime_known local
t_ok "a registered backend is known" "$?"
runtime_known herdr
t_fails "an unregistered one is not" "$?"

runtime_register local
t_ok "registering the same backend twice is not an error" "$?"
t_eq "and does not list it twice" \
  1 "$(runtime_backends | grep -c '^local$')"

runtime_register 'local; rm -rf /' 2>/dev/null
t_fails "a key that is not a plain name is refused" "$?"

runtime_run_batch herdr "${SPEC}" "${SPEC}" "${TMPROOT}/never.json" 2>/dev/null
t_fails "running on an unregistered backend is refused, not fallen back from" "$?"

RT_OUT=${TMPROOT}/runtime-unknown
HEINZEL_RUNTIME=herdr engine_run claude executor "${RUN_WORK}" \
  "${RUN_PROMPT}" "${RT_OUT}" 60 2>/dev/null
t_fails "and engine_run fails rather than quietly running it here" "$?"
[ -e "${RT_OUT}/result.json" ]
t_fails "leaving no result.json to be mistaken for a run" "$?"

# The launch spec and the run spec are separate files because they answer
# separate questions: what to start, and where and for how long.
RT_RUN=${TMPROOT}/runtime-run.json
RT_DIR=${TMPROOT}/runtime-batch
mkdir -p "${RT_DIR}"
fake_reset
FAKE_RC=5
jq -n --arg cwd "${RUN_WORK}" --arg d "${RT_DIR}" \
  '{schema_version: 1, cwd: $cwd, timeout_sec: 60, kill_after_sec: 5,
    stdout_path: ($d + "/raw"), stderr_path: ($d + "/stderr"),
    output_path: ($d + "/last.txt")}' >"${RT_RUN}"
engine_build_launch claude executor batch "${RUN_WORK}" "${RUN_PROMPT}" \
  "${RT_DIR}" "${RT_DIR}/launch.json"
runtime_run_batch local "${RT_DIR}/launch.json" "${RT_RUN}" \
  "${RT_DIR}/collected.json"
t_status "the backend returns the process's own exit status" 5 "$?"
t_eq "and writes it down, with the paths it used" \
  '{"schema_version":1,"exit_code":5}' \
  "$(jq -c '{schema_version, exit_code}' "${RT_DIR}/collected.json")"
t_eq "the stream paths in the record are the ones it was given" \
  "${RT_DIR}/raw ${RT_DIR}/stderr ${RT_DIR}/last.txt" \
  "$(jq -r '[.stdout_path, .stderr_path, .output_path] | join(" ")' \
      "${RT_DIR}/collected.json")"
[ -e "${RT_DIR}/collected.json.tmp" ]
t_fails "the temp file it renamed from is gone" "$?"

jq '.env = {"API_KEY": "x"}' "${RT_DIR}/launch.json" >"${RT_DIR}/env-launch.json"
runtime_run_batch local "${RT_DIR}/env-launch.json" "${RT_RUN}" \
  "${TMPROOT}/never.json" 2>/dev/null
t_fails "a launch environment it cannot carry is refused, not dropped" "$?"
fake_reset

# --- record schemas --------------------------------------------------------
#
# Three records outlive a run and are read by something other than the code that
# wrote them, and all three are versioned additively
# (docs/RUNTIME-BACKENDS.md §13.7, §14.1). Both halves of "additive" are
# asserted, because only one of them is obvious:
#
#   * a v2 writer keeps every v1 field — which the 113 assertions above already
#     say, since none of them were changed to accommodate v2;
#   * a v1 file is accepted, and is not repaired on the way past. That is the
#     half that fails silently: a reader that migrated what it read would make a
#     rollback to the previous build unreadable, and nothing would say so until
#     the rollback.

group 'schema constants'

# Each of the three is handed straight to `jq --argjson`, where an unset or
# non-numeric value is not a wrong version but a jq error — and the run record
# is appended with stderr discarded, so the row would simply not be written.
for _sc_name in HEINZEL_STATE_SCHEMA HEINZEL_RESULT_SCHEMA \
                HEINZEL_RUN_RECORD_SCHEMA; do
  eval "_sc=\${${_sc_name}:-}"
  case ${_sc} in
    ""|*[!0-9]*) _sc_ok=1 ;;
    *) _sc_ok=0 ;;
  esac
  t_eq "${_sc_name} is a number jq can take as JSON" 0 "${_sc_ok}"
done

group 'state.json schema'

# The file exactly as 0.1.6 wrote it: no schema_version, no runtime_backend.
# Expired on purpose, so hzl_eval_mode can be exercised without reaching the
# posture gate — this suite does not source lib/posture.sh.
V1_STATE=${TMPROOT}/v1-state.json
cat >"${V1_STATE}" <<'V1STATE'
{
  "mode": "heinzel",
  "activated_at": "2026-08-31T20:00:00+09:00",
  "activated_at_epoch": 1,
  "expires_at": "2026-09-01T06:00:00+09:00",
  "expires_at_epoch": 2,
  "duration": "10h",
  "boot_id": "old-boot",
  "workdir": "/tmp/work",
  "backlog": "/tmp/backlog.md",
  "max_tasks_per_run": 3,
  "max_tasks_total": 3,
  "tasks_done_total": 1,
  "run_timeout_sec": 3600,
  "hours": "1 2 3 4 5",
  "caffeinate_pid": 1,
  "pmset_restore": {"disablesleep": "0"},
  "sudo_used": true,
  "ticket_suspended": false,
  "halt_reason": null,
  "consecutive_failures": 0,
  "runs_completed": 2
}
V1STATE
cp "${V1_STATE}" "${STATE_FILE}"
V1_DIGEST=$(cksum <"${STATE_FILE}")

t_eq "a state file with no schema field is v1" 1 "$(state_schema_version)"
t_eq "and ran on local, the only backend there was when it was written" \
  local "$(state_runtime_backend)"

# Everything a status-shaped read touches, in one go.
state_get .mode normal >/dev/null
state_get .tasks_done_total 0 >/dev/null
state_get .halt_reason "" >/dev/null
state_schema_version >/dev/null
state_runtime_backend >/dev/null
state_schema_json >/dev/null
hzl_eval_mode
t_eq "reading a v1 file does not migrate it" "${V1_DIGEST}" "$(cksum <"${STATE_FILE}")"
t_eq "and it is still read as a real session state, not refused for its age" \
  "expired" "$(printf '%s' "${HZ_REASON}" | cut -d' ' -f1)"

# The same file with the fields `hzl on` now writes.
jq '. + {schema_version: 2, runtime_backend: "local"}' "${V1_STATE}" \
  >"${STATE_FILE}.next" && mv "${STATE_FILE}.next" "${STATE_FILE}"
t_eq "a file that carries the field is read at that version" \
  2 "$(state_schema_version)"
V2_DIGEST=$(cksum <"${STATE_FILE}")
state_schema_version >/dev/null
state_runtime_backend >/dev/null
t_eq "and reading it does not rewrite it either" \
  "${V2_DIGEST}" "$(cksum <"${STATE_FILE}")"

# A hand-edited or truncated version field must not become a shell arithmetic
# error three functions away.
jq '.schema_version = "banana"' "${V1_STATE}" >"${STATE_FILE}.next" &&
  mv "${STATE_FILE}.next" "${STATE_FILE}"
t_eq "a version that is not a number reads as v1 rather than as itself" \
  1 "$(state_schema_version)"

# A backend key from a build that had more of them: reported, not corrected.
jq '. + {schema_version: 3, runtime_backend: "herdr"}' "${V1_STATE}" \
  >"${STATE_FILE}.next" && mv "${STATE_FILE}.next" "${STATE_FILE}"
t_eq "a newer schema is read for the fields this build knows, not refused" \
  3 "$(state_schema_version)"
t_eq "and its backend is reported as it stands" herdr "$(state_runtime_backend)"

# What `hzl status --json` puts in the record. A machine that never ran
# `hzl on` has no state schema, and reporting 1 would be a claim about a file
# that does not exist.
t_eq "a state file has its schema reported as a number" 3 "$(state_schema_json)"
t_eq "and jq takes that value as a JSON scalar" \
  '{"schema_version":3}' \
  "$(jq -c -n --argjson schema_version "$(state_schema_json)" \
      '{schema_version: $schema_version}')"
rm -f "${STATE_FILE}"
t_eq "with no state file at all there is no schema to report" \
  null "$(state_schema_json)"
t_eq "which is also a JSON scalar, so the record is still valid JSON" \
  '{"schema_version":null}' \
  "$(jq -c -n --argjson schema_version "$(state_schema_json)" \
      '{schema_version: $schema_version}')"

group 'result.json schema'

# The record exactly as 0.1.6 wrote it, field for field.
V1_RESULT=${TMPROOT}/v1-result.json
cat >"${V1_RESULT}" <<'V1RESULT'
{
  "engine": "claude",
  "role": "executor",
  "model": "claude-opus-5",
  "effort": "xhigh",
  "models_used": ["claude-opus-5"],
  "exit_code": 0,
  "verdict": "ok",
  "duration_sec": 34,
  "session_id": "sess-old",
  "cost_usd": 0.25,
  "tokens_in": 11,
  "tokens_out": 22,
  "turns": 4,
  "text": "done"
}
V1RESULT
V1R_DIGEST=$(cksum <"${V1_RESULT}")

t_eq "a result with no schema field is v1" \
  1 "$(engine_result_schema_version "${V1_RESULT}")"
t_eq "it ran on local, because nothing else existed to run it" \
  local "$(engine_result_backend "${V1_RESULT}")"
t_eq "and its attempt outcome is derived from the verdict it does have" \
  COLLECTED "$(engine_result_attempt_outcome "${V1_RESULT}")"
t_eq "reading a v1 result does not rewrite it" \
  "${V1R_DIGEST}" "$(cksum <"${V1_RESULT}")"

printf '{"verdict":"timeout"}\n' >"${TMPROOT}/v1-timeout.json"
t_eq "a v1 timeout is read as one" \
  TIMED_OUT "$(engine_result_attempt_outcome "${TMPROOT}/v1-timeout.json")"
printf '{"verdict":"auth"}\n' >"${TMPROOT}/v1-auth.json"
t_eq "so is a v1 auth failure" \
  AUTH_FAILED "$(engine_result_attempt_outcome "${TMPROOT}/v1-auth.json")"
printf '{}\n' >"${TMPROOT}/v1-empty.json"
t_eq "a record with no verdict at all is unknown, not ok" \
  UNKNOWN "$(engine_result_attempt_outcome "${TMPROOT}/v1-empty.json")"

# The outcome exists so that "the attempt was collected" cannot be read as
# "the work was right". Nothing in the vocabulary says the latter.
t_eq "no verdict maps to a value that means the task was done" \
  "COLLECTED TIMED_OUT AUTH_FAILED FAILED UNKNOWN" \
  "$(engine_attempt_outcome ok; printf ' '; engine_attempt_outcome timeout
     printf ' '; engine_attempt_outcome auth; printf ' '
     engine_attempt_outcome error; printf ' '; engine_attempt_outcome nonsense)"

# What the writer produces now, from the runs already made above.
t_eq "a v2 result names its schema, its backend and its outcome" \
  '{"schema_version":2,"backend":"local","runtime_state":"EXITED","attempt_outcome":"COLLECTED","native_exit_code":0}' \
  "$(jq -c '{schema_version, backend, runtime_state, attempt_outcome,
             native_exit_code}' "${RUN_CE}/result.json")"
t_eq "and every v1 field is still exactly where it was" \
  '{"engine":"claude","role":"executor","model":"test-model","effort":"test-effort","exit_code":0,"verdict":"ok","session_id":"sess-1","cost_usd":0.25,"tokens_in":11,"tokens_out":22,"turns":4}' \
  "$(jq -c '{engine, role, model, effort, exit_code, verdict, session_id,
             cost_usd, tokens_in, tokens_out, turns}' "${RUN_CE}/result.json")"

# 124 is the watchdog's number, not the engine's. Reporting it as the process's
# own status would be a fabrication, and 0 would be a worse one (§13.7).
t_eq "a run the watchdog ended has no native exit code to report" \
  '{"exit_code":124,"native_exit_code":null,"attempt_outcome":"TIMED_OUT"}' \
  "$(jq -c '{exit_code, native_exit_code, attempt_outcome}' \
      "${RUN_CT}/result.json")"
t_eq "an engine that failed on its own keeps its own status" \
  '{"exit_code":3,"native_exit_code":3,"attempt_outcome":"FAILED"}' \
  "$(jq -c '{exit_code, native_exit_code, attempt_outcome}' \
      "${RUN_CF}/result.json")"
t_eq "an auth failure is named as one in the outcome too" \
  AUTH_FAILED "$(engine_result_attempt_outcome "${RUN_CA}/result.json")"

# A dry run started nothing, and the v2 fields say so rather than reporting a
# process that never existed.
t_eq "a dry run reports that nothing was started" \
  '{"schema_version":2,"backend":"local","runtime_state":"UNKNOWN","native_exit_code":null,"attempt_outcome":"NOT_STARTED","dry_run":true}' \
  "$(jq -c '{schema_version, backend, runtime_state, native_exit_code,
             attempt_outcome, dry_run}' "${AR_CE}/result.json")"

# The backend in the record is the one the run was sent to, not a constant.
engine_normalize_result "${RT_DIR}/launch.json" "${RT_DIR}/collected.json" \
  "${TMPROOT}/backend-named.json" herdr
t_eq "the backend written down is the one the caller named" \
  herdr "$(jq -r '.backend' "${TMPROOT}/backend-named.json")"
engine_normalize_result "${RT_DIR}/launch.json" "${RT_DIR}/collected.json" \
  "${TMPROOT}/backend-default.json"
t_eq "and a caller that names none gets local, as every v1 caller meant" \
  local "$(jq -r '.backend' "${TMPROOT}/backend-default.json")"

# --- the durable per-run store ---------------------------------------------
#
# One directory per run under HEINZEL_HOME (§14.1). HEINZEL_HOME is already
# redirected into the temp tree at the top of this file, and the suite refused
# to start otherwise, so every path below is under ${TMPROOT} by construction.

group 'runstore ids'

RS_ID=$(runstore_new_id)
RS_ID2=$(runstore_new_id)

# r-YYYYMMDDTHHMMSS-xxxxxx. Asserted as a shape rather than as a length,
# because the shape is what makes it sortable: fixed-width time, first.
case ${RS_ID} in
  r-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) RS_SHAPE=0 ;;
  *) RS_SHAPE=1 ;;
esac
t_eq "a run id is a fixed-width timestamp and a random suffix" 0 "${RS_SHAPE}"

# Two runs can start in the same second; a store keyed by the second alone
# would put the later one on top of the earlier one.
t_eq "two ids made in the same second are still different" \
  "different" "$([ "${RS_ID}" != "${RS_ID2}" ] && echo different || echo same)"

# The whole point of the shape: `sort` on the strings is chronological order.
t_eq "ids sort chronologically as plain strings" \
  "r-20260901T235959-aaaaaa r-20260902T000000-000000 r-20260902T031500-zzzzzz" \
  "$(printf 'r-20260902T031500-zzzzzz\nr-20260901T235959-aaaaaa\nr-20260902T000000-000000\n' |
     sort | tr '\n' ' ' | sed 's/ *$//')"

# A run id and a task id must never be mistaken for one another: the ledger's
# allocator reads `<letters>-<digits>` and would otherwise count a run id as
# the highest task number ever issued.
RS_LEDGER=${TMPROOT}/runid-vs-taskid.md
{
  printf '# Backlog\n\n## P1\n'
  printf -- '- [x] (id:h-0007) a real task\n'
  printf -- '- [ ] (id:%s) a line wearing a run id\n' "${RS_ID}"
} >"${RS_LEDGER}"
t_eq "a run id is not read as a task number" \
  7 "$(backlog_max_id_num "${RS_LEDGER}")"

group 'runstore layout'

runstore_dir "${RS_ID}" >/dev/null
t_ok "a well-formed id resolves to a directory" "$?"
t_eq "which is under HEINZEL_HOME, where the agent cannot reach it" \
  "${HEINZEL_HOME}/runs/${RS_ID}" "$(runstore_dir "${RS_ID}")"

runstore_dir "../../etc/passwd" 2>/dev/null
t_fails "an id that is not an id is refused rather than joined onto a path" "$?"
runstore_dir "" 2>/dev/null
t_fails "and so is an empty one" "$?"

runstore_init "${RS_ID}"
t_ok "the store for a run is created" "$?"
RS_DIR=$(runstore_dir "${RS_ID}")
[ -d "${RS_DIR}" ]
t_ok "and the directory is really there" "$?"

group 'runstore snapshot'

# The failure that produces a half-written file is a write that starts and does
# not finish. Here it is provoked directly: content that will not parse. If the
# target were opened for writing, it would exist and be broken; it is only ever
# renamed into place, so it does not exist at all.
runstore_snapshot "${RS_ID}" '{"broken": ' 2>/dev/null
t_fails "a snapshot that does not parse is refused" "$?"
[ -e "${RS_DIR}/workflow.json" ]
t_fails "and no partial file is left where a reader would look for one" "$?"

runstore_snapshot "${RS_ID}" '{"schema_version":1,"runner_state":"queued"}'
t_ok "a valid snapshot is written" "$?"
t_eq "and reads back whole" \
  '{"schema_version":1,"runner_state":"queued"}' \
  "$(runstore_read "${RS_ID}" | jq -c .)"

RS_FIRST=$(cksum <"${RS_DIR}/workflow.json")
runstore_snapshot "${RS_ID}" '{"runner_state": ' 2>/dev/null
t_fails "a later snapshot that does not parse is refused too" "$?"
t_eq "and the snapshot already there is untouched, not truncated" \
  "${RS_FIRST}" "$(cksum <"${RS_DIR}/workflow.json")"
t_ok "so the file a reader finds always parses" \
  "$(jq -e . "${RS_DIR}/workflow.json" >/dev/null 2>&1; printf %s $?)"

runstore_snapshot "${RS_ID}" '{"schema_version":1,"runner_state":"running"}'
t_eq "a snapshot replaces the one before it" \
  running "$(runstore_read "${RS_ID}" | jq -r '.runner_state')"

# The temp file is made in the same directory as the target — which is what
# makes the rename atomic rather than a copy across filesystems — and it is
# gone afterwards, on the failing path as well as the succeeding one.
t_eq "no temp file survives a write, successful or refused" \
  0 "$(find "${RS_DIR}" -maxdepth 1 -name '.workflow.*' | wc -l | tr -d ' ')"

runstore_read "r-20260101T000000-nosuch" 2>/dev/null
t_fails "reading a run with no store is a failure, not an empty snapshot" "$?"

group 'runstore events'

runstore_event "${RS_ID}" run.queued "1 task"
runstore_event "${RS_ID}" engine.started "claude executor"
t_ok "events are appended" "$?"
RS_EVENTS=${RS_DIR}/events.jsonl
t_eq "one line per event" 2 "$(wc -l <"${RS_EVENTS}" | tr -d ' ')"
t_eq "in the order they happened" \
  "run.queued engine.started" \
  "$(jq -r '.kind' "${RS_EVENTS}" | tr '\n' ' ' | sed 's/ *$//')"
t_ok "and every line is valid JSON on its own" \
  "$(jq -e -s . "${RS_EVENTS}" >/dev/null 2>&1; printf %s $?)"

# Append-only means the bytes already written are never rewritten. A trail that
# could be edited after the fact is not evidence of anything.
RS_PREFIX=$(cksum <"${RS_EVENTS}")
RS_PREFIX_LINES=$(wc -l <"${RS_EVENTS}" | tr -d ' ')
runstore_event "${RS_ID}" run.ended "ok"
t_eq "appending leaves every earlier byte where it was" \
  "${RS_PREFIX}" "$(head -n "${RS_PREFIX_LINES}" "${RS_EVENTS}" | cksum)"
t_eq "and the new event is on the end" \
  run.ended "$(tail -1 "${RS_EVENTS}" | jq -r '.kind')"

# A message with a newline in it would otherwise become two lines, one of
# which is not JSON.
runstore_event "${RS_ID}" note "$(printf 'first\nsecond')"
t_eq "a multi-line message is still one line" \
  4 "$(wc -l <"${RS_EVENTS}" | tr -d ' ')"
t_eq "with the message kept, flattened" \
  "first second" "$(tail -1 "${RS_EVENTS}" | jq -r '.message')"

runstore_event "r-20260101T000000-nosuch" note "no store" 2>/dev/null
t_fails "an event for a run with no store is refused, not written elsewhere" "$?"

group 'runstore listing'

runstore_init r-20260101T000000-aaaaaa
runstore_init r-20251231T235959-bbbbbb
t_eq "the runs with a store are listed oldest first" \
  "r-20251231T235959-bbbbbb r-20260101T000000-aaaaaa ${RS_ID}" \
  "$(runstore_runs | tr '\n' ' ' | sed 's/ *$//')"

# --- verdict ---------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
