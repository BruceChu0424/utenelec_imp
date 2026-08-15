#!/usr/bin/env bash
# Deprecated compatibility shim.  It performs no installation writes.
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly LAUNCHER=/usr/local/sbin/uten-imp-release-retention-installer

if [[ ! -f "$LAUNCHER" || -L "$LAUNCHER" ]]; then
  printf '%s\n' \
    'RETENTION_INSTALL_NO_GO: reviewed Python installer launcher is not installed at its fixed path' >&2
  exit 78
fi

exec /usr/bin/python3 -I -B "$LAUNCHER" -- "$@"
