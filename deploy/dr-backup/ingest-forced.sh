#!/bin/sh
set -eu
[ -z "${SSH_ORIGINAL_COMMAND:-}" ] || exit 64
exec /usr/bin/sudo -n -- /usr/bin/python3 -I /usr/local/libexec/uten-imp-dr-backup/continuous_backup.py receive --config /etc/uten-imp-dr-backup/receiver.json
