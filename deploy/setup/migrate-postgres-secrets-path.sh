#!/usr/bin/env bash
# One-time, fail-closed migration out of the application-readable /etc tree.
# Secret bytes are never printed, regenerated, or overwritten.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly LEGACY_ROLE_SECRETS=/etc/uten-imp/postgres-secrets
readonly LEGACY_PGBACKREST_SECRETS=/etc/uten-imp/pgbackrest-secrets
readonly DESTINATION=/etc/uten-imp-postgres
readonly CONFIRMATION='MIGRATE POSTGRES SECRETS TO /etc/uten-imp-postgres'

die() {
  printf 'POSTGRES_SECRET_MIGRATION_REFUSED: %s\n' "$*" >&2
  exit 1
}

require_root_installer() {
  local source_file current mode
  [[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute secret migration through a symlink'
  source_file="$(realpath -e -- "${BASH_SOURCE[0]}")"
  [[ -f "$source_file" && "$(stat -c '%U:%h' -- "$source_file")" == root:1 ]] \
    || die 'secret migration installer must be root-owned with one hard link'
  mode="$(stat -c '%a' -- "$source_file")"
  (( (8#$mode & 0022) == 0 )) || die 'secret migration installer is group- or other-writable'
  current="$(dirname -- "$source_file")"
  while :; do
    [[ -d "$current" && ! -L "$current" && "$(stat -c '%U' -- "$current")" == root ]] \
      || die "unsafe secret migration installer directory: $current"
    mode="$(stat -c '%a' -- "$current")"
    (( (8#$mode & 0022) == 0 )) || die "secret migration installer directory is writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

usage() {
  cat <<EOF
Usage:
  sudo bash migrate-postgres-secrets-path.sh \\
    --confirm '$CONFIRMATION'

The destination must not exist. Only the reviewed role password files and the
optional pgBackRest repo1 cipher file are accepted. Exact bytes are copied to a
root:postgres 0750 staging directory, verified without display, atomically
published, and only then removed from the legacy paths.
EOF
}

confirmation=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
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
require_root_installer
[[ "$confirmation" == "$CONFIRMATION" ]] \
  || die "explicit confirmation is required: --confirm '$CONFIRMATION'"
for command_name in stat find basename mktemp install cmp sync mv rm rmdir tail od tr; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "required command not found: $command_name"
done
[[ ! -L /etc/uten-imp ]] || die '/etc/uten-imp must not be a symlink'
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] \
  || die "$DESTINATION already exists; refusing to merge or overwrite secrets"
[[ -d "$LEGACY_ROLE_SECRETS" && ! -L "$LEGACY_ROLE_SECRETS" ]] \
  || die "$LEGACY_ROLE_SECRETS must be the existing real directory"
[[ "$(stat -c '%U:%G:%a' "$LEGACY_ROLE_SECRETS")" == postgres:postgres:700 ]] \
  || die "$LEGACY_ROLE_SECRETS must remain postgres:postgres mode 0700 before migration"

role_secret_names=(admin.password repl.password app.password)
if [[ -e "$LEGACY_ROLE_SECRETS/migrator.password" || -L "$LEGACY_ROLE_SECRETS/migrator.password" ]]; then
  role_secret_names+=(migrator.password)
fi

validate_secret_bytes() {
  local secret_path="$1" expected_metadata="$2" secret_value file_size value_size last_byte
  local LC_ALL=C
  [[ -f "$secret_path" && ! -L "$secret_path" ]] \
    || die "secret must be a regular, non-symlink file: $secret_path"
  [[ "$(stat -c '%U:%G:%a:%h' "$secret_path")" == "$expected_metadata:1" ]] \
    || die "secret metadata or hard-link count is invalid: $secret_path"
  file_size="$(stat -c '%s' "$secret_path")"
  (( file_size >= 20 && file_size <= 513 )) \
    || die "secret byte length is outside the reviewed 20-512 character range: $secret_path"
  secret_value="$(<"$secret_path")"
  value_size="${#secret_value}"
  (( value_size >= 20 && value_size <= 512 )) \
    || die "secret content length is outside the reviewed range: $secret_path"
  [[ "$secret_value" =~ ^[[:graph:]]+$ ]] \
    || die "secret contains whitespace, a control character, or non-printable bytes: $secret_path"
  if (( file_size == value_size + 1 )); then
    last_byte="$(tail -c 1 -- "$secret_path" | od -An -tu1 | tr -d '[:space:]')"
    [[ "$last_byte" == 10 ]] \
      || die "secret has an unexpected trailing byte: $secret_path"
  elif (( file_size != value_size )); then
    die "secret must contain exactly one non-empty line with at most one trailing LF: $secret_path"
  fi
  unset secret_value
}

for role_secret_name in "${role_secret_names[@]}"; do
  validate_secret_bytes "$LEGACY_ROLE_SECRETS/$role_secret_name" postgres:postgres:600
done
while IFS= read -r -d '' legacy_entry; do
  case "$(basename -- "$legacy_entry")" in
    admin.password|repl.password|app.password|migrator.password) ;;
    *) die "unreviewed entry exists in legacy role secret directory: $legacy_entry" ;;
  esac
done < <(find "$LEGACY_ROLE_SECRETS" -mindepth 1 -maxdepth 1 -print0)

has_pgbackrest_secret=false
if [[ -e "$LEGACY_PGBACKREST_SECRETS" || -L "$LEGACY_PGBACKREST_SECRETS" ]]; then
  [[ -d "$LEGACY_PGBACKREST_SECRETS" && ! -L "$LEGACY_PGBACKREST_SECRETS" ]] \
    || die "$LEGACY_PGBACKREST_SECRETS must be a real directory"
  [[ "$(stat -c '%U:%G:%a' "$LEGACY_PGBACKREST_SECRETS")" == root:postgres:700 ]] \
    || die "$LEGACY_PGBACKREST_SECRETS must be root:postgres mode 0700"
  validate_secret_bytes "$LEGACY_PGBACKREST_SECRETS/repo1.cipher" root:postgres:640
  [[ "$(find "$LEGACY_PGBACKREST_SECRETS" -mindepth 1 -maxdepth 1 -printf '%f\n')" == repo1.cipher ]] \
    || die "unreviewed entry exists in $LEGACY_PGBACKREST_SECRETS"
  has_pgbackrest_secret=true
fi

staging="$(mktemp -d -p /etc .uten-imp-postgres.migrate.XXXXXX)"
cleanup() {
  local original_status="$?"
  trap - EXIT
  if [[ -n "${staging:-}" && -d "$staging" ]]; then
    case "$staging" in
      /etc/.uten-imp-postgres.migrate.*) rm -rf -- "$staging" ;;
      *) printf 'POSTGRES_SECRET_MIGRATION_CLEANUP_REFUSED: unexpected staging path %s\n' "$staging" >&2 ;;
    esac
  fi
  exit "$original_status"
}
trap cleanup EXIT
chown root:postgres "$staging"
chmod 0750 "$staging"
for role_secret_name in "${role_secret_names[@]}"; do
  install -m 0640 -o root -g postgres \
    "$LEGACY_ROLE_SECRETS/$role_secret_name" "$staging/$role_secret_name"
  cmp --silent -- "$LEGACY_ROLE_SECRETS/$role_secret_name" "$staging/$role_secret_name" \
    || die "byte verification failed for $role_secret_name"
done
if [[ "$has_pgbackrest_secret" == true ]]; then
  install -d -m 0750 -o root -g postgres "$staging/pgbackrest"
  install -m 0640 -o root -g postgres \
    "$LEGACY_PGBACKREST_SECRETS/repo1.cipher" "$staging/pgbackrest/repo1.cipher"
  cmp --silent -- "$LEGACY_PGBACKREST_SECRETS/repo1.cipher" "$staging/pgbackrest/repo1.cipher" \
    || die 'byte verification failed for repo1.cipher'
fi
sync -f "$staging"

[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] \
  || die "$DESTINATION appeared during validation; refusing to overwrite it"
mv -T --no-clobber -- "$staging" "$DESTINATION"
[[ -d "$DESTINATION" && ! -L "$DESTINATION" && ! -e "$staging" ]] \
  || die 'atomic destination publish did not complete; legacy source remains authoritative'
staging=''
sync -f /etc

for role_secret_name in "${role_secret_names[@]}"; do
  cmp --silent -- "$LEGACY_ROLE_SECRETS/$role_secret_name" "$DESTINATION/$role_secret_name" \
    || die "post-publish byte verification failed for $role_secret_name; legacy source retained"
done
if [[ "$has_pgbackrest_secret" == true ]]; then
  cmp --silent -- "$LEGACY_PGBACKREST_SECRETS/repo1.cipher" "$DESTINATION/pgbackrest/repo1.cipher" \
    || die 'post-publish byte verification failed for repo1.cipher; legacy source retained'
fi

for role_secret_name in "${role_secret_names[@]}"; do
  rm -f -- "$LEGACY_ROLE_SECRETS/$role_secret_name"
done
rmdir -- "$LEGACY_ROLE_SECRETS"
if [[ "$has_pgbackrest_secret" == true ]]; then
  rm -f -- "$LEGACY_PGBACKREST_SECRETS/repo1.cipher"
  rmdir -- "$LEGACY_PGBACKREST_SECRETS"
fi
sync -f /etc/uten-imp

printf '%s\n' \
  'POSTGRES_SECRET_PATH_MIGRATION_OK' \
  'Secret bytes were preserved and were not displayed. Legacy secret files were removed only after byte-for-byte destination verification.'
