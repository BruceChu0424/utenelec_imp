#!/usr/bin/env bash
# Non-destructive role/ownership hardening for the already-created 16/main cluster.
# It never drops/restores a database and never runs or edits Flyway migrations.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE

readonly PG_VERSION=16
readonly PG_CLUSTER=main
readonly PGDATA_EXPECTED=/data/postgresql/16/main
readonly DATABASE=uten_imp
readonly SECRETS=/etc/uten-imp-postgres
readonly LEGACY_SECRETS=/etc/uten-imp/postgres-secrets
readonly STANZA=uten-imp
readonly TRUSTED_RELEASE_GUARD=/usr/local/libexec/uten-imp-release/release_guard.py
readonly TRUSTED_RELEASE_ALLOWED_SIGNERS=/etc/uten-imp-release-trust/release-allowed-signers
readonly HARDENING_STATE_DIR=/var/lib/uten-imp-db-hardening
readonly HARDENING_IN_PROGRESS="$HARDENING_STATE_DIR/in-progress"
readonly HARDENING_COMPLETE="$HARDENING_STATE_DIR/complete"

expected_flyway_version=''
max_backup_age_hours=24
allow_audited_nonempty=false
approval_id=''
confirmation=''
expected_release_version=''
trusted_release_manifest=''
trusted_release_signature=''

usage() {
  cat <<'EOF'
Usage:
  sudo bash harden-existing-postgres-roles.sh \
    --expected-flyway-version 289 \
    --expected-release-version v2026.08.14-1 \
    --trusted-release-manifest /root/trusted-release/manifest.json \
    --trusted-release-signature /root/trusted-release/manifest.sig \
    --confirm 'HARDEN uten_imp ON 16/main'

For any non-empty database, a separately reviewed change approval is mandatory:

  sudo bash harden-existing-postgres-roles.sh \
    --expected-flyway-version 289 \
    --expected-release-version v2026.08.14-1 \
    --trusted-release-manifest /root/trusted-release/manifest.json \
    --trusted-release-signature /root/trusted-release/manifest.sig \
    --allow-audited-nonempty \
    --approval-id CHANGE-1234 \
    --confirm 'HARDEN uten_imp ON 16/main'

Options:
  --expected-flyway-version NUMBER  Required exact restored/live Flyway version
  --expected-release-version TAG    Exact signed release version containing the Flyway inventory
  --trusted-release-manifest PATH   Root-controlled signed release manifest
  --trusted-release-signature PATH  Root-controlled detached OpenSSH signature
  --max-backup-age-hours NUMBER      Maximum age of latest good backup (default 24)
  --allow-audited-nonempty           Permit a non-empty DB after approval
  --approval-id ID                   Recorded external approval/change identifier
  --confirm TEXT                     Must exactly match the phrase above
  --help

This changes roles, ownership, grants, and default privileges only. It accepts
no built-in Flyway-version allowlist: the explicit expected head, authenticated
release manifest and live version/script/checksum rows must all match. Historical
baselines still require the separately approved data-migration procedure first.

The audited guard and release trust policy are fixed at
/usr/local/libexec/uten-imp-release/release_guard.py and
/etc/uten-imp-release-trust/release-allowed-signers. Install that trust bootstrap
with bootstrap-release-verifier.sh before running this hardener.
EOF
}

die() {
  printf 'ROLE_HARDENING_REFUSED: %s\n' "$*" >&2
  exit 1
}

secure_root_file() {
  local file_path="$1" label="$2" max_bytes="$3" current_path file_mode file_size
  [[ "$file_path" == /* ]] || die "$label must be an absolute path"
  [[ -f "$file_path" && ! -L "$file_path" ]] \
    || die "$label must be a regular, non-symlink file"
  [[ "$(realpath -e -- "$file_path")" == "$file_path" ]] \
    || die "$label path must be canonical and contain no symlink component"
  current_path="$file_path"
  while :; do
    [[ ! -L "$current_path" ]] || die "$label trust chain contains a symlink: $current_path"
    [[ "$(stat -c '%U' -- "$current_path")" == root ]] \
      || die "$label trust chain is not root-owned: $current_path"
    file_mode="$(stat -c '%a' -- "$current_path")"
    (( (8#$file_mode & 0022) == 0 )) \
      || die "$label trust chain is group- or other-writable: $current_path"
    [[ "$current_path" == / ]] && break
    current_path="$(dirname -- "$current_path")"
  done
  file_size="$(stat -c '%s' -- "$file_path")"
  (( file_size > 0 && file_size <= max_bytes )) || die "$label has an unsafe size"
  printf '%s' "$file_path"
}

require_root_state_file() {
  local state_file="$1"
  secure_root_file "$state_file" 'role-hardening state' 65536 >/dev/null
  [[ -f "$state_file" && ! -L "$state_file" ]] \
    || die "hardening state must be a regular, non-symlink file: $state_file"
  [[ "$(stat -c '%U:%G:%a:%h' -- "$state_file")" == root:root:600:1 ]] \
    || die "hardening state must be root:root mode 0600 with one hard link: $state_file"
}

require_root_directory_chain() {
  local current="$1" directory_mode
  current="$(realpath -e -- "$current")"
  while :; do
    [[ -d "$current" && ! -L "$current" ]] \
      || die "hardening state directory is unsafe: $current"
    [[ "$(stat -c '%U' -- "$current")" == root ]] \
      || die "hardening state directory is not root-owned: $current"
    directory_mode="$(stat -c '%a' -- "$current")"
    (( (8#$directory_mode & 0022) == 0 )) \
      || die "hardening state directory is group/world-writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
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

write_state_atomically() {
  local destination="$1" payload="$2" temporary
  temporary="$(mktemp "$HARDENING_STATE_DIR/.state.XXXXXX")"
  printf '%s\n' "$payload" >"$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  sync -f "$temporary"
  mv -fT -- "$temporary" "$destination"
  fsync_directory "$HARDENING_STATE_DIR"
}

remove_state_durably() {
  local state_file="$1"
  rm -f -- "$state_file"
  fsync_directory "$HARDENING_STATE_DIR"
}

need_value() {
  [[ "$#" -ge 2 ]] || die "missing value for $1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --expected-flyway-version) need_value "$@"; expected_flyway_version="$2"; shift 2 ;;
    --expected-release-version) need_value "$@"; expected_release_version="$2"; shift 2 ;;
    --trusted-release-manifest) need_value "$@"; trusted_release_manifest="$2"; shift 2 ;;
    --trusted-release-signature) need_value "$@"; trusted_release_signature="$2"; shift 2 ;;
    --max-backup-age-hours) need_value "$@"; max_backup_age_hours="$2"; shift 2 ;;
    --allow-audited-nonempty) allow_audited_nonempty=true; shift ;;
    --approval-id) need_value "$@"; approval_id="$2"; shift 2 ;;
    --confirm) need_value "$@"; confirmation="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute hardener through a symlink'
readonly SCRIPT_FILE="$(realpath -e -- "${BASH_SOURCE[0]}")"
secure_root_file "$SCRIPT_FILE" 'role hardener installer' 2097152 >/dev/null
[[ "$expected_flyway_version" =~ ^[1-9][0-9]*$ ]] \
  || die '--expected-flyway-version must be a positive integer without a leading zero'
[[ "$expected_release_version" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[1-9][0-9]{0,2}$ ]] \
  || die '--expected-release-version must be one canonical signed release tag'
[[ -n "$trusted_release_manifest" && -n "$trusted_release_signature" ]] \
  || die 'both trusted release manifest and signature paths are required'
[[ "$max_backup_age_hours" =~ ^[1-9][0-9]*$ ]] || die '--max-backup-age-hours must be a positive integer'
(( max_backup_age_hours <= 168 )) || die '--max-backup-age-hours may not exceed 168'
[[ "$confirmation" == 'HARDEN uten_imp ON 16/main' ]] \
  || die "explicit confirmation is required: --confirm 'HARDEN uten_imp ON 16/main'"
if [[ "$allow_audited_nonempty" == true ]]; then
  [[ "$approval_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$ ]] \
    || die '--approval-id is required and must be a durable external change identifier'
else
  [[ -z "$approval_id" ]] || die '--approval-id requires --allow-audited-nonempty'
fi

for command_name in pg_lsclusters psql pgbackrest jq realpath mountpoint runuser openssl \
  python3 ssh-keygen stat readlink dirname sha256sum sync; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
postgres_uid="$(id -u postgres 2>/dev/null)" || die 'postgres service account is missing'
postgres_gid="$(id -g postgres 2>/dev/null)" || die 'postgres primary group is missing'
[[ "$postgres_uid" =~ ^[0-9]+$ && "$postgres_uid" != 0 \
  && "$postgres_gid" =~ ^[0-9]+$ && "$postgres_gid" != 0 ]] \
  || die 'postgres must use non-root numeric UID/GID values'
postgres_uid_names="$(getent passwd | awk -F: -v uid="$postgres_uid" '$3 == uid {print $1}')"
[[ "$postgres_uid_names" == postgres ]] \
  || die 'postgres numeric UID must map to exactly one passwd name'
postgres_gid_names="$(getent group | awk -F: -v gid="$postgres_gid" '$3 == gid {print $1}')"
[[ "$postgres_gid_names" == postgres ]] \
  || die 'postgres numeric GID must map to exactly one group name'
postgres_group_record="$(getent group postgres)" || die 'postgres group record is missing'
IFS=: read -r _ _ _ postgres_explicit_members <<<"$postgres_group_record"
[[ -z "$postgres_explicit_members" || "$postgres_explicit_members" == postgres ]] \
  || die 'postgres group contains another explicit member that could read database secrets'
postgres_primary_names="$(getent passwd | awk -F: -v gid="$postgres_gid" '$4 == gid {print $1}')"
[[ "$postgres_primary_names" == postgres ]] \
  || die 'postgres group must be the primary group of exactly the postgres account'
trusted_release_manifest="$(secure_root_file "$trusted_release_manifest" 'trusted release manifest' 2097152)"
trusted_release_signature="$(secure_root_file "$trusted_release_signature" 'trusted release signature' 65536)"
trusted_release_allowed_signers="$(secure_root_file "$TRUSTED_RELEASE_ALLOWED_SIGNERS" 'fixed trusted release allowed_signers policy' 1048576)"
trusted_release_guard="$(secure_root_file "$TRUSTED_RELEASE_GUARD" 'fixed trusted audited release guard' 2097152)"
mountpoint --quiet /data || die '/data is not the required mounted filesystem'
[[ -d "$PGDATA_EXPECTED" && ! -L "$PGDATA_EXPECTED" ]] \
  || die "$PGDATA_EXPECTED must be a real directory"

cluster_lines="$(pg_lsclusters --no-header 2>/dev/null || true)"
cluster_count="$(awk '$1 == "16" && $2 == "main" { n++ } END { print n + 0 }' <<<"$cluster_lines")"
[[ "$cluster_count" == 1 ]] || die 'expected exactly one 16/main cluster'
total_cluster_count="$(awk 'NF { n++ } END { print n + 0 }' <<<"$cluster_lines")"
[[ "$total_cluster_count" == 1 ]] || die 'this dedicated-host procedure refuses to run when any additional PostgreSQL cluster exists'
cluster_port="$(awk '$1 == "16" && $2 == "main" { print $3 }' <<<"$cluster_lines")"
cluster_status="$(awk '$1 == "16" && $2 == "main" { print $4 }' <<<"$cluster_lines")"
cluster_owner="$(awk '$1 == "16" && $2 == "main" { print $5 }' <<<"$cluster_lines")"
cluster_data_dir="$(awk '$1 == "16" && $2 == "main" { print $6 }' <<<"$cluster_lines")"
[[ "$cluster_status" == online ]] || die "16/main must be online (found $cluster_status)"
[[ "$cluster_port" == 5432 ]] || die "16/main port must be 5432 (found $cluster_port)"
[[ "$cluster_owner" == postgres ]] || die "16/main owner must be postgres (found $cluster_owner)"
[[ "$(realpath -- "$cluster_data_dir")" == "$(realpath -- "$PGDATA_EXPECTED")" ]] \
  || die "16/main data directory is $cluster_data_dir, expected $PGDATA_EXPECTED"

maintenance_units=(
  nginx.service
  uten-imp-migrate.service
  uten-imp.service
  uten-imp-watchdog.service
  uten-imp-watchdog.timer
  uten-imp-entry-watchdog.service
  uten-imp-entry-watchdog.timer
)
for maintenance_unit in "${maintenance_units[@]}"; do
  if systemctl is-active --quiet "$maintenance_unit" 2>/dev/null; then
    die "maintenance unit must be inactive before role hardening: $maintenance_unit"
  fi
  if systemctl is-enabled --quiet "$maintenance_unit" 2>/dev/null; then
    die "maintenance unit must be disabled before role hardening: $maintenance_unit"
  fi
done

psql_admin() {
  runuser -u postgres -- psql -X -h /var/run/postgresql -p 5432 \
    -d "$DATABASE" -At -v ON_ERROR_STOP=1 -c "$1"
}

server_version_num="$(psql_admin 'SHOW server_version_num;')"
(( server_version_num >= 160006 && server_version_num < 170000 )) \
  || die "server_version_num must be PostgreSQL 16.6 or newer (found $server_version_num)"
[[ "$(psql_admin 'SELECT current_database();')" == "$DATABASE" ]] \
  || die "connected database is not $DATABASE"
[[ "$(realpath -- "$(psql_admin 'SHOW data_directory;')")" == "$(realpath -- "$PGDATA_EXPECTED")" ]] \
  || die 'server-reported data_directory does not match the approved path'
[[ "$(psql_admin 'SELECT pg_is_in_recovery()::int;')" == 0 ]] \
  || die 'role hardening is forbidden on a standby/in-recovery server'
[[ "$(psql_admin "SELECT count(*) FROM pg_stat_activity WHERE datname='$DATABASE' AND pid <> pg_backend_pid();")" == 0 ]] \
  || die 'other uten_imp sessions are active; stop and drain all clients first'
[[ "$(psql_admin "SELECT count(*) FROM pg_roles WHERE rolname='uten';")" == 1 ]] \
  || die 'existing runtime role uten is missing'
[[ ! -e "$LEGACY_SECRETS" && ! -L "$LEGACY_SECRETS" ]] \
  || die "legacy secret path remains at $LEGACY_SECRETS; run the separately confirmed secret-path migration first"
[[ -d "$SECRETS" && ! -L "$SECRETS" ]] || die "$SECRETS must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$SECRETS")" == root:postgres:750 ]] \
  || die "$SECRETS must be root:postgres mode 0750"
[[ -f "$SECRETS/app.password" && ! -L "$SECRETS/app.password" ]] \
  || die "$SECRETS/app.password must be a regular file"
[[ "$(stat -c '%U:%G:%a' "$SECRETS/app.password")" == root:postgres:640 ]] \
  || die "$SECRETS/app.password must be root:postgres mode 0640"

[[ "$(psql_admin "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL;")" == t ]] \
  || die 'flyway_schema_history is missing'
[[ "$(psql_admin 'SELECT count(*) FROM flyway_schema_history WHERE success IS DISTINCT FROM true;')" == 0 ]] \
  || die 'Flyway history contains a failed or indeterminate row'
invalid_successful_history_count="$(psql_admin "SELECT count(*) FROM flyway_schema_history WHERE success AND (version IS NULL OR version !~ '^[1-9][0-9]*$' OR checksum IS NULL OR type IS DISTINCT FROM 'SQL');")"
[[ "$invalid_successful_history_count" == 0 ]] \
  || die 'Flyway history contains a successful repeatable/non-SQL row, a null version/checksum, or a non-canonical version'
duplicate_successful_history_count="$(psql_admin "SELECT count(*) FROM (SELECT version FROM flyway_schema_history WHERE success GROUP BY version HAVING count(*) <> 1 UNION ALL SELECT script FROM flyway_schema_history WHERE success GROUP BY script HAVING count(*) <> 1) AS duplicates;")"
[[ "$duplicate_successful_history_count" == 0 ]] \
  || die 'Flyway history contains a duplicate successful version or script'
live_flyway_version="$(psql_admin "SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1;")"
[[ "$live_flyway_version" == "$expected_flyway_version" ]] \
  || die "live Flyway version is $live_flyway_version, expected $expected_flyway_version"
successful_migration_count="$(psql_admin 'SELECT count(*) FROM flyway_schema_history WHERE success AND version IS NOT NULL;')"
successful_history_count="$(psql_admin 'SELECT count(*) FROM flyway_schema_history WHERE success;')"

echo '==> Verify the signed release key, manifest, and exact Flyway version/script/checksum inventory'
if ! trusted_manifest_rows_data="$(/usr/bin/python3 -I "$trusted_release_guard" \
  verified-flyway-checksums \
  --manifest "$trusted_release_manifest" \
  --signature "$trusted_release_signature" \
  --allowed-signers "$trusted_release_allowed_signers" \
  --expected-version "$expected_release_version")"; then
  die 'release guard rejected the signature, claimed signing key, manifest, or Flyway inventory'
fi
if ! manifest_summary="$(LC_ALL=C awk -F '\t' '
  NF != 3 { exit 10 }
  $1 !~ /^[1-9][0-9]*$/ { exit 11 }
  $2 !~ /^V[0-9]+__[A-Za-z0-9_]+[.]sql$/ { exit 12 }
  $3 !~ /^-?[0-9]+$/ || $3 < -2147483648 || $3 > 2147483647 { exit 13 }
  {
    file_version = $2
    sub(/^V/, "", file_version)
    sub(/__.*/, "", file_version)
    if ((file_version + 0) != ($1 + 0)) exit 14
    if (seen_version[$1]++ || seen_file[$2]++) exit 15
    if (count > 0 && ($1 + 0) <= previous_version) exit 16
    previous_version = ($1 + 0)
    count++
  }
  END {
    if (count < 1) exit 17
    printf "%d\t%d\n", count, previous_version
  }
' <<<"$trusted_manifest_rows_data")"; then
  die 'release guard emitted a non-canonical Flyway checksum inventory'
fi
IFS=$'\t' read -r trusted_manifest_count trusted_manifest_max_version <<<"$manifest_summary"
[[ "$trusted_manifest_max_version" == "$expected_flyway_version" ]] \
  || die 'signed Flyway inventory head does not match the explicitly approved head'
[[ "$successful_migration_count" == "$trusted_manifest_count" ]] \
  || die "live Flyway versioned-row count differs from the authenticated release manifest (live=$successful_migration_count, signed=$trusted_manifest_count)"
[[ "$successful_history_count" == "$trusted_manifest_count" ]] \
  || die "Flyway history contains an unenumerated successful row (total=$successful_history_count, signed=$trusted_manifest_count)"
expected_migration_count="$trusted_manifest_count"
live_flyway_rows="$(psql_admin "SELECT version || E'\\t' || script || E'\\t' || checksum::text FROM flyway_schema_history WHERE success AND version IS NOT NULL AND checksum IS NOT NULL ORDER BY version::integer;")"
[[ "$live_flyway_rows" == "$trusted_manifest_rows_data" ]] \
  || die 'live Flyway version/script/checksum rows differ from the authenticated release manifest'
unset live_flyway_rows trusted_manifest_rows_data manifest_summary

required_business_tables=(goods sales_orders stock_movements ar_ap_ledger gl_entries)
if (( expected_flyway_version >= 240 )); then
  required_business_tables+=(attachments)
fi
if (( expected_flyway_version >= 251 )); then
  required_business_tables+=(goods_import_batches goods_import_creations)
fi
if (( expected_flyway_version >= 275 )); then
  required_business_tables+=(system_master_category_registry)
fi
if (( expected_flyway_version >= 279 )); then
  required_business_tables+=(
    business_identifier_namespaces
    business_identifier_reservations
    business_identifier_conflicts
  )
fi
if (( expected_flyway_version >= 285 )); then
  required_business_tables+=(client_default_settlement_migration_issues)
fi
if (( expected_flyway_version >= 288 )); then
  required_business_tables+=(production_material_analysis_borrows)
fi
for table_name in "${required_business_tables[@]}"; do
  [[ "$(psql_admin "SELECT to_regclass('public.$table_name') IS NOT NULL;")" == t ]] \
    || die "required business table is missing: $table_name"
done
if (( expected_flyway_version >= 289 )); then
  borrow_trigger_count="$(psql_admin "SELECT count(*) FROM pg_trigger WHERE tgrelid='production_material_analysis_borrows'::regclass AND NOT tgisinternal AND tgname IN ('trg_guard_production_material_analysis_borrow_mutation','trg_set_updated_at_production_material_analysis_borrows','trg_validate_pma_borrow_endpoint','trg_audit_production_material_analysis_borrows');")"
  [[ "$borrow_trigger_count" == 4 ]] \
    || die 'V289 production material-analysis borrow guards/audit are incomplete'
fi
business_rows="$(psql_admin 'SELECT
  (SELECT count(*) FROM goods) +
  (SELECT count(*) FROM sales_orders) +
  (SELECT count(*) FROM stock_movements) +
  (SELECT count(*) FROM ar_ap_ledger) +
  (SELECT count(*) FROM gl_entries);')"
if (( business_rows > 0 )); then
  [[ "$allow_audited_nonempty" == true ]] \
    || die "database is non-empty (business rows=$business_rows, V$expected_flyway_version); separate approval is required"
fi

backup_json="$(runuser -u postgres -- pgbackrest --stanza="$STANZA" --output=json info)"
backup_status_code="$(jq -er --arg stanza "$STANZA" '.[] | select(.name == $stanza) | .status.code' <<<"$backup_json")" \
  || die 'cannot read pgBackRest stanza status'
[[ "$backup_status_code" == 0 ]] || die "pgBackRest stanza status is not OK (code $backup_status_code)"
latest_backup_stop="$(jq -er --arg stanza "$STANZA" \
  '[.[] | select(.name == $stanza) | .backup[]? | select(.error != true) | .timestamp.stop] | max | select(. != null)' \
  <<<"$backup_json")" || die 'no successful pgBackRest backup was found'
now_epoch="$(date +%s)"
(( latest_backup_stop <= now_epoch + 300 )) || die 'latest backup timestamp is unexpectedly in the future'
backup_age_seconds=$((now_epoch - latest_backup_stop))
(( backup_age_seconds <= max_backup_age_hours * 3600 )) \
  || die "latest successful backup is older than $max_backup_age_hours hours"

if [[ -e "$HARDENING_STATE_DIR" || -L "$HARDENING_STATE_DIR" ]]; then
  [[ -d "$HARDENING_STATE_DIR" && ! -L "$HARDENING_STATE_DIR" ]] \
    || die "$HARDENING_STATE_DIR must be a real directory"
  [[ "$(stat -c '%U:%G:%a' -- "$HARDENING_STATE_DIR")" == root:root:700 ]] \
    || die "$HARDENING_STATE_DIR must be root:root mode 0700"
else
  install -d -m 0700 -o root -g root "$HARDENING_STATE_DIR"
  fsync_directory /var/lib
fi
require_root_directory_chain "$HARDENING_STATE_DIR"
manifest_sha256="$(sha256sum -- "$trusted_release_manifest" | awk '{print $1}')"
signature_sha256="$(sha256sum -- "$trusted_release_signature" | awk '{print $1}')"
state_approval_id="${approval_id:-EMPTY_CANDIDATE_PATH}"
hardening_state_payload="$(printf '%s\n' \
  'schemaVersion=2' \
  'database=uten_imp' \
  'cluster=16/main' \
  "expectedReleaseVersion=$expected_release_version" \
  "expectedFlywayVersion=$expected_flyway_version" \
  "expectedMigrationCount=$expected_migration_count" \
  "manifestSha256=$manifest_sha256" \
  "signatureSha256=$signature_sha256" \
  "approvalId=$state_approval_id")"

if [[ -e "$HARDENING_COMPLETE" || -L "$HARDENING_COMPLETE" ]]; then
  require_root_state_file "$HARDENING_COMPLETE"
  [[ "$(<"$HARDENING_COMPLETE")" == "$hardening_state_payload" ]] \
    || die 'a different role-hardening completion is already recorded; use a separately reviewed drift procedure'
  ddl_flags="$(psql_admin "SELECT
    has_database_privilege('uten', 'uten_imp', 'CREATE')::int || ':' ||
    has_schema_privilege('uten', 'public', 'CREATE')::int || ':' ||
    pg_has_role('uten', 'uten_owner', 'MEMBER')::int;")"
  [[ "$ddl_flags" == '0:0:0' ]] || die "completed-state app DDL verification failed: $ddl_flags"
  [[ "$(psql_admin "SELECT has_table_privilege('uten', 'flyway_schema_history', 'INSERT,UPDATE,DELETE')::int;")" == 0 ]] \
    || die 'completed-state runtime app role can mutate flyway_schema_history'
  psql_admin 'ALTER ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;' >/dev/null
  [[ "$(psql_admin "SELECT rolcanlogin::int FROM pg_roles WHERE rolname='uten';")" == 1 ]] \
    || die 'completed hardening could not restore the runtime role login state'
  if [[ -e "$HARDENING_IN_PROGRESS" || -L "$HARDENING_IN_PROGRESS" ]]; then
    require_root_state_file "$HARDENING_IN_PROGRESS"
    [[ "$(<"$HARDENING_IN_PROGRESS")" == "$hardening_state_payload" ]] \
      || die 'in-progress hardening evidence differs from the completed evidence'
    remove_state_durably "$HARDENING_IN_PROGRESS"
  fi
  printf '%s\n' 'EXISTING_CLUSTER_ROLE_HARDENING_ALREADY_COMPLETE'
  exit 0
fi

if [[ -e "$HARDENING_IN_PROGRESS" || -L "$HARDENING_IN_PROGRESS" ]]; then
  require_root_state_file "$HARDENING_IN_PROGRESS"
  [[ "$(<"$HARDENING_IN_PROGRESS")" == "$hardening_state_payload" ]] \
    || die 'an interrupted role-hardening operation has different signed evidence; keep the app offline and investigate'
else
  write_state_atomically "$HARDENING_IN_PROGRESS" "$hardening_state_payload"
fi

# This is deliberately committed outside the ownership transaction. Other
# sessions must observe NOLOGIN before the final drain and DDL changes begin.
psql_admin 'ALTER ROLE uten NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;' >/dev/null
[[ "$(psql_admin "SELECT rolcanlogin::int FROM pg_roles WHERE rolname='uten';")" == 0 ]] \
  || die 'runtime role did not enter the persistent NOLOGIN maintenance state'
psql_admin "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname=current_database() AND pid <> pg_backend_pid();" >/dev/null
[[ "$(psql_admin "SELECT count(*) FROM pg_stat_activity WHERE datname='$DATABASE' AND pid <> pg_backend_pid();")" == 0 ]] \
  || die 'database sessions remain after the persistent NOLOGIN maintenance gate'

install -d -m 0750 -o root -g postgres "$SECRETS"
[[ ! -L "$SECRETS/migrator.password" ]] \
  || die "$SECRETS/migrator.password must not be a symlink"
if [[ -e "$SECRETS/migrator.password" ]]; then
  [[ -f "$SECRETS/migrator.password" ]] \
    || die "$SECRETS/migrator.password must be a regular file"
  [[ "$(stat -c '%U:%G:%a' "$SECRETS/migrator.password")" == root:postgres:640 ]] \
    || die "$SECRETS/migrator.password must already be root:postgres mode 0640"
fi
if [[ ! -s "$SECRETS/migrator.password" ]]; then
  openssl rand -hex 32 >"$SECRETS/migrator.password"
fi
chown root:postgres "$SECRETS/migrator.password"
chmod 0640 "$SECRETS/migrator.password"
migrator_password="$(<"$SECRETS/migrator.password")"
[[ "$migrator_password" =~ ^[A-Za-z0-9]{20,512}$ ]] \
  || die 'migrator password is not safe for the protected SQL input path; use a separately approved transactional password rotation'

printf '==> Apply transactional role hardening to %s V%s (business rows=%s)\n' \
  "$DATABASE" "$live_flyway_version" "$business_rows"
install -d -m 0710 -o root -g postgres /run/uten-imp-setup
role_sql_file="$(mktemp /run/uten-imp-setup/existing-role-hardening.XXXXXX.sql)"
chown postgres:postgres "$role_sql_file"
chmod 0600 "$role_sql_file"
cleanup_role_sql() {
  local original_status="$?"
  local cleanup_failed=false
  trap - EXIT
  if [[ -n "${role_sql_file:-}" ]]; then
    if ! rm -f -- "$role_sql_file"; then
      printf 'ROLE_HARDENING_CLEANUP_FAILED: transient SQL file remains at %s\n' "$role_sql_file" >&2
      cleanup_failed=true
    fi
  fi
  [[ "$cleanup_failed" == false ]] || exit 1
  exit "$original_status"
}
trap cleanup_role_sql EXIT
{
  printf "\\set migrator_password '%s'\n" "$migrator_password"
  cat <<'SQL'
SET log_statement = 'none';
SET log_duration = off;
SET log_min_duration_statement = -1;
BEGIN;
DO $$
BEGIN
  IF EXISTS (
    SELECT FROM pg_stat_activity
    WHERE datname = current_database() AND pid <> pg_backend_pid()
  ) THEN
    RAISE EXCEPTION 'other uten_imp sessions appeared after the preflight drain check';
  END IF;
END
$$;
SELECT 'CREATE ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION'
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'uten_owner') \gexec
SELECT format(
  'CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
  :'migrator_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'uten_migrator') \gexec
ALTER ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'migrator_password';
REVOKE uten_owner FROM uten;
GRANT uten_owner TO uten_migrator;
REASSIGN OWNED BY uten TO uten_owner;
REASSIGN OWNED BY uten_migrator TO uten_owner;
ALTER DATABASE uten_imp OWNER TO uten_owner;
REVOKE ALL ON DATABASE uten_imp FROM PUBLIC;
REVOKE ALL ON DATABASE uten_imp FROM uten;
GRANT CONNECT ON DATABASE uten_imp TO uten, uten_migrator;
ALTER ROLE uten_migrator IN DATABASE uten_imp SET role TO 'uten_owner';
ALTER SCHEMA public OWNER TO uten_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM uten;
GRANT USAGE ON SCHEMA public TO uten;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM uten;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO uten;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM uten;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO uten;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM uten;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO uten;
REVOKE ALL ON TABLE flyway_schema_history FROM uten;
COMMIT;
SQL
} >"$role_sql_file"
runuser -u postgres -- psql -X -q -h /var/run/postgresql -p 5432 \
  -d "$DATABASE" -v ON_ERROR_STOP=1 --file="$role_sql_file"
rm -f -- "$role_sql_file" \
  || die "failed to remove transient PostgreSQL role SQL file: $role_sql_file"
role_sql_file=''
trap - EXIT
unset migrator_password

ddl_flags="$(psql_admin "SELECT
  has_database_privilege('uten', 'uten_imp', 'CREATE')::int || ':' ||
  has_schema_privilege('uten', 'public', 'CREATE')::int || ':' ||
  pg_has_role('uten', 'uten_owner', 'MEMBER')::int;")"
[[ "$ddl_flags" == '0:0:0' ]] || die "post-change app DDL verification failed: $ddl_flags"
flyway_access="$(psql_admin "SELECT has_table_privilege('uten', 'flyway_schema_history', 'INSERT,UPDATE,DELETE')::int;")"
[[ "$flyway_access" == 0 ]] || die 'runtime app role can still mutate flyway_schema_history'

# Persist successful postconditions before restoring login. A crash before this
# point leaves the application role NOLOGIN; a crash after it is safely
# resumable from the exact signed evidence above.
write_state_atomically "$HARDENING_COMPLETE" "$hardening_state_payload"
psql_admin 'ALTER ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;' >/dev/null
[[ "$(psql_admin "SELECT rolcanlogin::int FROM pg_roles WHERE rolname='uten';")" == 1 ]] \
  || die 'runtime role could not leave the persistent NOLOGIN maintenance state'
remove_state_durably "$HARDENING_IN_PROGRESS"

printf '%s\n' \
  'EXISTING_CLUSTER_ROLE_HARDENING_OK' \
  "approval_id=${approval_id:-EMPTY_CANDIDATE_PATH}" \
  'The runtime DB role has no DDL. Phase3 must still create and validate the dedicated uten-imp-migrate process environment.' \
  'Never copy migrator.password into /etc/uten-imp/server.env; the backend must keep SPRING_FLYWAY_ENABLED=false.'
