#!/usr/bin/env bash
# Prepare the on-premises PostgreSQL primary for one-way physical streaming
# replication. Run this script on the primary host as the PostgreSQL service
# account. Secrets are read from files and are never placed in process argv.
set -Eeuo pipefail
umask 077

readonly MANAGED_HBA_BEGIN="# BEGIN UTEN IMP MANAGED REPLICATION ACCESS"
readonly MANAGED_HBA_END="# END UTEN IMP MANAGED REPLICATION ACCESS"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_identifier() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
    die "$label must match ^[a-z_][a-z0-9_]{0,62}$"
}

require_cidr() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] ||
    die "$label must be one explicit IPv4/IPv6 CIDR without whitespace"
}

read_secret() {
  local label="$1" path="$2" value
  [[ -f "$path" && -r "$path" ]] || die "$label file is not a readable regular file: $path"
  value="$(<"$path")"
  [[ ${#value} -ge 16 ]] || die "$label must contain at least 16 characters"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label must be exactly one line"
  printf '%s' "$value"
}

canonical_existing_path() {
  local path="$1"
  realpath -e -- "$path"
}

pgpass_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//:/\\:}"
  printf '%s' "$value"
}

require_command psql
require_command realpath
require_command mktemp
require_command awk

: "${PRIMARY_PGDATA:?set PRIMARY_PGDATA to the exact running primary data directory}"
: "${PRIMARY_PG_HBA_FILE:?set PRIMARY_PG_HBA_FILE to the exact pg_hba.conf used by that primary}"
: "${ADMIN_PASSWORD_FILE:?set ADMIN_PASSWORD_FILE to a root-readable/admin-only secret file}"
: "${REPL_PASSWORD_FILE:?set REPL_PASSWORD_FILE to a different secret file}"
: "${APP_PASSWORD_FILE:?set APP_PASSWORD_FILE to a different secret file}"
: "${REPLICATION_CIDR:?set REPLICATION_CIDR to the current replica host/CIDR}"
: "${CLOUD_APP_CIDR:?set CLOUD_APP_CIDR to the cloud application host/CIDR}"
: "${ON_PREM_REPLICA_CIDR:?set ON_PREM_REPLICA_CIDR to the on-premises host/CIDR that may be rebuilt as a standby after failover}"
: "${ON_PREM_APP_CIDR:?set ON_PREM_APP_CIDR to the on-premises application host/CIDR used after failover}"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-postgres}"
PGUSER="${PGUSER:-postgres}"
PGSSLMODE="${PGSSLMODE:-verify-full}"
PGSSLROOTCERT="${PGSSLROOTCERT:-}"
REPL_USER="${REPL_USER:-uten_repl}"
APP_USER="${APP_USER:-uten}"
APP_DATABASE="${APP_DATABASE:-uten_imp}"
SLOT_NAME="${SLOT_NAME:-uten_cloud_replica}"
APPLICATION_NAME="${APPLICATION_NAME:-uten_cloud_replica}"
HBA_RECORD_TYPE="${HBA_RECORD_TYPE:-hostssl}"
WAL_KEEP_SIZE="${WAL_KEEP_SIZE:-2GB}"
MAX_SLOT_WAL_KEEP_SIZE="${MAX_SLOT_WAL_KEEP_SIZE:-16GB}"
MAX_WAL_SENDERS="${MAX_WAL_SENDERS:-10}"
MAX_REPLICATION_SLOTS="${MAX_REPLICATION_SLOTS:-10}"
ALLOW_INSECURE_TESTING="${ALLOW_INSECURE_TESTING:-no}"
RECREATE_INVALID_SLOT="${RECREATE_INVALID_SLOT:-no}"

require_identifier REPL_USER "$REPL_USER"
require_identifier APP_USER "$APP_USER"
require_identifier APP_DATABASE "$APP_DATABASE"
require_identifier SLOT_NAME "$SLOT_NAME"
require_identifier APPLICATION_NAME "$APPLICATION_NAME"
[[ "$PGUSER" != "$REPL_USER" && "$PGUSER" != "$APP_USER" && "$REPL_USER" != "$APP_USER" ]] ||
  die "admin, replication and application role names must be distinct"
require_cidr REPLICATION_CIDR "$REPLICATION_CIDR"
require_cidr CLOUD_APP_CIDR "$CLOUD_APP_CIDR"
require_cidr ON_PREM_REPLICA_CIDR "$ON_PREM_REPLICA_CIDR"
require_cidr ON_PREM_APP_CIDR "$ON_PREM_APP_CIDR"
[[ "$PGPORT" =~ ^[0-9]{1,5}$ ]] || die "PGPORT must be numeric"
[[ "$WAL_KEEP_SIZE" =~ ^[1-9][0-9]*(MB|GB)$ ]] || die "WAL_KEEP_SIZE must be a positive MB or GB value"
[[ "$MAX_SLOT_WAL_KEEP_SIZE" =~ ^[1-9][0-9]*(MB|GB)$ ]] ||
  die "MAX_SLOT_WAL_KEEP_SIZE must be finite and expressed in MB or GB"
[[ "$MAX_WAL_SENDERS" =~ ^[1-9][0-9]*$ ]] || die "MAX_WAL_SENDERS must be positive"
[[ "$MAX_REPLICATION_SLOTS" =~ ^[1-9][0-9]*$ ]] || die "MAX_REPLICATION_SLOTS must be positive"
[[ "$HBA_RECORD_TYPE" == "hostssl" || "$HBA_RECORD_TYPE" == "host" ]] ||
  die "HBA_RECORD_TYPE must be hostssl (production) or host (isolated test only)"
[[ "$RECREATE_INVALID_SLOT" == "yes" || "$RECREATE_INVALID_SLOT" == "no" ]] ||
  die "RECREATE_INVALID_SLOT must be yes or no"

[[ "$PGSSLMODE" == "verify-full" || "$PGSSLMODE" == "disable" ]] ||
  die "PGSSLMODE must be verify-full in production (disable is isolated-test only)"
if [[ "$PGSSLMODE" == "disable" || "$HBA_RECORD_TYPE" == "host" ]]; then
  [[ "$ALLOW_INSECURE_TESTING" == "yes" ]] ||
    die "unencrypted PostgreSQL access is allowed only with ALLOW_INSECURE_TESTING=yes"
fi
if [[ "$PGSSLMODE" == "verify-full" ]]; then
  [[ -f "$PGSSLROOTCERT" ]] || die "PGSSLROOTCERT is required for PGSSLMODE=verify-full"
fi

[[ ! -L "$PRIMARY_PGDATA" ]] || die "PRIMARY_PGDATA must not be a symlink"
[[ ! -L "$PRIMARY_PG_HBA_FILE" ]] || die "PRIMARY_PG_HBA_FILE must not be a symlink"
PRIMARY_PGDATA="$(canonical_existing_path "$PRIMARY_PGDATA")"
PRIMARY_PG_HBA_FILE="$(canonical_existing_path "$PRIMARY_PG_HBA_FILE")"
[[ -f "$PRIMARY_PGDATA/PG_VERSION" ]] || die "PRIMARY_PGDATA has no PG_VERSION: $PRIMARY_PGDATA"
[[ "$(<"$PRIMARY_PGDATA/PG_VERSION")" == "16" ]] || die "only PostgreSQL 16 is supported"
[[ -w "$PRIMARY_PG_HBA_FILE" ]] || die "pg_hba.conf is not writable by the current service account"

ADMIN_PASSWORD="$(read_secret ADMIN_PASSWORD "$ADMIN_PASSWORD_FILE")"
REPL_PASSWORD="$(read_secret REPL_PASSWORD "$REPL_PASSWORD_FILE")"
APP_PASSWORD="$(read_secret APP_PASSWORD "$APP_PASSWORD_FILE")"
[[ "$ADMIN_PASSWORD" != "$REPL_PASSWORD" ]] || die "admin and replication passwords must differ"
[[ "$ADMIN_PASSWORD" != "$APP_PASSWORD" ]] || die "admin and application passwords must differ"
[[ "$REPL_PASSWORD" != "$APP_PASSWORD" ]] || die "replication and application passwords must differ"

PGPASSFILE="$(mktemp)"
HBA_TEMP=""
cleanup() {
  unset ADMIN_PASSWORD REPL_PASSWORD APP_PASSWORD UTEN_REPL_PASSWORD UTEN_APP_PASSWORD
  [[ -z "$HBA_TEMP" || ! -e "$HBA_TEMP" ]] || rm -f -- "$HBA_TEMP"
  [[ ! -e "$PGPASSFILE" ]] || rm -f -- "$PGPASSFILE"
}
trap cleanup EXIT

printf '%s:%s:%s:%s:%s\n' \
  "$(pgpass_escape "$PGHOST")" \
  "$(pgpass_escape "$PGPORT")" \
  "$(pgpass_escape "$PGDATABASE")" \
  "$(pgpass_escape "$PGUSER")" \
  "$(pgpass_escape "$ADMIN_PASSWORD")" >"$PGPASSFILE"
chmod 0600 "$PGPASSFILE"
export PGPASSFILE PGSSLMODE
[[ -z "$PGSSLROOTCERT" ]] || export PGSSLROOTCERT

PSQL=(psql --no-password --host "$PGHOST" --port "$PGPORT" --username "$PGUSER" --dbname "$PGDATABASE" -X -v ON_ERROR_STOP=1)

SERVER_PGDATA="$("${PSQL[@]}" -Atqc 'SHOW data_directory')"
SERVER_HBA="$("${PSQL[@]}" -Atqc 'SHOW hba_file')"
SERVER_VERSION_NUM="$("${PSQL[@]}" -Atqc "SELECT current_setting('server_version_num')")"
SERVER_IN_RECOVERY="$("${PSQL[@]}" -Atqc 'SELECT pg_is_in_recovery()')"
SERVER_SSL="$("${PSQL[@]}" -Atqc 'SHOW ssl')"
APP_DB_EXISTS="$("${PSQL[@]}" -Atqc "SELECT count(*) FROM pg_database WHERE datname = '$APP_DATABASE'")"

SERVER_PGDATA="$(canonical_existing_path "$SERVER_PGDATA")"
SERVER_HBA="$(canonical_existing_path "$SERVER_HBA")"
[[ "$SERVER_PGDATA" == "$PRIMARY_PGDATA" ]] ||
  die "connected cluster data_directory is $SERVER_PGDATA, not PRIMARY_PGDATA=$PRIMARY_PGDATA"
[[ "$SERVER_HBA" == "$PRIMARY_PG_HBA_FILE" ]] ||
  die "connected cluster hba_file is $SERVER_HBA, not PRIMARY_PG_HBA_FILE=$PRIMARY_PG_HBA_FILE"
[[ "$SERVER_VERSION_NUM" -ge 160000 && "$SERVER_VERSION_NUM" -lt 170000 ]] ||
  die "connected server is not PostgreSQL 16"
[[ "$SERVER_IN_RECOVERY" == "f" ]] || die "refusing to prepare a standby as primary"
[[ "$APP_DB_EXISTS" == "1" ]] || die "application database does not exist: $APP_DATABASE"
if [[ "$HBA_RECORD_TYPE" == "hostssl" && "$SERVER_SSL" != "on" ]]; then
  die "hostssl rules require ssl=on and a configured PostgreSQL server certificate"
fi

# Complete all non-mutating slot/HBA safety checks before changing roles,
# settings, slots or files. The state is queried again at the mutation point to
# close the race with a standby reconnecting during this script.
SLOT_PREFLIGHT="$("${PSQL[@]}" -AtF '|' -qc \
  "SELECT slot_type, active, coalesce(wal_status, '') FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME'")"
if [[ -n "$SLOT_PREFLIGHT" ]]; then
  IFS='|' read -r PREFLIGHT_SLOT_TYPE PREFLIGHT_SLOT_ACTIVE PREFLIGHT_WAL_STATUS <<<"$SLOT_PREFLIGHT"
  [[ "$PREFLIGHT_SLOT_TYPE" == "physical" ]] ||
    die "slot $SLOT_NAME already exists but is not physical"
  if [[ "$PREFLIGHT_WAL_STATUS" == "unreserved" || "$PREFLIGHT_WAL_STATUS" == "lost" ]]; then
    [[ "$PREFLIGHT_SLOT_ACTIVE" == "f" ]] ||
      die "slot $SLOT_NAME is active with wal_status=$PREFLIGHT_WAL_STATUS; fence/stop its standby and investigate"
    [[ "$RECREATE_INVALID_SLOT" == "yes" ]] ||
      die "slot $SLOT_NAME has wal_status=$PREFLIGHT_WAL_STATUS; no changes made. Fence the old standby and re-run with RECREATE_INVALID_SLOT=yes"
  fi
fi
EXISTING_HBA_ERRORS="$("${PSQL[@]}" -Atqc 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL')"
[[ "$EXISTING_HBA_ERRORS" == "0" ]] ||
  die "existing pg_hba.conf has parse errors; no changes made"
if ! awk -v begin="$MANAGED_HBA_BEGIN" -v end="$MANAGED_HBA_END" '
  $0 == begin { if (inside) exit 41; inside = 1; next }
  $0 == end   { if (!inside) exit 42; inside = 0; next }
  END         { if (inside) exit 43 }
' "$PRIMARY_PG_HBA_FILE" >/dev/null; then
  die "existing managed HBA block is malformed; no changes made"
fi

printf 'Preparing PostgreSQL primary at %s (hba=%s)\n' "$PRIMARY_PGDATA" "$PRIMARY_PG_HBA_FILE"

export UTEN_REPL_USER="$REPL_USER"
export UTEN_REPL_PASSWORD="$REPL_PASSWORD"
export UTEN_APP_USER="$APP_USER"
export UTEN_APP_PASSWORD="$APP_PASSWORD"
export UTEN_APP_DATABASE="$APP_DATABASE"

"${PSQL[@]}" <<'SQL'
\set ON_ERROR_STOP on
\getenv repl_user UTEN_REPL_USER
\getenv repl_password UTEN_REPL_PASSWORD
\getenv app_user UTEN_APP_USER
\getenv app_password UTEN_APP_PASSWORD
\getenv app_database UTEN_APP_DATABASE

SELECT format('CREATE ROLE %I', :'repl_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'repl_user')
\gexec
SELECT format(
  'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT REPLICATION NOBYPASSRLS PASSWORD %L',
  :'repl_user', :'repl_password')
\gexec

SELECT format('CREATE ROLE %I', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
\gexec
SELECT format(
  'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS PASSWORD %L',
  :'app_user', :'app_password')
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'app_database', :'app_user')
WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_database')
\gexec
SQL

unset UTEN_REPL_PASSWORD UTEN_APP_PASSWORD REPL_PASSWORD APP_PASSWORD ADMIN_PASSWORD

SLOT_STATE="$("${PSQL[@]}" -AtF '|' -qc \
  "SELECT slot_type, active, coalesce(wal_status, ''), coalesce(restart_lsn::text, '') FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME'")"
if [[ -z "$SLOT_STATE" ]]; then
  # Reserve WAL immediately. clone-replica.sh deliberately uses a temporary
  # base-backup slot so an existing healthy standby may keep this permanent
  # slot active until the final service cutover.
  "${PSQL[@]}" -c "SELECT pg_create_physical_replication_slot('$SLOT_NAME', true);" >/dev/null
else
  IFS='|' read -r SLOT_TYPE SLOT_ACTIVE SLOT_WAL_STATUS SLOT_RESTART_LSN <<<"$SLOT_STATE"
  [[ "$SLOT_TYPE" == "physical" ]] ||
    die "slot $SLOT_NAME already exists but is not physical"
  if [[ "$SLOT_WAL_STATUS" == "unreserved" || "$SLOT_WAL_STATUS" == "lost" ]]; then
    [[ "$SLOT_ACTIVE" == "f" ]] ||
      die "slot $SLOT_NAME is active with wal_status=$SLOT_WAL_STATUS; fence/stop its standby and investigate before rebuilding"
    [[ "$RECREATE_INVALID_SLOT" == "yes" ]] ||
      die "slot $SLOT_NAME has wal_status=$SLOT_WAL_STATUS and cannot resume; re-run only after fencing the old standby with RECREATE_INVALID_SLOT=yes, then immediately re-clone it"
    printf 'Recreating explicitly confirmed invalid slot %s (old restart_lsn=%s).\n' \
      "$SLOT_NAME" "${SLOT_RESTART_LSN:-none}"
    "${PSQL[@]}" -c "SELECT pg_drop_replication_slot('$SLOT_NAME');" >/dev/null
    "${PSQL[@]}" -c "SELECT pg_create_physical_replication_slot('$SLOT_NAME', true);" >/dev/null
  fi
fi

export UTEN_WAL_KEEP_SIZE="$WAL_KEEP_SIZE"
export UTEN_MAX_SLOT_WAL_KEEP_SIZE="$MAX_SLOT_WAL_KEEP_SIZE"
export UTEN_MAX_WAL_SENDERS="$MAX_WAL_SENDERS"
export UTEN_MAX_REPLICATION_SLOTS="$MAX_REPLICATION_SLOTS"
"${PSQL[@]}" <<'SQL'
\set ON_ERROR_STOP on
\getenv wal_keep_size UTEN_WAL_KEEP_SIZE
\getenv max_slot_wal_keep_size UTEN_MAX_SLOT_WAL_KEEP_SIZE
\getenv max_wal_senders UTEN_MAX_WAL_SENDERS
\getenv max_replication_slots UTEN_MAX_REPLICATION_SLOTS
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
ALTER SYSTEM SET wal_level = 'replica';
SELECT format('ALTER SYSTEM SET wal_keep_size = %L', :'wal_keep_size') \gexec
SELECT format('ALTER SYSTEM SET max_slot_wal_keep_size = %L', :'max_slot_wal_keep_size') \gexec
SELECT format('ALTER SYSTEM SET max_wal_senders = %L', :'max_wal_senders') \gexec
SELECT format('ALTER SYSTEM SET max_replication_slots = %L', :'max_replication_slots') \gexec
ALTER SYSTEM SET synchronous_standby_names = '';
SQL
unset UTEN_WAL_KEEP_SIZE UTEN_MAX_SLOT_WAL_KEEP_SIZE UTEN_MAX_WAL_SENDERS UTEN_MAX_REPLICATION_SLOTS

HBA_BACKUP="${PRIMARY_PG_HBA_FILE}.uten-backup-$(date -u +%Y%m%dT%H%M%SZ).$$"
cp -p -- "$PRIMARY_PG_HBA_FILE" "$HBA_BACKUP"
HBA_TEMP="$(mktemp "${PRIMARY_PG_HBA_FILE}.uten.XXXXXX")"
awk -v begin="$MANAGED_HBA_BEGIN" -v end="$MANAGED_HBA_END" '
  $0 == begin { if (inside) exit 41; inside = 1; next }
  $0 == end   { if (!inside) exit 42; inside = 0; next }
  !inside     { print }
  END         { if (inside) exit 43 }
' "$PRIMARY_PG_HBA_FILE" >"$HBA_TEMP"
{
  printf '\n%s\n' "$MANAGED_HBA_BEGIN"
  printf '%-8s %-16s %-20s %-24s %s\n' "$HBA_RECORD_TYPE" replication "$REPL_USER" "$REPLICATION_CIDR" scram-sha-256
  printf '%-8s %-16s %-20s %-24s %s\n' "$HBA_RECORD_TYPE" "$APP_DATABASE" "$APP_USER" "$CLOUD_APP_CIDR" scram-sha-256
  # Dormant disaster-recovery rules keep the primary-side HBA ready for the
  # reverse topology. If hba_file lives outside PGDATA, base backup cannot copy
  # it; the cloud host must be prepared against its own exact SHOW hba_file path.
  if [[ "$ON_PREM_REPLICA_CIDR" != "$REPLICATION_CIDR" ]]; then
    printf '%-8s %-16s %-20s %-24s %s\n' "$HBA_RECORD_TYPE" replication "$REPL_USER" "$ON_PREM_REPLICA_CIDR" scram-sha-256
  fi
  if [[ "$ON_PREM_APP_CIDR" != "$CLOUD_APP_CIDR" ]]; then
    printf '%-8s %-16s %-20s %-24s %s\n' "$HBA_RECORD_TYPE" "$APP_DATABASE" "$APP_USER" "$ON_PREM_APP_CIDR" scram-sha-256
  fi
  printf '%s\n' "$MANAGED_HBA_END"
} >>"$HBA_TEMP"
chmod --reference="$PRIMARY_PG_HBA_FILE" "$HBA_TEMP"
chown --reference="$PRIMARY_PG_HBA_FILE" "$HBA_TEMP"
mv -f -- "$HBA_TEMP" "$PRIMARY_PG_HBA_FILE"
HBA_TEMP=""

mapfile -t HBA_CHECK < <("${PSQL[@]}" -Atq <<'SQL'
SELECT pg_reload_conf();
SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;
SQL
)
if [[ "${HBA_CHECK[0]:-}" != "t" || "${HBA_CHECK[1]:-}" != "0" ]]; then
  cp -p -- "$HBA_BACKUP" "$PRIMARY_PG_HBA_FILE"
  "${PSQL[@]}" -Atqc 'SELECT pg_reload_conf()' >/dev/null || true
  die "new pg_hba.conf failed reload/parse validation; original HBA was restored"
fi

PENDING_RESTART="$("${PSQL[@]}" -Atqc "SELECT coalesce(string_agg(name, ', ' ORDER BY name), '') FROM pg_settings WHERE pending_restart AND name IN ('listen_addresses','wal_level','max_wal_senders','max_replication_slots','max_slot_wal_keep_size')")"

printf 'Primary roles, slot and HBA are prepared. HBA backup: %s\n' "$HBA_BACKUP"
if [[ -n "$PENDING_RESTART" ]]; then
  printf 'RESTART REQUIRED before cloning; pending settings: %s\n' "$PENDING_RESTART"
else
  printf 'No replication setting is pending restart.\n'
fi
printf 'Verify after restart: SHOW wal_level; SHOW max_slot_wal_keep_size; SELECT * FROM pg_replication_slots WHERE slot_name=%q;\n' "$SLOT_NAME"
