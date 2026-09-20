#!/bin/bash
# Daily entry point shared with the verified paired database/media backup.
# The helper publishes only a complete snapshot and keeps the last successful
# set intact on failure. Configuration and backup sets are root-only.
set -euo pipefail
umask 077

exec /usr/bin/python3 /usr/local/lib/uten-imp/paired_internal_backup.py \
  --config /etc/uten-imp/paired-internal-backup.json
