#!/bin/bash
# Strict, non-executing parser for the dedicated internal ERP test environment.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly ENV_FILE="${1:-/etc/uten-imp/server.env}"
readonly ENV_DIR=/etc/uten-imp
readonly POSTGRES_SECRETS=/etc/uten-imp-postgres

die() {
  printf 'INTERNAL_TEST_SERVER_ENV_INVALID: %s\n' "$*" >&2
  exit 1
}

env_count() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { n++ } END { print n + 0 }' "$ENV_FILE"
}

env_value() {
  local key="$1" count value
  count="$(env_count "$key")"
  [[ "$count" == 1 ]] || die "$key must appear exactly once (found $count)"
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$ENV_FILE")"
  [[ "$value" != *$'\r'* ]] || die "$key contains a carriage return"
  printf '%s' "$value"
}

expect_exact() {
  local key="$1" expected="$2"
  [[ "$(env_value "$key")" == "$expected" ]] || die "$key must be $expected"
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
  local key="$1"
  [[ "$(env_count "$key")" == 0 ]] || die "$key must not be present"
}

require_value() {
  local key="$1" value
  value="$(env_value "$key")"
  [[ -n "$value" ]] || die "$key must not be empty"
  [[ "$value" != *REPLACE* && "$value" != *CHANGE_ME* ]] \
    || die "$key still contains a placeholder"
  printf '%s' "$value"
}

require_secret() {
  local key="$1" minimum="$2" value
  value="$(require_value "$key")"
  [[ "$value" != *[[:space:]]* ]] || die "$key must not contain whitespace"
  (( ${#value} >= minimum )) || die "$key must contain at least $minimum characters"
}

validate_supported_environment_keys() {
  local environment_line environment_key
  while IFS= read -r environment_line || [[ -n "$environment_line" ]]; do
    [[ -z "$environment_line" || "${environment_line:0:1}" == '#' ]] && continue
    environment_key="${environment_line%%=*}"
    case "$environment_key" in
      UTEN_PROFILE|UTEN_DEPLOYMENT_SITE|UTEN_LOCAL_ALLOWED_CIDRS|SERVER_ADDRESS|SERVER_PORT|\
      UTEN_DB_URL|UTEN_DB_USER|UTEN_DB_PASSWORD|SPRING_FLYWAY_ENABLED|\
      UTEN_JWT_SECRET|UTEN_JWT_ISSUER|UTEN_PGP_MASTER_KEY|UTEN_PGP_KEY_VERSION|\
      UTEN_HMAC_KEY|UTEN_CORS_ORIGINS|UTEN_REQUIRE_HTTPS|UTEN_SSL_ENABLED|\
      UTEN_TRUSTED_PROXY_REGEX|UTEN_SWAGGER_ENABLED|UTEN_BOOTSTRAP_ADMIN_RETIRED|\
      BOOTSTRAP_ADMIN_LOGIN|BOOTSTRAP_ADMIN_PASSWORD|UTEN_SMS_PROVIDER|UTEN_SMS_EXPOSE_CODE|\
      UTEN_POLICY_INTELLIGENCE_ENABLED|UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED|\
      UTEN_LEGACY_ENABLED|UTEN_STORAGE_PROVIDER|\
      UTEN_STORAGE_LOCAL_DIR|UTEN_ATTACHMENT_UPLOADS_ENABLED|\
      UTEN_ATTACHMENT_SCANNER_PROVIDER|UTEN_ATTACHMENT_RECONCILIATION_ENABLED|\
      UTEN_STORAGE_MAX_BYTES|UTEN_STORAGE_PRESIGN_EXPIRY)
        ;;
      *)
        die "unsupported environment key: $environment_key"
        ;;
    esac
  done <"$ENV_FILE"
}

validate_narrow_local_cidrs() {
  local configured="$1"
  (( ${#configured} <= 1024 )) || die 'UTEN_LOCAL_ALLOWED_CIDRS is too long'
  if ! /usr/bin/python3 -I - "$configured" <<'PY'
import ipaddress
import sys

raw_value = sys.argv[1]
entries = raw_value.split(",")
if not entries or len(entries) > 8 or len(set(entries)) != len(entries):
    raise SystemExit(1)

loopback4 = ipaddress.ip_network("127.0.0.0/8")
private4 = tuple(
    ipaddress.ip_network(value)
    for value in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)
for raw in entries:
    if not raw or raw != raw.strip():
        raise SystemExit(1)
    try:
        network = ipaddress.ip_network(raw, strict=True)
    except ValueError:
        raise SystemExit(1)
    if str(network) != raw:
        raise SystemExit(1)
    if network.version == 6:
        if raw != "::1/128":
            raise SystemExit(1)
        continue
    if network.subnet_of(loopback4):
        continue
    if any(
        network.subnet_of(parent) and network.prefixlen > parent.prefixlen
        for parent in private4
    ):
        continue
    raise SystemExit(1)
PY
  then
    die 'local source entries must be canonical loopback or strict RFC1918 subnets'
  fi
}

validate_exclusive_service_account() {
  local account_name="$1" group_name="$2" passwd_record account_uid account_gid
  local account_home account_shell group_record expected_gid explicit_members
  local primary_members uid_names gid_names
  passwd_record="$(getent passwd "$account_name")" \
    || die "missing service account: $account_name"
  IFS=: read -r _ _ account_uid account_gid _ account_home account_shell <<<"$passwd_record"
  [[ "$account_uid" =~ ^[0-9]+$ && "$account_uid" != 0 ]] \
    || die "$account_name must be a non-root service account"
  uid_names="$(getent passwd | awk -F: -v uid="$account_uid" '$3 == uid { print $1 }')"
  [[ "$uid_names" == "$account_name" ]] \
    || die "$account_uid must map only to $account_name"
  group_record="$(getent group "$group_name")" || die "missing service group: $group_name"
  IFS=: read -r _ _ expected_gid explicit_members <<<"$group_record"
  gid_names="$(getent group | awk -F: -v gid="$expected_gid" '$3 == gid { print $1 }')"
  [[ "$gid_names" == "$group_name" ]] \
    || die "$expected_gid must map only to $group_name"
  [[ "$account_gid" == "$expected_gid" ]] \
    || die "$account_name must use $group_name as its primary group"
  [[ "$account_home" == /nonexistent && "$account_shell" == /usr/sbin/nologin ]] \
    || die "$account_name must be a nologin account with /nonexistent home"
  [[ "$(id -Gn "$account_name")" == "$group_name" ]] \
    || die "$account_name must not have supplementary groups"
  [[ -z "$explicit_members" || "$explicit_members" == "$account_name" ]] \
    || die "$group_name must not contain another explicit member"
  primary_members="$(getent passwd | awk -F: -v gid="$expected_gid" '$4 == gid { print $1 }')"
  [[ "$primary_members" == "$account_name" ]] \
    || die "$group_name must be primary for only $account_name"
}

[[ "${EUID}" -eq 0 ]] || die 'run this validator as root'
[[ -d "$ENV_DIR" && ! -L "$ENV_DIR" ]] || die "$ENV_DIR must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$ENV_DIR")" == root:uten-imp:750 ]] \
  || die "$ENV_DIR must be root:uten-imp mode 0750"
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "$ENV_FILE must be a regular non-symlink file"
[[ "$(dirname -- "$(realpath -e -- "$ENV_FILE")")" == "$ENV_DIR" ]] \
  || die "$ENV_FILE must be directly inside $ENV_DIR"
[[ "$(stat -c '%h' "$ENV_FILE")" == 1 ]] || die "$ENV_FILE must have one hard link"
metadata="$(stat -c '%U:%G:%a' "$ENV_FILE")"
[[ "$metadata" == root:root:600 || "$metadata" == root:uten-imp:640 ]] \
  || die "$ENV_FILE must be root:root 0600 or root:uten-imp 0640"
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
  die 'environment must be canonical data: no duplicate keys, quotes, backslashes, or control characters'
fi

validate_supported_environment_keys

expect_exact UTEN_PROFILE internal-test
expect_exact UTEN_DEPLOYMENT_SITE local
expect_exact SERVER_ADDRESS 127.0.0.1
expect_exact SERVER_PORT 8080
expect_exact UTEN_DB_URL jdbc:postgresql://127.0.0.1:5432/uten_imp
expect_exact UTEN_DB_USER uten
expect_exact SPRING_FLYWAY_ENABLED false
for key in SPRING_FLYWAY_USER SPRING_FLYWAY_PASSWORD SPRING_FLYWAY_URL \
  FLYWAY_USER FLYWAY_PASSWORD FLYWAY_URL UTEN_MIGRATOR_DB_PASSWORD \
  UTEN_FLYWAY_BASELINE_ON_MIGRATE; do
  expect_absent "$key"
done
require_secret UTEN_DB_PASSWORD 20

[[ -d "$POSTGRES_SECRETS" && ! -L "$POSTGRES_SECRETS" ]] \
  || die "$POSTGRES_SECRETS must be a real directory"
[[ "$(stat -c '%U:%G:%a' "$POSTGRES_SECRETS")" == root:postgres:750 ]] \
  || die "$POSTGRES_SECRETS must be root:postgres mode 0750"
app_password_file="$POSTGRES_SECRETS/app.password"
[[ -f "$app_password_file" && ! -L "$app_password_file" ]] \
  || die "$app_password_file must be a regular non-symlink file"
[[ "$(stat -c '%U:%G:%a:%h' "$app_password_file")" == root:postgres:640:1 ]] \
  || die "$app_password_file must be root:postgres mode 0640 with one hard link"
[[ "$(env_value UTEN_DB_PASSWORD)" == "$(<"$app_password_file")" ]] \
  || die 'UTEN_DB_PASSWORD does not match the root-managed app credential'
migrator_password_file="$POSTGRES_SECRETS/migrator.password"
[[ -f "$migrator_password_file" && ! -L "$migrator_password_file" ]] \
  || die "$migrator_password_file must be a regular non-symlink file"
[[ "$(stat -c '%U:%G:%a:%h' "$migrator_password_file")" == root:postgres:640:1 ]] \
  || die "$migrator_password_file must be root:postgres mode 0640 with one hard link"
migrator_password="$(<"$migrator_password_file")"
[[ "$migrator_password" =~ ^[A-Za-z0-9]{20,512}$ ]] \
  || die 'the root-managed migrator credential is outside the reviewed format'
while IFS= read -r environment_line || [[ -n "$environment_line" ]]; do
  [[ -z "$environment_line" || "${environment_line:0:1}" == '#' ]] && continue
  environment_value="${environment_line#*=}"
  [[ "$environment_value" != *"$migrator_password"* ]] \
    || die 'the application environment contains the dedicated migrator credential'
done <"$ENV_FILE"
unset migrator_password environment_line environment_value

require_secret UTEN_JWT_SECRET 32
expect_exact UTEN_JWT_ISSUER uten-imp-internal-test
require_secret UTEN_PGP_MASTER_KEY 32
expect_exact UTEN_PGP_KEY_VERSION 1
require_secret UTEN_HMAC_KEY 32

expect_exact UTEN_REQUIRE_HTTPS true
expect_exact UTEN_SSL_ENABLED false
expect_exact UTEN_TRUSTED_PROXY_REGEX '127[.].*|::1'
expect_exact UTEN_SWAGGER_ENABLED false
expect_boolean UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED
cors="$(require_value UTEN_CORS_ORIGINS)"
IFS=',' read -r -a cors_entries <<<"$cors"
(( ${#cors_entries[@]} > 0 )) || die 'UTEN_CORS_ORIGINS must not be empty'
for origin in "${cors_entries[@]}"; do
  [[ "$origin" == https://* ]] || die 'every CORS origin must use https://'
  [[ "$origin" != *[[:space:]@*]* ]] || die 'CORS origins must not contain whitespace, user information, or wildcards'
  authority="${origin#https://}"
  [[ -n "$authority" && "$authority" != */* && "$authority" != *\?* && "$authority" != *#* ]] \
    || die 'every CORS entry must be exactly https://host[:port]'
  [[ "$authority" != localhost* && ! "$authority" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$ ]] \
    || die 'the internal employee origin must use an approved DNS name, not localhost or a raw IP address'
done

cidrs="$(require_value UTEN_LOCAL_ALLOWED_CIDRS)"
validate_narrow_local_cidrs "$cidrs"

bootstrap_retired="$(env_value UTEN_BOOTSTRAP_ADMIN_RETIRED)"
bootstrap_login="$(require_value BOOTSTRAP_ADMIN_LOGIN)"
[[ "$bootstrap_login" != *[[:space:]]* && ${#bootstrap_login} -le 128 ]] \
  || die 'BOOTSTRAP_ADMIN_LOGIN must be one approved account identifier'
unset bootstrap_login
case "$bootstrap_retired" in
  false)
    require_secret BOOTSTRAP_ADMIN_PASSWORD 32
    ;;
  true)
    [[ -z "$(env_value BOOTSTRAP_ADMIN_PASSWORD)" ]] \
      || die 'BOOTSTRAP_ADMIN_PASSWORD must be empty after controlled retirement'
    ;;
  *)
    die 'UTEN_BOOTSTRAP_ADMIN_RETIRED must be false or true'
    ;;
esac
expect_exact UTEN_SMS_PROVIDER disabled
expect_exact UTEN_SMS_EXPOSE_CODE false
expect_exact UTEN_POLICY_INTELLIGENCE_ENABLED false
expect_exact UTEN_LEGACY_ENABLED false

expect_exact UTEN_STORAGE_PROVIDER local
expect_exact UTEN_STORAGE_LOCAL_DIR /data/uten-imp/attachments
expect_exact UTEN_ATTACHMENT_UPLOADS_ENABLED false
expect_exact UTEN_ATTACHMENT_SCANNER_PROVIDER disabled
expect_exact UTEN_ATTACHMENT_RECONCILIATION_ENABLED false
expect_exact UTEN_STORAGE_MAX_BYTES 26214400
expect_exact UTEN_STORAGE_PRESIGN_EXPIRY 300
for key in UTEN_OSS_ENDPOINT UTEN_OSS_INTERNAL_ENDPOINT UTEN_OSS_STAGING_BUCKET \
  UTEN_OSS_FINAL_BUCKET UTEN_OSS_REGION UTEN_OSS_ACCESS_KEY_ID \
  UTEN_OSS_ACCESS_KEY_SECRET UTEN_OSS_USE_INSTANCE_ROLE UTEN_OSS_ROLE_NAME \
  UTEN_OSS_KEY_PREFIX UTEN_OSS_REQUIRE_VERSIONING DEEPSEEK_API_KEY \
  UTEN_WEBSITE_INQUIRY_INGEST_TOKEN UTEN_LEGACY_DB_URL UTEN_LEGACY_DB_USER \
  UTEN_LEGACY_DB_PASSWORD; do
  expect_absent "$key"
done

printf '%s\n' \
  'INTERNAL_TEST_SERVER_ENV_OK' \
  'Runtime is loopback-only behind HTTPS Nginx; Flyway, Swagger, website integration, external APIs and attachment intake remain disabled.' \
  'Local attachments are pinned to /data/uten-imp/attachments and require the independent storage preflight.'
