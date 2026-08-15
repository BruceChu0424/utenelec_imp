#!/usr/bin/env bash
# Atomically promote the reviewed Phase 3 pending environment into the fixed
# application runtime path. It never prints, sources, or replaces secret data.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE

die() {
  printf 'SERVER_ENV_INSTALL_REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash install-server-env.sh \
    --confirm 'INSTALL VALIDATED UTEN SERVER ENV'

For an existing legacy live file prepared by Phase 3 maintenance mode:

  sudo bash install-server-env.sh \
    --replace-existing \
    --expected-current-sha256 64_LOWERCASE_HEX \
    --approval-reference CHG-20260811-SERVER-ENV \
    --confirm-replace 'REPLACE LEGACY UTEN SERVER ENV' \
    --confirm 'INSTALL VALIDATED UTEN SERVER ENV'

Contract:
  * /etc/uten-imp/server.env.pending must be root:root 0600, canonical,
    single-linked, and pass the reviewed Phase 3 validator.
  * An existing live server.env is never replaced by default. The legacy mode
    requires its independently reviewed SHA-256 and a non-secret approval ID,
    and retains the old bytes under a root-only evidence directory.
  * Secret values are never sourced, printed, or accepted on the command line.
EOF
}

readonly CONFIRMATION='INSTALL VALIDATED UTEN SERVER ENV'
readonly REPLACE_CONFIRMATION='REPLACE LEGACY UTEN SERVER ENV'
confirmation=''
replace_existing=false
expected_current_sha256=''
approval_reference=''
replace_confirmation=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --replace-existing)
      replace_existing=true
      shift
      ;;
    --expected-current-sha256)
      [[ "$#" -ge 2 ]] || die 'missing value for --expected-current-sha256'
      expected_current_sha256="$2"
      shift 2
      ;;
    --approval-reference)
      [[ "$#" -ge 2 ]] || die 'missing value for --approval-reference'
      approval_reference="$2"
      shift 2
      ;;
    --confirm-replace)
      [[ "$#" -ge 2 ]] || die 'missing value for --confirm-replace'
      replace_confirmation="$2"
      shift 2
      ;;
    --confirm)
      [[ "$#" -ge 2 ]] || die 'missing value for --confirm'
      confirmation="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ "$confirmation" == "$CONFIRMATION" ]] \
  || die "exact confirmation is required: --confirm '$CONFIRMATION'"
if [[ "$replace_existing" == true ]]; then
  [[ "$expected_current_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || die '--replace-existing requires a 64-character lowercase --expected-current-sha256'
  [[ "$approval_reference" =~ ^(CHG|CAB|SEC)-[A-Za-z0-9][A-Za-z0-9._-]{2,95}$ ]] \
    || die '--replace-existing requires a non-secret CHG-, CAB-, or SEC- approval reference'
  [[ "$replace_confirmation" == "$REPLACE_CONFIRMATION" ]] \
    || die "--replace-existing requires --confirm-replace '$REPLACE_CONFIRMATION'"
elif [[ -n "$expected_current_sha256" || -n "$approval_reference" || -n "$replace_confirmation" ]]; then
  die 'replacement evidence options are valid only with --replace-existing'
fi
[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute through a symlink'

readonly SCRIPT_FILE="$(realpath -e -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_FILE")" && pwd -P)"
readonly VALIDATOR_SOURCE="$SCRIPT_DIR/validate-server-env.sh"
readonly INSTALLED_VALIDATOR=/usr/local/sbin/uten-imp-validate-server-env
readonly ENV_DIR=/etc/uten-imp
readonly PENDING_ENV="$ENV_DIR/server.env.pending"
readonly LIVE_ENV="$ENV_DIR/server.env"
readonly INSTALLING_ENV="$ENV_DIR/.server.env.installing"
readonly EVIDENCE_ROOT=/var/lib/uten-imp-runtime-evidence

require_root_directory_chain() {
  local current="$1" mode
  current="$(realpath -e -- "$current")"
  while :; do
    [[ -d "$current" && ! -L "$current" ]] \
      || die "trusted directory is not real: $current"
    [[ "$(stat -c '%U' -- "$current")" == root ]] \
      || die "trusted directory is not root-owned: $current"
    mode="$(stat -c '%a' -- "$current")"
    (( (8#$mode & 0022) == 0 )) \
      || die "trusted directory is group/world-writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

require_root_source_file() {
  local source_file="$1" mode
  [[ -f "$source_file" && ! -L "$source_file" ]] \
    || die "trusted source is not a regular file: $source_file"
  [[ "$(realpath -e -- "$source_file")" == "$source_file" ]] \
    || die "trusted source path is not canonical: $source_file"
  [[ "$(stat -c '%U:%h' -- "$source_file")" == root:1 ]] \
    || die "trusted source must be root-owned with one hard link: $source_file"
  mode="$(stat -c '%a' -- "$source_file")"
  (( (8#$mode & 0022) == 0 )) \
    || die "trusted source is group/world-writable: $source_file"
  require_root_directory_chain "$(dirname -- "$source_file")"
}

require_pending_file() {
  [[ -f "$PENDING_ENV" && ! -L "$PENDING_ENV" ]] \
    || die "$PENDING_ENV must be a regular, non-symlink file"
  [[ "$(realpath -e -- "$PENDING_ENV")" == "$PENDING_ENV" ]] \
    || die "$PENDING_ENV path is not canonical"
  [[ "$(stat -c '%U:%G:%a:%h' -- "$PENDING_ENV")" == root:root:600:1 ]] \
    || die "$PENDING_ENV must be root:root mode 0600 with one hard link"
}

require_install_file() {
  local install_file="$1"
  [[ -f "$install_file" && ! -L "$install_file" ]] \
    || die "runtime environment is not a regular, non-symlink file: $install_file"
  [[ "$(stat -c '%U:%G:%a:%h' -- "$install_file")" == root:uten-imp:640:1 ]] \
    || die "runtime environment must be root:uten-imp mode 0640 with one hard link: $install_file"
}

fsync_directory() {
  /usr/bin/python3 -I - "$1" <<'PY'
import os
import sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

require_control_file() {
  local control_file="$1" label="$2"
  [[ -f "$control_file" && ! -L "$control_file" ]] \
    || die "$label is not a regular, non-symlink file"
  [[ "$(stat -c '%U:%G:%a:%h' -- "$control_file")" == root:root:600:1 ]] \
    || die "$label must be root:root mode 0600 with one hard link"
  (( $(stat -c '%s' -- "$control_file") > 0 )) || die "$label is empty"
}

atomic_write_control() {
  local control_dir="$1" destination="$2" content="$3" temporary
  [[ ! -e "$destination" && ! -L "$destination" ]] \
    || die "control destination already exists: $destination"
  temporary="$(mktemp "$control_dir/.control.XXXXXX")"
  printf '%s\n' "$content" >"$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  sync -f "$temporary"
  mv -T -- "$temporary" "$destination"
  fsync_directory "$control_dir"
}

for command_name in awk cmp date dirname find flock grep install mktemp mv python3 \
  realpath rm sha256sum stat sync; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "required command is missing: $command_name"
done
require_root_source_file "$SCRIPT_FILE"
require_root_source_file "$VALIDATOR_SOURCE"
require_root_source_file "$INSTALLED_VALIDATOR"
cmp -s -- "$VALIDATOR_SOURCE" "$INSTALLED_VALIDATOR" \
  || die 'installed environment validator differs from the reviewed Phase 3 source'
[[ -x "$INSTALLED_VALIDATOR" ]] || die 'installed environment validator is not executable'
[[ -d "$ENV_DIR" && ! -L "$ENV_DIR" ]] || die "$ENV_DIR must be a real directory"
[[ "$(stat -c '%U:%G:%a' -- "$ENV_DIR")" == root:uten-imp:750 ]] \
  || die "$ENV_DIR must be root:uten-imp mode 0750"
require_root_directory_chain "$ENV_DIR"

readonly INSTALL_LOCK=/run/uten-imp-server-env-install.lock
if [[ ! -e "$INSTALL_LOCK" && ! -L "$INSTALL_LOCK" ]]; then
  install -m 0600 -o root -g root /dev/null "$INSTALL_LOCK"
  sync -f /run
fi
[[ -f "$INSTALL_LOCK" && ! -L "$INSTALL_LOCK" ]] \
  || die 'server environment install lock is not a regular file'
[[ "$(stat -c '%U:%G:%a:%h' -- "$INSTALL_LOCK")" == root:root:600:1 ]] \
  || die 'server environment install lock must be root:root mode 0600 with one hard link'
exec 9<>"$INSTALL_LOCK"
flock -n 9 || die 'another server environment installation is running'

if find "$ENV_DIR" -mindepth 1 -maxdepth 1 -name '.server.env.build.*' -print -quit | grep -q .; then
  die 'a prior transient server.env build remains; preserve and audit it before retrying'
fi

require_pending_file
"$INSTALLED_VALIDATOR" "$PENDING_ENV"
pending_sha256="$(sha256sum -- "$PENDING_ENV" | awk 'NR == 1 {print $1}')"

prepare_installing_env() {
  if [[ -e "$INSTALLING_ENV" || -L "$INSTALLING_ENV" ]]; then
    require_install_file "$INSTALLING_ENV"
    "$INSTALLED_VALIDATOR" "$INSTALLING_ENV"
    cmp -s -- "$PENDING_ENV" "$INSTALLING_ENV" \
      || die 'interrupted installing file differs from the reviewed pending environment'
    return
  fi

  temporary="$(mktemp "$ENV_DIR/.server.env.build.XXXXXX")"
  cleanup_temporary() {
    local status="$?"
    trap - EXIT
    if [[ -n "${temporary:-}" && "$temporary" == "$ENV_DIR"/.server.env.build.* \
      && -f "$temporary" && ! -L "$temporary" ]]; then
      rm -f -- "$temporary" || true
    fi
    exit "$status"
  }
  trap cleanup_temporary EXIT
  install -m 0640 -o root -g uten-imp -- "$PENDING_ENV" "$temporary"
  require_install_file "$temporary"
  "$INSTALLED_VALIDATOR" "$temporary"
  cmp -s -- "$PENDING_ENV" "$temporary" \
    || die 'validated temporary environment differs from pending input'
  sync -f "$temporary"
  mv -T -- "$temporary" "$INSTALLING_ENV"
  temporary=''
  trap - EXIT
  fsync_directory "$ENV_DIR"
}

if [[ -e "$LIVE_ENV" || -L "$LIVE_ENV" ]]; then
  [[ -f "$LIVE_ENV" && ! -L "$LIVE_ENV" ]] \
    || die 'existing live server.env must be a regular, non-symlink file'
  live_metadata="$(stat -c '%U:%G:%a:%h' -- "$LIVE_ENV")"
  [[ "$live_metadata" == root:root:600:1 || "$live_metadata" == root:uten-imp:640:1 ]] \
    || die 'existing live server.env must be root:root 0600 or root:uten-imp 0640 with one hard link'
  current_sha256="$(sha256sum -- "$LIVE_ENV" | awk 'NR == 1 {print $1}')"

  if [[ "$replace_existing" != true ]]; then
    require_install_file "$LIVE_ENV"
    "$INSTALLED_VALIDATOR" "$LIVE_ENV"
    cmp -s -- "$PENDING_ENV" "$LIVE_ENV" \
      || die 'live and pending server environments differ; replacement is forbidden without the explicit legacy contract'
    [[ ! -e "$INSTALLING_ENV" && ! -L "$INSTALLING_ENV" ]] \
      || die 'an unexpected installing environment remains beside an existing live file'
    rm -f -- "$PENDING_ENV"
    fsync_directory "$ENV_DIR"
    printf '%s\n' 'SERVER_ENV_INSTALL_RECOVERED: live file validated; duplicate pending secret removed.'
    exit 0
  fi

  [[ "$current_sha256" == "$expected_current_sha256" || "$current_sha256" == "$pending_sha256" ]] \
    || die 'live server.env matches neither the independently reviewed old SHA-256 nor the reviewed pending file'
  if [[ -e "$EVIDENCE_ROOT" || -L "$EVIDENCE_ROOT" ]]; then
    [[ -d "$EVIDENCE_ROOT" && ! -L "$EVIDENCE_ROOT" ]] \
      || die "$EVIDENCE_ROOT must be a real directory"
    [[ "$(stat -c '%U:%G:%a' -- "$EVIDENCE_ROOT")" == root:root:700 ]] \
      || die "$EVIDENCE_ROOT must be root:root mode 0700"
  else
    require_root_directory_chain /var/lib
    install -d -m 0700 -o root -g root "$EVIDENCE_ROOT"
    fsync_directory /var/lib
  fi
  require_root_directory_chain "$EVIDENCE_ROOT"
  transaction_hash="$(printf '%s' "$approval_reference" | sha256sum | awk '{print $1}')"
  transaction_dir="$EVIDENCE_ROOT/server-env-$transaction_hash"
  if [[ -e "$transaction_dir" || -L "$transaction_dir" ]]; then
    [[ -d "$transaction_dir" && ! -L "$transaction_dir" ]] \
      || die 'server environment evidence transaction is not a real directory'
    [[ "$(stat -c '%U:%G:%a' -- "$transaction_dir")" == root:root:700 ]] \
      || die 'server environment evidence transaction must be root:root mode 0700'
  else
    install -d -m 0700 -o root -g root "$transaction_dir"
    fsync_directory "$EVIDENCE_ROOT"
  fi
  require_root_directory_chain "$transaction_dir"
  evidence_backup="$transaction_dir/server.env.pre-migration"
  in_progress="$transaction_dir/in-progress.state"
  closed_progress="$transaction_dir/in-progress.closed.state"
  complete="$transaction_dir/complete.state"
  state_payload="$(printf '%s\n' \
    'format=uten-imp-server-env-migration-v1' \
    "approval_reference=$approval_reference" \
    "old_sha256=$expected_current_sha256" \
    "new_sha256=$pending_sha256")"

  if [[ -e "$complete" || -L "$complete" ]]; then
    require_control_file "$complete" 'server environment completion evidence'
    [[ "$(<"$complete")" == "$state_payload" ]] \
      || die 'server environment completion evidence differs from this request'
    require_install_file "$LIVE_ENV"
    "$INSTALLED_VALIDATOR" "$LIVE_ENV"
    [[ "$(sha256sum -- "$LIVE_ENV" | awk 'NR == 1 {print $1}')" == "$pending_sha256" ]] \
      || die 'completed server environment evidence does not match the live file'
    if [[ -e "$in_progress" || -L "$in_progress" ]]; then
      require_control_file "$in_progress" 'server environment in-progress evidence'
      [[ "$(<"$in_progress")" == "$state_payload" ]] \
        || die 'server environment in-progress evidence differs from completion evidence'
      [[ ! -e "$closed_progress" && ! -L "$closed_progress" ]] \
        || die 'both open and closed server environment progress evidence exist'
      mv -T -- "$in_progress" "$closed_progress"
      fsync_directory "$transaction_dir"
    fi
    rm -f -- "$PENDING_ENV"
    fsync_directory "$ENV_DIR"
    printf 'SERVER_ENV_REPLACEMENT_ALREADY_COMPLETE: approval=%s evidence=%s\n' \
      "$approval_reference" "$transaction_dir"
    exit 0
  fi

  if [[ -e "$closed_progress" || -L "$closed_progress" ]]; then
    die 'closed server environment progress evidence exists without completion evidence'
  fi
  if [[ -e "$in_progress" || -L "$in_progress" ]]; then
    require_control_file "$in_progress" 'server environment in-progress evidence'
    [[ "$(<"$in_progress")" == "$state_payload" ]] \
      || die 'server environment in-progress evidence differs from this request'
  else
    atomic_write_control "$transaction_dir" "$in_progress" "$state_payload"
  fi

  if [[ -e "$evidence_backup" || -L "$evidence_backup" ]]; then
    [[ -f "$evidence_backup" && ! -L "$evidence_backup" ]] \
      || die 'legacy server environment evidence is not a regular file'
    [[ "$(stat -c '%U:%G:%a:%h' -- "$evidence_backup")" == root:root:600:1 ]] \
      || die 'legacy server environment evidence must be root:root mode 0600 with one hard link'
    [[ "$(sha256sum -- "$evidence_backup" | awk 'NR == 1 {print $1}')" == "$expected_current_sha256" ]] \
      || die 'legacy server environment evidence SHA-256 differs from the approved old file'
  else
    [[ "$current_sha256" == "$expected_current_sha256" ]] \
      || die 'live file was already replaced but the required old secret evidence is absent'
    backup_temp="$(mktemp "$transaction_dir/.server.env.pre-migration.XXXXXX")"
    install -m 0600 -o root -g root -- "$LIVE_ENV" "$backup_temp"
    [[ "$(sha256sum -- "$backup_temp" | awk 'NR == 1 {print $1}')" == "$expected_current_sha256" ]] \
      || die 'legacy server environment evidence copy differs from the approved old file'
    sync -f "$backup_temp"
    mv -T -- "$backup_temp" "$evidence_backup"
    fsync_directory "$transaction_dir"
  fi

  if [[ "$current_sha256" == "$expected_current_sha256" ]]; then
    prepare_installing_env
    mv -fT -- "$INSTALLING_ENV" "$LIVE_ENV"
    fsync_directory "$ENV_DIR"
  else
    [[ ! -e "$INSTALLING_ENV" && ! -L "$INSTALLING_ENV" ]] \
      || die 'live file is already replaced but an unexpected installing file also exists'
  fi
  require_install_file "$LIVE_ENV"
  "$INSTALLED_VALIDATOR" "$LIVE_ENV"
  cmp -s -- "$PENDING_ENV" "$LIVE_ENV" \
    || die 'replacement live environment differs from the reviewed pending input'
  atomic_write_control "$transaction_dir" "$complete" "$state_payload"
  mv -T -- "$in_progress" "$closed_progress"
  fsync_directory "$transaction_dir"
  rm -f -- "$PENDING_ENV"
  fsync_directory "$ENV_DIR"
  printf 'SERVER_ENV_REPLACEMENT_OK: approval=%s evidence=%s secret_values_not_logged=true\n' \
    "$approval_reference" "$transaction_dir"
  exit 0
fi

[[ "$replace_existing" != true ]] \
  || die '--replace-existing requires the independently reviewed legacy live server.env to exist'
prepare_installing_env
mv -T -- "$INSTALLING_ENV" "$LIVE_ENV"
fsync_directory "$ENV_DIR"
require_install_file "$LIVE_ENV"
"$INSTALLED_VALIDATOR" "$LIVE_ENV"
cmp -s -- "$PENDING_ENV" "$LIVE_ENV" \
  || die 'installed live environment differs from the reviewed pending input'
rm -f -- "$PENDING_ENV"
fsync_directory "$ENV_DIR"

printf '%s\n' \
  'SERVER_ENV_INSTALL_OK' \
  'The live environment was validated before and after an fsynced same-directory atomic rename.' \
  'The duplicate pending secret was removed only after the live file passed validation.'
