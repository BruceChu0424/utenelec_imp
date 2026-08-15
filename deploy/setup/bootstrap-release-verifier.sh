#!/usr/bin/env bash
# Install only the audited release verifier and one pinned Ed25519 public key.
# This is the minimal trust bootstrap required before a signed DB-history check.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE

readonly CONFIRMATION='INSTALL UTEN RELEASE VERIFIER'
readonly TARGET_ROOT=/usr/local/libexec
readonly TARGET_GUARD_DIR=/usr/local/libexec/uten-imp-release
readonly TARGET_GUARD=/usr/local/libexec/uten-imp-release/release_guard.py
readonly TARGET_TRUST_DIR=/etc/uten-imp-release-trust
readonly TARGET_ALLOWED_SIGNERS=/etc/uten-imp-release-trust/release-allowed-signers
readonly LOCK_FILE=/run/lock/uten-imp-release-verifier-bootstrap.lock

release_public_key=''
expected_signing_fingerprint=''
expected_guard_sha256=''
confirmation=''
temporary_files=()

die() {
  printf 'VERIFIER_BOOTSTRAP_REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash bootstrap-release-verifier.sh \
    --release-public-key /root/trusted-release/release-signing-key.pub \
    --expected-signing-fingerprint SHA256:REVIEWED_OUT_OF_BAND_VALUE \
    --expected-guard-sha256 REVIEWED_64_LOWERCASE_HEX_DIGEST \
    --confirm 'INSTALL UTEN RELEASE VERIFIER'

The fingerprint and release_guard.py SHA-256 must come from an independent,
reviewed channel. This script installs no downloader, credential, timer,
application release, or auto-start unit. It refuses to replace an existing
trust bootstrap with different bytes or a different key.
EOF
}

need_value() {
  [[ "$#" -ge 2 ]] || die "missing value for $1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --release-public-key) need_value "$@"; release_public_key="$2"; shift 2 ;;
    --expected-signing-fingerprint) need_value "$@"; expected_signing_fingerprint="$2"; shift 2 ;;
    --expected-guard-sha256) need_value "$@"; expected_guard_sha256="$2"; shift 2 ;;
    --confirm) need_value "$@"; confirmation="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ "$confirmation" == "$CONFIRMATION" ]] \
  || die "--confirm must exactly equal: $CONFIRMATION"
[[ "$expected_signing_fingerprint" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] \
  || die '--expected-signing-fingerprint must be one canonical OpenSSH SHA256 fingerprint'
[[ "$expected_guard_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || die '--expected-guard-sha256 must be 64 lowercase hexadecimal characters'
[[ -n "$release_public_key" ]] || die '--release-public-key is required'

for command_name in realpath readlink stat dirname install mktemp sha256sum ssh-keygen \
  awk grep cmp find sort flock sync mv; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute through a symlink'
readonly SCRIPT_FILE="$(realpath -e -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(dirname -- "$SCRIPT_FILE")"
readonly DEPLOY_ROOT="$(realpath -e -- "$SCRIPT_DIR/..")"
readonly SOURCE_GUARD="$DEPLOY_ROOT/updater/release_guard.py"

secure_root_directory_chain() {
  local current="$1" mode
  [[ "$current" == /* ]] || die "trusted directory must be absolute: $current"
  [[ "$(realpath -e -- "$current")" == "$current" ]] \
    || die "trusted directory path is non-canonical or contains a symlink: $current"
  while :; do
    [[ -d "$current" && ! -L "$current" ]] || die "unsafe trusted directory: $current"
    [[ "$(stat -c '%U' -- "$current")" == root ]] \
      || die "trusted directory is not root-owned: $current"
    mode="$(stat -c '%a' -- "$current")"
    (( (8#$mode & 0022) == 0 )) \
      || die "trusted directory is group- or other-writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

secure_root_file() {
  local file_path="$1" label="$2" max_bytes="$3" mode size
  [[ "$file_path" == /* ]] || die "$label must be an absolute path"
  [[ -f "$file_path" && ! -L "$file_path" ]] \
    || die "$label must be a regular, non-symlink file"
  [[ "$(realpath -e -- "$file_path")" == "$file_path" ]] \
    || die "$label path must be canonical and contain no symlink component"
  [[ "$(stat -c '%U:%h' -- "$file_path")" == root:1 ]] \
    || die "$label must be root-owned with one hard link"
  mode="$(stat -c '%a' -- "$file_path")"
  (( (8#$mode & 0022) == 0 )) || die "$label is group- or other-writable"
  size="$(stat -c '%s' -- "$file_path")"
  (( size > 0 && size <= max_bytes )) || die "$label has an unsafe size"
  secure_root_directory_chain "$(dirname -- "$file_path")"
  printf '%s' "$file_path"
}

ensure_exact_directory() {
  local path="$1" owner_group="$2" mode="$3" parent
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || die "managed directory is unsafe: $path"
    [[ "$(stat -c '%U:%G:%a' -- "$path")" == "$owner_group:$mode" ]] \
      || die "managed directory metadata differs from $owner_group mode $mode: $path"
    secure_root_directory_chain "$path"
    return
  fi
  parent="$(dirname -- "$path")"
  secure_root_directory_chain "$parent"
  install -d -m "0$mode" -o "${owner_group%%:*}" -g "${owner_group##*:}" "$path"
  sync -f "$parent"
  [[ "$(stat -c '%U:%G:%a' -- "$path")" == "$owner_group:$mode" ]] \
    || die "failed to create the exact managed directory: $path"
}

cleanup_temporaries() {
  local status="$?" path
  trap - EXIT
  for path in "${temporary_files[@]:-}"; do
    case "$path" in
      "$TARGET_GUARD_DIR"/.release_guard.py.*|"$TARGET_TRUST_DIR"/.release-allowed-signers.*)
        if [[ -f "$path" && ! -L "$path" ]]; then
          rm -f -- "$path" || true
        fi
        ;;
    esac
  done
  exit "$status"
}
trap cleanup_temporaries EXIT

secure_root_directory_chain /run/lock
if [[ ! -e "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
  install -m 0600 -o root -g root /dev/null "$LOCK_FILE"
fi
[[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || die 'bootstrap lock is not a regular file'
[[ "$(stat -c '%U:%G:%a:%h' -- "$LOCK_FILE")" == root:root:600:1 ]] \
  || die 'bootstrap lock must be root:root mode 0600 with one hard link'
exec 9<>"$LOCK_FILE"
flock -n 9 || die 'another release-verifier bootstrap is running'

secure_root_file "$SCRIPT_FILE" 'bootstrap installer' 1048576 >/dev/null
secure_root_file "$SOURCE_GUARD" 'reviewed release guard source' 2097152 >/dev/null
release_public_key="$(secure_root_file "$release_public_key" 'release public key' 16384)"

actual_guard_sha256="$(sha256sum -- "$SOURCE_GUARD" | awk '{print $1}')"
[[ "$actual_guard_sha256" == "$expected_guard_sha256" ]] \
  || die 'release guard SHA-256 differs from the independently reviewed value'

[[ "$(grep -Ec '^[^[:space:]#]' "$release_public_key")" == 1 ]] \
  || die 'release public-key file must contain exactly one key'
key_line="$(grep -E '^[^[:space:]#]' "$release_public_key")"
[[ "$key_line" =~ ^ssh-ed25519[[:space:]]+([A-Za-z0-9+/]+={0,2})([[:space:]]+[A-Za-z0-9._@+-]{1,128})?$ ]] \
  || die 'release public key must be one canonical Ed25519 public-key line'
release_key_blob="${BASH_REMATCH[1]}"
fingerprint_output="$(ssh-keygen -E sha256 -lf "$release_public_key")" \
  || die 'release public key cannot be fingerprinted'
[[ "$(grep -Ec '^[0-9]+[[:space:]]+SHA256:' <<<"$fingerprint_output")" == 1 ]] \
  || die 'release public key produced an ambiguous fingerprint result'
actual_fingerprint="$(awk 'NR == 1 {print $2}' <<<"$fingerprint_output")"
[[ "$actual_fingerprint" == "$expected_signing_fingerprint" ]] \
  || die 'release signing fingerprint differs from the independently reviewed value'

ensure_exact_directory "$TARGET_ROOT" root:root 755
ensure_exact_directory "$TARGET_GUARD_DIR" root:root 755
ensure_exact_directory "$TARGET_TRUST_DIR" root:root 750

mapfile -t existing_guard_entries < <(find "$TARGET_GUARD_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
if (( ${#existing_guard_entries[@]} > 0 )); then
  [[ "${#existing_guard_entries[@]}" == 1 && "${existing_guard_entries[0]}" == release_guard.py ]] \
    || die 'the stable verifier directory is not an exact verifier-only bootstrap; use a separately audited trust-maintenance path'
fi
mapfile -t existing_trust_entries < <(find "$TARGET_TRUST_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
if (( ${#existing_trust_entries[@]} > 0 )); then
  [[ "${#existing_trust_entries[@]}" == 1 && "${existing_trust_entries[0]}" == release-allowed-signers ]] \
    || die 'the stable trust directory is not an exact verifier-only bootstrap; use a separately audited trust-maintenance path'
fi

if [[ -e "$TARGET_GUARD" || -L "$TARGET_GUARD" ]]; then
  secure_root_file "$TARGET_GUARD" 'installed release guard' 2097152 >/dev/null
  [[ "$(stat -c '%U:%G:%a:%h' -- "$TARGET_GUARD")" == root:root:644:1 ]] \
    || die 'installed release guard metadata differs from root:root mode 0644 with one hard link'
  cmp -s -- "$SOURCE_GUARD" "$TARGET_GUARD" \
    || die 'an existing installed release guard has different bytes; replacement is refused'
else
  guard_tmp="$(mktemp "$TARGET_GUARD_DIR/.release_guard.py.XXXXXX")"
  temporary_files+=("$guard_tmp")
  install -m 0644 -o root -g root "$SOURCE_GUARD" "$guard_tmp"
  sync -f "$guard_tmp"
  [[ ! -e "$TARGET_GUARD" && ! -L "$TARGET_GUARD" ]] \
    || die 'release guard target appeared during installation'
  mv -nT -- "$guard_tmp" "$TARGET_GUARD"
  sync -f "$TARGET_GUARD_DIR"
fi

canonical_signer="uten-imp-release ssh-ed25519 $release_key_blob"
if [[ -e "$TARGET_ALLOWED_SIGNERS" || -L "$TARGET_ALLOWED_SIGNERS" ]]; then
  secure_root_file "$TARGET_ALLOWED_SIGNERS" 'installed release trust policy' 1048576 >/dev/null
  [[ "$(stat -c '%U:%G:%a:%h' -- "$TARGET_ALLOWED_SIGNERS")" == root:root:640:1 ]] \
    || die 'installed release trust policy metadata differs from root:root mode 0640 with one hard link'
  [[ "$(<"$TARGET_ALLOWED_SIGNERS")" == "$canonical_signer" ]] \
    || die 'an existing installed release key differs; key replacement is refused'
else
  signer_tmp="$(mktemp "$TARGET_TRUST_DIR/.release-allowed-signers.XXXXXX")"
  temporary_files+=("$signer_tmp")
  printf '%s\n' "$canonical_signer" >"$signer_tmp"
  chown root:root "$signer_tmp"
  chmod 0640 "$signer_tmp"
  sync -f "$signer_tmp"
  [[ ! -e "$TARGET_ALLOWED_SIGNERS" && ! -L "$TARGET_ALLOWED_SIGNERS" ]] \
    || die 'release trust-policy target appeared during installation'
  mv -nT -- "$signer_tmp" "$TARGET_ALLOWED_SIGNERS"
  sync -f "$TARGET_TRUST_DIR"
fi

[[ "$(sha256sum -- "$TARGET_GUARD" | awk '{print $1}')" == "$expected_guard_sha256" ]] \
  || die 'installed release guard failed its final digest check'
[[ "$(<"$TARGET_ALLOWED_SIGNERS")" == "$canonical_signer" ]] \
  || die 'installed release trust policy failed its final exact-content check'
temporary_files=()
trap - EXIT

printf 'VERIFIER_BOOTSTRAP_INSTALLED: guard_sha256=%s signing_fingerprint=%s staging_not_enabled=true\n' \
  "$expected_guard_sha256" "$expected_signing_fingerprint"
