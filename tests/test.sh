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

# `[ ... ]` on one line and `$?` on the next is the status of that condition -
# until somebody inserts a line between the two, when it silently becomes the
# status of whatever they inserted, and an assertion that reads as a check on
# the file is a check on the last `printf`. shellcheck names the shape (SC2319)
# and is right that it invites the mistake even where it has not made it. These
# two take the condition itself, so there is nothing in between to get it wrong.
# A compound condition cannot be passed as arguments; write those as an `if`.
t_true() { # name command...
  local name=$1
  shift
  "$@"
  t_ok "${name}" "$?"
}

t_false() { # name command...
  local name=$1
  shift
  "$@"
  t_fails "${name}" "$?"
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
# Every other function in this file is derived from these seven fields, so the
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
- [ ] (id:h-0002) (dir:paperclip-ops) a task for another checkout
- [ ] (dir:heinzel) routed before it has an id
- [ ] (id:h-0003) a (dir:...) that is not at the front stays in the text
- [!] (id:h-0005) blocked, with metadata <!-- blocked:2026-09-08T01:00:00+09:00 reason:needs a person run:20260908-010000 -->
FIXTURE

SCAN_ROW=$(backlog_scan "${SCAN_LEDGER}" | sed -n 2p)
t_eq "a row has seven fields" \
  7 "$(printf '%s\n' "${SCAN_ROW}" | awk -F'\t' '{print NF}')"
t_eq "an id-less row keeps an empty id field rather than shifting left" \
  "" "$(printf '%s' "${SCAN_ROW}" | cut -f4)"
t_eq "an id-less row keeps its text in field 5" \
  "a task the agent split off, with no id yet" \
  "$(printf '%s' "${SCAN_ROW}" | cut -f5)"
t_eq "and an empty workspace in field 6, meaning the default one" \
  "" "$(printf '%s' "${SCAN_ROW}" | cut -f6)"

# The routing comes off the front the way the id does, so what reaches the
# worksheet, the prompt and the ledger reads the way a person wrote it.
SCAN_DIR=$(backlog_scan "${SCAN_LEDGER}" | sed -n 3p)
t_eq "a (dir:) after the id is the workspace" \
  "paperclip-ops" "$(printf '%s' "${SCAN_DIR}" | cut -f6)"
t_eq "and is taken off the text, not left in it" \
  "a task for another checkout" "$(printf '%s' "${SCAN_DIR}" | cut -f5)"

# A person writes `(dir:x)` on a line with no id yet; the runner puts the id in
# front of it afterwards. Both orders have to parse, or a task routes correctly
# only after the run that numbered it.
SCAN_DIR_NOID=$(backlog_scan "${SCAN_LEDGER}" | sed -n 4p)
t_eq "a (dir:) on a line with no id is still the workspace" \
  "heinzel" "$(printf '%s' "${SCAN_DIR_NOID}" | cut -f6)"
t_eq "and that row still has an empty id field" \
  "" "$(printf '%s' "${SCAN_DIR_NOID}" | cut -f4)"

# Only a leading tag routes. Otherwise a task *about* the syntax reroutes
# itself by being written down.
SCAN_MID=$(backlog_scan "${SCAN_LEDGER}" | sed -n 5p)
t_eq "a (dir:) that is not at the front is text" \
  "" "$(printf '%s' "${SCAN_MID}" | cut -f6)"
t_eq "and stays in the text where it was written" \
  "a (dir:...) that is not at the front stays in the text" \
  "$(printf '%s' "${SCAN_MID}" | cut -f5)"

# The trailing comment is the whole of what a task records about itself, and it
# is field 7 rather than something every reader re-parses the line for. That
# second parse is exactly what fell behind: `ledger_blocked` carried its own
# copy, and when `backlog_scan` learned to take `(dir:)` off the text the copy
# did not, so the morning report showed a tag the ledger no longer considered
# part of the task.
SCAN_META=$(backlog_scan "${SCAN_LEDGER}" | sed -n 6p)
t_eq "the trailing comment is field 7" \
  "blocked:2026-09-08T01:00:00+09:00 reason:needs a person run:20260908-010000" \
  "$(printf '%s' "${SCAN_META}" | cut -f7)"
t_eq "and is not left in the text" \
  "blocked, with metadata" "$(printf '%s' "${SCAN_META}" | cut -f5)"
t_eq "a task with no comment has an empty field 7, not a missing one" \
  "" "$(printf '%s' "${SCAN_ROW}" | cut -f7)"

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
if [ "${MG_P1NEW}" -gt 0 ] && [ "${MG_P1NEW}" -lt "${MG_P2HEAD}" ]
then MG_INSERTED=0
else MG_INSERTED=1
fi
t_ok "a new task is inserted at the end of its own priority section" "${MG_INSERTED}"
t_true "a new P2 task lands under P2, not P1" [ "${MG_P2NEW}" -gt "${MG_P2HEAD}" ]

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

# --- the merge is one transition -------------------------------------------
#
# Six candidates used to be six rewrites of the ledger, each of them a truncate
# followed by a write. A crash between two of them left a ledger holding some of
# the run's work and not the rest — or half a line — while the receipt written
# afterwards described a ledger that had never existed (SPEC §11.4).
#
# Checked through the inode, which is what the difference actually is: a rename
# gives the name a new file and leaves the old one alone, so a reader holding
# the ledger it started with never sees it change under them. A file rewritten
# in place has one inode from beginning to end, and every intermediate state is
# visible through it.

group 'the merge is one ledger transition'

mg_fixture() { # ledger worksheet ids
  cat >"$1" <<'MGLED'
# Backlog

## P1
- [~] (id:h-0001) first <!-- run:20260901-030005 -->
- [~] (id:h-0002) second <!-- run:20260901-030005 -->
- [~] (id:h-0003) third <!-- run:20260901-030005 -->
MGLED
  cat >"$2" <<'MGWS'
# Worksheet

## P1
- [x] (id:h-0001) first
- [x] (id:h-0002) second
- [!] (id:h-0003) third <!-- reason:needs a decision -->
MGWS
  printf 'h-0001\nh-0002\nh-0003\n' >"$3"
}

MG_TDIR=${TMPROOT}/merge-transition
mkdir -p "${MG_TDIR}"
MG_TLED=${MG_TDIR}/backlog.md
MG_TWS=${MG_TDIR}/worksheet.md
MG_TIDS=${MG_TDIR}/ids.txt
mg_fixture "${MG_TLED}" "${MG_TWS}" "${MG_TIDS}"

# A second name for the file the merge starts with. Whatever the merge does to
# the ledger, this name still points at the bytes that were there when it began
# — unless the merge wrote through them.
MG_KEEP=${MG_TDIR}/as-it-was
ln "${MG_TLED}" "${MG_KEEP}"
MG_INO_BEFORE=$(stat -f '%i' "${MG_TLED}")
MG_WAS=$(cksum <"${MG_TLED}")

t_eq "three candidates are applied" \
  "2 1 0 0" "$(worksheet_merge "${MG_TWS}" "${MG_TLED}" "${MG_RUN}" "${MG_TIDS}")"
t_eq "and all three markers moved, not some of them" \
  "2 1 0" "$(printf '%s %s %s' "$(backlog_count "${MG_TLED}" x)" \
                               "$(backlog_count "${MG_TLED}" '!')" \
                               "$(backlog_count "${MG_TLED}" '~')")"

t_eq "the ledger is a new file, put there in one rename" \
  different \
  "$([ "$(stat -f '%i' "${MG_TLED}")" != "${MG_INO_BEFORE}" ] &&
     echo different || echo same)"
t_eq "so the file it replaced is intact, byte for byte" \
  "${MG_WAS}" "$(cksum <"${MG_KEEP}")"
rm -f "${MG_KEEP}"

# The mode comes from the ledger, not from mktemp: a ledger a person cannot
# read is not a ledger, and mktemp makes a private file.
mg_fixture "${MG_TLED}" "${MG_TWS}" "${MG_TIDS}"
chmod 644 "${MG_TLED}"
worksheet_merge "${MG_TWS}" "${MG_TLED}" "${MG_RUN}" "${MG_TIDS}" >/dev/null
t_eq "the ledger keeps its own mode across the transition" \
  644 "$(stat -f '%Lp' "${MG_TLED}")"

# A merge with nothing to apply leaves the file alone. A rename that only moved
# the mtime would make every no-op run look like a run that wrote something.
MG_INO_BEFORE=$(stat -f '%i' "${MG_TLED}")
printf 'h-9999\n' >"${MG_TIDS}"
t_eq "a merge with nothing in scope applies nothing" \
  "0 0 0 3" "$(worksheet_merge "${MG_TWS}" "${MG_TLED}" "${MG_RUN}" "${MG_TIDS}")"
t_eq "and does not replace the ledger at all" \
  same \
  "$([ "$(stat -f '%i' "${MG_TLED}")" = "${MG_INO_BEFORE}" ] &&
     echo same || echo different)"

# A ledger that cannot be written is refused before the copy is made, rather
# than after the steps have been installed and the markers computed.
mg_fixture "${MG_TLED}" "${MG_TWS}" "${MG_TIDS}"
printf 'h-0001\nh-0002\nh-0003\n' >"${MG_TIDS}"
chmod 444 "${MG_TLED}"
MG_RO=$(worksheet_merge "${MG_TWS}" "${MG_TLED}" "${MG_RUN}" "${MG_TIDS}" 2>/dev/null)
MG_ST=$?
chmod 644 "${MG_TLED}"
t_eq "a ledger that cannot be written applies nothing" "0 0 0 0" "${MG_RO}"
t_fails "and says so" "${MG_ST}"
t_eq "leaving every marker where it was" \
  "~" "$(backlog_marker_of_id "${MG_TLED}" h-0001)"

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
# The value of each name in FAKE_ENV_NAMES, in that order, NUL-separated, so a
# value holding a newline or an `=` is still one value. Indirect expansion
# rather than `env`: BSD env has no -0, and a line-per-variable dump could not
# say which newline was a separator.
if [ -n "${FAKE_ENV_FILE:-}" ]; then
  : >"${FAKE_ENV_FILE}"
  for _fake_n in ${FAKE_ENV_NAMES:-}; do
    printf '%s\0' "${!_fake_n-}" >>"${FAKE_ENV_FILE}"
  done
fi
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
FAKE_ENV_FILE=""
FAKE_ENV_NAMES=""
FAKE_LAST_FILE=""
FAKE_LAST_TEXT=""
FAKE_OUT_FILE=""
FAKE_ERR_FILE=""
FAKE_SLEEP=0
FAKE_RC=0
export FAKE_ARGV FAKE_ENV_FILE FAKE_ENV_NAMES FAKE_LAST_FILE FAKE_LAST_TEXT \
       FAKE_OUT_FILE FAKE_ERR_FILE FAKE_SLEEP FAKE_RC

fake_reset() {
  FAKE_ARGV=""
  FAKE_ENV_FILE=""
  FAKE_ENV_NAMES=""
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
  --output-format stream-json --verbose \
  --setting-sources user \
  --settings "${SETTINGS}" \
  --permission-mode dontAsk \
  --disallowedTools 'Bash(sudo *)' 'Bash(sudo)' \
  --model test-model --effort test-effort
t_false "a dry run starts no engine" [ -e "${AR_CE}/must-not-exist.argv" ]

AR_CR=${TMPROOT}/argv-claude-reviewer
dry_run claude reviewer "${AR_CR}"
# `--output-format json`, deliberately, where the executor streams: whether
# `--json-schema` survives being combined with `stream-json` is not known, and
# a reviewer whose schema was quietly dropped would return prose where the
# runner parses a verdict. This assertion is what holds the reviewer there.
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
  --output-format stream-json --verbose \
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
  --output-format stream-json --verbose \
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

# --- the claude executor's stream -------------------------------------------
#
# The executor is launched with --output-format stream-json, so its `raw` is
# one event per line as the run happens, and a person can `tail -f` it. Three
# fixed samples, because three things can be true of a stream: it finished, it
# finished saying the run failed, and it stopped in the middle. Fixed bytes on
# disk, never a real engine: none of this costs anything or needs a network.
#
# The reviewer is deliberately not in this group. It stays on the single-object
# `json` form, and the argv assertion above is what holds it there.

group 'claude stream-json (executor)'

STREAM_OK=${TMPROOT}/claude-stream-ok.jsonl
cat >"${STREAM_OK}" <<'STREAMOK'
{"type":"system","subtype":"init","session_id":"sess-stream","model":"test-model","tools":["Bash","Edit"]}
{"type":"assistant","session_id":"sess-stream","message":{"role":"assistant","content":[{"type":"text","text":"reading the worksheet"}]}}
{"type":"assistant","session_id":"sess-stream","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"tests/test.sh"}}]}}
{"type":"user","session_id":"sess-stream","message":{"role":"user","content":[{"type":"tool_result","content":"900 passed"}]}}
{"type":"result","subtype":"success","is_error":false,"session_id":"sess-stream","num_turns":4,"total_cost_usd":0.25,"usage":{"input_tokens":11,"output_tokens":22},"modelUsage":{"claude-opus-5":{"inputTokens":11},"claude-haiku-4-5":{"inputTokens":1}},"result":"first line\nsecond line"}
STREAMOK

RUN_SOK=${TMPROOT}/run-stream-ok
fake_reset
FAKE_OUT_FILE=${STREAM_OK}
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_SOK}" 60
t_status "a streamed run returns 0" 0 "$?"

# The whole point of the change: what is on disk is a line per event, not one
# object that appears only when the run is already over.
t_eq "raw is one JSON object per line, so tail -f has something to follow" \
  5 "$(grep -c . "${RUN_SOK}/raw")"
t_eq "and every line of it parses on its own" \
  5 "$(jq -c -s 'length' "${RUN_SOK}/raw")"

t_eq "the telemetry is read from the result line, not from the stream" \
  '{"verdict":"ok","session_id":"sess-stream","cost_usd":0.25,"turns":4,"tokens_in":11,"tokens_out":22,"models_used":["claude-haiku-4-5","claude-opus-5"]}' \
  "$(jq -c '{verdict, session_id, cost_usd, turns, tokens_in, tokens_out,
             models_used}' "${RUN_SOK}/result.json")"
t_eq "and the final message still lands in last.txt, as it did before" \
  "$(printf 'first line\nsecond line')" "$(cat "${RUN_SOK}/last.txt")"

STREAM_ERR=${TMPROOT}/claude-stream-error.jsonl
cat >"${STREAM_ERR}" <<'STREAMERR'
{"type":"system","subtype":"init","session_id":"sess-stream-err","model":"test-model"}
{"type":"assistant","session_id":"sess-stream-err","message":{"role":"assistant","content":[{"type":"text","text":"trying"}]}}
{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-stream-err","num_turns":2,"total_cost_usd":0.04,"usage":{"input_tokens":7,"output_tokens":3},"modelUsage":{"claude-opus-5":{"inputTokens":7}},"result":"could not finish"}
STREAMERR

RUN_SERR=${TMPROOT}/run-stream-error
fake_reset
FAKE_OUT_FILE=${STREAM_ERR}
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_SERR}" 60
t_status "a streamed run that failed still exits 0, as claude does" 0 "$?"
t_eq "but is_error on the result line is found, and the verdict is error" \
  '{"verdict":"error","exit_code":0,"attempt_outcome":"FAILED"}' \
  "$(jq -c '{verdict, exit_code, attempt_outcome}' "${RUN_SERR}/result.json")"
# A failed run still cost money, and it is the only record of what it cost.
t_eq "and what the failed run spent is still recorded" \
  '{"session_id":"sess-stream-err","cost_usd":0.04,"turns":2}' \
  "$(jq -c '{session_id, cost_usd, turns}' "${RUN_SERR}/result.json")"

# Cut off in the middle: no result line at all, and the last line half written,
# which is exactly what a run killed at the deadline leaves behind. `jq -s`
# rejects the whole file on that line; a reader that stopped there would throw
# away the complete events before it.
STREAM_CUT=${TMPROOT}/claude-stream-cut.jsonl
cat >"${STREAM_CUT}" <<'STREAMCUT'
{"type":"system","subtype":"init","session_id":"sess-cut","model":"test-model"}
{"type":"assistant","session_id":"sess-cut","message":{"role":"assistant","content":[{"type":"text","text":"halfway through"}]}}
STREAMCUT
printf '%s' '{"type":"assistant","session_id":"sess-cut","message":{"role":"assi' \
  >>"${STREAM_CUT}"

RUN_SCUT=${TMPROOT}/run-stream-cut
fake_reset
FAKE_OUT_FILE=${STREAM_CUT}
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RUN_SCUT}" 60
t_status "a stream that stopped in the middle is still normalised" 0 "$?"
t_eq "the half-written line does not take the parsed ones with it" \
  sess-cut "$(jq -r '.session_id' "${RUN_SCUT}/result.json")"
# Nothing reported a cost, a turn count or a final message, and the record says
# so rather than inventing a zero-dollar success.
t_eq "with nothing reported reported as nothing, not as zero spend" \
  '{"cost_usd":null,"turns":0,"tokens_in":0,"tokens_out":0,"text":""}' \
  "$(jq -c '{cost_usd, turns, tokens_in, tokens_out, text}' \
      "${RUN_SCUT}/result.json")"
# Byte count, not `$(cat ...)`: command substitution strips trailing newlines,
# so a file holding one blank line would read as empty and pass.
t_eq "and last.txt is empty, because there was no final message" \
  0 "$(wc -c <"${RUN_SCUT}/last.txt" | tr -d ' ')"

# The reviewer's single object is read by the same reader, and a pretty-printed
# one spread over several lines still parses. This is the shape every claude
# record written before this release has, so it is not only the reviewer's.
t_eq "the single-object form is still read, however many lines it is on" \
  '{"session_id":"sess-1","cost_usd":0.25,"turns":4,"tokens_in":11,"tokens_out":22,"text":"first line\nsecond line"}' \
  "$(_engine_result_claude "${CLAUDE_OK_RAW}" |
     jq -c '{session_id, cost_usd, turns, tokens_in, tokens_out, text}')"

# --- what reaches runs.jsonl -----------------------------------------------
#
# `cost_usd` in the run record is projected out of the engine's result.json by
# bin/hzl-run. The projection is replicated here rather than by running a whole
# night, and pinned to the runner's source below, so the replica cannot quietly
# stop being what the runner does.

runs_jsonl_cost() { # result.json -> the value the run record would carry
  jq -n -c --slurpfile engine_result "$1" \
    '$engine_result[0].cost_usd // null'
}

t_eq "a completed run's cost reaches the run record" \
  0.25 "$(runs_jsonl_cost "${RUN_SOK}/result.json")"
t_eq "so does a failed one's, which is still money spent" \
  0.04 "$(runs_jsonl_cost "${RUN_SERR}/result.json")"
t_eq "and a run that reported none carries null, not 0" \
  null "$(runs_jsonl_cost "${RUN_SCUT}/result.json")"
t_eq "codex, which has no USD telemetry at all, carries null too" \
  null "$(runs_jsonl_cost "${RUN_XE}/result.json")"

t_eq "the runner still projects that field from the engine result" \
  1 "$(grep -cF 'cost_usd: ($engine_result[0].cost_usd // null),' \
        "${TEST_ROOT}/bin/hzl-run")"

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
t_false "leaving no result.json to be mistaken for a run" [ -e "${RT_OUT}/result.json" ]

# The same refusal, in a directory a previous run already succeeded in. The
# records of that run are cleared before anything is launched, so a launch that
# never reaches the backend cannot be read as the old run happening again.
RT_REUSE=${TMPROOT}/runtime-reused
fake_reset
FAKE_OUT_FILE=${CLAUDE_OK_RAW}
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RT_REUSE}" 60
t_status "the first run in the directory succeeds" 0 "$?"
t_eq "and leaves a collected.json behind" \
  ok "$(jq -r '.verdict' "${RT_REUSE}/result.json")"

HEINZEL_RUNTIME=herdr engine_run claude executor "${RUN_WORK}" \
  "${RUN_PROMPT}" "${RT_REUSE}" 60 2>/dev/null
t_fails "a second run that never starts fails" "$?"
t_false "the previous run's collected.json is gone, not waiting to be reread" \
  [ -e "${RT_REUSE}/collected.json" ]
t_false "and no result.json survives to report the old run as this one" \
  [ -e "${RT_REUSE}/result.json" ]

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
t_false "the temp file it renamed from is gone" [ -e "${RT_DIR}/collected.json.tmp" ]

# A launch environment is carried, not refused: the backend passes a validated
# env as `env KEY=VALUE ... command` (RUNTIME-BACKENDS §8.4). The values are
# read back out of the process NUL-separated, for the same reason the argv is —
# one of them holds a newline and an `=`, and a line-per-variable dump could not
# say which newline was a separator.
RT_ENVD=${TMPROOT}/runtime-env.dump
fake_reset
FAKE_ENV_FILE=${RT_ENVD}
FAKE_ENV_NAMES='HZL_TEST_ONE HZL_TEST_TWO'
jq '.env = {"HZL_TEST_ONE": "a value with spaces",
            "HZL_TEST_TWO": "two\nlines = one value"}' \
  "${RT_DIR}/launch.json" >"${RT_DIR}/env-launch.json"
runtime_run_batch local "${RT_DIR}/env-launch.json" "${RT_RUN}" \
  "${RT_DIR}/env-collected.json"
t_status "a launch that carries an environment runs" 0 "$?"
t_argv "and the process is given each value whole" "${RT_ENVD}" \
  'a value with spaces' 'two
lines = one value'

# What a process cannot be given is refused at the spec, before anything is
# started. NUL is not representable in an OS argv or environ entry, and it is
# the delimiter the restore uses: an argument holding one would arrive as two.
fake_reset
FAKE_ARGV=${RT_DIR}/must-not-exist.argv
jq '.argv += [("x" + ([0] | implode) + "y")]' "${RT_DIR}/launch.json" \
  >"${RT_DIR}/nul-argv-launch.json"
runtime_run_batch local "${RT_DIR}/nul-argv-launch.json" "${RT_RUN}" \
  "${TMPROOT}/never.json" 2>/dev/null
t_fails "an argv holding a NUL byte is refused, not silently split in two" "$?"
t_false "and nothing was started" [ -e "${FAKE_ARGV}" ]

jq '.env = {"HZL_TEST_ONE": ("x" + ([0] | implode) + "y")}' \
  "${RT_DIR}/launch.json" >"${RT_DIR}/nul-env-launch.json"
runtime_run_batch local "${RT_DIR}/nul-env-launch.json" "${RT_RUN}" \
  "${TMPROOT}/never.json" 2>/dev/null
t_fails "an environment value holding a NUL byte is refused too" "$?"

jq '.env = {"HZL TEST": "x"}' "${RT_DIR}/launch.json" \
  >"${RT_DIR}/bad-name-launch.json"
runtime_run_batch local "${RT_DIR}/bad-name-launch.json" "${RT_RUN}" \
  "${TMPROOT}/never.json" 2>/dev/null
t_fails "a name env could not set is refused, not folded into a value" "$?"

jq '.env = {"HZL_TEST_ONE": 3}' "${RT_DIR}/launch.json" \
  >"${RT_DIR}/bad-value-launch.json"
runtime_run_batch local "${RT_DIR}/bad-value-launch.json" "${RT_RUN}" \
  "${TMPROOT}/never.json" 2>/dev/null
t_fails "and so is a value that is not a string" "$?"

t_false "no refused launch left a collected record behind" [ -e "${TMPROOT}/never.json" ]
fake_reset

# --- which backend a run goes to -------------------------------------------
#
# The session's, not this process's environment. A run starts at 03:00 from
# launchd, which passes a minimal environment and none of ours: `HEINZEL_RUNTIME`
# read there could only ever say `local`, whatever `hzl on` recorded, and the
# run would then write down a backend it had not used (SPEC §9.0).
#
# The state file is absent here and is put back that way at the end of the
# block: the schema group below writes its own fixture and expects to find
# nothing in the way.

group 'the backend a run goes to'

t_eq "with no session, the environment names the backend" \
  herdr "$(HEINZEL_RUNTIME=herdr runtime_selected)"
t_eq "and with neither, it is local" local "$(runtime_selected)"

printf '{"mode":"heinzel","runtime_backend":"herdr"}\n' >"${STATE_FILE}"
t_eq "a session that recorded one is the one that answers" \
  herdr "$(runtime_selected)"
t_eq "and the environment does not overrule it" \
  herdr "$(HEINZEL_RUNTIME=local runtime_selected)"

RT_FS=${TMPROOT}/runtime-from-state
fake_reset
FAKE_ARGV=${RT_FS}/must-not-exist.argv
engine_run claude executor "${RUN_WORK}" "${RUN_PROMPT}" "${RT_FS}" 60 2>/dev/null
t_fails "and a run goes there, so an unregistered one fails the run" "$?"
t_false "without starting anything here instead" [ -e "${FAKE_ARGV}" ]

# The other direction, which is the one the environment could get wrong: a
# session that recorded `local` runs here even when the environment asks for a
# backend this build does not have.
printf '{"mode":"heinzel","runtime_backend":"local"}\n' >"${STATE_FILE}"
RT_FS2=${TMPROOT}/runtime-from-state-local
fake_reset
FAKE_OUT_FILE=${CLAUDE_OK_RAW}
HEINZEL_RUNTIME=herdr engine_run claude executor "${RUN_WORK}" \
  "${RUN_PROMPT}" "${RT_FS2}" 60
t_status "a session that recorded local runs, whatever the environment says" \
  0 "$?"
t_eq "and the result names the backend it was actually run on" \
  local "$(jq -r '.backend' "${RT_FS2}/result.json")"

# A session recorded before the field existed is a v1 file, and v1 means local
# (§13.7). The environment does not get to speak for it either: there is a
# session, and it answered.
printf '{"mode":"heinzel"}\n' >"${STATE_FILE}"
t_eq "a session from before the field existed answers local" \
  local "$(HEINZEL_RUNTIME=herdr runtime_selected)"

rm -f "${STATE_FILE}"
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

# --- when a run is allowed to happen ---------------------------------------
#
# The schedule is one value, `HEINZEL_HOURS`, and everything that asks "when"
# derives from it: the plist `hzl install` writes, the runner's window guard,
# and the count of slots left before a session expires. `all` means every hour —
# a session that is on may be allowed to work whenever it is on — and it has to
# be expanded in one place, or the three answers drift apart.

group 'the schedule'

# The defaults without this machine's own etc/heinzel.conf: `hzl_load_conf` sets
# every default before it reads the file, so a root with no file in it is the
# cheapest way to get a whole valid configuration in here.
SC_ROOT=${TMPROOT}/sched-root
mkdir -p "${SC_ROOT}/etc"
sc_validate() { # hours [gap] -> the validator's status
  (
    # The suite sets marker model and effort values for the argv assertions,
    # and `hzl_load_conf` lets the environment win for those keys — cleared
    # here, or every schedule below would be invalid for a reason that has
    # nothing to do with the schedule.
    HEINZEL_MODEL="" HEINZEL_EFFORT=""
    HEINZEL_CODEX_MODEL="" HEINZEL_CODEX_EFFORT=""
    HEINZEL_ROOT=${SC_ROOT}
    hzl_load_conf >/dev/null 2>&1
    HEINZEL_HOURS=$1
    [ -n "${2:-}" ] && HEINZEL_MIN_RUN_GAP_SEC=$2
    hzl_validate_conf >/dev/null 2>&1
  )
}

HEINZEL_HOURS="5 1 3 1"
t_eq "a list is normalised, de-duplicated and ascending" \
  "1 3 5" "$(hours_normalised)"
t_fails "and is not every hour" "$(hours_is_all; echo $?)"
t_eq "which is what a person is shown" "1 3 5" "$(hours_display)"

HEINZEL_HOURS="all"
t_ok "all is every hour" "$(hours_is_all; echo $?)"
t_eq "and expands to twenty-four of them, for the plist and the guard alike" \
  "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23" \
  "$(hours_normalised)"
t_eq "a person is told it in three words, not twenty-four numbers" \
  "every hour" "$(hours_display)"
t_ok "so no hour of the day is outside the window" "$(in_window; echo $?)"
t_eq "and every hour before a deadline is a slot" \
  2 "$(slots_within $(( $(now_epoch) + 7300 )))"

# The hour the guard compares against is the hour it is, not the hour the
# schedule was written for.
HEINZEL_HOURS="$(date +%H | sed 's/^0//;s/^$/0/')"
t_ok "the current hour is in a window that names it" "$(in_window; echo $?)"
HEINZEL_HOURS="$(( ($(date +%H | sed 's/^0//;s/^$/0/') + 12) % 24 ))"
t_fails "and twelve hours from now is not" "$(in_window; echo $?)"

sc_validate "1 2 3 4 5"
t_ok "a list of hours is a valid schedule" "$?"
sc_validate "all"
t_ok "and so is all" "$?"
sc_validate "24"
t_fails "an hour that is not an hour is refused" "$?"
sc_validate "all 7"
t_fails "and all is the whole value or none of it" "$?"

# `*` cannot survive being read: the value is split with an unquoted expansion,
# so it would become the names of the files in whatever directory the reader
# happened to be in. Refused by name, rather than left to fail later as
# "HEINZEL_HOURS: 'CHANGELOG.md' is not an integer".
sc_validate "*"
t_fails "a glob is refused" "$?"
SC_ERR=${TMPROOT}/sched-err.txt
(
  HEINZEL_MODEL="" HEINZEL_EFFORT=""
  HEINZEL_ROOT=${SC_ROOT}
  hzl_load_conf >/dev/null 2>&1
  HEINZEL_HOURS="*"
  hzl_validate_conf
) >/dev/null 2>"${SC_ERR}"
t_has "and the message gives the spelling that works" "${SC_ERR}" "write 'all'"

sc_validate "1 2 3" "notanumber"
t_fails "a gap that is not a number of seconds is refused" "$?"
sc_validate "1 2 3" "0"
t_ok "and zero is, because zero turns it off" "$?"

unset HEINZEL_HOURS

# --- the next slot, as a time ----------------------------------------------
#
# `hours_normalised` is the shape of the schedule; `next_slot_epoch` is the
# question a person actually asks, and `hzl schedule` and `hzl status` both
# print its answer. The two properties worth pinning are that the slot it
# names is one the schedule names, and that asking again from a slot moves
# forward - the "then" list in `hzl schedule` walks it in a loop and would not
# terminate otherwise.

group 'the next slot'

HEINZEL_HOURS="2 9 17"
NS_NOW=$(now_epoch)
NS=$(next_slot_epoch "${NS_NOW}")
t_ok "a slot is found" "$?"
NS_H=$(date -r "${NS}" +%H | sed 's/^0//;s/^$/0/')
ns_scheduled() { # hour -> 0 when the schedule names it
  local h
  for h in $(hours_normalised); do
    [ "${h}" -eq "$1" ] && return 0
  done
  return 1
}
t_true "and it falls on an hour the schedule names" ns_scheduled "${NS_H}"
t_eq "on the hour itself, because that is when launchd fires" \
  "00" "$(date -r "${NS}" +%M)"
t_true "it is in the future" [ "${NS}" -gt "${NS_NOW}" ]
t_true "and inside the next day, because the schedule repeats daily" \
  [ $((NS - NS_NOW)) -le 86400 ]

NS2=$(next_slot_epoch "${NS}")
t_true "asking again from a slot gives a later one, never that same slot" \
  [ "${NS2}" -gt "${NS}" ]

HEINZEL_HOURS="all"
NS_NOW=$(now_epoch)
NS=$(next_slot_epoch "${NS_NOW}")
t_eq "with every hour scheduled the next slot is the top of the next hour" \
  "00:00" "$(date -r "${NS}" +%M:%S)"
t_true "which is at most an hour away" [ $((NS - NS_NOW)) -le 3600 ]

# The minutes and seconds already spent are subtracted with arithmetic, so a
# leading zero must not be read as octal - 09:09:09 is the shape that breaks a
# `$((10#))`-less implementation, and it breaks it silently, on eight minutes
# of every hour.
HEINZEL_HOURS="10"
NS_ODD=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 09:09:09" +%s)
t_eq "a from-time with leading-zero minutes and seconds is arithmetic, not octal" \
  "10:00:00" "$(date -r "$(next_slot_epoch "${NS_ODD}")" +%H:%M:%S)"

unset HEINZEL_HOURS

# --- how long until then ---------------------------------------------------

group 'a distance a person reads'

t_eq "under a minute is said in words - 'in 0m' reads like a stopped clock" \
  "in under a minute" "$(rel_dur 59)"
t_eq "a minute is a minute" "in 1m" "$(rel_dur 60)"
t_eq "minutes alone, below the hour" "in 5m" "$(rel_dur 300)"
t_eq "hours and minutes, rounded down to the minute" \
  "in 3h 47m" "$(rel_dur $((3 * 3600 + 47 * 60 + 59)))"
t_eq "days and hours, and no minutes: nobody reads the third unit" \
  "in 2d 3h" "$(rel_dur $((2 * 86400 + 3 * 3600 + 59 * 60)))"

# --- several working directories -------------------------------------------
#
# `DEFAULT_WORKDIR` holds one path per line. One line is one workspace, which
# is what every configuration written before this was, and several lines are
# several - so the first thing asserted is that a single-line value has not
# changed meaning, including one with a space in it. The separator is a newline
# for exactly that reason: a space-separated list would halve such a path at
# 03:00 and the run would fail on a directory nobody wrote.

group 'the workspace list'

WS_SAVED=${DEFAULT_WORKDIR:-}

DEFAULT_WORKDIR="/Users/x/Claude/heinzel"
t_eq "one path is one workspace" 1 "$(workdirs_count)"
t_eq "and it is the default" "/Users/x/Claude/heinzel" "$(workdir_default)"
t_eq "named by its last path component" "heinzel" "$(workdir_name "$(workdir_default)")"

DEFAULT_WORKDIR="/Users/x/My Code/thing"
t_eq "a single path keeps a space, because the separator is a newline" \
  "/Users/x/My Code/thing" "$(workdir_default)"
t_eq "and is still one workspace" 1 "$(workdirs_count)"

DEFAULT_WORKDIR="/Users/x/Claude/heinzel
  /Users/x/Claude/paperclip-ops

/Users/x/other  "
t_eq "several lines are several workspaces" 3 "$(workdirs_count)"
t_eq "a blank line is not one of them" \
  "/Users/x/other" "$(workdirs_list | sed -n 3p)"
t_eq "indentation is not part of a path" \
  "/Users/x/Claude/paperclip-ops" "$(workdirs_list | sed -n 2p)"
t_eq "and neither is a trailing space" \
  "/Users/x/other" "$(workdirs_list | sed -n 3p)"
t_eq "the first line is the default, whatever sorts first" \
  "/Users/x/Claude/heinzel" "$(workdir_default)"
t_eq "the names are the last components, in configuration order" \
  "heinzel paperclip-ops other" "$(workdir_names_of "$(workdirs_list)")"

t_eq "a name resolves to its path" \
  "/Users/x/Claude/paperclip-ops" "$(workdir_of_name paperclip-ops)"
t_fails "a name nobody configured resolves to nothing" \
  "$(workdir_of_name nosuch >/dev/null 2>&1; echo $?)"

# The lookup the runner makes is against the *session's* set, not against
# whatever `heinzel.conf` says this morning: a session started last night keeps
# the workspaces it was started with.
t_eq "a name resolves within a given set" \
  "/tmp/b" "$(workdir_path_in b "/tmp/a
/tmp/b")"
t_fails "and not outside it, even when the configuration has it" \
  "$(workdir_path_in heinzel "/tmp/a
/tmp/b" >/dev/null 2>&1; echo $?)"

# --- what a person is shown ------------------------------------------------

t_eq "one workspace is shown as the path it is" \
  "/Users/x/Claude/heinzel" "$(workdirs_display "/Users/x/Claude/heinzel")"
t_eq "several are shown by name, default first and marked" \
  "heinzel (default), paperclip-ops" \
  "$(workdirs_display "/Users/x/Claude/heinzel
/Users/x/Claude/paperclip-ops")"
t_eq "and none is said, not shown as an empty line" \
  "unset" "$(workdirs_display "")"

# `abspath` prints without a trailing newline because every other caller takes
# it in a `$( )`. Here the newline is the separator, and without it two
# workspaces come out as one impossible path - which shows up first as an allow
# rule that matches nothing, which is silent.
ABS_TWO=$(abspath_lines "${TMPROOT}/one
${TMPROOT}/two")
t_eq "abspath over a list keeps the entries apart" 2 "$(printf '%s\n' "${ABS_TWO}" | grep -c .)"
t_eq "and resolves each of them the way abspath does" \
  "$(abspath "${TMPROOT}/two")" "$(printf '%s\n' "${ABS_TWO}" | sed -n 2p)"

# --- what the configuration will not accept --------------------------------
#
# Shape only, and deliberately not existence: this runs before every command,
# and a checkout on an unmounted disk must not stop `hzl status` answering.

ws_validate() { # value
  (
    # The same clearing `sc_validate` does, and for the same reason: the suite
    # sets marker model and effort values for the argv assertions, and every
    # list below would otherwise be invalid for a reason that has nothing to do
    # with workspaces.
    HEINZEL_MODEL="" HEINZEL_EFFORT=""
    HEINZEL_CODEX_MODEL="" HEINZEL_CODEX_EFFORT=""
    HEINZEL_ROOT=${SC_ROOT}
    hzl_load_conf >/dev/null 2>&1
    DEFAULT_WORKDIR=$1
    hzl_validate_conf >/dev/null 2>&1
  )
}

ws_validate "/Users/x/a
/Users/x/b"
t_ok "two absolute paths are a valid list" "$?"
ws_validate ""
t_ok "and so is none, because a fresh install has none yet" "$?"
ws_validate "Claude/heinzel"
t_fails "a relative path is refused - launchd runs with cwd=/" "$?"
ws_validate "/Users/x/a
/Users/y/a"
t_fails "and so are two workspaces with the same name" "$?"
WS_ERR=${TMPROOT}/ws-err.txt
(
  HEINZEL_MODEL="" HEINZEL_EFFORT=""
  HEINZEL_CODEX_MODEL="" HEINZEL_CODEX_EFFORT=""
  HEINZEL_ROOT=${SC_ROOT}
  hzl_load_conf >/dev/null 2>&1
  DEFAULT_WORKDIR="/Users/x/a
/Users/y/a"
  hzl_validate_conf
) >/dev/null 2>"${WS_ERR}"
t_has "and the message says which name is ambiguous" "${WS_ERR}" "(dir:a) could mean either"

# --- which workspace a task belongs to -------------------------------------

group 'routing a task to a workspace'

DEFAULT_WORKDIR="/Users/x/Claude/heinzel
/Users/x/Claude/paperclip-ops"

t_eq "a task with no (dir:) belongs to the default workspace" \
  "heinzel" "$(task_workspace_name "")"
t_eq "and one with a (dir:) belongs to that one" \
  "paperclip-ops" "$(task_workspace_name paperclip-ops)"

WS_LEDGER=${TMPROOT}/ws-backlog.md
cat >"${WS_LEDGER}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) (dir:paperclip-ops) the highest-priority task
- [ ] (id:h-0002) an untagged task, so the default workspace
## P2
- [ ] (id:h-0003) (dir:paperclip-ops) another for paperclip
- [ ] (id:h-0004) (dir:heinzel) one named explicitly
FIXTURE

# The order of attack picks the task and the workspace follows from it: one
# queue, and the highest-priority task decides where the night starts.
t_eq "the next run's workspace is the top task's" \
  "paperclip-ops" "$(backlog_next_workspace "${WS_LEDGER}")"

WS_OUT=${TMPROOT}/ws-worksheet.md
WS_IDS=$(worksheet_write "${WS_LEDGER}" 9 "${WS_OUT}" paperclip-ops)
t_eq "a worksheet for one workspace holds only that workspace's tasks" \
  "h-0001 h-0003" "$(printf '%s\n' "${WS_IDS}" | tr '\n' ' ' | sed 's/ $//')"
t_lacks "and names none of the others" "${WS_OUT}" "h-0002"

# An engine launch has one working directory, so a worksheet spanning two would
# list tasks the agent could not reach half of. The per-run limit therefore
# counts within the workspace, not across the queue.
WS_IDS=$(worksheet_write "${WS_LEDGER}" 1 "${WS_OUT}" paperclip-ops)
t_eq "the per-run limit counts within the workspace" "h-0001" "${WS_IDS}"

WS_IDS=$(worksheet_write "${WS_LEDGER}" 9 "${WS_OUT}" heinzel)
t_eq "an untagged task lands in the default workspace's worksheet" \
  "h-0002 h-0004" "$(printf '%s\n' "${WS_IDS}" | tr '\n' ' ' | sed 's/ $//')"

# No workspace named is the whole queue, which is what every caller before this
# asked for and what a one-workspace configuration still means.
WS_IDS=$(worksheet_write "${WS_LEDGER}" 9 "${WS_OUT}")
t_eq "with no workspace named the worksheet is the whole queue" \
  4 "$(printf '%s\n' "${WS_IDS}" | grep -c .)"

# --- when the ledger is not in English -------------------------------------
#
# BSD awk under a UTF-8 locale reports two different multibyte strings as
# equal. Measured 2026-09-08 on this machine:
#
#     printf 'a\tログイン\nb\tデフォルト\n' |
#       awk -F'\t' -v t=デフォルト '$2 == t {print $1}'
#     a
#     b            <- both rows, for a value equal to one of them
#
# `LC_ALL=C` compares bytes and gets it right, and byte equality is exactly
# what every comparison in this program wants — nothing here sorts or folds
# case on task text. The bug is invisible while the ledger is in English,
# which this one is not, so the regression is pinned on a Japanese workspace
# name: routing every task to the first checkout in the list is silent, and
# the run that goes wrong is a night's work in the wrong tree.

JP_LED=${TMPROOT}/jp-backlog.md
cat >"${JP_LED}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) (dir:あかり) 明かりを直す
- [ ] (id:h-0002) (dir:みどり) 緑を直す
FIXTURE
(
  DEFAULT_WORKDIR="/Users/x/あかり
/Users/x/みどり"
  JP_OUT=${TMPROOT}/jp-worksheet.md
  t_eq "a worksheet for a Japanese workspace name holds only that workspace" \
    "h-0002" "$(worksheet_write "${JP_LED}" 9 "${JP_OUT}" みどり)"
  t_eq "and the other name still selects the other task" \
    "h-0001" "$(worksheet_write "${JP_LED}" 9 "${JP_OUT}" あかり)"
  printf '%s %s\n' "${PASS}" "${FAIL}" >"${TMPROOT}/jp-counts"
)
# The assertions above ran in a subshell so that DEFAULT_WORKDIR could be set
# without disturbing the group below; the counters they moved have to be
# carried back out or the run would report two fewer than it made.
PASS=$(cut -d' ' -f1 "${TMPROOT}/jp-counts")
FAIL=$(cut -d' ' -f2 "${TMPROOT}/jp-counts")

# --- a task the agent split off ---------------------------------------------
#
# A follow-up written inside one checkout has to come back to it. Without the
# tag it would be queued against whichever workspace happens to be first in
# `DEFAULT_WORKDIR`, and the next run would hand the agent a task about a tree
# it is not standing in.

t_eq "a task written in a non-default workspace is tagged with it" \
  "(dir:paperclip-ops) " "$(task_route_prefix paperclip-ops)"
t_eq "one written in the default workspace is not, because untagged means that" \
  "" "$(task_route_prefix heinzel)"
t_eq "and a name no configuration knows routes nothing at all" \
  "" "$(task_route_prefix somewhere-else)"

# The name comes from where the worksheet lives, because the merge is reached
# through four callers and the recovery path has only the files a dead run
# wrote.
t_eq "a worksheet names the workspace it was written in" \
  "paperclip-ops" "$(worksheet_workspace "/Users/x/Claude/paperclip-ops/.heinzel/worksheet.md")"

WS_MG_LED=${TMPROOT}/ws-merge-ledger.md
cat >"${WS_MG_LED}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) (dir:paperclip-ops) the claimed task
FIXTURE
WS_MG_DIR=${TMPROOT}/ws-merge/paperclip-ops/.heinzel
mkdir -p "${WS_MG_DIR}"
cat >"${WS_MG_DIR}/worksheet.md" <<'FIXTURE'
# Worksheet

## P1
- [x] (id:h-0001) the claimed task
- [ ] something else this checkout needs
FIXTURE
printf 'h-0001\n' >"${TMPROOT}/ws-merge-ids.txt"
(
  # The workspace has to be a configured one for the tag to be written, and
  # its path has to be the one the worksheet sits under.
  DEFAULT_WORKDIR="/Users/x/Claude/heinzel
${TMPROOT}/ws-merge/paperclip-ops"
  worksheet_merge "${WS_MG_DIR}/worksheet.md" "${WS_MG_LED}" run-1 \
    "${TMPROOT}/ws-merge-ids.txt"
) >/dev/null
t_has "a new task keeps the workspace it was written in" \
  "${WS_MG_LED}" "(dir:paperclip-ops) something else this checkout needs"

# --- a session started by an older build -----------------------------------
#
# `state.json` carried a single `.workdir` before this. It has to read as the
# one-workspace list it describes, or a session started last night loses its
# working directory when this build's runner picks it up at 03:00.

WS_STATE=${TMPROOT}/ws-state.json
printf '{"mode":"heinzel","workdir":"/Users/x/only"}\n' >"${WS_STATE}"
t_eq "a state file with .workdir and no .workdirs reads as one workspace" \
  "/Users/x/only" "$(STATE_FILE=${WS_STATE} state_get_workdirs)"
printf '{"mode":"heinzel","workdir":"/a","workdirs":["/a","/b"]}\n' >"${WS_STATE}"
t_eq "and one with .workdirs reads all of them, in the order it recorded" \
  "/a /b" "$(STATE_FILE=${WS_STATE} state_get_workdirs | tr '\n' ' ' | sed 's/ $//')"

DEFAULT_WORKDIR=${WS_SAVED}
unset WS_SAVED WS_LEDGER WS_OUT WS_IDS WS_ERR ABS_TWO WS_MG_LED WS_MG_DIR WS_STATE

# --- the minimum gap between runs ------------------------------------------
#
# What is left of the window guard when the window is every hour: `all` makes
# `in_window` always true, and the burst it was there to stop — every slot the
# machine slept through, firing at once on wake — is inside the window again.
# The gap is measured from the last run that actually ran, so an hourly
# schedule never reaches it and a replay of six missed slots runs one.

group 'the minimum gap between runs'

SC_RUNS_SAVED=${RUNS_JSONL}
RUNS_JSONL=${TMPROOT}/sched-runs.jsonl
rm -f "${RUNS_JSONL}"
last_run_started_epoch >/dev/null 2>&1
t_fails "with no record at all there is no last run" "$?"

printf '%s\n' '{"run_id":"20260907-010000","started_at_epoch":1757000000}' \
  >"${RUNS_JSONL}"
t_eq "the record says when the last run started" \
  1757000000 "$(last_run_started_epoch)"

printf '%s\n' '{"run_id":"20260907-020000","started_at_epoch":1757003600}' \
  >>"${RUNS_JSONL}"
t_eq "and it is the last line, because the file is appended to" \
  1757003600 "$(last_run_started_epoch)"

# A half-written record is not a time. The same care `last_run_json` takes in
# `bin/hzl`, for the same reason: a torn line that parsed as something would be
# worse than one that parses as nothing.
printf '%s\n' '{"run_id":"20260907-03000' >>"${RUNS_JSONL}"
last_run_started_epoch >/dev/null 2>&1
t_fails "a record torn by an interrupted append is not a time" "$?"

printf '%s\n' '{"run_id":"20260907-040000","started_at_epoch":"soon"}' \
  >"${RUNS_JSONL}"
last_run_started_epoch >/dev/null 2>&1
t_fails "and neither is a record whose epoch is not a number" "$?"

# What makes the gap a gap between runs rather than between wake-ups: a run
# stopped at a gate exits before the record is written, so a skipped slot does
# not push the next one further out.
t_eq "the skip path writes no run record" \
  0 "$(awk '/^skip\(\) \{/,/^\}/' "${TEST_ROOT}/bin/hzl-run" | grep -c 'RUNS_JSONL')"

# And the gate is not applied to a run a person asked for: `hzl run-now` means
# now. Structural, because the suite does not drive `bin/hzl-run` end to end.
t_eq "both schedule gates let a manual run through" \
  2 "$(grep -c '\[ "${TRIGGER}" != manual \]' "${TEST_ROOT}/bin/hzl-run")"

RUNS_JSONL=${SC_RUNS_SAVED}
unset SC_ROOT SC_ERR SC_RUNS_SAVED

group 'schema constants'

# Each of the three is handed straight to `jq --argjson`, where an unset or
# non-numeric value is not a wrong version but a jq error — and the run record
# is appended with stderr discarded, so the row would simply not be written.
_sc=
for _sc_name in HEINZEL_STATE_SCHEMA HEINZEL_RESULT_SCHEMA \
                HEINZEL_RUN_RECORD_SCHEMA; do
  # Through eval because the name is the loop variable, and shellcheck cannot
  # see an assignment made that way - hence the declaration above the loop.
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
t_eq "and predates the mode split, so it reads as work" \
  work "$(session_operating_mode)"

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

# The same file with the fields `hzl work` now writes.
jq '. + {schema_version: 3, runtime_backend: "local", operating_mode: "work"}' "${V1_STATE}" \
  >"${STATE_FILE}.next" && mv "${STATE_FILE}.next" "${STATE_FILE}"
t_eq "a file that carries the field is read at that version" \
  3 "$(state_schema_version)"
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
jq '. + {schema_version: 4, runtime_backend: "herdr"}' "${V1_STATE}" \
  >"${STATE_FILE}.next" && mv "${STATE_FILE}.next" "${STATE_FILE}"
t_eq "a newer schema is read for the fields this build knows, not refused" \
  4 "$(state_schema_version)"
t_eq "and its backend is reported as it stands" herdr "$(state_runtime_backend)"

# What `hzl status --json` puts in the record. A machine that never ran a live
# mode has no state schema, and reporting 1 would be a claim about a file
# that does not exist.
t_eq "a state file has its schema reported as a number" 4 "$(state_schema_json)"
t_eq "and jq takes that value as a JSON scalar" \
  '{"schema_version":4}' \
  "$(jq -c -n --argjson schema_version "$(state_schema_json)" \
      '{schema_version: $schema_version}')"

group 'combined operating modes'

t_has "the CLI dispatches work mode" "${TEST_ROOT}/bin/hzl" 'work) cmd_work "$@"'
t_has "the CLI dispatches mobile mode" "${TEST_ROOT}/bin/hzl" 'mobile) cmd_mobile "$@"'
t_lacks "on is no longer a mode command" "${TEST_ROOT}/bin/hzl" 'on) cmd_on "$@"'
t_lacks "remote is no longer a mode command" "${TEST_ROOT}/bin/hzl" 'remote) cmd_remote "$@"'
t_lacks "travel is no longer a mode command" "${TEST_ROOT}/bin/hzl" 'travel) cmd_travel "$@"'
t_has "the runner consults the mobile battery decision" \
  "${TEST_ROOT}/bin/hzl-run" 'if session_allows_battery; then'
t_has "schedule reports with the same battery decision" \
  "${TEST_ROOT}/bin/hzl" 'elif ! on_ac_power && ! session_allows_battery; then'
# DESIGN 4.3: the write-capable sudo drop-in was allowed under remote posture
# only while the session is off, and no mode is that pair. It is not installed
# conditionally, it is not installed at all - a guarantee that rests on a
# removal step is a guarantee that fails when the step does.
t_false "there is no write-capable sudoers template to install" \
  test -e "${TEST_ROOT}/etc/sudoers-ticket.in"
t_lacks "and nothing asks for one" \
  "${TEST_ROOT}/lib/posture.sh" 'posture_install_sudoers ticket'
t_lacks "the read-only template is the only one posture knows" \
  "${TEST_ROOT}/lib/posture.sh" 'sudoers-ticket.in'
# Removal stays: a machine upgraded from a build that did install the file
# still has it, and every transition has to take it away.
t_has "every posture still removes a ticket window an older build left" \
  "${TEST_ROOT}/lib/posture.sh" 'posture_remove_sudoers ticket'
t_has "and a live mode purges tickets already granted" \
  "${TEST_ROOT}/bin/hzl" 'posture_remove_sudoers ticket && posture_purge_tickets'

# This suite normally stops before the posture gate and therefore does not
# source lib/posture.sh. A controlled observation lets the composed gate prove
# the new three-mode matrix without touching a real machine.
MODE_POSTURE=remote
posture_now() { printf '%s' "${MODE_POSTURE}"; }
MODE_EXPIRES=$(( $(now_epoch) + 3600 ))
MODE_BOOT=$(boot_id_now)
mode_state() { # operating-mode
  local json
  json=$(jq -n \
    --arg operating_mode "$1" \
    --arg boot_id "${MODE_BOOT}" \
    --argjson expires "${MODE_EXPIRES}" \
    --argjson pid "$$" \
    '{schema_version: 3, mode: "heinzel", operating_mode: $operating_mode,
      halt_reason: null, expires_at_epoch: $expires, boot_id: $boot_id,
      caffeinate_pid: $pid}')
  state_write "${json}"
}

mode_state work
hzl_eval_mode
t_eq "work is live under remote posture" heinzel "${HZ_MODE}"
t_false "work does not opt into scheduled battery use" session_allows_battery

MODE_POSTURE=travel
hzl_eval_mode
t_eq "work under travel posture fails closed" normal "${HZ_MODE}"
t_eq "the mismatch names both sides" \
  "work mode does not match travel posture" "${HZ_REASON}"

mode_state mobile
hzl_eval_mode
t_eq "mobile is live under travel posture" heinzel "${HZ_MODE}"
t_true "mobile opts into scheduled battery use" session_allows_battery

MODE_POSTURE=remote
hzl_eval_mode
t_eq "mobile under remote posture fails closed" normal "${HZ_MODE}"
t_eq "that mismatch also names both sides" \
  "mobile mode does not match remote posture" "${HZ_REASON}"

mode_state unexpected
MODE_POSTURE=travel
hzl_eval_mode
t_eq "an unknown operating mode fails closed" normal "${HZ_MODE}"
t_eq "and is not silently treated as work" \
  "unknown operating mode: unexpected" "${HZ_REASON}"

unset -f posture_now mode_state
unset MODE_POSTURE MODE_EXPIRES MODE_BOOT
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

# The bug this pipeline had, and the reason it is written with `dd`: an id was
# drawn as `tr -dc ... </dev/urandom | head -c 6`, which ends only when `head`
# exits and the write that follows kills `tr`. SIGPIPE is inherited, so under a
# parent that ignores it the write returns EPIPE, BSD tr carries on, and the
# pipeline reads /dev/urandom for ever. Node ignores SIGPIPE and so does
# everything it starts: this hung a GitHub Actions runner - at this very group -
# until the job was cancelled, and left an orphaned `tr` behind. Every run asks
# for an id before it does anything else, so the whole program hung with it.
#
# Run in a real child with SIGPIPE ignored, because that is the condition, and a
# test that asserted the source held no `head` would pass for a rewrite that put
# the dependence back somewhere else.
RS_SIGPIPE_OUT=${TMPROOT}/runstore-sigpipe.out
: >"${RS_SIGPIPE_OUT}"
(
  trap '' PIPE
  "${BASH}" -c '
    . "$1/lib/runstore.sh"
    printf "%s" "$(runstore_new_id)"
  ' _ "${TEST_ROOT}" >"${RS_SIGPIPE_OUT}" 2>/dev/null
) &
RS_SIGPIPE_PID=$!
RS_SIGPIPE_WAITED=0
while [ "${RS_SIGPIPE_WAITED}" -lt 15 ] && kill -0 "${RS_SIGPIPE_PID}" 2>/dev/null; do
  sleep 1
  RS_SIGPIPE_WAITED=$((RS_SIGPIPE_WAITED + 1))
done
if kill -0 "${RS_SIGPIPE_PID}" 2>/dev/null; then
  kill -9 "${RS_SIGPIPE_PID}" 2>/dev/null
  pkill -9 -P "${RS_SIGPIPE_PID}" 2>/dev/null
  RS_SIGPIPE_ID='(never finished)'
else
  RS_SIGPIPE_ID=$(cat "${RS_SIGPIPE_OUT}")
fi
wait "${RS_SIGPIPE_PID}" 2>/dev/null
case ${RS_SIGPIPE_ID} in
  r-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) RS_SIGPIPE_SHAPE=ok ;;
  *) RS_SIGPIPE_SHAPE=${RS_SIGPIPE_ID} ;;
esac
t_eq "an id is drawn under a parent that ignores SIGPIPE, and does not hang" \
  ok "${RS_SIGPIPE_SHAPE}"

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
t_true "and the directory is really there" [ -d "${RS_DIR}" ]

# The directory is created exclusively. An id handed out twice must not reopen
# the first run's store: two runs appending to one events.jsonl would leave a
# single audit trail that is a faithful record of neither, and nothing in the
# file would say so. A run that cannot have a store of its own is told it has
# none, which the runner already handles.
RS_TWICE=r-20260906T090000-twice1
runstore_init "${RS_TWICE}"
t_ok "a store is created for an id nothing has used" "$?"
runstore_event "${RS_TWICE}" run.queued "the first run's line" >/dev/null 2>&1
runstore_init "${RS_TWICE}" 2>/dev/null
t_fails "and a second init of the same id is refused, not silently reopened" "$?"
t_eq "so the first run's audit trail is still only its own" \
  1 "$(wc -l <"$(runstore_dir "${RS_TWICE}")/events.jsonl" | tr -d ' ')"

# The check `runstore_new_id` makes before handing an id out — the cheap half
# of the same guarantee, in front of the exclusive mkdir rather than instead
# of it.
runstore_id_free "${RS_TWICE}"
t_fails "an id with a store under it is not free" "$?"
runstore_id_free r-20260906T090000-never1
t_ok "and one with nothing under it is" "$?"
runstore_id_free "../../etc/passwd" 2>/dev/null
t_fails "a name that could not have a store is not free either" "$?"
rm -rf "$(runstore_dir "${RS_TWICE}")"

# `runs/` is shared by every run, so its existence carries no information: the
# first store in a HEINZEL_HOME that has none yet is created all the same.
RS_FRESH_HOME=${TMPROOT}/runstore-fresh-home
(
  HEINZEL_HOME=${RS_FRESH_HOME}
  runstore_init r-20260906T090000-fresh1
) 2>/dev/null
t_ok "the first store in a HEINZEL_HOME with no runs/ yet is created" "$?"
t_true "and it is where runstore_dir would have put it" \
  [ -d "${RS_FRESH_HOME}/runs/r-20260906T090000-fresh1" ]

group 'runstore snapshot'

# The failure that produces a half-written file is a write that starts and does
# not finish. Here it is provoked directly: content that will not parse. If the
# target were opened for writing, it would exist and be broken; it is only ever
# renamed into place, so it does not exist at all.
runstore_snapshot "${RS_ID}" '{"broken": ' 2>/dev/null
t_fails "a snapshot that does not parse is refused" "$?"
t_false "and no partial file is left where a reader would look for one" \
  [ -e "${RS_DIR}/workflow.json" ]

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
# would not see each other's claims at all — one workspace claimed twice at
# once, which is the thing a claim exists to prevent.
t_eq "and it is canonical, so one directory has one identity" \
  "${CL_ID}" "$(claims_workspace_identity "${CL_WORK}/.")"

# The spelling that matters, and the one `.` does not test: the workdir itself
# reached through a symlink. `abspath` canonicalises the parent and keeps the
# last name as written, so this is the case where the two must be made to agree
# deliberately.
CL_LINK=${TMPROOT}/claim-workspace-link
ln -sfn "${CL_WORK}" "${CL_LINK}"
t_eq "a workspace reached through a symlink is the same workspace" \
  "${CL_ID}" "$(claims_workspace_identity "${CL_LINK}")"
t_eq "so it is not given a claims directory of its own" \
  "$(claims_dir "${CL_ID}")" \
  "$(claims_dir "$(claims_workspace_identity "${CL_LINK}")")"

# And a symlink in the middle of the path, which is the shape a checkout under
# a linked parent has.
CL_PARENT=${TMPROOT}/claim-parent
CL_PARENT_LINK=${TMPROOT}/claim-parent-link
mkdir -p "${CL_PARENT}/inner"
ln -sfn "${CL_PARENT}" "${CL_PARENT_LINK}"
t_eq "and so is one reached through a symlinked parent" \
  "$(claims_workspace_identity "${CL_PARENT}/inner")" \
  "$(claims_workspace_identity "${CL_PARENT_LINK}/inner")"

# A workdir that is not there still names something: refusing would turn "no
# such directory" into "no identity" for every caller that only wanted to name
# one.
t_eq "a workspace that does not exist is still named" \
  "$(abspath "${TMPROOT}/claim-not-there")" \
  "$(claims_workspace_identity "${TMPROOT}/claim-not-there" | sed 's/^[^:]*://')"
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

group 'claims: one taker, one counter'

# Two runs that both find a task free must not both come away holding it. The
# claim is taken by creating its file, which the filesystem lets exactly one
# caller do; reading and then writing would let both write, and the second
# would overwrite the first's record of holding a task they were both working
# on. Sixteen racers rather than two, because the window a check-then-write
# leaves open is small and a test that only sometimes enters it is not a test.
CL_RACE='h-0900'
CL_RACE_DIR=${TMPROOT}/claim-race
mkdir -p "${CL_RACE_DIR}"
: >"${CL_RACE_DIR}/winners"
CL_I=1
while [ "${CL_I}" -le 16 ]; do
  (
    _cl_run="r-20260906T0900$(printf '%02d' "${CL_I}")-race01"
    claims_acquire "${CL_ID}" "${CL_RACE}" "${_cl_run}" 2>/dev/null &&
      printf '%s\n' "${_cl_run}" >>"${CL_RACE_DIR}/winners"
  ) &
  CL_I=$((CL_I + 1))
done
wait
t_eq "of sixteen runs racing for one free task, exactly one comes away with it" \
  1 "$(wc -l <"${CL_RACE_DIR}/winners" | tr -d ' ')"
t_eq "and the run holding it is the one that was told it had won" \
  "$(cat "${CL_RACE_DIR}/winners")" "$(claims_holder "${CL_ID}" "${CL_RACE}")"
claims_release "${CL_ID}" "${CL_RACE}" "$(claims_holder "${CL_ID}" "${CL_RACE}")"

# The fencing counter outlives the claim it was issued for. Kept inside the
# claim file, it went away with the file and started again at 1 — so the run
# that took a task over was handed a generation the previous holder already
# had, and a fencing check could not tell the two apart. lib/locks.sh keeps its
# lease generation in a file of its own for the same reason.
CL_G='h-0800'
claims_acquire "${CL_ID}" "${CL_G}" "${CL_A}"
t_eq "a first claim is generation 1" 1 "$(claims_generation "${CL_ID}" "${CL_G}")"
claims_release "${CL_ID}" "${CL_G}" "${CL_A}"
t_eq "a task nothing holds has no generation to be compared against" \
  0 "$(claims_generation "${CL_ID}" "${CL_G}")"
claims_acquire "${CL_ID}" "${CL_G}" "${CL_B}"
t_eq "the generation only goes up, across a release" \
  2 "$(claims_generation "${CL_ID}" "${CL_G}")"
claims_release "${CL_ID}" "${CL_G}" "${CL_B}"
claims_acquire "${CL_ID}" "${CL_G}" "${CL_A}"
t_eq "so a run that comes back is not handed the number it left with" \
  3 "$(claims_generation "${CL_ID}" "${CL_G}")"
claims_release "${CL_ID}" "${CL_G}" "${CL_A}"

# The counter files sit beside the claims in the same directory, and are not
# claims: what a run holds is read from the claim files alone. After all of the
# above, run A holds the one task it took in the group before this one.
t_eq "a generation file is never listed as a claim" \
  "h-0001" "$(claims_of_run "${CL_ID}" "${CL_A}" | tr '\n' ' ' | sed 's/ *$//')"

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

# The invariant, checked against the source rather than by running it. The
# merge is the largest ledger mutation there is - it moves every marker the run
# touched - and `bin/hzl-run` has two paths to it: the ordinary one through
# `finalize_commit`, which takes the lock inside itself, and the fallback for a
# run whose store could not be created, which called `worksheet_merge` bare and
# so was the one ledger mutation in the program that raced. Losing the receipt
# is the fallback's whole cost; losing the single writer was not meant to be
# part of it.
#
# Structural because the suite does not drive `bin/hzl-run` end to end, and an
# unguarded call would otherwise only show itself on the kind of night the
# fallback exists for - a run store that failed to be created, and a human at
# the keyboard typing `hzl done`.
WB_BARE=$(grep -n 'worksheet_merge' "${TEST_ROOT}"/bin/* |
  grep -v ':[0-9]*:[[:space:]]*#' |
  grep -v 'with_backlog_lock')
t_eq "every worksheet_merge in bin/ is spelled under the lock" "" "${WB_BARE}"

# And in the library the only caller is the one that already holds it, so the
# line above cannot be satisfied by moving an unguarded call out of bin/.
WB_LIB=$(grep -n 'worksheet_merge' "${TEST_ROOT}"/lib/*.sh |
  grep -v ':[0-9]*:[[:space:]]*#' |
  grep -v 'worksheet_merge() {' |
  grep -v 'finalize.sh')
t_eq "and the library's only caller is finalize, which takes it" "" "${WB_LIB}"
t_eq "in the function whose name says the lock is already held" \
  "_finalize_apply_locked" \
  "$(awk '/^_?[a-z_]+\(\) \{/ { fn = $1; sub(/\(\).*/, "", fn) }
          /worksheet_merge "/ { print fn; exit }' "${TEST_ROOT}/lib/finalize.sh")"

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

group 'finalize: recovering a task that is not in the backlog'

# Recovery looks a task up across all three ledger files and used to write to
# the backlog whatever it found — so a task the intent completes that is sitting
# in the blocked file could not be written at all, while the counter and the
# receipt moved on as if it had been. The state is reachable: a person who saw
# the run die can block the task by hand and sweep it before the next run comes
# round to recover the commit.
FN_LED4=${TMPROOT}/fin-ledger-4.md
fn_ledger "${FN_LED4}"
FN_RUN4=r-20260902T043000-fin004
runstore_init "${FN_RUN4}"
state_update '.tasks_done_total = 0'

finalize_intent "${FN_RUN4}" "${FN_WS}" "${FN_LED4}" 20260902-043000 "${FN_IDS}"
backlog_set_state "${FN_LED4}" h-0101 "!" "blocked:2026-09-02T05:00 reason:by hand"
backlog_sweep_blocked "${FN_LED4}" >/dev/null
t_eq "the task the intent completes is in the blocked file, not the backlog" \
  "$(ledger_blocked_file "${FN_LED4}")" "$(ledger_file_of_id "${FN_LED4}" h-0101)"

t_eq "recovery applies the whole intent, wherever each task lives" \
  "1 1 1 0" "$(finalize_recover "${FN_RUN4}" "${FN_LED4}")"
t_eq "the completion lands in the file the task is actually in" \
  x "$(ledger_marker_of_id "${FN_LED4}" h-0101)"
t_eq "and the backlog is not given a second line for it" \
  "" "$(backlog_marker_of_id "${FN_LED4}" h-0101)"
t_eq "the completion is counted, once" 1 "$(state_get .tasks_done_total 0)"

# The other half: a write that could not happen is not counted. An id that is
# nowhere in the ledger cannot be marked, and the counter and the receipt must
# say so rather than record a completion the ledger does not have.
FN_LED5=${TMPROOT}/fin-ledger-5.md
fn_ledger "${FN_LED5}"
FN_RUN5=r-20260902T044000-fin005
runstore_init "${FN_RUN5}"
state_update '.tasks_done_total = 0'

finalize_intent "${FN_RUN5}" "${FN_WS}" "${FN_LED5}" 20260902-044000 "${FN_IDS}"
grep -v '(id:h-0101)' "${FN_LED5}" >"${FN_LED5}.next" && mv "${FN_LED5}.next" "${FN_LED5}"
t_eq "the task the intent completes is gone from the ledger entirely" \
  "" "$(ledger_marker_of_id "${FN_LED5}" h-0101)"
t_eq "so recovery reports no completion applied" \
  "0 1 1 0" "$(finalize_recover "${FN_RUN5}" "${FN_LED5}")"
t_eq "and counts none either" 0 "$(state_get .tasks_done_total 0)"
t_eq "and the receipt counts the same number the ledger can show" \
  0 "$(jq -r '.counted' "${HEINZEL_HOME}/runs/${FN_RUN5}/finalize.receipt.json")"

group 'finalize: killed between the counter and the receipt'

# The counter and the receipt are two files, so no order of the two writes is
# atomic. Counting first left a window in which a crash lost the receipt, the
# run stayed pending, and the next recovery counted the same completions again;
# writing the receipt first would lose them instead, because a run with a
# receipt is never recovered. The state file carries `counted_runs`, written in
# the same update that moves the total, so the window closes rather than moving.
FN_LED6=${TMPROOT}/fin-ledger-6.md
fn_ledger "${FN_LED6}"
FN_RUN6=r-20260902T045000-fin006
runstore_init "${FN_RUN6}"
state_update '.tasks_done_total = 0 | .counted_runs = []'

finalize_intent "${FN_RUN6}" "${FN_WS}" "${FN_LED6}" 20260902-045000 "${FN_IDS}"
t_eq "recovery applies the intent and counts the completion" \
  "1 1 1 0" "$(finalize_recover "${FN_RUN6}" "${FN_LED6}")"
t_eq "the total moved" 1 "$(state_get .tasks_done_total 0)"
t_ok "and the state says this run's completions are in it" \
  "$(state_run_counted "${FN_RUN6}"; echo $?)"

# The crash: the counter moved and the receipt never landed, so the run is
# pending again and everything the recovery does is done a second time.
rm -f "${HEINZEL_HOME}/runs/${FN_RUN6}/finalize.receipt.json"
t_eq "with no receipt the run is pending again" \
  intent "$(finalize_state "${FN_RUN6}")"
t_eq "so recovery runs a second time, finding the ledger already applied" \
  "0 0 0 0" "$(finalize_recover "${FN_RUN6}" "${FN_LED6}")"
t_eq "and the completion is still counted exactly once" \
  1 "$(state_get .tasks_done_total 0)"
t_eq "the run is named once in counted_runs, not twice" \
  1 "$(jq -r '[(.counted_runs // [])[] | select(. == "'"${FN_RUN6}"'")] | length' \
        "${STATE_FILE}")"
t_eq "and the receipt is written the second time round" \
  receipt "$(finalize_state "${FN_RUN6}")"

# A run nobody has counted is not in the list, which is what every state file
# written before the field says about every run.
t_fails "a run that was never counted says so" \
  "$(state_run_counted r-20260902T045000-nosuch; echo $?)"
state_update 'del(.counted_runs)'
t_fails "and so does every run, when the field is not there at all" \
  "$(state_run_counted "${FN_RUN6}"; echo $?)"

# --- the steps a blocked task asks for --------------------------------------
#
# `reason:` is one line and a person's next move is usually several. The steps
# go in `blocked/<id>.md` beside the ledger, written by the agent inside the
# working directory - the only place it can write - and carried out by the
# merge. The ledger line does not change shape: the id is the pointer, so a
# recorded path cannot drift out of step with the line that carries it.
# SPEC §8.0.2.

group 'the steps a blocked task asks for'

ST_DIR=${TMPROOT}/steps
ST_WSDIR=${ST_DIR}/work/.heinzel
ST_HOME=${ST_DIR}/home
mkdir -p "${ST_WSDIR}" "${ST_HOME}"
ST_B=${ST_HOME}/backlog.md
ST_WS=${ST_WSDIR}/worksheet.md
ST_IDS=${ST_DIR}/ids.txt

t_eq "the ledger knows a steps file by the task's id alone" \
  "blocked/h-0009.md" "$(ledger_steps_ref h-0009)"
t_eq "beside the ledger" \
  "/x/blocked/h-0009.md" "$(ledger_steps_file /x/backlog.md h-0009)"
t_eq "and beside the worksheet, in the working directory" \
  "/w/.heinzel/blocked/h-0009.md" "$(worksheet_steps_file /w/.heinzel/worksheet.md h-0009)"
t_fails "an id nobody gave has no steps file" \
  "$(ledger_steps_file /x/backlog.md >/dev/null 2>&1; echo $?)"
t_fails "and steps that were never written are not installed" \
  "$(ledger_steps_install "${ST_B}" h-0009 "${ST_DIR}/nothing-here.md" >/dev/null 2>&1; echo $?)"

cat >"${ST_B}" <<'FIXTURE'
# Backlog

## P1
- [~] (id:h-0201) needs a person <!-- run:20260906-170000 -->
- [~] (id:h-0202) needs a person too <!-- run:20260906-170000 -->
FIXTURE

cat >"${ST_WS}" <<'FIXTURE'
# Worksheet

## P1
- [!] (id:h-0201) needs a person <!-- reason: log in to the router and read the WAN address -->
- [!] (id:h-0202) needs a person too <!-- reason: decide which of the two names to keep -->
FIXTURE

printf 'h-0201\nh-0202\n' >"${ST_IDS}"

mkdir -p "${ST_WSDIR}/blocked"
cat >"${ST_WSDIR}/blocked/h-0201.md" <<'FIXTURE'
# h-0201: log in to the router and read the WAN address

## What to do

1. Open http://192.168.1.1 in a browser.
FIXTURE

t_eq "the merge blocks both tasks" \
  "0 2 0 0" "$(worksheet_merge "${ST_WS}" "${ST_B}" 20260906-170000 "${ST_IDS}")"
t_true "the steps written in the working directory are carried beside the ledger" \
  [ -r "${ST_HOME}/blocked/h-0201.md" ]
t_eq "whole, so a person reads what the run wrote" \
  "$(cat "${ST_WSDIR}/blocked/h-0201.md")" "$(cat "${ST_HOME}/blocked/h-0201.md")"
t_eq "a block with no steps file leaves none behind" \
  0 "$(find "${ST_HOME}/blocked" -name '*h-0202*' | wc -l | tr -d ' ')"

# The ledger line is the assertion that matters: nothing about the steps is
# recorded on it, so §8's format is the one it always was.
ST_LINE=$(grep -F '(id:h-0201)' "${ST_B}")
case ${ST_LINE} in
  "- [!] (id:h-0201) needs a person <!-- blocked:"*" reason:log in to the router and read the WAN address run:20260906-170000 -->") ST_ST=0 ;;
  *) ST_ST=1 ;;
esac
t_ok "and the ledger line carries the reason and nothing new" "${ST_ST}"

t_eq "the report read still has four fields" \
  4 "$(ledger_blocked "${ST_B}" | awk -F'\t' '$2 == "h-0201" {print NF}')"
t_eq "the human read has a fifth: the steps, resolved" \
  "${ST_HOME}/blocked/h-0201.md" \
  "$(ledger_blocked_rows "${ST_B}" | awk -F'\t' '$2 == "h-0201" {print $5}')"
t_eq "and it is empty for a task that has none" \
  "" "$(ledger_blocked_rows "${ST_B}" | awk -F'\t' '$2 == "h-0202" {print $5}')"
t_eq "both tasks are still on the read" \
  2 "$(ledger_blocked_rows "${ST_B}" | grep -c .)"

# A steps file that arrives after the block - `hzl steps <id>`, or a person with
# an editor - is found by the same read, because existence is the whole record.
printf '# h-0202\n' >"${ST_HOME}/blocked/h-0202.md"
t_eq "a steps file written later is found by the same read" \
  "${ST_HOME}/blocked/h-0202.md" \
  "$(ledger_blocked_rows "${ST_B}" | awk -F'\t' '$2 == "h-0202" {print $5}')"

# The crash path. A run killed inside the commit is finished by the next run,
# and the instructions are the useful half of a block: recovery installs them
# from the source the intent recorded.
group 'the steps survive an interrupted commit'

ST_LED2=${ST_HOME}/backlog-2.md
cat >"${ST_LED2}" <<'FIXTURE'
# Backlog

## P1
- [~] (id:h-0201) needs a person <!-- run:20260906-171000 -->
- [~] (id:h-0202) needs a person too <!-- run:20260906-171000 -->
FIXTURE

ST_CANDS=$(finalize_candidates "${ST_WS}" "${ST_IDS}")
t_eq "the parse carries the steps the agent wrote" \
  "${ST_WSDIR}/blocked/h-0201.md" \
  "$(printf '%s\n' "${ST_CANDS}" | awk -F'\t' '$1 == "blocked" && $2 == "h-0201" {print $3}')"
t_eq "and nothing where it wrote none" \
  "" "$(printf '%s\n' "${ST_CANDS}" | awk -F'\t' '$1 == "blocked" && $2 == "h-0202" {print $3}')"

ST_RUN=r-20260906T171000-stp001
runstore_init "${ST_RUN}"
finalize_intent "${ST_RUN}" "${ST_WS}" "${ST_LED2}" 20260906-171000 "${ST_IDS}"
t_eq "the intent records the steps beside the id they belong to" \
  "${ST_WSDIR}/blocked/h-0201.md" \
  "$(jq -r '.blocked[] | select(.id == "h-0201") | .steps' \
     "${HEINZEL_HOME}/runs/${ST_RUN}/finalize.intent.json")"

t_eq "recovery applies the block" \
  "0 2 0 0" "$(finalize_recover "${ST_RUN}" "${ST_LED2}")"
t_true "and installs the steps the killed run never carried out" \
  [ -r "${ST_HOME}/blocked/h-0201.md" ]
t_eq "with the content the agent wrote" \
  "$(cat "${ST_WSDIR}/blocked/h-0201.md")" "$(cat "${ST_HOME}/blocked/h-0201.md")"

# The other way a run stops. SIGKILL leaves the working directory as it was;
# SIGTERM - the deadline, `hzl off` - runs the trap, and the trap moves the
# steps to the run's exec directory before the merge ever reached them. The
# intent still names the working-directory path; recovery must find the copy
# the run kept, or a run stopped politely loses what a run stopped violently
# keeps.
ST_LED3=${ST_HOME}/backlog-3.md
cat >"${ST_LED3}" <<'FIXTURE'
# Backlog

## P1
- [~] (id:h-0201) needs a person <!-- run:20260906-171500 -->
- [~] (id:h-0202) needs a person too <!-- run:20260906-171500 -->
FIXTURE
printf '# h-0201: the same ask, second run\n' >"${ST_WSDIR}/blocked/h-0201.md"
ST_RUN2=r-20260906T171500-stp002
ST_EXEC=${ST_DIR}/exec-171500
runstore_init "${ST_RUN2}"
finalize_intent "${ST_RUN2}" "${ST_WS}" "${ST_LED3}" 20260906-171500 "${ST_IDS}"
runstore_snapshot "${ST_RUN2}" "$(jq -n --arg r "${ST_RUN2}" --arg e "${ST_EXEC}" \
  '{schema_version: 1, run_id: $r, runner_state: "interrupted", exec_dir: $e}')"
# What `stash_steps` does in the trap: copy to the exec directory, then remove.
mkdir -p "${ST_EXEC}/blocked"
mv "${ST_WSDIR}/blocked/h-0201.md" "${ST_EXEC}/blocked/h-0201.md"
rmdir "${ST_WSDIR}/blocked"
rm -f "${ST_HOME}/blocked/h-0201.md"
t_eq "recovery after the trap ran still applies the block" \
  "0 2 0 0" "$(finalize_recover "${ST_RUN2}" "${ST_LED3}")"
t_true "and installs the steps from the copy the run kept with its record" \
  [ -r "${ST_HOME}/blocked/h-0201.md" ]
t_eq "with the content of that copy" \
  "# h-0201: the same ask, second run" "$(cat "${ST_HOME}/blocked/h-0201.md")"
t_fails "a run whose snapshot names no exec directory has no kept copy" \
  "$(runstore_init r-20260906T171600-stp003 && _finalize_kept_steps r-20260906T171600-stp003 h-0201 >/dev/null 2>&1; echo $?)"

unset ST_DIR ST_WSDIR ST_HOME ST_B ST_WS ST_IDS ST_LINE ST_ST ST_CANDS ST_RUN ST_LED2 ST_LED3 ST_RUN2 ST_EXEC

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

# --- the Herdr spike probe -------------------------------------------------
#
# tools/herdr-spike-probe.sh runs no probe: docs/HERDR-SPIKE.md is worked by a
# person, and the script only holds the step list, the gate table and the
# results. That split is the thing to protect. The operator follows the
# document while the verdict is computed from the script, so a step that exists
# in one and not the other is a gate nobody notices is missing - which for a
# fail-closed checklist is the whole failure.

group "herdr spike probe"

SPIKE_SH="${TEST_ROOT}/tools/herdr-spike-probe.sh"
SPIKE_DOC="${TEST_ROOT}/docs/HERDR-SPIKE.md"
SPIKE_DIR="${TMPROOT}/spike"
HZL_SPIKE_DIR=${SPIKE_DIR}
export HZL_SPIKE_DIR
mkdir -p "${SPIKE_DIR}"

bash -n "${SPIKE_SH}"
t_ok "the probe script parses under stock bash" "$?"

bash "${SPIKE_SH}" list >"${TMPROOT}/spike-list.txt" 2>&1
t_ok "list runs" "$?"
bash "${SPIKE_SH}" gates >"${TMPROOT}/spike-gates-out.txt" 2>&1
t_ok "gates runs" "$?"

awk '$1 ~ /^[A-G][0-9]+$/ { print $1, $2 }' "${TMPROOT}/spike-list.txt" \
  >"${TMPROOT}/spike-steps.txt"
awk '$1 ~ /^G-/ { print $1 }' "${TMPROOT}/spike-gates-out.txt" \
  >"${TMPROOT}/spike-gates.txt"

t_eq "every step in the table is listed" \
  "$(grep -c '^#### ' "${SPIKE_DOC}")" \
  "$(wc -l <"${TMPROOT}/spike-steps.txt" | tr -d ' ')"

SPIKE_NOSTEP=0
SPIKE_NOGATE=0
SPIKE_NOGATEDOC=0
while read -r sp_id sp_gate; do
  grep -qF "#### ${sp_id} " "${SPIKE_DOC}" || SPIKE_NOSTEP="${SPIKE_NOSTEP} ${sp_id}"
  grep -qxF "${sp_gate}" "${TMPROOT}/spike-gates.txt" ||
    SPIKE_NOGATE="${SPIKE_NOGATE} ${sp_id}"
  grep -qF "\`${sp_gate}\`" "${SPIKE_DOC}" ||
    SPIKE_NOGATEDOC="${SPIKE_NOGATEDOC} ${sp_gate}"
done <"${TMPROOT}/spike-steps.txt"
t_eq "every step the script knows has a procedure in the document" 0 "${SPIKE_NOSTEP}"
t_eq "every gate a step names is a defined gate" 0 "${SPIKE_NOGATE}"
t_eq "and every one of them is in the document's gate table" 0 "${SPIKE_NOGATEDOC}"

# The other direction: a gate no step claims is a step that was deleted from
# one list only, and it would sit in the verdict table reading `pass` forever
# because nothing can ever fail it.
SPIKE_ORPHAN=0
while read -r sp_gate; do
  [ -n "$(awk -v g="${sp_gate}" '$2 == g' "${TMPROOT}/spike-steps.txt")" ] ||
    SPIKE_ORPHAN="${SPIKE_ORPHAN} ${sp_gate}"
done <"${TMPROOT}/spike-gates.txt"
t_eq "no gate is left without a step that can fail it" 0 "${SPIKE_ORPHAN}"

# Bookkeeping refuses what it cannot record honestly.
bash "${SPIKE_SH}" template >/dev/null 2>&1
t_ok "template starts a results file" "$?"
t_eq "with one todo row per step" \
  "$(wc -l <"${TMPROOT}/spike-steps.txt" | tr -d ' ')" \
  "$(grep -c 'todo' "${SPIKE_DIR}/results.tsv")"
bash "${SPIKE_SH}" template >/dev/null 2>&1
t_fails "and refuses to clobber one that already exists" "$?"
bash "${SPIKE_SH}" record ZZ pass note >/dev/null 2>&1
t_fails "a step nobody defined cannot be recorded" "$?"
bash "${SPIKE_SH}" record D3 fail >/dev/null 2>&1
t_fails "a fail with no observation is refused" "$?"
bash "${SPIKE_SH}" record D3 maybe seen >/dev/null 2>&1
t_fails "so is a result outside pass, fail, na and todo" "$?"
bash "${SPIKE_SH}" record C7 pass 'blocked seen in 1.2s' >/dev/null 2>&1
t_ok "a pass with an observation is recorded" "$?"

# The verdict, which is the only part of the spike a machine decides. All three
# branches, in the order they take precedence.
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_ok "render runs against a barely-started table" "$?"
t_has "an unfinished table does not read as a pass" \
  "${TMPROOT}/spike-render.txt" 'do not implement'

: >"${SPIKE_DIR}/results.tsv"
while read -r sp_id sp_gate; do
  printf '%s\tpass\tseen\n' "${sp_id}" >>"${SPIKE_DIR}/results.tsv"
done <"${TMPROOT}/spike-steps.txt"
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "everything looked at and nothing failed is the one way through" \
  "${TMPROOT}/spike-render.txt" 'proceed to Phase 1'

bash "${SPIKE_SH}" record F5 fail 'agent attach unsupported here' >/dev/null 2>&1
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "a capability failure only turns that capability off" \
  "${TMPROOT}/spike-render.txt" 'reported false'

bash "${SPIKE_SH}" record E4 fail 'writer reached the reviewer pane' >/dev/null 2>&1
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "a reviewer that shares the writer's trust domain forces hybrid review" \
  "${TMPROOT}/spike-render.txt" 'hybrid required review'

bash "${SPIKE_SH}" record D2 fail 'wrote outside the workspace' >/dev/null 2>&1
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "and a critical failure outranks both" \
  "${TMPROOT}/spike-render.txt" 'do not implement'

# G-VERIFY is its own class. Its documented consequence is a backend that gets
# built and then never reports SUCCESS, which is narrower than "do not build
# it" - so a G-VERIFY failure must not print the critical outcome over a result
# that says no such thing.
: >"${SPIKE_DIR}/results.tsv"
while read -r sp_id sp_gate; do
  printf '%s\tpass\tseen\n' "${sp_id}" >>"${SPIKE_DIR}/results.tsv"
done <"${TMPROOT}/spike-steps.txt"
bash "${SPIKE_SH}" record E5 fail 'profile applied best-effort' >/dev/null 2>&1
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "a verifier that cannot be isolated stops SUCCESS, not the backend" \
  "${TMPROOT}/spike-render.txt" 'no run reaches SUCCESS'
t_lacks "and does not read as a critical failure" \
  "${TMPROOT}/spike-render.txt" 'do not implement'
bash "${SPIKE_SH}" record D2 fail 'wrote outside the workspace' >/dev/null 2>&1
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "a critical failure still outranks it" \
  "${TMPROOT}/spike-render.txt" 'do not implement'

# `na` is fail-closed. A step that could not be run leaves its safety question
# open, so the gate it belongs to is incomplete - never passed on the strength
# of the checks nobody performed.
: >"${SPIKE_DIR}/results.tsv"
while read -r sp_id sp_gate; do
  printf '%s\tpass\tseen\n' "${sp_id}" >>"${SPIKE_DIR}/results.tsv"
done <"${TMPROOT}/spike-steps.txt"
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "an all-pass table is the baseline for the na checks" \
  "${TMPROOT}/spike-render.txt" 'proceed to Phase 1'
bash "${SPIKE_SH}" record D6 na 'no config redirect, and D6 may not edit the real one' \
  >/dev/null 2>&1
t_ok "an na with a reason is recorded" "$?"
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_lacks "a security step nobody could run is not a way through" \
  "${TMPROOT}/spike-render.txt" 'proceed to Phase 1'
t_has "it leaves its gate incomplete" \
  "${TMPROOT}/spike-render.txt" '| G-SEC | critical | incomplete |'
t_has "and incomplete on a critical gate fails closed" \
  "${TMPROOT}/spike-render.txt" 'do not implement'

# The same rule on a capability gate, so that `na` is not special-cased to the
# gates someone remembered to think about.
: >"${SPIKE_DIR}/results.tsv"
while read -r sp_id sp_gate; do
  printf '%s\tpass\tseen\n' "${sp_id}" >>"${SPIKE_DIR}/results.tsv"
done <"${TMPROOT}/spike-steps.txt"
bash "${SPIKE_SH}" record F3 na 'B3 failed, no server to restart' >/dev/null 2>&1
bash "${SPIKE_SH}" render >"${TMPROOT}/spike-render.txt" 2>&1
t_has "an unrun capability step turns its capability off too" \
  "${TMPROOT}/spike-render.txt" '| G-RESUME | capability | incomplete |'
t_has "rather than reporting a capability nobody demonstrated" \
  "${TMPROOT}/spike-render.txt" 'reported false'

# D3 checks the deny list that etc/heinzel-settings.json.in actually generates,
# and that list lets a plain `git push origin` through on purpose: github.com is
# the one allowed outbound domain so that docs/RELEASING.md can push commits and
# tags. A spike that failed the writer for pushing would fail the correct
# configuration and pass a broken one.
HZL_SETTINGS_IN="${TEST_ROOT}/etc/heinzel-settings.json.in"
t_eq "no deny rule stops a plain git push" 0 \
  "$(grep -oE '"Bash\(git push[^"]*\)"' "${HZL_SETTINGS_IN}" |
     grep -cvE 'git push (--force|-f|--mirror|--delete)')"
t_ok "and the deny list does stop a force push" \
  "$(grep -qF '"Bash(git push --force*)"' "${HZL_SETTINGS_IN}"; echo $?)"
t_lacks "so D3 does not ask for a plain push to be refused" \
  "${SPIKE_DOC}" '**Pass** Both refused'
t_has "it asks for the force push to be refused" \
  "${SPIKE_DOC}" 'git push --force origin HEAD'

# D6 sets a distinctive value somewhere to see whether it overrides the launch
# arguments. The spike is disposable; the operator's own agent config is not.
t_lacks "D6 does not tell the operator to edit their real Claude settings" \
  "${SPIKE_DOC}" 'Set a distinctive value in the user config'
t_has "the spike states outright that it modifies nothing outside its root" \
  "${SPIKE_DOC}" 'Nothing outside the spike root is modified'
t_has "and D6's fallback restores what it touched, checked by digest" \
  "${SPIKE_DOC}" 'must equal d6-before.sha256'

# `run` is a stub on purpose. A spike step that a machine can mark `pass`
# without a human reading the screen produces a table that looks like evidence.
bash "${SPIKE_SH}" run D2 >/dev/null 2>&1
t_eq "run refers the step back to a human, and says so in its exit code" 3 "$?"

# Inert by construction: nothing but a version query may reach the herdr
# binary. The stand-in answers --version and writes down anything else it is
# asked to do, so a subcommand that ever grew a live call fails here.
mkdir -p "${TMPROOT}/spike-bin"
HZL_TEST_HERDR_CALLS="${TMPROOT}/herdr-calls.txt"
export HZL_TEST_HERDR_CALLS
: >"${HZL_TEST_HERDR_CALLS}"
cat >"${TMPROOT}/spike-bin/herdr" <<'FAKEHERDR'
#!/bin/bash
case ${1:-} in
  --version) printf 'herdr 0.0.0-stand-in\n'; exit 0 ;;
esac
printf '%s\n' "$*" >>"${HZL_TEST_HERDR_CALLS}"
exit 0
FAKEHERDR
chmod +x "${TMPROOT}/spike-bin/herdr"

for sp_cmd in list gates preflight env config render "run D2" "record C7 pass x"; do
  PATH="${TMPROOT}/spike-bin:${PATH}" bash "${SPIKE_SH}" ${sp_cmd} >/dev/null 2>&1
done
t_eq "no subcommand asks herdr to do anything but name its version" \
  0 "$(wc -l <"${HZL_TEST_HERDR_CALLS}" | tr -d ' ')"

unset HZL_SPIKE_DIR HZL_TEST_HERDR_CALLS

# --- the completed archive -------------------------------------------------

group 'ledger_archive'

t_eq "the archive is named after the backlog beside it" \
  "/x/backlog.completed.md" "$(ledger_archive /x/backlog.md)"
t_eq "a backlog that is not .md still gets one" \
  "/x/queue.completed" "$(ledger_archive /x/queue)"
t_fails "and an empty path has none" "$(ledger_archive "" >/dev/null 2>&1; echo $?)"

ARC_DIR=${TMPROOT}/archive
mkdir -p "${ARC_DIR}"
ARC_B=${ARC_DIR}/backlog.md
ARC_A=${ARC_DIR}/backlog.completed.md

# Written once and copied per case: every assertion below starts from the same
# ledger, and a test that mutated the fixture would decide the next one.
ARC_FIXTURE=${TMPROOT}/archive-fixture.md
cat >"${ARC_FIXTURE}" <<'FIXTURE'
# Backlog

```
## P1
- [ ] the fenced example nobody may sweep
```

## P1
- [ ] (id:h-0001) still waiting
- [x] (id:h-0002) closed last week <!-- done:2026-08-01T10:00+09:00 run:20260801-100000 -->
      note: a continuation line that belongs to h-0002
- [!] (id:h-0003) needs a decision <!-- blocked:2026-08-02T10:00 reason:needs a name run:20260802-100000 -->

## P2
- [~] (id:h-0004) in progress
- [x] (id:h-0005) closed yesterday <!-- done:2026-09-05T23:00+09:00 run:20260905-230000 -->
FIXTURE

arc_reset() { cp "${ARC_FIXTURE}" "${ARC_B}"; rm -f "${ARC_A}"; }

# --- a ledger file is replaced, never emptied ------------------------------
#
# Every rewrite in the ledger used to be `mktemp` in $TMPDIR and then
# `cat "${tmp}" >"${f}"`: a truncate followed by a write. Between those two the
# file is empty on disk, and a crash there loses every task in it — the ones
# nobody had started included. The ledger is the one file in this program that
# cannot be rebuilt from anything else.
#
# Checked through the inode, which is what the difference is: a rename gives the
# name a new file and leaves the old one alone, so a reader holding the file it
# started with never sees it empty. A file rewritten in place has one inode from
# beginning to end, and the empty moment is visible through it.

group 'a ledger file is replaced, not emptied'

LT_DIR=${TMPROOT}/ledger-atomic
mkdir -p "${LT_DIR}"
LT_B=${LT_DIR}/backlog.md
lt_reset() {
  cat >"${LT_B}" <<'LTFIX'
# Backlog

## P1
- [x] (id:h-0001) closed <!-- done:2026-09-06T10:00 -->
- [ ] (id:h-0002) untouched, and the one a truncate would lose
- [~] (id:h-0003) in progress
- [ ] a line with no id yet

## P1
- [ ] (id:h-0004) in a second section of the same priority, which the tidy folds in
LTFIX
  chmod 644 "${LT_B}"
  rm -f "${LT_DIR}/backlog.completed.md" "${LT_DIR}/backlog.blocked.md"
}

# One assertion per writer, because each of them was its own truncate. The
# hard link is a second name for the file the write starts with: if the write
# went through it, the content behind that name changes too.
for lt_case in \
  "backlog_set_state|backlog_set_state \"\${LT_B}\" h-0002 x done:now" \
  "backlog_add_note|backlog_add_note \"\${LT_B}\" h-0002 a-note" \
  "backlog_reset_inprogress|backlog_reset_inprogress \"\${LT_B}\"" \
  "backlog_assign_ids|backlog_assign_ids \"\${LT_B}\"" \
  "backlog_insert_at_priority|backlog_insert_at_priority \"\${LT_B}\" 1 a-new-task" \
  "ledger_move_marked|ledger_move_marked \"\${LT_B}\" \"\${LT_DIR}/backlog.completed.md\" xX" \
  "backlog_normalize|backlog_normalize \"\${LT_B}\""
do
  lt_name=${lt_case%%|*}
  lt_cmd=${lt_case#*|}
  lt_reset
  LT_KEEP=${LT_DIR}/as-it-was
  rm -f "${LT_KEEP}"
  ln "${LT_B}" "${LT_KEEP}"
  LT_INO=$(stat -f '%i' "${LT_B}")
  LT_WAS=$(cksum <"${LT_B}")
  eval "${lt_cmd}" >/dev/null 2>&1
  t_eq "${lt_name} puts a new file there, in one rename" \
    different \
    "$([ "$(stat -f '%i' "${LT_B}")" != "${LT_INO}" ] && echo different || echo same)"
  t_eq "so the file it replaced is whole, and still holds the untouched task" \
    "${LT_WAS}" "$(cksum <"${LT_KEEP}")"
  t_eq "and the ledger keeps its mode, not mktemp's" \
    644 "$(stat -f '%Lp' "${LT_B}")"
  rm -f "${LT_KEEP}"
done

# The scratch file has to be in the same directory as its target: across
# filesystems `mv` is a copy and an unlink, which has the hole back again.
lt_reset
LT_TMP=$(ledger_tmp "${LT_B}")
t_eq "a scratch file is made beside the file it will replace" \
  "${LT_DIR}" "$(dirname "${LT_TMP}")"
t_eq "with the target's mode, so the ledger stays readable" \
  644 "$(stat -f '%Lp' "${LT_TMP}")"
rm -f "${LT_TMP}"
ledger_tmp "" >/dev/null 2>&1
t_fails "and no file at all has no scratch file" "$?"

# Structural, because a seventh writer added later would reintroduce the hole
# silently: nothing in the ledger writes over a file it did not rename into
# place.
LT_INPLACE=$(grep -n 'cat "${tmp}" >"${f}"\|cat "${keep}" >"${f}"' \
  "${TEST_ROOT}"/lib/*.sh "${TEST_ROOT}"/bin/* |
  grep -v ':[0-9]*:[[:space:]]*#')
t_eq "no ledger writer rewrites its file in place" "" "${LT_INPLACE}"
LT_FARTMP=$(grep -n 'mktemp "${TMPDIR:-/tmp}/hzl-backlog' "${TEST_ROOT}"/lib/*.sh)
t_eq "and none of them builds the replacement on another filesystem" \
  "" "${LT_FARTMP}"

unset LT_DIR LT_B LT_KEEP LT_INO LT_WAS LT_TMP lt_case lt_name lt_cmd
unset LT_INPLACE LT_FARTMP

group 'backlog_archive_done'

arc_reset
ARC_N=$(backlog_archive_done "${ARC_B}")
t_eq "both completions move" 2 "${ARC_N}"
t_lacks "the backlog loses the closed task" "${ARC_B}" "(id:h-0002)"
t_lacks "and the one closed yesterday" "${ARC_B}" "(id:h-0005)"
t_has "the archive gains it" "${ARC_A}" "(id:h-0002)"
t_has "the todo stays put" "${ARC_B}" "(id:h-0001)"
t_has "so does the blocked task - it is what the human is here for" "${ARC_B}" "(id:h-0003)"
t_has "and the in-progress marker, which is a claim's projection" "${ARC_B}" "(id:h-0004)"
t_has "the fenced example is documentation, and is never swept" "${ARC_B}" "the fenced example nobody may sweep"
t_has "a completion takes its notes with it" "${ARC_A}" "note: a continuation line that belongs to h-0002"
t_lacks "and leaves none behind" "${ARC_B}" "note: a continuation line that belongs to h-0002"

t_eq "the archive carries the priority the task was closed at" \
  "1" "$(backlog_scan "${ARC_A}" | awk -F'\t' '$4 == "h-0002" {print $2}')"
t_eq "each of them" \
  "2" "$(backlog_scan "${ARC_A}" | awk -F'\t' '$4 == "h-0005" {print $2}')"

t_eq "a second sweep finds nothing left to move" 0 "$(backlog_archive_done "${ARC_B}")"
t_eq "and does not append the same task twice" \
  1 "$(grep -c "(id:h-0002)" "${ARC_A}")"

arc_reset
t_eq "a ledger with nothing closed sweeps nothing" 0 \
  "$(printf '# B\n\n## P1\n- [ ] (id:h-0001) waiting\n' >"${ARC_B}"; backlog_archive_done "${ARC_B}")"
t_eq "and writes no archive for it" 0 "$([ -e "${ARC_A}" ] && echo 1 || echo 0)"

# The crash the append-then-rewrite order is chosen for: the archive took the
# line and the process died before the backlog was rewritten. The repair is the
# next sweep, and it has to drop the duplicate rather than archive it again.
arc_reset
backlog_archive_done "${ARC_B}" >/dev/null
printf -- '- [x] (id:h-0002) closed last week <!-- done:2026-08-01T10:00+09:00 run:20260801-100000 -->\n' >>"${ARC_B}"
ARC_N=$(backlog_archive_done "${ARC_B}")
t_eq "a task left in both files is swept again" 1 "${ARC_N}"
t_lacks "out of the backlog" "${ARC_B}" "(id:h-0002)"
t_eq "and not into the archive a second time" 1 "$(grep -c "(id:h-0002)" "${ARC_A}")"

group 'the ledger is both files'

arc_reset
backlog_archive_done "${ARC_B}" >/dev/null

t_eq "ledger_files lists the backlog and its archive" \
  "${ARC_B} ${ARC_A}" "$(ledger_files "${ARC_B}" | tr '\n' ' ' | sed 's/ $//')"
t_eq "and only the backlog when nothing has been swept" \
  "${ARC_FIXTURE}" "$(ledger_files "${ARC_FIXTURE}" | tr '\n' ' ' | sed 's/ $//')"

t_eq "a marker is looked up across the ledger" "x" "$(ledger_marker_of_id "${ARC_B}" h-0002)"
t_eq "including one still in the backlog" "!" "$(ledger_marker_of_id "${ARC_B}" h-0003)"
t_eq "an id nowhere in it has no marker" "" "$(ledger_marker_of_id "${ARC_B}" h-9999)"

# The invariant the whole split turns on: an archived id is spent.
t_eq "the highest id counts archived tasks" 5 "$(ledger_max_id_num "${ARC_B}")"
t_eq "which the backlog alone no longer knows" 4 "$(backlog_max_id_num "${ARC_B}")"
printf -- '- [ ] a task with no id yet\n' >>"${ARC_B}"
backlog_assign_ids "${ARC_B}"
t_has "so allocation does not reissue a swept id" "${ARC_B}" "(id:h-0006) a task with no id yet"

t_eq "text is matched across the ledger" 0 \
  "$(ledger_has_text "${ARC_B}" "closed last week" && echo 0 || echo 1)"
t_eq "and text nobody wrote is not" 1 \
  "$(ledger_has_text "${ARC_B}" "never written anywhere" && echo 0 || echo 1)"
t_eq "a run's completions are found after they are swept" \
  "h-0002" "$(ledger_ids_done_by_run "${ARC_B}" 20260801-100000)"

group 'the morning report'

arc_reset
backlog_archive_done "${ARC_B}" >/dev/null

t_eq "a blocked task is reported with its date, id and text" \
  "2026-08-02	h-0003	needs a decision" \
  "$(ledger_blocked "${ARC_B}" | awk -F'\t' '{printf "%s\t%s\t%s", $1, $2, $4}')"
t_eq "and its reason, without the run id a person did not ask for" \
  "needs a name" "$(ledger_blocked "${ARC_B}" | cut -f3)"
t_eq "nothing else is blocked" 1 "$(ledger_blocked "${ARC_B}" | grep -c .)"

t_eq "completions are filtered by date" \
  "2026-09-05	h-0005	closed yesterday" "$(ledger_completed_since "${ARC_B}" 2026-09-01)"
t_eq "and reach back through the archive when asked to" \
  2 "$(ledger_completed_since "${ARC_B}" 2026-01-01 | grep -c .)"
t_eq "a window with nothing in it reports nothing" \
  0 "$(ledger_completed_since "${ARC_B}" 2026-12-01 | grep -c .)"

unset ARC_DIR ARC_B ARC_A ARC_FIXTURE ARC_N

# --- the blocked file ------------------------------------------------------

group 'ledger_blocked_file'

t_eq "the blocked file is named after the backlog beside it" \
  "/x/backlog.blocked.md" "$(ledger_blocked_file /x/backlog.md)"
t_eq "a backlog that is not .md still gets one" \
  "/x/queue.blocked" "$(ledger_blocked_file /x/queue)"
t_fails "and an empty path has none" "$(ledger_blocked_file "" >/dev/null 2>&1; echo $?)"

BLK_DIR=${TMPROOT}/blocked
mkdir -p "${BLK_DIR}"
BLK_B=${BLK_DIR}/backlog.md
BLK_F=${BLK_DIR}/backlog.blocked.md
BLK_A=${BLK_DIR}/backlog.completed.md

BLK_FIXTURE=${TMPROOT}/blocked-fixture.md
cat >"${BLK_FIXTURE}" <<'FIXTURE'
# Backlog

```
## P1
- [!] the fenced example nobody may sweep
```

## P1
- [ ] (id:h-0001) still waiting
- [!] (id:h-0002) needs a decision <!-- blocked:2026-08-02T10:00 reason:needs a name run:20260802-100000 -->
      note: a continuation line that belongs to h-0002
- [x] (id:h-0003) closed <!-- done:2026-08-01T10:00+09:00 run:20260801-100000 -->

## P2
- [~] (id:h-0004) in progress
- [!] (id:h-0005) needs a credential <!-- blocked:2026-09-05T23:00 reason:no token -->
FIXTURE

blk_reset() { cp "${BLK_FIXTURE}" "${BLK_B}"; rm -f "${BLK_F}" "${BLK_A}"; }

group 'backlog_sweep_blocked'

blk_reset
t_eq "both blocked tasks leave the backlog, and nothing comes back" \
  "2 0" "$(backlog_sweep_blocked "${BLK_B}")"
t_lacks "the backlog loses the blocked task" "${BLK_B}" "(id:h-0002)"
t_lacks "and the one at P2" "${BLK_B}" "(id:h-0005)"
t_has "the blocked file gains it" "${BLK_F}" "(id:h-0002)"
t_has "a blocked task takes its notes with it" "${BLK_F}" "note: a continuation line that belongs to h-0002"
t_lacks "and leaves none behind" "${BLK_B}" "note: a continuation line that belongs to h-0002"
t_has "the todo stays put - the backlog is the queue" "${BLK_B}" "(id:h-0001)"
t_has "so does the completion, which is the archive's to take" "${BLK_B}" "(id:h-0003)"
t_has "and the in-progress marker, which is a claim's projection" "${BLK_B}" "(id:h-0004)"
t_has "the fenced example is documentation, and is never swept" \
  "${BLK_B}" "the fenced example nobody may sweep"
t_eq "the blocked file carries the priority the task was blocked at" \
  "2" "$(backlog_scan "${BLK_F}" | awk -F'\t' '$4 == "h-0005" {print $2}')"

t_eq "a second sweep finds nothing to move either way" "0 0" "$(backlog_sweep_blocked "${BLK_B}")"
t_eq "and does not append the same task twice" 1 "$(grep -c "(id:h-0002)" "${BLK_F}")"

blk_reset
printf '# B\n\n## P1\n- [ ] (id:h-0001) waiting\n' >"${BLK_B}"
t_eq "a ledger with nothing blocked sweeps nothing" "0 0" "$(backlog_sweep_blocked "${BLK_B}")"
t_eq "and writes no blocked file for it" 0 "$([ -e "${BLK_F}" ] && echo 1 || echo 0)"

# The crash the append-then-rewrite order is chosen for, in the direction the
# archive cannot show: the blocked file took the line and the process died before
# the backlog was rewritten.
blk_reset
backlog_sweep_blocked "${BLK_B}" >/dev/null
printf -- '- [!] (id:h-0002) needs a decision <!-- blocked:2026-08-02T10:00 reason:needs a name -->\n' >>"${BLK_B}"
t_eq "a task left in both files is swept again" "1 0" "$(backlog_sweep_blocked "${BLK_B}")"
t_lacks "out of the backlog" "${BLK_B}" "(id:h-0002)"
t_eq "and not into the blocked file a second time" 1 "$(grep -c "(id:h-0002)" "${BLK_F}")"

# The residue is a task line and the notes under it, and dropping only the line
# sends the notes on to the destination alone — where they land under whichever
# task was written there last and are read as belonging to that one.
blk_reset
backlog_sweep_blocked "${BLK_B}" >/dev/null
{
  printf -- '- [!] (id:h-0002) needs a decision <!-- blocked:2026-08-02T10:00 reason:needs a name -->\n'
  printf -- '      note: a continuation line that belongs to h-0002\n'
  printf -- '- [!] (id:h-0006) a second blocked task, written after the residue\n'
} >>"${BLK_B}"
t_eq "the residue and a real block are both swept" "2 0" "$(backlog_sweep_blocked "${BLK_B}")"
t_eq "the note under a task that was already there is not written twice" \
  1 "$(grep -c "note: a continuation line that belongs to h-0002" "${BLK_F}")"
t_lacks "so it cannot be read as a note on the task written after it" \
  "${BLK_B}" "note: a continuation line that belongs to h-0002"
t_eq "and the task written after it is still swept, with its own line intact" \
  1 "$(grep -c "(id:h-0006)" "${BLK_F}")"

# A sweep that failed prints the same `0 0` a sweep with nothing to do prints,
# so it has to say separately that it failed — every caller of it decides
# something on the strength of that status.
BLK_STUCK=${TMPROOT}/blocked-stuck
mkdir -p "${BLK_STUCK}"
cp "${BLK_FIXTURE}" "${BLK_STUCK}/backlog.md"
mkdir -p "${BLK_STUCK}/backlog.blocked.md"
t_eq "a sweep that cannot write the blocked file still prints a count" \
  "0 0" "$(backlog_sweep_blocked "${BLK_STUCK}/backlog.md" 2>/dev/null)"
backlog_sweep_blocked "${BLK_STUCK}/backlog.md" >/dev/null 2>&1
t_fails "and says, separately from the count, that it did not do it" "$?"
t_has "so nothing was moved out of the backlog" \
  "${BLK_STUCK}/backlog.md" "(id:h-0002)"

cp "${BLK_FIXTURE}" "${BLK_STUCK}/backlog.md"
mkdir -p "${BLK_STUCK}/backlog.completed.md"
backlog_archive_done "${BLK_STUCK}/backlog.md" >/dev/null 2>&1
t_fails "the archive sweep says so too" "$?"
t_eq "while still printing a count that reads like nothing to do" \
  0 "$(backlog_archive_done "${BLK_STUCK}/backlog.md" 2>/dev/null)"
rmdir "${BLK_STUCK}/backlog.blocked.md" "${BLK_STUCK}/backlog.completed.md"

# Both callers read that status. Structural, because the suite does not drive
# `bin/hzl` or `bin/hzl-run` end to end: a call that ignored it would print `0`
# for a sweep that failed, and the only sign would be a task nobody picks up.
BLK_UNCHECKED=$(grep -n 'backlog_sweep_blocked\|backlog_archive_done' "${TEST_ROOT}"/bin/* |
  grep -v ':[0-9]*:[[:space:]]*#' |
  grep -v '||' |
  grep -v ':[0-9]*:if ')
t_eq "every sweep in bin/ is called for its status, not just its count" \
  "" "${BLK_UNCHECKED}"

group 'the way back'

# What makes this sweep different from the archive's: `[x]` is terminal and `[!]`
# is not, so a task that stops being blocked has to find its way home.
blk_reset
backlog_sweep_blocked "${BLK_B}" >/dev/null
backlog_set_state "${BLK_F}" h-0002 " " ""
backlog_set_state "${BLK_F}" h-0005 " " ""
t_eq "an unblocked task comes back" "0 2" "$(backlog_sweep_blocked "${BLK_B}")"
t_has "into the file the worksheet is built from" "${BLK_B}" "(id:h-0002)"
t_lacks "and out of the blocked file" "${BLK_F}" "(id:h-0002)"
t_has "with the notes that belong to it" "${BLK_B}" "note: a continuation line that belongs to h-0002"
t_eq "at the priority it left with" \
  "2" "$(backlog_scan "${BLK_B}" | awk -F'\t' '$4 == "h-0005" {print $2}')"
t_eq "so the runner still attacks P1 first" "h-0001" "$(backlog_next_id "${BLK_B}")"
t_eq "an in-progress marker stranded there comes back too - it is not blocked" \
  "1 1" "$(backlog_set_state "${BLK_B}" h-0002 "!" "blocked:2026-09-06T01:00 reason:again"
           printf -- '- [~] (id:h-0004) stranded\n' >>"${BLK_F}"
           backlog_sweep_blocked "${BLK_B}")"

# --- the ledger a person has to be able to read ----------------------------
#
# The sweep appends, and appending opens a `## P<n>` at the destination and
# leaves an emptied one behind at the source. Every block and every unblock
# therefore used to add a heading to each live file and never remove one, so a
# machine that blocked a few tasks a night turned a backlog into a run of
# single-task sections under repeated headings, with the empty shells of the
# original ones stranded above them. It parsed correctly the whole time. It was
# just no longer a file a person could open and see their queue in - which is
# the only reason the ledger is Markdown.

group 'the ledger stays readable'

NRM_DIR=${TMPROOT}/normalize
mkdir -p "${NRM_DIR}"
NRM_B=${NRM_DIR}/backlog.md
NRM_F=${NRM_DIR}/backlog.blocked.md
NRM_A=${NRM_DIR}/backlog.completed.md

cat >"${NRM_B}" <<'FIXTURE'
# Backlog

```
## P1
- [ ] the fenced example that is not a heading
```

## P1 - this week
- [ ] (id:h-0001) one
- [ ] (id:h-0002) two
      note: a continuation line that belongs to h-0002

## P2
- [ ] (id:h-0003) three

## P3
FIXTURE
cp "${NRM_B}" "${NRM_DIR}/before.md"

# Three tasks blocked one at a time and unblocked one at a time: six sweeps,
# which is a quiet night. Before the tidy this left eight headings across the
# two files and no task under the first three of them.
for NRM_ID in h-0001 h-0002 h-0003; do
  backlog_set_state "${NRM_B}" "${NRM_ID}" "!" "blocked:2026-09-07T09:00 reason:a person has to decide" >/dev/null
  backlog_sweep_blocked "${NRM_B}" >/dev/null
done
for NRM_ID in h-0001 h-0002 h-0003; do
  ledger_set_state "${NRM_B}" "${NRM_ID}" " " "" >/dev/null
  backlog_sweep_blocked "${NRM_B}" >/dev/null
done

t_eq "a task that went out and came back leaves the backlog exactly as it was" \
  "" "$(diff "${NRM_DIR}/before.md" "${NRM_B}")"
t_eq "so a priority has one heading however many sweeps touched it" \
  "1 1 1" "$(awk '
    /^[ \t]*(```|~~~)/ { infence = !infence; next }
    infence { next }
    /^##[ \t]*[Pp][0-9]+/ { n[$0]++ }
    END { printf "%d %d %d", n["## P1 - this week"], n["## P2"], n["## P3"] }' "${NRM_B}")"
t_eq "and the blocked file is not left with a heading per block either" \
  1 "$(grep -c '^## P1$' "${NRM_F}")"
t_eq "the order of attack is the one the file was written with" \
  "h-0001" "$(backlog_next_id "${NRM_B}")"
t_eq "and every task is still at the priority it was blocked at" \
  "1 1 2" "$(backlog_scan "${NRM_B}" | awk -F'\t' '$4 != "" {printf "%s%s", sep, $2; sep = " "}')"
t_has "a heading a person wrote for themselves is kept word for word" \
  "${NRM_B}" '## P1 - this week'
t_has "a heading left empty is theirs too, and survives" "${NRM_B}" '## P3'
t_has "the fenced example is documentation, not a section" \
  "${NRM_B}" '- [ ] the fenced example that is not a heading'
t_eq "and is still inside its fence, above the first real heading" \
  1 "$(awk '/^## P1 - this week/ { exit } /the fenced example/ { n++ } END { print n + 0 }' "${NRM_B}")"

# Idempotence is what makes it safe to run at the end of every sweep: a ledger
# that is already tidy is not rewritten, so nothing churns the file - or its
# mtime - on the nights nothing moved.
cp "${NRM_B}" "${NRM_DIR}/tidy.md"
backlog_normalize "${NRM_B}"
t_ok "normalising a tidy ledger succeeds" "$?"
t_eq "and changes nothing" "" "$(diff "${NRM_DIR}/tidy.md" "${NRM_B}")"

# The order within a priority is the order the tasks were written in, across
# sections that were separate before the merge - it is what `backlog_next_row`
# breaks ties on, so getting it wrong would silently reorder the queue.
printf '\n## P1\n- [ ] (id:h-0009) written last, in a section of its own\n' >>"${NRM_B}"
backlog_normalize "${NRM_B}"
t_eq "a merged section keeps its tasks in the order they were written" \
  "h-0001 h-0002 h-0009" \
  "$(backlog_scan "${NRM_B}" | awk -F'\t' '$2 == 1 && $4 != "" {printf "%s%s", sep, $4; sep = " "}')"

# The archive is the one ledger file this must not touch. Its repeated headings
# are the record of when things moved, and folding them together would say that
# tasks closed on the same night that closed a month apart.
NRM_ARC_DIR=${TMPROOT}/normalize-archive
mkdir -p "${NRM_ARC_DIR}"
printf '# Backlog\n\n## P1\n- [x] (id:h-0004) closed today <!-- done:2026-09-07T10:00+09:00 run:20260907-100000 -->\n\n## P1\n- [ ] (id:h-0005) still open\n' \
  >"${NRM_ARC_DIR}/backlog.md"
printf '# Done\n\n## P1\n- [x] (id:h-0101) first night\n\n## P1\n- [x] (id:h-0102) second night\n' \
  >"${NRM_ARC_DIR}/backlog.completed.md"
backlog_archive_done "${NRM_ARC_DIR}/backlog.md" >/dev/null
t_eq "the archive keeps a heading for every night it recorded" \
  3 "$(grep -c '^## P1$' "${NRM_ARC_DIR}/backlog.completed.md")"
t_eq "while the file the completion left is tidied like any other live file" \
  1 "$(grep -c '^## P1$' "${NRM_ARC_DIR}/backlog.md")"

# A file with no heading at all has nothing to group, and is handed back byte
# for byte rather than reformatted on a guess.
printf '# Backlog\n\n\n- [ ] (id:h-0201) no heading anywhere\n\n\n' >"${NRM_DIR}/flat.md"
cp "${NRM_DIR}/flat.md" "${NRM_DIR}/flat-before.md"
backlog_normalize "${NRM_DIR}/flat.md"
t_eq "a ledger with no priority heading is left alone" \
  "" "$(diff "${NRM_DIR}/flat-before.md" "${NRM_DIR}/flat.md")"

# The tidy is presentation, and the sweep's status is about whether the tasks
# moved. A caller reads that status to decide whether it may go on, so a
# heading it could not straighten must not be reported as a move that failed.
NRM_STUCK=${TMPROOT}/normalize-stuck
mkdir -p "${NRM_STUCK}"
cp "${NRM_DIR}/before.md" "${NRM_STUCK}/backlog.md"
backlog_set_state "${NRM_STUCK}/backlog.md" h-0001 "!" "blocked:2026-09-07T09:00 reason:x" >/dev/null
# A new task goes into the section it belongs to, and a section that exists but
# holds nothing is a section. It used to get a second heading at the foot of the
# file, which is the same defect the tidy exists for, arriving by another door -
# and this one a person sees the moment they type the command.
NRM_ADD=${TMPROOT}/normalize-add.md
printf '# Backlog\n\n```\n## P1\n- [ ] the fenced example\n```\n\n## P1\n- [ ] (id:h-0001) one\n      note: belongs to one\n\n## P2\n\n## P3\n' \
  >"${NRM_ADD}"
backlog_insert_at_priority "${NRM_ADD}" 2 "a task for the empty section"
t_eq "a task added to an empty section does not open a second heading for it" \
  1 "$(grep -c '^## P2$' "${NRM_ADD}")"
t_eq "and it is at the priority it was added to, not at the foot of the file" \
  2 "$(backlog_scan "${NRM_ADD}" | awk -F'\t' '$5 == "a task for the empty section" {print $2}')"
backlog_insert_at_priority "${NRM_ADD}" 1 "a task for a section that has one"
t_eq "a section that already has a task still takes the new one at its end" \
  "one a task for a section that has one" \
  "$(backlog_scan "${NRM_ADD}" | awk -F'\t' '$2 == 1 {printf "%s%s", sep, $5; sep = " "}')"
t_has "after the notes of the task before it, which are still that task's" \
  "${NRM_ADD}" 'note: belongs to one'
t_eq "the fenced example is not a section a task can be added to" \
  after "$([ "$(line_of "${NRM_ADD}" 'a task for a section that has one')" \
    -gt "$(line_of "${NRM_ADD}" '- [ ] the fenced example')" ] && echo after || echo inside)"
t_eq "and the fence still holds only what it was written with" \
  1 "$(awk '/^[ \t]*```/ { infence = !infence; next } infence && /^- \[/ { n++ } END { print n + 0 }' "${NRM_ADD}")"
backlog_insert_at_priority "${NRM_ADD}" 5 "a priority the file has never had"
t_eq "a priority with no heading at all still gets one" \
  1 "$(grep -c '^## P5$' "${NRM_ADD}")"
t_eq "and nothing the tidy would move afterwards" \
  "" "$(cp "${NRM_ADD}" "${NRM_ADD}.was"; backlog_normalize "${NRM_ADD}"; diff "${NRM_ADD}.was" "${NRM_ADD}")"

NRM_SAVED=$(declare -f backlog_normalize)
backlog_normalize() { return 1; }
backlog_sweep_blocked "${NRM_STUCK}/backlog.md" >/dev/null
t_ok "a tidy that failed does not turn a sweep that worked into a failure" "$?"
t_lacks "and the move it was reporting on really did happen" \
  "${NRM_STUCK}/backlog.md" "(id:h-0001)"
eval "${NRM_SAVED}"
t_ok "the real tidy is back" \
  "$(backlog_normalize "${NRM_STUCK}/backlog.md" >/dev/null 2>&1; echo $?)"

group 'closing a task where it lies'

blk_reset
backlog_sweep_blocked "${BLK_B}" >/dev/null
t_eq "a mutation finds the file the task is in" "${BLK_F}" "$(ledger_file_of_id "${BLK_B}" h-0002)"
ledger_set_state "${BLK_B}" h-0002 x "done:2026-09-06T01:00+09:00 by:human"
t_eq "and the marker lands there, not in the backlog" "x" "$(backlog_marker_of_id "${BLK_F}" h-0002)"
# One from each live file: h-0003 was closed in the backlog, h-0002 where it lay.
t_eq "the archive sweep empties both live files of completions" \
  2 "$(backlog_archive_done "${BLK_B}")"
t_has "the one closed while blocked reaches the archive" "${BLK_A}" "(id:h-0002)"
t_lacks "leaving the blocked file to open questions only" "${BLK_F}" "(id:h-0002)"

# --- closing a task, and saying why ----------------------------------------
#
# `hzl done <id> "what changed"` is two mutations and it used to report on one.
# The note is the whole reason the argument exists: the marker says a task
# ended, the note says what came of it, and a ledger full of completions nobody
# can account for is the thing this suite exists to keep from happening quietly.

# --- the window between choosing a task and claiming it --------------------
#
# `worksheet_write` reads the ledger without the backlog lock, and the claim
# that follows takes the lock and writes `[~]`. A human's `hzl done` takes the
# same lock, so it lands wholly inside that window or wholly outside it - and
# landing inside it, against an unconditional write, reopened a task somebody
# had just finished.

group 'a task closed while the worksheet was being built'

WC_B=${TMPROOT}/wc-backlog.md
cat >"${WC_B}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) still open when the claim comes
- [ ] (id:h-0002) a human closes this one in the window
- [ ] (id:h-0003) a human blocks this one in the window
- [~] (id:h-0004) another run already has this
FIXTURE

t_ok "an open task may be claimed" \
  "$(worksheet_claim_refusal "${WC_B}" h-0001 >/dev/null; echo $?)"
t_eq "and it says nothing about it" "" "$(worksheet_claim_refusal "${WC_B}" h-0001)"

# The window: the worksheet named h-0002, and by the time the lock is held the
# ledger says it is done.
ledger_set_state "${WC_B}" h-0002 x "done:now by:human"
t_fails "a task closed in the window may not be claimed" \
  "$(worksheet_claim_refusal "${WC_B}" h-0002 >/dev/null; echo $?)"
t_eq "and says which way it went" \
  "closed since the worksheet was built" "$(worksheet_claim_refusal "${WC_B}" h-0002)"

ledger_set_state "${WC_B}" h-0003 "!" "blocked:now"
t_fails "so may a task blocked in the window" \
  "$(worksheet_claim_refusal "${WC_B}" h-0003 >/dev/null; echo $?)"
t_eq "and it says so" \
  "blocked since the worksheet was built" "$(worksheet_claim_refusal "${WC_B}" h-0003)"

t_fails "a task already in progress is not claimed a second time" \
  "$(worksheet_claim_refusal "${WC_B}" h-0004 >/dev/null; echo $?)"

# `hzl block` moves the task out of the backlog entirely, so the id the
# worksheet is holding resolves to nothing. Not found is refused, not allowed:
# a task that left the file went somewhere this run has no business following.
t_fails "an id that is no longer in the backlog is refused" \
  "$(worksheet_claim_refusal "${WC_B}" h-9999 >/dev/null; echo $?)"
t_eq "saying it is gone rather than guessing" \
  "no longer in ${WC_B}" "$(worksheet_claim_refusal "${WC_B}" h-9999)"

# The whole point, stated once: the closed task keeps its `[x]`. This is the
# assertion the review asked for - a human's completion is not overwritten by a
# run that chose the task a moment before they closed it.
WC_CLAIMED=${TMPROOT}/wc-claimed.txt
: >"${WC_CLAIMED}"
for wc_id in h-0001 h-0002 h-0003 h-0004; do
  worksheet_claim_refusal "${WC_B}" "${wc_id}" >/dev/null || continue
  backlog_set_state "${WC_B}" "${wc_id}" "~" "run:20260906-000001"
  printf '%s\n' "${wc_id}" >>"${WC_CLAIMED}"
done
t_eq "the task the human closed is still closed" x "$(backlog_marker_of_id "${WC_B}" h-0002)"
t_eq "the task the human blocked is still blocked" "!" "$(backlog_marker_of_id "${WC_B}" h-0003)"
t_eq "only the still-open task was claimed" "h-0001" "$(cat "${WC_CLAIMED}")"
t_eq "and it is the one now in progress" "~" "$(backlog_marker_of_id "${WC_B}" h-0001)"

group 'ledger_close_with_note'

CN_B=${TMPROOT}/cn-backlog.md
cat >"${CN_B}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) a task a human closes with a reason
- [ ] (id:h-0002) a task closed with no reason given
FIXTURE

ledger_close_with_note "${CN_B}" h-0001 "done:2026-09-06T01:00+09:00 by:human" "what changed"
t_ok "closing a task with a note succeeds" "$?"
t_eq "the marker is set" x "$(backlog_marker_of_id "${CN_B}" h-0001)"
t_has "and the note is under it" "${CN_B}" "note: what changed"

ledger_close_with_note "${CN_B}" h-0002 "done:2026-09-06T01:00+09:00 by:human" ""
t_ok "a close with no note asked for is still a success" "$?"
t_eq "and the marker is set" x "$(backlog_marker_of_id "${CN_B}" h-0002)"

ledger_close_with_note "${CN_B}" h-9999 "done:now by:human" "note"
t_status "an id in no live file is still 3" 3 "$?"

# The regression. A note that was asked for and did not get written reported
# success, because the `backlog_add_note` call ended a `&&` list whose status
# an unconditional `return 0` discarded. `hzl done` then printed `done.` over a
# ledger that had recorded the completion and lost the reason for it.
#
# The note half is failed on its own. Breaking something both halves share -
# TMPDIR, the file's permissions - fails `backlog_set_state` first and never
# reaches the note, which would test the wrong branch and pass. So the note
# function itself is shadowed for exactly one call, and put back after.
cat >"${CN_B}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0003) a task whose note will not be written
FIXTURE
t_status "the real note write reports 3 for an id that is not there" \
  3 "$(backlog_add_note "${CN_B}" h-9999 "probe" >/dev/null 2>&1; echo $?)"

CN_SAVED_ADD=$(declare -f backlog_add_note)
backlog_add_note() { return 1; }
ledger_close_with_note "${CN_B}" h-0003 "done:now by:human" "the reason"
t_status "a note that could not be written is status 4, not success" 4 "$?"
eval "${CN_SAVED_ADD}"
t_ok "the real note function is back" \
  "$(backlog_add_note "${CN_B}" h-0003 "restored" >/dev/null 2>&1; echo $?)"

# The state under test is "closed, and the reason is missing" - not "nothing
# happened". If the marker had not landed, status 4 would be describing a
# different failure and the caller's message would be wrong.
t_eq "the marker landed even so" x "$(backlog_marker_of_id "${CN_B}" h-0003)"
t_lacks "and the ledger really is missing the reason" "${CN_B}" "note: the reason"

group 'the ledger is three files'

blk_reset
backlog_sweep_blocked "${BLK_B}" >/dev/null
backlog_archive_done "${BLK_B}" >/dev/null

t_eq "ledger_files lists the backlog, the blocked file and the archive" \
  "${BLK_B} ${BLK_F} ${BLK_A}" "$(ledger_files "${BLK_B}" | tr '\n' ' ' | sed 's/ $//')"
t_eq "ledger_live_files leaves the record out" \
  "${BLK_B} ${BLK_F}" "$(ledger_live_files "${BLK_B}" | tr '\n' ' ' | sed 's/ $//')"

t_eq "a marker is looked up across all three" "!" "$(ledger_marker_of_id "${BLK_B}" h-0005)"
t_eq "including one that has been archived" "x" "$(ledger_marker_of_id "${BLK_B}" h-0003)"
t_eq "the highest id counts what is blocked" 5 "$(ledger_max_id_num "${BLK_B}")"
t_eq "which the backlog alone no longer knows" 4 "$(backlog_max_id_num "${BLK_B}")"

# The count that must never be wrong: "nothing is blocked" read off the backlog
# alone is how a task waiting on a person becomes a task nobody is told about.
t_eq "blocked is counted across the live files" 2 "$(ledger_count "${BLK_B}" "!")"
t_eq "and the backlog alone would say nothing is" 0 "$(backlog_count "${BLK_B}" "!")"
t_eq "the morning report reads the blocked file" 2 "$(ledger_blocked "${BLK_B}" | grep -c .)"
t_eq "with its reason, and without the run id a person did not ask for" \
  "needs a name" "$(ledger_blocked "${BLK_B}" | awk -F'\t' '$2 == "h-0002" {print $3}')"

t_eq "ledger_scan_live sees both live files" \
  4 "$(ledger_scan_live "${BLK_B}" | grep -c .)"
t_eq "and not the archive" \
  0 "$(ledger_scan_live "${BLK_B}" | awk -F'\t' '$4 == "h-0003"' | grep -c .)"
t_fails "an id in no live file has no home" \
  "$(ledger_file_of_id "${BLK_B}" h-9999 >/dev/null 2>&1; echo $?)"
t_eq "and a mutation never reaches the archive" \
  3 "$(ledger_set_state "${BLK_B}" h-0003 " " "" >/dev/null 2>&1; echo $?)"

unset BLK_DIR BLK_B BLK_F BLK_A BLK_FIXTURE

# --- what the agent is denied ----------------------------------------------
#
# The ledger is three files and the agent may edit none of them: a run that
# could write the backlog could mark its own tasks done, and one that could
# write the blocked file could unblock the task it was told to leave alone.
# Only the backlog was named, so the other two were the agent's to edit.
#
# `generate_settings` is lifted out of `bin/hzl` and run against a template in
# the temp tree rather than reimplemented here, so that the assertions are about
# the substitutions the installer actually performs. Sourced rather than
# eval'd, and in a subshell, because it writes to ${HEINZEL_ROOT}/etc.

group 'the generated settings'

GS_SRC=${TMPROOT}/generate-settings.sh
sed -n '/^generate_settings() {/,/^}/p' "${TEST_ROOT}/bin/hzl" >"${GS_SRC}"
t_ok "generate_settings can be lifted out of bin/hzl whole" \
  "$(grep -c '^}' "${GS_SRC}" | grep -q '^1$' && echo 0 || echo 1)"

GS_ROOT=${TMPROOT}/gs-root
mkdir -p "${GS_ROOT}/etc"
cp "${TEST_ROOT}/etc/heinzel-settings.json.in" "${GS_ROOT}/etc/"
GS_OUT=${GS_ROOT}/etc/heinzel-settings.json
GS_WORK=${TMPROOT}/gs-work
GS_BACKLOG=${GS_WORK}/backlog.md

(
  HEINZEL_ROOT=${GS_ROOT}
  # shellcheck source=/dev/null
  . "${GS_SRC}"
  generate_settings "${GS_WORK}" "${GS_BACKLOG}"
)
t_ok "the settings generate from the template" "$?"
t_eq "and are valid JSON, which the runner checks before every run" \
  0 "$(jq -e . "${GS_OUT}" >/dev/null 2>&1; echo $?)"

# Every one of the three, both tools. Read as well as Edit: a worksheet is what
# the agent is given, and a run that could read the whole ledger could work on
# a task nobody put on it.
for gs_f in "${GS_BACKLOG}" "$(ledger_blocked_file "${GS_BACKLOG}")" \
            "$(ledger_archive "${GS_BACKLOG}")"; do
  for gs_tool in Read Edit; do
    t_eq "${gs_tool}(${gs_f##*/}) is denied" \
      1 "$(jq -r --arg r "${gs_tool}(//${gs_f#/})" \
             '[.permissions.deny[] | select(. == $r)] | length' "${GS_OUT}")"
  done
done

# The failure this file is written to make impossible: a placeholder that
# survives is still valid JSON, so the runner's check passes, and every rule
# carrying one matches nothing. A rule added to the template with no
# substitution behind it fails here rather than at three in the morning.
t_eq "no placeholder survives into the generated file" \
  "" "$(grep -o '__[A-Z_]*__' "${GS_OUT}" | sort -u | tr '\n' ' ' | sed 's/ *$//')"

# And the same check the other way round, so that a template rule nobody
# substitutes cannot be added without this suite saying so.
#
# The placeholder has to be *named* in `generate_settings`, not substituted by
# any particular means: `__WORKSPACE_RULES__` is a whole line replaced by a
# generated block, the way the plist's `__CALENDAR__` is, because the number of
# entries behind it is a function of how many workspaces are configured and
# `sed` replaces a placeholder with a value rather than with a list. Paired
# with the check above - that nothing survives into the output - this still
# catches the failure it was written for.
GS_MISSING=""
for gs_ph in $(grep -o '__[A-Z_]*__' "${GS_ROOT}/etc/heinzel-settings.json.in" | sort -u); do
  grep -q -- "${gs_ph}" "${GS_SRC}" || GS_MISSING="${GS_MISSING} ${gs_ph}"
done
t_eq "every placeholder in the template has a substitution behind it" \
  "" "${GS_MISSING}"

# --- safe mode --------------------------------------------------------------
#
# The commands that reach a cluster, a cloud account, a registry or another host
# are denied unless somebody wrote HEINZEL_SAFE_MODE=0. The default is the whole
# feature: an unattended run is exactly where a `terraform apply` would happen
# with nobody there to take it back, so "on unless told otherwise" is asserted
# with the variable *unset*, which is what a configuration file written before
# this existed looks like.

group 'safe mode'

GS_ROOT_D=${TMPROOT}/gs-safe-default
mkdir -p "${GS_ROOT_D}/etc"
cp "${TEST_ROOT}/etc/heinzel-settings.json.in" "${GS_ROOT_D}/etc/"
GS_OUT_D=${GS_ROOT_D}/etc/heinzel-settings.json
(
  HEINZEL_ROOT=${GS_ROOT_D}
  unset HEINZEL_SAFE_MODE
  # shellcheck source=/dev/null
  . "${GS_SRC}"
  generate_settings "${GS_WORK}" "${GS_BACKLOG}"
)
t_ok "settings generate with no HEINZEL_SAFE_MODE set at all" "$?"
t_eq "and are valid JSON" 0 "$(jq -e . "${GS_OUT_D}" >/dev/null 2>&1; echo $?)"

# Both pattern syntaxes for each, because a rule written in only one of them is
# accepted and then never consulted - the failure the template's comment names.
for gs_c in gcloud kubectl terraform helm ssh "docker push" "npm publish"; do
  for gs_form in " *)" ":*)"; do
    t_eq "Bash(${gs_c}${gs_form} is denied by default" 1 \
      "$(jq -r --arg r "Bash(${gs_c}${gs_form}" \
             '[.permissions.deny[] | select(. == $r)] | length' "${GS_OUT_D}")"
  done
done

t_eq "nothing on the safe-mode list is missing from the generated file" \
  "" "$(safe_mode_missing_rules "${GS_OUT_D}" | tr '\n' ' ' | sed 's/ *$//')"

# The one outward action a run is allowed. The release ritual in
# docs/RELEASING.md is built on it and the sandbox already allows exactly
# github.com, so safe mode denying it would mean every completed task ended in a
# `push pending` - and the deny list would be lying about what it is for.
t_eq "git push is not on the list - the release ritual still works" 0 \
  "$(jq -r '[.permissions.deny[] | select(. == "Bash(git push *)")] | length' "${GS_OUT_D}")"
t_eq "and the force-push denials the template carries are still there" 1 \
  "$(jq -r '[.permissions.deny[] | select(. == "Bash(git push --force*)")] | length' "${GS_OUT_D}")"

# Off, which is a sentence somebody has to write. The rest of the deny list is
# untouched by it: safe mode is a block of rules, not the file.
GS_ROOT_O=${TMPROOT}/gs-safe-off
mkdir -p "${GS_ROOT_O}/etc"
cp "${TEST_ROOT}/etc/heinzel-settings.json.in" "${GS_ROOT_O}/etc/"
GS_OUT_O=${GS_ROOT_O}/etc/heinzel-settings.json
(
  HEINZEL_ROOT=${GS_ROOT_O}
  HEINZEL_SAFE_MODE=0
  # shellcheck source=/dev/null
  . "${GS_SRC}"
  generate_settings "${GS_WORK}" "${GS_BACKLOG}"
)
t_ok "settings generate with safe mode off" "$?"
t_eq "and are still valid JSON" 0 "$(jq -e . "${GS_OUT_O}" >/dev/null 2>&1; echo $?)"
t_eq "kubectl is not denied when safe mode is off" 0 \
  "$(jq -r '[.permissions.deny[] | select(. == "Bash(kubectl *)")] | length' "${GS_OUT_O}")"
t_eq "sudo still is - safe mode is a block of rules, not the file" 1 \
  "$(jq -r '[.permissions.deny[] | select(. == "Bash(sudo)")] | length' "${GS_OUT_O}")"
t_eq "the ledger is denied either way" 1 \
  "$(jq -r --arg r "Edit(//${GS_BACKLOG#/})" \
         '[.permissions.deny[] | select(. == $r)] | length' "${GS_OUT_O}")"

# What the runner's gate reads. A conf that says 1 over a file generated when it
# said 0 is a control believed to be on and absent, so this has to name every
# missing command rather than shrug.
t_ok "safe_mode_missing_rules names what a file generated without it lacks" \
  "$(safe_mode_missing_rules "${GS_OUT_O}" | grep -qx kubectl && echo 0 || echo 1)"
t_eq "and names all of them" \
  "$(hzl_safe_mode_commands | grep -c .)" \
  "$(safe_mode_missing_rules "${GS_OUT_O}" | grep -c .)"
t_eq "the list itself holds no duplicates" \
  "$(hzl_safe_mode_commands | grep -c .)" \
  "$(hzl_safe_mode_commands | sort -u | grep -c .)"

unset GS_ROOT_D GS_OUT_D GS_ROOT_O GS_OUT_O gs_c gs_form
unset GS_SRC GS_ROOT GS_OUT GS_WORK GS_BACKLOG gs_f gs_tool gs_ph GS_MISSING

# --- the run prompt ---------------------------------------------------------
#
# The same failure as the settings template, in the other generated artefact: a
# `{{NAME}}` nobody renders is caught at 03:00 by an abort, which costs a night.
# Caught here instead, and for the same reason the settings check exists - a
# placeholder added to the prompt without the substitution behind it is the
# easiest of all these mistakes to make.

group 'the run prompt'

PR_MISSING=""
for pr_ph in $(grep -o '{{[A-Z_]*}}' "${TEST_ROOT}/prompts/backlog-run.md" | sort -u); do
  grep -q -- "render '${pr_ph}'" "${TEST_ROOT}/bin/hzl-run" || PR_MISSING="${PR_MISSING} ${pr_ph}"
done
t_eq "every placeholder in the run prompt is rendered by bin/hzl-run" "" "${PR_MISSING}"
unset PR_MISSING pr_ph

# --- what the web UI is served ---------------------------------------------
#
# `hzl dashboard` is the page's only source, and `hzl add` its only writer.
# The server in lib/web/server.py parses no ledger on purpose: one parse, in
# `backlog_scan`, and a second implementation of "what the queue says" written
# in JavaScript would be the copy that falls behind — the way `ledger_blocked`'s
# copy did. These assertions are about the contract that makes that possible,
# so they run the real commands rather than a fixture of what those commands
# are believed to print.
#
# `bin/hzl` finds its root by resolving its own path through every symlink, so
# a test root needs a real copy of the script; `lib` and `prompts` are linked
# because nothing here writes to them. The point of the root is `etc`: it is
# the only way to hand these commands a backlog that is not the machine's own.

group 'the dashboard document'

DB_ROOT=${TMPROOT}/db-root
DB_HOME=${TMPROOT}/db-home
DB_WORK=${TMPROOT}/db-work
DB_BACKLOG=${DB_HOME}/backlog.md
mkdir -p "${DB_ROOT}/bin" "${DB_ROOT}/etc" "${DB_HOME}" "${DB_WORK}"
cp "${TEST_ROOT}/bin/hzl" "${DB_ROOT}/bin/hzl"
ln -sf "${TEST_ROOT}/lib" "${DB_ROOT}/lib"
ln -sf "${TEST_ROOT}/prompts" "${DB_ROOT}/prompts"
cat >"${DB_ROOT}/etc/heinzel.conf" <<CONF
DEFAULT_WORKDIR="${DB_WORK}"
DEFAULT_BACKLOG="${DB_BACKLOG}"
HEINZEL_POSTURE=0
CONF
hzl_db() { HEINZEL_HOME=${DB_HOME} "${DB_ROOT}/bin/hzl" "$@"; }

cat >"${DB_BACKLOG}" <<'FIXTURE'
# Backlog

## P1
- [ ] (id:h-0001) 待っている仕事
- [!] (id:h-0002) 人を待っている <!-- blocked:2026-09-08T01:00:00+09:00 reason:実機が要る run:20260908-010000 -->
FIXTURE

group 'combined mode CLI'

DB_MODE_OUT=${TMPROOT}/mode.out
hzl_db help >"${DB_MODE_OUT}" 2>&1
t_has "help presents work mode" "${DB_MODE_OUT}" "hzl work [options]"
t_has "help presents mobile mode" "${DB_MODE_OUT}" "hzl mobile [options]"

hzl_db on >"${DB_MODE_OUT}" 2>&1
DB_OLD_RC=$?
t_fails "the old on command is refused" "${DB_OLD_RC}"
t_has "and tells the operator to choose a real mode" "${DB_MODE_OUT}" "choose 'hzl work' or 'hzl mobile'"

hzl_db status --json >"${DB_MODE_OUT}" 2>/dev/null
t_eq "status JSON reports the public off mode" off "$(jq -r .mode "${DB_MODE_OUT}")"

DB_MODE_EXPIRES=$(( $(now_epoch) + 3600 ))
jq -n \
  --arg boot_id "$(boot_id_now)" \
  --argjson expires "${DB_MODE_EXPIRES}" \
  --argjson pid "$$" \
  '{schema_version: 3, mode: "heinzel", operating_mode: "work",
    halt_reason: null, expires_at_epoch: $expires, boot_id: $boot_id,
    caffeinate_pid: $pid}' >"${DB_HOME}/state.json"
hzl_db status --json >"${DB_MODE_OUT}" 2>/dev/null
DB_STATUS_RC=$?
t_eq "live work status keeps the live exit contract" 10 "${DB_STATUS_RC}"
t_eq "and reports work as the public mode" work "$(jq -r .mode "${DB_MODE_OUT}")"

jq '.operating_mode = "mobile"' "${DB_HOME}/state.json" >"${DB_HOME}/state.next" &&
  mv "${DB_HOME}/state.next" "${DB_HOME}/state.json"
hzl_db status --json >"${DB_MODE_OUT}" 2>/dev/null
DB_STATUS_RC=$?
t_eq "live mobile status keeps the live exit contract" 10 "${DB_STATUS_RC}"
t_eq "and reports mobile as the public mode" mobile "$(jq -r .mode "${DB_MODE_OUT}")"
rm -f "${DB_HOME}/state.json"

hzl_db work --dry-run --force >"${DB_MODE_OUT}" 2>&1
t_ok "work dry-run validates without changing posture" "$?"
t_has "and names the mode it would enter" "${DB_MODE_OUT}" "would enter work mode"

hzl_db mobile --dry-run >"${DB_MODE_OUT}" 2>&1
t_ok "mobile dry-run does not demand interactive confirmation" "$?"
t_has "but still carries the battery warning" "${DB_MODE_OUT}" "may drain it while travelling"

# `</dev/null` is the assertion, not scaffolding: the refusal being checked is
# the one `mobile` makes when there is no terminal to ask at. Run from a real
# terminal without it, this line inherits the developer's tty, `mobile` prompts,
# and the whole suite blocks on a y/N nobody is watching for.
hzl_db mobile </dev/null >"${DB_MODE_OUT}" 2>&1
DB_MOBILE_RC=$?
t_fails "non-interactive mobile requires explicit consent" "${DB_MOBILE_RC}"
t_has "and tells automation how to give it" "${DB_MODE_OUT}" "re-run with --yes"

hzl_db work --yes </dev/null >"${DB_MODE_OUT}" 2>&1
t_fails "work has no --yes to give" "$?"
t_has "and says so before it validates anything else" \
  "${DB_MODE_OUT}" "work: unknown option --yes"

# JSON before anything else is worth asking: the server hands this to the page
# verbatim, and a page that cannot parse it shows nothing at all.
DB_OUT=${TMPROOT}/dashboard.json
hzl_db dashboard --days 1 >"${DB_OUT}" 2>/dev/null
t_eq "hzl dashboard emits JSON" 0 "$(jq -e . "${DB_OUT}" >/dev/null 2>&1; echo $?)"
for db_k in generated_at host version backlog session schedule workspaces tasks runs log; do
  t_eq "it carries .${db_k}" 1 \
    "$(jq --arg k "${db_k}" 'if has($k) then 1 else 0 end' "${DB_OUT}" 2>/dev/null)"
done

# Markers and routing come from the ledger's own parse, so a task reads the
# same on the page as it does in `hzl next`.
t_eq "a todo is in the document with its marker" \
  "1" "$(jq '[.tasks[] | select(.marker == " ")] | length' "${DB_OUT}" 2>/dev/null)"
t_eq "and a blocked task carries the reason a person wrote" \
  "実機が要る" "$(jq -r '[.tasks[] | select(.marker == "!")][0].reason // ""' "${DB_OUT}" 2>/dev/null)"
t_eq "with the run that blocked it, so a judgement can be traced back" \
  "20260908-010000" "$(jq -r '[.tasks[] | select(.marker == "!")][0].run // ""' "${DB_OUT}" 2>/dev/null)"
t_eq "and no task carries its raw comment through to the page" \
  "0" "$(jq '[.tasks[] | select(has("meta"))] | length' "${DB_OUT}" 2>/dev/null)"
t_eq "an untagged task is shown in the workspace a run would use" \
  "$(basename "${DB_WORK}")" "$(jq -r '[.tasks[] | select(.marker == " ")][0].workspace' "${DB_OUT}" 2>/dev/null)"

# `status --json` exits 10 while a session is live. Taken as a failure, the
# document gained the word `null` after a perfectly good body — valid nowhere,
# and only when a session was running, which is the case the page is for.
t_eq "the session object survives status's exit code" \
  "object" "$(jq -r '.session | type' "${DB_OUT}" 2>/dev/null)"

group 'hzl add'

hzl_db add --priority 2 "フォームから積んだ仕事" >/dev/null 2>&1
t_ok "a task can be added without an editor" "$?"
t_has "and lands under the priority it was given" "${DB_BACKLOG}" "## P2"
t_has "with its text intact" "${DB_BACKLOG}" "フォームから積んだ仕事"
t_eq "and is given an id, so whoever added it can name it" \
  1 "$(grep -c 'フォームから積んだ仕事' "${DB_BACKLOG}")"
t_eq "the id is allocated, not left for the next run" \
  1 "$(grep -c '(id:[a-z]*-[0-9]*).*フォームから積んだ仕事' "${DB_BACKLOG}")"

# Two identical tasks are worked twice and the second finds nothing to do. A
# double-submitted form is the ordinary way to produce that pair.
hzl_db add --priority 2 "フォームから積んだ仕事" >/dev/null 2>&1
t_eq "the same task word for word is refused, not queued twice" 4 "$?"
t_eq "and the ledger still holds exactly one of it" \
  1 "$(grep -c 'フォームから積んだ仕事' "${DB_BACKLOG}")"

hzl_db add --priority 0 "範囲外" >/dev/null 2>&1
t_fails "a priority outside 1..99 is refused" "$?"
hzl_db add --dir nosuch "行き先なし" >/dev/null 2>&1
t_fails "a workspace nobody configured is refused before it is queued" "$?"
hzl_db add "" >/dev/null 2>&1
t_fails "and so is an empty task" "$?"

unset DB_ROOT DB_HOME DB_WORK DB_BACKLOG DB_OUT db_k

# --- verdict ---------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
