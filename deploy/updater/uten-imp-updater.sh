#!/usr/bin/env bash
# Trusted, unprivileged entrypoint. systemd injects OSS credentials; this file never sources them.
set -euo pipefail
umask 027
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly UPDATER_DIR=/opt/uten-imp/updater
readonly PYTHON="$UPDATER_DIR/venv/bin/python"

die() {
  printf 'uten-imp-updater: %s\n' "$*" >&2
  exit 1
}

verify_trusted_file() {
  local path="$1" mode
  [[ -f "$path" && ! -L "$path" ]] || die "trusted file is missing or is a symlink: $path"
  [[ "$(stat -c '%u' -- "$path")" == "0" ]] || die "trusted file is not root-owned: $path"
  mode="$(stat -c '%a' -- "$path")"
  (( (8#$mode & 022) == 0 )) || die "trusted file is group/world-writable: $path"
}

verify_root_directory_chain() {
  local path="$1" mode
  while [[ "$path" != "/" ]]; do
    [[ -d "$path" && ! -L "$path" ]] || die "trusted directory is missing or is a symlink: $path"
    [[ "$(stat -c '%u' -- "$path")" == "0" ]] || die "trusted directory is not root-owned: $path"
    mode="$(stat -c '%a' -- "$path")"
    (( (8#$mode & 022) == 0 )) || die "trusted directory is group/world-writable: $path"
    path="$(dirname -- "$path")"
  done
}

[[ -x "$PYTHON" ]] || die "updater virtualenv Python is missing"
verify_root_directory_chain "$UPDATER_DIR"
verify_root_directory_chain "$(dirname -- "$PYTHON")"
resolved_python="$(readlink -f -- "$PYTHON")"
[[ "$resolved_python" =~ ^/usr/bin/python3(\.[0-9]+)?$ ]] \
  || die "virtualenv Python resolves outside the trusted system interpreter path"
verify_root_directory_chain "$(dirname -- "$resolved_python")"
verify_trusted_file "$resolved_python"
verify_trusted_file "$UPDATER_DIR/release_updater.py"
verify_trusted_file "$UPDATER_DIR/release_guard.py"
verify_trusted_file "$UPDATER_DIR/oss_io.py"
verify_trusted_file "$UPDATER_DIR/wheelhouse_supply_chain.py"
verify_trusted_file "$UPDATER_DIR/requirements.lock"

# The verifier runs under the system interpreter before any code is imported
# from the credential-bearing updater venv.  This also protects manual starts
# that do not pass through the systemd ExecStartPre chain.
/usr/bin/python3 -I "$UPDATER_DIR/wheelhouse_supply_chain.py" \
  verify-installed \
  --lock "$UPDATER_DIR/requirements.lock" \
  --venv "$UPDATER_DIR/venv"

exec "$PYTHON" "$UPDATER_DIR/release_updater.py" stage
