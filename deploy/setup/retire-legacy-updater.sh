#!/usr/bin/env bash
# Quarantine the pre-signed-release updater credential, configuration, and state.
# This helper never deletes evidence and never installs or starts the new updater.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE
unset OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_SECURITY_TOKEN OSS_BUCKET OSS_ENDPOINT

readonly CONFIRMATION='RETIRE LEGACY UTEN UPDATER'
readonly REVOCATION_CONFIRMATION='LEGACY OSS CREDENTIAL REVOKED OR ROTATED OUT OF BAND'
readonly LEGACY_CREDENTIAL=/etc/uten-imp/oss-pull.env
readonly LEGACY_CONFIG=/etc/uten-imp-updater
readonly LEGACY_STATE=/var/lib/uten-imp-updater
readonly EVIDENCE_ROOT=/var/lib/uten-imp-legacy-evidence
readonly STABLE_GUARD=/usr/local/libexec/uten-imp-release/release_guard.py
readonly STABLE_TRUST=/etc/uten-imp-release-trust
readonly LOCK_FILE=/run/uten-imp-legacy-updater-retirement.lock
readonly SHARED_OPERATION_LOCK=/var/lib/uten-imp-release/operation.lock
readonly MAX_CREDENTIAL_BYTES=65536
readonly MAX_TREE_ENTRIES=100000
readonly MAX_TREE_BYTES=$((20 * 1024 * 1024 * 1024))

approval_reference=''
expected_credential_sha256=''
revocation_confirmation=''
confirmation=''
scratch_files=()
allowed_state_uids=(0)
allowed_state_gids=(0)
allowed_config_gids=(0)
legacy_account_uids=()
legacy_updater_gid=''

die() {
  printf 'LEGACY_UPDATER_RETIREMENT_REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash retire-legacy-updater.sh \
    --approval-reference CHG-20260811-LEGACY-UPDATER \
    --expected-legacy-credential-sha256 64_LOWERCASE_HEX \
    --confirm-revoked \
      'LEGACY OSS CREDENTIAL REVOKED OR ROTATED OUT OF BAND' \
    --confirm 'RETIRE LEGACY UTEN UPDATER'

The approval reference must be a non-secret CAB/change/security record ID.
The credential digest must be calculated and reviewed out of band. This tool
does not contact the cloud provider and the revocation confirmation is an
operator assertion that the old identity can no longer access the bucket.

Only these legacy paths can be moved:
  /etc/uten-imp/oss-pull.env
  /etc/uten-imp-updater
  /var/lib/uten-imp-updater

Evidence is retained under /var/lib/uten-imp-legacy-evidence. The stable
verifier and trust policy under /usr/local/libexec/uten-imp-release and
/etc/uten-imp-release-trust are explicitly outside this transaction.
EOF
}

need_value() {
  [[ "$#" -ge 2 ]] || die "missing value for $1"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --approval-reference)
      need_value "$@"; approval_reference="$2"; shift 2 ;;
    --expected-legacy-credential-sha256)
      need_value "$@"; expected_credential_sha256="$2"; shift 2 ;;
    --confirm-revoked)
      need_value "$@"; revocation_confirmation="$2"; shift 2 ;;
    --confirm)
      need_value "$@"; confirmation="$2"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
[[ "$approval_reference" =~ ^(CHG|CAB|SEC)-[A-Za-z0-9][A-Za-z0-9._-]{2,95}$ ]] \
  || die '--approval-reference must be a non-secret CHG-, CAB-, or SEC- record ID'
[[ "$expected_credential_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || die '--expected-legacy-credential-sha256 must be 64 lowercase hexadecimal characters'
[[ "$revocation_confirmation" == "$REVOCATION_CONFIRMATION" ]] \
  || die "--confirm-revoked must exactly equal: $REVOCATION_CONFIRMATION"
[[ "$confirmation" == "$CONFIRMATION" ]] \
  || die "--confirm must exactly equal: $CONFIRMATION"

for command_name in realpath dirname stat install sha256sum awk grep find sort \
  flock sync mv mktemp cmp base64 systemctl pgrep getent id date readlink mountpoint \
  basename chown chmod rm cat; do
  command -v "$command_name" >/dev/null 2>&1 \
    || die "required command not found: $command_name"
done

[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute through a symlink'
readonly SCRIPT_FILE="$(realpath -e -- "${BASH_SOURCE[0]}")"

secure_root_directory_chain() {
  local current="$1" mode
  [[ "$current" == /* ]] || die "trusted directory must be absolute: $current"
  [[ "$(realpath -e -- "$current")" == "$current" ]] \
    || die "trusted directory path is non-canonical or contains a symlink: $current"
  while :; do
    [[ -d "$current" && ! -L "$current" ]] || die "unsafe trusted directory: $current"
    [[ "$(stat -c '%u' -- "$current")" == 0 ]] \
      || die "trusted directory is not root-owned: $current"
    mode="$(stat -c '%a' -- "$current")"
    (( (8#$mode & 0022) == 0 )) \
      || die "trusted directory is group- or other-writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

secure_root_file() {
  local path="$1" label="$2" mode size
  [[ "$path" == /* ]] || die "$label must be an absolute path"
  [[ -f "$path" && ! -L "$path" ]] || die "$label must be a regular non-symlink file"
  [[ "$(realpath -e -- "$path")" == "$path" ]] \
    || die "$label path is non-canonical or contains a symlink"
  [[ "$(stat -c '%u:%h' -- "$path")" == 0:1 ]] \
    || die "$label must be root-owned with one hard link"
  mode="$(stat -c '%a' -- "$path")"
  (( (8#$mode & 0022) == 0 && (8#$mode & 07000) == 0 )) \
    || die "$label is writable by another identity or has special permission bits"
  size="$(stat -c '%s' -- "$path")"
  (( size > 0 && size <= 1048576 )) || die "$label has an unsafe size"
  secure_root_directory_chain "$(dirname -- "$path")"
}

secure_root_file "$SCRIPT_FILE" 'legacy updater retirement helper'

paths_overlap() {
  local left="$1" right="$2"
  [[ "$left" == "$right" || "$left" == "$right"/* || "$right" == "$left"/* ]]
}

for legacy_path in "$LEGACY_CREDENTIAL" "$LEGACY_CONFIG" "$LEGACY_STATE"; do
  paths_overlap "$legacy_path" "$STABLE_GUARD" \
    && die "legacy scope overlaps the stable release guard: $legacy_path"
  paths_overlap "$legacy_path" "$STABLE_TRUST" \
    && die "legacy scope overlaps the stable release trust namespace: $legacy_path"
done

secure_root_directory_chain /run
if [[ ! -e "$LOCK_FILE" && ! -L "$LOCK_FILE" ]]; then
  install -m 0600 -o root -g root /dev/null "$LOCK_FILE"
  sync -f /run
fi
[[ -f "$LOCK_FILE" && ! -L "$LOCK_FILE" ]] || die 'retirement lock is not a regular file'
[[ "$(stat -c '%u:%g:%a:%h' -- "$LOCK_FILE")" == 0:0:600:1 ]] \
  || die 'retirement lock must be root:root mode 0600 with one hard link'
exec 9<>"$LOCK_FILE"
flock -n 9 || die 'another legacy updater retirement is running'

cleanup_scratch() {
  local status="$?" scratch
  trap - EXIT
  for scratch in "${scratch_files[@]:-}"; do
    case "$scratch" in
      /run/uten-imp-legacy-retirement.*)
        [[ ! -e "$scratch" || ( -f "$scratch" && ! -L "$scratch" ) ]] \
          && rm -f -- "$scratch" || true ;;
    esac
  done
  exit "$status"
}
trap cleanup_scratch EXIT

add_unique_identity() {
  local kind="$1" name="$2" entry numeric_id names_count
  if [[ "$kind" == user ]]; then
    entry="$(getent passwd "$name" || true)"
    [[ -n "$entry" ]] || return 0
    [[ "$(grep -c . <<<"$entry")" == 1 ]] || die "ambiguous legacy account: $name"
    numeric_id="$(awk -F: 'NR == 1 {print $3}' <<<"$entry")"
    names_count="$(getent passwd | awk -F: -v id="$numeric_id" '$3 == id {count++} END {print count+0}')"
    [[ "$names_count" == 1 ]] || die "legacy account UID has aliases: $name"
    allowed_state_uids+=("$numeric_id")
    legacy_account_uids+=("$numeric_id:$name")
  else
    entry="$(getent group "$name" || true)"
    [[ -n "$entry" ]] || return 0
    [[ "$(grep -c . <<<"$entry")" == 1 ]] || die "ambiguous legacy group: $name"
    numeric_id="$(awk -F: 'NR == 1 {print $3}' <<<"$entry")"
    names_count="$(getent group | awk -F: -v id="$numeric_id" '$3 == id {count++} END {print count+0}')"
    [[ "$names_count" == 1 ]] || die "legacy group GID has aliases: $name"
    allowed_state_gids+=("$numeric_id")
    allowed_config_gids+=("$numeric_id")
    [[ "$name" != uten-imp-updater ]] || legacy_updater_gid="$numeric_id"
  fi
}

add_unique_identity user uten-imp
add_unique_identity user uten-imp-updater
add_unique_identity group uten-imp
add_unique_identity group uten-imp-updater

array_contains() {
  local wanted="$1" value
  shift
  for value in "$@"; do
    [[ "$value" == "$wanted" ]] && return 0
  done
  return 1
}

assert_units_quiescent() {
  local unit active_state enabled_state
  local units=(
    nginx.service
    uten-imp-migrate.service
    uten-imp-updater.service
    uten-imp-updater.timer
    uten-imp.service
    uten-imp-watchdog.service
    uten-imp-watchdog.timer
    uten-imp-entry-watchdog.service
    uten-imp-entry-watchdog.timer
  )
  for unit in "${units[@]}"; do
    active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ "$active_state" == inactive || "$active_state" == unknown ]] \
      || die "related unit is not inactive: $unit ($active_state)"
    enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    case "$enabled_state" in
      disabled|static|not-found|'') ;;
      *) die "related unit is not disabled: $unit ($enabled_state)" ;;
    esac
  done
  assert_no_legacy_processes
}

assert_no_legacy_processes() {
  local identity numeric_id account_name
  for identity in "${legacy_account_uids[@]:-}"; do
    numeric_id="${identity%%:*}"
    account_name="${identity#*:}"
    pgrep -u "$numeric_id" >/dev/null 2>&1 \
      && die "legacy account still owns a running process: $account_name"
  done
}

assert_units_quiescent

shared_operation_parent="$(dirname -- "$SHARED_OPERATION_LOCK")"
if [[ -e "$shared_operation_parent" || -L "$shared_operation_parent" ]]; then
  [[ -d "$shared_operation_parent" && ! -L "$shared_operation_parent" ]] \
    || die 'shared release operation-lock parent is not a real directory'
  secure_root_directory_chain "$shared_operation_parent"
fi
if [[ -e "$SHARED_OPERATION_LOCK" || -L "$SHARED_OPERATION_LOCK" ]]; then
  [[ -n "$legacy_updater_gid" ]] \
    || die 'shared release operation lock exists without the dedicated updater group'
  [[ -f "$SHARED_OPERATION_LOCK" && ! -L "$SHARED_OPERATION_LOCK" ]] \
    || die 'shared release operation lock is not a regular non-symlink file'
  [[ "$(realpath -e -- "$SHARED_OPERATION_LOCK")" == "$SHARED_OPERATION_LOCK" ]] \
    || die 'shared release operation lock path is non-canonical or contains a symlink'
  [[ "$(stat -c '%u:%g:%a:%h' -- "$SHARED_OPERATION_LOCK")" \
    == "0:$legacy_updater_gid:660:1" ]] \
    || die 'shared release operation lock metadata is not root:uten-imp-updater 0660 single-link'
  secure_root_directory_chain "$(dirname -- "$SHARED_OPERATION_LOCK")"
  exec 8<>"$SHARED_OPERATION_LOCK"
  flock -n 8 || die 'a signed staging or activation operation is running'
else
  [[ ! -L "$SHARED_OPERATION_LOCK" ]] \
    || die 'shared release operation lock path is a dangling symlink'
fi

validate_source_parent() {
  local path="$1"
  secure_root_directory_chain "$(dirname -- "$path")"
}

validate_source_parent "$LEGACY_CREDENTIAL"
validate_source_parent "$LEGACY_CONFIG"
validate_source_parent "$LEGACY_STATE"

credential_metadata() {
  local path="$1" context="$2" uid gid mode links size before after digest
  [[ -f "$path" && ! -L "$path" ]] \
    || die "$context credential must be a regular non-symlink file"
  mountpoint --quiet "$path" \
    && die "$context credential must not be a file mount point"
  [[ "$(realpath -e -- "$path")" == "$path" ]] \
    || die "$context credential path is non-canonical or contains a symlink"
  before="$(stat -c '%u:%g:%a:%h:%s' -- "$path")"
  IFS=: read -r uid gid mode links size <<<"$before"
  [[ "$uid" == 0 ]] || die "$context credential is not root-owned"
  array_contains "$gid" "${allowed_config_gids[@]}" \
    || die "$context credential has an unapproved group"
  [[ "$mode" == 600 || "$mode" == 640 ]] \
    || die "$context credential mode must be 0600 or 0640"
  [[ "$links" == 1 ]] || die "$context credential has multiple hard links"
  (( size > 0 && size <= MAX_CREDENTIAL_BYTES )) \
    || die "$context credential has an unsafe size"
  digest="$(sha256sum -- "$path" | awk 'NR == 1 {print $1}')"
  after="$(stat -c '%u:%g:%a:%h:%s' -- "$path")"
  [[ "$before" == "$after" ]] || die "$context credential changed while it was hashed"
  [[ "$digest" == "$expected_credential_sha256" ]] \
    || die "$context credential digest differs from the independently reviewed SHA-256"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$uid" "$gid" "$mode" "$links" "$size" "$digest"
}

validate_tree_entry() {
  local profile="$1" entry="$2" type uid gid mode links size mode_value
  [[ ! -L "$entry" ]] || die "$profile tree contains a symlink"
  mountpoint --quiet "$entry" && die "$profile tree contains a mount point"
  type="$(stat -c '%F' -- "$entry")"
  uid="$(stat -c '%u' -- "$entry")"
  gid="$(stat -c '%g' -- "$entry")"
  mode="$(stat -c '%a' -- "$entry")"
  links="$(stat -c '%h' -- "$entry")"
  size="$(stat -c '%s' -- "$entry")"
  mode_value=$((8#$mode))
  (( (mode_value & 0022) == 0 && (mode_value & 07000) == 0 )) \
    || die "$profile tree contains writable-by-other or special permission bits"
  if [[ "$profile" == config ]]; then
    [[ "$uid" == 0 ]] || die 'legacy config tree contains a non-root-owned entry'
    array_contains "$gid" "${allowed_config_gids[@]}" \
      || die 'legacy config tree contains an unapproved group'
  else
    array_contains "$uid" "${allowed_state_uids[@]}" \
      || die 'legacy updater state contains an unapproved owner'
    array_contains "$gid" "${allowed_state_gids[@]}" \
      || die 'legacy updater state contains an unapproved group'
  fi
  case "$type" in
    directory)
      [[ "$mode" == 700 || "$mode" == 750 || "$mode" == 755 ]] \
        || die "$profile tree directory mode is outside the 0700/0750/0755 allowlist"
      ;;
    'regular file')
      [[ "$links" == 1 ]] || die "$profile tree contains a multiply-linked file"
      [[ "$mode" == 600 || "$mode" == 640 || "$mode" == 644 ]] \
        || die "$profile tree file mode is outside the 0600/0640/0644 allowlist"
      ;;
    *)
      die "$profile tree contains an unsupported file type: $type" ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s' "$type" "$uid" "$gid" "$mode" "$links" "$size"
}

append_tree_inventory() {
  local logical="$1" profile="$2" root="$3" output="$4"
  local entry relative encoded metadata type before after digest='-' entries=0 total_bytes=0 tree_list
  if [[ ! -e "$root" && ! -L "$root" ]]; then
    printf 'tree\t%s\tabsent\t-\t-\t-\t-\t-\t-\t-\n' "$logical" >>"$output"
    return
  fi
  [[ -d "$root" && ! -L "$root" ]] || die "$logical must be a real directory"
  [[ "$(realpath -e -- "$root")" == "$root" ]] \
    || die "$logical path is non-canonical or contains a symlink"
  tree_list="$(mktemp /run/uten-imp-legacy-retirement.tree.XXXXXX)"
  scratch_files+=("$tree_list")
  find -P "$root" -xdev -print0 >"$tree_list" \
    || die "$logical cannot be completely enumerated"
  LC_ALL=C sort -z -o "$tree_list" "$tree_list" \
    || die "$logical inventory cannot be sorted"
  while IFS= read -r -d '' entry; do
    entries=$((entries + 1))
    (( entries <= MAX_TREE_ENTRIES )) || die "$logical exceeds the evidence entry limit"
    relative="${entry#"$root"}"
    relative="${relative#/}"
    [[ -n "$relative" ]] || relative='.'
    encoded="$(printf '%s' "$relative" | base64 -w 0)"
    metadata="$(validate_tree_entry "$profile" "$entry")"
    type="${metadata%%$'\t'*}"
    if [[ "$type" == 'regular file' ]]; then
      before="$(stat -c '%u:%g:%a:%h:%s' -- "$entry")"
      digest="$(sha256sum -- "$entry" | awk 'NR == 1 {print $1}')"
      after="$(stat -c '%u:%g:%a:%h:%s' -- "$entry")"
      [[ "$before" == "$after" ]] || die "$logical changed while its inventory was created"
      total_bytes=$((total_bytes + ${before##*:}))
      (( total_bytes <= MAX_TREE_BYTES )) || die "$logical exceeds the evidence byte limit"
    else
      digest='-'
    fi
    printf 'tree\t%s\tpresent\t%s\t%s\t%s\n' \
      "$logical" "$encoded" "$metadata" "$digest" >>"$output"
  done <"$tree_list"
}

readonly transaction_hash="$(printf '%s' "$approval_reference" | sha256sum | awk '{print $1}')"
readonly TRANSACTION_DIR="$EVIDENCE_ROOT/retirement-$transaction_hash"
readonly EVIDENCE_CREDENTIAL="$TRANSACTION_DIR/legacy-etc-uten-imp-oss-pull.env"
readonly EVIDENCE_CONFIG="$TRANSACTION_DIR/legacy-etc-uten-imp-updater"
readonly EVIDENCE_STATE="$TRANSACTION_DIR/legacy-var-lib-uten-imp-updater"
readonly IN_PROGRESS="$TRANSACTION_DIR/in-progress.state"
readonly CLOSED_PROGRESS="$TRANSACTION_DIR/in-progress.closed.state"
readonly COMPLETE="$TRANSACTION_DIR/complete.state"
readonly MANIFEST="$TRANSACTION_DIR/manifest.tsv"
readonly MANIFEST_DIGEST="$TRANSACTION_DIR/manifest.sha256"

ensure_exact_evidence_directory() {
  local path="$1" parent
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -d "$path" && ! -L "$path" ]] || die "evidence path is not a real directory: $path"
    [[ "$(stat -c '%u:%g:%a' -- "$path")" == 0:0:700 ]] \
      || die "evidence directory must be root:root mode 0700: $path"
    [[ "$(realpath -e -- "$path")" == "$path" ]] \
      || die "evidence directory is non-canonical or contains a symlink: $path"
    return
  fi
  parent="$(dirname -- "$path")"
  secure_root_directory_chain "$parent"
  install -d -m 0700 -o root -g root "$path"
  sync -f "$parent"
  [[ "$(stat -c '%u:%g:%a' -- "$path")" == 0:0:700 ]] \
    || die "failed to create exact evidence directory: $path"
}

secure_root_directory_chain /var/lib
ensure_exact_evidence_directory "$EVIDENCE_ROOT"
ensure_exact_evidence_directory "$TRANSACTION_DIR"

validate_transaction_namespace() {
  local entry name metadata namespace_list
  namespace_list="$(mktemp /run/uten-imp-legacy-retirement.namespace.XXXXXX)"
  scratch_files+=("$namespace_list")
  find -P "$TRANSACTION_DIR" -mindepth 1 -maxdepth 1 -print0 >"$namespace_list" \
    || die 'transaction evidence namespace cannot be completely enumerated'
  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    [[ ! -L "$entry" ]] || die "transaction evidence contains a symlink: $name"
    case "$name" in
      legacy-etc-uten-imp-updater|legacy-var-lib-uten-imp-updater)
        [[ -d "$entry" ]] || die "transaction tree target has the wrong type: $name" ;;
      legacy-etc-uten-imp-oss-pull.env|in-progress.state|in-progress.closed.state|complete.state|manifest.tsv|manifest.sha256|moved-credential.state|moved-config.state|moved-state.state)
        [[ -f "$entry" ]] || die "transaction evidence file has the wrong type: $name" ;;
      .in-progress.state.tmp.*|.complete.state.tmp.*|.manifest.tsv.tmp.*|.manifest.sha256.tmp.*|.moved-credential.state.tmp.*|.moved-config.state.tmp.*|.moved-state.state.tmp.*)
        [[ -f "$entry" ]] || die "interrupted control temporary has the wrong type: $name"
        metadata="$(stat -c '%u:%g:%a:%h' -- "$entry")"
        [[ "$metadata" == 0:0:600:1 ]] \
          || die "interrupted control temporary has unsafe metadata: $name" ;;
      *)
        die "transaction evidence contains an unknown entry: $name" ;;
    esac
  done <"$namespace_list"
}

validate_transaction_namespace

while IFS= read -r -d '' other_progress; do
  [[ "$(dirname -- "$other_progress")" == "$TRANSACTION_DIR" ]] \
    || die "another unfinished legacy-updater retirement exists: $(dirname -- "$other_progress")"
done < <(find -P "$EVIDENCE_ROOT" -mindepth 2 -maxdepth 2 -type f -name in-progress.state -print0)

assert_same_device() {
  local path="$1" label="$2"
  [[ "$(stat -c '%d' -- "$path")" == "$(stat -c '%d' -- "$TRANSACTION_DIR")" ]] \
    || die "$label is not on the evidence filesystem; atomic quarantine is impossible"
}

assert_same_device "$(dirname -- "$LEGACY_CREDENTIAL")" 'legacy credential parent'
assert_same_device "$(dirname -- "$LEGACY_CONFIG")" 'legacy config parent'
assert_same_device "$(dirname -- "$LEGACY_STATE")" 'legacy state parent'

validate_control_file() {
  local path="$1" label="$2" max_bytes="$3" size
  [[ -f "$path" && ! -L "$path" ]] || die "$label is not a regular non-symlink file"
  [[ "$(stat -c '%u:%g:%a:%h' -- "$path")" == 0:0:600:1 ]] \
    || die "$label must be root:root mode 0600 with one hard link"
  size="$(stat -c '%s' -- "$path")"
  (( size > 0 && size <= max_bytes )) || die "$label has an unsafe size"
}

state_value() {
  local path="$1" key="$2"
  awk -F= -v wanted="$key" '$1 == wanted {count++; value=substr($0, length($1) + 2)} END {if (count == 1) print value; else exit 1}' "$path"
}

validate_transaction_identity() {
  local marker="$1" expected_status="$2"
  validate_control_file "$marker" 'transaction state marker' 16384
  [[ "$(state_value "$marker" format)" == uten-imp-legacy-updater-retirement-v1 ]] \
    || die 'transaction marker format is not recognized'
  [[ "$(state_value "$marker" approval_reference)" == "$approval_reference" ]] \
    || die 'approval reference differs from the existing transaction'
  [[ "$(state_value "$marker" expected_credential_sha256)" == "$expected_credential_sha256" ]] \
    || die 'credential digest differs from the existing transaction'
  [[ "$(state_value "$marker" status)" == "$expected_status" ]] \
    || die "transaction marker status is not $expected_status"
}

atomic_write_control() {
  local target="$1" content="$2" temporary
  [[ ! -e "$target" && ! -L "$target" ]] || die "control target already exists: $target"
  temporary="$(mktemp "$TRANSACTION_DIR/.$(basename -- "$target").tmp.XXXXXX")"
  printf '%s' "$content" >"$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  sync -f "$temporary"
  [[ ! -e "$target" && ! -L "$target" ]] || die "control target appeared: $target"
  mv -T -- "$temporary" "$target"
  sync -f "$TRANSACTION_DIR"
}

if [[ -e "$IN_PROGRESS" || -L "$IN_PROGRESS" ]]; then
  validate_transaction_identity "$IN_PROGRESS" IN_PROGRESS
elif [[ -e "$CLOSED_PROGRESS" || -L "$CLOSED_PROGRESS" ]]; then
  validate_transaction_identity "$CLOSED_PROGRESS" IN_PROGRESS
  [[ -e "$COMPLETE" && ! -L "$COMPLETE" ]] \
    || die 'closed in-progress evidence exists without a complete marker'
elif [[ ! -e "$COMPLETE" && ! -L "$COMPLETE" ]]; then
  [[ ! -e "$EVIDENCE_CREDENTIAL" && ! -L "$EVIDENCE_CREDENTIAL" \
    && ! -e "$EVIDENCE_CONFIG" && ! -L "$EVIDENCE_CONFIG" \
    && ! -e "$EVIDENCE_STATE" && ! -L "$EVIDENCE_STATE" ]] \
    || die 'uncommitted evidence exists without a transaction marker'
  in_progress_content="$(printf \
    'format=uten-imp-legacy-updater-retirement-v1\nstatus=IN_PROGRESS\napproval_reference=%s\nexpected_credential_sha256=%s\nstarted_utc=%s\n' \
    "$approval_reference" "$expected_credential_sha256" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  atomic_write_control "$IN_PROGRESS" "$in_progress_content"$'\n'
fi

choose_location() {
  local source="$1" destination="$2" logical="$3"
  if [[ ( -e "$source" || -L "$source" ) && ( -e "$destination" || -L "$destination" ) ]]; then
    die "$logical exists in both the live and evidence namespaces"
  elif [[ -e "$source" || -L "$source" ]]; then
    printf '%s' "$source"
  elif [[ -e "$destination" || -L "$destination" ]]; then
    printf '%s' "$destination"
  else
    printf '%s' ''
  fi
}

current_credential="$(choose_location "$LEGACY_CREDENTIAL" "$EVIDENCE_CREDENTIAL" credential)"
current_config="$(choose_location "$LEGACY_CONFIG" "$EVIDENCE_CONFIG" config)"
current_state="$(choose_location "$LEGACY_STATE" "$EVIDENCE_STATE" state)"
[[ -n "$current_credential" ]] \
  || die 'legacy credential is absent from both the live and evidence namespaces'

if [[ "$current_credential" == "$EVIDENCE_CREDENTIAL" ]]; then
  credential_line="$(credential_metadata "$current_credential" evidence)"
  credential_uid="${credential_line%%$'\t'*}"
  [[ "$credential_uid" == 0 ]] || die 'evidence credential owner changed'
  credential_digest="${credential_line##*$'\t'}"
  chown root:root "$current_credential"
  chmod 0600 "$current_credential"
  sync -f "$current_credential"
  [[ "$(stat -c '%u:%g:%a:%h' -- "$current_credential")" == 0:0:600:1 ]] \
    || die 'evidence credential could not be normalized to root:root mode 0600'
else
  credential_line="$(credential_metadata "$current_credential" live)"
  credential_digest="${credential_line##*$'\t'}"
fi

create_comparable_inventory() {
  local output="$1" credential="$2" config="$3" state="$4" credential_size
  : >"$output"
  chmod 0600 "$output"
  credential_size="$(stat -c '%s' -- "$credential")"
  printf 'credential-content\tpresent\t%s\t%s\n' \
    "$credential_size" "$credential_digest" >>"$output"
  append_tree_inventory config config "$config" "$output"
  append_tree_inventory state state "$state" "$output"
}

current_inventory="$(mktemp /run/uten-imp-legacy-retirement.inventory.XXXXXX)"
scratch_files+=("$current_inventory")
create_comparable_inventory "$current_inventory" "$current_credential" "$current_config" "$current_state"

if [[ ! -e "$MANIFEST" && ! -L "$MANIFEST" ]]; then
  [[ ! -e "$MANIFEST_DIGEST" && ! -L "$MANIFEST_DIGEST" ]] \
    || die 'manifest digest exists without a manifest'
  manifest_tmp="$(mktemp "$TRANSACTION_DIR/.manifest.tsv.tmp.XXXXXX")"
  {
    printf 'format\tuten-imp-legacy-updater-retirement-v1\n'
    printf 'approval-reference\t%s\n' "$approval_reference"
    printf 'credential-original\t%s\n' "$credential_line"
    cat "$current_inventory"
  } >"$manifest_tmp"
  chown root:root "$manifest_tmp"
  chmod 0600 "$manifest_tmp"
  sync -f "$manifest_tmp"
  mv -T -- "$manifest_tmp" "$MANIFEST"
  sync -f "$TRANSACTION_DIR"
fi

validate_control_file "$MANIFEST" 'retirement manifest' 33554432
[[ "$(awk -F '\t' 'NR == 1 && $1 == "format" {print $2}' "$MANIFEST")" \
  == uten-imp-legacy-updater-retirement-v1 ]] \
  || die 'retirement manifest format is not recognized'
[[ "$(awk -F '\t' '$1 == "approval-reference" {count++; value=$2} END {if (count == 1) print value; else exit 1}' "$MANIFEST")" \
  == "$approval_reference" ]] || die 'retirement manifest approval reference differs'

if [[ ! -e "$MANIFEST_DIGEST" && ! -L "$MANIFEST_DIGEST" ]]; then
  for premature_evidence in "$EVIDENCE_CREDENTIAL" "$EVIDENCE_CONFIG" "$EVIDENCE_STATE" \
    "$TRANSACTION_DIR/moved-credential.state" "$TRANSACTION_DIR/moved-config.state" \
    "$TRANSACTION_DIR/moved-state.state" "$COMPLETE"; do
    [[ ! -e "$premature_evidence" && ! -L "$premature_evidence" ]] \
      || die 'manifest digest is missing after evidence movement began'
  done
  recovery_inventory="$(mktemp /run/uten-imp-legacy-retirement.recovery.XXXXXX)"
  scratch_files+=("$recovery_inventory")
  awk -F '\t' '$1 == "credential-content" || $1 == "tree"' "$MANIFEST" >"$recovery_inventory"
  cmp -s -- "$current_inventory" "$recovery_inventory" \
    || die 'an interrupted manifest differs from the still-live legacy paths'
  manifest_hash="$(sha256sum -- "$MANIFEST" | awk '{print $1}')"
  atomic_write_control "$MANIFEST_DIGEST" "$manifest_hash"$'\n'
else
  validate_control_file "$MANIFEST_DIGEST" 'retirement manifest digest' 1024
  manifest_hash="$(<"$MANIFEST_DIGEST")"
  [[ "$manifest_hash" =~ ^[0-9a-f]{64}$ ]] || die 'manifest digest record is malformed'
  [[ "$(sha256sum -- "$MANIFEST" | awk '{print $1}')" == "$manifest_hash" ]] \
    || die 'retirement manifest digest verification failed'
fi

committed_inventory="$(mktemp /run/uten-imp-legacy-retirement.committed.XXXXXX)"
scratch_files+=("$committed_inventory")
awk -F '\t' '$1 == "credential-content" || $1 == "tree"' "$MANIFEST" >"$committed_inventory"
cmp -s -- "$current_inventory" "$committed_inventory" \
  || die 'live/evidence paths differ from the committed preflight inventory'

verify_logical_inventory() {
  local logical="$1" source="$2" destination="$3" location inventory expected line digest size
  location="$(choose_location "$source" "$destination" "$logical")"
  inventory="$(mktemp /run/uten-imp-legacy-retirement.recheck.XXXXXX)"
  expected="$(mktemp /run/uten-imp-legacy-retirement.expected.XXXXXX)"
  scratch_files+=("$inventory" "$expected")
  : >"$inventory"
  chmod 0600 "$inventory"
  case "$logical" in
    credential)
      [[ -n "$location" ]] || die 'legacy credential disappeared before quarantine'
      line="$(credential_metadata "$location" recheck)"
      digest="${line##*$'\t'}"
      size="$(stat -c '%s' -- "$location")"
      printf 'credential-content\tpresent\t%s\t%s\n' "$size" "$digest" >"$inventory"
      awk -F '\t' '$1 == "credential-content"' "$committed_inventory" >"$expected"
      ;;
    config)
      append_tree_inventory config config "$location" "$inventory"
      awk -F '\t' '$1 == "tree" && $2 == "config"' "$committed_inventory" >"$expected"
      ;;
    state)
      append_tree_inventory state state "$location" "$inventory"
      awk -F '\t' '$1 == "tree" && $2 == "state"' "$committed_inventory" >"$expected"
      ;;
    *)
      die "unknown retirement logical item: $logical" ;;
  esac
  cmp -s -- "$inventory" "$expected" \
    || die "$logical changed after the committed preflight inventory"
}

write_step_marker() {
  local logical="$1" status="$2" marker="$TRANSACTION_DIR/moved-$logical.state" content
  content="$(printf \
    'format=uten-imp-legacy-updater-retirement-step-v1\nlogical=%s\nstatus=%s\nmanifest_sha256=%s\n' \
    "$logical" "$status" "$manifest_hash")"
  if [[ -e "$marker" || -L "$marker" ]]; then
    validate_control_file "$marker" "$logical step marker" 4096
    [[ "$(<"$marker")" == "$content" ]] || die "$logical step marker differs from this transaction"
  else
    atomic_write_control "$marker" "$content"$'\n'
  fi
}

move_to_evidence() {
  local logical="$1" source="$2" destination="$3" location status
  assert_units_quiescent
  verify_logical_inventory "$logical" "$source" "$destination"
  location="$(choose_location "$source" "$destination" "$logical")"
  if [[ -z "$location" ]]; then
    status=absent
  elif [[ "$location" == "$source" ]]; then
    assert_same_device "$source" "$logical source"
    [[ ! -e "$destination" && ! -L "$destination" ]] \
      || die "$logical evidence destination appeared"
    mv -T -- "$source" "$destination"
    sync -f "$(dirname -- "$source")"
    sync -f "$TRANSACTION_DIR"
    status=moved
  else
    status=moved
  fi
  if [[ "$logical" == credential && "$status" == moved ]]; then
    credential_metadata "$destination" evidence >/dev/null
    chown root:root "$destination"
    chmod 0600 "$destination"
    sync -f "$destination"
    [[ "$(stat -c '%u:%g:%a:%h' -- "$destination")" == 0:0:600:1 ]] \
      || die 'quarantined credential is not root:root mode 0600 with one hard link'
  fi
  write_step_marker "$logical" "$status"
}

move_to_evidence credential "$LEGACY_CREDENTIAL" "$EVIDENCE_CREDENTIAL"
move_to_evidence config "$LEGACY_CONFIG" "$EVIDENCE_CONFIG"
move_to_evidence state "$LEGACY_STATE" "$EVIDENCE_STATE"

assert_units_quiescent
for retired_source in "$LEGACY_CREDENTIAL" "$LEGACY_CONFIG" "$LEGACY_STATE"; do
  [[ ! -e "$retired_source" && ! -L "$retired_source" ]] \
    || die "legacy source still exists after quarantine: $retired_source"
done

final_inventory="$(mktemp /run/uten-imp-legacy-retirement.final.XXXXXX)"
scratch_files+=("$final_inventory")
credential_digest="$expected_credential_sha256"
create_comparable_inventory \
  "$final_inventory" "$EVIDENCE_CREDENTIAL" \
  "$(choose_location "$LEGACY_CONFIG" "$EVIDENCE_CONFIG" config)" \
  "$(choose_location "$LEGACY_STATE" "$EVIDENCE_STATE" state)"
cmp -s -- "$final_inventory" "$committed_inventory" \
  || die 'final evidence differs from the committed preflight inventory'

if [[ -e "$COMPLETE" || -L "$COMPLETE" ]]; then
  validate_transaction_identity "$COMPLETE" COMPLETE
  [[ "$(state_value "$COMPLETE" manifest_sha256)" == "$manifest_hash" ]] \
    || die 'complete marker refers to a different manifest'
else
  complete_content="$(printf \
    'format=uten-imp-legacy-updater-retirement-v1\nstatus=COMPLETE\napproval_reference=%s\nexpected_credential_sha256=%s\nmanifest_sha256=%s\ncompleted_utc=%s\n' \
    "$approval_reference" "$expected_credential_sha256" "$manifest_hash" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  atomic_write_control "$COMPLETE" "$complete_content"$'\n'
fi

if [[ -e "$IN_PROGRESS" || -L "$IN_PROGRESS" ]]; then
  validate_transaction_identity "$IN_PROGRESS" IN_PROGRESS
  [[ ! -e "$CLOSED_PROGRESS" && ! -L "$CLOSED_PROGRESS" ]] \
    || die 'both open and closed in-progress markers exist'
  mv -T -- "$IN_PROGRESS" "$CLOSED_PROGRESS"
  sync -f "$TRANSACTION_DIR"
fi

trap - EXIT
printf 'LEGACY_UPDATER_RETIREMENT_COMPLETE: approval_reference=%s evidence=%s credential_content_not_logged=true\n' \
  "$approval_reference" "$TRANSACTION_DIR"
cleanup_scratch
