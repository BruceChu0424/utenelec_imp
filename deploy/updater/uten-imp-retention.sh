#!/usr/bin/env bash
# Fixed-path root entrypoint for release retention audit/prune/alert operations.
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly UPDATER_DIR=/opt/uten-imp/updater
readonly PYTHON=/usr/bin/python3

unset UTEN_UPDATER_HOME UTEN_UPDATER_STATE_DIR UTEN_RELEASE_ALLOWED_SIGNERS
unset UTEN_RELEASE_LOCK_FILE UTEN_RELEASE_BASE UTEN_RELEASE_ROOT_STATE_DIR
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE

die() {
  printf 'uten-imp-retention: %s\n' "$*" >&2
  exit 1
}

verify_root_chain() {
  local path="$1" mode
  while [[ "$path" != / ]]; do
    [[ -d "$path" && ! -L "$path" ]] || die "trusted directory is missing or a symlink: $path"
    [[ "$(stat -c '%u' -- "$path")" == 0 ]] || die "trusted directory is not root-owned: $path"
    mode="$(stat -c '%a' -- "$path")"
    (( (8#$mode & 022) == 0 )) || die "trusted directory is group/world-writable: $path"
    path="$(dirname -- "$path")"
  done
}

verify_file() {
  local path="$1" mode
  [[ -f "$path" && ! -L "$path" ]] || die "trusted file is missing or a symlink: $path"
  [[ "$(stat -c '%u:%h' -- "$path")" == 0:1 ]] || die "trusted file must be root-owned with one link: $path"
  mode="$(stat -c '%a' -- "$path")"
  (( (8#$mode & 022) == 0 )) || die "trusted file is group/world-writable: $path"
}

[[ "$(id -u)" == 0 ]] || die 'retention operations must be invoked explicitly as root'
verify_root_chain "$UPDATER_DIR"
resolved_python="$(readlink -f -- "$PYTHON")"
[[ "$resolved_python" =~ ^/usr/bin/python3(\.[0-9]+)?$ ]] \
  || die 'system Python resolves outside the fixed trusted path'
verify_file "$resolved_python"
verify_file "$UPDATER_DIR/retention_launcher.py"
verify_file "$UPDATER_DIR/retention_manager.py"
verify_file "$UPDATER_DIR/release_updater.py"
verify_file "$UPDATER_DIR/release_guard.py"

exec "$PYTHON" -I -B "$UPDATER_DIR/retention_launcher.py" "$@"
