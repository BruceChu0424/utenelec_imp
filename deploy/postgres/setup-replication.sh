#!/usr/bin/env bash
# Kept only as a fail-closed compatibility guard. Preparing the primary and
# replacing a replica PGDATA are deliberately separate operations now.
set -Eeuo pipefail

cat >&2 <<'EOF'
setup-replication.sh no longer performs any changes.

Run the two reviewed steps explicitly:
  1. bash deploy/postgres/prepare-primary.sh
  2. bash deploy/postgres/clone-replica.sh

See deploy/cloud/README-cloud.md for required secret files, exact PGDATA/HBA
validation, restart, backup and failover procedures.
EOF
exit 64
