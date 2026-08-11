#!/usr/bin/env bash
# Portable Flutter quality gate. Requires the project Flutter SDK on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

flutter pub get
flutter analyze
flutter test
