#!/usr/bin/env bash
# Portable backend quality gate. Requires Java 21 and Maven on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/server"

mvn --batch-mode --no-transfer-progress verify
