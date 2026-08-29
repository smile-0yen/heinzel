#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# install.sh — put `hzl` on your PATH. Deliberately small: it creates a symlink
# and a configuration file, and nothing else. Scheduling is a separate,
# explicit step (`hzl install`), and so is anything privileged.

set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BINDIR=${HZL_BINDIR:-${HOME}/.local/bin}

if [ "$(id -u)" -eq 0 ]; then
  printf 'Do not run this with sudo. Heinzel installs per user.\n' >&2
  exit 1
fi

for c in jq caffeinate pmset launchctl lockf; do
  command -v "${c}" >/dev/null 2>&1 || {
    printf 'missing prerequisite: %s\n' "${c}" >&2
    exit 1
  }
done

mkdir -p "${BINDIR}" || exit 1
ln -sf "${ROOT}/bin/hzl" "${BINDIR}/hzl"
printf 'linked %s -> %s\n' "${BINDIR}/hzl" "${ROOT}/bin/hzl"

if [ ! -f "${ROOT}/etc/heinzel.conf" ]; then
  cp "${ROOT}/etc/heinzel.conf.example" "${ROOT}/etc/heinzel.conf"
  printf 'created %s from the example\n' "${ROOT}/etc/heinzel.conf"
fi

case ":${PATH}:" in
  *":${BINDIR}:"*) ;;
  *) printf '\nNote: %s is not on your PATH.\n' "${BINDIR}" ;;
esac

cat <<NEXT

Next:

  1. Edit etc/heinzel.conf - at minimum DEFAULT_WORKDIR and DEFAULT_BACKLOG.
     They must be absolute paths.
  2. hzl doctor          check the setup
  3. hzl install         generate the launchd agent and the permission file
  4. hzl on --dry-run    see what starting a session would do

Nothing runs unattended until you run 'hzl on'.
NEXT
