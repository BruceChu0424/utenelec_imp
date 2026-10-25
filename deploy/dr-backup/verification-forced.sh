#!/bin/sh
# Dedicated new verifier key only. Never reuse the upload or cloud admin key.
# Install only after root records that old unleased management exports drained.
set -eu
if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
  exit 126
fi
exec /usr/bin/python3 -I /usr/local/libexec/uten-imp-dr-backup/verification_session.py \
  --config /etc/uten-imp-dr-backup/receiver.json --legacy-exports-drained
