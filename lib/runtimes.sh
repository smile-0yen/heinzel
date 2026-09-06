#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/runtimes.sh — the runtime backend registry.
#
# A runtime backend is the thing that actually starts an agent and watches it.
# Today there is one, `local`: this machine, this process group, the watchdog in
# lib/watchdog.sh. Later there is a second one that starts agents inside a
# terminal multiplexer on this or another host (docs/RUNTIME-BACKENDS.md §8).
#
# The registry exists so that the second one is a new file and a registration,
# never a new arm in a case statement somewhere else. Nothing outside
# lib/runtimes/ may branch on the backend key: code that did would have to be
# found and edited again for the third backend, and that is exactly the shape
# this design is trying not to have (§8.4).
#
# Dispatch is by constructed function name — `runtime_<backend>_run_batch` — so
# a backend is looked up the way any command is looked up, without `eval` and
# without an associative array, neither of which stock bash 3.2 would give us
# anyway.
#
# Contract, as far as Phase 1 needs it:
#
#   runtime_register  <backend>
#   runtime_known     <backend>                                        -> 0/1
#   runtime_backends                          the registered keys, one per line
#   runtime_selected                          the backend this run goes to
#   runtime_run_batch <backend> <launch.json> <run.json> <collected.json>
#
# Everything crosses the boundary as a path to a JSON file, never as a shell
# string and never as an array: the next backend is not necessarily written in
# shell, and the one after that is not necessarily on this machine.
#
# The wider contract in §8 — provision, observe, attach, reconcile, dispose —
# arrives with the durable workflow in Phase 2. A one-shot batch run is all the
# current runner asks for, and a registry full of functions that return
# "unsupported" would be a worse description of this backend than their absence.
#
# Requires lib/common.sh.

_HZ_RUNTIMES=""

runtime_register() {
  local backend=$1
  case ${backend} in
    ""|*[!a-z0-9_-]*)
      err "not a usable runtime backend key: '${backend}'"
      return 1
      ;;
  esac
  runtime_known "${backend}" && return 0
  _HZ_RUNTIMES="${_HZ_RUNTIMES} ${backend}"
}

runtime_known() {
  local b
  for b in ${_HZ_RUNTIMES}; do
    [ "$1" = "${b}" ] && return 0
  done
  return 1
}

runtime_backends() {
  local b
  for b in ${_HZ_RUNTIMES}; do
    printf '%s\n' "${b}"
  done
}

# The backend this run goes to: the one the session promised, and only failing
# that the one the environment asks for.
#
# The session's answer comes first because `hzl on` recorded it while someone
# was there to choose it, and the run that keeps that promise starts at 03:00
# from launchd — which passes a minimal environment and none of ours
# (docs/SPEC.md §9.0, §14). `HEINZEL_RUNTIME` read at that moment could only
# ever say `local`, whatever the session asked for, and the run would then
# record a backend it had not used. So the environment variable is what selects
# a backend when there is no session to have selected one: a run started by
# hand, or a `hzl on` choosing what to write down in the first place.
#
# The key is not validated here. `hzl on` refuses one the registry does not
# know, and `runtime_run_batch` refuses it again at the moment of use — a state
# file written by a build that had a backend this one does not must fail the
# run, not fall back to the backend that happens to be here.
runtime_selected() {
  if [ -r "${STATE_FILE:-}" ]; then
    state_runtime_backend
    return
  fi
  printf '%s' "${HEINZEL_RUNTIME:-local}"
}

# Start what <launch.json> names, on <backend>, according to <run.json>, and
# leave what was observed in <collected.json>. Returns the process's own exit
# status, so that a caller which only cares about that need not read the file.
runtime_run_batch() {
  local backend=$1
  shift
  local fn="runtime_${backend}_run_batch"

  if ! runtime_known "${backend}"; then
    err "unknown runtime backend: ${backend}"
    return 1
  fi
  # A registered backend that does not implement the operation is a bug in that
  # backend, and saying so is better than falling back to one that does.
  if ! command -v "${fn}" >/dev/null 2>&1; then
    err "runtime backend ${backend} cannot run a batch job"
    return 1
  fi

  "${fn}" "$@"
}

# The backends this build ships. A new one is a file and a line here.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=runtimes/local.sh
. "${HEINZEL_ROOT}/lib/runtimes/local.sh"
