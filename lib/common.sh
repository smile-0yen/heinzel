#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/common.sh — configuration, session state, the backlog ledger, time and power.
#
# Sourced by every executable. Sourcing this file must never change the machine:
# it defines functions and assigns variables, and does nothing else.
#
# Requires HEINZEL_ROOT to be set by the caller (see hzl_resolve_root).

# Multibyte truncation is locale-dependent (DESIGN 6.3). Fix it once, here.
export LC_CTYPE=UTF-8

HEINZEL_VERSION="0.3.14"

# The TTL ceiling is deliberately not configurable. A session that can be
# created with an unbounded lifetime is not a session, it is a mode.
MAX_DURATION_SEC=86400

# --- record schemas --------------------------------------------------------
#
# The three records that outlive a run and are read by something other than the
# code that wrote them (docs/RUNTIME-BACKENDS.md §13.7, §14.1). Versioning them
# is additive in both directions, and the two halves of that are what make it
# worth anything:
#
#   * a v2 writer keeps every v1 field, so a reader that never heard of the
#     version keeps working;
#   * a reader that finds no version field at all is looking at v1, and reads it
#     where it lies. Nothing migrates a file on the way past. `hzl status` is
#     read-only, and a status command that rewrote the state file would make a
#     rollback to the previous build unreadable — for a field it only printed.
HEINZEL_STATE_SCHEMA=2
HEINZEL_RESULT_SCHEMA=2
HEINZEL_RUN_RECORD_SCHEMA=2

# --- paths -----------------------------------------------------------------

# Resolve the repository root through any number of symlinks. hzl is normally
# reached through ~/.local/bin/hzl, so $0 is not where the code lives.
hzl_resolve_root() {
  local src=$1 dir
  while [ -L "${src}" ]; do
    dir=$(cd -P "$(dirname "${src}")" && pwd) || return 1
    src=$(readlink "${src}")
    case ${src} in
      /*) ;;
      *) src=${dir}/${src} ;;
    esac
  done
  (cd -P "$(dirname "${src}")/.." && pwd)
}

HEINZEL_HOME=${HEINZEL_HOME:-${HOME}/.heinzel}
STATE_FILE=${HEINZEL_HOME}/state.json
LOG_DIR=${HEINZEL_HOME}/logs
RUNNER_LOG=${LOG_DIR}/runner.log
RUNS_JSONL=${LOG_DIR}/runs.jsonl
# `run.pid` is the file `hzl off` kills by, and it is written by the run that
# holds the workspace writer lease. There was a `run.lock` beside it, held by
# `lockf` for the whole of a run; it is gone, and what says "one runner" now is
# the lease and the short backlog lock (docs/RUNTIME-BACKENDS.md §14.3).
RUN_PID_FILE=${HEINZEL_HOME}/run.pid
CAFFEINATE_PID_FILE=${HEINZEL_HOME}/caffeinate.pid

# --- output ----------------------------------------------------------------

if [ -t 1 ]; then
  _C_GREEN=$(printf '\033[32m')
  _C_RED=$(printf '\033[31m')
  _C_YELLOW=$(printf '\033[33m')
  _C_DIM=$(printf '\033[2m')
  _C_OFF=$(printf '\033[0m')
else
  _C_GREEN="" _C_RED="" _C_YELLOW="" _C_DIM="" _C_OFF=""
fi

say()   { printf '%s\n' "$*"; }
good()  { printf '%s%s%s\n' "${_C_GREEN}" "$*" "${_C_OFF}"; }
bad()   { printf '%s%s%s\n' "${_C_RED}" "$*" "${_C_OFF}"; }
dim()   { printf '%s%s%s\n' "${_C_DIM}" "$*" "${_C_OFF}"; }
warn()  { printf '%swarning:%s %s\n' "${_C_YELLOW}" "${_C_OFF}" "$*" >&2; }
err()   { printf '%serror:%s %s\n' "${_C_RED}" "${_C_OFF}" "$*" >&2; }
die()   { err "$*"; exit 1; }

# Two-column status line. The UI is English, so a column count is a column
# count; the byte-width arithmetic macmode needed is gone with the Japanese.
field() { printf '  %-26s %s\n' "$1" "$2"; }

# Truncate to N characters, not N bytes.
trunc() {
  local s=$1 n=$2
  if [ ${#s} -le "${n}" ]; then
    printf '%s' "${s}"
  else
    printf '%s...' "$(printf '%s' "${s}" | cut -c "1-$((n - 3))")"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Flatten to a single line. The ledger is line-oriented and its metadata lives
# in a trailing comment, so an embedded newline would break the format; it also
# happens to be the thing awk -v refuses to accept.
oneline() {
  printf '%s' "$*" | tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# --- time ------------------------------------------------------------------

now_epoch() { date +%s; }

# ISO8601 with a colon in the offset, from an epoch (default: now).
iso_at() {
  local e=${1:-}
  if [ -n "${e}" ]; then
    date -r "${e}" +%Y-%m-%dT%H:%M:%S%z
  else
    date +%Y-%m-%dT%H:%M:%S%z
  fi | sed -E 's/([0-9][0-9])([0-9][0-9])$/\1:\2/'
}

# Short human stamp used in status output and reason strings.
short_at() { date -r "$1" +'%m-%d %H:%M' 2>/dev/null; }

# "10h" / "90m" / "3600" -> seconds. Rejects anything else, and anything
# outside [60, MAX_DURATION_SEC], by returning non-zero.
parse_duration() {
  local d=$1 n
  [ -n "${d}" ] || return 1
  case ${d} in
    *h) n=${d%h}; n=$((n * 3600)) 2>/dev/null || return 1 ;;
    *m) n=${d%m}; n=$((n * 60)) 2>/dev/null || return 1 ;;
    *s) n=${d%s} ;;
    *)  n=${d} ;;
  esac
  case ${n} in
    "") return 1 ;;
    *[!0-9]*) return 1 ;;
  esac
  [ "${n}" -ge 60 ] || return 1
  [ "${n}" -le "${MAX_DURATION_SEC}" ] || return 1
  printf '%s' "${n}"
}

# Absolute path, without requiring the target to exist. launchd runs with
# cwd=/, so a relative path here is not a latent bug, it is a certain abort.
abspath() {
  local p=$1 dir base
  [ -n "${p}" ] || return 1
  # The tilde is quoted on purpose: case patterns undergo tilde expansion, so
  # an unquoted ~/* would expand to the home directory and never match the
  # literal "~/..." string this is here to catch.
  # shellcheck disable=SC2088
  case ${p} in
    /*) ;;
    "~") p=${HOME} ;;
    "~/"*) p="${HOME}/${p#\~/}" ;;
    *) p="$(pwd)/${p}" ;;
  esac
  dir=$(dirname "${p}")
  base=$(basename "${p}")
  if [ -d "${dir}" ]; then dir=$(cd -P "${dir}" && pwd); fi
  case ${base} in
    .) printf '%s' "${dir}" ;;
    *) printf '%s/%s' "${dir%/}" "${base}" ;;
  esac
}

# --- power -----------------------------------------------------------------

on_ac_power() { pmset -g batt 2>/dev/null | head -1 | grep -q "AC Power"; }

battery_pct() { pmset -g batt 2>/dev/null | grep -o '[0-9]\{1,3\}%' | head -1; }

# pmset -g omits SleepDisabled entirely until it has been set at least once,
# and prints it as 0 afterwards. An empty read therefore means 0 as well.
sleep_disabled() {
  local v
  v=$(pmset -g 2>/dev/null | awk '/SleepDisabled/{print $2; exit}')
  printf '%s' "${v:-0}"
}

# Unique per boot, constant while up. Never kern.boottime: that value moves
# without a reboot, which silently no-ops every run after the first sleep/wake
# cycle (DESIGN 5).
boot_id_now() {
  local v
  v=$(sysctl -n kern.bootsessionuuid 2>/dev/null)
  if [ -n "${v}" ]; then
    printf '%s' "${v}"
    return 0
  fi
  # Fallback for environments without that sysctl: seconds only, anchored so
  # the pattern cannot capture usec.
  sysctl -n kern.boottime 2>/dev/null |
    sed -n 's/^{ sec = \([0-9][0-9]*\),.*/\1/p' | tr -d '\n'
}

# Two boot ids match if they are equal; when both are numeric (the fallback
# path) allow 120s of clock correction.
boot_id_matches() {
  local saved=$1 now=$2 d
  [ -z "${saved}" ] && return 0
  [ "${saved}" = "${now}" ] && return 0
  case ${saved}${now} in
    *[!0-9]*) return 1 ;;
  esac
  d=$((saved - now))
  [ ${d} -lt 0 ] && d=$((-d))
  [ ${d} -le 120 ]
}

pid_alive() {
  local p=$1
  case ${p} in
    "") return 1 ;;
    0) return 1 ;;
    null) return 1 ;;
    *[!0-9]*) return 1 ;;
  esac
  kill -0 "${p}" 2>/dev/null
}

# --- configuration ---------------------------------------------------------

# Review-related keys take environment over conf, because the documented way to
# try the review pipeline is `HEINZEL_REVIEW=1 hzl run-now`. If conf silently
# won, that command would produce a run that reviewed nothing while claiming to.
_HZ_ENV_KEYS="HEINZEL_REVIEW HEINZEL_EXECUTOR_ENGINE HEINZEL_REVIEWER_ENGINE
HEINZEL_CODEX_MODEL HEINZEL_CODEX_EFFORT HEINZEL_REVIEW_ON_REVISE
HEINZEL_REVIEW_TIMEOUT HEINZEL_REVIEW_MAX_PATCH_BYTES
HEINZEL_CODEX_IGNORE_USER_CONFIG HEINZEL_MODEL HEINZEL_EFFORT"

hzl_load_conf() {
  local k v line saved_env="" conf="${HEINZEL_ROOT}/etc/heinzel.conf"

  for k in ${_HZ_ENV_KEYS}; do
    eval "v=\${${k}:-}"
    if [ -n "${v}" ]; then
      saved_env="${saved_env}${k} ${v}
"
    fi
  done

  # Defaults. Anything a stranger would have to change lives here and in
  # etc/heinzel.conf.example, not scattered through the code.
  HEINZEL_LABEL="local.heinzel"
  HEINZEL_HOURS="1 2 3 4 5"
  DEFAULT_MAX_TASKS_TOTAL=3
  DEFAULT_MAX_TASKS=3
  DEFAULT_RUN_TIMEOUT=3600
  DEFAULT_DURATION="10h"
  DEFAULT_WORKDIR=""
  DEFAULT_BACKLOG=""
  LOG_RETENTION_DAYS=14
  HEINZEL_MODEL="claude-opus-5"
  HEINZEL_EFFORT="xhigh"
  HEINZEL_EXECUTOR_ENGINE="claude"
  HEINZEL_REVIEWER_ENGINE="codex"
  HEINZEL_CODEX_MODEL="gpt-5.6-sol"
  HEINZEL_CODEX_EFFORT="xhigh"
  # Review is opt-in on a fresh install: it costs money and needs a second
  # engine, and a tool that bills you by default on first run is impolite.
  HEINZEL_REVIEW=0
  HEINZEL_REVIEW_ON_REVISE="note-only"
  HEINZEL_REVIEW_TIMEOUT=900
  HEINZEL_REVIEW_MAX_PATCH_BYTES=200000
  HEINZEL_CODEX_IGNORE_USER_CONFIG=0
  # Posture is opt-in: with no configuration we refuse rather than guess at
  # someone else's firewall (DESIGN 8).
  HEINZEL_POSTURE=0
  HEINZEL_REMOTE_SCREENLOCK=300
  HEINZEL_TRAVEL_SCREENLOCK="immediate"
  HEINZEL_REMOTE_IDLE_SLEEP=0
  HEINZEL_TRAVEL_IDLE_SLEEP=10
  HEINZEL_CLAUDE_SETTINGS="${HOME}/.claude/settings.json"

  # shellcheck source=/dev/null
  [ -f "${conf}" ] && . "${conf}"

  if [ -n "${saved_env}" ]; then
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      eval "${line%% *}=\"\${line#* }\""
    done <<EOF
${saved_env}
EOF
  fi
  return 0
}

# Principle 6: a misspelling must fail at startup, not silently change what the
# unattended run does at 03:00.
hzl_validate_conf() {
  local h n v

  [ -n "${HEINZEL_HOURS}" ] || { err "HEINZEL_HOURS is empty"; return 1; }
  for h in ${HEINZEL_HOURS}; do
    case ${h} in
      "") err "HEINZEL_HOURS contains an empty entry"; return 1 ;;
      *[!0-9]*) err "HEINZEL_HOURS: '${h}' is not an integer"; return 1 ;;
    esac
    if [ "${h}" -gt 23 ]; then
      err "HEINZEL_HOURS: ${h} is out of range 0-23"
      return 1
    fi
  done

  for n in DEFAULT_MAX_TASKS_TOTAL DEFAULT_MAX_TASKS DEFAULT_RUN_TIMEOUT \
           LOG_RETENTION_DAYS HEINZEL_REVIEW_TIMEOUT HEINZEL_REVIEW_MAX_PATCH_BYTES; do
    eval "v=\${${n}}"
    case ${v} in
      "") err "${n} is empty"; return 1 ;;
      *[!0-9]*) err "${n}: '${v}' is not a positive integer"; return 1 ;;
    esac
    [ "${v}" -ge 1 ] || { err "${n} must be >= 1"; return 1; }
  done

  case ${HEINZEL_REVIEW} in
    0|1) ;;
    *) err "HEINZEL_REVIEW must be 0 or 1 (got '${HEINZEL_REVIEW}')"; return 1 ;;
  esac
  case ${HEINZEL_POSTURE} in
    0|1) ;;
    *) err "HEINZEL_POSTURE must be 0 or 1 (got '${HEINZEL_POSTURE}')"; return 1 ;;
  esac
  case ${HEINZEL_CODEX_IGNORE_USER_CONFIG} in
    0|1) ;;
    *) err "HEINZEL_CODEX_IGNORE_USER_CONFIG must be 0 or 1"; return 1 ;;
  esac
  case ${HEINZEL_REVIEW_ON_REVISE} in
    note-only|fix-once|block) ;;
    *) err "HEINZEL_REVIEW_ON_REVISE must be note-only, fix-once or block"; return 1 ;;
  esac
  case ${HEINZEL_EXECUTOR_ENGINE} in
    claude|codex) ;;
    *) err "HEINZEL_EXECUTOR_ENGINE must be claude or codex"; return 1 ;;
  esac
  case ${HEINZEL_REVIEWER_ENGINE} in
    claude|codex) ;;
    *) err "HEINZEL_REVIEWER_ENGINE must be claude or codex"; return 1 ;;
  esac
  # An effort typo degrades differently per engine: claude warns and completes
  # at its default (invisible), codex gets a 400 and the review fails. Neither
  # is allowed to happen at 03:00.
  case ${HEINZEL_EFFORT} in
    ""|low|medium|high|xhigh|max) ;;
    *) err "HEINZEL_EFFORT: '${HEINZEL_EFFORT}' is not a valid effort"; return 1 ;;
  esac
  case ${HEINZEL_CODEX_EFFORT} in
    ""|none|minimal|low|medium|high|xhigh|max) ;;
    *) err "HEINZEL_CODEX_EFFORT: '${HEINZEL_CODEX_EFFORT}' is not a valid effort"; return 1 ;;
  esac
  parse_duration "${DEFAULT_DURATION}" >/dev/null || {
    err "DEFAULT_DURATION: '${DEFAULT_DURATION}' is not a valid duration in [60s, 24h]"
    return 1
  }
  return 0
}

# Normalised, de-duplicated, ascending. One source of truth for the schedule:
# both the plist and the runner's window guard are generated from this value.
hours_normalised() {
  printf '%s\n' ${HEINZEL_HOURS} | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}

in_window() {
  local now h
  now=$(date +%H)
  now=${now#0}
  [ -z "${now}" ] && now=0
  for h in ${HEINZEL_HOURS}; do
    [ "${h}" -eq "${now}" ] && return 0
  done
  return 1
}

# How many scheduled slots fall between now and a deadline. `on` uses this to
# warn that a TTL will expire before anything can possibly run.
slots_within() {
  local until=$1 n=0 probe h hh
  probe=$(now_epoch)
  while [ "${probe}" -lt "${until}" ]; do
    probe=$((probe + 3600))
    [ "${probe}" -ge "${until}" ] && break
    hh=$(date -r "${probe}" +%H)
    hh=${hh#0}
    [ -z "${hh}" ] && hh=0
    for h in ${HEINZEL_HOURS}; do
      if [ "${h}" -eq "${hh}" ]; then
        n=$((n + 1))
        break
      fi
    done
  done
  printf '%s' "${n}"
}

# --- session state ---------------------------------------------------------

# Read one field, given a jq path. The jq `//` operator must never be used
# here: `false // $d` yields $d, so every boolean field would silently read as
# its default.
state_get() {
  local path=$1 default=${2:-} v
  [ -r "${STATE_FILE}" ] || { printf '%s' "${default}"; return 1; }
  v=$(jq -r --arg d "${default}" "${path} as \$v | if \$v == null then \$d else \$v end" \
      "${STATE_FILE}" 2>/dev/null) || { printf '%s' "${default}"; return 1; }
  printf '%s' "${v}"
}

# Apply a jq filter to the state file atomically. Validates before replacing: a
# torn state file cannot be repaired without knowing what used to be in it.
state_update() {
  local filter=$1
  shift
  local tmp
  [ -f "${STATE_FILE}" ] || return 1
  tmp=$(mktemp "${HEINZEL_HOME}/.state.XXXXXX") || return 1
  if jq "$@" "${filter}" "${STATE_FILE}" >"${tmp}" 2>/dev/null &&
     jq -e . "${tmp}" >/dev/null 2>&1; then
    chmod 600 "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" && return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Which schema wrote the state file. There was no field before v2, so a file
# that has none is v1 — and one written by a later build than this one is read
# for the fields this build knows rather than refused: the fields are additive,
# so an unknown version is not an unreadable file (§14.1).
state_schema_version() {
  local v
  v=$(state_get .schema_version 1)
  case ${v} in
    ""|*[!0-9]*) printf 1 ;;
    *) printf '%s' "${v}" ;;
  esac
}

# The same value as a JSON scalar, for the records that report it: a number
# when there is a file to have a schema, and null when there is none. A machine
# that never ran `hzl on` has no state schema, and saying `1` there would be a
# claim about a file that does not exist.
state_schema_json() {
  if [ -r "${STATE_FILE}" ]; then
    state_schema_version
  else
    printf null
  fi
}

# The runtime backend this session's runs go to. Everything written before the
# field existed ran on `local`, which is exactly what an absent value means.
state_runtime_backend() {
  local v
  v=$(state_get .runtime_backend "")
  case ${v} in
    ""|null) printf local ;;
    *) printf '%s' "${v}" ;;
  esac
}

state_write() {
  local json=$1 tmp
  mkdir -p "${HEINZEL_HOME}" || return 1
  chmod 700 "${HEINZEL_HOME}" 2>/dev/null
  tmp=$(mktemp "${HEINZEL_HOME}/.state.XXXXXX") || return 1
  if printf '%s' "${json}" | jq -e . >"${tmp}" 2>/dev/null; then
    chmod 600 "${tmp}" && mv -f "${tmp}" "${STATE_FILE}" && return 0
  fi
  rm -f "${tmp}"
  return 1
}

# The composed function (DESIGN 5.1). Short-circuit AND, cheapest gate first.
# Any single false lands on `normal`, and there is only one direction to fall.
# HZ_REASON is set to the one reason string for the gate that failed; each
# string maps to exactly one row in the RUNBOOK.
HZ_MODE=""
HZ_REASON=""

# Sets HZ_MODE and HZ_REASON. It assigns rather than prints because a caller
# that wraps this in $( ) runs it in a subshell, and the reason string set
# there would be discarded - which is exactly how `status` came to report a
# session as off with no explanation.
hzl_eval_mode() {
  HZ_MODE=normal
  HZ_REASON=""
  local v now exp saved_boot

  if [ ! -e "${STATE_FILE}" ]; then
    HZ_REASON="no state file (never started)"
    HZ_MODE=normal; return
  fi
  if [ ! -r "${STATE_FILE}" ]; then
    HZ_REASON="state.json is unreadable (permissions - was hzl run under sudo?)"
    HZ_MODE=normal; return
  fi
  if ! jq -e . "${STATE_FILE}" >/dev/null 2>&1; then
    HZ_REASON="state.json is corrupt"
    HZ_MODE=normal; return
  fi

  v=$(state_get .mode normal)
  if [ "${v}" != heinzel ]; then
    HZ_REASON="mode is normal"
    HZ_MODE=normal; return
  fi

  v=$(state_get .halt_reason "")
  if [ -n "${v}" ] && [ "${v}" != null ]; then
    HZ_REASON="halted: ${v} (clear it with 'hzl resume')"
    HZ_MODE=normal; return
  fi

  now=$(now_epoch)
  exp=$(state_get .expires_at_epoch 0)
  case ${exp} in
    ""|*[!0-9]*) exp=0 ;;
  esac
  if [ "${now}" -ge "${exp}" ]; then
    HZ_REASON="expired ($(short_at "${exp}")) - run 'hzl off', sleep settings are still changed"
    HZ_MODE=normal; return
  fi

  saved_boot=$(state_get .boot_id "")
  if ! boot_id_matches "${saved_boot}" "$(boot_id_now)"; then
    HZ_REASON="boot session mismatch (rebooted, or an old state file)"
    HZ_MODE=normal; return
  fi

  v=$(state_get .caffeinate_pid 0)
  if ! pid_alive "${v}"; then
    HZ_REASON="the caffeinate marker (pid ${v}) is gone"
    HZ_MODE=normal; return
  fi

  # Gate 7: where the machine is, not what state it is in. The runner's AC gate
  # catches the bag; this one catches the cafe.
  if [ "$(posture_now)" = travel ]; then
    HZ_REASON="posture is travel"
    HZ_MODE=normal; return
  fi

  HZ_MODE=heinzel
}

# Convenience wrapper for the many places that only need the value. Callers
# that also need HZ_REASON must call hzl_eval_mode directly.
effective_mode() {
  hzl_eval_mode
  printf '%s' "${HZ_MODE}"
}

# --- logging ---------------------------------------------------------------

# One line per event. `kind` is normative: other scripts branch on it.
log_event() {
  local kind=$1
  shift
  mkdir -p "${LOG_DIR}" 2>/dev/null || return 0
  printf '%s %-6s %s\n' "$(iso_at)" "${kind}" "$*" >>"${RUNNER_LOG}"
}

# --- the backlog ledger ----------------------------------------------------
#
# The only surface a human and the unattended runner share. It has to be both
# machine-readable and hand-writable, so state lives in a leading marker and
# everything else in an HTML comment at the end of the line:
#
#   ## P1
#   - [ ] (id:h-0007) refresh the unused-disk report
#         note: last one is in reports/2026-05.md
#   - [x] (id:h-0003) add tests <!-- done:2026-08-18T17:42+09:00 run:20260818-174200 -->
#   - [!] (id:h-0009) needs cloud credentials <!-- blocked:2026-08-18T18:10 reason:permission-denied -->
#
# Markers: [ ] todo, [~] in progress, [x] done, [!] blocked.
# Priority: the nearest preceding `## P<n>` heading; before any heading, 99.
# macOS awk cannot be trusted with [[:space:]], so every pattern uses [ \t].

# The example is inside a fence on purpose. An illustrative `- [ ]` line at the
# top level is a real todo: the first unattended run would pick it up and spend
# a task on it.
BACKLOG_TEMPLATE='# Backlog

Add tasks under a priority heading, like this:

```
## P1
- [ ] the most important thing
      note: indented lines are passed to the agent as context
```

Markers: [ ] todo   [~] in progress   [x] done   [!] blocked
Ids are assigned automatically; do not write them by hand.
'

backlog_ensure() {
  local f=$1
  [ -n "${f}" ] || return 1
  [ -f "${f}" ] && return 0
  mkdir -p "$(dirname "${f}")" || return 1
  printf '%s' "${BACKLOG_TEMPLATE}" >"${f}"
}

# One TSV row per task line: lineno, priority, marker, id, text.
# Everything else is derived from this, so the parse exists in exactly one place.
backlog_scan() {
  local f=$1
  [ -r "${f}" ] || return 1
  awk '
    # Fenced blocks are documentation, not work. Without this, an example task
    # written inside a fence is picked up and attempted like a real one.
    /^[ \t]*(```|~~~)/ { infence = !infence; next }
    infence { next }
    /^##[ \t]*[Pp][0-9]+/ {
      line = $0
      sub(/^##[ \t]*[Pp]/, "", line)
      sub(/[^0-9].*$/, "", line)
      if (line != "") prio = line + 0
      next
    }
    /^[ \t]*-[ \t]+\[.\][ \t]*/ {
      marker = $0
      sub(/^[ \t]*-[ \t]+\[/, "", marker)
      sub(/\].*$/, "", marker)

      text = $0
      sub(/^[ \t]*-[ \t]+\[.\][ \t]*/, "", text)

      id = ""
      if (text ~ /^\(id:[a-zA-Z0-9_-]+\)/) {
        id = text
        sub(/^\(id:/, "", id)
        sub(/\).*$/, "", id)
        sub(/^\(id:[a-zA-Z0-9_-]+\)[ \t]*/, "", text)
      }
      sub(/[ \t]*<!--.*-->[ \t]*$/, "", text)

      printf "%d\t%d\t%s\t%s\t%s\n", NR, (prio == 0 ? 99 : prio), marker, id, text
    }
    BEGIN { prio = 99 }
  ' "${f}"
}

backlog_count() {
  local f=$1 marker=$2
  backlog_scan "${f}" 2>/dev/null | awk -F'\t' -v m="${marker}" '$3 == m {n++} END {print n + 0}'
}

# Order of attack: priority ascending, then top to bottom within a priority.
backlog_next_row() {
  backlog_scan "$1" 2>/dev/null |
    awk -F'\t' '$3 == " "' |
    sort -t"$(printf '\t')" -k2,2n -k1,1n |
    head -1
}

backlog_next_id()   { backlog_next_row "$1" | cut -f4; }
backlog_next_text() { backlog_next_row "$1" | cut -f5; }

# A task's indented continuation lines, which carry context the runner must
# pass through to the prompt verbatim.
backlog_notes_for_line() {
  local f=$1 lineno=$2
  awk -v start="${lineno}" '
    NR <= start { next }
    /^[ \t]*-[ \t]+\[.\]/ { exit }
    /^[ \t]*##/ { exit }
    /^[ \t]+[^ \t]/ { print; next }
    { exit }
  ' "${f}"
}

backlog_line_of_id() {
  local f=$1 id=$2
  backlog_scan "${f}" 2>/dev/null | awk -F'\t' -v id="${id}" '$4 == id {print $1; exit}'
}

backlog_text_of_id() {
  local f=$1 id=$2
  backlog_scan "${f}" 2>/dev/null | awk -F'\t' -v id="${id}" '$4 == id {print $5; exit}'
}

backlog_marker_of_id() {
  local f=$1 id=$2
  backlog_scan "${f}" 2>/dev/null | awk -F'\t' -v id="${id}" '$4 == id {print $3; exit}'
}

# Highest existing id number, so the runner can allocate the next one. Leading
# zeros are stripped here, not by the caller: ids are printed %04d, and bash
# reads "0009" as an invalid octal literal in arithmetic.
backlog_max_id_num() {
  local f=$1 n
  n=$(backlog_scan "${f}" 2>/dev/null | cut -f4 |
      sed -n 's/^[a-zA-Z]*-\([0-9][0-9]*\)$/\1/p' |
      sed 's/^0*//' | sort -n | tail -1)
  case ${n} in
    ""|*[!0-9]*) printf 0 ;;
    *) printf '%s' "${n}" ;;
  esac
}

# Ids are allocated by the tool, never written by hand: hand-written ids
# collide, and the completion marker's `run:` field has to stay unambiguous.
backlog_assign_ids() {
  local f=$1 prefix=${2:-h} start tmp
  # Ledger-wide, not file-wide: an id whose task has been swept into the
  # archive is spent, and reissuing it would put two different tasks behind one
  # `run:` attribution.
  start=$(($(ledger_max_id_num "${f}") + 1))
  tmp=$(mktemp "${TMPDIR:-/tmp}/hzl-backlog.XXXXXX") || return 1
  # `next` is an awk keyword, so the counter cannot be called that.
  # Fenced blocks are skipped here for the same reason backlog_scan skips them,
  # and the omission was visible: the allocator stamped an id onto the example
  # in the file's own header, directly under the line telling the reader that
  # ids are never written by hand.
  awk -v seq="${start}" -v prefix="${prefix}" '
    /^[ \t]*(```|~~~)/ { infence = !infence; print; next }
    infence { print; next }
    /^[ \t]*-[ \t]+\[.\][ \t]*/ {
      rest = $0
      sub(/^[ \t]*-[ \t]+\[.\][ \t]*/, "", rest)
      if (rest !~ /^\(id:/) {
        head = $0
        sub(/\][ \t]*.*$/, "] ", head)
        printf "%s(id:%s-%04d) %s\n", head, prefix, seq, rest
        seq++
        next
      }
    }
    { print }
  ' "${f}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
  cat "${tmp}" >"${f}" && rm -f "${tmp}"
}

# Replace a line's marker, and replace its trailing metadata comment wholesale
# rather than appending a second one.
backlog_set_state() {
  local f=$1 id=$2 marker=$3 meta=${4:-} lineno tmp
  meta=$(oneline "${meta}")
  lineno=$(backlog_line_of_id "${f}" "${id}")
  [ -n "${lineno}" ] || return 3
  tmp=$(mktemp "${TMPDIR:-/tmp}/hzl-backlog.XXXXXX") || return 1
  awk -v target="${lineno}" -v marker="${marker}" -v meta="${meta}" '
    NR == target {
      line = $0
      sub(/\[.\]/, "[" marker "]", line)
      sub(/[ \t]*<!--.*-->[ \t]*$/, "", line)
      if (meta != "") line = line " <!-- " meta " -->"
      print line
      next
    }
    { print }
  ' "${f}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
  cat "${tmp}" >"${f}" && rm -f "${tmp}"
}

# Add an indented continuation line directly under a task.
backlog_add_note() {
  local f=$1 id=$2 note=$3 lineno tmp
  note=$(oneline "${note}")
  [ -n "${note}" ] || return 0
  lineno=$(backlog_line_of_id "${f}" "${id}")
  [ -n "${lineno}" ] || return 3
  tmp=$(mktemp "${TMPDIR:-/tmp}/hzl-backlog.XXXXXX") || return 1
  awk -v target="${lineno}" -v note="${note}" '
    { print }
    NR == target { printf "      note: %s\n", note }
  ' "${f}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
  cat "${tmp}" >"${f}" && rm -f "${tmp}"
}

# An interrupted run leaves [~] behind. The runner rolls them back on the way
# in, and its EXIT trap rolls them back on the way out.
backlog_reset_inprogress() {
  local f=$1 tmp n=0
  n=$(backlog_count "${f}" "~")
  [ "${n}" -gt 0 ] || { printf 0; return 0; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/hzl-backlog.XXXXXX") || return 1
  awk '
    /^[ \t]*-[ \t]+\[~\]/ { sub(/\[~\]/, "[ ]"); print; next }
    { print }
  ' "${f}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
  cat "${tmp}" >"${f}" && rm -f "${tmp}"
  printf '%s' "${n}"
}

# Completion lines carry `run:<id>`, which is how the review gate reverts only
# what this run closed and leaves other runs and human edits alone.
backlog_ids_done_by_run() {
  local f=$1 run_id=$2
  awk -v run="run:${run_id}" '
    /^[ \t]*-[ \t]+\[[xX]\]/ && index($0, run) > 0 {
      line = $0
      sub(/^[ \t]*-[ \t]+\[.\][ \t]*/, "", line)
      if (line ~ /^\(id:/) {
        sub(/^\(id:/, "", line)
        sub(/\).*$/, "", line)
        print line
      }
    }
  ' "${f}"
}

# --- the ledger's other files ----------------------------------------------
#
# The backlog is a queue, and a queue that keeps everything it ever served is a
# log wearing a queue's format. Every closed task stayed in `backlog.md` next to
# the three or four lines that are actually waiting, so the file a human opens
# to add a todo grew without bound and the `[!]` lines that need a decision sank
# into a month of `[x]`.
#
# So the ledger is three files that share one format, split by whose move it is:
#
#   backlog.md             the machine's queue:  [ ]  [~]
#   backlog.blocked.md     waiting on a person:  [!]
#   backlog.completed.md   what is closed:       [x]
#
# Sweeping `[x]` out was the first half and it left the second half visible: a
# blocked task is not work the runner can pick up either, so it sat in the queue
# being skipped by every run that read past it, and the queue still was not the
# list of what is queued. `backlog.md` now answers one question — what happens
# next — and the file whose whole content is addressed to a human is a file a
# human can open on its own.
#
# Both are derived from the backlog's own name rather than configured. A second
# setting is a second thing to get wrong, and the files have to be found together
# by every reader — including one that only has the backlog path out of
# `state.json`.
#
# The blocked file is *live*, and that is its one difference from the archive:
# `[x]` is terminal, `[!]` is not. So its sweep runs both ways — `[!]` leaves the
# backlog, and a line in the blocked file that is no longer `[!]` (`hzl unblock`,
# or a human with an editor) goes back into it. One-way would strand an unblocked
# task in a file no worksheet is ever built from, which is losing work quietly.
# For the same reason every *mutation* addresses the ledger's live files and
# never the archive: `ledger_file_of_id` looks in those two only.
#
# Two invariants survive the split, and they are the whole reason the reads
# below exist rather than each caller opening the file it happens to know about:
#
#   * an id is allocated once, ever. `backlog_max_id_num` reading only the
#     backlog would hand out h-0007 again the moment the first h-0007 was
#     archived, and `run:` attribution would stop meaning anything.
#   * "is this task already closed" is a question about the ledger, not about
#     one of its files. Finalize recovery asks it, and an answer of "no marker
#     here" from a swept backlog would re-apply a completion that landed.
#
# What does *not* change is the crash boundary. The sweep is not part of the
# ledger transition: it runs at the top of a run, after any pending commit is
# recovered and before the worksheet is built, so the intent and receipt of
# §13.4 still digest a single file at the moment they are written.

ARCHIVE_TEMPLATE='# Completed

Tasks the ledger has closed, swept out of the backlog so that what is waiting
stays short. This is the record, not the queue: nothing here is picked up again.

Ids are still live in this file - `hzl` reads it when it allocates the next one -
so do not renumber or delete them by hand.
'

BLOCKED_TEMPLATE='# Blocked

Tasks an unattended run stopped on: each needed a judgement call, a privilege, or
something irreversible it would not do on its own. The comment at the end of the
line says what to do in one line; the steps are in `blocked/<id>.md` beside this
file, and `hzl take <id>` reads them back with the task.

This file is live, not a record. Change a `[!]` back to `[ ]` here (or run
`hzl unblock <id>`) and the task returns to the backlog at the next sweep.
'

# The archive that belongs to a backlog, and the blocked file that belongs to it.
# Beside it and named after it, so the three sort together in a directory listing
# and none of them can be found without the others.
ledger_archive() {
  local f=$1
  [ -n "${f}" ] || return 1
  case ${f} in
    *.md) printf '%s.completed.md' "${f%.md}" ;;
    *) printf '%s.completed' "${f}" ;;
  esac
}

# Not `ledger_blocked`: that one is the report read, and this is a path.
ledger_blocked_file() {
  local f=$1
  [ -n "${f}" ] || return 1
  case ${f} in
    *.md) printf '%s.blocked.md' "${f%.md}" ;;
    *) printf '%s.blocked' "${f}" ;;
  esac
}

# --- the steps a blocked task asks for -------------------------------------
#
# A `[!]` line is addressed to a person, and `reason:` is one line. One line can
# say what to decide; it cannot say which page to open, what to type, and how to
# tell it worked - and the person reading it in the morning did not see the run
# and may not be an engineer. So the instructions get a file of their own:
#
#   ~/.heinzel/blocked/h-0009.md    beside the ledger, named for the task
#
# and the ledger line stays one line. Nothing points at the file, because the id
# is the pointer: a name derived from the id cannot drift out of step with the
# line the way a recorded path can, and `hzl report`, `hzl take` and `hzl steps`
# all ask the same question - is there a file for this id - and get one answer.
#
# The agent writes its copy at `<workdir>/.heinzel/blocked/<id>.md`, the only
# place it can write, and the merge carries it out here. The worksheet is
# deleted at the end of a run, and steps that die with the worksheet were never
# for the person.
ledger_steps_ref() { # id -> the name the ledger's directory knows it by
  [ -n "${1:-}" ] || return 1
  printf 'blocked/%s.md' "$1"
}

ledger_steps_file() { # backlog id
  local ref
  [ -n "${1:-}" ] || return 1
  ref=$(ledger_steps_ref "${2:-}") || return 1
  printf '%s/%s' "$(dirname "$1")" "${ref}"
}

# Where the agent left them, if it left any: the same name under the worksheet's
# own directory, so the run and the ledger agree without being told.
worksheet_steps_file() { # worksheet id
  local ref
  [ -n "${1:-}" ] || return 1
  ref=$(ledger_steps_ref "${2:-}") || return 1
  printf '%s/%s' "$(dirname "$1")" "${ref}"
}

# Copy one run's steps out of the working directory and beside the ledger.
# Whole and renamed into place, because a reader that opens this file is reading
# it to act on it, and half a set of instructions is worse than none.
#
# Failure is not fatal to a block: a blocked task with no steps file is still
# blocked, and the reason on the line is what is left of the ask.
ledger_steps_install() { # backlog id source
  local dst dir tmp
  [ -r "${3:-}" ] || return 1
  dst=$(ledger_steps_file "$1" "$2") || return 1
  dir=$(dirname "${dst}")
  mkdir -p "${dir}" 2>/dev/null || return 1
  tmp=$(mktemp "${dir}/.steps.XXXXXX") || return 1
  if cat "$3" >"${tmp}" 2>/dev/null && mv -f "${tmp}" "${dst}"; then
    printf '%s' "${dst}"
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# What a person gets when they ask for a steps file that nobody wrote: the same
# shape the prompt asks the agent for, with the parts only they can fill in left
# blank. An empty file would be a worse answer than a form.
STEPS_TEMPLATE='# %s: %s

## What I need from you

<one sentence: the decision, the permission, or the account>

## Why it stopped here

<two sentences at most, in plain words>

## What to do

1. <the first step - a command to copy, or a page to open>
2. <the next one>

## How to tell it worked

<what you should see when the step above has worked>

## When you are done

Run `hzl unblock %s` to put the task back in the queue, or
`hzl done %s "<what changed>"` if you finished it yourself.
'

# Created on the first sweep that has something to put there, never before: a
# machine that has closed nothing and blocked nothing has a one-file ledger, and
# every read below has to work there unchanged.
ledger_file_ensure() { # path template
  local p=$1
  [ -n "${p}" ] || return 1
  [ -f "${p}" ] && return 0
  mkdir -p "$(dirname "${p}")" || return 1
  printf '%s' "$2" >"${p}"
}

# The files that hold live work, backlog first. These are the ones a mutation may
# land in; a task moves between them and out of them into the archive.
ledger_live_files() {
  local f=$1 b
  [ -n "${f}" ] || return 1
  printf '%s\n' "${f}"
  b=$(ledger_blocked_file "${f}") 2>/dev/null
  [ -n "${b}" ] && [ -r "${b}" ] && printf '%s\n' "${b}"
  return 0
}

# The files that together are the ledger: the live ones, then the archive.
ledger_files() {
  local f=$1 a
  ledger_live_files "${f}" || return 1
  a=$(ledger_archive "${f}") 2>/dev/null
  [ -n "${a}" ] && [ -r "${a}" ] && printf '%s\n' "${a}"
  return 0
}

# The marker on an id anywhere in the ledger. Empty when no file has it.
ledger_marker_of_id() {
  local id=$2 f m
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    m=$(backlog_marker_of_id "${f}" "${id}")
    [ -n "${m}" ] && { printf '%s' "${m}"; return 0; }
  done <<EOF
$(ledger_files "$1")
EOF
  return 1
}

# The highest id number the ledger has ever issued, across both files. This is
# the one that allocation must use; `backlog_max_id_num` is the per-file read it
# is built from.
ledger_max_id_num() {
  local f n max=0
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    n=$(backlog_max_id_num "${f}")
    [ "${n}" -gt "${max}" ] && max=${n}
  done <<EOF
$(ledger_files "$1")
EOF
  printf '%s' "${max}"
}

# Is a task with exactly this text anywhere in the ledger? Asked on the
# recovery path, where a run may have inserted it before it stopped.
ledger_has_text() {
  local f
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    backlog_scan "${f}" 2>/dev/null | cut -f5- | grep -qxF -- "$2" && return 0
  done <<EOF
$(ledger_files "$1")
EOF
  return 1
}

# The ids a run closed, across both files, so that the review gate can still
# find its own completions after a sweep has moved them.
ledger_ids_done_by_run() {
  local f
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    backlog_ids_done_by_run "${f}" "$2"
  done <<EOF
$(ledger_files "$1")
EOF
}

# The sweep, in one function because both sweeps are the same move: every task
# line whose marker is wanted, with the continuation lines belonging to it, goes
# from one ledger file to another. `want` is the set of marker characters to
# move; with a leading `^` it is the set to keep and everything else moves.
# Prints how many tasks moved.
#
# The destination is appended to *before* the source is rewritten, and that order
# is the whole safety argument. A crash between the two leaves a task in both
# files, which the next sweep repairs (an id already at the destination is
# dropped from the source rather than appended twice); the other order would lose
# the task outright. Duplication is visible and self-healing, loss is neither.
#
# Appended chronologically, not merged by priority: this is a record of when
# things moved. Each run of tasks carries the `## P<n>` heading it came from, so
# `backlog_scan` reads the destination with the same priorities the source had,
# and a revert - or the sweep back out of the blocked file - can put a line where
# it belongs.
#
# Caller holds the backlog lock.
ledger_move_marked() { # src dst want [template]
  local f=$1 a=$2 want=$3 invert=0 seen delta keep n
  [ -r "${f}" ] && [ -w "${f}" ] || { printf 0; return 1; }
  [ -n "${a}" ] || { printf 0; return 1; }
  case ${want} in ^*) invert=1; want=${want#^} ;; esac

  # Nothing to move is the common case, and it must not create the destination:
  # a ledger that has never blocked anything has no blocked file to back up.
  [ "$(backlog_scan "${f}" 2>/dev/null |
       awk -F'\t' -v want="${want}" -v inv="${invert}" '
         $4 != "" { hit = (index(want, $3) > 0); if (inv) hit = !hit; if (hit) n++ }
         END { print n + 0 }')" -gt 0 ] || { printf 0; return 0; }
  ledger_file_ensure "${a}" "${4:-}" || { printf 0; return 1; }

  seen=$(mktemp "${TMPDIR:-/tmp}/hzl-arc-seen.XXXXXX") || { printf 0; return 1; }
  delta=$(mktemp "${TMPDIR:-/tmp}/hzl-arc-delta.XXXXXX") || { rm -f "${seen}"; printf 0; return 1; }
  keep=$(mktemp "${TMPDIR:-/tmp}/hzl-arc-keep.XXXXXX") || { rm -f "${seen}" "${delta}"; printf 0; return 1; }

  backlog_scan "${a}" 2>/dev/null | cut -f4 | sed '/^$/d' >"${seen}"

  # The parse is backlog_scan's, repeated here because this pass has to write
  # every line it reads to one of two places rather than summarise the ones it
  # recognises. `mode` carries the last task line's destination forward, so an
  # indented note follows the task it belongs to.
  n=$(awk -v idfile="${seen}" -v out_keep="${keep}" -v out_arc="${delta}" \
          -v want="${want}" -v inv="${invert}" '
    BEGIN {
      while ((getline line < idfile) > 0) if (line != "") archived[line] = 1
      prio = 99; lastprio = ""; mode = "keep"; n = 0
    }
    /^[ \t]*(```|~~~)/ { infence = !infence; mode = "keep"; print > out_keep; next }
    infence { print > out_keep; next }
    /^##[ \t]*[Pp][0-9]+/ {
      h = $0
      sub(/^##[ \t]*[Pp]/, "", h)
      sub(/[^0-9].*$/, "", h)
      if (h != "") prio = h + 0
      mode = "keep"; print > out_keep; next
    }
    /^[ \t]*-[ \t]+\[.\][ \t]*/ {
      marker = $0
      sub(/^[ \t]*-[ \t]+\[/, "", marker)
      sub(/\].*$/, "", marker)
      rest = $0
      sub(/^[ \t]*-[ \t]+\[.\][ \t]*/, "", rest)
      id = ""
      if (rest ~ /^\(id:[a-zA-Z0-9_-]+\)/) {
        id = rest
        sub(/^\(id:/, "", id)
        sub(/\).*$/, "", id)
      }
      # An id-less line is left alone: there is nothing to deduplicate it by, so
      # moving it could not be made idempotent.
      hit = (index(want, marker) > 0)
      if (inv) hit = !hit
      if (hit && id != "") {
        n++
        # Already there: the residue of a crash between the append and the
        # rewrite. Dropping it here is the repair — and the notes under it go
        # with it. Staying in "archive" mode would send them to the destination
        # a second time, where they would land under whichever task was written
        # there last and be read as the notes of that one.
        if (id in archived) { mode = "drop"; next }
        mode = "archive"
        if (prio != lastprio) { printf "\n## P%d\n", prio > out_arc; lastprio = prio }
        print > out_arc
        archived[id] = 1
        next
      }
      mode = "keep"; print > out_keep; next
    }
    /^[ \t]+[^ \t]/ {
      if (mode == "archive") print > out_arc
      else if (mode != "drop") print > out_keep
      next
    }
    { mode = "keep"; print > out_keep; next }
    END { print n + 0 }
  ' "${f}") || { rm -f "${seen}" "${delta}" "${keep}"; printf 0; return 1; }

  case ${n} in ""|*[!0-9]*) n=0 ;; esac
  if [ "${n}" -gt 0 ]; then
    cat "${delta}" >>"${a}" || { rm -f "${seen}" "${delta}" "${keep}"; printf 0; return 1; }
    cat "${keep}" >"${f}" || { rm -f "${seen}" "${delta}" "${keep}"; printf 0; return 1; }
  fi
  rm -f "${seen}" "${delta}" "${keep}"
  printf '%s' "${n}"
}

# Everything closed anywhere in the live ledger moves to the archive. Both live
# files, because `hzl done` closes a blocked task where it lies, and a `[x]` left
# in the blocked file is a completion in the file that is supposed to be nothing
# but open questions. Prints how many tasks moved.
#
# Caller holds the backlog lock.
backlog_archive_done() { # backlog
  local f=$1 a m n total=0 rc=0
  a=$(ledger_archive "${f}") || { printf 0; return 1; }
  while IFS= read -r m; do
    [ -n "${m}" ] || continue
    n=$(ledger_move_marked "${m}" "${a}" 'xX' "${ARCHIVE_TEMPLATE}") || rc=1
    case ${n} in ""|*[!0-9]*) n=0 ;; esac
    total=$((total + n))
  done <<EOF
$(ledger_live_files "${f}")
EOF
  printf '%s' "${total}"
  return ${rc}
}

# The blocked sweep, which runs both ways because blocked work is live work:
# `[!]` leaves the backlog for the blocked file, and anything in the blocked file
# that is no longer `[!]` goes back into the backlog. Prints `out back`.
#
# Out first: a task that was blocked and is now `[ ]` again must not be moved out
# and back in the same sweep. Ordering the other way would still be correct - the
# marker decides, not the order - but it would churn the file for nothing.
#
# What comes back is appended under a `## P<n>` heading of its own rather than
# spliced into the section it came from. Appending is the operation the crash
# argument above is built on, and a repeated heading is legal in this format:
# priority is the nearest heading above a line, so the task lands back at exactly
# the priority it left with.
#
# Caller holds the backlog lock.
backlog_sweep_blocked() { # backlog
  local f=$1 b out=0 back=0 rc=0
  b=$(ledger_blocked_file "${f}") || { printf '0 0'; return 1; }
  out=$(ledger_move_marked "${f}" "${b}" '!' "${BLOCKED_TEMPLATE}") || rc=1
  case ${out} in ""|*[!0-9]*) out=0 ;; esac
  if [ -r "${b}" ]; then
    back=$(ledger_move_marked "${b}" "${f}" '^!' "${BACKLOG_TEMPLATE}") || rc=1
    case ${back} in ""|*[!0-9]*) back=0 ;; esac
  fi
  printf '%s %s' "${out}" "${back}"
  return ${rc}
}

# --- the live ledger, as one file ------------------------------------------
#
# A task the runner is not working on is in the backlog or in the blocked file,
# and which of the two is an implementation detail of the sweep. Every read and
# every write a human drives goes through these, so that `hzl block h-0007` and
# `hzl done h-0007` do not have to know where the line currently sits.
#
# Deliberately not extended to the archive. A mutation that reached it would
# rewrite the record - and `hzl done` on an id that was closed last month should
# say "no such id", not silently close it a second time.

# backlog_scan across the live files. Line numbers are per file, so a caller that
# needs to *change* a line resolves its file with `ledger_file_of_id` first.
ledger_scan_live() { # backlog
  local f
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    backlog_scan "${f}" 2>/dev/null
  done <<EOF
$(ledger_live_files "$1")
EOF
}

# How many tasks carry this marker anywhere in the live ledger. `[!]` is the
# reason this exists: after the split, counting the backlog alone reports that
# nothing is blocked, which is the one answer that must never be wrong.
ledger_count() { # backlog marker
  ledger_scan_live "$1" | awk -F'\t' -v m="$2" '$3 == m {n++} END {print n + 0}'
}

# Which live file holds an id, empty and status 3 when none does.
ledger_file_of_id() { # backlog id
  local id=$2 f
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    [ -n "$(backlog_line_of_id "${f}" "${id}")" ] && { printf '%s' "${f}"; return 0; }
  done <<EOF
$(ledger_live_files "$1")
EOF
  return 3
}

# backlog_set_state without having to know which live file the task is in.
# Status 3 - no such id - is passed through unchanged: it is what tells a caller
# it typed a wrong id.
ledger_set_state() { # backlog id marker [meta]
  local f
  f=$(ledger_file_of_id "$1" "$2") || return 3
  backlog_set_state "${f}" "$2" "$3" "${4:-}"
}

# Closing a task and recording why, as one mutation. Both halves go to the file
# the task is actually in, resolved once: a task closed while it sits in the
# blocked file must not have its note land in the backlog, and the sweep takes
# it to the archive from wherever it was closed.
#
# Three statuses, because the two halves fail differently and the caller has
# something different to say about each:
#
#   3  no such id - nothing was written
#   4  the marker was set and the note was not
#
# Status 4 is not a rollback. The work really was finished, and putting the
# marker back to hide a missing note would discard the true half of the record
# to avoid reporting the missing half; the caller is told instead, and can say
# precisely what state the ledger is in. What it replaced was worse than either:
# the note call ended a `&&` list whose result was thrown away, so a note that
# never reached the ledger still reported success. The note is the whole reason
# the argument exists - a marker says a task ended, not what came of it.
ledger_close_with_note() { # backlog id meta note
  local f
  f=$(ledger_file_of_id "$1" "$2") || return 3
  backlog_set_state "${f}" "$2" x "$3" || return $?
  [ -n "$4" ] || return 0
  backlog_add_note "${f}" "$2" "$4" || return 4
  return 0
}

# --- reading the ledger for a human ----------------------------------------
#
# The two questions the morning after answers: what is waiting on a decision,
# and what got done. They are here rather than in `bin/hzl` because they are
# reads of the ledger format, and the ledger format has one parser per question
# and a test around it.

# TSV: date, id, text. Across both files, so a completion that was swept into
# the archive still appears in the report for the morning it happened.
#
# Dates are compared as strings, which ISO8601 is ordered for by construction.
# Doing it inside awk keeps this to one pass per file however long the archive
# gets - and the archive is the file with no bound on it.
ledger_completed_since() { # backlog since-date
  local f
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    awk -v since="$2" '
      /^[ \t]*(```|~~~)/ { infence = !infence; next }
      infence { next }
      /^[ \t]*-[ \t]+\[[xX]\][ \t]*/ {
        meta = $0
        if (meta !~ /<!--/) next
        sub(/^.*<!--[ \t]*/, "", meta)
        sub(/[ \t]*-->.*$/, "", meta)
        if (!match(meta, /done:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) next
        d = substr(meta, RSTART + 5, 10)
        if (d < since) next
        rest = $0
        sub(/^[ \t]*-[ \t]+\[.\][ \t]*/, "", rest)
        id = ""
        if (rest ~ /^\(id:[a-zA-Z0-9_-]+\)/) {
          id = rest
          sub(/^\(id:/, "", id)
          sub(/\).*$/, "", id)
          sub(/^\(id:[a-zA-Z0-9_-]+\)[ \t]*/, "", rest)
        }
        sub(/[ \t]*<!--.*-->[ \t]*$/, "", rest)
        printf "%s\t%s\t%s\n", d, id, rest
      }
    ' "${f}"
  done <<EOF
$(ledger_files "$1")
EOF
}

# TSV: date, id, reason, text, steps. The live files only: a blocked task is live work,
# and the archive holds nothing but completions. Both of them, because a `[!]`
# written by this run is still in the backlog until the next sweep moves it - the
# report has to read the same set the sweep moves between.
#
# The trailing `run:<id>` comes off the reason. Every other reader of this
# metadata takes the rest of the line and keeps the run id in it, which is right
# for a record and wrong for a sentence somebody reads over breakfast.
ledger_blocked() { # backlog
  local lf
  while IFS= read -r lf; do
    [ -n "${lf}" ] || continue
    awk '
    /^[ \t]*(```|~~~)/ { infence = !infence; next }
    infence { next }
    /^[ \t]*-[ \t]+\[!\][ \t]*/ {
      meta = $0
      d = ""; reason = ""
      if (meta ~ /<!--/) {
        sub(/^.*<!--[ \t]*/, "", meta)
        sub(/[ \t]*-->.*$/, "", meta)
        if (match(meta, /blocked:[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/))
          d = substr(meta, RSTART + 8, 10)
        if (match(meta, /reason:/)) {
          reason = substr(meta, RSTART + 7)
          sub(/[ \t]*recovered:[^ \t]*[ \t]*$/, "", reason)
          sub(/[ \t]*run:[^ \t]*[ \t]*$/, "", reason)
        }
      }
      if (reason == "") reason = "not stated"
      if (d == "") d = "-"
      rest = $0
      sub(/^[ \t]*-[ \t]+\[.\][ \t]*/, "", rest)
      id = ""
      if (rest ~ /^\(id:[a-zA-Z0-9_-]+\)/) {
        id = rest
        sub(/^\(id:/, "", id)
        sub(/\).*$/, "", id)
        sub(/^\(id:[a-zA-Z0-9_-]+\)[ \t]*/, "", rest)
      }
      sub(/[ \t]*<!--.*-->[ \t]*$/, "", rest)
      printf "%s\t%s\t%s\t%s\n", d, id, reason, rest
    }
    ' "${lf}"
  done <<EOF
$(ledger_live_files "$1")
EOF
}

# The same read, with a fifth field: the steps file when there is one, empty
# when there is not. Every human-facing caller wants this one - "is there more
# to read about this task" is part of what a blocked task is, and leaving the
# question to each caller is how one caller comes to forget to ask.
ledger_blocked_rows() { # backlog
  local row id steps
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    id=$(printf '%s' "${row}" | cut -f2)
    steps=""
    if [ -n "${id}" ]; then
      steps=$(ledger_steps_file "$1" "${id}" 2>/dev/null)
      [ -n "${steps}" ] && [ -r "${steps}" ] || steps=""
    fi
    printf '%s\t%s\n' "${row}" "${steps}"
  done <<EOF
$(ledger_blocked "$1")
EOF
}

# --- the worksheet ---------------------------------------------------------
#
# What the agent actually sees. The ledger is the human's file and the runner's
# record; handing the whole of it to an agent means every line ever closed
# competes for attention with the one task that matters, and every line ever
# closed sits inside the agent's write radius, guarded by nothing more than a
# sentence in a prompt. The worksheet is one run's slice of the ledger: the
# `[ ]` lines this run may touch, their notes, and nothing else.
#
#   ## P1
#   - [ ] (id:h-0007) refresh the unused-disk report
#         note: last one is in reports/2026-05.md
#
# The agent moves markers here. The runner merges the result back by id and is
# the ledger's only writer, so the scope of a run is enforced rather than
# requested: an id the runner did not put on the worksheet is not applied,
# whatever the agent wrote beside it.
#
# Rows from backlog_scan are taken apart with `cut`, never with
# `IFS=<tab> read`. Tab is one of the shell's IFS whitespace characters, so a
# run of tabs collapses into a single delimiter: an empty field - which is
# exactly what an id-less line the agent added looks like - shifts every field
# after it left, and the new task arrives wearing the next field's value.

# The trailing `<!-- ... -->` on a line, without its delimiters. The worksheet
# is where the agent states a reason for blocking; timestamps and run ids are
# the runner's to write, so this is the only metadata read back out of it.
line_meta() {
  local f=$1 lineno=$2
  awk -v target="${lineno}" '
    NR == target {
      if (match($0, /<!--.*-->/)) {
        s = substr($0, RSTART + 4, RLENGTH - 7)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        print s
      }
      exit
    }
  ' "${f}"
}

# Write a worksheet holding exactly the ids listed in `ids` - one per line -
# and print the ids it wrote, in the order it wrote them. Priority headings are
# carried across, because a task's priority is context the agent needs when it
# splits one, and because a new line written under a heading is merged back into
# that priority.
#
# The ledger's own marker is not consulted, and deliberately: a run rebuilds its
# worksheet *after* it has claimed its tasks, when those lines read `[~]`, and
# what the agent is handed is always a todo. Membership of the id list is the
# only thing that decides what appears.
#
# An id that is not in the ledger is skipped rather than invented, and a render
# that wrote nothing fails: an empty worksheet handed to an agent is a prompt
# with no work in it.
worksheet_render() {
  local f=$1 ids=$2 out=$3
  local rows row want prev_prio="" lineno prio id text n=0
  [ -r "${f}" ] && [ -r "${ids}" ] || return 1
  want=" $(tr '\n' ' ' <"${ids}") "
  rows=$(backlog_scan "${f}" 2>/dev/null |
    awk -F'\t' '$4 != ""' |
    sort -t"$(printf '\t')" -k2,2n -k1,1n)
  [ -n "${rows}" ] || return 1
  {
    printf '# Worksheet\n\n'
    printf 'The tasks this run may work on, in the order to work them.\n'
    printf 'Markers: [ ] todo   [x] done   [!] blocked.\n'
  } >"${out}" || return 1
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    lineno=$(printf '%s' "${row}" | cut -f1)
    prio=$(printf '%s' "${row}" | cut -f2)
    id=$(printf '%s' "${row}" | cut -f4)
    text=$(printf '%s' "${row}" | cut -f5-)
    [ -n "${id}" ] || continue
    case ${want} in
      *" ${id} "*) ;;
      *) continue ;;
    esac
    if [ "${prio}" != "${prev_prio}" ]; then
      printf '\n## P%s\n' "${prio}" >>"${out}"
      prev_prio=${prio}
    fi
    printf -- '- [ ] (id:%s) %s\n' "${id}" "${text}" >>"${out}"
    backlog_notes_for_line "${f}" "${lineno}" >>"${out}"
    printf '%s\n' "${id}"
    n=$((n + 1))
  done <<EOF
${rows}
EOF
  [ "${n}" -gt 0 ]
}

# Whether a task named on a worksheet may still be claimed. Prints nothing and
# returns 0 when it may; prints why not and returns 1 when it may not.
#
# The question exists because a whole lock sits between the two halves of
# claiming. `worksheet_write` reads the ledger without the backlog lock — it is
# choosing what to propose, not writing anything — and the claim that follows
# takes the lock and writes `[~]`. Every id on the worksheet is therefore a
# statement about the ledger as it was some moments ago, and a human at the
# keyboard runs `hzl done` and `hzl block` under that same lock, so their edit
# lands wholly in that window or wholly outside it. Landing inside it, against
# an unconditional `backlog_set_state ... "~"`, turned a person's `[x]` back
# into `[~]` and handed the finished task to the agent: not work lost so much
# as work reopened, which is worse, because the ledger then disagrees with the
# person who wrote it and nothing says so.
#
# A marker this does not recognise is refused rather than allowed. The set of
# markers is small and closed, and a new one would arrive here as a task
# silently claimed on a state nobody considered.
worksheet_claim_refusal() { # backlog id
  local marker
  marker=$(backlog_marker_of_id "$1" "$2")
  case ${marker} in
    ' ') return 0 ;;
    x) printf 'closed since the worksheet was built' ;;
    '!') printf 'blocked since the worksheet was built' ;;
    '~') printf 'already in progress' ;;
    '') printf 'no longer in %s' "$1" ;;
    *) printf 'marked [%s] since the worksheet was built' "${marker}" ;;
  esac
  return 1
}

# Write the run's slice of the ledger to `out`, and print the ids it contains,
# one per line: that list is what the merge will accept, and nothing else.
# The slice is the first `max` todos in the order of attack; the writing of it
# is `worksheet_render`, which the runner calls again if the claims it takes
# turn out to cover fewer tasks than this.
worksheet_write() {
  local f=$1 max=$2 out=$3 ids tmp rc
  [ -r "${f}" ] || return 1
  case ${max} in ""|*[!0-9]*) return 1 ;; esac
  [ "${max}" -ge 1 ] || return 1
  ids=$(backlog_scan "${f}" 2>/dev/null |
    awk -F'\t' '$3 == " " && $4 != ""' |
    sort -t"$(printf '\t')" -k2,2n -k1,1n |
    head -n "${max}" |
    cut -f4)
  [ -n "${ids}" ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/hzl-worksheet.XXXXXX") || return 1
  printf '%s\n' "${ids}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
  worksheet_render "${f}" "${tmp}" "${out}"
  rc=$?
  rm -f "${tmp}"
  return ${rc}
}

# Insert a new todo at the end of a priority section, after that section's last
# task *and its continuation lines* - inserting between a task and its notes
# would silently reassign the notes to the new task. A section that no longer
# exists gets one at the end of the file, rather than the task dropping into P99.
backlog_insert_at_priority() {
  local f=$1 prio=$2 text=$3 last after tmp
  text=$(oneline "${text}")
  [ -n "${text}" ] || return 1
  case ${prio} in ""|*[!0-9]*) prio=99 ;; esac
  last=$(backlog_scan "${f}" 2>/dev/null |
    awk -F'\t' -v p="${prio}" '$2 == p {n = $1} END {if (n) print n}')
  if [ -z "${last}" ]; then
    printf '\n## P%s\n- [ ] %s\n' "${prio}" "${text}" >>"${f}"
    return 0
  fi
  after=$(awk -v start="${last}" '
    NR <= start { seen = NR; next }
    /^[ \t]*-[ \t]+\[.\]/ { exit }
    /^[ \t]*##/ { exit }
    /^[ \t]+[^ \t]/ { seen = NR; next }
    { exit }
    END { print seen }
  ' "${f}")
  [ -n "${after}" ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/hzl-backlog.XXXXXX") || return 1
  # Through ENVIRON, not awk -v: awk -v interprets escape sequences, and this
  # text was written by an agent that had no reason to avoid a backslash.
  HZL_INS_TEXT=${text} awk -v target="${after}" '
    BEGIN { text = ENVIRON["HZL_INS_TEXT"] }
    { print }
    NR == target { printf "- [ ] %s\n", text }
  ' "${f}" >"${tmp}" || { rm -f "${tmp}"; return 1; }
  cat "${tmp}" >"${f}" && rm -f "${tmp}"
}

# Merge a finished worksheet into the ledger. Prints `done blocked new ignored`.
#
# Timestamps and `run:` fields are written here, not by the agent: an agent has
# no clock, and `run:` is what lets the review gate revert this run's work and
# nobody else's. Anything unrecognised is counted and dropped rather than
# guessed at.
worksheet_merge() {
  local ws=$1 f=$2 run_id=$3 allowed=$4
  local rows row allow_list lineno prio marker id text reason
  local n_done=0 n_blocked=0 n_new=0 n_ignored=0
  [ -r "${ws}" ] && [ -r "${allowed}" ] || { printf '0 0 0 0\n'; return 1; }
  allow_list=" $(tr '\n' ' ' <"${allowed}") "
  rows=$(backlog_scan "${ws}" 2>/dev/null)
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    lineno=$(printf '%s' "${row}" | cut -f1)
    prio=$(printf '%s' "${row}" | cut -f2)
    marker=$(printf '%s' "${row}" | cut -f3)
    id=$(printf '%s' "${row}" | cut -f4)
    text=$(printf '%s' "${row}" | cut -f5-)
    if [ -z "${id}" ]; then
      # A task split off from another. Only a todo can arrive without an id: a
      # line marked done that nobody ever queued is not a completion, and the
      # runner has nothing to check it against.
      if [ "${marker}" = " " ]; then
        backlog_insert_at_priority "${f}" "${prio}" "${text}" &&
          n_new=$((n_new + 1))
      else
        n_ignored=$((n_ignored + 1))
      fi
      continue
    fi
    case ${allow_list} in
      *" ${id} "*) ;;
      *) n_ignored=$((n_ignored + 1)); continue ;;
    esac
    case "${marker}" in
      x|X)
        backlog_set_state "${f}" "${id}" x "done:$(iso_at) run:${run_id}" &&
          n_done=$((n_done + 1))
        ;;
      "!")
        reason=$(line_meta "${ws}" "${lineno}" | sed -n 's/.*reason:[ 	]*//p')
        [ -n "${reason}" ] || reason="not stated"
        # The steps go out of the working directory before the marker moves. A
        # `[!]` a person can see and instructions they cannot open yet is the
        # one order that reads as "there is nothing more to say".
        ledger_steps_install "${f}" "${id}" \
          "$(worksheet_steps_file "${ws}" "${id}")" >/dev/null 2>&1
        backlog_set_state "${f}" "${id}" "!" \
          "blocked:$(iso_at) reason:${reason} run:${run_id}" &&
          n_blocked=$((n_blocked + 1))
        ;;
      *)
        # Never picked up, or left in progress by a run that ran out of clock.
        # Either way it goes back to the queue rather than staying half-claimed.
        backlog_set_state "${f}" "${id}" " " ""
        ;;
    esac
  done <<EOF
${rows}
EOF
  printf '%s %s %s %s\n' "${n_done}" "${n_blocked}" "${n_new}" "${n_ignored}"
}
