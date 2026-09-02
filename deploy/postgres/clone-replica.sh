#!/usr/bin/env bash
# Clone/replace the cloud PostgreSQL standby from the on-premises primary.
# The old PGDATA is renamed and retained; this script never recursively deletes
# an existing cluster. Run as the PostgreSQL service account, not root.
set -Eeuo pipefail
umask 077

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

read_secret() {
  local path="$1" value
  [[ -f "$path" && -r "$path" ]] || die "replication password file is not readable: $path"
  value="$(<"$path")"
  [[ ${#value} -ge 16 ]] || die "replication password must contain at least 16 characters"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "replication password must be exactly one line"
  printf '%s' "$value"
}

pgpass_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//:/\\:}"
  printf '%s' "$value"
}

conninfo_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "'%s'" "$value"
}

require_command pg_basebackup
require_command pg_ctl
require_command psql
require_command realpath
require_command mktemp
require_command pg_verifybackup

[[ "$(id -u)" -ne 0 ]] || die "run as the PostgreSQL service account, never root"

: "${PRIMARY_HOST:?set PRIMARY_HOST to the primary certificate DNS name/address}"
: "${REPL_PASSWORD_FILE:?set REPL_PASSWORD_FILE to a service-account-readable secret file}"
: "${REPLICA_PGDATA:?set REPLICA_PGDATA to the exact cloud standby data directory}"
: "${CONFIRM_REPLICA_PGDATA:?set CONFIRM_REPLICA_PGDATA to the same exact path as REPLICA_PGDATA}"

PRIMARY_PORT="${PRIMARY_PORT:-5432}"
PRIMARY_SSLMODE="${PRIMARY_SSLMODE:-verify-full}"
PRIMARY_SSLROOTCERT="${PRIMARY_SSLROOTCERT:-}"
REPL_USER="${REPL_USER:-uten_repl}"
SLOT_NAME="${SLOT_NAME:-uten_cloud_replica}"
APPLICATION_NAME="${APPLICATION_NAME:-uten_cloud_replica}"
APP_DATABASE="${APP_DATABASE:-uten_imp}"
REPLICA_SERVICE_MANAGER="${REPLICA_SERVICE_MANAGER:-auto}"
REPLICA_CLUSTER_VERSION="${REPLICA_CLUSTER_VERSION:-16}"
REPLICA_CLUSTER_NAME="${REPLICA_CLUSTER_NAME:-main}"
REPLICA_VERIFY_SOCKET="${REPLICA_VERIFY_SOCKET:-/var/run/postgresql}"
REPLICA_VERIFY_PORT="${REPLICA_VERIFY_PORT:-5432}"
ALLOW_INSECURE_TESTING="${ALLOW_INSECURE_TESTING:-no}"

require_identifier REPL_USER "$REPL_USER"
require_identifier SLOT_NAME "$SLOT_NAME"
require_identifier APPLICATION_NAME "$APPLICATION_NAME"
require_identifier APP_DATABASE "$APP_DATABASE"
[[ "$PRIMARY_HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die "PRIMARY_HOST contains unsafe characters"
[[ "$PRIMARY_PORT" =~ ^[0-9]{1,5}$ ]] || die "PRIMARY_PORT must be numeric"
[[ "$REPLICA_VERIFY_PORT" =~ ^[0-9]{1,5}$ ]] || die "REPLICA_VERIFY_PORT must be numeric"
[[ "$REPLICA_VERIFY_SOCKET" == /* ]] || die "REPLICA_VERIFY_SOCKET must be an absolute Unix-socket directory"
[[ "$PRIMARY_SSLMODE" =~ ^(verify-full|verify-ca|require|disable)$ ]] ||
  die "PRIMARY_SSLMODE must be verify-full, verify-ca, require or disable"
if [[ "$PRIMARY_SSLMODE" == "disable" ]]; then
  [[ "$ALLOW_INSECURE_TESTING" == "yes" ]] ||
    die "PRIMARY_SSLMODE=disable is allowed only for an isolated test"
fi
if [[ "$PRIMARY_SSLMODE" == "verify-full" || "$PRIMARY_SSLMODE" == "verify-ca" ]]; then
  [[ -f "$PRIMARY_SSLROOTCERT" && -r "$PRIMARY_SSLROOTCERT" ]] ||
    die "PRIMARY_SSLROOTCERT is required and must be readable for certificate verification"
fi

[[ "$REPLICA_PGDATA" == /* ]] || die "REPLICA_PGDATA must be an absolute path"
[[ "$CONFIRM_REPLICA_PGDATA" == "$REPLICA_PGDATA" ]] ||
  die "CONFIRM_REPLICA_PGDATA must exactly equal REPLICA_PGDATA"
[[ ! -L "$REPLICA_PGDATA" ]] || die "REPLICA_PGDATA must not be a symlink"
case "$REPLICA_PGDATA" in
  /|/var|/var/lib|/var/lib/postgresql|/usr|/etc|/opt)
    die "REPLICA_PGDATA is too broad: $REPLICA_PGDATA" ;;
esac
PGDATA_PARENT="$(dirname -- "$REPLICA_PGDATA")"
PGDATA_BASENAME="$(basename -- "$REPLICA_PGDATA")"
[[ "$PGDATA_BASENAME" != "." && "$PGDATA_BASENAME" != ".." ]] || die "unsafe PGDATA basename"
[[ "$PGDATA_BASENAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "PGDATA basename contains unsafe characters"
[[ -d "$PGDATA_PARENT" ]] || die "PGDATA parent does not exist: $PGDATA_PARENT"
PGDATA_PARENT="$(realpath -e -- "$PGDATA_PARENT")"
[[ -w "$PGDATA_PARENT" ]] || die "PGDATA parent is not writable by the PostgreSQL service account"
REPLICA_PGDATA="$(realpath -m -- "$PGDATA_PARENT/$PGDATA_BASENAME")"
[[ "$CONFIRM_REPLICA_PGDATA" == "$REPLICA_PGDATA" ]] ||
  die "confirmation does not match the canonical replica path: $REPLICA_PGDATA"
case "$REPLICA_PGDATA" in
  /|/var|/var/lib|/var/lib/postgresql|/usr|/etc|/opt)
    die "canonical REPLICA_PGDATA is too broad: $REPLICA_PGDATA" ;;
esac
command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$REPLICA_PGDATA" &&
  die "REPLICA_PGDATA is a mount point; clone to a staging volume and switch it manually"

REPL_SECRET="$(read_secret "$REPL_PASSWORD_FILE")"
PGPASSFILE="$(mktemp)"
PGPASS_TEMP_PATH="$PGPASSFILE"
STAGE="${REPLICA_PGDATA}.uten-stage.$$"
BACKUP="${REPLICA_PGDATA}.preclone.$(date -u +%Y%m%dT%H%M%SZ)"
SWAPPED="no"

cleanup() {
  unset REPL_SECRET PGPASSWORD
  [[ -z "${PGPASS_TEMP_PATH:-}" || ! -e "$PGPASS_TEMP_PATH" ]] || rm -f -- "$PGPASS_TEMP_PATH"
  if [[ "$SWAPPED" == "no" && -d "$STAGE" ]]; then
    rm -rf -- "$STAGE"
  fi
}
trap cleanup EXIT

[[ ! -e "$STAGE" ]] || die "staging path already exists: $STAGE"
[[ ! -e "$BACKUP" ]] || die "backup path already exists: $BACKUP"

printf '%s:%s:replication:%s:%s\n' \
  "$(pgpass_escape "$PRIMARY_HOST")" \
  "$(pgpass_escape "$PRIMARY_PORT")" \
  "$(pgpass_escape "$REPL_USER")" \
  "$(pgpass_escape "$REPL_SECRET")" >"$PGPASSFILE"
chmod 0600 "$PGPASSFILE"
export PGPASSFILE
export PGSSLMODE="$PRIMARY_SSLMODE"
[[ -z "$PRIMARY_SSLROOTCERT" ]] || export PGSSLROOTCERT="$PRIMARY_SSLROOTCERT"

printf 'Cloning primary %s:%s into staging path %s\n' "$PRIMARY_HOST" "$PRIMARY_PORT" "$STAGE"
# Do not attach pg_basebackup to the permanent standby slot. PostgreSQL uses a
# temporary slot for --wal-method=stream when --slot is omitted. This lets a
# healthy old standby keep the permanent SLOT_NAME active while the replacement
# is staged and verified; after stop_replica, the new standby takes over that
# same permanent slot through primary_slot_name below.
pg_basebackup \
  --no-password \
  --host "$PRIMARY_HOST" \
  --port "$PRIMARY_PORT" \
  --username "$REPL_USER" \
  --pgdata "$STAGE" \
  --format plain \
  --wal-method stream \
  --checkpoint fast \
  --manifest-checksums SHA256 \
  --progress

pg_verifybackup "$STAGE"

STANDBY_PGPASS="$STAGE/standby.pgpass"
printf '%s:%s:replication:%s:%s\n' \
  "$(pgpass_escape "$PRIMARY_HOST")" \
  "$(pgpass_escape "$PRIMARY_PORT")" \
  "$(pgpass_escape "$REPL_USER")" \
  "$(pgpass_escape "$REPL_SECRET")" >"$STANDBY_PGPASS"
chmod 0600 "$STANDBY_PGPASS"

ROOT_CERT_SETTING=""
if [[ -n "$PRIMARY_SSLROOTCERT" ]]; then
  cp -- "$PRIMARY_SSLROOTCERT" "$STAGE/uten-primary-root.crt"
  chmod 0600 "$STAGE/uten-primary-root.crt"
  ROOT_CERT_SETTING=" sslrootcert=$(conninfo_quote "$REPLICA_PGDATA/uten-primary-root.crt")"
fi

CONNINFO="host=$(conninfo_quote "$PRIMARY_HOST") port=$(conninfo_quote "$PRIMARY_PORT") user=$(conninfo_quote "$REPL_USER") application_name=$(conninfo_quote "$APPLICATION_NAME") sslmode=$(conninfo_quote "$PRIMARY_SSLMODE") passfile=$(conninfo_quote "$REPLICA_PGDATA/standby.pgpass")${ROOT_CERT_SETTING}"
POSTGRES_CONFIG_VALUE="${CONNINFO//\'/\'\'}"
{
  printf '\n# Managed by clone-replica.sh; password is held in standby.pgpass, not here.\n'
  printf "primary_conninfo = '%s'\n" "$POSTGRES_CONFIG_VALUE"
  printf "primary_slot_name = '%s'\n" "$SLOT_NAME"
  printf "hot_standby = 'on'\n"
} >>"$STAGE/postgresql.auto.conf"
touch "$STAGE/standby.signal"
unset REPL_SECRET
rm -f -- "$PGPASS_TEMP_PATH"
unset PGPASSFILE PGSSLMODE PGSSLROOTCERT

find_cluster_data_directory() {
  pg_lsclusters --no-header 2>/dev/null |
    awk -v version="$REPLICA_CLUSTER_VERSION" -v cluster="$REPLICA_CLUSTER_NAME" \
      '$1 == version && $2 == cluster { print $6; exit }'
}

find_cluster_status() {
  pg_lsclusters --no-header 2>/dev/null |
    awk -v version="$REPLICA_CLUSTER_VERSION" -v cluster="$REPLICA_CLUSTER_NAME" \
      '$1 == version && $2 == cluster { print $4; exit }'
}

if [[ "$REPLICA_SERVICE_MANAGER" == "auto" ]]; then
  if command -v pg_ctlcluster >/dev/null 2>&1 && command -v pg_lsclusters >/dev/null 2>&1; then
    CLUSTER_DATA="$(find_cluster_data_directory)"
    if [[ -n "$CLUSTER_DATA" && "$(realpath -m -- "$CLUSTER_DATA")" == "$REPLICA_PGDATA" ]]; then
      REPLICA_SERVICE_MANAGER="pg_ctlcluster"
    else
      REPLICA_SERVICE_MANAGER="pg_ctl"
    fi
  else
    REPLICA_SERVICE_MANAGER="pg_ctl"
  fi
fi

stop_replica() {
  if [[ "$REPLICA_SERVICE_MANAGER" == "pg_ctlcluster" ]]; then
    local cluster_data
    cluster_data="$(find_cluster_data_directory)"
    [[ -n "$cluster_data" ]] || die "cluster $REPLICA_CLUSTER_VERSION/$REPLICA_CLUSTER_NAME not found"
    [[ "$(realpath -m -- "$cluster_data")" == "$REPLICA_PGDATA" ]] ||
      die "pg_ctlcluster targets $cluster_data, not $REPLICA_PGDATA"
    local cluster_status
    cluster_status="$(find_cluster_status)"
    [[ -n "$cluster_status" ]] || die "could not determine cluster status"
    if [[ "$cluster_status" != "down" ]]; then
      pg_ctlcluster "$REPLICA_CLUSTER_VERSION" "$REPLICA_CLUSTER_NAME" stop
    fi
  elif [[ "$REPLICA_SERVICE_MANAGER" == "pg_ctl" ]]; then
    if [[ -f "$REPLICA_PGDATA/postmaster.pid" ]]; then
      local postmaster_pid
      postmaster_pid="$(head -n 1 "$REPLICA_PGDATA/postmaster.pid")"
      [[ "$postmaster_pid" =~ ^[1-9][0-9]*$ ]] || die "invalid postmaster.pid in existing PGDATA"
      if kill -0 "$postmaster_pid" 2>/dev/null; then
        pg_ctl -D "$REPLICA_PGDATA" status >/dev/null 2>&1 ||
          die "postmaster.pid is live but pg_ctl cannot verify it belongs to this PGDATA"
        pg_ctl -D "$REPLICA_PGDATA" -m fast -w -t 60 stop
      else
        printf 'WARNING: preserving stale postmaster.pid inside the rollback copy.\n' >&2
      fi
    fi
  else
    die "REPLICA_SERVICE_MANAGER must be auto, pg_ctlcluster or pg_ctl"
  fi
}

start_replica() {
  if [[ "$REPLICA_SERVICE_MANAGER" == "pg_ctlcluster" ]]; then
    pg_ctlcluster "$REPLICA_CLUSTER_VERSION" "$REPLICA_CLUSTER_NAME" start
  else
    pg_ctl -D "$REPLICA_PGDATA" -l "$REPLICA_PGDATA/uten-standby-startup.log" -w -t 60 start
  fi
}

stop_replica
if [[ -e "$REPLICA_PGDATA" ]]; then
  mv -- "$REPLICA_PGDATA" "$BACKUP"
fi
if ! mv -- "$STAGE" "$REPLICA_PGDATA"; then
  [[ ! -e "$BACKUP" ]] || mv -- "$BACKUP" "$REPLICA_PGDATA"
  die "could not install staged replica"
fi
SWAPPED="yes"

if ! start_replica; then
  FAILED="${REPLICA_PGDATA}.failed.$(date -u +%Y%m%dT%H%M%SZ)"
  mv -- "$REPLICA_PGDATA" "$FAILED"
  if [[ -e "$BACKUP" ]]; then
    mv -- "$BACKUP" "$REPLICA_PGDATA"
    start_replica || true
  fi
  die "new standby failed to start; failed clone retained at $FAILED and previous PGDATA restored when available"
fi

for _ in $(seq 1 60); do
  # The script is required to run as the postgres OS account. Verify locally
  # through peer authentication with an explicit database user; never reuse
  # the replication password for a normal SQL connection.
  RECOVERY_STATE="$(psql --no-password -X -Atq \
    --host "$REPLICA_VERIFY_SOCKET" \
    --port "$REPLICA_VERIFY_PORT" \
    --username postgres \
    --dbname "$APP_DATABASE" \
    -c 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  [[ "$RECOVERY_STATE" == "t" ]] && break
  sleep 1
done
[[ "${RECOVERY_STATE:-}" == "t" ]] || die "new server is running but did not verify as a standby"

printf 'Replica is in recovery and streaming can start.\n'
if [[ -e "$BACKUP" ]]; then
  printf 'Previous PGDATA retained for rollback at: %s\n' "$BACKUP"
  printf 'Delete it only after replay, application and backup validation have passed.\n'
fi
