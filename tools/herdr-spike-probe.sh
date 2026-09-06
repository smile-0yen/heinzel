#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# herdr-spike-probe.sh — the bookkeeping half of the live Herdr spike.
#
# The spike itself is docs/HERDR-SPIKE.md and it needs a person at the machine:
# it starts servers, launches real agents, tries to break out of sandboxes, and
# reads terminals back. This script deliberately does none of that. It knows
# the step list and the gates, reports what is installed, keeps the results
# table, and renders the section that goes into docs/VERIFICATION.md — so the
# operator's attention goes to the terminal rather than to a spreadsheet.
#
#   herdr-spike-probe.sh list                      the steps and their gates
#   herdr-spike-probe.sh gates                     the gates and what a failure means
#   herdr-spike-probe.sh preflight                 what is installed (read-only)
#   herdr-spike-probe.sh env                       the disposable environment, printed
#   herdr-spike-probe.sh config                    the step B1 herdr config body
#   herdr-spike-probe.sh template                  start the results file
#   herdr-spike-probe.sh record <step> <result> [note]
#   herdr-spike-probe.sh render                    markdown table + gate verdict
#   herdr-spike-probe.sh run <step>                not implemented, on purpose
#
# `run` is a stub and stays one. A security gate that can report `pass` without
# a human reading the screen is worse than no gate: it produces a table that
# looks like evidence. Everything here either observes this machine read-only
# or edits a file under the spike directory. It installs nothing, starts no
# server, and launches no agent.
#
# Exit codes: 0 ok, 1 error, 2 usage, 3 needs a human.

set -uo pipefail

SPIKE_DIR=${HZL_SPIKE_DIR:-${PWD}/.heinzel/herdr-spike}
RESULTS="${SPIKE_DIR}/results.tsv"
VERSIONS="${SPIKE_DIR}/versions.md"
DOC="docs/HERDR-SPIKE.md"

# id|gate|purpose. The ids and gates are the same ones as in the document; if
# you add a step there, add it here, because `render` treats a step it does not
# know about as one that was never run.
steps() {
  cat <<'EOF'
A1|G-CAP|the herdr binary: resolved path, version, digest
A2|G-CAP|the CLI-embedded schema names every method 10.5 maps
A3|G-SEC|the agent binaries: real binaries, not aliases
A4|G-OWN|the disposable environment, outside every real workspace
B1|G-CFG|the dedicated config: bytes, mode, digest, config check
B2|G-CFG|whether config check tells the truth when the file is gone or broken
B3|G-PROV|headless server provision and bounded wait for ping
B4|G-DETACH|a launchd job owns the server and it survives its parent
B5|G-ADOPT|whether ping/status can prove PID, config path, resume setting
C1|G-LAUNCH|pane creation carries cwd, PATH and the env allowlist
C2|G-LAUNCH|the fresh-pane race, and agent_pane_busy vs every other error
C3|G-SEC|Claude interactive launch with the executor profile
C4|G-SEC|Codex interactive launch, executor and reviewer profiles
C5|G-TURN|a prompt acknowledgement is not evidence of activity
C6|G-TURN|the status walk: initial idle and post-dispatch settled differ
C7|G-TURN|blocked is detected as blocked, and what unknown means
C8|G-TURN|events.subscribe, the bootstrap gap, and the absent cursor
C9|G-OUT|what agent.read gives you in each mode and each state
C10|G-ATTEST|the native session reference is retrievable and stable
C11|G-ATTEST|how far pane.process_info goes, and where it stops
C12|G-REVIEW|structured reviewer output survives the terminal round trip
D1|G-SEC|dontAsk and the generated settings hold in the pane
D2|G-SEC|the workspace confinement holds
D3|G-SEC|the deny list holds: sudo and force-push refused, plain push not
D4|G-SEC|the Codex executor profile confines the same way
D5|G-SEC|the reviewer really is read-only
D6|G-SEC|inherited user config does not override the launch arguments
D7|G-SEC|clean shell: no user rc, bare agent names resolve to A3
D8|G-SEC|an auth or trust prompt reports blocked, not working
E1|G-INDEP|the injected socket variables, and whether they can be removed
E2|G-INDEP|sibling namespace sockets from inside the agent sandbox
E3|G-INDEP|the Heinzel control store from inside the agent sandbox
E4|G-INDEP|the reviewer control surface from inside the writer pane
E5|G-VERIFY|the verifier: network, credentials, writes, control store
F1|G-RECOVER|the controller dies and the agent is rediscovered
F2|G-TURN|the socket drops right after a prompt: is delivery decidable
F3|G-RESUME|the server restarts and nothing resumes by itself
F4|G-ATTEST|safe explicit resume keeps the same attested security profile
F5|G-ATTACH|workspace attach, agent attach, and their side effects
G1|G-OWN|dispose touches only what Heinzel owned
G2|G-OWN|nothing left behind: process, socket, job, directory
EOF
}

# gate|class|what a failure means. Class is the verdict rule, in the order the
# classes outrank each other: `critical` stops the implementation,
# `no-success` lets it be built but stops any run reaching SUCCESS,
# `required-review` only stops a Herdr reviewer counting as required, and
# `capability` turns a feature off.
#
# G-VERIFY is deliberately not critical. Its documented consequence is narrower
# than the other two: `exec_verifier` returns `verifier_unavailable` and no run
# reaches SUCCESS, which is a backend that gets built and then refuses to call
# anything done - not a backend that is never built. Classing it `critical`
# printed "do not implement the unattended Herdr backend" over a result that
# says no such thing.
gates() {
  cat <<'EOF'
G-SEC|critical|launch parity not established: do not implement the unattended backend
G-ATTEST|critical|attestation insufficient: refuse resume; no unattended backend if it cannot fail closed
G-VERIFY|no-success|verifier cannot be isolated: exec_verifier returns verifier_unavailable, no run reaches SUCCESS
G-INDEP|required-review|a Herdr reviewer in the writer trust domain is never a required review
G-PROV|capability|no headless server: there is no backend to implement
G-CAP|capability|version/method probe fails: --backend herdr refuses to start, no local fallback
G-CFG|capability|config provisioning unprovable: treat as provision failure
G-ADOPT|capability|unknown same-name servers indistinguishable: always a fresh random namespace
G-DETACH|capability|no --detach on this platform: synchronous runs only
G-LAUNCH|capability|start is not deterministic: contract-test the start algorithm before Phase 3
G-TURN|capability|turn correlation weaker than 11: widen DELIVERY_UNKNOWN, never resend
G-OUT|capability|terminal output is not an audit source
G-REVIEW|capability|structured review runs on LocalRuntime instead
G-RECOVER|capability|rediscovery unreliable: the durable handle needs more identity
G-RESUME|capability|cold restart unsafe: INTERRUPTED is terminal rather than resumable
G-ATTACH|capability|workspace-level attach only, no --agent
G-OWN|capability|ownership leaks on teardown: fix before anything runs unattended
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }

# The header block is the usage text. Read to the first line that is not a
# comment rather than to a line number, so that editing the header cannot
# silently truncate the help.
usage() {
  awk 'NR < 4 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exit 2
}

step_gate() {
  steps | awk -F'|' -v id="$1" '$1 == id { print $2; exit }'
}

digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -c1-16
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -c1-16
  else
    printf 'no-sha256-tool'
  fi
}

# A tool report is three columns: name, resolved path, version + digest. A
# missing tool is reported, not treated as an error - "herdr is not installed"
# is the correct outcome of a preflight on a machine that has not opted in.
report_tool() {
  local name=$1 path ver
  path=$(command -v "${name}" 2>/dev/null)
  if [ -z "${path}" ]; then
    printf '  %-8s not installed\n' "${name}"
    return 0
  fi
  ver=$("${name}" --version 2>/dev/null | head -1)
  printf '  %-8s %s\n' "${name}" "${path}"
  printf '  %-8s version: %s  sha256: %s\n' '' "${ver:-unknown}" "$(digest "${path}")"
  case $(type -a "${name}" 2>/dev/null | head -1) in
    *' is a function'*|*' is aliased to '*)
      printf '  %-8s WARNING: shadowed by a shell function or alias (see step D7)\n' '' ;;
  esac
}

cmd_list() {
  printf '%-4s %-11s %s\n' STEP GATE PURPOSE
  steps | while IFS='|' read -r id gate purpose; do
    printf '%-4s %-11s %s\n' "${id}" "${gate}" "${purpose}"
  done
  printf '\n%s steps. The procedure for each one is in %s.\n' \
    "$(steps | wc -l | tr -d ' ')" "${DOC}"
}

cmd_gates() {
  printf '%-11s %-15s %s\n' GATE CLASS 'IF IT FAILS'
  gates | while IFS='|' read -r gate class rule; do
    printf '%-11s %-15s %s\n' "${gate}" "${class}" "${rule}"
  done
}

# Read-only. Nothing here starts a server, launches an agent, or writes a file.
cmd_preflight() {
  printf 'machine\n'
  printf '  %-8s %s\n' 'os' "$(sw_vers -productVersion 2>/dev/null || uname -sr)"
  printf '  %-8s %s\n' 'bash' "${BASH_VERSION}"
  printf '\ntools\n'
  report_tool herdr
  report_tool claude
  report_tool codex
  printf '\ninherited herdr environment\n'
  local found=0 v val
  for v in HERDR_SESSION HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH \
           HERDR_CONFIG_PATH HERDR_BIN_PATH; do
    eval "val=\${${v}:-}"
    if [ -n "${val}" ]; then
      printf '  %s=%s\n' "${v}" "${val}"
      found=1
    fi
  done
  if [ "${found}" = 1 ]; then
    printf '  ^ clear these before every spike command. A socket override beats\n'
    printf '    a session name, so an inherited one silently retargets the call\n'
    printf '    at your own namespace (docs/RUNTIME-BACKENDS.md 10.3).\n'
  else
    printf '  none set\n'
  fi
  printf '\nspike directory\n  %s%s\n' "${SPIKE_DIR}" \
    "$([ -d "${SPIKE_DIR}" ] && printf '' || printf '  (not created yet)')"
  if ! command -v herdr >/dev/null 2>&1; then
    printf '\nherdr is not installed, so the spike cannot run. Installing it is a\n'
    printf 'decision with its own review; it is not a step of this spike.\n'
  fi
}

# Printed, not created. Creating the config is step B1 and belongs to the human
# who is watching what it does.
cmd_env() {
  local suffix stamp
  suffix=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "${suffix}" ] || suffix=$(printf '%06x' $$)
  stamp=$(date +%Y%m%dT%H%M%S)

  cat <<EOF
# The disposable environment for one spike. Printed, not created: creating the
# config is step B1, and you should watch it happen. The workspace must be a
# fresh worktree of a scratch repository - Stage D asks agents to write where
# they should not and Stage F kills them mid-turn, so do not point either at
# work you want to keep.

export HZL_SPIKE_ID=${stamp}-${suffix}
export HZL_SPIKE_DIR=${SPIKE_DIR}
export HERDR_NAMESPACE=hzl-spike-${suffix}
export HERDR_CONFIG_PATH=${SPIKE_DIR}/herdr/herdr.toml
export HEINZEL_HOME=${SPIKE_DIR}/heinzel-home
export HZL_SPIKE_WORKTREE=${SPIKE_DIR}/worktree

unset HERDR_SESSION HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_BIN_PATH
EOF
}

# The config body for step B1, on its own so that neither output has to be
# edited before it is used. TOML takes # comments, so these survive the paste.
cmd_config() {
  cat <<'EOF'
# Written atomically, mode 0600, into a directory the agent's confinement
# cannot write. Record the digest of what you wrote before you believe
# anything `herdr config check` says about it: docs/RUNTIME-BACKENDS.md 10.2
# holds that check alone can report ok for defaults when the file is missing,
# and the default has automatic resume on. That is step B2.

onboarding = false

[session]
resume_agents_on_restore = false
EOF
}

cmd_template() {
  [ -e "${RESULTS}" ] && die "already started: ${RESULTS} (delete it to start over)"
  mkdir -p "${SPIKE_DIR}" || die "cannot create ${SPIKE_DIR}"
  : >"${RESULTS}" || die "cannot write ${RESULTS}"
  steps | while IFS='|' read -r id _gate _purpose; do
    printf '%s\ttodo\t\n' "${id}" >>"${RESULTS}"
  done
  if [ ! -e "${VERSIONS}" ]; then
    cat >"${VERSIONS}" <<'EOF'
| | |
|---|---|
| date | |
| herdr CLI | |
| herdr server | |
| claude | |
| codex | |
| macOS | |
| namespace | |
| operator | |
EOF
  fi
  printf 'results: %s (%s steps, all todo)\n' \
    "${RESULTS}" "$(steps | wc -l | tr -d ' ')"
  printf 'versions: %s  <- fill this in first; every answer is an answer\n' "${VERSIONS}"
  printf '          about one version of three programs.\n'
}

cmd_record() {
  local id=$1 result=$2 note=${3:-} tmp
  [ -e "${RESULTS}" ] || die "no results file: run '${0##*/} template' first"
  [ -n "$(step_gate "${id}")" ] || die "no such step: ${id} (see '${0##*/} list')"
  case ${result} in
    pass|fail|na|todo) ;;
    *) die "result must be pass, fail, na or todo (got: ${result})" ;;
  esac
  case ${result} in
    na) [ -n "${note}" ] || die "na needs a reason: which step made it not applicable?" ;;
    fail) [ -n "${note}" ] || die "fail needs a note: what was observed?" ;;
  esac
  note=$(printf '%s' "${note}" | tr '\t\n' '  ')

  tmp="${RESULTS}.tmp.$$"
  awk -F'\t' -v id="${id}" 'BEGIN{OFS="\t"} $1 != id' "${RESULTS}" >"${tmp}" || {
    rm -f "${tmp}"; die "cannot rewrite ${RESULTS}"
  }
  printf '%s\t%s\t%s\n' "${id}" "${result}" "${note}" >>"${tmp}"
  mv "${tmp}" "${RESULTS}" || die "cannot replace ${RESULTS}"
  printf '%s %s [%s] %s\n' "${id}" "$(step_gate "${id}")" "${result}" "${note}"
}

lookup() {
  awk -F'\t' -v id="$1" -v col="$2" '$1 == id { print $col; f=1 } END { if (!f) print "" }' \
    "${RESULTS}"
}

# A gate is failed if any of its steps failed, incomplete if any of them went
# unanswered, and passed only if every one of them was looked at and held.
# Incomplete counts as failed for the gates that stop something: not having
# looked and having looked and seen nothing are the same answer to a
# fail-closed question.
#
# `na` is unanswered, not answered well. It is the honest record of a step that
# could not be run - the earlier step it depended on failed, the platform has
# no such feature - and every one of those reasons leaves the safety question
# it was asking still open. Counting it as a pass is how a gate comes to read
# `pass` on the strength of the checks nobody performed, which is the one
# failure mode this whole table exists to prevent. A step that genuinely does
# not apply is a step that should not be in the list.
gate_verdict() {
  local gate=$1 id g r verdict=pass
  while IFS='|' read -r id g _purpose; do
    [ "${g}" = "${gate}" ] || continue
    r=$(lookup "${id}" 2)
    case ${r} in
      fail) printf 'fail\n'; return 0 ;;
      todo|na|'') verdict=incomplete ;;
    esac
  done <<EOF
$(steps)
EOF
  printf '%s\n' "${verdict}"
}

cmd_render() {
  [ -e "${RESULTS}" ] || die "no results file: run '${0##*/} template' first"
  local id gate purpose result note class verdict
  local critical_bad=0 verify_bad=0 indep_bad=0 cap_bad=0

  printf '### Herdr Phase 0 — versions\n\n'
  if [ -e "${VERSIONS}" ]; then cat "${VERSIONS}"; else printf '_(not recorded)_\n'; fi

  printf '\n### Herdr Phase 0 — results\n\n'
  printf '| Step | Gate | Result | Observed | Evidence |\n'
  printf '|---|---|---|---|---|\n'
  while IFS='|' read -r id gate purpose; do
    result=$(lookup "${id}" 2)
    note=$(lookup "${id}" 3)
    [ -n "${result}" ] || result=todo
    printf '| %s | %s | %s | %s | |\n' "${id}" "${gate}" "${result}" "${note}"
  done <<EOF
$(steps)
EOF

  printf '\n### Herdr Phase 0 — verdict\n\n'
  printf '| Gate | Class | Verdict |\n'
  printf '|---|---|---|\n'
  while IFS='|' read -r gate class _rule; do
    verdict=$(gate_verdict "${gate}")
    printf '| %s | %s | %s |\n' "${gate}" "${class}" "${verdict}"
    if [ "${verdict}" != pass ]; then
      case ${class} in
        critical) critical_bad=1 ;;
        no-success) verify_bad=1 ;;
        required-review) indep_bad=1 ;;
        *) cap_bad=1 ;;
      esac
    fi
  done <<EOF
$(gates)
EOF

  printf '\n**Outcome:** '
  if [ "${critical_bad}" = 1 ]; then
    printf 'do not implement the unattended Herdr backend. A critical gate is\n'
    printf 'failed or incomplete; amend docs/RUNTIME-BACKENDS.md with what was\n'
    printf 'measured. Phases 1 and 2 are LocalRuntime work and are unaffected.\n'
  elif [ "${verify_bad}" = 1 ]; then
    printf 'implement the backend, but no run reaches SUCCESS. The verifier\n'
    printf 'cannot be shown to be isolated, so exec_verifier returns\n'
    printf 'verifier_unavailable rather than degrading to an unsandboxed\n'
    printf 'command. An unattended run that cannot check its own work does not\n'
    printf 'get to call it done; fix the isolation before Phase 4.\n'
  elif [ "${indep_bad}" = 1 ]; then
    printf 'proceed with hybrid required review. A Herdr reviewer sharing the\n'
    printf 'writer trust domain does not count as a required review; it runs on\n'
    printf 'a separate UID/host or on LocalRuntime.\n'
  elif [ "${cap_bad}" = 1 ]; then
    printf 'proceed with the failed capabilities reported false in the\n'
    printf 'CapabilityReport. A missing capability is an explicit refusal, never\n'
    printf 'a silent degradation into a different meaning.\n'
  else
    printf 'proceed to Phase 1.\n'
  fi
  printf '\n_Rendered by tools/%s; procedure in %s._\n' "${0##*/}" "${DOC}"
}

# Not implemented, and not an oversight. See the header.
cmd_run() {
  local id=$1 gate
  gate=$(step_gate "${id}")
  [ -n "${gate}" ] || die "no such step: ${id} (see '${0##*/} list')"
  printf 'step %s (%s) is not automated, and will not be.\n\n' "${id}" "${gate}"
  printf 'It needs a person watching the terminal: the procedure, what a pass\n'
  printf 'looks like, and what to do when it is not a pass are under "%s" in\n' "${id}"
  printf '%s. When you have run it:\n\n' "${DOC}"
  printf '    %s record %s pass|fail|na "what you saw"\n\n' "${0##*/}" "${id}"
  exit 3
}

case ${1:-} in
  list) [ $# -eq 1 ] || usage; cmd_list ;;
  gates) [ $# -eq 1 ] || usage; cmd_gates ;;
  preflight) [ $# -eq 1 ] || usage; cmd_preflight ;;
  env) [ $# -eq 1 ] || usage; cmd_env ;;
  config) [ $# -eq 1 ] || usage; cmd_config ;;
  template) [ $# -eq 1 ] || usage; cmd_template ;;
  record) [ $# -ge 3 ] || usage; cmd_record "$2" "$3" "${4:-}" ;;
  render) [ $# -eq 1 ] || usage; cmd_render ;;
  run) [ $# -eq 2 ] || usage; cmd_run "$2" ;;
  *) usage ;;
esac
