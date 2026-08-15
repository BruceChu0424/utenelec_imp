#!/usr/bin/env bash
# Uten IMP Phase 3: Java/Nginx runtime, fail-closed production env, and systemd.
# This script installs units and audited watchdog copies; it never starts the app.
set -Eeuo pipefail
umask 0077
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo bash phase3-runtime.sh [options]

  (no options)                  Fresh runtime bootstrap only. Refuses any
                                existing Uten runtime or active/enabled Nginx.
  --maintenance-reinstall      Reinstall audited runtime files during an
                                already approved maintenance window.
  --confirm-maintenance TEXT   Must exactly equal:
                                MAINTENANCE WINDOW: REINSTALL UTEN RUNTIME
  --expected-data-source DEV  Legacy schema-v2 rollback only: exact software
                               RAID device, for example /dev/md/uten-data.
  --expected-data-uuid UUID   Exact lowercase filesystem UUID proven out of band.
  --expected-data-fstype FS   Exact reviewed filesystem type: ext4 or xfs.
  --storage-approval-reference ID
                              Non-secret change/commissioning approval ID.
  --confirm-storage-authority TEXT
                              With no authority file, must exactly bind mode,
                              identity and approval as printed by preflight.
  --help

Maintenance mode never creates a downtime window. Nginx, the migration job, the
application, and both watchdogs/timers must already be stopped and not enabled
before this script will make any package, Nginx, or systemd change.
EOF
}

readonly MAINTENANCE_CONFIRMATION='MAINTENANCE WINDOW: REINSTALL UTEN RUNTIME'
install_mode=initial
maintenance_confirmation=''
expected_data_source=''
expected_data_uuid=''
expected_data_fstype=''
storage_approval_reference=''
storage_authority_confirmation=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --maintenance-reinstall)
      [[ "$install_mode" == initial ]] || die '--maintenance-reinstall was specified more than once'
      install_mode=maintenance
      shift
      ;;
    --confirm-maintenance)
      [[ "$#" -ge 2 ]] || die 'missing value for --confirm-maintenance'
      [[ -z "$maintenance_confirmation" ]] || die '--confirm-maintenance was specified more than once'
      maintenance_confirmation="$2"
      shift 2
      ;;
    --expected-data-source)
      [[ "$#" -ge 2 ]] || die 'missing value for --expected-data-source'
      [[ -z "$expected_data_source" ]] || die '--expected-data-source was specified more than once'
      expected_data_source="$2"
      shift 2
      ;;
    --expected-data-uuid)
      [[ "$#" -ge 2 ]] || die 'missing value for --expected-data-uuid'
      [[ -z "$expected_data_uuid" ]] || die '--expected-data-uuid was specified more than once'
      expected_data_uuid="${2,,}"
      shift 2
      ;;
    --expected-data-fstype)
      [[ "$#" -ge 2 ]] || die 'missing value for --expected-data-fstype'
      [[ -z "$expected_data_fstype" ]] || die '--expected-data-fstype was specified more than once'
      expected_data_fstype="$2"
      shift 2
      ;;
    --storage-approval-reference)
      [[ "$#" -ge 2 ]] || die 'missing value for --storage-approval-reference'
      [[ -z "$storage_approval_reference" ]] \
        || die '--storage-approval-reference was specified more than once'
      storage_approval_reference="$2"
      shift 2
      ;;
    --confirm-storage-authority)
      [[ "$#" -ge 2 ]] || die 'missing value for --confirm-storage-authority'
      [[ -z "$storage_authority_confirmation" ]] \
        || die '--confirm-storage-authority was specified more than once'
      storage_authority_confirmation="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root (sudo bash phase3-runtime.sh)'
[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to run phase3 through a symlink'
readonly SCRIPT_FILE="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_FILE")" && pwd -P)"
readonly DEPLOY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly ENV_FILE=/etc/uten-imp/server.env
readonly PENDING_ENV=/etc/uten-imp/server.env.pending
readonly MIGRATOR_ENV_DIR=/etc/uten-imp-migrator
readonly MIGRATOR_ENV_FILE=/etc/uten-imp-migrator/migrator.env
readonly MIGRATOR_USER=uten-imp-migrate
readonly MIGRATOR_GROUP=uten-imp-migrate
readonly POSTGRES_SECRETS=/etc/uten-imp-postgres
readonly LEGACY_POSTGRES_SECRETS=/etc/uten-imp/postgres-secrets
readonly LIBEXEC_DIR=/usr/local/libexec/uten-imp
readonly RELEASE_LIBEXEC_DIR=/usr/local/libexec/uten-imp-release
readonly STORAGE_AUTHORITY=/etc/uten-imp/storage-authority.json
readonly STORAGE_BOOT_VERIFIER="$RELEASE_LIBEXEC_DIR/storage_boot_verifier.py"
readonly STORAGE_MOUNT_OBSERVER="$RELEASE_LIBEXEC_DIR/storage_mount_observer.py"
readonly MIGRATION_AUTHORIZATION_HELPER="$RELEASE_LIBEXEC_DIR/migration_authorization.py"
readonly RECOVERY_COMMIT_BOOT_VERIFIER="$RELEASE_LIBEXEC_DIR/recovery_commit_boot_verifier.py"
readonly RECOVERY_INGRESS_GATE="$RELEASE_LIBEXEC_DIR/recovery_ingress_gate.py"
readonly RECOVERY_COMMIT_BOOT_UNIT=/etc/systemd/system/uten-imp-recovery-commit-verifier.service
readonly MIGRATION_AUTHORIZATION_HELPER_SHA256='7eafd7e5111d1fceef5ade7ae2bdc63e3b96b44423f4ecf14924571308b02bfe'
readonly STORAGE_OBSERVER_UNIT_TEMPLATE="$DEPLOY_ROOT/systemd/uten-imp-storage-observer.service.example"
readonly STORAGE_OBSERVER_UNIT=/etc/systemd/system/uten-imp-storage-observer.service
readonly POSTGRES_STORAGE_DROPIN_DIR=/etc/systemd/system/postgresql@16-main.service.d
readonly POSTGRES_STORAGE_DROPIN="$POSTGRES_STORAGE_DROPIN_DIR/uten-imp-storage.conf"
readonly POSTGRES_START_CONF=/etc/postgresql/16/main/start.conf
readonly POSTGRES_META_UNIT=postgresql.service
readonly POSTGRES_INSTANCE_UNIT=postgresql@16-main.service
readonly POSTGRES_GENERATOR_ROOT=/run/systemd/generator
readonly POSTGRES_GENERATOR_WANTS=$POSTGRES_GENERATOR_ROOT/postgresql.service.wants
readonly POSTGRES_GENERATOR_LINK=$POSTGRES_GENERATOR_WANTS/$POSTGRES_INSTANCE_UNIT
readonly COMMISSIONING_DIR=/var/lib/uten-imp-commissioning
readonly DATABASE_BOOT_IN_PROGRESS=$COMMISSIONING_DIR/phase3-database-boot-enablement.state

require_root_directory_chain() {
  local current="$1" mode
  current="$(readlink -f -- "$current")"
  while :; do
    [[ -d "$current" && ! -L "$current" ]] || die "unsafe deployment source directory: $current"
    [[ "$(stat -c '%U' -- "$current")" == root ]] \
      || die "deployment source directory is not root-owned: $current"
    mode="$(stat -c '%a' -- "$current")"
    (( (8#$mode & 0022) == 0 )) \
      || die "deployment source directory is group- or other-writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

require_root_source_file() {
  local source_file="$1" mode
  [[ -f "$source_file" && ! -L "$source_file" ]] \
    || die "deployment bundle source must be a regular, non-symlink file: $source_file"
  [[ "$(stat -c '%U:%h' -- "$source_file")" == root:1 ]] \
    || die "deployment bundle source must be root-owned with one hard link: $source_file"
  mode="$(stat -c '%a' -- "$source_file")"
  (( (8#$mode & 0022) == 0 )) \
    || die "deployment bundle source is group- or other-writable: $source_file"
  require_root_directory_chain "$(dirname -- "$source_file")"
}

atomic_install_root_file() {
  local source_file="$1" target_file="$2" mode="$3" group_name="$4"
  local target_parent temporary_file
  target_parent="$(dirname -- "$target_file")"
  temporary_file="$(mktemp "$target_parent/.${target_file##*/}.install.XXXXXX")"
  if ! install -m "$mode" -o root -g "$group_name" "$source_file" "$temporary_file"; then
    rm -f -- "$temporary_file"
    die "failed to prepare atomic root file: $target_file"
  fi
  sync -f "$temporary_file" || die "failed to fsync prepared root file: $target_file"
  mv -fT -- "$temporary_file" "$target_file"
  sync -f "$target_parent" || die "failed to fsync installed root file parent: $target_parent"
}

verify_postgres_start_conf_auto() {
  [[ -f "$POSTGRES_START_CONF" && ! -L "$POSTGRES_START_CONF" ]] \
    || die 'PostgreSQL start.conf must be a regular, non-symlink file'
  [[ "$(stat -c '%U:%G:%a:%h' -- "$POSTGRES_START_CONF")" == root:root:644:1 ]] \
    || die 'PostgreSQL start.conf must be root:root 0644 with one hard link'
  cmp -s -- "$POSTGRES_START_CONF" <(printf 'auto\n') \
    || die 'PostgreSQL start.conf must contain exactly auto and one newline'
}

verify_database_boot_contract() {
  local unit='' wants='' directory='' mode='' fragment=''
  verify_postgres_start_conf_auto
  for unit in "$POSTGRES_META_UNIT" "$POSTGRES_INSTANCE_UNIT"; do
    [[ "$(systemctl show --property=LoadState --value "$unit")" == loaded ]] \
      || die "database boot unit is not loaded: $unit"
    [[ "$(systemctl show --property=UnitFileState --value "$unit")" == enabled ]] \
      || die "database boot unit is not persistently enabled: $unit"
    [[ "$(systemctl show --property=ActiveState --value "$unit")" == active ]] \
      || die "database boot unit is not active: $unit"
  done
  wants=" $(systemctl show --property=Wants --value "$POSTGRES_META_UNIT") "
  [[ "$wants" == *" $POSTGRES_INSTANCE_UNIT "* ]] \
    || die 'postgresql.service does not want the 16/main instance from the generator'
  for directory in "$POSTGRES_GENERATOR_ROOT" "$POSTGRES_GENERATOR_WANTS"; do
    [[ -d "$directory" && ! -L "$directory" ]] \
      || die "PostgreSQL generator directory is missing or symlinked: $directory"
    [[ "$(stat -c '%U' -- "$directory")" == root ]] \
      || die "PostgreSQL generator directory is not root-owned: $directory"
    mode="$(stat -c '%a' -- "$directory")"
    (( (8#$mode & 0022) == 0 )) \
      || die "PostgreSQL generator directory is group- or other-writable: $directory"
  done
  [[ -L "$POSTGRES_GENERATOR_LINK" \
    && "$(stat -c '%U' -- "$POSTGRES_GENERATOR_LINK")" == root ]] \
    || die 'PostgreSQL generator instance dependency is not one root-owned symlink'
  fragment="$(systemctl show --property=FragmentPath --value "$POSTGRES_INSTANCE_UNIT")"
  [[ -n "$fragment" && -f "$fragment" ]] \
    || die 'PostgreSQL instance has no loaded fragment path'
  [[ "$(readlink -f -- "$POSTGRES_GENERATOR_LINK")" == "$(readlink -f -- "$fragment")" ]] \
    || die 'PostgreSQL generator dependency targets an unexpected unit fragment'
}

publish_database_boot_marker() {
  local marker_tmp
  install -d -m 0700 -o root -g root "$COMMISSIONING_DIR"
  marker_tmp="$(mktemp "$COMMISSIONING_DIR/.phase3-database-boot.XXXXXX")"
  printf 'kind=uten-imp-phase3-database-boot\nstate=IN_PROGRESS\ncluster=16/main\n' >"$marker_tmp"
  chown root:root "$marker_tmp"
  chmod 0600 "$marker_tmp"
  sync -f "$marker_tmp"
  mv -fT -- "$marker_tmp" "$DATABASE_BOOT_IN_PROGRESS"
  sync -f "$COMMISSIONING_DIR"
}

verify_database_boot_marker() {
  [[ -f "$DATABASE_BOOT_IN_PROGRESS" && ! -L "$DATABASE_BOOT_IN_PROGRESS" ]] \
    || die 'Phase 3 database boot-enablement marker is not a regular file'
  [[ "$(stat -c '%U:%G:%a:%h' -- "$DATABASE_BOOT_IN_PROGRESS")" == root:root:600:1 ]] \
    || die 'Phase 3 database boot-enablement marker metadata is unsafe'
  cmp -s -- "$DATABASE_BOOT_IN_PROGRESS" \
    <(printf 'kind=uten-imp-phase3-database-boot\nstate=IN_PROGRESS\ncluster=16/main\n') \
    || die 'Phase 3 database boot-enablement marker content is invalid'
  require_root_directory_chain "$COMMISSIONING_DIR"
}

require_root_source_file "$SCRIPT_FILE"

database_boot_restore_required=false
if [[ -e "$DATABASE_BOOT_IN_PROGRESS" || -L "$DATABASE_BOOT_IN_PROGRESS" ]]; then
  verify_database_boot_marker
  database_boot_restore_required=true
fi

for protected_path in /etc/uten-imp "$MIGRATOR_ENV_DIR" "$POSTGRES_SECRETS" /data/uten-imp /opt/uten-imp "$LIBEXEC_DIR" /usr/local/sbin; do
  [[ ! -L "$protected_path" ]] || die "protected runtime path must not be a symlink: $protected_path"
done

required_sources=(
  "$SCRIPT_DIR/validate-server-env.sh"
  "$SCRIPT_DIR/validate-migrator-env.sh"
  "$SCRIPT_DIR/harden-existing-postgres-roles.sh"
  "$SCRIPT_DIR/migrate-postgres-secrets-path.sh"
  "$SCRIPT_DIR/server.env.oss-migration.example"
  "$SCRIPT_DIR/wait-for-erp-readiness.sh"
  "$DEPLOY_ROOT/watchdog/uten-imp-watchdog.sh"
  "$DEPLOY_ROOT/watchdog/uten-imp-entry-watchdog.sh"
  "$DEPLOY_ROOT/updater/migration_authorization.py"
  "$DEPLOY_ROOT/updater/recovery_commit_boot_verifier.py"
  "$DEPLOY_ROOT/updater/recovery_ingress_gate.py"
  "$DEPLOY_ROOT/systemd/uten-imp.service.example"
  "$DEPLOY_ROOT/systemd/uten-imp-migrate.service.example"
  "$DEPLOY_ROOT/systemd/nginx-uten-imp-override.conf.example"
  "$DEPLOY_ROOT/systemd/uten-imp-recovery-commit-verifier.service.example"
  "$DEPLOY_ROOT/systemd/uten-imp-watchdog.service.example"
  "$DEPLOY_ROOT/systemd/uten-imp-watchdog.timer.example"
  "$STORAGE_OBSERVER_UNIT_TEMPLATE"
  "$DEPLOY_ROOT/systemd/uten-imp-entry-watchdog.service.example"
  "$DEPLOY_ROOT/systemd/uten-imp-entry-watchdog.timer.example"
  "$DEPLOY_ROOT/systemd/postgresql-uten-imp-storage.conf.example"
  "$DEPLOY_ROOT/updater/storage_boot_verifier.py"
  "$DEPLOY_ROOT/updater/storage_mount_observer.py"
)
for source_file in "${required_sources[@]}"; do
  require_root_source_file "$source_file"
done
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'
[[ "$(sha256sum -- "$DEPLOY_ROOT/updater/migration_authorization.py" \
  | awk 'NR == 1 {print $1}')" == "$MIGRATION_AUTHORIZATION_HELPER_SHA256" ]] \
  || die 'migration authorization helper differs from the fixed Phase 3 digest'

echo '==> Classify the host before any package, Nginx, or systemd change'
command -v systemctl >/dev/null 2>&1 || die 'systemctl is required'
[[ -r /etc/os-release ]] || die '/etc/os-release is required'
os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
[[ "$os_id" == ubuntu && "$os_version" == 24.04 ]] \
  || die 'the audited runtime and restart-backoff contract supports only Ubuntu 24.04'
systemd_version="$(systemctl --version | awk 'NR == 1 && $1 == "systemd" { print $2 }')"
[[ "$systemd_version" =~ ^[0-9]+$ && "$systemd_version" -ge 255 ]] \
  || die 'systemd 255 or newer is required for reviewed RestartSteps/RestartMaxDelaySec semantics'

runtime_markers=()
record_path_marker() {
  local marker_path="$1"
  if [[ -e "$marker_path" || -L "$marker_path" ]]; then
    runtime_markers+=("$marker_path")
  fi
}
for marker_path in \
  "$LEGACY_POSTGRES_SECRETS" \
  /opt/uten-imp/current \
  "$LIBEXEC_DIR" \
  /etc/systemd/system/uten-imp-migrate.service \
  /etc/systemd/system/uten-imp-migrate.service.d \
  /etc/systemd/system/uten-imp.service \
  /etc/systemd/system/uten-imp-watchdog.service \
  /etc/systemd/system/uten-imp-watchdog.timer \
  "$STORAGE_OBSERVER_UNIT" \
  /etc/systemd/system/uten-imp-entry-watchdog.service \
  /etc/systemd/system/uten-imp-entry-watchdog.timer \
  "$DATABASE_BOOT_IN_PROGRESS" \
  /etc/systemd/system/nginx.service.d/uten-imp.conf; do
  record_path_marker "$marker_path"
done
if [[ -d /opt/uten-imp/releases ]] \
  && find /opt/uten-imp/releases -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  runtime_markers+=(/opt/uten-imp/releases/nonempty)
fi
for nginx_site_dir in /etc/nginx/sites-available /etc/nginx/sites-enabled; do
  if [[ -d "$nginx_site_dir" ]]; then
    while IFS= read -r -d '' marker_path; do
      runtime_markers+=("$marker_path")
    done < <(find "$nginx_site_dir" -maxdepth 1 -mindepth 1 -name 'uten-imp*' -print0)
  fi
done

managed_units=(
  nginx.service
  uten-imp-migrate.service
  uten-imp.service
  uten-imp-watchdog.service
  uten-imp-watchdog.timer
  uten-imp-storage-observer.service
  uten-imp-entry-watchdog.service
  uten-imp-entry-watchdog.timer
)
declare -A unit_active_state=()
declare -A unit_enabled_state=()
declare -A unit_is_enabled=()
for managed_unit in "${managed_units[@]}"; do
  unit_active_state["$managed_unit"]="$(systemctl is-active "$managed_unit" 2>/dev/null || true)"
  unit_enabled_state["$managed_unit"]="$(systemctl is-enabled "$managed_unit" 2>/dev/null || true)"
  if systemctl is-enabled --quiet "$managed_unit" 2>/dev/null; then
    unit_is_enabled["$managed_unit"]=true
  else
    unit_is_enabled["$managed_unit"]=false
  fi
done

print_classification() {
  local item
  if (( ${#runtime_markers[@]} > 0 )); then
    printf 'Detected Uten runtime markers:\n' >&2
    for item in "${runtime_markers[@]}"; do
      printf '  - %s\n' "$item" >&2
    done
  fi
  printf 'Detected service states:\n' >&2
  for item in "${managed_units[@]}"; do
    printf '  - %s active=%s enabled=%s\n' \
      "$item" "${unit_active_state[$item]:-unknown}" "${unit_enabled_state[$item]:-unknown}" >&2
  done
}

unit_is_inactive_or_absent() {
  local unit_name="$1"
  case "${unit_active_state[$unit_name]:-unknown}" in
    inactive|unknown) ;;
    *) return 1 ;;
  esac
  [[ "${unit_is_enabled[$unit_name]}" == false ]]
}

if [[ -e "$LEGACY_POSTGRES_SECRETS" || -L "$LEGACY_POSTGRES_SECRETS" ]]; then
  print_classification
  die "legacy PostgreSQL secrets require the separately confirmed $SCRIPT_DIR/migrate-postgres-secrets-path.sh before any runtime installation or maintenance"
fi
[[ ! -e /etc/systemd/system/uten-imp-migrate.service.d \
  && ! -L /etc/systemd/system/uten-imp-migrate.service.d ]] \
  || die 'migration unit drop-ins are forbidden; review and remove the override directory before phase3'
[[ ! -e /etc/systemd/system/uten-imp-storage-observer.service.d \
  && ! -L /etc/systemd/system/uten-imp-storage-observer.service.d ]] \
  || die 'storage observer unit drop-ins are forbidden; review and remove the override directory before phase3'
[[ ! -e /etc/systemd/system/uten-imp-entry-watchdog.service.d \
  && ! -L /etc/systemd/system/uten-imp-entry-watchdog.service.d ]] \
  || die 'entry watchdog unit drop-ins are forbidden; review and remove the override directory before phase3'
if [[ -e "$POSTGRES_STORAGE_DROPIN_DIR" || -L "$POSTGRES_STORAGE_DROPIN_DIR" ]]; then
  [[ -d "$POSTGRES_STORAGE_DROPIN_DIR" && ! -L "$POSTGRES_STORAGE_DROPIN_DIR" ]] \
    || die 'PostgreSQL drop-in path must be a real directory'
  require_root_directory_chain "$POSTGRES_STORAGE_DROPIN_DIR"
  while IFS= read -r -d '' postgres_dropin; do
    [[ "$postgres_dropin" == "$POSTGRES_STORAGE_DROPIN" ]] \
      || die "unreviewed PostgreSQL drop-in blocks runtime installation: $postgres_dropin"
    require_root_source_file "$postgres_dropin"
    cmp -s -- "$DEPLOY_ROOT/systemd/postgresql-uten-imp-storage.conf.example" "$postgres_dropin" \
      || die 'existing PostgreSQL storage drop-in differs from the reviewed resumable gate'
  done < <(find "$POSTGRES_STORAGE_DROPIN_DIR" -mindepth 1 -maxdepth 1 -print0)
fi

if [[ "$install_mode" == initial ]]; then
  [[ -z "$maintenance_confirmation" ]] \
    || die '--confirm-maintenance is valid only with --maintenance-reinstall'
  if (( ${#runtime_markers[@]} > 0 )); then
    print_classification
    die 'fresh bootstrap refused: existing Uten runtime state requires an explicitly approved maintenance reinstall'
  fi
  if ! unit_is_inactive_or_absent nginx.service; then
    print_classification
    die 'fresh bootstrap refused: Nginx is active or enabled; do not let this script create an outage'
  fi
  for managed_unit in "${managed_units[@]:1}"; do
    if ! unit_is_inactive_or_absent "$managed_unit"; then
      print_classification
      die "fresh bootstrap refused: managed unit has pre-existing state: $managed_unit"
    fi
  done
else
  [[ "$maintenance_confirmation" == "$MAINTENANCE_CONFIRMATION" ]] \
    || die "maintenance reinstall requires --confirm-maintenance '$MAINTENANCE_CONFIRMATION'"
  (( ${#runtime_markers[@]} > 0 )) \
    || die 'maintenance reinstall refused: no existing Uten runtime marker was detected; use fresh bootstrap'
  for managed_unit in "${managed_units[@]}"; do
    if ! unit_is_inactive_or_absent "$managed_unit"; then
      print_classification
      die "maintenance reinstall refused: $managed_unit must already be inactive and not enabled"
    fi
  done
  printf '%s\n' 'MAINTENANCE_WINDOW_CONFIRMED: pre-existing entry/app/watchdog units are inactive and not enabled.'
fi

if [[ "$database_boot_restore_required" == true \
  || ( "$install_mode" == maintenance \
    && ! -e "$STORAGE_AUTHORITY" && ! -L "$STORAGE_AUTHORITY" ) ]]; then
  verify_postgres_start_conf_auto
else
  # A normal install/reinstall must detect database boot drift before apt,
  # storage-authority, environment, or systemd writes begin.
  verify_database_boot_contract
fi

echo '==> Validate the persistent data mount before creating writable paths'
command -v mountpoint >/dev/null 2>&1 || die 'mountpoint is required'
command -v findmnt >/dev/null 2>&1 || die 'findmnt is required'
[[ -d /data ]] || die '/data does not exist'
mountpoint --quiet /data || die '/data must be a real mounted filesystem; refusing to bind runtime ordering to the root filesystem'
data_mount_observation="$(findmnt --noheadings --raw \
  --output TARGET,SOURCE,FSTYPE,OPTIONS,UUID --target /data)" \
  || die 'cannot observe the authoritative /data mount'
[[ "$(wc -l <<<"$data_mount_observation")" == 1 ]] \
  || die '/data mount observation is ambiguous'
read -r data_target data_source data_fstype data_options data_uuid data_extra \
  <<<"$data_mount_observation"
[[ "$data_target" == /data && -z "${data_extra:-}" ]] \
  || die '/data mount observation is malformed'
[[ "$data_fstype" == ext4 || "$data_fstype" == xfs ]] \
  || die '/data must use the reviewed ext4 or XFS filesystem policy'
data_uuid="${data_uuid,,}"
[[ "$data_uuid" =~ ^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{16,64})$ ]] \
  || die '/data has no canonical persistent filesystem UUID'
storage_authority_schema=''
data_observer_device=''
for required_mount_option in rw nodev nosuid noexec; do
  [[ ",$data_options," == *",$required_mount_option,"* ]] \
    || die "/data lacks required mount option: $required_mount_option"
done
if [[ -e "$STORAGE_AUTHORITY" || -L "$STORAGE_AUTHORITY" ]]; then
  [[ -z "$expected_data_source" && -z "$expected_data_uuid" \
    && -z "$expected_data_fstype" && -z "$storage_approval_reference" \
    && -z "$storage_authority_confirmation" ]] \
    || die 'storage commissioning arguments are forbidden when an authority already exists; the existing root-controlled authority must match exactly'
  [[ -f "$STORAGE_AUTHORITY" && ! -L "$STORAGE_AUTHORITY" \
    && "$(stat -c '%U:%G:%a:%h' -- "$STORAGE_AUTHORITY")" == root:root:640:1 ]] \
    || die 'existing storage authority is not a canonical root-controlled file'
  authority_observation="$(/usr/bin/python3 -I - \
    "$DEPLOY_ROOT/updater/storage_boot_verifier.py" \
    "$DEPLOY_ROOT/updater/storage_mount_observer.py" \
    "$STORAGE_AUTHORITY" <<'PY'
import importlib.util
import os
import stat
import sys
from pathlib import Path

source = Path(sys.argv[1])
observer_source = Path(sys.argv[2])
authority_path = Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("uten_imp_storage_boot", source)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load reviewed storage verifier")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
if authority_path != module.STORAGE_AUTHORITY:
    raise SystemExit("storage authority path differs from fixed verifier contract")
authority = module._read_authority()
version = module.validate_authority(authority)
if version == 3:
    module._verify_lvm_nvme_identity(authority)
observer_spec = importlib.util.spec_from_file_location(
    "uten_imp_storage_observer_preflight", observer_source
)
if observer_spec is None or observer_spec.loader is None:
    raise SystemExit("cannot load reviewed storage observer")
observer = importlib.util.module_from_spec(observer_spec)
observer_spec.loader.exec_module(observer)
observer_authority = observer._authority(authority_path.read_bytes())
if observer_authority != authority:
    raise SystemExit("storage verifier and observer parsed different authorities")
fstab_raw = observer._read_regular(
    observer.FSTAB_PATH, exact_mode=None, maximum=observer.MAX_FSTAB_BYTES
)
observer._validate_fstab_and_data_unit(observer_authority, fstab_raw)
resolved = os.path.realpath(authority["dataSource"])
details = os.stat(resolved)
if not stat.S_ISBLK(details.st_mode):
    raise SystemExit("authority source is not a block device")
print(version, authority["dataUuid"], authority["dataFilesystem"], resolved)
PY
  )" || die 'existing storage authority could not prove the live block topology'
  read -r storage_authority_schema authority_uuid authority_fstype authority_resolved authority_extra \
    <<<"$authority_observation"
  [[ -z "${authority_extra:-}" && "$authority_uuid" == "$data_uuid" \
    && "$authority_fstype" == "$data_fstype" ]] \
    || die 'mounted /data UUID/filesystem differs from storage authority'
  [[ "$(stat -c '%t:%T' -- "$data_source")" == "$(stat -c '%t:%T' -- "$authority_resolved")" ]] \
    || die 'mounted /data block identity differs from storage authority'
  if [[ "$storage_authority_schema" == 2 ]]; then
    data_observer_device="$authority_resolved"
    [[ "$data_observer_device" =~ ^/dev/md[0-9]+$ ]] \
      || die 'legacy authority must resolve to one /dev/mdN node'
  else
    [[ "$storage_authority_schema" == 3 && "$authority_resolved" =~ ^/dev/dm-[0-9]+$ ]] \
      || die 'current authority must prove one LVM-on-NVMe device'
  fi
else
  [[ "$expected_data_source" =~ ^/dev/md([0-9]+|/[A-Za-z0-9_.-]+)$ ]] \
    || die 'legacy rollback commissioning requires a canonical --expected-data-source software RAID device; new NVMe hosts require a precommissioned v3 authority'
  [[ "$expected_data_uuid" =~ ^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{16,64})$ ]] \
    || die 'storage commissioning requires a canonical --expected-data-uuid'
  [[ "$expected_data_fstype" == ext4 || "$expected_data_fstype" == xfs ]] \
    || die 'storage commissioning requires --expected-data-fstype ext4 or xfs'
  [[ "$storage_approval_reference" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$ ]] \
    || die 'storage authority creation requires a canonical non-secret --storage-approval-reference'
  [[ "$data_source" == "$expected_data_source" \
    && "$data_uuid" == "$expected_data_uuid" \
    && "$data_fstype" == "$expected_data_fstype" ]] \
    || die 'observed /data identity differs from the independently approved commissioning identity'
  storage_authority_schema=2
  data_observer_device="$(readlink -f -- "$data_source")" \
    || die 'cannot resolve the legacy commissioned md source'
  [[ "$data_observer_device" =~ ^/dev/md[0-9]+$ && -b "$data_observer_device" ]] \
    || die 'legacy commissioned md source must resolve to /dev/mdN'
  storage_commissioning_mode=INITIAL
  if [[ "$install_mode" == maintenance ]]; then
    storage_commissioning_mode=EXISTING
    for postgres_unit in postgresql.service postgresql@16-main.service; do
      [[ "$(systemctl show --property=LoadState --value "$postgres_unit" 2>/dev/null)" == loaded ]] \
        || die "existing-host storage commissioning requires a loaded unit: $postgres_unit"
      [[ "$(systemctl is-active "$postgres_unit" 2>/dev/null || true)" == inactive ]] \
        || die "existing-host storage commissioning requires inactive: $postgres_unit"
      [[ "$(systemctl is-enabled "$postgres_unit" 2>/dev/null || true)" == disabled ]] \
        || die "existing-host storage commissioning requires disabled: $postgres_unit"
    done
    verify_postgres_start_conf_auto
    database_boot_restore_required=true
  fi
  expected_storage_confirmation="COMMISSION $storage_commissioning_mode /data: source=$expected_data_source uuid=$expected_data_uuid fstype=$expected_data_fstype approval=$storage_approval_reference"
  [[ "$storage_authority_confirmation" == "$expected_storage_confirmation" ]] \
    || die "storage authority creation requires --confirm-storage-authority '$expected_storage_confirmation'"
  if [[ "$storage_commissioning_mode" == EXISTING ]]; then
    if [[ ! -e "$DATABASE_BOOT_IN_PROGRESS" && ! -L "$DATABASE_BOOT_IN_PROGRESS" ]]; then
      publish_database_boot_marker
    else
      verify_database_boot_marker
    fi
  fi
fi
[[ ! -e /data/uten-imp/attachments && ! -L /data/uten-imp/attachments ]] \
  || die 'legacy local attachments exist under /data; preserve them as read-only migration evidence and complete a separately approved OSS migration before runtime installation'

echo '==> Install Java 21, Nginx, PostgreSQL client, and watchdog dependencies'
apt-get update -qq
[[ ! -L /etc/systemd/system/nginx.service ]] \
  || die 'a persistent Nginx mask/alias exists in /etc/systemd/system; review it before phase3'
runtime_nginx_mask_pending=true
cleanup_runtime_nginx_mask() {
  local original_status="$?"
  trap - EXIT
  if ! systemctl unmask --runtime nginx.service >/dev/null 2>&1; then
    printf 'ERROR: failed to remove the runtime-only Nginx package-start mask\n' >&2
    exit 1
  fi
  runtime_nginx_mask_pending=false
  exit "$original_status"
}
systemctl mask --runtime nginx.service >/dev/null
trap cleanup_runtime_nginx_mask EXIT
apt-get install -y -qq \
  openjdk-21-jre-headless nginx postgresql-client-16 curl jq util-linux iproute2 ca-certificates openssl >/dev/null
[[ -x /usr/bin/pg_conftool ]] \
  || die 'postgresql-common pg_conftool is required to prove the 16/main data_directory before PostgreSQL starts'
systemctl unmask --runtime nginx.service >/dev/null \
  || die 'failed to remove the runtime-only Nginx package-start mask'
runtime_nginx_mask_pending=false
trap - EXIT

echo '==> Publish the PostgreSQL fail-closed pre-start gate before storage authority or later runtime writes'
install -d -m 0755 -o root -g root "$RELEASE_LIBEXEC_DIR" "$POSTGRES_STORAGE_DROPIN_DIR"
atomic_install_root_file \
  "$DEPLOY_ROOT/updater/storage_boot_verifier.py" "$STORAGE_BOOT_VERIFIER" 0644 root
atomic_install_root_file \
  "$DEPLOY_ROOT/systemd/postgresql-uten-imp-storage.conf.example" \
  "$POSTGRES_STORAGE_DROPIN" 0644 root
systemctl daemon-reload
[[ "$(systemctl show --property=DropInPaths --value postgresql@16-main.service)" == "$POSTGRES_STORAGE_DROPIN" ]] \
  || die 'PostgreSQL fail-closed storage drop-in was not loaded exactly'
systemctl show --property=ExecStartPre --value postgresql@16-main.service \
  | grep -Fq '/usr/local/libexec/uten-imp-release/storage_boot_verifier.py' \
  || die 'PostgreSQL fail-closed storage verifier is absent from the loaded unit'
if [[ "$install_mode" == initial ]]; then
  rm -f -- /etc/nginx/sites-enabled/default
  systemctl disable --now nginx.service
fi

echo '==> Create dedicated non-login service accounts and persistent directories'
ensure_dedicated_account() {
  local account_name="$1" group_name="$2" passwd_record account_uid account_gid expected_gid account_home account_shell
  local group_record explicit_members primary_members uid_names gid_names
  getent group "$group_name" >/dev/null || groupadd --system "$group_name"
  id -u "$account_name" >/dev/null 2>&1 || \
    useradd --system --gid "$group_name" --home-dir /nonexistent --shell /usr/sbin/nologin "$account_name"
  passwd_record="$(getent passwd "$account_name")" || die "missing service account: $account_name"
  IFS=: read -r _ _ account_uid account_gid _ account_home account_shell <<<"$passwd_record"
  [[ "$account_uid" =~ ^[0-9]+$ && "$account_uid" != 0 ]] \
    || die "$account_name must be a non-root numeric service account"
  uid_names="$(getent passwd | awk -F: -v uid="$account_uid" '$3 == uid { print $1 }')"
  [[ "$uid_names" == "$account_name" ]] \
    || die "$account_uid must map to exactly one passwd name: $account_name"
  group_record="$(getent group "$group_name")" || die "missing service group: $group_name"
  IFS=: read -r _ _ expected_gid explicit_members <<<"$group_record"
  gid_names="$(getent group | awk -F: -v gid="$expected_gid" '$3 == gid { print $1 }')"
  [[ "$gid_names" == "$group_name" ]] \
    || die "$expected_gid must map to exactly one group name: $group_name"
  [[ "$account_gid" == "$expected_gid" ]] || die "$account_name must use $group_name as its primary group"
  [[ "$account_home" == /nonexistent && "$account_shell" == /usr/sbin/nologin ]] \
    || die "$account_name must be a nologin account with /nonexistent home"
  [[ "$(id -Gn "$account_name")" == "$group_name" ]] \
    || die "$account_name must not have supplementary groups"
  [[ -z "$explicit_members" || "$explicit_members" == "$account_name" ]] \
    || die "$group_name must not contain another explicit member"
  primary_members="$(getent passwd | awk -F: -v gid="$expected_gid" '$4 == gid { print $1 }')"
  [[ "$primary_members" == "$account_name" ]] \
    || die "$group_name must be the primary group of only $account_name"
}
ensure_dedicated_account uten-imp uten-imp
ensure_dedicated_account "$MIGRATOR_USER" "$MIGRATOR_GROUP"
install -d -m 0755 -o root -g root /opt/uten-imp/releases
install -d -m 0750 -o root -g uten-imp /etc/uten-imp
install -d -m 0750 -o root -g "$MIGRATOR_GROUP" "$MIGRATOR_ENV_DIR"

echo '==> Install the root-only env validator and migration checklist'
install -d -m 0755 -o root -g root /usr/local/sbin /etc/uten-imp/templates

echo '==> Pin the persistent /data identity and runtime capacity floor'
if [[ -e "$STORAGE_AUTHORITY" || -L "$STORAGE_AUTHORITY" ]]; then
  [[ -f "$STORAGE_AUTHORITY" && ! -L "$STORAGE_AUTHORITY" \
    && "$(stat -c '%U:%G:%a:%h' -- "$STORAGE_AUTHORITY")" == root:root:640:1 ]] \
    || die 'existing storage authority is not a canonical root-controlled file'
else
  storage_authority_temp="$(mktemp /etc/uten-imp/.storage-authority.XXXXXX)"
  cleanup_storage_authority_temp() {
    [[ -z "${storage_authority_temp:-}" ]] || rm -f -- "$storage_authority_temp"
  }
  trap cleanup_storage_authority_temp EXIT
  printf '{\n  "dataFilesystem": "%s",\n  "dataSource": "%s",\n  "dataUuid": "%s",\n  "minimumFreeBytes": 2147483648,\n  "minimumFreeInodes": 100000,\n  "mountPoint": "/data",\n  "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],\n  "schemaVersion": 2\n}\n' \
    "$data_fstype" "$data_source" "$data_uuid" >"$storage_authority_temp"
  chown root:root "$storage_authority_temp"
  chmod 0640 "$storage_authority_temp"
  sync -f "$storage_authority_temp"
  mv -T -- "$storage_authority_temp" "$STORAGE_AUTHORITY"
  storage_authority_temp=''
  trap - EXIT
fi
sync -f /etc/uten-imp
install -m 0755 -o root -g root \
  "$SCRIPT_DIR/validate-server-env.sh" /usr/local/sbin/uten-imp-validate-server-env
install -m 0755 -o root -g root \
  "$SCRIPT_DIR/validate-migrator-env.sh" /usr/local/sbin/uten-imp-validate-migrator-env
install -m 0755 -o root -g root \
  "$SCRIPT_DIR/harden-existing-postgres-roles.sh" \
  /usr/local/sbin/uten-imp-harden-existing-postgres-roles
install -m 0755 -o root -g root \
  "$SCRIPT_DIR/migrate-postgres-secrets-path.sh" \
  /usr/local/sbin/uten-imp-migrate-postgres-secrets-path
install -m 0600 -o root -g root \
  "$SCRIPT_DIR/server.env.oss-migration.example" \
  /etc/uten-imp/templates/server.env.oss-migration.example

[[ ! -L "$ENV_FILE" ]] || die "$ENV_FILE must not be a symlink"
[[ ! -L "$PENDING_ENV" ]] || die "$PENDING_ENV must not be a symlink"
validate_postgres_secret() {
  local secret_path="$1" secret_value
  [[ -f "$secret_path" && ! -L "$secret_path" ]] || die "PostgreSQL secret must be a regular file: $secret_path"
  [[ "$(stat -c '%U:%G:%a:%h' "$secret_path")" == root:postgres:640:1 ]] \
    || die "PostgreSQL secret must be root:postgres mode 0640 with one hard link: $secret_path"
  secret_value="$(<"$secret_path")"
  [[ "$secret_value" =~ ^[A-Za-z0-9]{20,512}$ ]] \
    || die "PostgreSQL secret is outside the reviewed credential format: $secret_path"
  unset secret_value
}
[[ ! -e "$LEGACY_POSTGRES_SECRETS" && ! -L "$LEGACY_POSTGRES_SECRETS" ]] \
  || die "legacy PostgreSQL secrets remain at $LEGACY_POSTGRES_SECRETS; run the separately confirmed uten-imp-migrate-postgres-secrets-path helper before phase3"
[[ -d "$POSTGRES_SECRETS" && ! -L "$POSTGRES_SECRETS" ]] \
  || die "$POSTGRES_SECRETS must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$POSTGRES_SECRETS")" == root:postgres:750 ]] \
  || die "$POSTGRES_SECRETS must be root:postgres mode 0750"
validate_postgres_secret "$POSTGRES_SECRETS/app.password"
if [[ ! -e "$POSTGRES_SECRETS/migrator.password" ]]; then
  die "missing $POSTGRES_SECRETS/migrator.password; run the separately confirmed /usr/local/sbin/uten-imp-harden-existing-postgres-roles path before phase3"
fi
validate_postgres_secret "$POSTGRES_SECRETS/migrator.password"

[[ ! -L "$MIGRATOR_ENV_FILE" ]] || die "$MIGRATOR_ENV_FILE must not be a symlink"
if [[ ! -e "$MIGRATOR_ENV_FILE" ]]; then
  migrator_password="$(<"$POSTGRES_SECRETS/migrator.password")"
  [[ "$migrator_password" =~ ^[A-Za-z0-9]{20,512}$ ]] \
    || die 'migrator password is outside the reviewed credential format'
  migrator_env_temp="$(mktemp -p "$MIGRATOR_ENV_DIR" .migrator.env.XXXXXX)"
  cleanup_migrator_env_temp() {
    local original_status="$?"
    trap - EXIT
    if [[ -n "${migrator_env_temp:-}" && -e "$migrator_env_temp" ]]; then
      case "$migrator_env_temp" in
        "$MIGRATOR_ENV_DIR"/.migrator.env.*) rm -f -- "$migrator_env_temp" ;;
        *) printf 'ERROR: refusing unexpected migrator env cleanup path\n' >&2 ;;
      esac
    fi
    exit "$original_status"
  }
  trap cleanup_migrator_env_temp EXIT
  printf 'UTEN_MIGRATOR_DB_PASSWORD=%s\n' "$migrator_password" >"$migrator_env_temp"
  unset migrator_password
  chown root:"$MIGRATOR_GROUP" "$migrator_env_temp"
  chmod 0640 "$migrator_env_temp"
  sync -f "$migrator_env_temp"
  mv -T --no-clobber -- "$migrator_env_temp" "$MIGRATOR_ENV_FILE"
  migrator_env_temp=''
  trap - EXIT
fi
/usr/local/sbin/uten-imp-validate-migrator-env "$MIGRATOR_ENV_FILE"

generate_secret() {
  openssl rand -hex "${1:-32}"
}

if [[ -e "$PENDING_ENV" ]]; then
  [[ -f "$PENDING_ENV" ]] || die "$PENDING_ENV must be a regular file"
  [[ "$(stat -c '%U:%G:%a:%h' "$PENDING_ENV")" == root:root:600:1 ]] \
    || die "$PENDING_ENV must be root:root mode 0600 with one hard link"
  pending_migrator_secret="$(<"$POSTGRES_SECRETS/migrator.password")"
  pending_contains_migrator=false
  while IFS= read -r pending_line || [[ -n "$pending_line" ]]; do
    case "$pending_line" in
      SPRING_FLYWAY_USER=*|SPRING_FLYWAY_PASSWORD=*|SPRING_FLYWAY_URL=*|FLYWAY_USER=*|FLYWAY_PASSWORD=*|FLYWAY_URL=*|UTEN_MIGRATOR_DB_PASSWORD=*|UTEN_FLYWAY_BASELINE_ON_MIGRATE=*)
        pending_contains_migrator=true
        ;;
      \#*|'') ;;
      *)
        pending_value="${pending_line#*=}"
        if [[ "$pending_value" == *"$pending_migrator_secret"* ]]; then
          pending_contains_migrator=true
        fi
        ;;
    esac
  done <"$PENDING_ENV"
  unset pending_migrator_secret pending_line pending_value
  [[ "$pending_contains_migrator" == false ]] \
    || die "$PENDING_ENV contains an obsolete migrator credential. Keep it only if approved incident evidence is required; otherwise remove it through a reviewed root operation and rerun phase3 to generate a secret-free file"
  unset pending_contains_migrator
fi

if [[ ! -e "$ENV_FILE" ]]; then
  if [[ ! -e "$PENDING_ENV" ]]; then
    app_db_password="$(<"$POSTGRES_SECRETS/app.password")"
    cat >"$PENDING_ENV" <<EOF
# PENDING Uten IMP production environment. Root review is required before activation.
UTEN_PROFILE=prod
UTEN_DEPLOYMENT_SITE=local
UTEN_LOCAL_ALLOWED_CIDRS=127.0.0.0/8,::1/128,REPLACE_EXACT_OFFICE_CIDR
SERVER_ADDRESS=127.0.0.1
SERVER_PORT=8080

UTEN_DB_URL=jdbc:postgresql://127.0.0.1:5432/uten_imp
UTEN_DB_USER=uten
UTEN_DB_PASSWORD=${app_db_password}
SPRING_FLYWAY_ENABLED=false
UTEN_DB_POOL_MAX=20
UTEN_DB_POOL_MIN_IDLE=2
UTEN_DB_CONNECTION_TIMEOUT_MS=10000
UTEN_DB_IDLE_TIMEOUT_MS=600000
UTEN_DB_MAX_LIFETIME_MS=1800000

UTEN_MAX_JSON_BODY_BYTES=1048576
UTEN_FINANCE_ASSET_POSTED_WORKFLOWS_ENABLED=false
UTEN_AUDIT_RETENTION_ENABLED=true
UTEN_AUDIT_RETENTION_CRON=0 17 3 * * *
UTEN_SCHEDULING_POOL_SIZE=4

UTEN_JWT_SECRET=$(generate_secret 32)
UTEN_JWT_ISSUER=uten-imp-production
UTEN_PGP_MASTER_KEY=$(generate_secret 32)
UTEN_PGP_KEY_VERSION=1
UTEN_HMAC_KEY=$(generate_secret 32)

UTEN_CORS_ORIGINS=https://REPLACE_WITH_EXACT_ALLOWED_ORIGIN
UTEN_REQUIRE_HTTPS=true
UTEN_SSL_ENABLED=false
UTEN_TRUSTED_PROXY_REGEX=127[.].*|::1
# One-time 192-bit bootstrap secret. Never copy it into tickets, chat, shell
# history, or logs. After the forced HTTPS first-login change is independently
# verified, follow the validator's controlled retirement procedure.
UTEN_BOOTSTRAP_ADMIN_RETIRED=false
BOOTSTRAP_ADMIN_LOGIN=REPLACE_APPROVED_BOOTSTRAP_ADMIN_LOGIN
BOOTSTRAP_ADMIN_PASSWORD=$(generate_secret 24)
UTEN_SMS_PROVIDER=disabled

UTEN_STORAGE_PROVIDER=oss
UTEN_ATTACHMENT_UPLOADS_ENABLED=false
UTEN_ATTACHMENT_SCANNER_PROVIDER=disabled
UTEN_ATTACHMENT_RECONCILIATION_ENABLED=false
UTEN_STORAGE_MAX_BYTES=26214400
UTEN_STORAGE_PRESIGN_EXPIRY=300
UTEN_OSS_ENDPOINT=https://REPLACE_WITH_PUBLIC_OSS_ENDPOINT
UTEN_OSS_INTERNAL_ENDPOINT=
UTEN_OSS_STAGING_BUCKET=REPLACE_WITH_UNVERSIONED_STAGING_BUCKET
UTEN_OSS_FINAL_BUCKET=REPLACE_WITH_VERSIONED_FINAL_BUCKET
UTEN_OSS_REGION=REPLACE_WITH_REGION
UTEN_OSS_USE_INSTANCE_ROLE=false
UTEN_OSS_ACCESS_KEY_ID=REPLACE_WITH_LEAST_PRIVILEGE_RAM_ACCESS_KEY_ID
UTEN_OSS_ACCESS_KEY_SECRET=REPLACE_WITH_LEAST_PRIVILEGE_RAM_ACCESS_KEY_SECRET
UTEN_OSS_KEY_PREFIX=attachments/
UTEN_OSS_REQUIRE_VERSIONING=true

UTEN_POLICY_INTELLIGENCE_ENABLED=false
EOF
    unset app_db_password
    chown root:root "$PENDING_ENV"
    chmod 0600 "$PENDING_ENV"
  fi
  die "no live server.env exists. Review $PENDING_ENV with sudoedit, verify split OSS Bucket versioning and existing attachment migration, then install it as $ENV_FILE (root:uten-imp 0640) and rerun phase3"
fi

# Existing secrets and metadata are never regenerated, overwritten, or silently
# broadened. In maintenance mode only, a legacy live file with safe metadata may
# be copied byte-for-byte to a root-only pending file for explicit review. The
# live file remains untouched and the runtime installation stops.
if ! /usr/local/sbin/uten-imp-validate-server-env "$ENV_FILE"; then
  [[ "$install_mode" == maintenance ]] \
    || die 'live server.env failed validation during fresh bootstrap'
  [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] \
    || die 'legacy live server.env must be a regular non-symlink file before migration preparation'
  [[ "$(realpath -e -- "$ENV_FILE")" == "$ENV_FILE" ]] \
    || die 'legacy live server.env path is non-canonical'
  legacy_env_metadata="$(stat -c '%U:%G:%a:%h' -- "$ENV_FILE")"
  [[ "$legacy_env_metadata" == root:root:600:1 \
    || "$legacy_env_metadata" == root:uten-imp:640:1 ]] \
    || die 'legacy live server.env must be root:root 0600 or root:uten-imp 0640 with one hard link before migration preparation'
  [[ ! -e "$PENDING_ENV" && ! -L "$PENDING_ENV" ]] \
    || die 'live server.env is invalid and a pending migration file already exists; review it without overwriting either secret file'
  pending_env_temp="$(mktemp -p "$ENV_DIR" .server.env.pending.XXXXXX)"
  cleanup_pending_env_temp() {
    local status="$?"
    trap - EXIT
    if [[ -n "${pending_env_temp:-}" && "$pending_env_temp" == "$ENV_DIR"/.server.env.pending.* \
      && -f "$pending_env_temp" && ! -L "$pending_env_temp" ]]; then
      rm -f -- "$pending_env_temp" || true
    fi
    exit "$status"
  }
  trap cleanup_pending_env_temp EXIT
  install -m 0600 -o root -g root "$ENV_FILE" "$pending_env_temp"
  sync -f "$pending_env_temp"
  mv -T -- "$pending_env_temp" "$PENDING_ENV"
  pending_env_temp=''
  trap - EXIT
  sync -f "$ENV_DIR"
  die "legacy live server.env failed the new validator. Its exact bytes were copied to $PENDING_ENV (root:root 0600); use sudoedit, then install-server-env.sh with the independently reviewed old SHA-256 and replacement approval. The live file was not changed."
fi

echo '==> Install audited watchdog scripts outside the switchable release tree'
install -d -m 0755 -o root -g root "$LIBEXEC_DIR"
install -d -m 0755 -o root -g root "$RELEASE_LIBEXEC_DIR"
cmp -s -- "$DEPLOY_ROOT/updater/storage_boot_verifier.py" "$STORAGE_BOOT_VERIFIER" \
  || die 'installed PostgreSQL storage verifier changed during Phase 3'
atomic_install_root_file \
  "$DEPLOY_ROOT/updater/storage_mount_observer.py" "$STORAGE_MOUNT_OBSERVER" 0644 root
cmp -s -- "$DEPLOY_ROOT/updater/storage_mount_observer.py" "$STORAGE_MOUNT_OBSERVER" \
  || die 'installed storage host observer changed during Phase 3'
atomic_install_root_file \
  "$DEPLOY_ROOT/updater/migration_authorization.py" \
  "$MIGRATION_AUTHORIZATION_HELPER" 0644 root
cmp -s -- "$DEPLOY_ROOT/updater/migration_authorization.py" \
  "$MIGRATION_AUTHORIZATION_HELPER" \
  || die 'installed migration authorization helper changed during Phase 3'
atomic_install_root_file \
  "$DEPLOY_ROOT/updater/recovery_commit_boot_verifier.py" \
  "$RECOVERY_COMMIT_BOOT_VERIFIER" 0644 root
atomic_install_root_file \
  "$DEPLOY_ROOT/updater/recovery_ingress_gate.py" \
  "$RECOVERY_INGRESS_GATE" 0644 root
cmp -s -- "$DEPLOY_ROOT/updater/recovery_commit_boot_verifier.py" \
  "$RECOVERY_COMMIT_BOOT_VERIFIER" \
  || die 'installed recovery commit verifier changed during Phase 3'
cmp -s -- "$DEPLOY_ROOT/updater/recovery_ingress_gate.py" \
  "$RECOVERY_INGRESS_GATE" \
  || die 'installed recovery ingress gate changed during Phase 3'
install -m 0755 -o root -g root \
  "$DEPLOY_ROOT/watchdog/uten-imp-watchdog.sh" "$LIBEXEC_DIR/uten-imp-watchdog"
atomic_install_root_file \
  "$DEPLOY_ROOT/watchdog/uten-imp-entry-watchdog.sh" \
  "$LIBEXEC_DIR/uten-imp-entry-watchdog" 0755 root
cmp -s -- "$DEPLOY_ROOT/watchdog/uten-imp-entry-watchdog.sh" \
  "$LIBEXEC_DIR/uten-imp-entry-watchdog" \
  || die 'installed entry watchdog differs from the reviewed fail-closed source'
install -m 0755 -o root -g root \
  "$SCRIPT_DIR/wait-for-erp-readiness.sh" "$LIBEXEC_DIR/uten-imp-wait-ready"

echo '==> Install systemd units (activation is deliberately deferred)'
install -d -m 0755 -o root -g root "$POSTGRES_STORAGE_DROPIN_DIR"
cmp -s -- "$DEPLOY_ROOT/systemd/postgresql-uten-imp-storage.conf.example" "$POSTGRES_STORAGE_DROPIN" \
  || die 'installed PostgreSQL storage drop-in changed during Phase 3'
install -m 0644 -o root -g root \
  "$DEPLOY_ROOT/systemd/uten-imp-migrate.service.example" \
  /etc/systemd/system/uten-imp-migrate.service
install -m 0644 -o root -g root \
  "$DEPLOY_ROOT/systemd/uten-imp.service.example" /etc/systemd/system/uten-imp.service
atomic_install_root_file \
  "$DEPLOY_ROOT/systemd/uten-imp-recovery-commit-verifier.service.example" \
  "$RECOVERY_COMMIT_BOOT_UNIT" 0644 root
install -d -m 0755 -o root -g root /etc/systemd/system/nginx.service.d
install -m 0644 -o root -g root \
  "$DEPLOY_ROOT/systemd/nginx-uten-imp-override.conf.example" \
  /etc/systemd/system/nginx.service.d/uten-imp.conf
install -m 0644 -o root -g root \
  "$DEPLOY_ROOT/systemd/uten-imp-watchdog.service.example" \
  /etc/systemd/system/uten-imp-watchdog.service
install -m 0644 -o root -g root \
  "$DEPLOY_ROOT/systemd/uten-imp-watchdog.timer.example" \
  /etc/systemd/system/uten-imp-watchdog.timer
observer_unit_rendered="$(mktemp /tmp/uten-imp-storage-observer.XXXXXX)"
cleanup_observer_unit_render() {
  local status="$?"
  trap - EXIT
  [[ -z "${observer_unit_rendered:-}" ]] || rm -f -- "$observer_unit_rendered"
  exit "$status"
}
trap cleanup_observer_unit_render EXIT
/usr/bin/python3 -I - "$DEPLOY_ROOT/updater/storage_mount_observer.py" \
  "$observer_unit_rendered" "$STORAGE_OBSERVER_UNIT_TEMPLATE" \
  "$storage_authority_schema" "$data_observer_device" <<'PY'
import importlib.util
import sys
from pathlib import Path

source = Path(sys.argv[1])
rendered = Path(sys.argv[2])
template = Path(sys.argv[3])
schema = int(sys.argv[4])
device = sys.argv[5] or None
spec = importlib.util.spec_from_file_location("uten_imp_storage_observer", source)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load reviewed storage observer")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
expected = module.render_observer_unit(device if schema == 2 else None)
rendered.write_text(expected, encoding="utf-8")
if rendered.read_text(encoding="utf-8") != expected:
    raise SystemExit("rendered storage observer unit differs from helper contract")
if schema == 3 and template.read_text(encoding="utf-8") != expected:
    raise SystemExit("v3 storage observer template differs from helper contract")
PY
atomic_install_root_file "$observer_unit_rendered" "$STORAGE_OBSERVER_UNIT" 0644 root
cmp -s -- "$observer_unit_rendered" "$STORAGE_OBSERVER_UNIT" \
  || die 'installed storage observer unit differs from the authority-generation contract'
rm -f -- "$observer_unit_rendered"
observer_unit_rendered=''
trap - EXIT
atomic_install_root_file \
  "$DEPLOY_ROOT/systemd/uten-imp-entry-watchdog.service.example" \
  /etc/systemd/system/uten-imp-entry-watchdog.service 0644 root
install -m 0644 -o root -g root \
  "$DEPLOY_ROOT/systemd/uten-imp-entry-watchdog.timer.example" \
  /etc/systemd/system/uten-imp-entry-watchdog.timer
systemctl daemon-reload
systemctl enable --now uten-imp-recovery-commit-verifier.service
[[ "$(systemctl show --property=UnitFileState --value uten-imp-recovery-commit-verifier.service)" == enabled \
  && "$(systemctl show --property=ActiveState --value uten-imp-recovery-commit-verifier.service)" == active \
  && "$(systemctl show --property=FragmentPath --value uten-imp-recovery-commit-verifier.service)" == "$RECOVERY_COMMIT_BOOT_UNIT" \
  && -z "$(systemctl show --property=DropInPaths --value uten-imp-recovery-commit-verifier.service)" ]] \
  || die 'recovery commit boot verifier did not converge to its fixed enabled unit'
loaded_migrator_after=" $(systemctl show --property=After --value uten-imp-migrate.service) "
[[ "$loaded_migrator_after" == *' network-online.target '* \
  && "$loaded_migrator_after" == *' data.mount '* \
  && "$loaded_migrator_after" == *" $POSTGRES_INSTANCE_UNIT "* ]] \
  || die 'loaded migrator unit lacks reviewed ordering-only dependencies'
[[ "$(systemctl show --property=Wants --value uten-imp-migrate.service)" \
  == network-online.target ]] \
  || die 'loaded migrator unit Wants must contain only network-online.target'
for pull_property in Requires Requisite BindsTo PartOf Upholds; do
  pull_dependencies=" $(systemctl show --property="$pull_property" --value uten-imp-migrate.service) "
  [[ "$pull_dependencies" != *" $POSTGRES_INSTANCE_UNIT "* \
    && "$pull_dependencies" != *' data.mount '* ]] \
    || die "loaded migrator unit must not pull PostgreSQL or /data through $pull_property="
done
[[ -z "$(systemctl show --property=RequiresMountsFor --value uten-imp-migrate.service)" ]] \
  || die 'loaded migrator unit must not pull /data through RequiresMountsFor='
[[ "$(systemctl show --property=FragmentPath --value uten-imp-storage-observer.service)" == "$STORAGE_OBSERVER_UNIT" \
  && -z "$(systemctl show --property=DropInPaths --value uten-imp-storage-observer.service)" \
  && "$(systemctl show --property=DevicePolicy --value uten-imp-storage-observer.service)" == closed ]] \
  || die 'loaded storage observer lacks the fixed no-drop-in exact-device sandbox'
cmp -s -- "$DEPLOY_ROOT/systemd/uten-imp-entry-watchdog.service.example" \
  /etc/systemd/system/uten-imp-entry-watchdog.service \
  || die 'installed entry watchdog unit differs from the reviewed fixed contract'
[[ "$(systemctl show --property=FragmentPath --value uten-imp-entry-watchdog.service)" == /etc/systemd/system/uten-imp-entry-watchdog.service \
  && -z "$(systemctl show --property=DropInPaths --value uten-imp-entry-watchdog.service)" \
  && "$(systemctl show --property=Wants --value uten-imp-entry-watchdog.service)" == network-online.target ]] \
  || die 'loaded entry watchdog unit has an unreviewed source, drop-in, or Wants dependency'
entry_watchdog_after=" $(systemctl show --property=After --value uten-imp-entry-watchdog.service) "
[[ "$entry_watchdog_after" == *' nginx.service '* \
  && "$entry_watchdog_after" == *' network-online.target '* ]] \
  || die 'loaded entry watchdog unit lacks fixed Nginx/network ordering'
for pull_property in Requires BindsTo Upholds; do
  pull_dependencies=" $(systemctl show --property="$pull_property" --value uten-imp-entry-watchdog.service) "
  [[ "$pull_dependencies" != *' nginx.service '* ]] \
    || die "loaded entry watchdog must not pull Nginx through $pull_property="
done
systemctl is-active --quiet uten-imp-storage-observer.service 2>/dev/null \
  && die 'storage observer unexpectedly became active during Phase 3'
systemctl is-enabled --quiet uten-imp-storage-observer.service 2>/dev/null \
  && die 'storage observer must remain an on-demand, non-enabled service'
if [[ "$install_mode" == initial ]]; then
  systemctl disable nginx.service uten-imp-migrate.service uten-imp.service \
    uten-imp-watchdog.timer uten-imp-entry-watchdog.timer
fi

if [[ "$database_boot_restore_required" == true ]]; then
  verify_database_boot_marker
  # Every possible crash boundary after this point retains the durable marker.
  # A partial enablement is still storage-gated, while every application/entry
  # unit remains inactive and disabled. A maintenance rerun converges the two
  # database boot units and only then removes the marker.
  systemctl daemon-reload
  systemctl enable "$POSTGRES_META_UNIT" "$POSTGRES_INSTANCE_UNIT"
  systemctl start "$POSTGRES_META_UNIT"
  verify_database_boot_contract
  rm -f -- "$DATABASE_BOOT_IN_PROGRESS"
  sync -f "$COMMISSIONING_DIR"
else
  verify_database_boot_contract
fi

echo '==> Migrator, Nginx, application, and watchdog activation remain deferred pending acceptance'
echo '==> Runtime baseline installed without starting the application'
java -version 2>&1 | head -1
nginx -v 2>&1
id uten-imp
id "$MIGRATOR_USER"
ls -ld /opt/uten-imp/releases "$LIBEXEC_DIR"
ls -ld "$MIGRATOR_ENV_DIR"
ls -l "$ENV_FILE" "$MIGRATOR_ENV_FILE" "$LIBEXEC_DIR/uten-imp-watchdog" \
  "$LIBEXEC_DIR/uten-imp-entry-watchdog" "$LIBEXEC_DIR/uten-imp-wait-ready" \
  "$STORAGE_BOOT_VERIFIER" "$STORAGE_MOUNT_OBSERVER" \
  "$MIGRATION_AUTHORIZATION_HELPER" \
  "$POSTGRES_STORAGE_DROPIN" "$STORAGE_OBSERVER_UNIT"
printf '%s\n' \
  'RUNTIME_BASELINE_INSTALLED' \
  'APP_NOT_STARTED_OR_ENABLED: app/watchdog activation is a later explicit step after every gate passes.' \
  'BOOTSTRAP_ADMIN_PENDING: use the generated credential only over accepted HTTPS; after the forced change, verify the old credential fails and the database records the change, then clear it with UTEN_BOOTSTRAP_ADMIN_RETIRED=true and use a controlled restart to scrub the process environment.' \
  'PROCESS_SECRET_ISOLATION_INSTALLED: the app has Flyway disabled and cannot read the dedicated migrator environment. Activation must run uten-imp-migrate.service explicitly before starting the backend.' \
  'DATABASE_BOOT_AUTHORITY_VERIFIED: postgresql.service and postgresql@16-main.service are active and persistently enabled through exact start.conf=auto and the Debian generator dependency.' \
  'POSTGRES_STORAGE_BOOT_GATE_INSTALLED: PostgreSQL is bound to data.mount and verifies the commissioned md source/UUID, mount policy, capacity, inodes, and effective 16/main data_directory before every future start.' \
  'STORAGE_LATE_MOUNT_OBSERVER_INSTALLED: the network watchdog retains PrivateDevices; a separate non-networked exact-device read-only observer may issue one short-lived boot-bound receipt before data.mount is started.' \
  'A signed release, accepted TLS site, V238-to-V255 migration/reconciliation, OSS acceptance, and restore evidence remain separate gates.'
