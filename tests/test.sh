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
# shellcheck source=../lib/claims.sh
. "${TEST_ROOT}/lib/claims.sh"
# shellcheck source=../lib/locks.sh
. "${TEST_ROOT}/lib/locks.sh"
# shellcheck source=../lib/finalize.sh
. "${TEST_ROOT}/lib/finalize.sh"
# shellcheck source=../lib/watchdog.sh
. "${TEST_ROOT}/lib/watchdog.sh"
# shellcheck source=../lib/cancel.sh
. "${TEST_ROOT}/lib/cancel.sh"

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

# --- backlog_count ---------------------------------------------------------
#
# The four markers partition the ledger, which is why `hzl status` prints all
# four. It printed todo, blocked and done: a task a run had just claimed left
# `todo` and arrived nowhere, so three tasks vanished from a line whose numbers
# a human is meant to be able to add up.

group 'backlog_count'

CNT_LEDGER=${TMPROOT}/count.md
cat >"${CNT_LEDGER}" <<'FIXTURE'
# Backlog

The markers are documented in a fence, which is not work:

```
- [ ] an example that must not be counted as anything
```

## P1
- [ ] (id:h-0001) waiting for a run to pick it up
- [~] (id:h-0002) claimed by a run <!-- run:20260903-012502 -->
- [!] (id:h-0003) blocked <!-- blocked:2026-09-02T02:08:20+09:00 -->
- [x] (id:h-0004) finished <!-- done:2026-09-01T03:09:35+09:00 -->

## P2
- [~] (id:h-0005) claimed as well <!-- run:20260903-012502 -->
FIXTURE

t_eq "todo is counted" 1 "$(backlog_count "${CNT_LEDGER}" " ")"
t_eq "in progress is counted, which the status line used to leave out" \
  2 "$(backlog_count "${CNT_LEDGER}" "~")"
t_eq "blocked is counted" 1 "$(backlog_count "${CNT_LEDGER}" "!")"
t_eq "done is counted" 1 "$(backlog_count "${CNT_LEDGER}" x)"
t_eq "and the four add up to every task in the ledger, the fenced one excluded" \
  "$(backlog_scan "${CNT_LEDGER}" | awk 'END {print NR}')" \
  "$(( $(backlog_count "${CNT_LEDGER}" " ") \
     + $(backlog_count "${CNT_LEDGER}" "~") \
     + $(backlog_count "${CNT_LEDGER}" "!") \
     + $(backlog_count "${CNT_LEDGER}" x) ))"

# `hzl next` hands out `[ ]` and nothing else, so nothing coming back from it
# is not the same statement as an empty ledger. That is why it now reports what
# is in progress rather than saying there is nothing to do.
CNT_HELD=${TMPROOT}/count-held.md
cat >"${CNT_HELD}" <<'FIXTURE'
# Backlog

## P1
- [~] (id:h-0001) the last task, and a run is holding it <!-- run:20260903-012502 -->
FIXTURE

t_eq "a ledger whose remaining task is claimed offers nothing up" \
  "" "$(backlog_next_row "${CNT_HELD}")"
t_eq "and it is still one unfinished task, not an empty backlog" \
  1 "$(backlog_count "${CNT_HELD}" "~")"

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

# --- worksheet_render ------------------------------------------------------
#
# The rebuild the runner does once it knows which of the tasks it wanted it
# actually got. What it takes is a list of ids, not a budget: a task another run
# claimed first is not on the worksheet at all, rather than on it without a
# marker (docs/RUNTIME-BACKENDS.md §13.4).

group 'worksheet_render'

RD_LEDGER=${TMPROOT}/rd-ledger.md
cat >"${RD_LEDGER}" <<'FIXTURE'
# Backlog

## P1
- [~] (id:h-0001) claimed by this run <!-- run:20260902-050000 -->
      note: a continuation line the agent needs
- [ ] (id:h-0002) claimed by somebody else

## P2
- [~] (id:h-0003) also claimed by this run <!-- run:20260902-050000 -->

## P3
- [ ] (id:h-0004) never on the worksheet at all
FIXTURE

RD_IDFILE=${TMPROOT}/rd-ids.txt
RD_OUT=${TMPROOT}/rd-worksheet.md
printf 'h-0001\nh-0003\n' >"${RD_IDFILE}"
RD_IDS=$(worksheet_render "${RD_LEDGER}" "${RD_IDFILE}" "${RD_OUT}" |
  tr '\n' ' ' | sed 's/ *$//')
t_eq "only the listed ids come back, in ledger order" "h-0001 h-0003" "${RD_IDS}"
t_has "a claimed task is handed to the agent as a todo, not as [~]" \
  "${RD_OUT}" '- [ ] (id:h-0001) claimed by this run'
t_lacks "the run: metadata of the claim is not shown to the agent" \
  "${RD_OUT}" 'run:20260902-050000'
t_has "continuation lines survive the rebuild" \
  "${RD_OUT}" '      note: a continuation line the agent needs'
t_lacks "a task claimed by another run is not in front of the agent at all" \
  "${RD_OUT}" 'h-0002'
t_lacks "and neither is one this run never asked for" "${RD_OUT}" 'h-0004'
t_has "the priority heading of a rendered task comes with it" "${RD_OUT}" '## P1'
t_has "so does the second one" "${RD_OUT}" '## P2'
t_lacks "a priority with nothing left in it gets no heading" "${RD_OUT}" '## P3'

printf 'h-9999\n' >"${RD_IDFILE}"
RD_IDS=$(worksheet_render "${RD_LEDGER}" "${RD_IDFILE}" "${TMPROOT}/never.md")
t_fails "an id that is not in the ledger is not invented" "$?"
t_eq "and nothing is printed for it" "" "${RD_IDS}"

: >"${RD_IDFILE}"
worksheet_render "${RD_LEDGER}" "${RD_IDFILE}" "${TMPROOT}/never.md" >/dev/null 2>&1
t_fails "an empty id list is refused rather than rendered blank" "$?"

worksheet_render "${RD_LEDGER}" "${TMPROOT}/no-such-ids.txt" "${TMPROOT}/never.md" \
  >/dev/null 2>&1
t_fails "so is a missing id list" "$?"

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

# --- run-scoped task claims -------------------------------------------------
#
# The record of who is working on what moves out of the ledger, where the agent
# can reach it and where rolling back was all-or-nothing, and into
# HEINZEL_HOME, where it names a run (§13.4). Everything below is about scope:
# one run's claims, and nobody else's.

group 'claims identity'

CL_WORK=${TMPROOT}/claim-workspace
CL_OTHER=${TMPROOT}/claim-workspace-two
mkdir -p "${CL_WORK}" "${CL_OTHER}"
CL_ID=$(claims_workspace_identity "${CL_WORK}")
CL_ID2=$(claims_workspace_identity "${CL_OTHER}")

t_eq "an identity is a host and an absolute path" \
  "$(abspath "${CL_WORK}")" "$(printf '%s' "${CL_ID}" | sed 's/^[^:]*://')"
# Two spellings of one directory are one workspace. Without this, a workdir
# reached through a symlink would get its own claims directory and the two
# would not see each other's claims at all.
t_eq "and it is canonical, so one directory has one identity" \
  "${CL_ID}" "$(claims_workspace_identity "${CL_WORK}/.")"
t_eq "the same workspace hashes the same way twice" \
  "$(claims_workspace_hash "${CL_ID}")" \
  "$(claims_workspace_hash "$(claims_workspace_identity "${CL_WORK}")")"
t_eq "two workspaces do not share a directory" \
  different \
  "$([ "$(claims_dir "${CL_ID}")" != "$(claims_dir "${CL_ID2}")" ] &&
     echo different || echo same)"
t_eq "which is under HEINZEL_HOME, where the agent cannot write it" \
  "${HEINZEL_HOME}/claims/$(claims_workspace_hash "${CL_ID}")" \
  "$(claims_dir "${CL_ID}")"

claims_acquire "${CL_ID}" "../../escape" r-20260902T000000-aaaaaa 2>/dev/null
t_fails "a task id that is not a task id is refused, not turned into a path" "$?"

group 'claims scope'

CL_A=r-20260902T000000-aaaaaa
CL_B=r-20260902T001000-bbbbbb
CL_C=r-20260902T002000-cccccc

claims_acquire "${CL_ID}" h-0001 "${CL_A}"
t_ok "a run takes a claim" "$?"
t_eq "and is recorded as holding it" \
  "${CL_A}" "$(claims_holder "${CL_ID}" h-0001)"
t_eq "at generation 1" 1 "$(claims_generation "${CL_ID}" h-0001)"

claims_acquire "${CL_ID}" h-0001 "${CL_A}"
t_ok "the same run retaking its own claim is not a conflict" "$?"
t_eq "and the fencing generation moves on" \
  2 "$(claims_generation "${CL_ID}" h-0001)"

claims_acquire "${CL_ID}" h-0001 "${CL_B}"
t_fails "another run cannot take a claim that is held" "$?"
t_eq "and the holder is unchanged by the attempt" \
  "${CL_A}" "$(claims_holder "${CL_ID}" h-0001)"

claims_release "${CL_ID}" h-0001 "${CL_B}"
t_fails "a run cannot release a claim it does not hold" "$?"
t_eq "so the claim is still there" \
  "${CL_A}" "$(claims_holder "${CL_ID}" h-0001)"

# The same task id in a different workspace is a different task.
claims_acquire "${CL_ID2}" h-0001 "${CL_B}"
t_ok "the same id in another workspace is free to claim" "$?"
t_eq "and the first workspace is untouched" \
  "${CL_A}" "$(claims_holder "${CL_ID}" h-0001)"

group 'claims reconcile: the kill case'

# Run A is holding two tasks when it is killed: nothing it ran could tidy up,
# so its claims are still standing. Run C holds one of its own.
claims_acquire "${CL_ID}" h-0002 "${CL_A}"
claims_acquire "${CL_ID}" h-0003 "${CL_C}"
t_eq "the runs holding claims here are all listed" \
  "${CL_A} ${CL_C}" \
  "$(claims_runs "${CL_ID}" | tr '\n' ' ' | sed 's/ *$//')"
t_eq "and each one's own tasks can be named" \
  "h-0001 h-0002" \
  "$(claims_of_run "${CL_ID}" "${CL_A}" | tr '\n' ' ' | sed 's/ *$//')"

t_eq "reconciling the dead run releases exactly its claims" \
  2 "$(claims_reconcile "${CL_ID}" "${CL_A}")"
t_eq "so it holds none" \
  "" "$(claims_of_run "${CL_ID}" "${CL_A}" | tr '\n' ' ' | sed 's/ *$//')"
t_eq "and the other run's claim is exactly where it was" \
  "${CL_C}" "$(claims_holder "${CL_ID}" h-0003)"
t_eq "which is also true of the other workspace" \
  "${CL_B}" "$(claims_holder "${CL_ID2}" h-0001)"

t_eq "reconciling a run that holds nothing is a no-op, not a failure" \
  0 "$(claims_reconcile "${CL_ID}" "${CL_A}")"

group 'claims rollback is a projection'

# The ledger marker is display. The rollback moves both, and only for the run
# it was given: another run's `[~]` is not its business, and a task the merge
# has already closed is not rolled back to todo by a claim being released.
CL_LEDGER=${TMPROOT}/claim-ledger.md
cat >"${CL_LEDGER}" <<'CLFIX'
# Backlog

## P1
- [~] (id:h-0010) held by the run being rolled back
- [x] (id:h-0011) closed by the merge, same run
- [~] (id:h-0012) held by a different run
- [ ] (id:h-0013) nobody's
CLFIX

claims_acquire "${CL_ID}" h-0010 "${CL_B}"
claims_acquire "${CL_ID}" h-0011 "${CL_B}"
claims_acquire "${CL_ID}" h-0012 "${CL_C}"

t_eq "the rollback resets one marker: the one still in progress" \
  1 "$(claims_rollback_run "${CL_ID}" "${CL_LEDGER}" "${CL_B}")"
t_eq "the in-progress task is back in the queue" \
  " " "$(backlog_marker_of_id "${CL_LEDGER}" h-0010)"
t_eq "the task the merge closed keeps its marker" \
  x "$(backlog_marker_of_id "${CL_LEDGER}" h-0011)"
t_eq "another run's in-progress marker is not touched" \
  "~" "$(backlog_marker_of_id "${CL_LEDGER}" h-0012)"
t_eq "and its claim is not released either" \
  "${CL_C}" "$(claims_holder "${CL_ID}" h-0012)"
t_eq "while the rolled-back run holds nothing" \
  "" "$(claims_of_run "${CL_ID}" "${CL_B}" | tr '\n' ' ' | sed 's/ *$//')"

# The blanket reset is still there and still works: it is what puts back a
# `[~]` that no claim ever covered.
t_eq "the legacy blanket reset still returns every marker it finds" \
  1 "$(backlog_reset_inprogress "${CL_LEDGER}")"
t_eq "including the one no rollback would have scoped to a run" \
  " " "$(backlog_marker_of_id "${CL_LEDGER}" h-0012)"

# --- locks and the workspace writer lease -----------------------------------
#
# The one global `run.lock` said three things at once: another runner is
# running, the ledger is being written, and this checkout has a writer. Here
# they are three (§14.3). Everything below is about who may take what, and what
# happens to what a dead process was holding.

group 'lock names and paths'

t_eq "a lock file is under HEINZEL_HOME, where the agent cannot write it" \
  "${HEINZEL_HOME}/locks/backlog.lock" "$(lock_file backlog)"
lock_file "../../escape" 2>/dev/null
t_fails "a lock name that is not a name is refused, not turned into a path" "$?"

group 'the short backlog lock'

lock_acquire "${LOCK_BACKLOG}" 0
t_ok "the lock is taken" "$?"
t_eq "and names the process holding it" "$$" "$(lock_holder "${LOCK_BACKLOG}")"

lock_release "${LOCK_BACKLOG}"
t_ok "the holder can release it" "$?"
t_eq "and then nobody holds it" "" "$(lock_holder "${LOCK_BACKLOG}")"

# A command run under the lock, and the lock gone afterwards: the point of the
# short lock is that it is short. `lock_with` runs the command in this shell, so
# a shell function can be the critical section - which is the reason this is not
# `lockf`, which can only wrap a command it execs.
LK_TOUCHED=${TMPROOT}/lock-witness
touched_under_lock() { printf '%s' "$(lock_holder "${LOCK_BACKLOG}")" >"${LK_TOUCHED}"; }
lock_with "${LOCK_BACKLOG}" 0 touched_under_lock
t_ok "lock_with runs its command" "$?"
t_eq "which ran while the lock was held" "$$" "$(cat "${LK_TOUCHED}")"
t_eq "and the lock is released when it returns" "" "$(lock_holder "${LOCK_BACKLOG}")"

lock_with "${LOCK_BACKLOG}" 0 false
t_status "lock_with returns its command's status, not its own" 1 "$?"

# A live holder that is not us. A real second process, because a pid that is
# merely a number would not answer the only question that matters here.
sleep 30 &
LK_LIVE=$!
LK_FILE=$(lock_file "${LOCK_BACKLOG}")
_lock_take "${LK_FILE}" "$(jq -c -n --argjson pid "${LK_LIVE}" \
  --arg acquired_at "$(iso_at)" \
  '{schema_version: 1, name: "backlog", pid: $pid, acquired_at: $acquired_at}')"
t_ok "another process takes the lock" "$?"

lock_acquire "${LOCK_BACKLOG}" 0
t_fails "a lock that is held is not taken" "$?"
lock_release "${LOCK_BACKLOG}"
t_fails "and cannot be released by anyone but its holder" "$?"
lock_reclaim "${LOCK_BACKLOG}" >/dev/null
t_fails "a live holder is never reclaimed, however long it has been holding" "$?"
t_eq "so it is still holding it" "${LK_LIVE}" "$(lock_holder "${LOCK_BACKLOG}")"

lock_with "${LOCK_BACKLOG}" 0 touched_under_lock
t_status "lock_with reports EX_TEMPFAIL, the same 75 lockf reports" 75 "$?"

# The holder dies without releasing. `wait` reaps it: a zombie still answers
# `kill -0`, so a test that skipped this would be asserting against a pid that
# reads as alive.
kill "${LK_LIVE}" 2>/dev/null
wait "${LK_LIVE}" 2>/dev/null
t_eq "the dead holder's lock is reclaimed, and names whose it was" \
  "${LK_LIVE}" "$(lock_reclaim "${LOCK_BACKLOG}")"
t_eq "so nobody holds it" "" "$(lock_holder "${LOCK_BACKLOG}")"
lock_acquire "${LOCK_BACKLOG}" 0
t_ok "and it can be taken again" "$?"
lock_release "${LOCK_BACKLOG}"

# --- with_backlog_lock ------------------------------------------------------
#
# The one spelling every ledger and session mutation in `bin/hzl-run` and
# `bin/hzl` goes through, so that "is this mutation guarded" is a question about
# one name (docs/RUNTIME-BACKENDS.md §14.3).

group 'with_backlog_lock'

WB_LEDGER=${TMPROOT}/wb-ledger.md
cat >"${WB_LEDGER}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) a task a human is about to close
FIXTURE

with_backlog_lock backlog_set_state "${WB_LEDGER}" h-0001 x "done:now by:human"
t_ok "a mutation under the lock succeeds" "$?"
t_eq "and it happened" x "$(backlog_marker_of_id "${WB_LEDGER}" h-0001)"
t_eq "the lock is not still held afterwards" "" "$(lock_holder "${LOCK_BACKLOG}")"

t_eq "stdout comes back through the lock" \
  "1" "$(with_backlog_lock backlog_count "${WB_LEDGER}" x)"

with_backlog_lock backlog_set_state "${WB_LEDGER}" h-9999 x ""
t_status "and so does a status: no such id is still 3" 3 "$?"

# Held by a live process that is not us. The mutation must not happen at all —
# a write that went ahead anyway is the bug the lock exists to prevent.
sleep 30 &
WB_LIVE=$!
_lock_take "$(lock_file "${LOCK_BACKLOG}")" "$(jq -c -n --argjson pid "${WB_LIVE}" \
  --arg acquired_at "$(iso_at)" \
  '{schema_version: 1, name: "backlog", pid: $pid, acquired_at: $acquired_at}')"
WB_SAVED_WAIT=${LOCK_WAIT_SEC}
LOCK_WAIT_SEC=1
with_backlog_lock backlog_set_state "${WB_LEDGER}" h-0001 "!" "blocked:now" 2>/dev/null
t_status "a mutation that cannot take the lock reports 75" 75 "$?"
t_eq "and did not touch the ledger" x "$(backlog_marker_of_id "${WB_LEDGER}" h-0001)"
WB_ERR=$(with_backlog_lock backlog_set_state "${WB_LEDGER}" h-0001 "!" "x" 2>&1 >/dev/null)
case ${WB_ERR} in
  *"did not run"*) t_ok "a refusal says so rather than passing quietly" 0 ;;
  *) t_ok "a refusal says so rather than passing quietly" 1 ;;
esac
LOCK_WAIT_SEC=${WB_SAVED_WAIT}

kill "${WB_LIVE}" 2>/dev/null
wait "${WB_LIVE}" 2>/dev/null
with_backlog_lock backlog_set_state "${WB_LEDGER}" h-0001 " " ""
t_ok "once the holder is gone the mutation goes through" "$?"
t_eq "and the ledger moved" " " "$(backlog_marker_of_id "${WB_LEDGER}" h-0001)"

group 'the workspace writer lease'

# One writer per checkout (§14.3, invariant 13). Two runs on one working tree
# are two writers in it, whatever else is different about them.
LS_ID=${CL_ID}
LS_ID2=${CL_ID2}
LS_A=r-20260902T010000-aaaaaa
LS_B=r-20260902T011000-bbbbbb

sleep 30 &
LS_LIVE=$!

t_eq "a lease lives under HEINZEL_HOME too" \
  "${HEINZEL_HOME}/workspace-leases/$(claims_workspace_hash "${LS_ID}").json" \
  "$(lease_file "${LS_ID}")"

lease_acquire "${LS_ID}" "${LS_A}" "${LS_LIVE}"
t_ok "the first run takes the writer lease" "$?"
t_eq "and is recorded as holding it" "${LS_A}" "$(lease_holder "${LS_ID}")"
t_eq "with the process that holds it" "${LS_LIVE}" "$(lease_pid "${LS_ID}")"
t_eq "at generation 1" 1 "$(lease_generation "${LS_ID}")"
t_eq "in a file only its owner can read" \
  600 "$(stat -f '%Lp' "$(lease_file "${LS_ID}")" 2>/dev/null)"

# The acceptance test: two runs, one working directory, one lease.
lease_acquire "${LS_ID}" "${LS_B}" "$$"
t_fails "a second run on the same workdir is refused the lease" "$?"
t_eq "and the first run still holds it" "${LS_A}" "$(lease_holder "${LS_ID}")"
lease_release "${LS_ID}" "${LS_B}"
t_fails "a run cannot release a lease it does not hold" "$?"
lease_renew "${LS_ID}" "${LS_B}"
t_fails "nor renew one" "$?"

lease_acquire "${LS_ID2}" "${LS_B}" "$$"
t_ok "another checkout is another lease, and free" "$?"
t_eq "which leaves the first exactly where it was" \
  "${LS_A}" "$(lease_holder "${LS_ID}")"

lease_acquire "${LS_ID}" "${LS_A}" "${LS_LIVE}"
t_ok "the holder retaking its own lease is not a conflict" "$?"
t_eq "and the fencing generation moves on" 2 "$(lease_generation "${LS_ID}")"

lease_renew "${LS_ID}" "${LS_A}"
t_ok "the holder renews it" "$?"
t_eq "which is a heartbeat, so the generation does not move" \
  2 "$(lease_generation "${LS_ID}")"

lease_reclaim "${LS_ID}" >/dev/null
t_fails "a lease whose holder is alive is not reclaimed" "$?"
t_eq "so the checkout still has its writer" "${LS_A}" "$(lease_holder "${LS_ID}")"

# The killed run: the lease outlives the process on purpose, because a
# controller that died still owns the checkout until something confirms it
# stopped. Recovering it is a deliberate act, and it names the run it took it
# from.
kill "${LS_LIVE}" 2>/dev/null
wait "${LS_LIVE}" 2>/dev/null
t_eq "a lease left by a dead run is recoverable, and says whose it was" \
  "${LS_A}" "$(lease_reclaim "${LS_ID}")"
t_eq "so the checkout has no writer" "" "$(lease_holder "${LS_ID}")"

lease_acquire "${LS_ID}" "${LS_B}" "$$"
t_ok "and the next run can take it" "$?"
t_eq "at a generation past the one that was fenced out" \
  3 "$(lease_generation "${LS_ID}")"
lease_release "${LS_ID}" "${LS_B}"
t_ok "the holder releases it" "$?"
t_eq "leaving nobody holding it" "" "$(lease_holder "${LS_ID}")"
# The counter is the workspace's, not the lease's: a counter that reset when the
# lease went would hand the next run a generation that had already been issued.
lease_acquire "${LS_ID}" "${LS_A}" "$$"
t_eq "the generation still only goes up, across a release" \
  4 "$(lease_generation "${LS_ID}")"
lease_release "${LS_ID}" "${LS_A}"

# --- the ledger commit, and the two places it can be interrupted ------------
#
# The merge used to be one motion: parse a line, apply it, parse the next. A
# process killed in the middle of that left half a merge and nothing saying so.
# Now it is parse, check, intent, commit, receipt (§13.4), and the two crash
# points are the acceptance: killed between the intent and the commit, and
# between the commit and the receipt. Either way the ledger line and
# `tasks_done_total` come out applied exactly once (§21.1).

group 'finalize: the candidate parse'

FN_WS=${TMPROOT}/fin-worksheet.md
FN_IDS=${TMPROOT}/fin-ids.txt
cat >"${FN_WS}" <<'FNWS'
# Worksheet

## P1
- [x] (id:h-0101) finished
- [!] (id:h-0102) stopped <!-- reason:needs a decision -->
- [ ] (id:h-0103) never picked up
- [ ] a task split off from another
- [x] (id:h-0199) never on this worksheet
FNWS
printf 'h-0101\nh-0102\nh-0103\n' >"${FN_IDS}"

FN_CANDS=$(finalize_candidates "${FN_WS}" "${FN_IDS}")
t_eq "a done marker in scope is a candidate completion" \
  "done	h-0101" "$(printf '%s\n' "${FN_CANDS}" | awk -F'\t' '$1 == "done" {print $1 "\t" $2}')"
t_eq "a blocked marker carries the reason the agent gave" \
  "needs a decision" \
  "$(printf '%s\n' "${FN_CANDS}" | awk -F'\t' '$1 == "blocked" {print $4}')"
t_eq "an untouched task is a reopen, not a completion" \
  h-0103 "$(printf '%s\n' "${FN_CANDS}" | awk -F'\t' '$1 == "reopen" {print $2}')"
t_eq "a line with no id is a new task, with its priority" \
  "1	a task split off from another" \
  "$(printf '%s\n' "${FN_CANDS}" | awk -F'\t' '$1 == "new" {print $3 "\t" $4}')"
# The scope check, made before anything is written rather than during.
t_eq "an id this run was not given is ignored, and named" \
  h-0199 "$(printf '%s\n' "${FN_CANDS}" | awk -F'\t' '$1 == "ignored" {print $2}')"
t_eq "and the parse writes nothing at all" \
  "$(finalize_digest "${FN_WS}")" "$(finalize_digest "${FN_WS}")"

# A ledger to commit against, rebuilt for each case so that one crash point
# cannot be read through the state the other left.
fn_ledger() { # path
  cat >"$1" <<'FNLED'
# Backlog

## P1
- [~] (id:h-0101) finished <!-- run:20260902-040000 -->
- [~] (id:h-0102) stopped <!-- run:20260902-040000 -->
- [~] (id:h-0103) never picked up <!-- run:20260902-040000 -->
FNLED
}

state_write '{"schema_version": 2, "mode": "normal", "tasks_done_total": 0}'

group 'finalize: the whole commit'

FN_LED=${TMPROOT}/fin-ledger.md
fn_ledger "${FN_LED}"
FN_RUN=r-20260902T040000-fin001
runstore_init "${FN_RUN}"

# One done, one blocked, one new task, and one line ignored: the id that was
# never on this run's worksheet, which is the scope check doing its job.
t_eq "the commit reports what it applied" \
  "1 1 1 1" "$(finalize_commit "${FN_RUN}" "${FN_WS}" "${FN_LED}" 20260902-040000 "${FN_IDS}")"
t_eq "and leaves a receipt, so the transition is on the record" \
  receipt "$(finalize_state "${FN_RUN}")"
t_eq "the completion is in the ledger" x "$(backlog_marker_of_id "${FN_LED}" h-0101)"
t_eq "the blocked task is blocked" "!" "$(backlog_marker_of_id "${FN_LED}" h-0102)"
t_eq "and the untouched one is back in the queue" \
  " " "$(backlog_marker_of_id "${FN_LED}" h-0103)"
t_eq "the intent named the completion before it happened" \
  h-0101 "$(jq -r '.done[0]' "${HEINZEL_HOME}/runs/${FN_RUN}/finalize.intent.json")"
t_eq "and the receipt digests the ledger the commit produced" \
  "$(finalize_digest "${FN_LED}")" \
  "$(jq -r '.ledger_digest_after' "${HEINZEL_HOME}/runs/${FN_RUN}/finalize.receipt.json")"
t_eq "a committed run is not pending" \
  "" "$(finalize_pending "${FN_LED}")"

group 'finalize: killed between the intent and the commit'

FN_LED2=${TMPROOT}/fin-ledger-2.md
fn_ledger "${FN_LED2}"
FN_RUN2=r-20260902T041000-fin002
runstore_init "${FN_RUN2}"
state_update '.tasks_done_total = 0'

# The crash: the intent is saved and the process is gone before the ledger is
# touched.
finalize_intent "${FN_RUN2}" "${FN_WS}" "${FN_LED2}" 20260902-041000 "${FN_IDS}"
t_ok "the intent is saved before the ledger is touched" "$?"
t_eq "so the ledger is exactly as it was" \
  "~" "$(backlog_marker_of_id "${FN_LED2}" h-0101)"
t_eq "and the run is pending: an intent with nothing saying it was applied" \
  "${FN_RUN2}" "$(finalize_pending "${FN_LED2}")"

t_eq "recovery applies the whole intent" \
  "1 1 1 0" "$(finalize_recover "${FN_RUN2}" "${FN_LED2}")"
t_eq "the completion lands" x "$(backlog_marker_of_id "${FN_LED2}" h-0101)"
t_eq "and is counted, once" 1 "$(state_get .tasks_done_total 0)"
t_eq "the run is finalized, so it is no longer pending" \
  receipt "$(finalize_state "${FN_RUN2}")"

finalize_recover "${FN_RUN2}" "${FN_LED2}" >/dev/null
t_fails "a second recovery is refused" "$?"
t_eq "the completion is not counted twice" 1 "$(state_get .tasks_done_total 0)"
t_eq "and the ledger line is applied once" \
  1 "$(backlog_count "${FN_LED2}" x)"

group 'finalize: killed between the commit and the receipt'

FN_LED3=${TMPROOT}/fin-ledger-3.md
fn_ledger "${FN_LED3}"
FN_RUN3=r-20260902T042000-fin003
runstore_init "${FN_RUN3}"
state_update '.tasks_done_total = 0'

# The other crash: the ledger transition happened and the receipt did not. The
# run never reached its own counter either - that is the last thing it does -
# so the completion is in the ledger and missing from the total.
finalize_intent "${FN_RUN3}" "${FN_WS}" "${FN_LED3}" 20260902-042000 "${FN_IDS}"
finalize_apply "${FN_RUN3}" "${FN_WS}" "${FN_LED3}" 20260902-042000 "${FN_IDS}" >/dev/null
t_eq "the ledger transition is already applied" \
  x "$(backlog_marker_of_id "${FN_LED3}" h-0101)"
t_eq "but nothing says so" intent "$(finalize_state "${FN_RUN3}")"
t_eq "so the run is pending" \
  "${FN_RUN3}" "$(finalize_pending "${FN_LED3}")"
FN_NEW_LINES=$(grep -cF 'a task split off from another' "${FN_LED3}")

t_eq "recovery re-applies nothing, because nothing is missing" \
  "0 0 0 0" "$(finalize_recover "${FN_RUN3}" "${FN_LED3}")"
t_eq "the completion is still applied exactly once" \
  1 "$(backlog_count "${FN_LED3}" x)"
t_eq "the new task the run added is not added a second time" \
  "${FN_NEW_LINES}" "$(grep -cF 'a task split off from another' "${FN_LED3}")"
t_eq "and the completion the run never counted is counted, once" \
  1 "$(state_get .tasks_done_total 0)"
t_eq "the receipt says the recovery wrote it" \
  true "$(jq -r '.recovered' "${HEINZEL_HOME}/runs/${FN_RUN3}/finalize.receipt.json")"

finalize_recover "${FN_RUN3}" "${FN_LED3}" >/dev/null
t_fails "and a second recovery is refused here too" "$?"
t_eq "leaving the total where it was" 1 "$(state_get .tasks_done_total 0)"

# --- a run that was killed does not settle ----------------------------------
#
# The first of the fault transitions (§21.1): a run interrupted during a task is
# `INTERRUPTED`, never `SETTLED`. The snapshot is written by the run it
# describes, so the last one a killed run managed to write says it was working -
# and it was, right until it was not. A reader that took that at face value
# would find a run that has been running since Tuesday.

group 'runstore: a killed run does not settle'

RS_RUN=r-20260902T050000-int001
runstore_init "${RS_RUN}"
rs_snap() { # runner-state [pid]
  if [ -n "${2:-}" ]; then
    jq -n --arg s "$1" --argjson p "$2" \
      '{schema_version: 1, run_id: "r-20260902T050000-int001",
        runner_state: $s, pid: $p}'
  else
    jq -n --arg s "$1" \
      '{schema_version: 1, run_id: "r-20260902T050000-int001",
        runner_state: $s}'
  fi
}

sleep 30 &
RS_LIVE=$!
runstore_snapshot "${RS_RUN}" "$(rs_snap running "${RS_LIVE}")"
t_eq "a run whose process is there is working, and says so" \
  running "$(runstore_runner_state "${RS_RUN}")"

kill "${RS_LIVE}" 2>/dev/null
wait "${RS_LIVE}" 2>/dev/null
t_eq "the same snapshot, written by a process that is gone, is interrupted" \
  interrupted "$(runstore_runner_state "${RS_RUN}")"
t_eq "and the snapshot itself is untouched by being read" \
  running "$(runstore_read "${RS_RUN}" | jq -r .runner_state)"

runstore_snapshot "${RS_RUN}" "$(rs_snap merging "${RS_LIVE}")"
t_eq "a run killed in the middle of its merge is interrupted too" \
  interrupted "$(runstore_runner_state "${RS_RUN}")"

# A terminal state is returned as it stands. A run that finished is finished,
# and its process being gone afterwards is what is supposed to happen.
runstore_snapshot "${RS_RUN}" "$(rs_snap ended "${RS_LIVE}")"
t_eq "a run that ended stays ended, dead process and all" \
  ended "$(runstore_runner_state "${RS_RUN}")"
runstore_snapshot "${RS_RUN}" "$(rs_snap interrupted "${RS_LIVE}")"
t_eq "and one the trap already marked interrupted is left alone" \
  interrupted "$(runstore_runner_state "${RS_RUN}")"

# A snapshot from a build before the pid was recorded cannot be checked, and a
# run that cannot be shown to be working is not working: the answer that leaves
# a human looking is the safe one.
runstore_snapshot "${RS_RUN}" "$(rs_snap running)"
t_eq "a snapshot with no pid to check reads as interrupted, not as running" \
  interrupted "$(runstore_runner_state "${RS_RUN}")"

# --- runstore_prune --------------------------------------------------------
#
# One directory per run, one run a night. The log tree has had a prune since the
# beginning; this store had none (docs/RUNTIME-BACKENDS.md §14.7). What must
# never be swept is the interesting half: a run that is still active, a run that
# stopped without settling, and a run whose ledger commit is unrecorded.

group 'runstore_prune'

RP_HOME=${TMPROOT}/prune-home
RP_SAVED_HOME=${HEINZEL_HOME}
HEINZEL_HOME=${RP_HOME}
mkdir -p "${RP_HOME}/runs"

# `find -mtime` measures the directory, so every fixture is aged after it is
# written. An old date rather than an offset: the suite must not depend on being
# run at a particular time of day.
rp_age() { touch -t 200001010000 "${RP_HOME}/runs/$1"; }
rp_make() { # id runner-state [pid]
  runstore_init "$1"
  if [ -n "${3:-}" ]; then
    runstore_snapshot "$1" "$(jq -n --arg r "$1" --arg s "$2" --argjson p "$3" \
      '{schema_version: 1, run_id: $r, runner_state: $s, pid: $p}')"
  else
    runstore_snapshot "$1" "$(jq -n --arg r "$1" --arg s "$2" \
      '{schema_version: 1, run_id: $r, runner_state: $s}')"
  fi
}

RP_OLD=r-20260101T010101-aaaaaa
RP_FRESH=r-20260101T010102-bbbbbb
RP_KILLED=r-20260101T010103-cccccc
RP_PENDING=r-20260101T010104-dddddd
RP_NOSNAP=r-20260101T010105-eeeeee
RP_STRAY=not-a-run-id

sleep 30 &
RP_LIVE=$!

rp_make "${RP_OLD}" ended 1
rp_make "${RP_FRESH}" ended 1
rp_make "${RP_KILLED}" running "${RP_LIVE}"
rp_make "${RP_PENDING}" ended 1
printf '{"run_id":"%s"}\n' "${RP_PENDING}" >"${RP_HOME}/runs/${RP_PENDING}/finalize.intent.json"
runstore_init "${RP_NOSNAP}"
mkdir -p "${RP_HOME}/runs/${RP_STRAY}"
printf 'a human left this here\n' >"${RP_HOME}/runs/${RP_STRAY}/notes.txt"

for rp in "${RP_OLD}" "${RP_KILLED}" "${RP_PENDING}" "${RP_NOSNAP}" "${RP_STRAY}"; do
  rp_age "${rp}"
done

t_eq "an id of the shape runstore_new_id writes is a run store" \
  0 "$(runstore_is_run_id "${RP_OLD}"; printf '%s' $?)"
t_eq "a directory a human named is not" \
  1 "$(runstore_is_run_id "${RP_STRAY}"; printf '%s' $?)"
t_eq "and neither is a task id" 1 "$(runstore_is_run_id h-0007; printf '%s' $?)"

RP_SWEPT=$(runstore_prune 14 | tr '\n' ' ' | sed 's/ *$//')
t_eq "an ended run past the window is swept, and named" "${RP_OLD}" "${RP_SWEPT}"
t_ok "and its directory is gone" \
  "$([ ! -d "${RP_HOME}/runs/${RP_OLD}" ] && printf 0 || printf 1)"
t_ok "a run killed with its process still alive is kept" \
  "$([ -d "${RP_HOME}/runs/${RP_KILLED}" ] && printf 0 || printf 1)"
t_ok "a run holding an intent with no receipt is kept" \
  "$([ -d "${RP_HOME}/runs/${RP_PENDING}" ] && printf 0 || printf 1)"
t_ok "a store with no snapshot to read is kept" \
  "$([ -d "${RP_HOME}/runs/${RP_NOSNAP}" ] && printf 0 || printf 1)"
t_ok "a directory that is not a run store is never touched" \
  "$([ -f "${RP_HOME}/runs/${RP_STRAY}/notes.txt" ] && printf 0 || printf 1)"
t_ok "a run inside the window is kept, ended or not" \
  "$([ -d "${RP_HOME}/runs/${RP_FRESH}" ] && printf 0 || printf 1)"

# The killed run's process ends: its state becomes `interrupted`, which §14.7
# calls active. A run that stopped without settling is not swept by age.
kill "${RP_LIVE}" 2>/dev/null
wait "${RP_LIVE}" 2>/dev/null
t_eq "the killed run now reads as interrupted" \
  interrupted "$(runstore_runner_state "${RP_KILLED}")"
RP_SWEPT=$(runstore_prune 14 | tr '\n' ' ' | sed 's/ *$//')
t_eq "a second pass finds nothing left to sweep" "" "${RP_SWEPT}"
t_ok "and an interrupted run is still there" \
  "$([ -d "${RP_HOME}/runs/${RP_KILLED}" ] && printf 0 || printf 1)"

# The receipt arrives: the commit is recorded, and the run becomes sweepable.
printf '{"run_id":"%s"}\n' "${RP_PENDING}" >"${RP_HOME}/runs/${RP_PENDING}/finalize.receipt.json"
rp_age "${RP_PENDING}"
RP_SWEPT=$(runstore_prune 14 | tr '\n' ' ' | sed 's/ *$//')
t_eq "a recorded commit no longer holds its store open" "${RP_PENDING}" "${RP_SWEPT}"

runstore_prune 0 2>/dev/null
t_fails "a retention of zero days is refused rather than sweeping everything" "$?"
runstore_prune abc 2>/dev/null
t_fails "and so is a window that is not a number" "$?"

# The stop states. `cancelled` is a run that was asked to stop and was watched
# stopping, so it is over and sweepable. `cancelling` and `orphaned` are not:
# §14.7 counts a stop in progress and a stop that could not be confirmed as
# active, and a store swept out from under an orphan takes with it the only
# record of what is still holding the checkout.
RP_CANCELLED=r-20260801T000004-can001
RP_CANCELLING=r-20260801T000005-can002
RP_ORPHANED=r-20260801T000006-orp001
for rp_id in "${RP_CANCELLED}" "${RP_CANCELLING}" "${RP_ORPHANED}"; do
  mkdir -p "${RP_HOME}/runs/${rp_id}"
done
printf '{"run_id":"x","runner_state":"cancelled","pid":1}\n' >"${RP_HOME}/runs/${RP_CANCELLED}/workflow.json"
printf '{"run_id":"x","runner_state":"cancelling","pid":1}\n' >"${RP_HOME}/runs/${RP_CANCELLING}/workflow.json"
printf '{"run_id":"x","runner_state":"orphaned","pid":1}\n' >"${RP_HOME}/runs/${RP_ORPHANED}/workflow.json"
rp_age "${RP_CANCELLED}"
rp_age "${RP_CANCELLING}"
rp_age "${RP_ORPHANED}"
RP_SWEPT=$(runstore_prune 14 | tr '\n' ' ' | sed 's/ *$//')
t_eq "a cancelled run is over, and is swept" "${RP_CANCELLED}" "${RP_SWEPT}"
t_eq "a stop still in progress is not" \
  1 "$([ -d "${RP_HOME}/runs/${RP_CANCELLING}" ] && printf 1 || printf 0)"
t_eq "and an orphaned run is kept, whatever its age" \
  1 "$([ -d "${RP_HOME}/runs/${RP_ORPHANED}" ] && printf 1 || printf 0)"

HEINZEL_HOME=${RP_SAVED_HOME}

# --- runstore_set_state -----------------------------------------------------
#
# Moving a run's state from outside the run. `hzl off` settles a run it has just
# stopped, and it does not know that run's task ids, exec directory or start
# time - so it must move the one field and leave the rest exactly as the run
# wrote it. A snapshot rebuilt from outside would quietly drop what recovery
# reads.

group 'runstore_set_state'

SS_RUN=r-20260902T060000-set001
runstore_init "${SS_RUN}"
runstore_snapshot "${SS_RUN}" '{"schema_version":1,"run_id":"r-20260902T060000-set001","runner_state":"running","pid":1,"task_ids":["h-0001","h-0002"],"exec_dir":"/tmp/exec","started_at":"2026-09-02T06:00:00+09:00"}'

t_ok "a state moves" "$(runstore_set_state "${SS_RUN}" cancelled >/dev/null 2>&1; echo $?)"
t_eq "and it is the new one" \
  cancelled "$(runstore_read "${SS_RUN}" | jq -r .runner_state)"
t_eq "the task ids the run recorded are still there" \
  '["h-0001","h-0002"]' "$(runstore_read "${SS_RUN}" | jq -c .task_ids)"
t_eq "and so is everything else recovery reads" \
  "/tmp/exec 2026-09-02T06:00:00+09:00" \
  "$(runstore_read "${SS_RUN}" | jq -r '"\(.exec_dir) \(.started_at)"')"
t_eq "updated_at is stamped, because something did change" \
  1 "$(runstore_read "${SS_RUN}" | jq -r 'if (.updated_at // "") == "" then 0 else 1 end')"
runstore_set_state "${SS_RUN}" "" 2>/dev/null
t_fails "an empty state is refused rather than written" "$?"
runstore_set_state r-20260902T060000-nope1 ended 2>/dev/null
t_fails "and a run with no snapshot to move has nothing to move" "$?"

# --- the durable cancel intent ----------------------------------------------
#
# `hzl off` sent a signal, waited, sent a stronger one and returned 0. Nothing
# recorded that a stop had been asked for, so a stop requested and never
# completed was indistinguishable afterwards from a run that fell over for no
# reason (docs/RUNTIME-BACKENDS.md §14.4, §14.5). The intent is written before
# anything is signalled, and the receipt is the only thing that says it worked.

group 'the durable cancel intent'

CX_RUN=r-20260902T070000-cxl001
runstore_init "${CX_RUN}"

t_eq "a run nobody has asked to stop has no intent" none "$(cancel_state "${CX_RUN}")"
cancel_requested "${CX_RUN}"
t_fails "and does not read as cancelled" "$?"

t_ok "a stop is requested" "$(cancel_request "${CX_RUN}" off 4242 >/dev/null 2>&1; echo $?)"
t_eq "which is durable, and says so" requested "$(cancel_state "${CX_RUN}")"
t_eq "the cause is recorded, not just the fact" off "$(cancel_reason "${CX_RUN}")"
cancel_requested "${CX_RUN}"
t_ok "a requested stop reads as cancelled from here on" "$?"
t_eq "the target it was written about is in it" \
  4242 "$(jq -r .target_pid "${HEINZEL_HOME}/runs/${CX_RUN}/cancel.intent.json")"

# The first cause is the true one. A run cancelled by `off` and then hurried
# along by a deadline was still cancelled by `off`, and a second request that
# overwrote the first would turn the record of why into the record of what
# happened last.
cancel_request "${CX_RUN}" ttl 5150 >/dev/null 2>&1
t_eq "a second request does not overwrite the first cause" off "$(cancel_reason "${CX_RUN}")"
t_ok "and is not an error - an intent is there, which is what it wanted" "$?"

t_eq "a run asked to stop and not confirmed is pending" \
  "${CX_RUN}" "$(cancel_pending | grep -F "${CX_RUN}")"

t_ok "the stop is confirmed" \
  "$(cancel_confirm "${CX_RUN}" "the process is gone" >/dev/null 2>&1; echo $?)"
t_eq "and the state moves with the receipt, not with the signal" \
  confirmed "$(cancel_state "${CX_RUN}")"
t_eq "the receipt carries the cause the intent named" \
  off "$(jq -r .reason "${HEINZEL_HOME}/runs/${CX_RUN}/cancel.receipt.json")"
t_eq "what observed the stop is recorded too" \
  "the process is gone" \
  "$(jq -r .confirmed_by "${HEINZEL_HOME}/runs/${CX_RUN}/cancel.receipt.json")"
t_eq "and a confirmed run is no longer pending" "" "$(cancel_pending | grep -F "${CX_RUN}")"

cancel_request r-20260902T070000-nostr7 off 2>/dev/null
t_fails "a run with no store has nowhere to put an intent" "$?"
cancel_request "${CX_RUN}" "" 2>/dev/null
t_fails "and a stop with no stated cause is refused" "$?"

# --- the stop barrier -------------------------------------------------------
#
# Soft interrupt, bounded grace, force stop, and then an observation. A signal
# delivered is not a stop; the difference is the whole of what `ORPHANED` means.

group 'the stop barrier'

# The `Terminated: 15` lines below are bash reporting its own background jobs
# going away, which is the thing these assertions are asking for. They are left
# visible rather than redirected: silencing the shell for the length of a test
# silences whatever else it had to say.

cancel_stop 0
t_ok "a target that is already gone is confirmed gone, without signalling" "$?"

sleep 30 &
CS_SOFT=$!
cancel_stop "${CS_SOFT}" 5 2
t_ok "a process that takes TERM is stopped inside the grace" "$?"
wait "${CS_SOFT}" 2>/dev/null
pid_alive "${CS_SOFT}"
t_fails "and it really is gone afterwards" "$?"

# A child that ignores TERM: the grace expires, the bounded force stop follows,
# and the answer is still an observation of the process being gone.
bash -c 'trap "" TERM; sleep 30' &
CS_HARD=$!
cancel_stop "${CS_HARD}" 2 5
t_ok "a process that ignores TERM is force-stopped, and that is still confirmed" "$?"
wait "${CS_HARD}" 2>/dev/null

# The unconfirmed answer, which is the one that costs a checkout. Tested on the
# primitive rather than by inventing an unkillable process: the barrier's whole
# claim is that it answers what it observed within the window it was given.
sleep 30 &
CS_LIVE=$!
_cancel_wait_gone "${CS_LIVE}" 1
t_fails "a process that is still there when the window closes is not confirmed" "$?"
_cancel_wait_gone "${CS_LIVE}" 0
t_fails "and a window of zero is still an observation, not an assumption" "$?"
kill "${CS_LIVE}" 2>/dev/null
wait "${CS_LIVE}" 2>/dev/null
_cancel_wait_gone "${CS_LIVE}" 0
t_ok "the same call answers yes once the process has gone" "$?"

# And the same answer from the barrier itself, which is what `ORPHANED` is keyed
# on. There is no portable way to make a process outlive SIGKILL, so what is
# replaced is the observation and not the process: the signals really go to a
# child of this suite, and `cancel_stop` is asked about a target that never
# reads as gone. It has to say so rather than assume.
sleep 30 &
CS_STUB=$!
CS_SAVED_ALIVE=$(declare -f pid_alive)
pid_alive() { return 0; }
cancel_stop "${CS_STUB}" 1 1
t_fails "a target that outlives both windows is not confirmed stopped" "$?"
eval "${CS_SAVED_ALIVE}"
wait "${CS_STUB}" 2>/dev/null
pid_alive 0
t_fails "and the observation the suite borrowed is given back" "$?"

t_eq "the window off gives a runner outlasts the one the runner gives its engine" \
  1 "$([ "${CANCEL_RUNNER_GRACE_SEC}" -gt "$((CANCEL_GRACE_SEC + CANCEL_KILL_SEC))" ] && printf 1 || printf 0)"

# --- the workspace freeze ---------------------------------------------------
#
# A confirmed stop is the moment the working directory stops moving, so that is
# when it is digested. Everything after it is evidence *about* that state, and
# evidence about a workspace that has since moved is not evidence about this one
# (§13.2, §9.2 `QUIESCING`).

group 'the workspace freeze'

QF_WORK=${TMPROOT}/quiesce-work
mkdir -p "${QF_WORK}/src" "${QF_WORK}/.heinzel"
printf 'one\n' >"${QF_WORK}/src/a.txt"
printf 'two\n' >"${QF_WORK}/src/b.txt"

# The parenthesised case patterns are not decoration: bash 3.2 ends a $( )
# substitution at the first `)` of a pattern, so the leading paren is what makes
# these run at all on the stock macOS shell.
digest_shaped() { case $1 in (sha256:*|cksum:*) printf 1 ;; (*) printf 0 ;; esac; }

QF_D1=$(workspace_digest "${QF_WORK}")
t_eq "a digest is computed, and named by what computed it" \
  1 "$(digest_shaped "${QF_D1}")"
t_eq "reading the same tree twice gives the same answer" \
  "${QF_D1}" "$(workspace_digest "${QF_WORK}")"

printf 'one changed\n' >"${QF_WORK}/src/a.txt"
t_eq "content that changed changes it" \
  1 "$([ "${QF_D1}" = "$(workspace_digest "${QF_WORK}")" ] && printf 0 || printf 1)"
printf 'one\n' >"${QF_WORK}/src/a.txt"
t_eq "and content put back puts the digest back - it is content, not a clock" \
  "${QF_D1}" "$(workspace_digest "${QF_WORK}")"

printf 'scaffolding\n' >"${QF_WORK}/.heinzel/worksheet.md"
t_eq "the run's own worksheet is not somebody else's edit" \
  "${QF_D1}" "$(workspace_digest "${QF_WORK}")"

workspace_digest "${TMPROOT}/not-a-workdir" 2>/dev/null
t_fails "a workdir that is not there has no digest" "$?"

QF_RUN=r-20260902T080000-qsc001
runstore_init "${QF_RUN}"
QF_IDENT=$(claims_workspace_identity "${QF_WORK}")

t_eq "the first freeze is generation 1" \
  1 "$(quiesce_freeze "${QF_RUN}" "${QF_IDENT}" "${QF_WORK}")"
t_eq "and it froze what is actually there" "${QF_D1}" "$(quiesce_digest "${QF_RUN}")"
quiesce_unchanged "${QF_RUN}" "${QF_WORK}"
t_ok "evidence gathered now is about the frozen state" "$?"

printf 'somebody else was here\n' >"${QF_WORK}/src/c.txt"
quiesce_unchanged "${QF_RUN}" "${QF_WORK}"
t_fails "a tree that moved underneath invalidates it" "$?"

# A fix pass is a new writer under the same lease, so what it leaves is a new
# state to be evidence about - a new generation, not a second reading of the
# first one.
t_eq "re-freezing is the next generation, not the same one again" \
  2 "$(quiesce_freeze "${QF_RUN}" "${QF_IDENT}" "${QF_WORK}")"
quiesce_unchanged "${QF_RUN}" "${QF_WORK}"
t_ok "and evidence gathered after it is about the new state" "$?"
t_eq "the generation is readable on its own" 2 "$(quiesce_generation "${QF_RUN}")"

quiesce_unchanged "${QF_RUN}" "${TMPROOT}/gone-entirely"
t_fails "a workdir that has gone away is the largest change available" "$?"

# The store is allowed to fail and the run happens anyway, so a check that
# failed closed on a missing freeze would refuse the work of every run whose
# bookkeeping broke. This one fails open, deliberately and in one place.
QF_NOFREEZE=r-20260902T080000-qsc002
runstore_init "${QF_NOFREEZE}"
quiesce_unchanged "${QF_NOFREEZE}" "${QF_WORK}"
t_ok "a run with no frozen digest has no evidence to invalidate" "$?"
t_eq "and no generation either" 0 "$(quiesce_generation "${QF_NOFREEZE}")"

# The git half of the listing: a repository answers with HEAD and its status
# rather than with the bytes of its object store, and the answer is stable.
QF_REPO_D1=$(workspace_digest "${TEST_ROOT}")
t_eq "a git checkout digests, and digests the same way twice" \
  "${QF_REPO_D1}" "$(workspace_digest "${TEST_ROOT}")"
t_eq "and .git itself is never walked into - the answer is a digest, not a hang" \
  1 "$(digest_shaped "${QF_REPO_D1}")"

# --- verdict ---------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
