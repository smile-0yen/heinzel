#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/watchdog.sh — the wall clock, and how a process tree is signalled.
#
# Stock macOS ships neither `timeout` nor `gtimeout` (measured on 26.6.2), and
# the wall-clock budget is not optional, so we carry our own (DESIGN 6.1).
#
# What used to be here was that timeout, written in shell: a background job, a
# `set -m` toggled around it so the job led a process group, a watchdog
# subshell, and a marker file carrying the verdict back across the subshell
# boundary because a subshell cannot set a variable in its parent. Four
# mechanisms for one idea, and every one of them had a comment explaining which
# rearrangement of it would silently orphan a running engine.
#
# It is now `hzl-exec timeout` (go/proc.go), where the process group is a field
# on the exec call and the verdict is a return value. What remains here is the
# shell's side of the same contract:
#
#   hzl_timeout <kill_after> <seconds> <command> [args...]
#
#   exit 124  the command was killed after exceeding <seconds>
#   exit 137  the command ignored TERM and was killed after <kill_after> more
#   exit 125  refused before anything started
#   otherwise the command's own exit status
#
# Two properties of the old implementation are kept deliberately, because
# callers depend on them and neither is the binary's to provide:
#
#   * the job is backgrounded under job control, so that the pid published as
#     HEINZEL_ENGINE_PID leads a process group and `cancel_stop ... tree` has a
#     group to address (lib/cancel.sh §14.5);
#   * HEINZEL_ENGINE_PID is set for exactly as long as something is running,
#     and cleared after, so that a stop barrier reading it never signals a pid
#     the kernel has since handed to somebody else.
#
# The engine itself is in a further group of its own, which `hzl-exec` holds
# and forwards to. That is stricter than what it replaces: the engine is now
# stopped by a process that then waits to see it gone, rather than by a signal
# aimed at a group it was assumed to have joined.
#
# Requires lib/common.sh.

HEINZEL_ENGINE_PID=""

# Signal a whole process group, falling back to the single pid when the target
# never became a group leader. Still here, and still shell, because lib/cancel.sh
# signals things this file never started.
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

  hzl_exec_require || return 125

  local child rc had_monitor
  # Job control makes each background job a process-group leader. Without it
  # the pid below is in this shell's group, and `kill -- -pid` would address
  # whatever else happens to be in it.
  case $- in
    *m*) had_monitor=1 ;;
    *) had_monitor=0; set -m ;;
  esac

  "${HZL_EXEC}" timeout "${kill_after}" "${secs}" "$@" &
  child=$!
  HEINZEL_ENGINE_PID=${child}

  [ "${had_monitor}" -eq 0 ] && set +m

  wait "${child}" 2>/dev/null
  rc=$?

  HEINZEL_ENGINE_PID=""
  return ${rc}
}

# The same wall clock around a probe, which is a different thing from a run.
#
# A usage query is not the run's engine, so its pid must not be published as
# HEINZEL_ENGINE_PID: a stop barrier reading that variable would aim at
# whatever was asking `claude -p /usage` rather than at the agent writing to
# the working directory. Nothing is backgrounded here either, so the probe
# keeps whatever stdin it was given — `codex app-server` is the right-hand side
# of a pipeline and the request it has to read arrives down it.
hzl_timeout_probe() {
  local kill_after=$1 secs=$2
  shift 2
  [ $# -ge 1 ] || return 125
  case ${kill_after}${secs} in
    *[!0-9]*) return 125 ;;
  esac
  hzl_exec_require || return 125
  "${HZL_EXEC}" timeout "${kill_after}" "${secs}" "$@"
}
