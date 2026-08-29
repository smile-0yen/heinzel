#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/watchdog.sh — hzl_timeout, a replacement for coreutils timeout(1).
#
# Stock macOS ships neither `timeout` nor `gtimeout` (measured on 26.6.2), and
# the wall-clock budget is not optional, so we carry our own (DESIGN 6.1).
#
# Contract, compatible with coreutils timeout:
#
#   hzl_timeout <kill_after> <seconds> <command> [args...]
#
#   exit 124  the command was killed after exceeding <seconds>
#   exit 137  the command ignored TERM and was killed after <kill_after> more
#   otherwise the command's own exit status
#
# Two traps make this one tested helper rather than three inline copies:
#
#   * Never wrap `cd` in a subshell around the child. `( cd x && cmd ) &` makes
#     $! the subshell's pid; killing that orphans the real grandchild, which
#     keeps running and keeps billing. Callers cd, background, cd back, wait.
#   * Never run the child in the foreground. bash defers a SIGTERM trap until
#     the foreground child exits, so the caller's own cleanup trap would not
#     fire at the exact moment it is needed.
#
# The child's pid is published as HEINZEL_ENGINE_PID so a caller's trap can
# reach it.

HEINZEL_ENGINE_PID=""

# Signal a whole process group, falling back to the single pid when the child
# never became a group leader.
hzl_signal_tree() {
  local sig=$1 pid=$2
  kill "-${sig}" -- "-${pid}" 2>/dev/null || kill "-${sig}" "${pid}" 2>/dev/null
}

hzl_timeout() {
  local kill_after=$1 secs=$2
  shift 2
  [ $# -ge 1 ] || return 125

  case ${kill_after}${secs} in
    *[!0-9]*) return 125 ;;
  esac

  local child watchdog rc had_monitor
  local marker
  marker=$(mktemp "${TMPDIR:-/tmp}/hzl-timeout.XXXXXX") || return 125
  rm -f "${marker}"

  # Job control makes each background job a process-group leader, which lets us
  # signal the whole tree. Without it, killing the child orphans its children:
  # an engine's own subprocesses would survive the timeout and keep billing.
  case $- in
    *m*) had_monitor=1 ;;
    *) had_monitor=0; set -m ;;
  esac

  "$@" &
  child=$!
  HEINZEL_ENGINE_PID=${child}

  [ "${had_monitor}" -eq 0 ] && set +m

  # The watchdog is a plain background subshell, not a trap: it must survive
  # the child ignoring signals, and it must be killable from here.
  (
    i=0
    while [ ${i} -lt "${secs}" ]; do
      kill -0 "${child}" 2>/dev/null || exit 0
      sleep 1
      i=$((i + 1))
    done
    kill -0 "${child}" 2>/dev/null || exit 0
    : >"${marker}"
    hzl_signal_tree TERM "${child}"
    i=0
    while [ ${i} -lt "${kill_after}" ]; do
      kill -0 "${child}" 2>/dev/null || exit 0
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "${child}" 2>/dev/null; then
      : >"${marker}.kill"
      hzl_signal_tree KILL "${child}"
    fi
  ) &
  watchdog=$!

  wait "${child}" 2>/dev/null
  rc=$?

  # Take the watchdog down on the normal path so it cannot outlive the run and
  # signal a recycled pid later.
  kill -TERM "${watchdog}" 2>/dev/null
  wait "${watchdog}" 2>/dev/null

  HEINZEL_ENGINE_PID=""

  if [ -e "${marker}.kill" ]; then
    rm -f "${marker}" "${marker}.kill"
    return 137
  fi
  if [ -e "${marker}" ]; then
    rm -f "${marker}"
    return 124
  fi
  rm -f "${marker}" "${marker}.kill" 2>/dev/null
  return ${rc}
}
