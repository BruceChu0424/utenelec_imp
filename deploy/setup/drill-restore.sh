#!/usr/bin/env bash
# Restore a pgBackRest backup into an isolated PostgreSQL instance and validate it.
# No production cluster, database, or configuration file is modified.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE

readonly STANZA=uten-imp
readonly SOCKET_DIR=/var/run/postgresql
readonly PGDATA_ROOT=/data/postgresql
readonly BACKUP_REPO_ROOT=/data/backups
readonly MIN_FREE_MARGIN_BYTES=10737418240
readonly FREE_MARGIN_PERCENT=25
readonly TRUSTED_RELEASE_GUARD=/usr/local/libexec/uten-imp-release/release_guard.py
readonly TRUSTED_RELEASE_ALLOWED_SIGNERS=/etc/uten-imp-release-trust/release-allowed-signers
readonly RECOVERY_RECEIPT_DIR=/var/lib/uten-imp-release/database-receipts

repo=1
port=5433
startup_timeout=300
backup_set=''
target_time=''
restore_base=''
trusted_release_manifest=''
trusted_release_signature=''
expected_release_version=''
expected_flyway_version=''
expected_migration_count=''
recovery_receipt=''
approval_reference=''
min_users=1
min_goods=0
min_sales_orders=0
min_stock_movements=0
min_ar_entries=0
min_audit_rows=0

usage() {
  cat <<'EOF'
Usage: sudo bash drill-restore.sh [options]

  --restore-base PATH              Required dedicated scratch filesystem mount
  --trusted-release-manifest PATH  Required signed production manifest JSON
  --trusted-release-signature PATH Required detached ssh-keygen signature
  --expected-release-version TEXT  Exact signed release version expected
  --recovery-receipt PATH          Optional fixed root-only recovery receipt output
  --approval-reference TEXT        Required change/CAB reference with --recovery-receipt
  --target-time RFC3339             PITR target, e.g. 2026-08-11T10:30:00+08:00
  --backup-set LABEL                Pin a pgBackRest backup set
  --repo NUMBER                     pgBackRest repository number (default: 1)
  --port NUMBER                     Isolated PostgreSQL port (default: 5433)
  --startup-timeout SECONDS         Recovery startup deadline (default: 300)
  --expected-flyway-version NUMBER  Required exact latest successful version
  --expected-migration-count NUMBER Required exact successful versioned rows
  --min-users NUMBER                Minimum users rows (default: 1)
  --min-goods NUMBER                Minimum goods rows (default: 0)
  --min-sales-orders NUMBER         Minimum sales_orders rows (default: 0)
  --min-stock-movements NUMBER      Minimum stock_movements rows (default: 0)
  --min-ar-entries NUMBER           Minimum ar_ap_ledger rows (default: 0)
  --min-audit-rows NUMBER           Minimum audit_log rows (default: 0)
  --help

For a PITR point from an older signed release, pass the Flyway version/count and
business minima that were authoritative at that time. A zero minimum proves
readability and schema presence only; it is not historical business reconciliation.

The restore base must itself be a dedicated mounted scratch filesystem, on a
different device from /, /data/postgresql, and /data/backups. Flyway checksums
must be embedded by CI as `flyway.migrations[].flywayChecksum` in the production
manifest and covered by its Ed25519 signature. An unsigned TSV or an
administrator-supplied checksum/digest is intentionally not accepted.
The audited guard and trust policy are fixed at /usr/local/libexec/uten-imp-release/release_guard.py
and /etc/uten-imp-release-trust/release-allowed-signers; release payload code is never run.
EOF
}

die() {
  printf 'RESTORE_DRILL_ERROR: %s\n' "$*" >&2
  exit 1
}

need_value() {
  [[ "$#" -ge 2 ]] || die "missing value for $1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --restore-base) need_value "$@"; restore_base="$2"; shift 2 ;;
    --trusted-release-manifest) need_value "$@"; trusted_release_manifest="$2"; shift 2 ;;
    --trusted-release-signature) need_value "$@"; trusted_release_signature="$2"; shift 2 ;;
    --expected-release-version) need_value "$@"; expected_release_version="$2"; shift 2 ;;
    --recovery-receipt) need_value "$@"; recovery_receipt="$2"; shift 2 ;;
    --approval-reference) need_value "$@"; approval_reference="$2"; shift 2 ;;
    --target-time) need_value "$@"; target_time="$2"; shift 2 ;;
    --backup-set) need_value "$@"; backup_set="$2"; shift 2 ;;
    --repo) need_value "$@"; repo="$2"; shift 2 ;;
    --port) need_value "$@"; port="$2"; shift 2 ;;
    --startup-timeout) need_value "$@"; startup_timeout="$2"; shift 2 ;;
    --expected-flyway-version) need_value "$@"; expected_flyway_version="$2"; shift 2 ;;
    --expected-migration-count) need_value "$@"; expected_migration_count="$2"; shift 2 ;;
    --min-users) need_value "$@"; min_users="$2"; shift 2 ;;
    --min-goods) need_value "$@"; min_goods="$2"; shift 2 ;;
    --min-sales-orders) need_value "$@"; min_sales_orders="$2"; shift 2 ;;
    --min-stock-movements) need_value "$@"; min_stock_movements="$2"; shift 2 ;;
    --min-ar-entries) need_value "$@"; min_ar_entries="$2"; shift 2 ;;
    --min-audit-rows) need_value "$@"; min_audit_rows="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute restore drill through a symlink'
readonly SCRIPT_FILE="$(realpath -e -- "${BASH_SOURCE[0]}")"
[[ -n "$restore_base" ]] || die '--restore-base is required; /var/tmp and the system/root disk are forbidden'
[[ -n "$trusted_release_manifest" ]] || die '--trusted-release-manifest is required'
[[ -n "$trusted_release_signature" ]] || die '--trusted-release-signature is required'
[[ -n "$expected_release_version" ]] || die '--expected-release-version is required'
[[ -n "$expected_flyway_version" ]] || die '--expected-flyway-version is required'
[[ -n "$expected_migration_count" ]] || die '--expected-migration-count is required'
command -v mountpoint >/dev/null 2>&1 || die 'mountpoint is required'
mountpoint --quiet /data || die '/data backup repository is not on its required mount'
for command_name in pgbackrest psql pg_isready runuser mktemp realpath jq df stat \
  cmp sort awk date ssh-keygen sha256sum python3 readlink dirname basename; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

numeric_values=(
  "$repo" "$port" "$startup_timeout" "$expected_flyway_version"
  "$expected_migration_count" "$min_users" "$min_goods" "$min_sales_orders"
  "$min_stock_movements" "$min_ar_entries" "$min_audit_rows"
)
for numeric_value in "${numeric_values[@]}"; do
  [[ "$numeric_value" =~ ^(0|[1-9][0-9]*)$ ]] \
    || die "numeric argument is invalid or has a leading zero: $numeric_value"
done
(( repo >= 1 && repo <= 9 )) || die '--repo must be between 1 and 9'
(( port >= 1024 && port <= 65535 )) || die '--port must be between 1024 and 65535'
(( port != 5432 )) || die '--port 5432 is reserved for production and may not be used by a restore drill'
(( startup_timeout >= 30 && startup_timeout <= 7200 )) || die '--startup-timeout must be between 30 and 7200 seconds'
(( expected_flyway_version >= 1 )) || die '--expected-flyway-version must be positive'
(( expected_migration_count >= 1 )) || die '--expected-migration-count must be positive'
if [[ -n "$backup_set" ]]; then
  [[ "$backup_set" =~ ^[A-Za-z0-9_-]+$ ]] || die '--backup-set contains unsupported characters'
fi
if [[ -n "$target_time" ]]; then
  readonly PITR_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
  [[ "$target_time" =~ $PITR_PATTERN ]] \
    || die '--target-time must be an RFC3339 timestamp with an explicit timezone'
fi

[[ "$restore_base" == /* ]] || die '--restore-base must be an absolute path'
[[ -d "$restore_base" && ! -L "$restore_base" ]] \
  || die '--restore-base must be an existing, non-symlink directory'
restore_base="$(realpath -e -- "$restore_base")"
[[ "$restore_base" != / ]] || die 'the root filesystem cannot be used as restore scratch space'
mountpoint --quiet "$restore_base" \
  || die '--restore-base must be the mountpoint itself, not a directory on another filesystem'
[[ "$(stat -c '%U' -- "$restore_base")" == root ]] \
  || die '--restore-base mountpoint must be owned by root'
restore_base_mode="$(stat -c '%a' -- "$restore_base")"
(( (8#$restore_base_mode & 0022) == 0 )) \
  || die '--restore-base mountpoint must not be group- or other-writable'

paths_overlap() {
  local first="$1" second="$2"
  [[ "$first" == "$second" ]] && return 0
  case "$first/" in "$second/"*) return 0 ;; esac
  case "$second/" in "$first/"*) return 0 ;; esac
  return 1
}

for protected_data_path in "$PGDATA_ROOT" "$BACKUP_REPO_ROOT"; do
  [[ -d "$protected_data_path" && ! -L "$protected_data_path" ]] \
    || die "required protected data path is missing or a symlink: $protected_data_path"
  protected_data_path="$(realpath -e -- "$protected_data_path")"
  if paths_overlap "$restore_base" "$protected_data_path"; then
    die "restore scratch path overlaps protected data path: $protected_data_path"
  fi
done

scratch_device="$(stat -c '%d' -- "$restore_base")"
root_device="$(stat -c '%d' -- /)"
pgdata_device="$(stat -c '%d' -- "$PGDATA_ROOT")"
backup_repo_device="$(stat -c '%d' -- "$BACKUP_REPO_ROOT")"
[[ "$scratch_device" != "$root_device" ]] \
  || die '--restore-base is on the root filesystem; use a dedicated scratch disk or an independent recovery host'
[[ "$scratch_device" != "$pgdata_device" ]] \
  || die '--restore-base shares a device with /data/postgresql'
[[ "$scratch_device" != "$backup_repo_device" ]] \
  || die '--restore-base shares a device with /data/backups'

[[ "$expected_release_version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
  || die '--expected-release-version contains unsupported characters'
if [[ -n "$recovery_receipt" ]]; then
  [[ -n "$approval_reference" ]] \
    || die '--approval-reference is required with --recovery-receipt'
  [[ "$approval_reference" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$ ]] \
    || die '--approval-reference is not canonical'
  [[ "$recovery_receipt" == "$RECOVERY_RECEIPT_DIR"/* \
    && "$(dirname -- "$recovery_receipt")" == "$RECOVERY_RECEIPT_DIR" ]] \
    || die '--recovery-receipt must be a direct child of the fixed receipt directory'
  recovery_receipt_name="$(basename -- "$recovery_receipt")"
  [[ "$recovery_receipt_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,127}[.]json$ ]] \
    || die '--recovery-receipt filename is not canonical'
  [[ -d "$RECOVERY_RECEIPT_DIR" && ! -L "$RECOVERY_RECEIPT_DIR" ]] \
    || die 'fixed recovery receipt directory is missing or is a symlink'
  [[ "$(realpath -e -- "$RECOVERY_RECEIPT_DIR")" == "$RECOVERY_RECEIPT_DIR" \
    && "$(stat -c '%U:%G:%a' -- "$RECOVERY_RECEIPT_DIR")" == root:root:700 ]] \
    || die 'fixed recovery receipt directory must be canonical root:root 0700'
  [[ ! -e "$recovery_receipt" && ! -L "$recovery_receipt" ]] \
    || die '--recovery-receipt refuses to overwrite an existing path'
elif [[ -n "$approval_reference" ]]; then
  die '--approval-reference is valid only with --recovery-receipt'
fi
secure_root_file() {
  local file_path="$1" label="$2" max_bytes="$3" file_mode file_size current_path
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
secure_root_file "$SCRIPT_FILE" 'restore drill installer' 2097152 >/dev/null
trusted_release_manifest="$(secure_root_file "$trusted_release_manifest" 'trusted release manifest' 2097152)"
trusted_release_signature="$(secure_root_file "$trusted_release_signature" 'trusted release signature' 65536)"
trusted_release_allowed_signers="$(secure_root_file "$TRUSTED_RELEASE_ALLOWED_SIGNERS" 'trusted release allowed_signers policy' 1048576)"
trusted_release_guard="$(secure_root_file "$TRUSTED_RELEASE_GUARD" 'trusted root-installed release guard' 2097152)"

echo '==> Ask the root-installed guard to verify signature, claimed key ID, schema, and Flyway checksums'
if ! trusted_manifest_rows_data="$(/usr/bin/python3 -I "$trusted_release_guard" \
  verified-flyway-checksums \
  --manifest "$trusted_release_manifest" \
  --signature "$trusted_release_signature" \
  --allowed-signers "$trusted_release_allowed_signers" \
  --expected-version "$expected_release_version")"; then
  die 'root-installed release guard rejected the signature, claimed signing key, manifest, or Flyway checksum inventory'
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
  die 'root-installed release guard emitted a non-canonical Flyway checksum inventory'
fi
IFS=$'\t' read -r trusted_manifest_count trusted_manifest_max_version <<<"$manifest_summary"
[[ "$trusted_manifest_count" == "$expected_migration_count" ]] \
  || die "signed Flyway inventory has $trusted_manifest_count rows, expected $expected_migration_count"
[[ "$trusted_manifest_max_version" == "$expected_flyway_version" ]] \
  || die "signed Flyway inventory latest version is $trusted_manifest_max_version, expected $expected_flyway_version"
trusted_migration_set_sha256="$(jq -er \
  '.flyway.migrationSetSha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' \
  "$trusted_release_manifest")" \
  || die 'signed release manifest has no canonical Flyway migration-set digest'

[[ ! -e "$SOCKET_DIR/.s.PGSQL.$port" ]] \
  || die "socket $SOCKET_DIR/.s.PGSQL.$port already exists; inspect the existing process manually"
if pg_isready -q -h "$SOCKET_DIR" -p "$port" -t 1; then
  die "a PostgreSQL server is already accepting connections on port $port"
fi

echo '==> Resolve the exact backup and prove scratch capacity before restore'
if ! backup_inventory="$(runuser -u postgres -- \
  pgbackrest --stanza="$STANZA" --repo="$repo" --output=json info)"; then
  die "could not read pgBackRest repository $repo inventory"
fi
jq -e --arg stanza "$STANZA" \
  'length == 1 and .[0].name == $stanza and .[0].status.code == 0' \
  <<<"$backup_inventory" >/dev/null \
  || die "pgBackRest stanza $STANZA is missing, ambiguous, or unhealthy in repository $repo"

if [[ -n "$backup_set" ]]; then
  if ! selected_backup_json="$(jq -cer --arg label "$backup_set" '
    [.[0].backup[] | select(.label == $label and ((.error // false) == false))]
    | if length == 1 then .[0] else error("backup set missing or ambiguous") end
  ' <<<"$backup_inventory")"; then
    die "backup set is missing, ambiguous, or unhealthy in repository $repo: $backup_set"
  fi
elif [[ -n "$target_time" ]]; then
  if ! target_epoch="$(date --date="$target_time" +%s)"; then
    die '--target-time could not be converted to an epoch timestamp'
  fi
  if ! selected_backup_json="$(jq -cer --argjson target "$target_epoch" '
    [.[0].backup[]
      | select(((.error // false) == false) and (.timestamp.stop <= $target))]
    | if length > 0 then max_by(.timestamp.stop) else error("no eligible backup") end
  ' <<<"$backup_inventory")"; then
    die "no healthy backup completed at or before PITR target $target_time"
  fi
else
  if ! selected_backup_json="$(jq -cer '
    [.[0].backup[] | select((.error // false) == false)]
    | if length > 0 then max_by(.timestamp.stop) else error("no healthy backup") end
  ' <<<"$backup_inventory")"; then
    die "repository $repo contains no healthy backup"
  fi
fi

selected_backup_label="$(jq -er '.label | select(type == "string" and length > 0)' \
  <<<"$selected_backup_json")" \
  || die 'selected pgBackRest backup has no valid label'
selected_database_size="$(jq -er '
  (.info.size // .database.size)
  | select(type == "number" and . > 0 and floor == .)
  | tostring
' <<<"$selected_backup_json")" \
  || die 'selected backup has no reliable full uncompressed database size; use an independently capacity-verified recovery host'
[[ "$selected_database_size" =~ ^[1-9][0-9]*$ ]] \
  || die 'selected backup database size is not a positive integer'

percent_margin=$((
  (selected_database_size / 100 * FREE_MARGIN_PERCENT) +
  ((selected_database_size % 100 * FREE_MARGIN_PERCENT + 99) / 100)
))
if (( percent_margin < MIN_FREE_MARGIN_BYTES )); then
  safety_margin_bytes=$MIN_FREE_MARGIN_BYTES
else
  safety_margin_bytes=$percent_margin
fi
required_free_bytes=$((selected_database_size + safety_margin_bytes))
available_free_bytes="$(df -B1 --output=avail -- "$restore_base" | awk 'NR == 2 {print $1}')"
[[ "$available_free_bytes" =~ ^[1-9][0-9]*$ ]] \
  || die 'could not determine available bytes on the dedicated restore filesystem'
(( available_free_bytes >= required_free_bytes )) \
  || die "insufficient restore scratch space: available=$available_free_bytes required=$required_free_bytes database=$selected_database_size margin=$safety_margin_bytes"
printf 'RESTORE_CAPACITY_OK: backup=%s database_bytes=%s margin_bytes=%s available_bytes=%s scratch_device=%s\n' \
  "$selected_backup_label" "$selected_database_size" "$safety_margin_bytes" \
  "$available_free_bytes" "$scratch_device"

restore_dir=''
tablespace_dir=''
start_attempted=false
drill_succeeded=false
proven_postmaster_pid=''

write_recovery_receipt() {
  local completed_at evidence_reference receipt_sha256
  [[ -n "$recovery_receipt" ]] || return 0
  completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  evidence_reference="pgbackrest:repo=$repo;set=$selected_backup_label;target=${target_time:-latest}"
  if ! /usr/bin/python3 - "$RECOVERY_RECEIPT_DIR" "$recovery_receipt_name" \
    "$approval_reference" "$expected_release_version" "$expected_flyway_version" \
    "$trusted_migration_set_sha256" "$completed_at" "$evidence_reference" <<'PY'
import json
import os
import stat
import sys

(
    directory_text,
    filename,
    approval_reference,
    target_version,
    flyway_head,
    flyway_digest,
    completed_at,
    evidence_reference,
) = sys.argv[1:]
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
if not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit("O_NOFOLLOW is unavailable")
directory_flags |= os.O_NOFOLLOW
directory_fd = os.open(directory_text, directory_flags)
created = False
try:
    directory = os.fstat(directory_fd)
    if (
        not stat.S_ISDIR(directory.st_mode)
        or directory.st_uid != 0
        or directory.st_gid != 0
        or stat.S_IMODE(directory.st_mode) != 0o700
    ):
        raise SystemExit("receipt directory changed after validation")
    payload = {
        "approvalReference": approval_reference,
        "completedAtUtc": completed_at,
        "evidenceReference": evidence_reference,
        "flywayHeadVersion": flyway_head,
        "flywayMigrationSetSha256": flyway_digest,
        "receiptType": "restore",
        "schemaVersion": 1,
        "successful": True,
        "targetVersion": target_version,
    }
    encoded = (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
    descriptor = os.open(filename, flags, 0o600, dir_fd=directory_fd)
    created = True
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise OSError("short recovery receipt write")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.fsync(directory_fd)
except Exception:
    if created:
        try:
            os.unlink(filename, dir_fd=directory_fd)
            os.fsync(directory_fd)
        except OSError:
            pass
    raise
finally:
    os.close(directory_fd)
PY
  then
    printf 'RECOVERY_RECEIPT_FAILED: could not write root-only receipt %s\n' \
      "$recovery_receipt" >&2
    return 1
  fi
  [[ -f "$recovery_receipt" && ! -L "$recovery_receipt" \
    && "$(stat -c '%U:%G:%a:%h' -- "$recovery_receipt")" == root:root:600:1 ]] \
    || {
      printf 'RECOVERY_RECEIPT_FAILED: receipt ownership/mode/link count is unsafe\n' >&2
      return 1
    }
  receipt_sha256="$(sha256sum -- "$recovery_receipt" | awk '{print $1}')"
  [[ "$receipt_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'RECOVERY_RECEIPT_OK: path=%s sha256=%s approval=%s\n' \
    "$recovery_receipt" "$receipt_sha256" "$approval_reference"
}

isolated_postmaster_identity_proven() {
  local postmaster_pid='' process_owner='' process_exe='' process_cwd=''
  local data_arg_found=false socket_path="$SOCKET_DIR/.s.PGSQL.$port"
  local server_identity='' argument_index
  local -a process_args=()

  [[ -n "$restore_dir" && -d "$restore_dir" && -r "$restore_dir/postmaster.pid" ]] \
    || return 1
  IFS= read -r postmaster_pid <"$restore_dir/postmaster.pid" || return 1
  [[ "$postmaster_pid" =~ ^[1-9][0-9]*$ ]] && (( postmaster_pid > 1 )) || return 1
  [[ -d "/proc/$postmaster_pid" ]] || return 1
  process_owner="$(stat -c '%U' -- "/proc/$postmaster_pid" 2>/dev/null)" || return 1
  [[ "$process_owner" == postgres ]] || return 1
  process_exe="$(realpath -e -- "/proc/$postmaster_pid/exe" 2>/dev/null)" || return 1
  [[ "$process_exe" == /usr/lib/postgresql/16/bin/postgres ]] || return 1
  process_cwd="$(realpath -e -- "/proc/$postmaster_pid/cwd" 2>/dev/null)" || return 1
  [[ "$process_cwd" == "$restore_dir" ]] || return 1
  mapfile -d '' -t process_args <"/proc/$postmaster_pid/cmdline" || return 1
  (( ${#process_args[@]} >= 3 )) || return 1
  [[ "${process_args[0]}" == /usr/lib/postgresql/16/bin/postgres ]] || return 1
  for (( argument_index=1; argument_index<${#process_args[@]}; argument_index++ )); do
    if [[ "${process_args[$argument_index]}" == -D ]] \
      && (( argument_index + 1 < ${#process_args[@]} )) \
      && [[ "${process_args[$((argument_index + 1))]}" == "$restore_dir" ]]; then
      data_arg_found=true
      break
    fi
  done
  [[ "$data_arg_found" == true ]] || return 1
  [[ -S "$socket_path" && "$(stat -c '%U' -- "$socket_path" 2>/dev/null)" == postgres ]] \
    || return 1
  runuser -u postgres -- /usr/lib/postgresql/16/bin/pg_ctl \
    -D "$restore_dir" status >/dev/null 2>&1 || return 1
  server_identity="$(runuser -u postgres -- env PGCONNECT_TIMEOUT=2 \
    psql -X -h "$SOCKET_DIR" -p "$port" -d postgres -At -v ON_ERROR_STOP=1 \
      -c "SELECT current_setting('data_directory') || chr(9) || current_setting('port') || chr(9) || current_setting('listen_addresses') || chr(9) || current_setting('unix_socket_directories');" \
      2>/dev/null)" || return 1
  [[ "$server_identity" == "$restore_dir"$'\t'"$port"$'\t\t'"$SOCKET_DIR" ]] || return 1
  proven_postmaster_pid="$postmaster_pid"
  return 0
}

cleanup() {
  local original_status="$?"
  local final_status="$original_status"
  local safe_to_remove=true
  local postmaster_pid=''
  local postgres_might_be_running=false
  local isolated_stop_proven=false
  trap - EXIT INT TERM HUP
  set +e

  if [[ "$start_attempted" == true && -n "$restore_dir" && -d "$restore_dir" ]]; then
    if isolated_postmaster_identity_proven; then
      if ! runuser -u postgres -- /usr/lib/postgresql/16/bin/pg_ctl \
        -D "$restore_dir" -w -t 60 stop -m fast >/dev/null 2>&1; then
        printf 'RESTORE_DRILL_CLEANUP_FAILED: identity-proven isolated PostgreSQL did not stop; directory retained\n' >&2
        postgres_might_be_running=true
      elif ! kill -0 -- "$proven_postmaster_pid" 2>/dev/null \
        && [[ ! -e "$restore_dir/postmaster.pid" ]] \
        && [[ ! -e "$SOCKET_DIR/.s.PGSQL.$port" ]] \
        && ! runuser -u postgres -- /usr/lib/postgresql/16/bin/pg_ctl \
          -D "$restore_dir" status >/dev/null 2>&1; then
        isolated_stop_proven=true
      else
        printf 'RESTORE_DRILL_CLEANUP_FAILED: stop returned but exact PID/data/socket shutdown could not be proven; directory retained\n' >&2
        postgres_might_be_running=true
      fi
    else
      # Evidence that is incomplete or contradictory is never enough to signal
      # a PID: it may have been reused by an unrelated process.
      if [[ -r "$restore_dir/postmaster.pid" ]]; then
        IFS= read -r postmaster_pid <"$restore_dir/postmaster.pid" || postmaster_pid=''
        if [[ "$postmaster_pid" =~ ^[1-9][0-9]*$ ]] && (( postmaster_pid > 1 )) \
          && kill -0 -- "$postmaster_pid" 2>/dev/null; then
          postgres_might_be_running=true
        fi
      fi
      if runuser -u postgres -- /usr/lib/postgresql/16/bin/pg_ctl -D "$restore_dir" status >/dev/null 2>&1 \
        || [[ -e "$SOCKET_DIR/.s.PGSQL.$port" ]]; then
        postgres_might_be_running=true
      fi
      printf 'RESTORE_DRILL_CLEANUP_FAILED: PostgreSQL identity could not be proven; no signal was sent and directory is retained for manual handling\n' >&2
      postgres_might_be_running=true
    fi

    # Re-evaluate from scratch after the only permitted stop attempt.
    if [[ "$postgres_might_be_running" != true ]]; then
      postgres_might_be_running=false
    fi
    postmaster_pid=''
    if [[ -r "$restore_dir/postmaster.pid" ]]; then
      IFS= read -r postmaster_pid <"$restore_dir/postmaster.pid" || postmaster_pid=''
      if [[ "$postmaster_pid" =~ ^[1-9][0-9]*$ ]] && (( postmaster_pid > 1 )) \
        && kill -0 -- "$postmaster_pid" 2>/dev/null; then
        postgres_might_be_running=true
      fi
    fi
    if runuser -u postgres -- /usr/lib/postgresql/16/bin/pg_ctl -D "$restore_dir" status >/dev/null 2>&1; then
      postgres_might_be_running=true
    fi
    if [[ -e "$SOCKET_DIR/.s.PGSQL.$port" ]]; then
      postgres_might_be_running=true
    fi
    if [[ "$postgres_might_be_running" == true ]]; then
      printf 'RESTORE_DRILL_CLEANUP_FAILED: isolated PostgreSQL PID/socket may still be live at %s; directory retained\n' "$restore_dir" >&2
      safe_to_remove=false
      final_status=1
    fi
  fi

  if [[ "$start_attempted" == true && "$isolated_stop_proven" != true ]]; then
    safe_to_remove=false
    final_status=1
  fi

  if [[ -n "$restore_dir" && "$safe_to_remove" == true ]]; then
    if ! mountpoint --quiet "$restore_base" \
      || [[ "$(stat -c '%d' -- "$restore_base" 2>/dev/null)" != "$scratch_device" ]]; then
      printf 'RESTORE_DRILL_CLEANUP_REFUSED: scratch mount disappeared or changed device; directory retained: %s\n' "$restore_dir" >&2
      safe_to_remove=false
      final_status=1
    fi
  fi

  if [[ -n "$restore_dir" && "$safe_to_remove" == true ]]; then
    case "$restore_dir" in
      "$restore_base"/uten-pg-restore.*)
        if [[ -L "$restore_dir" || -L "$tablespace_dir" ]] \
          || [[ "$tablespace_dir" != "$restore_dir.tablespaces" ]]; then
          printf 'RESTORE_DRILL_CLEANUP_REFUSED: restore/tablespace path became unsafe: %s %s\n' "$restore_dir" "$tablespace_dir" >&2
          final_status=1
        else
          if ! rm -rf -- "$tablespace_dir" "$restore_dir"; then
            printf 'RESTORE_DRILL_CLEANUP_FAILED: could not remove isolated restore paths %s %s\n' "$restore_dir" "$tablespace_dir" >&2
            final_status=1
          fi
        fi
        ;;
      *)
        printf 'RESTORE_DRILL_CLEANUP_REFUSED: unexpected directory %s\n' "$restore_dir" >&2
        final_status=1
        ;;
    esac
  fi

  if [[ "$final_status" -eq 0 && "$drill_succeeded" != true ]]; then
    final_status=1
  fi
  if [[ "$final_status" -eq 0 && "$drill_succeeded" == true \
    && -n "$recovery_receipt" ]]; then
    if ! write_recovery_receipt; then
      final_status=1
    fi
  fi
  if [[ "$final_status" -eq 0 && "$drill_succeeded" == true ]]; then
    printf '%s\n' 'RESTORE_DRILL_OK'
  else
    printf '%s\n' 'RESTORE_DRILL_FAILED' >&2
  fi
  exit "$final_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo '==> Create a unique isolated restore directory'
restore_dir="$(mktemp -d -p "$restore_base" uten-pg-restore.XXXXXX)"
restore_dir="$(realpath -- "$restore_dir")"
case "$restore_dir" in
  "$restore_base"/uten-pg-restore.*) ;;
  *) die "mktemp returned an unexpected path: $restore_dir" ;;
esac
chown postgres:postgres "$restore_dir"
chmod 0700 "$restore_dir"
tablespace_dir="$restore_dir.tablespaces"
[[ ! -e "$tablespace_dir" && ! -L "$tablespace_dir" ]] \
  || die "isolated tablespace scratch path already exists: $tablespace_dir"
install -d -m 0700 -o postgres -g postgres "$tablespace_dir"
tablespace_dir="$(realpath -- "$tablespace_dir")"
[[ "$tablespace_dir" == "$restore_dir.tablespaces" ]] \
  || die "isolated tablespace path escaped its restore namespace: $tablespace_dir"

restore_args=(
  --stanza="$STANZA"
  --repo="$repo"
  --pg1-path="$restore_dir"
  --set="$selected_backup_label"
  --tablespace-map-all="$tablespace_dir"
  --log-level-console=warn
)
if [[ -n "$target_time" ]]; then
  restore_args+=(--type=time --target="$target_time" --target-action=promote)
fi

if [[ -n "$target_time" ]]; then
  printf '==> Restore repository %s to controlled PITR target %s\n' "$repo" "$target_time"
else
  printf '==> Restore the latest recoverable state from repository %s\n' "$repo"
fi
runuser -u postgres -- pgbackrest "${restore_args[@]}" restore

echo '==> Replace runtime settings with an isolated, Unix-socket-only configuration'
cat >"$restore_dir/postgresql.conf" <<CONF
port = $port
listen_addresses = ''
unix_socket_directories = '$SOCKET_DIR'
unix_socket_permissions = 0700
ssl = off
archive_mode = off
archive_command = ''
shared_buffers = 128MB
max_connections = 20
logging_collector = off
CONF
cat >"$restore_dir/pg_hba.conf" <<'HBA'
local all postgres peer
local all all reject
host all all 127.0.0.1/32 reject
host all all ::1/128 reject
HBA
: >"$restore_dir/pg_ident.conf"
chown postgres:postgres \
  "$restore_dir/postgresql.conf" "$restore_dir/pg_hba.conf" "$restore_dir/pg_ident.conf"
chmod 0600 \
  "$restore_dir/postgresql.conf" "$restore_dir/pg_hba.conf" "$restore_dir/pg_ident.conf"

echo '==> Start the isolated recovery instance'
start_attempted=true
runuser -u postgres -- /usr/lib/postgresql/16/bin/pg_ctl \
  -D "$restore_dir" \
  -o "-p $port -c listen_addresses=''" \
  -w -t "$startup_timeout" start \
  -l "$restore_dir/postgres.log"

psql_drill() {
  runuser -u postgres -- psql -X -h "$SOCKET_DIR" -p "$port" \
    -d "$1" -At -v ON_ERROR_STOP=1 -c "$2"
}

echo '==> Validate recovery completion and the expected business database'
[[ "$(psql_drill postgres "SELECT pg_is_in_recovery()::int;")" == 0 ]] \
  || die 'isolated instance did not finish recovery/promote at the requested target'
[[ "$(psql_drill postgres "SELECT count(*) FROM pg_database WHERE datname='uten_imp';")" == 1 ]] \
  || die 'uten_imp database is missing from the restored cluster'

echo '==> Validate Flyway history without mutating it'
[[ "$(psql_drill uten_imp "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL;")" == t ]] \
  || die 'flyway_schema_history is missing'
failed_migrations="$(psql_drill uten_imp 'SELECT count(*) FROM flyway_schema_history WHERE success IS DISTINCT FROM true;')"
[[ "$failed_migrations" == 0 ]] || die "Flyway history contains $failed_migrations failed or indeterminate rows"
invalid_successful_history_count="$(psql_drill uten_imp "SELECT count(*) FROM flyway_schema_history WHERE success AND (version IS NULL OR version !~ '^[1-9][0-9]*$' OR checksum IS NULL OR type IS DISTINCT FROM 'SQL');")"
[[ "$invalid_successful_history_count" == 0 ]] \
  || die 'Flyway history contains a successful repeatable/non-SQL row, a null version/checksum, or a non-canonical version'
latest_flyway_version="$(psql_drill uten_imp "SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1;")"
[[ "$latest_flyway_version" == "$expected_flyway_version" ]] \
  || die "latest Flyway version is $latest_flyway_version, expected $expected_flyway_version"
successful_migration_count="$(psql_drill uten_imp "SELECT count(*) FROM flyway_schema_history WHERE success AND version IS NOT NULL;")"
[[ "$successful_migration_count" == "$expected_migration_count" ]] \
  || die "successful versioned Flyway row count is $successful_migration_count, expected $expected_migration_count"
successful_history_count="$(psql_drill uten_imp 'SELECT count(*) FROM flyway_schema_history WHERE success;')"
[[ "$successful_history_count" == "$expected_migration_count" ]] \
  || die "Flyway history contains an unenumerated successful row (total=$successful_history_count, expected=$expected_migration_count)"
duplicate_successful_history_count="$(psql_drill uten_imp "SELECT count(*) FROM (SELECT version FROM flyway_schema_history WHERE success GROUP BY version HAVING count(*) <> 1 UNION ALL SELECT script FROM flyway_schema_history WHERE success GROUP BY script HAVING count(*) <> 1) AS duplicates;")"
[[ "$duplicate_successful_history_count" == 0 ]] \
  || die "Flyway history contains $duplicate_successful_history_count duplicate successful versions or scripts"

echo '==> Compare restored Flyway rows with the independently trusted release manifest'
trusted_manifest_rows="$restore_dir/trusted-flyway.tsv"
restored_manifest_rows="$restore_dir/restored-flyway.tsv"
printf '%s\n' "$trusted_manifest_rows_data" \
  | LC_ALL=C sort -t $'\t' -k1,1n >"$trusted_manifest_rows"
psql_drill uten_imp \
  "SELECT version || chr(9) || script || chr(9) || checksum::text FROM flyway_schema_history WHERE success ORDER BY version::bigint;" \
  | LC_ALL=C sort -t $'\t' -k1,1n >"$restored_manifest_rows"
chmod 0600 "$trusted_manifest_rows" "$restored_manifest_rows"
cmp --silent -- "$trusted_manifest_rows" "$restored_manifest_rows" \
  || die 'restored Flyway versions/scripts/checksums differ from the signed production release manifest'
printf 'TRUSTED_FLYWAY_MANIFEST_OK: release=%s rows=%s latest=%s\n' \
  "$expected_release_version" "$trusted_manifest_count" "$trusted_manifest_max_version"

echo '==> Validate required core tables and operator-supplied minimum row controls'
required_tables=(users audit_log goods sales_orders stock_movements ar_ap_ledger gl_vouchers)
if (( expected_flyway_version >= 240 )); then
  required_tables+=(attachments)
fi
if (( expected_flyway_version >= 251 )); then
  required_tables+=(goods_import_batches goods_import_creations)
fi
if (( expected_flyway_version >= 275 )); then
  required_tables+=(system_master_category_registry)
fi
if (( expected_flyway_version >= 279 )); then
  required_tables+=(
    business_identifier_namespaces
    business_identifier_reservations
    business_identifier_conflicts
  )
fi
if (( expected_flyway_version >= 285 )); then
  required_tables+=(client_default_settlement_migration_issues)
fi
if (( expected_flyway_version >= 288 )); then
  required_tables+=(production_material_analysis_borrows)
fi
for table_name in "${required_tables[@]}"; do
  [[ "$(psql_drill uten_imp "SELECT to_regclass('public.$table_name') IS NOT NULL;")" == t ]] \
    || die "required core table is missing: $table_name"
done
if (( expected_flyway_version >= 289 )); then
  borrow_trigger_count="$(psql_drill uten_imp "SELECT count(*) FROM pg_trigger WHERE tgrelid='production_material_analysis_borrows'::regclass AND NOT tgisinternal AND tgname IN ('trg_guard_production_material_analysis_borrow_mutation','trg_set_updated_at_production_material_analysis_borrows','trg_validate_pma_borrow_endpoint','trg_audit_production_material_analysis_borrows');")"
  [[ "$borrow_trigger_count" == 4 ]] \
    || die 'V289 production material-analysis borrow guards/audit are incomplete'
fi

check_minimum() {
  local table_name="$1" minimum="$2" actual
  actual="$(psql_drill uten_imp "SELECT count(*) FROM public.$table_name;")"
  (( actual >= minimum )) \
    || die "$table_name has $actual rows, below required minimum $minimum"
  printf 'CONTROL_OK: %s rows=%s minimum=%s\n' "$table_name" "$actual" "$minimum"
}

check_minimum users "$min_users"
check_minimum goods "$min_goods"
check_minimum sales_orders "$min_sales_orders"
check_minimum stock_movements "$min_stock_movements"
check_minimum ar_ap_ledger "$min_ar_entries"
check_minimum audit_log "$min_audit_rows"

printf 'FLYWAY_CONTROL_OK: version=%s successful_versioned_rows=%s\n' \
  "$latest_flyway_version" "$successful_migration_count"
if [[ -n "$target_time" ]]; then
  printf 'PITR_CONTROL_OK: target=%s repo=%s\n' "$target_time" "$repo"
else
  printf 'LATEST_RESTORE_CONTROL_OK: repo=%s\n' "$repo"
fi
printf '%s\n' \
  'NOTE: row minima and Flyway metadata checks do not replace finance, inventory, attachment-content, or source-system reconciliation.' \
  'DR_EVIDENCE_REQUIRED: retain the signed manifest/signature, then-current allowed_signers, signing-key fingerprint and revocation record, compatible root-installed release_guard source plus SHA-256, exact backup/PITR identifiers, and this drill output.' \
  'DR_SECRET_ESCROW_REQUIRED: separately preserve encrypted pgBackRest/application key material under approved offline access control; never place secret bytes in the ordinary drill report.'
drill_succeeded=true
