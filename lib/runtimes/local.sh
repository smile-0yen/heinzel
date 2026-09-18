#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/runtimes/local.sh — the local runtime backend.
#
# It starts a process on this machine, holds it to a wall clock, and writes down
# what it observed. It does not know what an engine is, what a role is, or what
# any of the arguments it passes on mean. Everything it needs arrives as JSON
# (docs/RUNTIME-BACKENDS.md §8.4).
#
#   runtime_local_run_batch <launch.json> <run.json> <collected.json>
#
# launch.json     schema_version, executable, argv[], env{}   (the Agent Driver
#                 writes it; see lib/engines.sh)
# run.json        schema_version, cwd, timeout_sec, kill_after_sec,
#                 stdout_path, stderr_path, output_path
# collected.json  schema_version, exit_code, duration_sec, and the three paths
#                 it wrote to, so a later reader does not have to remember them
#
# The work is `hzl-exec run` (go/run.go). What is left here is the registration
# and the two things the shell still owns: publishing the pid a stop barrier
# reaches for, and clearing it afterwards.
#
# The spec validation moved with the rest — an argv entry that is not a string,
# a NUL byte in an argument or an environment value, an environment name `env`
# could not set. It is still refused before anything is started, still refused
# whole rather than honoured in part (§8.1), and still leaves no collected
# record behind: a launch that never reached a process must not be readable as
# one that did.
#
# Requires lib/common.sh and lib/watchdog.sh.

runtime_register local

runtime_local_run_batch() {
  local launch=$1 run=$2 collected=$3
  local child rc had_monitor

  hzl_exec_require || return 1

  case $- in
    *m*) had_monitor=1 ;;
    *) had_monitor=0; set -m ;;
  esac

  "${HZL_EXEC}" run "${launch}" "${run}" "${collected}" &
  child=$!
  HEINZEL_ENGINE_PID=${child}

  [ "${had_monitor}" -eq 0 ] && set +m

  wait "${child}" 2>/dev/null
  rc=$?

  HEINZEL_ENGINE_PID=""
  return ${rc}
}
