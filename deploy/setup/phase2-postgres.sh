#!/usr/bin/env bash
# Uten IMP Phase 2: initialize a NEW PostgreSQL 16 host on a dedicated /data mount.
# This installer is intentionally non-idempotent: any existing cluster or data
# makes it stop. It never drops, rewrites, imports, or upgrades an existing DB.
set -Eeuo pipefail
umask 0077
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly PG_VERSION=16
readonly PG_CLUSTER=main
readonly PGDATA=/data/postgresql/16/main
readonly PG_CONFIG_DIR=/etc/postgresql/16/main
readonly SECRETS=/etc/uten-imp-postgres
readonly PGBACKREST_SECRETS=/etc/uten-imp-postgres/pgbackrest
readonly LEGACY_SECRETS=/etc/uten-imp/postgres-secrets
readonly LEGACY_PGBACKREST_SECRETS=/etc/uten-imp/pgbackrest-secrets
readonly PGBACKREST_REPO=/data/backups/pgbackrest
readonly BACKUP_LIBEXEC_DIR=/usr/local/libexec/uten-imp-backup
readonly BACKUP_LOCKED_JOB=$BACKUP_LIBEXEC_DIR/locked_job.py
readonly DB_MAINTENANCE_DIR=/var/lib/uten-imp-db-maintenance
readonly DB_MAINTENANCE_LOCK=$DB_MAINTENANCE_DIR/operation.lock
readonly BACKUP_HEALTH_STATE_DIR=/var/lib/uten-imp-backup-health
readonly MIN_RAM_KIB=$((16 * 1024 * 1024))
readonly MIN_DATA_BYTES=$((200 * 1024 * 1024 * 1024))
readonly MIN_DATA_FREE_BYTES=$((100 * 1024 * 1024 * 1024))
readonly FRESH_CONFIRMATION='INITIALIZE EMPTY UTEN POSTGRES 16/main'
readonly COMMISSIONING_DIR=/var/lib/uten-imp-commissioning
readonly CREATECLUSTER_CONF=/etc/postgresql-common/createcluster.conf
readonly CREATECLUSTER_OVERRIDE_MARKER=$COMMISSIONING_DIR/createcluster-override.state
readonly CREATECLUSTER_PREIMAGE=$COMMISSIONING_DIR/createcluster.conf.preimage
readonly PHASE2_IN_PROGRESS=$COMMISSIONING_DIR/phase2-in-progress.state
readonly PHASE2_FAILED=$COMMISSIONING_DIR/phase2-failed.state
readonly PHASE2_COMPLETE=$COMMISSIONING_DIR/phase2-complete.state

fresh_confirmation=''

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash phase2-postgres.sh \
    --confirm-empty-host 'INITIALIZE EMPTY UTEN POSTGRES 16/main'

This command is only for a proven-empty, dedicated host. It refuses any known
cluster, PostgreSQL process/socket/listener, common data/config root, or
PostgreSQL container. It never adopts, drops, overwrites, or repairs a database.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --confirm-empty-host)
      [[ "$#" -ge 2 ]] || die 'missing value for --confirm-empty-host'
      fresh_confirmation="$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

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
    || die "installer must be a regular, non-symlink file: $source_file"
  [[ "$(stat -c '%U:%h' -- "$source_file")" == root:1 ]] \
    || die "installer must be root-owned with one hard link: $source_file"
  mode="$(stat -c '%a' -- "$source_file")"
  (( (8#$mode & 0022) == 0 )) || die "installer is group- or other-writable: $source_file"
  require_root_directory_chain "$(dirname -- "$source_file")"
}

validate_data_raid() {
  local data_source md_name
  for required_command in mountpoint findmnt; do
    command -v "$required_command" >/dev/null 2>&1 \
      || die "$required_command is required before this installer can validate /data"
  done
  [[ -x /usr/bin/python3 ]] || die '/usr/bin/python3 is required for fail-closed storage validation'
  [[ -r /proc/mdstat ]] || die '/proc/mdstat is unavailable'
  [[ -d /data ]] || die '/data does not exist'
  mountpoint --quiet /data \
    || die '/data must be a real mounted filesystem; refusing to write database files to the root filesystem'
  data_source="$(findmnt -no SOURCE /data)"
  [[ "$data_source" =~ ^/dev/md([0-9]+)$ ]] \
    || die '/data must be mounted from one explicitly verified /dev/mdN software RAID device'
  md_name="md${BASH_REMATCH[1]}"
  [[ -b "$data_source" ]] || die "$data_source is not a block device"
  findmnt -no OPTIONS /data | grep -Eq '(^|,)rw(,|$)' \
    || die '/data is not mounted read-write'

  /usr/bin/python3 -I - /proc/mdstat "$md_name" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="ascii")
target = sys.argv[2]
blocks = {
    match.group(1): match.group(0)
    for match in re.finditer(
        r"(?ms)^(md\d+)\s*:\s*active\b.*?(?=^md\d+\s*:|^unused devices:|\Z)",
        text,
    )
}
block = blocks.get(target)
if block is None:
    raise SystemExit(f"mounted RAID {target} is not an active md array")
if re.search(r"(?:resync|recovery|reshape|check|repair)\s*=", block):
    raise SystemExit(f"mounted RAID {target} is busy; wait for it to finish")
counts = re.search(r"\[(\d+)/(\d+)\]", block)
state = re.search(r"\[([U_]+)\]", block)
if (
    counts is None
    or counts.group(1) != counts.group(2)
    or state is None
    or "_" in state.group(1)
    or len(state.group(1)) != int(counts.group(2))
):
    raise SystemExit(f"mounted RAID {target} is degraded or lacks complete redundancy")
PY

  /usr/bin/python3 -I - \
    "$MIN_RAM_KIB" "$MIN_DATA_BYTES" "$MIN_DATA_FREE_BYTES" <<'PY'
import os
import sys
from pathlib import Path

minimum_ram_kib, minimum_data_bytes, minimum_free_bytes = map(int, sys.argv[1:])
meminfo = Path("/proc/meminfo").read_text(encoding="ascii")
mem_total = next(
    (int(line.split()[1]) for line in meminfo.splitlines() if line.startswith("MemTotal:")),
    0,
)
if mem_total < minimum_ram_kib:
    raise SystemExit("at least 16 GiB RAM is required for the reviewed PostgreSQL baseline")
stats = os.statvfs("/data")
total = stats.f_blocks * stats.f_frsize
free = stats.f_bavail * stats.f_frsize
if total < minimum_data_bytes:
    raise SystemExit("/data must provide at least 200 GiB usable capacity")
if free < minimum_free_bytes or free * 100 < total * 80:
    raise SystemExit("fresh commissioning requires at least 100 GiB and 80% free on /data")
PY
}

require_fresh_cluster() {
  local clusters='' candidate_root running_database_units container_inventory
  if command -v pg_lsclusters >/dev/null 2>&1; then
    clusters="$(pg_lsclusters --no-header 2>/dev/null || true)"
  fi
  if [[ -n "${clusters//[[:space:]]/}" ]]; then
    printf '%s\n' "$clusters" >&2
    die 'an existing PostgreSQL cluster was detected; this fresh-host installer will not continue or delete it'
  fi
  [[ ! -e "$PG_CONFIG_DIR" ]] \
    || die "$PG_CONFIG_DIR already exists; inspect it manually and use a reviewed migration procedure"
  [[ ! -L "$PG_CONFIG_DIR" ]] || die "$PG_CONFIG_DIR must not be a symlink"
  [[ ! -e "$PGDATA" && ! -L "$PGDATA" ]] \
    || die "$PGDATA already exists; this installer will not reuse, delete, or overwrite it"
  if pgrep -x postgres >/dev/null 2>&1 || pgrep -x postmaster >/dev/null 2>&1; then
    die 'a PostgreSQL/postmaster process is already running; host identity is not proven empty'
  fi
  if ss -H -ltn | awk '$4 ~ /(^|[^0-9])5432$/ { found=1 } END { exit(found ? 0 : 1) }'; then
    die 'TCP port 5432 already has a listener; host identity is not proven empty'
  fi
  if [[ -d /var/run/postgresql ]] \
    && find /var/run/postgresql -maxdepth 1 -type s -name '.s.PGSQL.*' -print -quit | grep -q .; then
    die 'an existing PostgreSQL Unix socket was found'
  fi
  for candidate_root in /etc/postgresql /var/lib/postgresql /data/postgresql; do
    if [[ -e "$candidate_root" || -L "$candidate_root" ]]; then
      [[ -d "$candidate_root" && ! -L "$candidate_root" ]] \
        || die "possible PostgreSQL root is not a real directory: $candidate_root"
      if find "$candidate_root" -mindepth 1 -print -quit | grep -q .; then
        die "possible existing PostgreSQL state was found under $candidate_root"
      fi
    fi
  done
  running_database_units="$(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null \
    | awk 'tolower($0) ~ /(postgres|postgis|timescale)/ {print $1}')"
  [[ -z "$running_database_units" ]] \
    || die "a database-related systemd service is already running: $running_database_units"
  for container_command in docker podman; do
    if command -v "$container_command" >/dev/null 2>&1; then
      if ! container_inventory="$($container_command ps -a --format '{{.Image}} {{.Names}}' 2>/dev/null)"; then
        die "$container_command is installed but its full container inventory cannot be audited"
      fi
      if grep -Eiq '(postgres|postgis|timescale)' <<<"$container_inventory"; then
        die "a running or stopped PostgreSQL-related $container_command container exists"
      fi
    fi
  done
}

validate_postgres_identity_boundary() {
  local postgres_uid postgres_gid explicit_members uid_names gid_names primary_names group_record
  postgres_uid="$(id -u postgres 2>/dev/null)" || die 'postgres service account is missing after package installation'
  postgres_gid="$(id -g postgres 2>/dev/null)" || die 'postgres primary group is missing after package installation'
  [[ "$postgres_uid" =~ ^[0-9]+$ && "$postgres_uid" != 0 \
    && "$postgres_gid" =~ ^[0-9]+$ && "$postgres_gid" != 0 ]] \
    || die 'postgres must use non-root numeric UID/GID values'
  uid_names="$(getent passwd | awk -F: -v uid="$postgres_uid" '$3 == uid {print $1}')"
  [[ "$uid_names" == postgres ]] || die 'postgres numeric UID must map to exactly one passwd name'
  gid_names="$(getent group | awk -F: -v gid="$postgres_gid" '$3 == gid {print $1}')"
  [[ "$gid_names" == postgres ]] || die 'postgres numeric GID must map to exactly one group name'
  group_record="$(getent group postgres)" || die 'postgres group record is missing'
  IFS=: read -r _ _ _ explicit_members <<<"$group_record"
  [[ -z "$explicit_members" || "$explicit_members" == postgres ]] \
    || die 'postgres group contains another explicit member that could read database secrets'
  primary_names="$(getent passwd | awk -F: -v gid="$postgres_gid" '$4 == gid {print $1}')"
  [[ "$primary_names" == postgres ]] \
    || die 'postgres group must be the primary group of exactly the postgres account'
}

[[ "${EUID}" -eq 0 ]] || die 'run as root (sudo bash phase2-postgres.sh)'
[[ "$fresh_confirmation" == "$FRESH_CONFIRMATION" ]] \
  || die "--confirm-empty-host must exactly equal: $FRESH_CONFIRMATION"
[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to run phase2 through a symlink'
readonly SCRIPT_FILE="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_FILE")" && pwd -P)"
readonly DEPLOY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly BACKUP_LOCKED_JOB_SOURCE="$DEPLOY_ROOT/postgres/backup/locked_job.py"
require_root_source_file "$SCRIPT_FILE"
require_root_source_file "$BACKUP_LOCKED_JOB_SOURCE"
for prior_phase2_state in "$PHASE2_IN_PROGRESS" "$PHASE2_FAILED" "$PHASE2_COMPLETE"; do
  if [[ -e "$prior_phase2_state" || -L "$prior_phase2_state" ]]; then
    die "prior Phase 2 commissioning evidence exists at $prior_phase2_state; do not rerun or delete it without an audited recovery/reimage decision"
  fi
done
validate_data_raid
[[ ! -e /etc/pgbackrest.conf && ! -L /etc/pgbackrest.conf ]] \
  || die '/etc/pgbackrest.conf already exists; refusing to overwrite an existing backup configuration'
[[ ! -L /data/postgresql && ! -L /data/backups ]] \
  || die '/data/postgresql and /data/backups must be real directories, not symlinks'
for legacy_secret_dir in "$LEGACY_SECRETS" "$LEGACY_PGBACKREST_SECRETS"; do
  [[ ! -e "$legacy_secret_dir" && ! -L "$legacy_secret_dir" ]] \
    || die "legacy secret path detected at $legacy_secret_dir; this fresh installer will not move, reuse, or overwrite it"
done
if [[ -d "$SECRETS" ]] && find "$SECRETS" -mindepth 1 -print -quit | grep -q .; then
  die "$SECRETS is not empty; refusing to reuse unexplained credentials"
fi
[[ ! -L "$SECRETS" && ! -L "$PGBACKREST_SECRETS" ]] \
  || die 'PostgreSQL secret paths must not be symlinks'
[[ ! -L "$PGBACKREST_REPO" ]] || die "$PGBACKREST_REPO must not be a symlink"
if [[ -d "$PGBACKREST_REPO" ]] && find "$PGBACKREST_REPO" -mindepth 1 -print -quit | grep -q .; then
  die "$PGBACKREST_REPO is not empty; refusing to mix backup repositories"
fi
for fresh_backup_runtime_path in \
  "$BACKUP_LIBEXEC_DIR" "$DB_MAINTENANCE_DIR" "$BACKUP_HEALTH_STATE_DIR"; do
  [[ ! -e "$fresh_backup_runtime_path" && ! -L "$fresh_backup_runtime_path" ]] \
    || die "unexpected existing backup runtime path on a fresh host: $fresh_backup_runtime_path"
done

echo '==> Install PostgreSQL package tooling (no database cluster is modified)'
apt-get update -qq
apt-get install -y -qq postgresql-common ca-certificates openssl >/dev/null

# Debian/Ubuntu normally creates a default cluster while installing a server
# package. Persist the exact preimage before overriding that global hook so a
# reboot or SIGKILL can be recovered before any later commissioning attempt.
install -d -m 0700 -o root -g root "$COMMISSIONING_DIR"
[[ ! -L "$CREATECLUSTER_OVERRIDE_MARKER" && ! -L "$CREATECLUSTER_PREIMAGE" ]] \
  || die 'createcluster recovery evidence must not be symlinked'
createcluster_restore_pending=false

restore_createcluster_conf() {
  local state restore_tmp='' current_kind=missing current_metadata preimage_metadata
  [[ -e "$CREATECLUSTER_OVERRIDE_MARKER" ]] || {
    createcluster_restore_pending=false
    return 0
  }
  [[ -f "$CREATECLUSTER_OVERRIDE_MARKER" && ! -L "$CREATECLUSTER_OVERRIDE_MARKER" \
    && "$(stat -c '%U:%G:%a:%h' -- "$CREATECLUSTER_OVERRIDE_MARKER")" == root:root:600:1 ]] \
    || return 1
  state="$(<"$CREATECLUSTER_OVERRIDE_MARKER")"
  [[ "$state" == 'original=present' || "$state" == 'original=absent' ]] || return 1
  if [[ "$state" == 'original=present' ]]; then
    [[ -f "$CREATECLUSTER_PREIMAGE" && ! -L "$CREATECLUSTER_PREIMAGE" \
      && "$(stat -c '%U:%h' -- "$CREATECLUSTER_PREIMAGE")" == root:1 ]] \
      || return 1
  else
    [[ ! -e "$CREATECLUSTER_PREIMAGE" && ! -L "$CREATECLUSTER_PREIMAGE" ]] || return 1
  fi
  if [[ -e "$CREATECLUSTER_CONF" || -L "$CREATECLUSTER_CONF" ]]; then
    [[ -f "$CREATECLUSTER_CONF" && ! -L "$CREATECLUSTER_CONF" ]] || return 1
    current_metadata="$(stat -c '%U:%G:%a:%h' -- "$CREATECLUSTER_CONF")"
    if [[ "$current_metadata" == root:root:644:1 \
      && "$(<"$CREATECLUSTER_CONF")" == 'create_main_cluster = false' ]]; then
      current_kind=override
    elif [[ "$state" == 'original=present' ]] \
      && cmp -s -- "$CREATECLUSTER_CONF" "$CREATECLUSTER_PREIMAGE"; then
      preimage_metadata="$(stat -c '%U:%G:%a:%h' -- "$CREATECLUSTER_PREIMAGE")"
      [[ "$current_metadata" == "$preimage_metadata" ]] || return 1
      current_kind=original
    else
      return 1
    fi
  fi
  if [[ "$state" == 'original=present' ]]; then
    if [[ "$current_kind" != original ]]; then
      restore_tmp="$(mktemp /etc/postgresql-common/.createcluster.conf.restore.XXXXXX)"
      if ! cp --archive -- "$CREATECLUSTER_PREIMAGE" "$restore_tmp"; then
        rm -f -- "$restore_tmp" || true
        return 1
      fi
      if ! mv -fT -- "$restore_tmp" "$CREATECLUSTER_CONF"; then
        rm -f -- "$restore_tmp" || true
        return 1
      fi
      sync -f /etc/postgresql-common || return 1
    fi
  elif [[ "$current_kind" == override ]]; then
    rm -f -- "$CREATECLUSTER_CONF" || return 1
    sync -f /etc/postgresql-common || return 1
  fi
  rm -f -- "$CREATECLUSTER_PREIMAGE" "$CREATECLUSTER_OVERRIDE_MARKER" || return 1
  sync -f "$COMMISSIONING_DIR" || return 1
  createcluster_restore_pending=false
}

if [[ -e "$CREATECLUSTER_OVERRIDE_MARKER" ]]; then
  echo '==> Recover a persisted createcluster.conf preimage from an interrupted prior attempt'
  restore_createcluster_conf \
    || die 'stale createcluster.conf override cannot be proven/restored; keep PostgreSQL stopped and investigate manually'
fi
require_fresh_cluster
[[ ! -e "$CREATECLUSTER_PREIMAGE" && ! -L "$CREATECLUSTER_PREIMAGE" ]] \
  || die 'orphaned createcluster.conf preimage exists without a recovery marker; investigate manually'
if find "$COMMISSIONING_DIR" -maxdepth 1 -type f -name '.createcluster.conf.*' -print -quit | grep -q .; then
  die 'orphaned createcluster.conf staging evidence exists; investigate manually'
fi

if [[ -e "$CREATECLUSTER_CONF" || -L "$CREATECLUSTER_CONF" ]]; then
  [[ -f "$CREATECLUSTER_CONF" && ! -L "$CREATECLUSTER_CONF" ]] \
    || die "$CREATECLUSTER_CONF must be a regular, non-symlink file"
  [[ "$(stat -c '%U:%h' -- "$CREATECLUSTER_CONF")" == root:1 ]] \
    || die "$CREATECLUSTER_CONF must be root-owned with one hard link"
  createcluster_mode="$(stat -c '%a' -- "$CREATECLUSTER_CONF")"
  (( (8#$createcluster_mode & 0022) == 0 )) \
    || die "$CREATECLUSTER_CONF is group- or other-writable"
  preimage_tmp="$(mktemp "$COMMISSIONING_DIR/.createcluster.conf.preimage.XXXXXX")"
  cp --archive -- "$CREATECLUSTER_CONF" "$preimage_tmp"
  sync -f "$preimage_tmp"
  mv -fT -- "$preimage_tmp" "$CREATECLUSTER_PREIMAGE"
  sync -f "$COMMISSIONING_DIR"
  createcluster_original_state=present
else
  [[ ! -e "$CREATECLUSTER_PREIMAGE" ]] || die 'unexpected createcluster.conf preimage exists'
  createcluster_original_state=absent
fi
override_marker_tmp="$(mktemp "$COMMISSIONING_DIR/.createcluster-override.XXXXXX")"
printf 'original=%s\n' "$createcluster_original_state" >"$override_marker_tmp"
chown root:root "$override_marker_tmp"
chmod 0600 "$override_marker_tmp"
mv -fT -- "$override_marker_tmp" "$CREATECLUSTER_OVERRIDE_MARKER"
sync -f "$COMMISSIONING_DIR"
override_tmp="$(mktemp /etc/postgresql-common/.createcluster.conf.override.XXXXXX)"
printf 'create_main_cluster = false\n' >"$override_tmp"
chown root:root "$override_tmp"
chmod 0644 "$override_tmp"
mv -fT -- "$override_tmp" "$CREATECLUSTER_CONF"
sync -f /etc/postgresql-common
createcluster_restore_pending=true

cleanup_createcluster_conf() {
  local original_status="$?"
  trap - EXIT
  if ! restore_createcluster_conf; then
    printf 'ERROR: failed to restore %s; persistent evidence remains in %s\n' \
      "$CREATECLUSTER_CONF" "$COMMISSIONING_DIR" >&2
    exit 1
  fi
  exit "$original_status"
}
trap cleanup_createcluster_conf EXIT

echo '==> Install PostgreSQL 16 and pgBackRest without auto-creating a cluster'
apt-get install -y -qq postgresql-16 postgresql-client-16 pgbackrest >/dev/null
restore_createcluster_conf \
  || die "failed to restore $CREATECLUSTER_CONF; persistent evidence remains in $COMMISSIONING_DIR"
trap - EXIT
require_fresh_cluster
validate_postgres_identity_boundary

echo '==> Create the only cluster at /data with checksums and SCRAM authentication'
install -d -m 0700 -o postgres -g postgres /data/postgresql
phase2_complete=false
phase2_started=true
install -d -m 0700 -o root -g root "$COMMISSIONING_DIR"
phase2_state_tmp="$(mktemp "$COMMISSIONING_DIR/.phase2-in-progress.XXXXXX")"
printf 'state=IN_PROGRESS\nstarted_utc=%s\ncluster=%s/%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PG_VERSION" "$PG_CLUSTER" >"$phase2_state_tmp"
chown root:root "$phase2_state_tmp"
chmod 0600 "$phase2_state_tmp"
mv -fT -- "$phase2_state_tmp" "$PHASE2_IN_PROGRESS"
sync -f "$COMMISSIONING_DIR"

echo '==> Install the fixed backup-job supervisor and database-maintenance lock'
install -d -m 0755 -o root -g root "$BACKUP_LIBEXEC_DIR"
install -m 0755 -o root -g root "$BACKUP_LOCKED_JOB_SOURCE" "$BACKUP_LOCKED_JOB"
install -d -m 0750 -o root -g postgres "$DB_MAINTENANCE_DIR"
install -m 0660 -o root -g postgres /dev/null "$DB_MAINTENANCE_LOCK"
install -d -m 0770 -o root -g postgres "$BACKUP_HEALTH_STATE_DIR"
[[ "$(stat -c '%U:%G:%a:%h' -- "$BACKUP_LOCKED_JOB")" == root:root:755:1 ]] \
  || die 'installed backup-job supervisor metadata differs from root:root 0755 single-link'
[[ "$(stat -c '%U:%G:%a:%h' -- "$DB_MAINTENANCE_LOCK")" == root:postgres:660:1 ]] \
  || die 'database-maintenance lock metadata differs from root:postgres 0660 single-link'
[[ "$(stat -c '%U:%G:%a' -- "$BACKUP_HEALTH_STATE_DIR")" == root:postgres:770 ]] \
  || die 'backup-health state directory metadata differs from root:postgres 0770'
sync -f "$BACKUP_LOCKED_JOB"
sync -f "$DB_MAINTENANCE_LOCK"
sync -f "$BACKUP_LIBEXEC_DIR"
sync -f "$DB_MAINTENANCE_DIR"
sync -f "$BACKUP_HEALTH_STATE_DIR"

set_cluster_start_conf() {
  local value="$1" start_conf="$PG_CONFIG_DIR/start.conf" start_tmp
  [[ "$value" == manual || "$value" == auto ]] || return 1
  [[ -d "$PG_CONFIG_DIR" && ! -L "$PG_CONFIG_DIR" ]] || return 1
  [[ ! -L "$start_conf" ]] || return 1
  start_tmp="$(mktemp "$PG_CONFIG_DIR/.start.conf.XXXXXX")" || return 1
  printf '%s\n' "$value" >"$start_tmp" || return 1
  chown root:root "$start_tmp" || return 1
  chmod 0644 "$start_tmp" || return 1
  mv -fT -- "$start_tmp" "$start_conf" || return 1
  sync -f "$PG_CONFIG_DIR" || return 1
}

verify_database_boot_contract() {
  local start_conf="$PG_CONFIG_DIR/start.conf" generator_root=/run/systemd/generator
  local generator_wants="$generator_root/postgresql.service.wants"
  local instance="postgresql@${PG_VERSION}-${PG_CLUSTER}.service"
  local generator_link="$generator_wants/$instance" fragment='' mode='' unit='' wants=''

  [[ -f "$start_conf" && ! -L "$start_conf" ]] \
    || die 'PostgreSQL start.conf must be a regular, non-symlink file'
  [[ "$(stat -c '%U:%G:%a:%h' -- "$start_conf")" == root:root:644:1 ]] \
    || die 'PostgreSQL start.conf must be root:root 0644 with one hard link'
  cmp -s -- "$start_conf" <(printf 'auto\n') \
    || die 'PostgreSQL start.conf must contain exactly auto and one newline'

  for unit in postgresql.service "$instance"; do
    [[ "$(systemctl show --property=LoadState --value "$unit")" == loaded ]] \
      || die "database boot unit is not loaded: $unit"
    [[ "$(systemctl show --property=UnitFileState --value "$unit")" == enabled ]] \
      || die "database boot unit is not persistently enabled: $unit"
    [[ "$(systemctl show --property=ActiveState --value "$unit")" == active ]] \
      || die "database boot unit is not active: $unit"
  done

  wants=" $(systemctl show --property=Wants --value postgresql.service) "
  [[ "$wants" == *" $instance "* ]] \
    || die 'postgresql.service does not want the 16/main instance from the generator'
  for unit in "$generator_root" "$generator_wants"; do
    [[ -d "$unit" && ! -L "$unit" ]] \
      || die "PostgreSQL generator directory is missing or symlinked: $unit"
    [[ "$(stat -c '%U' -- "$unit")" == root ]] \
      || die "PostgreSQL generator directory is not root-owned: $unit"
    mode="$(stat -c '%a' -- "$unit")"
    (( (8#$mode & 0022) == 0 )) \
      || die "PostgreSQL generator directory is group- or other-writable: $unit"
  done
  [[ -L "$generator_link" && "$(stat -c '%U' -- "$generator_link")" == root ]] \
    || die 'PostgreSQL generator instance dependency is not one root-owned symlink'
  fragment="$(systemctl show --property=FragmentPath --value "$instance")"
  [[ -n "$fragment" && -f "$fragment" ]] \
    || die 'PostgreSQL instance has no loaded fragment path'
  [[ "$(readlink -f -- "$generator_link")" == "$(readlink -f -- "$fragment")" ]] \
    || die 'PostgreSQL generator dependency targets an unexpected unit fragment'
}

fail_close_phase2() {
  local original_status="$?" failed_tmp='' unit_state=''
  local -a containment_problems=()
  trap - EXIT
  if [[ "$phase2_started" == true && "$phase2_complete" != true ]]; then
    set +e
    if [[ -d "$COMMISSIONING_DIR" && ! -L "$COMMISSIONING_DIR" ]]; then
      failed_tmp="$(mktemp "$COMMISSIONING_DIR/.phase2-failed.XXXXXX")"
      if [[ -n "$failed_tmp" ]]; then
        printf 'state=FAILED\nfailed_utc=%s\nexit_status=%s\ncluster=%s/%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$original_status" "$PG_VERSION" "$PG_CLUSTER" >"$failed_tmp" \
          || containment_problems+=(failed-marker-write)
        chown root:root "$failed_tmp" || containment_problems+=(failed-marker-owner)
        chmod 0600 "$failed_tmp" || containment_problems+=(failed-marker-mode)
        mv -fT -- "$failed_tmp" "$PHASE2_FAILED" || containment_problems+=(failed-marker-publish)
        sync -f "$COMMISSIONING_DIR" || containment_problems+=(failed-marker-fsync)
      else
        containment_problems+=(failed-marker-temp)
      fi
    else
      containment_problems+=(commissioning-evidence-directory)
    fi
    set_cluster_start_conf manual || containment_problems+=(cluster-start-conf)
    systemctl daemon-reload >/dev/null 2>&1 \
      || containment_problems+=(postgresql-generator-reload)
    systemctl disable --now uten-pgbackup.timer >/dev/null 2>&1 \
      || containment_problems+=(disable-backup-timer)
    systemctl disable --now "postgresql@${PG_VERSION}-${PG_CLUSTER}.service" postgresql.service >/dev/null 2>&1 \
      || containment_problems+=(disable-postgresql)
    for containment_unit in \
      uten-pgbackup.timer "postgresql@${PG_VERSION}-${PG_CLUSTER}.service" postgresql.service; do
      if systemctl is-active --quiet "$containment_unit" 2>/dev/null; then
        containment_problems+=("active:$containment_unit")
      fi
      unit_state="$(systemctl is-enabled "$containment_unit" 2>/dev/null)"
      case "$unit_state" in
        disabled|masked|not-found) ;;
        *) containment_problems+=("enabled:$containment_unit:$unit_state") ;;
      esac
    done
    unit_state=" $(systemctl show --property=Wants --value postgresql.service 2>/dev/null) "
    [[ "$unit_state" != *" postgresql@${PG_VERSION}-${PG_CLUSTER}.service "* ]] \
      || containment_problems+=(postgresql-generator-dependency-remains)
    if (( ${#containment_problems[@]} == 0 )); then
      printf 'PHASE2_FAILED_CLOSED: PostgreSQL/timer were stopped and disabled; evidence is under %s. Do not delete it or rerun this fresh-host installer.\n' \
        "$COMMISSIONING_DIR" >&2
    else
      printf 'PHASE2_CONTAINMENT_INCOMPLETE: %s. Keep the console open; PostgreSQL/timer shutdown or durable evidence could not be proven.\n' \
        "${containment_problems[*]}" >&2
      original_status=1
    fi
  fi
  exit "$original_status"
}
trap fail_close_phase2 EXIT

pg_createcluster "$PG_VERSION" "$PG_CLUSTER" \
  -d "$PGDATA" --start-conf=manual -- \
  --data-checksums --auth-local=peer --auth-host=scram-sha-256
install -d -m 0750 -o postgres -g postgres "$PGBACKREST_REPO"

echo '==> Apply the reviewed conservative single-host PostgreSQL baseline (16 GiB or more)'
install -d -m 0755 -o postgres -g postgres "$PG_CONFIG_DIR/conf.d"
grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "$PG_CONFIG_DIR/postgresql.conf" \
  || die "$PG_CONFIG_DIR/postgresql.conf does not include conf.d; refusing to install an inactive configuration fragment"
cat >"$PG_CONFIG_DIR/conf.d/90-uten-imp.conf" <<'EOF'
listen_addresses = '127.0.0.1,::1'
port = 5432
ssl = on
shared_buffers = 4GB
effective_cache_size = 12GB
work_mem = 16MB
maintenance_work_mem = 512MB
max_connections = 100
wal_level = replica
wal_keep_size = 2GB
max_slot_wal_keep_size = 16GB
synchronous_standby_names = ''
archive_mode = on
archive_command = 'pgbackrest --stanza=uten-imp archive-push %p'
archive_timeout = 300
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
password_encryption = scram-sha-256
EOF
chown root:postgres "$PG_CONFIG_DIR/conf.d/90-uten-imp.conf"
chmod 0640 "$PG_CONFIG_DIR/conf.d/90-uten-imp.conf"
systemctl daemon-reload
systemctl start "postgresql@${PG_VERSION}-${PG_CLUSTER}.service"
server_version_num="$(runuser -u postgres -- psql -X -At -c 'SHOW server_version_num;')"
(( server_version_num >= 160006 && server_version_num < 170000 )) \
  || die "PostgreSQL 16.6 or newer is required for the reviewed default-role behavior (found $server_version_num)"

echo '==> Create independent PostgreSQL credentials (never printed)'
install -d -m 0750 -o root -g postgres "$SECRETS"
for role in admin repl app migrator; do
  if [[ ! -e "$SECRETS/$role.password" ]]; then
    openssl rand -hex 32 >"$SECRETS/$role.password"
  fi
  [[ -s "$SECRETS/$role.password" ]] || die "missing generated credential: $SECRETS/$role.password"
  chown root:postgres "$SECRETS/$role.password"
  chmod 0640 "$SECRETS/$role.password"
done

admin_password="$(<"$SECRETS/admin.password")"
repl_password="$(<"$SECRETS/repl.password")"
app_password="$(<"$SECRETS/app.password")"
migrator_password="$(<"$SECRETS/migrator.password")"
for generated_password in \
  "$admin_password" "$repl_password" "$app_password" "$migrator_password"; do
  [[ "$generated_password" =~ ^[A-Fa-f0-9]{64}$ ]] \
    || die 'new-cluster generated PostgreSQL passwords must be exactly 64 hexadecimal characters'
done

echo '==> Create owner (NOLOGIN), migrator, runtime app, and replication roles'
install -d -m 0710 -o root -g postgres /run/uten-imp-setup
role_sql_file="$(mktemp /run/uten-imp-setup/phase2-roles.XXXXXX.sql)"
chown postgres:postgres "$role_sql_file"
chmod 0600 "$role_sql_file"
cleanup_role_sql() {
  local original_status="$?"
  local cleanup_failed=false
  trap - EXIT
  if [[ -n "${role_sql_file:-}" ]]; then
    if ! rm -f -- "$role_sql_file"; then
      printf 'ERROR: failed to remove transient PostgreSQL role SQL file: %s\n' "$role_sql_file" >&2
      cleanup_failed=true
    fi
  fi
  [[ "$cleanup_failed" == false ]] || exit 1
  exit "$original_status"
}
trap cleanup_role_sql EXIT
{
  printf "\\set admin_password '%s'\n" "$admin_password"
  printf "\\set repl_password '%s'\n" "$repl_password"
  printf "\\set app_password '%s'\n" "$app_password"
  printf "\\set migrator_password '%s'\n" "$migrator_password"
  cat <<'SQL'
SET log_statement = 'none';
SET log_duration = off;
SET log_min_duration_statement = -1;
ALTER ROLE postgres PASSWORD :'admin_password';
CREATE ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD :'migrator_password';
CREATE ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD :'app_password';
CREATE ROLE uten_repl LOGIN REPLICATION NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'repl_password';
GRANT uten_owner TO uten_migrator;
CREATE DATABASE uten_imp OWNER uten_owner;
REVOKE ALL ON DATABASE uten_imp FROM PUBLIC;
GRANT CONNECT ON DATABASE uten_imp TO uten, uten_migrator;
ALTER ROLE uten_migrator IN DATABASE uten_imp SET role TO 'uten_owner';
\connect uten_imp
ALTER SCHEMA public OWNER TO uten_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO uten;
SQL
} >"$role_sql_file"
runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 --file="$role_sql_file"
rm -f -- "$role_sql_file" || die "failed to remove transient PostgreSQL role SQL file: $role_sql_file"
role_sql_file=''
trap - EXIT
unset admin_password repl_password app_password migrator_password

echo '==> Verify the runtime role has no database or schema DDL authority'
app_password="$(<"$SECRETS/app.password")"
[[ "$app_password" =~ ^[A-Fa-f0-9]{64}$ ]] \
  || die 'runtime app password is not the generated 64-character hexadecimal value'
app_pgpass_file="$(mktemp /run/uten-imp-setup/phase2-app-pgpass.XXXXXX)"
chmod 0600 "$app_pgpass_file"
printf '127.0.0.1:5432:uten_imp:uten:%s\n' "$app_password" >"$app_pgpass_file"
cleanup_app_pgpass() {
  local original_status="$?"
  trap - EXIT
  if [[ -n "${app_pgpass_file:-}" ]] && ! rm -f -- "$app_pgpass_file"; then
    printf 'ERROR: failed to remove transient app pgpass file: %s\n' "$app_pgpass_file" >&2
    exit 1
  fi
  exit "$original_status"
}
trap cleanup_app_pgpass EXIT
runtime_privileges="$(PGPASSFILE="$app_pgpass_file" psql -X -h 127.0.0.1 -p 5432 -U uten -d uten_imp -At -v ON_ERROR_STOP=1 \
  -c "SELECT has_database_privilege(current_user, current_database(), 'CREATE')::int || ':' || has_schema_privilege(current_user, 'public', 'CREATE')::int;")"
rm -f -- "$app_pgpass_file" || die "failed to remove transient app pgpass file: $app_pgpass_file"
app_pgpass_file=''
trap - EXIT
unset app_password
[[ "$runtime_privileges" == '0:0' ]] || die "runtime DB role unexpectedly has DDL privileges: $runtime_privileges"

echo '==> Configure an encrypted local pgBackRest repository with 7 successful full restore points'
install -d -m 0750 -o root -g postgres "$PGBACKREST_SECRETS"
if [[ ! -e "$PGBACKREST_SECRETS/repo1.cipher" ]]; then
  openssl rand -hex 32 >"$PGBACKREST_SECRETS/repo1.cipher"
fi
chown root:postgres "$PGBACKREST_SECRETS/repo1.cipher"
chmod 0640 "$PGBACKREST_SECRETS/repo1.cipher"
repo1_cipher="$(<"$PGBACKREST_SECRETS/repo1.cipher")"
cat >/etc/pgbackrest.conf <<EOF
[global]
repo1-path=$PGBACKREST_REPO
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$repo1_cipher
repo1-retention-full-type=count
repo1-retention-full=7
repo1-retention-archive-type=full
repo1-hardlink=y
repo1-bundle=y
process-max=4
log-level-console=info
log-level-file=detail
start-fast=y
stop-auto=y

[uten-imp]
pg1-path=$PGDATA
pg1-port=5432
EOF
unset repo1_cipher
chmod 0640 /etc/pgbackrest.conf
chown root:postgres /etc/pgbackrest.conf

install -d -m 0700 -o root -g root /etc/uten-imp/templates
cat >/etc/uten-imp/templates/pgbackrest-offsite-repo2.conf.example <<'EOF'
# INACTIVE TEMPLATE ONLY. Do not place this file under pgBackRest's active
# configuration directory until an off-site provider, independent credentials,
# retention, network policy, encryption-key escrow, and a restore drill pass.
# Select a provider supported and tested by the installed pgBackRest version.
#
# repo2-type=s3
# repo2-path=/uten-imp
# repo2-s3-bucket=REPLACE
# repo2-s3-endpoint=REPLACE
# repo2-s3-region=REPLACE
# repo2-s3-key=REPLACE
# repo2-s3-key-secret=REPLACE
# repo2-cipher-type=aes-256-cbc
# repo2-cipher-pass=REPLACE_WITH_INDEPENDENT_ESCROWED_KEY
# repo2-retention-full-type=count
# repo2-retention-full=7
EOF
chmod 0600 /etc/uten-imp/templates/pgbackrest-offsite-repo2.conf.example

echo '==> Create the stanza, check archiving, and take the first full backup'
runuser -u postgres -- pgbackrest --stanza=uten-imp stanza-create
runuser -u postgres -- pgbackrest --stanza=uten-imp check
/usr/bin/python3 -I "$BACKUP_LOCKED_JOB" repo1

echo '==> Install the daily 02:17 backup timer'
cat >/etc/systemd/system/uten-pgbackup.service <<'EOF'
[Unit]
Description=Uten IMP PostgreSQL daily pgBackRest full backup
After=postgresql@16-main.service
OnFailure=uten-pgbackup-alert@%n.service
StartLimitIntervalSec=3h
StartLimitBurst=8
StartLimitAction=none

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/activation-in-progress.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-in-progress.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-pending.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-authorization.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-finalizing.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-onboarding-adoption.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-activation-reauthorization.json
ExecStart=/usr/bin/python3 -I /usr/local/libexec/uten-imp-backup/locked_job.py repo1
Restart=on-failure
RestartPreventExitStatus=78 130 SIGHUP SIGINT SIGQUIT SIGILL SIGABRT SIGBUS SIGFPE SIGKILL SIGSEGV SIGPIPE SIGALRM SIGTERM SIGUSR1 SIGUSR2 SIGXCPU SIGXFSZ SIGVTALRM SIGPROF SIGIO SIGPWR SIGSYS
RestartSec=15m
CapabilityBoundingSet=CAP_SETUID CAP_SETGID
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
TimeoutStartSec=12h
EOF
cat >/etc/systemd/system/uten-pgbackup.timer <<'EOF'
[Unit]
Description=Uten IMP PostgreSQL daily backup timer

[Timer]
OnCalendar=*-*-* 02:17:00
RandomizedDelaySec=10m
Persistent=true
Unit=uten-pgbackup.service

[Install]
WantedBy=timers.target
EOF
for phase2_gate_dir in \
  "/etc/systemd/system/postgresql@${PG_VERSION}-${PG_CLUSTER}.service.d" \
  /etc/systemd/system/uten-pgbackup.service.d \
  /etc/systemd/system/uten-pgbackup.timer.d; do
  [[ ! -e "$phase2_gate_dir" && ! -L "$phase2_gate_dir" ]] \
    || die "unexpected pre-existing Phase 2 systemd gate directory: $phase2_gate_dir"
  install -d -m 0755 -o root -g root "$phase2_gate_dir"
  cat >"$phase2_gate_dir/10-commissioning-state.conf" <<EOF
[Unit]
ConditionPathExists=$PHASE2_COMPLETE
ConditionPathExists=!$PHASE2_IN_PROGRESS
ConditionPathExists=!$PHASE2_FAILED
EOF
  chown root:root "$phase2_gate_dir/10-commissioning-state.conf"
  chmod 0644 "$phase2_gate_dir/10-commissioning-state.conf"
done
systemctl daemon-reload

echo '==> Final local verification'
runuser -u postgres -- psql -X -tAc "SELECT version(); SELECT pg_is_in_recovery(); SHOW data_directory; SHOW ssl;"
runuser -u postgres -- pgbackrest --stanza=uten-imp info
systemctl list-timers uten-pgbackup.timer --no-pager
echo '==> Commit boot enablement only after configuration and the first full backup passed'
set_cluster_start_conf auto || die 'failed to commit PostgreSQL start.conf=auto'
systemctl daemon-reload
systemctl enable postgresql.service "postgresql@${PG_VERSION}-${PG_CLUSTER}.service"
systemctl start postgresql.service
systemctl disable --now uten-pgbackup.timer
sync -f /etc/systemd/system
verify_database_boot_contract
systemctl is-enabled --quiet uten-pgbackup.timer \
  && die 'backup timer must remain disabled until the separate backup commissioner passes'
systemctl is-active --quiet uten-pgbackup.timer \
  && die 'backup timer must remain inactive until the separate backup commissioner passes'
phase2_complete_tmp="$(mktemp "$COMMISSIONING_DIR/.phase2-complete.XXXXXX")"
printf 'state=COMPLETE\ncompleted_utc=%s\ncluster=%s/%s\nbackup_retention_full=7\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PG_VERSION" "$PG_CLUSTER" >"$phase2_complete_tmp"
chown root:root "$phase2_complete_tmp"
chmod 0600 "$phase2_complete_tmp"
sync -f "$phase2_complete_tmp"
mv -fT -- "$phase2_complete_tmp" "$PHASE2_COMPLETE"
sync -f "$COMMISSIONING_DIR"
rm -f -- "$PHASE2_IN_PROGRESS" "$PHASE2_FAILED"
sync -f "$COMMISSIONING_DIR"
phase2_complete=true
trap - EXIT
printf '%s\n' \
  'LOCAL_BACKUP_BASELINE_OK: retention is 7 successful full restore points (count), with required WAL.' \
  'OFFSITE_BACKUP_NOT_CONFIGURED: /data database and repo1 remain one failure domain.' \
  'BACKUP_TIMER_DISABLED: the separate existing-host backup commissioner must prove repo2, retention, alerting, and power-loss recovery before enabling any timer.' \
  'KEY_ESCROW_NOT_COMPLETE: escrow the repo1 cipher key and application PGP/HMAC keys outside this host before production.' \
  'Do not claim disaster recovery until encrypted off-site repo2 and a point-in-time restore drill pass.'
