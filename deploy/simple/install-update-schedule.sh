#!/usr/bin/env bash
# Compatibility installer name: automatic schedules have been retired.
set -euo pipefail
SRC=${1:?Usage: sudo bash install-update-schedule.sh /reviewed/deploy/simple}
[ -f "$SRC/install-server-operations.sh" ] && [ ! -L "$SRC/install-server-operations.sh" ] || {
  echo 'Use the complete reviewed deploy/simple directory and install-server-operations.sh.' >&2
  exit 1
}
exec /bin/bash "$SRC/install-server-operations.sh" "$SRC"
