#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# tests/test.sh — the regression suite for the backlog ledger and the worksheet.
#
# One entry point (DESIGN §7): CI runs this file and nothing else. Everything
# here is pure shell against fixture files in a temp directory — no engine is
# called, no network is touched, and HEINZEL_HOME is redirected before
# lib/common.sh is sourced, so a test run cannot see, let alone write, the real
# ~/.heinzel.
#
# Stock /bin/bash 3.2: no associative arrays, no `mapfile`, no `${var^^}`.

set -uo pipefail

# CONTRIBUTING.md documents `--live` as the flag that additionally exercises the
# reviewer engine. Nothing here calls an engine yet, so the flag is refused
# rather than accepted and ignored: a contributor who ran it and saw a green
# suite would believe the reviewer had been exercised.
while [ $# -gt 0 ]; do
  case $1 in
    --live)
      printf 'tests/test.sh: --live is not implemented yet (no engine test exists)\n' >&2
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

# --- verdict ---------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
