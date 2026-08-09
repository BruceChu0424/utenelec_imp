#!/usr/bin/env bash
# Install exact cloud-app and reverse-DR HBA rules on an already running
# PostgreSQL 16 standby. This is separate from pg_basebackup because Debian-like
# installations commonly keep hba_file outside PGDATA.
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

require_command psql
require_command realpath
require_command mktemp
require_command awk

[[ "$(id -u)" -ne 0 ]] || die "run as the PostgreSQL service account, never root"

: "${REPLICA_PGDATA:?set REPLICA_PGDATA to the exact running standby data directory}"
: "${REPLICA_PG_HBA_FILE:?set REPLICA_PG_HBA_FILE to the exact hba_file reported by the standby}"
: "${CLOUD_APP_CIDR:?set CLOUD_APP_CIDR to the cloud application host/CIDR}"
: "${ON_PREM_REPLICA_CIDR:?set ON_PREM_REPLICA_CIDR to the on-premises host/CIDR that may be rebuilt as a standby}"
: "${ON_PREM_APP_CIDR:?set ON_PREM_APP_CIDR to the on-premises application host/CIDR used after failover}"

REPLICA_VERIFY_SOCKET="${REPLICA_VERIFY_SOCKET:-/var/run/postgresql}"
REPLICA_VERIFY_PORT="${REPLICA_VERIFY_PORT:-5432}"
REPL_USER="${REPL_USER:-uten_repl}"
APP_USER="${APP_USER:-uten}"
APP_DATABASE="${APP_DATABASE:-uten_imp}"

require_identifier REPL_USER "$REPL_USER"
require_identifier APP_USER "$APP_USER"
require_identifier APP_DATABASE "$APP_DATABASE"
[[ "$REPL_USER" != "$APP_USER" ]] || die "replication and application role names must be distinct"
require_cidr CLOUD_APP_CIDR "$CLOUD_APP_CIDR"
require_cidr ON_PREM_REPLICA_CIDR "$ON_PREM_REPLICA_CIDR"
require_cidr ON_PREM_APP_CIDR "$ON_PREM_APP_CIDR"
[[ "$REPLICA_VERIFY_SOCKET" == /* ]] ||
  die "REPLICA_VERIFY_SOCKET must be an absolute Unix-socket directory"
[[ "$REPLICA_VERIFY_PORT" =~ ^[0-9]{1,5}$ ]] || die "REPLICA_VERIFY_PORT must be numeric"

[[ ! -L "$REPLICA_PGDATA" ]] || die "REPLICA_PGDATA must not be a symlink"
[[ ! -L "$REPLICA_PG_HBA_FILE" ]] || die "REPLICA_PG_HBA_FILE must not be a symlink"
REPLICA_PGDATA="$(realpath -e -- "$REPLICA_PGDATA")"
REPLICA_PG_HBA_FILE="$(realpath -e -- "$REPLICA_PG_HBA_FILE")"
[[ -f "$REPLICA_PGDATA/PG_VERSION" ]] || die "REPLICA_PGDATA has no PG_VERSION"
[[ "$(<"$REPLICA_PGDATA/PG_VERSION")" == "16" ]] || die "only PostgreSQL 16 is supported"
[[ -w "$REPLICA_PG_HBA_FILE" ]] || die "standby hba_file is not writable by this service account"

PSQL=(psql --no-password --host "$REPLICA_VERIFY_SOCKET" --port "$REPLICA_VERIFY_PORT" --username postgres --dbname postgres -X -v ON_ERROR_STOP=1)
SERVER_PGDATA="$("${PSQL[@]}" -Atqc 'SHOW data_directory')"
SERVER_HBA="$("${PSQL[@]}" -Atqc 'SHOW hba_file')"
SERVER_VERSION_NUM="$("${PSQL[@]}" -Atqc "SELECT current_setting('server_version_num')")"
SERVER_IN_RECOVERY="$("${PSQL[@]}" -Atqc 'SELECT pg_is_in_recovery()')"
SERVER_SSL="$("${PSQL[@]}" -Atqc 'SHOW ssl')"
APP_DB_EXISTS="$("${PSQL[@]}" -Atqc "SELECT count(*) FROM pg_database WHERE datname = '$APP_DATABASE'")"
ROLE_COUNT="$("${PSQL[@]}" -Atqc "SELECT count(*) FROM pg_roles WHERE rolname IN ('$REPL_USER', '$APP_USER')")"

SERVER_PGDATA="$(realpath -e -- "$SERVER_PGDATA")"
SERVER_HBA="$(realpath -e -- "$SERVER_HBA")"
[[ "$SERVER_PGDATA" == "$REPLICA_PGDATA" ]] ||
  die "connected standby data_directory is $SERVER_PGDATA, not REPLICA_PGDATA=$REPLICA_PGDATA"
[[ "$SERVER_HBA" == "$REPLICA_PG_HBA_FILE" ]] ||
  die "connected standby hba_file is $SERVER_HBA, not REPLICA_PG_HBA_FILE=$REPLICA_PG_HBA_FILE"
[[ "$SERVER_VERSION_NUM" -ge 160000 && "$SERVER_VERSION_NUM" -lt 170000 ]] ||
  die "connected server is not PostgreSQL 16"
[[ "$SERVER_IN_RECOVERY" == "t" ]] || die "refusing to prepare standby HBA on a writable primary"
[[ "$SERVER_SSL" == "on" ]] || die "hostssl rules require ssl=on and a configured standby certificate"
[[ "$APP_DB_EXISTS" == "1" ]] || die "application database does not exist: $APP_DATABASE"
[[ "$ROLE_COUNT" == "2" ]] || die "replication and application roles must both exist on the standby"

PREEXISTING_HBA_ERRORS="$("${PSQL[@]}" -Atqc 'SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL')"
[[ "$PREEXISTING_HBA_ERRORS" == "0" ]] ||
  die "existing standby hba_file already has parse errors; repair it before applying managed rules"

HBA_BACKUP="${REPLICA_PG_HBA_FILE}.uten-backup-$(date -u +%Y%m%dT%H%M%SZ).$$"
HBA_TEMP="$(mktemp "${REPLICA_PG_HBA_FILE}.uten.XXXXXX")"
cleanup() {
  [[ -z "${HBA_TEMP:-}" || ! -e "$HBA_TEMP" ]] || rm -f -- "$HBA_TEMP"
}
trap cleanup EXIT

cp -p -- "$REPLICA_PG_HBA_FILE" "$HBA_BACKUP"
if ! awk -v begin="$MANAGED_HBA_BEGIN" -v end="$MANAGED_HBA_END" '
  $0 == begin { if (inside) exit 41; inside = 1; next }
  $0 == end   { if (!inside) exit 42; inside = 0; next }
  !inside     { print }
  END         { if (inside) exit 43 }
' "$REPLICA_PG_HBA_FILE" >"$HBA_TEMP"; then
  die "existing managed HBA block is malformed; original file was not changed"
fi

{
  printf '\n%s\n' "$MANAGED_HBA_BEGIN"
  printf '%-8s %-16s %-20s %-24s %s\n' hostssl "$APP_DATABASE" "$APP_USER" "$CLOUD_APP_CIDR" scram-sha-256
  printf '%-8s %-16s %-20s %-24s %s\n' hostssl replication "$REPL_USER" "$ON_PREM_REPLICA_CIDR" scram-sha-256
  if [[ "$ON_PREM_APP_CIDR" != "$CLOUD_APP_CIDR" ]]; then
    printf '%-8s %-16s %-20s %-24s %s\n' hostssl "$APP_DATABASE" "$APP_USER" "$ON_PREM_APP_CIDR" scram-sha-256
  fi
  printf '%s\n' "$MANAGED_HBA_END"
} >>"$HBA_TEMP"

chmod --reference="$REPLICA_PG_HBA_FILE" "$HBA_TEMP"
chown --reference="$REPLICA_PG_HBA_FILE" "$HBA_TEMP"
mv -f -- "$HBA_TEMP" "$REPLICA_PG_HBA_FILE"
HBA_TEMP=""

mapfile -t HBA_CHECK < <("${PSQL[@]}" -Atq <<'SQL'
SELECT pg_reload_conf();
SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;
SQL
)
if [[ "${HBA_CHECK[0]:-}" != "t" || "${HBA_CHECK[1]:-}" != "0" ]]; then
  cp -p -- "$HBA_BACKUP" "$REPLICA_PG_HBA_FILE"
  "${PSQL[@]}" -Atqc 'SELECT pg_reload_conf()' >/dev/null || true
  die "new standby hba_file failed reload/parse validation; original HBA was restored"
fi

printf 'Standby HBA prepared and reloaded. Backup: %s\n' "$HBA_BACKUP"
printf 'Review rule order with SELECT * FROM pg_hba_file_rules ORDER BY rule_number;\n'
