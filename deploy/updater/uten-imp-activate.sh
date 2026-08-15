#!/usr/bin/env bash
# Explicit root-only activation entrypoint. Never execute a command or script from a release payload.
set -euo pipefail
umask 027
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly UPDATER_DIR=/opt/uten-imp/updater
readonly PYTHON=/usr/bin/python3

# Never allow sudo SETENV, a saved shell environment, or the downloader credential
# file to redirect a privileged activation to different code, state, keys, or /opt tree.
unset UTEN_UPDATER_HOME UTEN_UPDATER_STATE_DIR UTEN_RELEASE_ALLOWED_SIGNERS
unset UTEN_RELEASE_LOCK_FILE UTEN_RELEASE_BASE UTEN_RELEASE_ROOT_STATE_DIR
unset PYTHONPATH PYTHONHOME

die() {
  printf 'uten-imp-activate: %s\n' "$*" >&2
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

[[ "$(id -u)" == "0" ]] || die "activation must be invoked explicitly as root"
[[ -x "$PYTHON" ]] || die "trusted system Python is missing"
verify_root_directory_chain "$UPDATER_DIR"
verify_root_directory_chain "$(dirname -- "$PYTHON")"
resolved_python="$(readlink -f -- "$PYTHON")"
[[ "$resolved_python" =~ ^/usr/bin/python3(\.[0-9]+)?$ ]] \
  || die "system Python resolves outside the trusted interpreter path"
verify_trusted_file "$resolved_python"
verify_trusted_file "$UPDATER_DIR/release_updater.py"
verify_trusted_file "$UPDATER_DIR/release_guard.py"

exec "$PYTHON" -I "$UPDATER_DIR/release_updater.py" activate "$@"
