#!/usr/bin/env bash
# Static, non-secret-printing validation for the dedicated migration process.
# The environment file is parsed as data and is never sourced or executed.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly ENV_FILE="${1:-/etc/uten-imp-migrator/migrator.env}"
readonly ENV_DIR=/etc/uten-imp-migrator
readonly SERVICE_USER=uten-imp-migrate
readonly SERVICE_GROUP=uten-imp-migrate
readonly POSTGRES_SECRETS=/etc/uten-imp-postgres
readonly POSTGRES_SECRET="$POSTGRES_SECRETS/migrator.password"

die() {
  printf 'MIGRATOR_ENV_INVALID: %s\n' "$*" >&2
  exit 1
}

env_value() {
  local key="$1" count value
  count="$(awk -F= -v key="$key" '$1 == key { n++ } END { print n + 0 }' "$ENV_FILE")"
  [[ "$count" == 1 ]] || die "$key must appear exactly once (found $count)"
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$ENV_FILE")"
  [[ "$value" != *$'\r'* ]] || die "$key contains a carriage return"
  printf '%s' "$value"
}

[[ "${EUID}" -eq 0 ]] || die 'run this validator as root'
for command_name in awk getent id realpath stat systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

application_state="$(systemctl is-active uten-imp.service 2>/dev/null || true)"
case "$application_state" in
  inactive|failed|unknown) ;;
  *) die "uten-imp.service must be stopped before schema migration (state=$application_state)" ;;
esac

[[ -d "$ENV_DIR" && ! -L "$ENV_DIR" ]] || die "$ENV_DIR must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$ENV_DIR")" == "root:$SERVICE_GROUP:750" ]] \
  || die "$ENV_DIR must be root:$SERVICE_GROUP mode 0750"
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "$ENV_FILE must be a regular, non-symlink file"
[[ "$(dirname -- "$(realpath -e -- "$ENV_FILE")")" == "$ENV_DIR" ]] \
  || die "$ENV_FILE must be directly inside $ENV_DIR with a canonical path"
[[ "$(stat -c '%U:%G:%a:%h' "$ENV_FILE")" == "root:$SERVICE_GROUP:640:1" ]] \
  || die "$ENV_FILE must be root:$SERVICE_GROUP mode 0640 with one hard link"

service_account_record="$(getent passwd "$SERVICE_USER")" || die "missing service user $SERVICE_USER"
IFS=: read -r account_name _ account_uid account_gid _ account_home account_shell <<<"$service_account_record"
[[ "$account_name" == "$SERVICE_USER" && "$account_uid" =~ ^[0-9]+$ && "$account_uid" != 0 ]] \
  || die "invalid service account record for $SERVICE_USER"
uid_names="$(getent passwd | awk -F: -v uid="$account_uid" '$3 == uid { print $1 }')"
[[ "$uid_names" == "$SERVICE_USER" ]] \
  || die "$account_uid must map to exactly one passwd name: $SERVICE_USER"
service_group_record="$(getent group "$SERVICE_GROUP")" || die "missing service group $SERVICE_GROUP"
IFS=: read -r _ _ service_gid explicit_group_members <<<"$service_group_record"
[[ -n "$service_gid" && "$account_gid" == "$service_gid" ]] \
  || die "$SERVICE_USER must use $SERVICE_GROUP as its primary group"
gid_names="$(getent group | awk -F: -v gid="$service_gid" '$3 == gid { print $1 }')"
[[ "$gid_names" == "$SERVICE_GROUP" ]] \
  || die "$service_gid must map to exactly one group name: $SERVICE_GROUP"
[[ "$account_home" == /nonexistent && "$account_shell" == /usr/sbin/nologin ]] \
  || die "$SERVICE_USER must be a nologin account with /nonexistent home"
[[ "$(id -Gn "$SERVICE_USER")" == "$SERVICE_GROUP" ]] \
  || die "$SERVICE_USER must not have supplementary groups"
[[ -z "$explicit_group_members" || "$explicit_group_members" == "$SERVICE_USER" ]] \
  || die "$SERVICE_GROUP must not contain another explicit member"
primary_group_members="$(getent passwd | awk -F: -v gid="$service_gid" '$4 == gid { print $1 }')"
[[ "$primary_group_members" == "$SERVICE_USER" ]] \
  || die "$SERVICE_GROUP must be the primary group of only $SERVICE_USER"

[[ -d "$POSTGRES_SECRETS" && ! -L "$POSTGRES_SECRETS" ]] \
  || die "$POSTGRES_SECRETS must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$POSTGRES_SECRETS")" == root:postgres:750 ]] \
  || die "$POSTGRES_SECRETS must be root:postgres mode 0750"
[[ -f "$POSTGRES_SECRET" && ! -L "$POSTGRES_SECRET" ]] \
  || die "$POSTGRES_SECRET must be a regular, non-symlink file"
[[ "$(stat -c '%U:%G:%a:%h' "$POSTGRES_SECRET")" == root:postgres:640:1 ]] \
  || die "$POSTGRES_SECRET must be root:postgres mode 0640 with one hard link"

if ! LC_ALL=C awk '
  $0 == "" { next }
  $0 ~ /[[:cntrl:]]/ { exit 10 }
  substr($0, 1, 1) == "#" { next }
  $0 !~ /^[A-Z][A-Z0-9_]*=/ { exit 11 }
  {
    separator = index($0, "=")
    key = substr($0, 1, separator - 1)
    value = substr($0, separator + 1)
    if (seen[key]++) exit 12
    if (key != "UTEN_MIGRATOR_DB_PASSWORD") exit 13
    if (index(value, "\"") || index(value, "\047") || index(value, "\\")) exit 14
  }
' "$ENV_FILE"; then
  die "$ENV_FILE must contain only one canonical UTEN_MIGRATOR_DB_PASSWORD assignment"
fi

configured_secret="$(env_value UTEN_MIGRATOR_DB_PASSWORD)"
authoritative_secret="$(<"$POSTGRES_SECRET")"
[[ "$configured_secret" =~ ^[A-Za-z0-9]{20,512}$ ]] \
  || die 'UTEN_MIGRATOR_DB_PASSWORD is outside the reviewed credential format'
[[ "$configured_secret" == "$authoritative_secret" ]] \
  || die 'UTEN_MIGRATOR_DB_PASSWORD does not match the root-managed PostgreSQL secret'
unset configured_secret authoritative_secret

printf '%s\n' \
  'MIGRATOR_ENV_CONFIGURATION_OK' \
  'The file is isolated from the application account and contains no database URL or role override.'
