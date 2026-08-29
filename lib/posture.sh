#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# lib/posture.sh — how exposed the machine is: travel or remote.
#
# Posture is *observed*, never stored (DESIGN 2.3). A stored posture would
# start lying the moment someone toggles Screen Sharing in System Settings, and
# a lying state file is worse than no state file. Every component below is read
# back from the OS.
#
# Two tiers of observation, because pf needs root and the unattended runner has
# none (measured: `pfctl -s info` -> "Permission denied" as the user):
#
#   unprivileged   screen sharing, wake-on-LAN, idle sleep, screen lock, sudoers
#   privileged     the above plus the packet filter
#
# The decisive components are all in the unprivileged tier, so gate 7 of
# effective_mode() works from inside the runner.
#
# Requires lib/common.sh.

SUDOERS_DIAG=/etc/sudoers.d/heinzel-diag
SUDOERS_TICKET=/etc/sudoers.d/heinzel-ticket
SS_LABEL=com.apple.screensharing
SS_PLIST=/System/Library/LaunchDaemons/com.apple.screensharing.plist
PF_TRAVEL=/etc/pf.anchors/heinzel-travel
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

# --- observation -----------------------------------------------------------

# The launchd job's own enable/disable state survives reboots, which is what
# `hzl travel` relies on. Port 5900 tells us whether it is actually up now.
posture_screensharing() {
  local disabled
  disabled=$(launchctl print-disabled system 2>/dev/null |
             grep -F "\"${SS_LABEL}\"" | grep -c "=> disabled")
  if [ "${disabled:-0}" -gt 0 ]; then
    printf travel
  elif nc -z -G 1 127.0.0.1 5900 >/dev/null 2>&1; then
    printf remote
  else
    # Enabled but not listening: it was booted out without being disabled.
    printf travel
  fi
}

posture_vnc_listening() {
  nc -z -G 1 127.0.0.1 5900 >/dev/null 2>&1 && printf yes || printf no
}

pmset_ac_value() {
  pmset -g custom 2>/dev/null | sed -n '/AC Power/,$p' |
    awk -v k="$1" '$1 == k {print $2; exit}'
}

posture_wol() {
  case "$(pmset_ac_value womp)" in
    1) printf remote ;;
    0) printf travel ;;
    *) printf unknown ;;
  esac
}

posture_idle_sleep() {
  local v
  v=$(pmset_ac_value sleep)
  case ${v} in
    "") printf unknown ;;
    "${HEINZEL_REMOTE_IDLE_SLEEP}") printf remote ;;
    "${HEINZEL_TRAVEL_IDLE_SLEEP}") printf travel ;;
    *) printf other ;;
  esac
}

screenlock_now() {
  local s
  s=$(sysadminctl -screenLock status 2>&1 | grep -oE '[0-9]+ seconds' | head -1 | awk '{print $1}')
  if [ -z "${s}" ] || [ "${s}" = 0 ]; then printf immediate; else printf '%s' "${s}"; fi
}

posture_screenlock() {
  local v
  v=$(screenlock_now)
  if [ "${v}" = "${HEINZEL_TRAVEL_SCREENLOCK}" ]; then
    printf travel
  elif [ "${v}" = "${HEINZEL_REMOTE_SCREENLOCK}" ]; then
    printf remote
  else
    printf other
  fi
}

posture_sudoers() {
  if [ -f "${SUDOERS_DIAG}" ]; then printf remote; else printf travel; fi
}

# Root-only. Everyone else gets `unknown`, and says so rather than guessing.
posture_firewall() {
  case "$(pfctl -s info 2>/dev/null | awk '/^Status:/{print $2; exit}')" in
    Enabled)
      if pfctl -s rules 2>/dev/null | grep -q '^block drop in all'; then
        printf travel
      else
        printf remote
      fi
      ;;
    Disabled) printf remote ;;
    *) printf unknown ;;
  esac
}

# The composed posture. Only the three components that are both decisive and
# unprivileged get a vote; the rest are reported but do not decide, because
# they are configurable values a user may legitimately set to anything.
#
#   unmanaged  posture management is switched off (HEINZEL_POSTURE=0)
#   travel     every voting component agrees on travel
#   remote     every voting component agrees on remote
#   mixed      they disagree - a half-failed transition, reported as such
posture_now() {
  [ "${HEINZEL_POSTURE:-0}" = 1 ] || { printf unmanaged; return; }
  local t=0 r=0 c
  for c in "$(posture_screensharing)" "$(posture_wol)" "$(posture_sudoers)"; do
    case ${c} in
      travel) t=$((t + 1)) ;;
      remote) r=$((r + 1)) ;;
    esac
  done
  if [ ${t} -gt 0 ] && [ ${r} -eq 0 ]; then
    printf travel
  elif [ ${r} -gt 0 ] && [ ${t} -eq 0 ]; then
    printf remote
  else
    printf mixed
  fi
}

# --- mutation --------------------------------------------------------------
#
# Every setter below has the same shape: set, read back, compare, report the
# mismatch. macOS 26 has several settings tools that return 0 on failure
# (DESIGN 6.2), so an exit code is not evidence that anything happened.

POSTURE_DRY_RUN=0
POSTURE_FAILED=0

# Echo the command in dry-run mode, run it otherwise.
prun() {
  if [ "${POSTURE_DRY_RUN}" = 1 ]; then
    printf '  would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

posture_step_failed() {
  POSTURE_FAILED=$((POSTURE_FAILED + 1))
  bad "  ! $*"
}

posture_set_screensharing() {
  local want=$1 got
  if [ "${want}" = on ]; then
    prun sudo launchctl enable "system/${SS_LABEL}"
    prun sudo launchctl bootstrap system "${SS_PLIST}" 2>/dev/null
  else
    prun sudo launchctl bootout "system/${SS_LABEL}" 2>/dev/null
    prun sudo launchctl disable "system/${SS_LABEL}"
  fi
  [ "${POSTURE_DRY_RUN}" = 1 ] && return 0
  sleep 1
  got=$(posture_screensharing)
  case ${want}:${got} in
    on:remote|off:travel) return 0 ;;
    *) posture_step_failed "screen sharing did not become '${want}' (reads as ${got})" ;;
  esac
}

# Inbound blocking is done with pf, because socketfilterfw --setblockall is
# accepted and ignored on this OS. The application firewall itself and stealth
# mode do work, so they are set too.
posture_set_firewall() {
  local want=$1 out got
  prun sudo "${FW}" --setglobalstate on
  prun sudo "${FW}" --setstealthmode on

  if [ "${want}" = block ]; then
    if [ "${POSTURE_DRY_RUN}" = 1 ]; then
      printf '  would install %s and load it with pfctl\n' "${PF_TRAVEL}"
    else
      sed "s/__GENERATED__/$(iso_at)/" "${HEINZEL_ROOT}/etc/pf-travel.conf.in" |
        sudo tee "${PF_TRAVEL}" >/dev/null || {
          posture_step_failed "could not write ${PF_TRAVEL}"
          return 1
        }
      sudo chmod 644 "${PF_TRAVEL}"
      # Validate before loading: a malformed ruleset must not take the
      # packet filter down while we think we are securing it.
      if ! out=$(sudo pfctl -n -f "${PF_TRAVEL}" 2>&1); then
        posture_step_failed "pf ruleset failed validation, inbound NOT blocked"
        printf '    %s\n' "${out}"
        return 1
      fi
      sudo pfctl -f "${PF_TRAVEL}" >/dev/null 2>&1
      sudo pfctl -e >/dev/null 2>&1
    fi
  else
    prun sudo pfctl -d
    prun sudo pfctl -f /etc/pf.conf
  fi

  [ "${POSTURE_DRY_RUN}" = 1 ] && return 0
  got=$(posture_firewall)
  case ${want}:${got} in
    block:travel|normal:remote) return 0 ;;
    *:unknown) warn "  could not read pf state back (needs root)"; return 0 ;;
    *) posture_step_failed "inbound blocking did not become '${want}' (reads as ${got})" ;;
  esac
}

posture_set_power() {
  local want=$1 idle got
  if [ "${want}" = travel ]; then
    idle=${HEINZEL_TRAVEL_IDLE_SLEEP}
    prun sudo pmset -c sleep "${idle}" disksleep "${idle}" womp 0
  else
    idle=${HEINZEL_REMOTE_IDLE_SLEEP}
    prun sudo pmset -c sleep "${idle}" disksleep "${idle}" womp 1
  fi
  [ "${POSTURE_DRY_RUN}" = 1 ] && return 0
  got=$(posture_wol)
  [ "${got}" = "${want}" ] || posture_step_failed "wake-on-LAN did not become '${want}' (reads as ${got})"
}

# sysadminctl needs the user's password on stdin and returns 0 on failure.
posture_set_screenlock() {
  local want=$1 got
  if [ "${POSTURE_DRY_RUN}" = 1 ]; then
    printf '  would set the screen lock delay to %s\n' "${want}"
    return 0
  fi
  say "  setting the screen lock delay to ${want} (this asks for your login password)"
  sysadminctl -screenLock "${want}" -password - || true
  got=$(screenlock_now)
  if [ "${got}" != "${want}" ]; then
    posture_step_failed "screen lock is ${got}, not ${want}"
    say "    set it by hand: System Settings > Lock Screen > Require password"
  fi
}

# visudo -c before installing: a syntax error here breaks sudo itself, and
# recovering from that needs the very privilege it just removed.
posture_install_sudoers() {
  local which=$1 src dst tmp user=${SUDO_USER:-$(id -un)}
  case ${which} in
    diag) src=${HEINZEL_ROOT}/etc/sudoers-diag.in; dst=${SUDOERS_DIAG} ;;
    ticket) src=${HEINZEL_ROOT}/etc/sudoers-ticket.in; dst=${SUDOERS_TICKET} ;;
    *) return 1 ;;
  esac
  if [ "${POSTURE_DRY_RUN}" = 1 ]; then
    printf '  would install %s\n' "${dst}"
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/hzl-sudoers.XXXXXX") || return 1
  sed -e "s/__USER__/${user}/g" \
      -e "s/__TIMEOUT__/${HEINZEL_TICKET_TIMEOUT:-480}/g" "${src}" >"${tmp}"
  if ! visudo -cf "${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    posture_step_failed "sudoers template ${which} failed validation, not installed (sudo is untouched)"
    return 1
  fi
  sudo install -m 440 -o root -g wheel "${tmp}" "${dst}" || {
    rm -f "${tmp}"
    posture_step_failed "could not install ${dst}"
    return 1
  }
  rm -f "${tmp}"
}

posture_remove_sudoers() {
  local which=$1 dst
  case ${which} in
    diag) dst=${SUDOERS_DIAG} ;;
    ticket) dst=${SUDOERS_TICKET} ;;
    *) return 1 ;;
  esac
  [ -e "${dst}" ] || return 0
  prun sudo rm -f "${dst}"
  [ "${POSTURE_DRY_RUN}" = 1 ] && return 0
  [ -e "${dst}" ] && posture_step_failed "could not remove ${dst}"
  return 0
}

# Invalidate tickets already issued, so removing the sudoers file takes effect
# now rather than whenever the outstanding ticket happens to expire.
posture_purge_tickets() {
  local user=${SUDO_USER:-$(id -un)}
  prun sudo rm -rf "/var/db/sudo/ts/${user}"
  return 0
}

# Claude Code's own remote control switch. Keys are merged, not overwritten.
posture_patch_claude_settings() {
  local at_startup=$1 disable=$2
  if [ "${POSTURE_DRY_RUN}" = 1 ]; then
    printf '  would set remoteControlAtStartup=%s disableRemoteControl=%s in %s\n' \
      "${at_startup}" "${disable}" "${HEINZEL_CLAUDE_SETTINGS}"
    return 0
  fi
  [ -n "${HEINZEL_CLAUDE_SETTINGS}" ] || return 0
  local dir tmp
  dir=$(dirname "${HEINZEL_CLAUDE_SETTINGS}")
  mkdir -p "${dir}" || return 1
  tmp=$(mktemp "${dir}/.hzl-settings.XXXXXX") || return 1
  if [ -f "${HEINZEL_CLAUDE_SETTINGS}" ] &&
     ! jq -e . "${HEINZEL_CLAUDE_SETTINGS}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    posture_step_failed "${HEINZEL_CLAUDE_SETTINGS} is not valid JSON, leaving it alone"
    return 1
  fi
  if [ ! -f "${HEINZEL_CLAUDE_SETTINGS}" ]; then printf '{}' >"${HEINZEL_CLAUDE_SETTINGS}"; fi
  if jq --argjson s "${at_startup}" --argjson d "${disable}" \
       'if $d then .disableRemoteControl = true else del(.disableRemoteControl) end
        | .remoteControlAtStartup = $s' \
       "${HEINZEL_CLAUDE_SETTINGS}" >"${tmp}" 2>/dev/null; then
    mv -f "${tmp}" "${HEINZEL_CLAUDE_SETTINGS}"
  else
    rm -f "${tmp}"
    posture_step_failed "could not update ${HEINZEL_CLAUDE_SETTINGS}"
  fi
}

# --- transitions -----------------------------------------------------------

# `allow_ticket` is 0 while an unattended session is live: the write-capable
# sudo window stays shut for its duration (DESIGN 4.3).
posture_apply() {
  local want=$1 allow_ticket=${2:-1}
  POSTURE_FAILED=0

  case ${want} in
    travel)
      say "Switching to travel posture."
      posture_set_screensharing off
      posture_set_firewall block
      posture_set_power travel
      posture_set_screenlock "${HEINZEL_TRAVEL_SCREENLOCK}"
      posture_remove_sudoers ticket
      posture_remove_sudoers diag
      posture_purge_tickets
      posture_patch_claude_settings false true
      ;;
    remote)
      say "Switching to remote posture."
      posture_set_screensharing on
      posture_set_firewall normal
      posture_set_power remote
      posture_set_screenlock "${HEINZEL_REMOTE_SCREENLOCK}"
      posture_install_sudoers diag
      if [ "${allow_ticket}" = 1 ]; then
        posture_install_sudoers ticket
      else
        posture_remove_sudoers ticket
        say "  the sudo ticket window stays closed while a session is running"
      fi
      posture_patch_claude_settings true false
      ;;
    *) return 1 ;;
  esac

  [ "${POSTURE_FAILED}" -eq 0 ]
}
