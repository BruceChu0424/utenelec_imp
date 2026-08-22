#!/usr/bin/env bash
# Static, non-secret-printing validation for /etc/uten-imp/server.env.
# The file is parsed as data and is never sourced or executed.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly ENV_FILE="${1:-/etc/uten-imp/server.env}"
readonly ENV_DIR=/etc/uten-imp
readonly POSTGRES_SECRETS=/etc/uten-imp-postgres
readonly LEGACY_POSTGRES_SECRETS=/etc/uten-imp/postgres-secrets

die() {
  printf 'SERVER_ENV_INVALID: %s\n' "$*" >&2
  exit 1
}

env_value() {
  local key="$1"
  local count value
  count="$(awk -F= -v key="$key" '$1 == key { n++ } END { print n + 0 }' "$ENV_FILE")"
  [[ "$count" == 1 ]] || die "$key must appear exactly once (found $count)"
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$ENV_FILE")"
  [[ "$value" != *$'\r'* ]] || die "$key contains a carriage return"
  printf '%s' "$value"
}

expect_exact() {
  local key="$1" expected="$2" actual
  actual="$(env_value "$key")"
  [[ "$actual" == "$expected" ]] || die "$key must be $expected"
}

expect_boolean() {
  local key="$1" value
  value="$(env_value "$key")"
  case "$value" in
    true|false) ;;
    *) die "$key must be exactly true or false" ;;
  esac
}

expect_absent() {
  local key="$1" count
  count="$(awk -F= -v key="$key" '$1 == key { n++ } END { print n + 0 }' "$ENV_FILE")"
  [[ "$count" == 0 ]] || die "$key must not exist in the application environment"
}

validate_exclusive_service_account() {
  local account_name="$1" group_name="$2" passwd_record account_uid account_gid account_home account_shell
  local group_record expected_gid explicit_members primary_members uid_names gid_names
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

require_value() {
  local key="$1" value
  value="$(env_value "$key")"
  [[ -n "$value" ]] || die "$key must not be empty"
  [[ "$value" != *REPLACE* && "$value" != *CHANGE_ME* ]] || die "$key still contains a placeholder"
  [[ "$value" != *[[:space:]]* ]] || die "$key must not contain whitespace"
}

require_secret() {
  local key="$1" value
  value="$(env_value "$key")"
  [[ -n "$value" ]] || die "$key must not be empty"
  [[ "$value" != *REPLACE* && "$value" != *CHANGE_ME* ]] || die "$key still contains a placeholder"
  [[ "$value" != *[[:space:]]* ]] || die "$key must not contain whitespace"
  (( ${#value} >= 32 )) || die "$key must contain at least 32 characters"
}

require_credential() {
  local key="$1" minimum_length="$2" value
  value="$(env_value "$key")"
  [[ -n "$value" ]] || die "$key must not be empty"
  [[ "$value" != *REPLACE* && "$value" != *CHANGE_ME* ]] || die "$key still contains a placeholder"
  [[ "$value" != *[[:space:]]* ]] || die "$key must not contain whitespace"
  (( ${#value} >= minimum_length )) || die "$key must contain at least $minimum_length characters"
}

validate_bootstrap_admin_state() {
  local login retired password normalized unique_characters
  login="$(env_value BOOTSTRAP_ADMIN_LOGIN)"
  retired="$(env_value UTEN_BOOTSTRAP_ADMIN_RETIRED)"
  password="$(env_value BOOTSTRAP_ADMIN_PASSWORD)"

  [[ -n "$login" && ${#login} -le 128 && "$login" != *[[:space:]]* \
    && "$login" != *REPLACE* && "$login" != *CHANGE_ME* ]] \
    || die 'BOOTSTRAP_ADMIN_LOGIN must be one approved non-placeholder account identifier'

  case "$retired" in
    false)
      [[ -n "$password" ]] || die 'BOOTSTRAP_ADMIN_PASSWORD must not be empty before controlled retirement'
      normalized="${password,,}"
      [[ "$normalized" != *replace* && "$normalized" != *change_me* \
        && "$normalized" != *changeme* && "$normalized" != *password* \
        && "$normalized" != *temporary* && "$normalized" != *qwerty* \
        && "$normalized" != *admin* && "$normalized" != *uten* ]] \
        || die 'BOOTSTRAP_ADMIN_PASSWORD contains a placeholder or predictable product/account word'
      [[ "$password" =~ ^[0-9a-f]{48,128}$ ]] \
        || die 'active BOOTSTRAP_ADMIN_PASSWORD must be 48-128 lowercase hex characters from an approved CSPRNG (phase3 uses openssl rand -hex 24)'
      unique_characters="$(LC_ALL=C printf '%s' "$password" | fold -w1 | sort -u | wc -l)"
      (( unique_characters >= 12 )) \
        || die 'BOOTSTRAP_ADMIN_PASSWORD has insufficient character diversity for the approved random-secret format'
      ;;
    true)
      [[ -z "$password" ]] \
        || die 'BOOTSTRAP_ADMIN_PASSWORD must be empty after UTEN_BOOTSTRAP_ADMIN_RETIRED=true'
      ;;
    *)
      die 'UTEN_BOOTSTRAP_ADMIN_RETIRED must be exactly false or true'
      ;;
  esac
}

expect_postgres_secret_file() {
  local key="$1" secret_path="$2" configured actual
  [[ -f "$secret_path" && ! -L "$secret_path" ]] \
    || die "$secret_path must be a regular, non-symlink PostgreSQL secret"
  [[ "$(stat -c '%U:%G:%a:%h' "$secret_path")" == root:postgres:640:1 ]] \
    || die "$secret_path must be root:postgres mode 0640 with one hard link"
  configured="$(env_value "$key")"
  actual="$(<"$secret_path")"
  [[ "$configured" == "$actual" ]] \
    || die "$key does not match its root-managed PostgreSQL secret file"
}

[[ "${EUID}" -eq 0 ]] || die 'run this validator as root'
[[ -d "$ENV_DIR" && ! -L "$ENV_DIR" ]] || die "$ENV_DIR must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$ENV_DIR")" == root:uten-imp:750 ]] \
  || die "$ENV_DIR must be root:uten-imp mode 0750"
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "$ENV_FILE must be a regular, non-symlink file"
[[ "$(dirname -- "$(realpath -e -- "$ENV_FILE")")" == "$ENV_DIR" ]] \
  || die "$ENV_FILE must be directly inside $ENV_DIR with a canonical path"
[[ "$(stat -c '%h' "$ENV_FILE")" == 1 ]] || die "$ENV_FILE must have exactly one hard link"
env_metadata="$(stat -c '%U:%G:%a' "$ENV_FILE")"
[[ "$env_metadata" == root:root:600 || "$env_metadata" == root:uten-imp:640 ]] \
  || die "$ENV_FILE must be root:root 0600 or root:uten-imp 0640 (found $env_metadata)"
validate_exclusive_service_account uten-imp uten-imp
validate_exclusive_service_account uten-imp-migrate uten-imp-migrate
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
    if (index(value, "\"") || index(value, "\047") || index(value, "\\")) exit 13
  }
' "$ENV_FILE"; then
  die "$ENV_FILE is not canonical: no leading whitespace, duplicate keys, quotes, backslashes, or control characters are permitted"
fi
[[ ! -e "$LEGACY_POSTGRES_SECRETS" && ! -L "$LEGACY_POSTGRES_SECRETS" ]] \
  || die "legacy PostgreSQL secret path remains at $LEGACY_POSTGRES_SECRETS; run the separately reviewed migration helper"
[[ -d "$POSTGRES_SECRETS" && ! -L "$POSTGRES_SECRETS" ]] \
  || die "$POSTGRES_SECRETS must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$POSTGRES_SECRETS")" == root:postgres:750 ]] \
  || die "$POSTGRES_SECRETS must be root:postgres mode 0750"

expect_exact UTEN_PROFILE prod
expect_exact UTEN_DEPLOYMENT_SITE local
expect_exact SERVER_ADDRESS 127.0.0.1
expect_exact SERVER_PORT 8080
expect_exact UTEN_DB_URL jdbc:postgresql://127.0.0.1:5432/uten_imp
expect_exact UTEN_DB_USER uten
expect_exact SPRING_FLYWAY_ENABLED false
for forbidden_migration_key in \
  SPRING_FLYWAY_USER SPRING_FLYWAY_PASSWORD SPRING_FLYWAY_URL \
  FLYWAY_USER FLYWAY_PASSWORD FLYWAY_URL \
  UTEN_MIGRATOR_DB_PASSWORD UTEN_FLYWAY_BASELINE_ON_MIGRATE; do
  expect_absent "$forbidden_migration_key"
done
require_credential UTEN_DB_PASSWORD 20
expect_postgres_secret_file UTEN_DB_PASSWORD "$POSTGRES_SECRETS/app.password"

[[ -f "$POSTGRES_SECRETS/migrator.password" && ! -L "$POSTGRES_SECRETS/migrator.password" ]] \
  || die "$POSTGRES_SECRETS/migrator.password must be a regular, non-symlink PostgreSQL secret"
[[ "$(stat -c '%U:%G:%a:%h' "$POSTGRES_SECRETS/migrator.password")" == root:postgres:640:1 ]] \
  || die "$POSTGRES_SECRETS/migrator.password must be root:postgres mode 0640 with one hard link"
migrator_secret="$(<"$POSTGRES_SECRETS/migrator.password")"
[[ "$migrator_secret" =~ ^[A-Za-z0-9]{20,512}$ ]] \
  || die 'the root-managed migrator credential is outside the reviewed format'
while IFS= read -r environment_line || [[ -n "$environment_line" ]]; do
  [[ -z "$environment_line" || "${environment_line:0:1}" == '#' ]] && continue
  environment_value="${environment_line#*=}"
  [[ "$environment_value" != *"$migrator_secret"* ]] \
    || die 'the application environment contains the dedicated migrator credential'
done <"$ENV_FILE"
unset migrator_secret environment_line environment_value
require_secret UTEN_JWT_SECRET
require_secret UTEN_PGP_MASTER_KEY
require_secret UTEN_HMAC_KEY
validate_bootstrap_admin_state
expect_boolean UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED
expect_exact UTEN_REQUIRE_HTTPS true
expect_exact UTEN_SSL_ENABLED false
expect_exact UTEN_TRUSTED_PROXY_REGEX '127[.].*|::1'
cors_origins="$(env_value UTEN_CORS_ORIGINS)"
[[ -n "$cors_origins" ]] || die 'UTEN_CORS_ORIGINS must not be empty'
[[ "$cors_origins" != *REPLACE* && "$cors_origins" != *CHANGE_ME* ]] \
  || die 'UTEN_CORS_ORIGINS still contains a placeholder'
IFS=',' read -r -a cors_entries <<<"$cors_origins"
(( ${#cors_entries[@]} > 0 )) || die 'UTEN_CORS_ORIGINS must contain at least one origin'
for cors_origin in "${cors_entries[@]}"; do
  [[ "$cors_origin" == https://* ]] || die 'every CORS origin must use https://'
  [[ "$cors_origin" != *[[:space:]@*]* ]] \
    || die 'CORS origins must not contain whitespace, user information, or wildcards'
  cors_authority="${cors_origin#https://}"
  [[ -n "$cors_authority" && "$cors_authority" != */* && "$cors_authority" != *\?* && "$cors_authority" != *#* ]] \
    || die 'each CORS origin must be exactly https://host[:port] without a path, query, or fragment'
done
sms_provider="$(env_value UTEN_SMS_PROVIDER)"
[[ "$sms_provider" == disabled || "$sms_provider" == aliyun ]] \
  || die 'UTEN_SMS_PROVIDER must be disabled or aliyun in production (never log)'

expect_exact UTEN_STORAGE_PROVIDER oss
expect_exact UTEN_ATTACHMENT_UPLOADS_ENABLED false
expect_exact UTEN_ATTACHMENT_SCANNER_PROVIDER disabled
expect_exact UTEN_ATTACHMENT_RECONCILIATION_ENABLED false
expect_exact UTEN_OSS_REQUIRE_VERSIONING true
expect_exact UTEN_OSS_USE_INSTANCE_ROLE false
endpoint="$(env_value UTEN_OSS_ENDPOINT)"
[[ "$endpoint" == https://* ]] || die 'UTEN_OSS_ENDPOINT must start with https://'
[[ "$endpoint" != *REPLACE* && "$endpoint" != *CHANGE_ME* ]] || die 'UTEN_OSS_ENDPOINT still contains a placeholder'
[[ "$endpoint" != *[[:space:]@]* ]] || die 'UTEN_OSS_ENDPOINT must not contain whitespace or user information'
authority="${endpoint#https://}"
[[ -n "$authority" && "$authority" != */* && "$authority" != *\?* && "$authority" != *#* ]] \
  || die 'UTEN_OSS_ENDPOINT must be exactly https://host[:port] without a path, query, or fragment'
require_value UTEN_OSS_STAGING_BUCKET
require_value UTEN_OSS_FINAL_BUCKET
staging_bucket="$(env_value UTEN_OSS_STAGING_BUCKET)"
final_bucket="$(env_value UTEN_OSS_FINAL_BUCKET)"
[[ "$staging_bucket" != "$final_bucket" ]] \
  || die 'UTEN_OSS_STAGING_BUCKET and UTEN_OSS_FINAL_BUCKET must be different'
require_value UTEN_OSS_REGION
require_value UTEN_OSS_ACCESS_KEY_ID
require_credential UTEN_OSS_ACCESS_KEY_SECRET 16
expect_exact UTEN_OSS_KEY_PREFIX attachments/

printf '%s\n' \
  'SERVER_ENV_CONFIGURATION_OK' \
  'BOOTSTRAP_ADMIN_CONTROL: if the one-time credential is active, complete the HTTPS first-login password change; verify the old credential is rejected and users.must_change_password=false with last_password_changed_at set; then, in an approved maintenance window, empty BOOTSTRAP_ADMIN_PASSWORD, set UTEN_BOOTSTRAP_ADMIN_RETIRED=true, revalidate, and restart through the controlled activation path.' \
  'NOTE: attachment intake remains disabled; this validates local configuration only. OSS connectivity, least-privilege RAM policy, HTTPS certificate, staging=Off/final=Enabled versioning and all attachment acceptance drills still require live evidence.'
