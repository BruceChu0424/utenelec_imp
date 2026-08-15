#!/usr/bin/env bash
# Uten IMP Phase 4: install the signed staging boundary and the audited TLS site.
# Default behavior is install-only. It never activates an application release.
set -Eeuo pipefail
umask 0077
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE
unset UTEN_UPDATER_HOME UTEN_UPDATER_STATE_DIR UTEN_RELEASE_ALLOWED_SIGNERS
unset UTEN_RELEASE_LOCK_FILE UTEN_RELEASE_BASE UTEN_RELEASE_ROOT_STATE_DIR
unset OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_SECURITY_TOKEN OSS_BUCKET OSS_ENDPOINT

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash phase4-updater-nginx.sh \
    --domain erp.example.internal \
    --office-cidr __EXACT_OFFICE_CIDR__ \
    --vpn-cidr __EXACT_VPN_CIDR__ \
    --tls-cert /etc/letsencrypt/live/erp.example.internal/fullchain.pem \
    --tls-key /etc/letsencrypt/live/erp.example.internal/privkey.pem \
    --oss-public-host __OSS_PUBLIC_HOST__ \
    --release-public-key /opt/uten-imp-commissioning/uten-imp-release-ed25519.pub \
    --expected-signing-fingerprint SHA256:OUT_OF_BAND_FINGERPRINT \
    --wheelhouse /opt/uten-imp-commissioning/updater-wheelhouse \
    --requirements-lock /opt/uten-imp-commissioning/updater-requirements.lock \
    --wheelhouse-sha256s /opt/uten-imp-commissioning/updater-wheelhouse.SHA256SUMS \
    --wheelhouse-sbom /opt/uten-imp-commissioning/updater-wheelhouse.cdx.json \
    --wheelhouse-attestation /opt/uten-imp-commissioning/updater-wheelhouse.attestation.json \
    --wheelhouse-attestation-signature /opt/uten-imp-commissioning/updater-wheelhouse.attestation.sig \
    [--oss-env-source /root/commissioning/oss-pull.env] \
    [--replace-existing \
      --legacy-retirement-evidence /var/lib/uten-imp-legacy-evidence/retirement-SHA256 \
      --confirm-replace 'MAINTENANCE WINDOW: REPLACE INACTIVE PHASE4 FILES']

Security contract:
  * Run only from a reviewed root-owned, non-writable deployment snapshot.
  * The wheelhouse is offline, hash-locked, inventoried, and has an SBOM.
  * The OSS credential source is a root:root 0600 file created with sudoedit;
    it is never sourced, printed, or accepted as a command-line secret.
  * Default mode installs but does not enable the staging timer.
  * --enable-staging and its confirmation flags are reserved and always
    rejected in this version; there is no supported automatic-enable path.
  * This script never enables or starts the backend, Nginx, or watchdogs and
    never runs a release activation.
EOF
}

readonly REPLACE_CONFIRMATION='MAINTENANCE WINDOW: REPLACE INACTIVE PHASE4 FILES'
readonly OSS_READ_ONLY_CONFIRMATION='OSS DOWNLOADER GET-ONLY CONFIRMED'

domain=''
office_cidr=''
vpn_cidr=''
tls_cert=''
tls_key=''
oss_public_host=''
release_public_key=''
expected_signing_fingerprint=''
wheelhouse=''
requirements_lock=''
wheelhouse_sha256s=''
wheelhouse_sbom=''
wheelhouse_attestation=''
wheelhouse_attestation_signature=''
oss_env_source=''
replace_existing=false
replace_confirmation=''
legacy_retirement_evidence=''
enable_staging=false
expected_candidate_version=''
oss_read_only_confirmation=''

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --domain) [[ "$#" -ge 2 ]] || die 'missing value for --domain'; domain="$2"; shift 2 ;;
    --office-cidr) [[ "$#" -ge 2 ]] || die 'missing value for --office-cidr'; office_cidr="$2"; shift 2 ;;
    --vpn-cidr) [[ "$#" -ge 2 ]] || die 'missing value for --vpn-cidr'; vpn_cidr="$2"; shift 2 ;;
    --tls-cert) [[ "$#" -ge 2 ]] || die 'missing value for --tls-cert'; tls_cert="$2"; shift 2 ;;
    --tls-key) [[ "$#" -ge 2 ]] || die 'missing value for --tls-key'; tls_key="$2"; shift 2 ;;
    --oss-public-host) [[ "$#" -ge 2 ]] || die 'missing value for --oss-public-host'; oss_public_host="$2"; shift 2 ;;
    --release-public-key) [[ "$#" -ge 2 ]] || die 'missing value for --release-public-key'; release_public_key="$2"; shift 2 ;;
    --expected-signing-fingerprint) [[ "$#" -ge 2 ]] || die 'missing value for --expected-signing-fingerprint'; expected_signing_fingerprint="$2"; shift 2 ;;
    --wheelhouse) [[ "$#" -ge 2 ]] || die 'missing value for --wheelhouse'; wheelhouse="$2"; shift 2 ;;
    --requirements-lock) [[ "$#" -ge 2 ]] || die 'missing value for --requirements-lock'; requirements_lock="$2"; shift 2 ;;
    --wheelhouse-sha256s) [[ "$#" -ge 2 ]] || die 'missing value for --wheelhouse-sha256s'; wheelhouse_sha256s="$2"; shift 2 ;;
    --wheelhouse-sbom) [[ "$#" -ge 2 ]] || die 'missing value for --wheelhouse-sbom'; wheelhouse_sbom="$2"; shift 2 ;;
    --wheelhouse-attestation) [[ "$#" -ge 2 ]] || die 'missing value for --wheelhouse-attestation'; wheelhouse_attestation="$2"; shift 2 ;;
    --wheelhouse-attestation-signature) [[ "$#" -ge 2 ]] || die 'missing value for --wheelhouse-attestation-signature'; wheelhouse_attestation_signature="$2"; shift 2 ;;
    --oss-env-source) [[ "$#" -ge 2 ]] || die 'missing value for --oss-env-source'; oss_env_source="$2"; shift 2 ;;
    --replace-existing) replace_existing=true; shift ;;
    --legacy-retirement-evidence) [[ "$#" -ge 2 ]] || die 'missing value for --legacy-retirement-evidence'; legacy_retirement_evidence="$2"; shift 2 ;;
    --confirm-replace) [[ "$#" -ge 2 ]] || die 'missing value for --confirm-replace'; replace_confirmation="$2"; shift 2 ;;
    --enable-staging) enable_staging=true; shift ;;
    --expected-candidate-version) [[ "$#" -ge 2 ]] || die 'missing value for --expected-candidate-version'; expected_candidate_version="$2"; shift 2 ;;
    --confirm-oss-read-only) [[ "$#" -ge 2 ]] || die 'missing value for --confirm-oss-read-only'; oss_read_only_confirmation="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die 'run as root'
for required_value in \
  "$domain" "$office_cidr" "$vpn_cidr" "$tls_cert" "$tls_key" \
  "$oss_public_host" "$release_public_key" "$expected_signing_fingerprint" \
  "$wheelhouse" "$requirements_lock" "$wheelhouse_sha256s" "$wheelhouse_sbom" \
  "$wheelhouse_attestation" "$wheelhouse_attestation_signature"; do
  [[ -n "$required_value" ]] || { usage >&2; die 'all primary options are required'; }
done
if [[ "$replace_existing" == true ]]; then
  [[ "$replace_confirmation" == "$REPLACE_CONFIRMATION" ]] \
    || die "--replace-existing requires --confirm-replace '$REPLACE_CONFIRMATION'"
  [[ "$legacy_retirement_evidence" =~ ^/var/lib/uten-imp-legacy-evidence/retirement-[0-9a-f]{64}$ ]] \
    || die '--replace-existing requires the canonical --legacy-retirement-evidence directory produced by retire-legacy-updater.sh'
elif [[ -n "$replace_confirmation" || -n "$legacy_retirement_evidence" ]]; then
  die 'replacement evidence and confirmation are valid only with --replace-existing'
fi
if [[ "$enable_staging" == true ]]; then
  [[ "$expected_candidate_version" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-([1-9][0-9]{0,2})$ ]] \
    || die '--enable-staging requires a canonical --expected-candidate-version'
  [[ "$oss_read_only_confirmation" == "$OSS_READ_ONLY_CONFIRMATION" ]] \
    || die "--enable-staging requires --confirm-oss-read-only '$OSS_READ_ONLY_CONFIRMATION'"
  die '--enable-staging is intentionally NO-GO until tested candidate/release retention, disk quota, and alerting controls are installed'
elif [[ -n "$expected_candidate_version" || -n "$oss_read_only_confirmation" ]]; then
  die 'staging confirmations are valid only with --enable-staging'
fi

[[ ! -L "${BASH_SOURCE[0]}" ]] || die 'refusing to execute phase4 through a symlink'
readonly SCRIPT_FILE="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_FILE")" && pwd -P)"
readonly DEPLOY_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
readonly UPDATER_SOURCE="$DEPLOY_ROOT/updater"
readonly DB_RECOVERY_VERIFIER_SOURCE="$UPDATER_SOURCE/database_recovery_verifier.py"
readonly RUNTIME_BOOT_VERIFIER_SOURCE="$UPDATER_SOURCE/runtime_boot_verifier.py"
readonly STORAGE_BOOT_VERIFIER_SOURCE="$UPDATER_SOURCE/storage_boot_verifier.py"
readonly STORAGE_MOUNT_OBSERVER_SOURCE="$UPDATER_SOURCE/storage_mount_observer.py"
readonly MIGRATION_AUTHORIZATION_HELPER_SOURCE="$UPDATER_SOURCE/migration_authorization.py"
readonly RECOVERY_COMMIT_BOOT_VERIFIER_SOURCE="$UPDATER_SOURCE/recovery_commit_boot_verifier.py"
readonly RECOVERY_INGRESS_GATE_SOURCE="$UPDATER_SOURCE/recovery_ingress_gate.py"
readonly RECOVERY_COMMIT_BOOT_UNIT_TEMPLATE="$DEPLOY_ROOT/systemd/uten-imp-recovery-commit-verifier.service.example"
readonly NGINX_TEMPLATE="$DEPLOY_ROOT/nginx/uten-imp.conf.example"
readonly OPERATOR_GUIDE="$DEPLOY_ROOT/operator-guide.zh-CN.md"
readonly APP_UNIT_TEMPLATE="$DEPLOY_ROOT/systemd/uten-imp.service.example"
readonly MIGRATOR_UNIT_TEMPLATE="$DEPLOY_ROOT/systemd/uten-imp-migrate.service.example"
readonly POSTGRES_STORAGE_DROPIN_TEMPLATE="$DEPLOY_ROOT/systemd/postgresql-uten-imp-storage.conf.example"
readonly STORAGE_OBSERVER_UNIT_TEMPLATE="$DEPLOY_ROOT/systemd/uten-imp-storage-observer.service.example"
readonly SERVER_ENV_VALIDATOR_SOURCE="$SCRIPT_DIR/validate-server-env.sh"
readonly MIGRATOR_ENV_VALIDATOR_SOURCE="$SCRIPT_DIR/validate-migrator-env.sh"
readonly READINESS_GATE_SOURCE="$SCRIPT_DIR/wait-for-erp-readiness.sh"
readonly READINESS_GATE=/usr/local/libexec/uten-imp/uten-imp-wait-ready
readonly UPDATER_DIR=/opt/uten-imp/updater
readonly UPDATER_ETC=/etc/uten-imp-updater
readonly UPDATER_ENV="$UPDATER_ETC/oss-pull.env"
readonly ALLOWED_SIGNERS="$UPDATER_ETC/release-allowed-signers"
readonly STABLE_RELEASE_GUARD=/usr/local/libexec/uten-imp-release/release_guard.py
readonly STABLE_DB_RECOVERY_VERIFIER=/usr/local/libexec/uten-imp-release/database_recovery_verifier.py
readonly STABLE_RUNTIME_BOOT_VERIFIER=/usr/local/libexec/uten-imp-release/runtime_boot_verifier.py
readonly STABLE_STORAGE_BOOT_VERIFIER=/usr/local/libexec/uten-imp-release/storage_boot_verifier.py
readonly STABLE_STORAGE_MOUNT_OBSERVER=/usr/local/libexec/uten-imp-release/storage_mount_observer.py
readonly STABLE_MIGRATION_AUTHORIZATION_HELPER=/usr/local/libexec/uten-imp-release/migration_authorization.py
readonly STABLE_RECOVERY_COMMIT_BOOT_VERIFIER=/usr/local/libexec/uten-imp-release/recovery_commit_boot_verifier.py
readonly STABLE_RECOVERY_INGRESS_GATE=/usr/local/libexec/uten-imp-release/recovery_ingress_gate.py
readonly RECOVERY_COMMIT_BOOT_UNIT=/etc/systemd/system/uten-imp-recovery-commit-verifier.service
readonly MIGRATION_AUTHORIZATION_HELPER_SHA256='7eafd7e5111d1fceef5ade7ae2bdc63e3b96b44423f4ecf14924571308b02bfe'
readonly STABLE_ALLOWED_SIGNERS=/etc/uten-imp-release-trust/release-allowed-signers
readonly STORAGE_AUTHORITY=/etc/uten-imp/storage-authority.json
readonly ROOT_STATE=/var/lib/uten-imp-release
readonly OPERATION_LOCK="$ROOT_STATE/operation.lock"
readonly DB_MAINTENANCE_DIR=/var/lib/uten-imp-db-maintenance
readonly DB_MAINTENANCE_LOCK=$DB_MAINTENANCE_DIR/operation.lock
readonly POSTGRES_START_CONF=/etc/postgresql/16/main/start.conf
readonly POSTGRES_META_UNIT=postgresql.service
readonly POSTGRES_INSTANCE_UNIT=postgresql@16-main.service
readonly POSTGRES_GENERATOR_ROOT=/run/systemd/generator
readonly POSTGRES_GENERATOR_WANTS=$POSTGRES_GENERATOR_ROOT/postgresql.service.wants
readonly POSTGRES_GENERATOR_LINK=$POSTGRES_GENERATOR_WANTS/$POSTGRES_INSTANCE_UNIT
readonly NGINX_TARGET=/etc/nginx/conf.d/uten-imp.conf
readonly POSTGRES_STORAGE_DROPIN=/etc/systemd/system/postgresql@16-main.service.d/uten-imp-storage.conf
readonly STORAGE_OBSERVER_UNIT=/etc/systemd/system/uten-imp-storage-observer.service
readonly LEGACY_CREDENTIAL=/etc/uten-imp/oss-pull.env
readonly LEGACY_UPDATER_STATE=/var/lib/uten-imp-updater

require_root_directory_chain() {
  local current="$1" mode
  current="$(readlink -f -- "$current")"
  while true; do
    [[ -d "$current" && ! -L "$current" ]] || die "unsafe trusted directory: $current"
    [[ "$(stat -c '%u' -- "$current")" == 0 ]] || die "trusted directory is not root-owned: $current"
    mode="$(stat -c '%a' -- "$current")"
    (( (8#$mode & 022) == 0 )) || die "trusted directory is group/world-writable: $current"
    [[ "$current" == / ]] && break
    current="$(dirname -- "$current")"
  done
}

require_root_file() {
  local path="$1" mode
  [[ -f "$path" && ! -L "$path" ]] || die "trusted file must be regular and non-symlink: $path"
  [[ "$(stat -c '%u' -- "$path")" == 0 ]] || die "trusted file is not root-owned: $path"
  [[ "$(stat -c '%h' -- "$path")" == 1 ]] || die "trusted file has multiple hard links: $path"
  mode="$(stat -c '%a' -- "$path")"
  (( (8#$mode & 022) == 0 )) || die "trusted file is group/world-writable: $path"
  require_root_directory_chain "$(dirname -- "$path")"
}

atomic_install_root_file() {
  local source_file="$1" target_file="$2" mode="$3" group_name="$4"
  local target_parent temporary_file
  target_parent="$(dirname -- "$target_file")"
  temporary_file="$(mktemp "$target_parent/.${target_file##*/}.install.XXXXXX")"
  if ! install -m "$mode" -o root -g "$group_name" "$source_file" "$temporary_file"; then
    rm -f -- "$temporary_file"
    die "failed to prepare atomic root file: $target_file"
  fi
  sync -f "$temporary_file" || die "failed to fsync prepared root file: $target_file"
  mv -fT -- "$temporary_file" "$target_file"
  sync -f "$target_parent" || die "failed to fsync installed root file parent: $target_parent"
}

verify_database_maintenance_lock() {
  [[ -d "$DB_MAINTENANCE_DIR" && ! -L "$DB_MAINTENANCE_DIR" ]] \
    || die 'database maintenance directory must be real and non-symlinked'
  [[ "$(stat -c '%U:%G:%a' -- "$DB_MAINTENANCE_DIR")" == root:postgres:750 ]] \
    || die 'database maintenance directory must be root:postgres mode 0750'
  require_root_directory_chain "$(dirname -- "$DB_MAINTENANCE_DIR")"
  [[ -f "$DB_MAINTENANCE_LOCK" && ! -L "$DB_MAINTENANCE_LOCK" ]] \
    || die 'database maintenance lock must be a regular, non-symlink file'
  [[ "$(stat -c '%U:%G:%a:%h:%s' -- "$DB_MAINTENANCE_LOCK")" \
    == root:postgres:660:1:0 ]] \
    || die 'database maintenance lock must be empty root:postgres 0660 with one hard link'
}

verify_database_boot_contract() {
  local unit='' wants='' directory='' mode='' fragment=''
  [[ -f "$POSTGRES_START_CONF" && ! -L "$POSTGRES_START_CONF" ]] \
    || die 'PostgreSQL start.conf must be a regular, non-symlink file'
  [[ "$(stat -c '%U:%G:%a:%h' -- "$POSTGRES_START_CONF")" == root:root:644:1 ]] \
    || die 'PostgreSQL start.conf must be root:root 0644 with one hard link'
  cmp -s -- "$POSTGRES_START_CONF" <(printf 'auto\n') \
    || die 'PostgreSQL start.conf must contain exactly auto and one newline'
  for unit in "$POSTGRES_META_UNIT" "$POSTGRES_INSTANCE_UNIT"; do
    [[ "$(systemctl show --property=LoadState --value "$unit")" == loaded ]] \
      || die "database boot unit is not loaded: $unit"
    [[ "$(systemctl show --property=UnitFileState --value "$unit")" == enabled ]] \
      || die "database boot unit is not persistently enabled: $unit"
    [[ "$(systemctl show --property=ActiveState --value "$unit")" == active ]] \
      || die "database boot unit is not active: $unit"
  done
  wants=" $(systemctl show --property=Wants --value "$POSTGRES_META_UNIT") "
  [[ "$wants" == *" $POSTGRES_INSTANCE_UNIT "* ]] \
    || die 'postgresql.service does not want the 16/main instance from the generator'
  for directory in "$POSTGRES_GENERATOR_ROOT" "$POSTGRES_GENERATOR_WANTS"; do
    [[ -d "$directory" && ! -L "$directory" ]] \
      || die "PostgreSQL generator directory is missing or symlinked: $directory"
    [[ "$(stat -c '%U' -- "$directory")" == root ]] \
      || die "PostgreSQL generator directory is not root-owned: $directory"
    mode="$(stat -c '%a' -- "$directory")"
    (( (8#$mode & 0022) == 0 )) \
      || die "PostgreSQL generator directory is group- or other-writable: $directory"
  done
  [[ -L "$POSTGRES_GENERATOR_LINK" \
    && "$(stat -c '%U' -- "$POSTGRES_GENERATOR_LINK")" == root ]] \
    || die 'PostgreSQL generator instance dependency is not one root-owned symlink'
  fragment="$(systemctl show --property=FragmentPath --value "$POSTGRES_INSTANCE_UNIT")"
  [[ -n "$fragment" && -f "$fragment" ]] \
    || die 'PostgreSQL instance has no loaded fragment path'
  [[ "$(readlink -f -- "$POSTGRES_GENERATOR_LINK")" == "$(readlink -f -- "$fragment")" ]] \
    || die 'PostgreSQL generator dependency targets an unexpected unit fragment'
}

retirement_state_value() {
  local state_file="$1" key="$2"
  awk -F= -v wanted="$key" \
    '$1 == wanted { count++; value=substr($0, length($1) + 2) }
     END { if (count == 1) print value; else exit 1 }' "$state_file"
}

require_retirement_control_file() {
  local path="$1" label="$2" max_bytes="$3" size
  require_root_file "$path"
  [[ "$(stat -c '%U:%G:%a:%h' -- "$path")" == root:root:600:1 ]] \
    || die "$label must be root:root mode 0600 with one hard link"
  size="$(stat -c '%s' -- "$path")"
  (( size > 0 && size <= max_bytes )) || die "$label has an unsafe size"
}

validate_legacy_retirement_evidence() {
  local evidence="$1" complete closed manifest manifest_digest manifest_sha
  local marker logical status marker_manifest credential_evidence logical_evidence
  local namespace_entry namespace_name manifest_credential_digest
  [[ -d "$evidence" && ! -L "$evidence" ]] \
    || die 'legacy retirement evidence is not a real directory'
  [[ "$(realpath -e -- "$evidence")" == "$evidence" ]] \
    || die 'legacy retirement evidence path is non-canonical or contains a symlink'
  [[ "$(stat -c '%U:%G:%a' -- "$evidence")" == root:root:700 ]] \
    || die 'legacy retirement evidence directory must be root:root mode 0700'
  require_root_directory_chain "$evidence"
  if find -P "$evidence" -xdev -type l -print -quit | grep -q .; then
    die 'legacy retirement evidence contains a symlink'
  fi

  complete="$evidence/complete.state"
  closed="$evidence/in-progress.closed.state"
  manifest="$evidence/manifest.tsv"
  manifest_digest="$evidence/manifest.sha256"
  [[ ! -e "$evidence/in-progress.state" && ! -L "$evidence/in-progress.state" ]] \
    || die 'legacy retirement evidence still contains an open transaction marker'
  require_retirement_control_file "$complete" 'legacy retirement completion marker' 16384
  require_retirement_control_file "$closed" 'legacy retirement closed marker' 16384
  require_retirement_control_file "$manifest" 'legacy retirement manifest' 33554432
  require_retirement_control_file "$manifest_digest" 'legacy retirement manifest digest' 1024
  [[ "$(retirement_state_value "$complete" format)" == uten-imp-legacy-updater-retirement-v1 \
    && "$(retirement_state_value "$complete" status)" == COMPLETE ]] \
    || die 'legacy retirement completion marker is not canonical COMPLETE evidence'
  [[ "$(retirement_state_value "$closed" format)" == uten-imp-legacy-updater-retirement-v1 \
    && "$(retirement_state_value "$closed" status)" == IN_PROGRESS ]] \
    || die 'legacy retirement closed marker is not canonical transaction evidence'
  [[ "$(retirement_state_value "$closed" approval_reference)" \
      == "$(retirement_state_value "$complete" approval_reference)" \
    && "$(retirement_state_value "$closed" expected_credential_sha256)" \
      == "$(retirement_state_value "$complete" expected_credential_sha256)" ]] \
    || die 'legacy retirement completion and closed markers have different identities'
  [[ "$(retirement_state_value "$complete" expected_credential_sha256)" =~ ^[0-9a-f]{64}$ ]] \
    || die 'legacy retirement credential digest is malformed'
  [[ "$(retirement_state_value "$complete" approval_reference)" \
    =~ ^(CHG|CAB|SEC)-[A-Za-z0-9][A-Za-z0-9._-]{2,95}$ ]] \
    || die 'legacy retirement approval reference is malformed'

  manifest_sha="$(<"$manifest_digest")"
  [[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]] \
    || die 'legacy retirement manifest digest file is malformed'
  [[ "$(sha256sum -- "$manifest" | awk 'NR == 1 {print $1}')" == "$manifest_sha" ]] \
    || die 'legacy retirement manifest digest verification failed'
  [[ "$(retirement_state_value "$complete" manifest_sha256)" == "$manifest_sha" ]] \
    || die 'legacy retirement completion marker does not bind the manifest digest'
  [[ "$(awk -F '\t' 'NR == 1 && $1 == "format" {print $2}' "$manifest")" \
    == uten-imp-legacy-updater-retirement-v1 ]] \
    || die 'legacy retirement manifest format is not recognized'
  [[ "$(awk -F '\t' '$1 == "approval-reference" {count++; value=$2} END {if (count == 1) print value; else exit 1}' "$manifest")" \
    == "$(retirement_state_value "$complete" approval_reference)" ]] \
    || die 'legacy retirement manifest approval differs from completion evidence'

  for logical in credential config state; do
    marker="$evidence/moved-$logical.state"
    require_retirement_control_file "$marker" "legacy retirement $logical step marker" 4096
    [[ "$(retirement_state_value "$marker" format)" == uten-imp-legacy-updater-retirement-step-v1 \
      && "$(retirement_state_value "$marker" logical)" == "$logical" ]] \
      || die "legacy retirement $logical step marker is malformed"
    status="$(retirement_state_value "$marker" status)"
    [[ "$status" == moved || "$status" == absent ]] \
      || die "legacy retirement $logical step status is invalid"
    marker_manifest="$(retirement_state_value "$marker" manifest_sha256)"
    [[ "$marker_manifest" == "$manifest_sha" ]] \
      || die "legacy retirement $logical step is not bound to the completed manifest"
    if [[ "$logical" == credential && "$status" != moved ]]; then
      die 'legacy credential was not moved into evidence'
    fi
    case "$logical" in
      credential) logical_evidence="$evidence/legacy-etc-uten-imp-oss-pull.env" ;;
      config) logical_evidence="$evidence/legacy-etc-uten-imp-updater" ;;
      state) logical_evidence="$evidence/legacy-var-lib-uten-imp-updater" ;;
    esac
    if [[ "$status" == moved ]]; then
      if [[ "$logical" == credential ]]; then
        [[ -f "$logical_evidence" && ! -L "$logical_evidence" ]] \
          || die 'moved legacy credential evidence is missing'
      else
        [[ -d "$logical_evidence" && ! -L "$logical_evidence" ]] \
          || die "moved legacy $logical evidence directory is missing"
      fi
    else
      [[ ! -e "$logical_evidence" && ! -L "$logical_evidence" ]] \
        || die "legacy $logical was recorded absent but evidence exists"
    fi
  done

  credential_evidence="$evidence/legacy-etc-uten-imp-oss-pull.env"
  [[ -f "$credential_evidence" && ! -L "$credential_evidence" ]] \
    || die 'quarantined legacy credential evidence is missing'
  [[ "$(stat -c '%U:%G:%a:%h' -- "$credential_evidence")" == root:root:600:1 ]] \
    || die 'quarantined legacy credential evidence must be root:root mode 0600 with one hard link'
  [[ "$(sha256sum -- "$credential_evidence" | awk 'NR == 1 {print $1}')" \
    == "$(retirement_state_value "$complete" expected_credential_sha256)" ]] \
    || die 'quarantined legacy credential bytes differ from completion evidence'
  manifest_credential_digest="$(awk -F '\t' \
    '$1 == "credential-content" && $2 == "present" {count++; value=$4}
     END {if (count == 1) print value; else exit 1}' "$manifest")"
  [[ "$manifest_credential_digest" == "$(retirement_state_value "$complete" expected_credential_sha256)" ]] \
    || die 'legacy retirement manifest does not bind the approved credential digest'

  while IFS= read -r -d '' namespace_entry; do
    namespace_name="$(basename -- "$namespace_entry")"
    case "$namespace_name" in
      complete.state|in-progress.closed.state|manifest.tsv|manifest.sha256|moved-credential.state|moved-config.state|moved-state.state|legacy-etc-uten-imp-oss-pull.env|legacy-etc-uten-imp-updater|legacy-var-lib-uten-imp-updater) ;;
      .in-progress.state.tmp.*|.complete.state.tmp.*|.manifest.tsv.tmp.*|.manifest.sha256.tmp.*|.moved-credential.state.tmp.*|.moved-config.state.tmp.*|.moved-state.state.tmp.*)
        require_retirement_control_file "$namespace_entry" 'interrupted legacy-retirement control temporary' 33554432
        ;;
      *) die "legacy retirement evidence contains an unknown top-level entry: $namespace_name" ;;
    esac
  done < <(find -P "$evidence" -mindepth 1 -maxdepth 1 -print0)

  [[ ! -e "$LEGACY_CREDENTIAL" && ! -L "$LEGACY_CREDENTIAL" \
    && ! -e "$UPDATER_ETC" && ! -L "$UPDATER_ETC" \
    && ! -e "$LEGACY_UPDATER_STATE" && ! -L "$LEGACY_UPDATER_STATE" ]] \
    || die 'legacy updater live credential/config/state remain after the claimed retirement'
}

require_tls_file() {
  local path="$1" kind="$2" resolved mode
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "$kind path must be a canonical absolute path without shell metacharacters"
  require_root_directory_chain "$(dirname -- "$path")"
  resolved="$(readlink -f -- "$path")"
  [[ -f "$resolved" && ! -L "$resolved" ]] || die "$kind target is not a regular file"
  [[ "$(stat -c '%u' -- "$resolved")" == 0 ]] || die "$kind target is not root-owned"
  mode="$(stat -c '%a' -- "$resolved")"
  (( (8#$mode & 022) == 0 )) || die "$kind target is group/world-writable"
  if [[ "$kind" == 'TLS private key' ]]; then
    (( (8#$mode & 077) == 0 )) || die 'TLS private key must not be accessible to group or world'
  fi
  require_root_directory_chain "$(dirname -- "$resolved")"
}

require_root_directory_chain "$DEPLOY_ROOT"
required_sources=(
  "$SCRIPT_FILE"
  "$NGINX_TEMPLATE"
  "$OPERATOR_GUIDE"
  "$APP_UNIT_TEMPLATE"
  "$MIGRATOR_UNIT_TEMPLATE"
  "$POSTGRES_STORAGE_DROPIN_TEMPLATE"
  "$SERVER_ENV_VALIDATOR_SOURCE"
  "$MIGRATOR_ENV_VALIDATOR_SOURCE"
  "$READINESS_GATE_SOURCE"
  "$UPDATER_SOURCE/oss_io.py"
  "$DB_RECOVERY_VERIFIER_SOURCE"
  "$RUNTIME_BOOT_VERIFIER_SOURCE"
  "$STORAGE_BOOT_VERIFIER_SOURCE"
  "$STORAGE_MOUNT_OBSERVER_SOURCE"
  "$MIGRATION_AUTHORIZATION_HELPER_SOURCE"
  "$RECOVERY_COMMIT_BOOT_VERIFIER_SOURCE"
  "$RECOVERY_INGRESS_GATE_SOURCE"
  "$RECOVERY_COMMIT_BOOT_UNIT_TEMPLATE"
  "$STORAGE_OBSERVER_UNIT_TEMPLATE"
  "$UPDATER_SOURCE/release_guard.py"
  "$UPDATER_SOURCE/release_updater.py"
  "$UPDATER_SOURCE/retention_manager.py"
  "$UPDATER_SOURCE/wheelhouse_supply_chain.py"
  "$UPDATER_SOURCE/validate_oss_pull_env.py"
  "$UPDATER_SOURCE/uten-imp-updater.sh"
  "$UPDATER_SOURCE/uten-imp-activate.sh"
  "$UPDATER_SOURCE/uten-imp-recover.sh"
  "$UPDATER_SOURCE/uten-imp-updater.service"
  "$UPDATER_SOURCE/uten-imp-updater.timer"
  "$UPDATER_SOURCE/oss-pull.env.example"
)
for source_file in "${required_sources[@]}"; do
  require_root_file "$source_file"
done

for command_name in awk basename grep systemctl python3 ssh-keygen nginx openssl \
  mountpoint findmnt find stat install runuser pgrep readlink cmp sort sha256sum ss \
  pg_conftool; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done

python3 -I - "$domain" "$oss_public_host" "$office_cidr" "$vpn_cidr" "$expected_signing_fingerprint" <<'PY'
import ipaddress
import re
import sys

domain, oss_host, office_raw, vpn_raw, fingerprint = sys.argv[1:]
host_re = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)
if not host_re.fullmatch(domain) or not host_re.fullmatch(oss_host):
    raise SystemExit("domain and OSS public host must be canonical lowercase DNS names")
if not re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", fingerprint):
    raise SystemExit("expected signing fingerprint must be a canonical OpenSSH SHA256 fingerprint")
networks = []
for label, raw in (("office", office_raw), ("VPN", vpn_raw)):
    try:
        network = ipaddress.ip_network(raw, strict=True)
    except ValueError as exc:
        raise SystemExit(f"{label} CIDR is not canonical: {exc}") from exc
    if not network.is_private or network.is_loopback or network.is_multicast or network.prefixlen == 0:
        raise SystemExit(f"{label} CIDR must be an exact private non-default network")
    if network.version == 4 and network.prefixlen < 16:
        raise SystemExit(f"{label} IPv4 CIDR is broader than /16")
    if network.version == 6 and network.prefixlen < 48:
        raise SystemExit(f"{label} IPv6 CIDR is broader than /48")
    networks.append(network)
if networks[0].version == networks[1].version and networks[0].overlaps(networks[1]):
    raise SystemExit("office and VPN CIDRs must not overlap")
PY

require_tls_file "$tls_cert" 'TLS certificate'
require_tls_file "$tls_key" 'TLS private key'
openssl x509 -in "$tls_cert" -noout -checkend 2592000 \
  || die 'TLS certificate expires in less than 30 days'
openssl x509 -in "$tls_cert" -noout -checkhost "$domain" >/dev/null \
  || die 'TLS certificate SAN does not cover the configured ERP domain'
require_root_file "$release_public_key"
require_root_file "$requirements_lock"
require_root_file "$wheelhouse_sha256s"
require_root_file "$wheelhouse_sbom"
require_root_file "$wheelhouse_attestation"
require_root_file "$wheelhouse_attestation_signature"
[[ -s "$wheelhouse_sbom" ]] || die 'wheelhouse SBOM is empty'
(( $(stat -c '%s' -- "$requirements_lock") <= 524288 )) \
  || die 'wheelhouse requirements lock is unexpectedly large'
(( $(stat -c '%s' -- "$wheelhouse_sha256s") <= 524288 )) \
  || die 'wheelhouse SHA256SUMS is unexpectedly large'
(( $(stat -c '%s' -- "$wheelhouse_sbom") <= 16777216 )) \
  || die 'wheelhouse SBOM is unexpectedly large'
(( $(stat -c '%s' -- "$wheelhouse_attestation") <= 16777216 )) \
  || die 'wheelhouse attestation is unexpectedly large'
(( $(stat -c '%s' -- "$wheelhouse_attestation_signature") <= 32768 )) \
  || die 'wheelhouse attestation signature is unexpectedly large'
if [[ -n "$oss_env_source" ]]; then
  require_root_file "$oss_env_source"
  [[ "$(stat -c '%U:%G:%a' -- "$oss_env_source")" == root:root:600 ]] \
    || die '--oss-env-source must be root:root mode 0600'
  /usr/bin/python3 -I "$UPDATER_SOURCE/validate_oss_pull_env.py" --source "$oss_env_source"
fi
require_root_directory_chain "$wheelhouse"
[[ -d "$wheelhouse" && ! -L "$wheelhouse" ]] || die 'wheelhouse must be a real directory'

/usr/bin/python3 -I - "$requirements_lock" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
logical = []
pending = ""
for number, raw in enumerate(path.read_text(encoding="ascii").splitlines(), 1):
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue
    if "#" in stripped or ";" in stripped:
        raise SystemExit(f"requirements lock line {number} contains an inline directive")
    continued = stripped.endswith("\\")
    fragment = stripped[:-1].strip() if continued else stripped
    pending = f"{pending} {fragment}".strip()
    if not continued:
        logical.append((number, pending))
        pending = ""
if pending:
    raise SystemExit("requirements lock ends with an unfinished continuation")
entry_re = re.compile(
    r"([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9][A-Za-z0-9.!+_-]*)"
    r"((?:\s+--hash=sha256:[0-9a-f]{64})+)"
)
packages = {}
for number, entry in logical:
    match = entry_re.fullmatch(entry)
    if not match:
        raise SystemExit(
            f"requirements lock entry ending at line {number} is not an exact pin plus SHA-256 hashes"
        )
    name = re.sub(r"[-_.]+", "-", match.group(1)).lower()
    if name in packages:
        raise SystemExit(f"duplicate package pin: {name}")
    packages[name] = match.group(2)
if packages.get("oss2") != "2.19.1":
    raise SystemExit("requirements lock must pin oss2==2.19.1")
PY

python3 -I - "$wheelhouse" "$wheelhouse_sha256s" <<'PY'
import hashlib
import re
import stat
import sys
from pathlib import Path

wheelhouse = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
actual = set()
for child in wheelhouse.iterdir():
    details = child.lstat()
    if not stat.S_ISREG(details.st_mode) or child.is_symlink() or child.suffix != ".whl":
        raise SystemExit("wheelhouse must be flat and contain wheel files only")
    if details.st_uid != 0 or stat.S_IMODE(details.st_mode) & 0o022 or details.st_nlink != 1:
        raise SystemExit("every wheel must be root-owned, non-writable, and single-link")
    actual.add(child.name)
expected = {}
for number, line in enumerate(manifest_path.read_text(encoding="ascii").splitlines(), 1):
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*\.whl)", line)
    if not match or match.group(2) in expected:
        raise SystemExit(f"invalid wheelhouse SHA256 manifest line {number}")
    expected[match.group(2)] = match.group(1)
if actual != set(expected):
    raise SystemExit("wheelhouse SHA256 inventory does not exactly match its files")
for name, digest in expected.items():
    hasher = hashlib.sha256()
    with (wheelhouse / name).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(block)
    if hasher.hexdigest() != digest:
        raise SystemExit(f"wheel digest mismatch: {name}")
PY
/usr/bin/python3 -I - "$wheelhouse" /opt <<'PY'
import os
import pathlib
import sys

wheelhouse = pathlib.Path(sys.argv[1])
size = sum(path.stat().st_size for path in wheelhouse.iterdir())
stats = os.statvfs(sys.argv[2])
free = stats.f_bavail * stats.f_frsize
total = stats.f_blocks * stats.f_frsize
required = size * 5 + 1024 * 1024 * 1024
if free < required or free - required < total // 10:
    raise SystemExit("/opt lacks the wheel expansion budget plus 10% filesystem reserve")
PY

actual_fingerprint="$(ssh-keygen -E sha256 -lf "$release_public_key" | awk 'NR == 1 {print $2}')"
[[ "$actual_fingerprint" == "$expected_signing_fingerprint" ]] \
  || die 'release public-key fingerprint differs from the out-of-band value'
read -r release_key_type release_key_blob _ <"$release_public_key"
[[ "$release_key_type" == ssh-ed25519 ]] || die 'release signing key must be Ed25519'
[[ "$release_key_blob" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || die 'release public key is malformed'
[[ "$(grep -Ec '^[^[:space:]#]' "$release_public_key")" == 1 ]] \
  || die 'release public-key file must contain exactly one key'
require_root_file "$STABLE_RELEASE_GUARD"
require_root_file "$STABLE_ALLOWED_SIGNERS"
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_RELEASE_GUARD")" == root:root:644:1 ]] \
  || die 'stable privileged release guard must be root:root mode 0644 with one hard link'
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_ALLOWED_SIGNERS")" == root:root:640:1 ]] \
  || die 'stable release trust policy must be root:root mode 0640 with one hard link'
cmp -s -- "$UPDATER_SOURCE/release_guard.py" "$STABLE_RELEASE_GUARD" \
  || die 'stable privileged release guard differs from the reviewed Phase 4 source'
# These are read-only prerequisites and intentionally precede Phase 4's first
# filesystem mutation. A drifted database boot authority or shared maintenance
# lock leaves the host byte-for-byte untouched by this installer.
verify_database_maintenance_lock
verify_database_boot_contract
install -d -m 0755 -o root -g root /usr/local/libexec/uten-imp-release
# Never replace the root ExecStartPre authority while a Flyway JVM or its
# pre-start chain could be running. The broader managed-unit audit is repeated
# below before any updater/Nginx installation.
[[ "$(sha256sum -- "$MIGRATION_AUTHORIZATION_HELPER_SOURCE" \
  | awk 'NR == 1 {print $1}')" == "$MIGRATION_AUTHORIZATION_HELPER_SHA256" ]] \
  || die 'migration authorization helper differs from the fixed Phase 4 digest'
systemctl is-active --quiet uten-imp-migrate.service 2>/dev/null \
  && die 'migration service must be inactive before replacing its authorization helper'
atomic_install_root_file \
  "$DB_RECOVERY_VERIFIER_SOURCE" "$STABLE_DB_RECOVERY_VERIFIER" 0644 root
atomic_install_root_file \
  "$RUNTIME_BOOT_VERIFIER_SOURCE" "$STABLE_RUNTIME_BOOT_VERIFIER" 0644 root
atomic_install_root_file \
  "$STORAGE_BOOT_VERIFIER_SOURCE" "$STABLE_STORAGE_BOOT_VERIFIER" 0644 root
atomic_install_root_file \
  "$STORAGE_MOUNT_OBSERVER_SOURCE" "$STABLE_STORAGE_MOUNT_OBSERVER" 0644 root
atomic_install_root_file \
  "$MIGRATION_AUTHORIZATION_HELPER_SOURCE" \
  "$STABLE_MIGRATION_AUTHORIZATION_HELPER" 0644 root
atomic_install_root_file \
  "$RECOVERY_COMMIT_BOOT_VERIFIER_SOURCE" \
  "$STABLE_RECOVERY_COMMIT_BOOT_VERIFIER" 0644 root
atomic_install_root_file \
  "$RECOVERY_INGRESS_GATE_SOURCE" "$STABLE_RECOVERY_INGRESS_GATE" 0644 root
require_root_file "$STABLE_DB_RECOVERY_VERIFIER"
require_root_file "$STABLE_RUNTIME_BOOT_VERIFIER"
require_root_file "$STABLE_STORAGE_BOOT_VERIFIER"
require_root_file "$STABLE_STORAGE_MOUNT_OBSERVER"
require_root_file "$STABLE_MIGRATION_AUTHORIZATION_HELPER"
require_root_file "$STABLE_RECOVERY_COMMIT_BOOT_VERIFIER"
require_root_file "$STABLE_RECOVERY_INGRESS_GATE"
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_DB_RECOVERY_VERIFIER")" == root:root:644:1 ]] \
  || die 'database recovery verifier must be root:root mode 0644 with one hard link'
cmp -s -- "$DB_RECOVERY_VERIFIER_SOURCE" "$STABLE_DB_RECOVERY_VERIFIER" \
  || die 'installed database recovery verifier differs from the reviewed Phase 4 source'
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_RUNTIME_BOOT_VERIFIER")" == root:root:644:1 ]] \
  || die 'runtime boot verifier must be root:root mode 0644 with one hard link'
cmp -s -- "$RUNTIME_BOOT_VERIFIER_SOURCE" "$STABLE_RUNTIME_BOOT_VERIFIER" \
  || die 'installed runtime boot verifier differs from the reviewed Phase 4 source'
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_STORAGE_BOOT_VERIFIER")" == root:root:644:1 ]] \
  || die 'storage boot verifier must be root:root mode 0644 with one hard link'
cmp -s -- "$STORAGE_BOOT_VERIFIER_SOURCE" "$STABLE_STORAGE_BOOT_VERIFIER" \
  || die 'installed storage boot verifier differs from the reviewed Phase 4 source'
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_STORAGE_MOUNT_OBSERVER")" == root:root:644:1 ]] \
  || die 'storage mount observer must be root:root mode 0644 with one hard link'
cmp -s -- "$STORAGE_MOUNT_OBSERVER_SOURCE" "$STABLE_STORAGE_MOUNT_OBSERVER" \
  || die 'installed storage mount observer differs from the reviewed Phase 4 source'
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_MIGRATION_AUTHORIZATION_HELPER")" == root:root:644:1 ]] \
  || die 'migration authorization helper must be root:root mode 0644 with one hard link'
cmp -s -- "$MIGRATION_AUTHORIZATION_HELPER_SOURCE" \
  "$STABLE_MIGRATION_AUTHORIZATION_HELPER" \
  || die 'installed migration authorization helper differs from the reviewed Phase 4 source'
cmp -s -- "$RECOVERY_COMMIT_BOOT_VERIFIER_SOURCE" \
  "$STABLE_RECOVERY_COMMIT_BOOT_VERIFIER" \
  || die 'installed recovery commit verifier differs from the reviewed Phase 4 source'
cmp -s -- "$RECOVERY_INGRESS_GATE_SOURCE" "$STABLE_RECOVERY_INGRESS_GATE" \
  || die 'installed recovery ingress gate differs from the reviewed Phase 4 source'
/usr/bin/python3 -I - "$UPDATER_SOURCE/release_updater.py" \
  "$STABLE_DB_RECOVERY_VERIFIER" "$STABLE_RUNTIME_BOOT_VERIFIER" \
  "$STABLE_STORAGE_BOOT_VERIFIER" "$STABLE_RELEASE_GUARD" \
  "$STABLE_STORAGE_MOUNT_OBSERVER" \
  "$STABLE_MIGRATION_AUTHORIZATION_HELPER" <<'PY'
import ast
import hashlib
import sys
from pathlib import Path

updater = ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
assignments = {
    target.id: ast.literal_eval(node.value)
    for node in updater.body
    if isinstance(node, ast.Assign)
    for target in node.targets
    if isinstance(target, ast.Name)
    and target.id in {
        "DATABASE_RECOVERY_VERIFIER_SHA256",
        "RUNTIME_BOOT_VERIFIER_SHA256",
        "STORAGE_BOOT_VERIFIER_SHA256",
        "STORAGE_MOUNT_OBSERVER_SHA256",
        "MIGRATION_AUTHORIZATION_HELPER_SHA256",
    }
}
checks = (
    ("DATABASE_RECOVERY_VERIFIER_SHA256", Path(sys.argv[2])),
    ("RUNTIME_BOOT_VERIFIER_SHA256", Path(sys.argv[3])),
    ("STORAGE_BOOT_VERIFIER_SHA256", Path(sys.argv[4])),
    ("STORAGE_MOUNT_OBSERVER_SHA256", Path(sys.argv[6])),
    ("MIGRATION_AUTHORIZATION_HELPER_SHA256", Path(sys.argv[7])),
)
for name, path in checks:
    expected = assignments.get(name)
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"installed {name} digest differs from updater policy")

boot = ast.parse(Path(sys.argv[3]).read_text(encoding="utf-8"))
boot_assignments = {
    target.id: ast.literal_eval(node.value)
    for node in boot.body
    if isinstance(node, ast.Assign)
    for target in node.targets
    if isinstance(target, ast.Name)
    and target.id in {
        "DATABASE_VERIFIER_SHA256",
        "RELEASE_GUARD_SHA256",
        "STORAGE_VERIFIER_SHA256",
    }
}
for name, path in (
    ("DATABASE_VERIFIER_SHA256", Path(sys.argv[2])),
    ("STORAGE_VERIFIER_SHA256", Path(sys.argv[4])),
    ("RELEASE_GUARD_SHA256", Path(sys.argv[5])),
):
    if hashlib.sha256(path.read_bytes()).hexdigest() != boot_assignments.get(name):
        raise SystemExit(f"runtime boot verifier {name} dependency digest is stale")
PY
[[ "$(grep -Ec '^uten-imp-release[[:space:]]+ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,2}$' "$STABLE_ALLOWED_SIGNERS")" == 1 \
  && "$(grep -Ec '^[^[:space:]#]' "$STABLE_ALLOWED_SIGNERS")" == 1 ]] \
  || die 'stable release trust policy must contain exactly one canonical Uten Ed25519 key'
read -r stable_identity stable_key_type stable_key_blob <"$STABLE_ALLOWED_SIGNERS"
stable_key_file="$(mktemp /tmp/uten-stable-release-key.XXXXXX)"
printf '%s %s\n' "$stable_key_type" "$stable_key_blob" >"$stable_key_file"
stable_fingerprint="$(ssh-keygen -E sha256 -lf "$stable_key_file" | awk 'NR == 1 {print $2}')" \
  || { rm -f -- "$stable_key_file"; die 'stable release key cannot be fingerprinted'; }
rm -f -- "$stable_key_file"
[[ "$stable_fingerprint" == "$actual_fingerprint" ]] \
  || die 'Phase 4 release key differs from the independently bootstrapped stable trust policy'
ssh-keygen -Y verify -f "$STABLE_ALLOWED_SIGNERS" -I uten-imp-release \
  -n uten-imp-updater-wheelhouse-v1 -s "$wheelhouse_attestation_signature" \
  < "$wheelhouse_attestation" \
  || die 'updater wheelhouse attestation signature verification failed'
/usr/bin/python3 -I - "$wheelhouse_attestation" \
  "$UPDATER_SOURCE/wheelhouse_supply_chain.py" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

attestation_path = Path(sys.argv[1])
verifier_path = Path(sys.argv[2])
raw = attestation_path.read_bytes()
try:
    statement = json.loads(raw.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit("signed wheelhouse attestation is not UTF-8 JSON") from exc
canonical = (json.dumps(statement, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
if raw != canonical or not isinstance(statement, dict):
    raise SystemExit("signed wheelhouse attestation is not canonical JSON")
predicate = statement.get("predicate")
metadata = predicate.get("metadata") if isinstance(predicate, dict) else None
properties = metadata.get("properties") if isinstance(metadata, dict) else None
if not isinstance(properties, list) or any(
    not isinstance(item, dict) or set(item) != {"name", "value"}
    for item in properties
):
    raise SystemExit("signed wheelhouse attestation has invalid SBOM properties")
matches = [
    item["value"]
    for item in properties
    if item["name"] == "uten:builder:verifier-sha256"
]
if len(matches) != 1 or re.fullmatch(r"[0-9a-f]{64}", matches[0]) is None:
    raise SystemExit("signed wheelhouse attestation lacks one verifier source digest")
actual = hashlib.sha256(verifier_path.read_bytes()).hexdigest()
if actual != matches[0]:
    raise SystemExit("local wheelhouse verifier differs from the signed protected source")
PY
/usr/bin/python3 -I "$UPDATER_SOURCE/wheelhouse_supply_chain.py" verify \
  --lock "$requirements_lock" --wheelhouse "$wheelhouse" \
  --sums "$wheelhouse_sha256s" --sbom "$wheelhouse_sbom" \
  --attestation "$wheelhouse_attestation"
install_allowed_signer=true
if [[ -e "$ALLOWED_SIGNERS" || -L "$ALLOWED_SIGNERS" ]]; then
  require_root_directory_chain "$(dirname -- "$ALLOWED_SIGNERS")"
  [[ -f "$ALLOWED_SIGNERS" && ! -L "$ALLOWED_SIGNERS" ]] \
    || die 'existing allowed_signers must be a regular non-symlink file'
  [[ "$(stat -c '%U:%a:%h' -- "$ALLOWED_SIGNERS")" == root:640:1 ]] \
    || die 'existing allowed_signers must be root-owned mode 0640 with one hard link'
  [[ "$(grep -Ec '^uten-imp-release[[:space:]]+ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,2}([[:space:]].*)?$' "$ALLOWED_SIGNERS")" == 1 ]] \
    || die 'existing allowed_signers must contain exactly one canonical Uten release key'
  [[ "$(grep -Ec '^[^[:space:]#]' "$ALLOWED_SIGNERS")" == 1 ]] \
    || die 'existing allowed_signers contains an unexpected identity or rotation state'
  read -r existing_identity existing_key_type existing_key_blob _ <"$ALLOWED_SIGNERS"
  existing_key_file="$(mktemp /tmp/uten-existing-release-key.XXXXXX)"
  printf '%s %s\n' "$existing_key_type" "$existing_key_blob" >"$existing_key_file"
  if ! existing_fingerprint="$(ssh-keygen -E sha256 -lf "$existing_key_file" | awk 'NR == 1 {print $2}')"; then
    rm -f -- "$existing_key_file"
    die 'existing release public key cannot be fingerprinted'
  fi
  rm -f -- "$existing_key_file"
  if [[ "$existing_fingerprint" != "$actual_fingerprint" ]]; then
    die 'release signing key differs from existing trust; ordinary reinstall may not collapse trust—use a separately audited overlap rotation procedure'
  fi
  install_allowed_signer=false
fi

echo '==> Confirm storage and inactive commissioning state'
mountpoint --quiet /data || die '/data must be a real mounted filesystem'
require_root_file "$STORAGE_AUTHORITY"
[[ "$(stat -c '%U:%G:%a:%h' -- "$STORAGE_AUTHORITY")" == root:root:640:1 ]] \
  || die 'storage authority must be root:root mode 0640 with one hard link'
if ! /usr/bin/python3 -I "$STABLE_STORAGE_BOOT_VERIFIER"; then
  die 'the installed fail-closed verifier cannot prove the commissioned /data topology'
fi
/usr/bin/python3 -I - "$STABLE_STORAGE_BOOT_VERIFIER" /proc/mdstat <<'PY'
import importlib.util
import os
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("uten_imp_storage_boot", source)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load installed storage verifier")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
authority = module._read_authority()
if module.validate_authority(authority) == 3:
    raise SystemExit(0)
resolved = os.path.realpath(authority["dataSource"])
md_name = Path(resolved).name
text = Path(sys.argv[2]).read_text(encoding="ascii")
match = re.search(
    rf"(?ms)^{re.escape(md_name)}\s*:\s*active\b.*?(?=^md\d+\s*:|^unused devices:|\Z)",
    text,
)
if match is None or re.search(r"(?:resync|recovery|reshape|check|repair)\s*=", match.group(0)):
    raise SystemExit("legacy commissioned md array is absent or busy")
counts = re.search(r"\[(\d+)/(\d+)\]", match.group(0))
state = re.search(r"\[([U_]+)\]", match.group(0))
if not counts or counts.group(1) != counts.group(2) or not state or "_" in state.group(1):
    raise SystemExit("legacy commissioned md array is degraded")
PY
[[ -d /opt/uten-imp/releases && ! -L /opt/uten-imp/releases ]] \
  || die 'phase3 runtime baseline is missing /opt/uten-imp/releases'
for trusted_parent in \
  /opt/uten-imp /opt/uten-imp/releases /var/lib /etc/nginx/conf.d \
  /etc/systemd/system /usr/local /usr/local/sbin /usr/local/share; do
  require_root_directory_chain "$trusted_parent"
done
for optional_root_path in "$ROOT_STATE" "$UPDATER_ETC" "$UPDATER_DIR"; do
  if [[ -e "$optional_root_path" || -L "$optional_root_path" ]]; then
    [[ ! -L "$optional_root_path" ]] || die "managed directory must not be a symlink: $optional_root_path"
    require_root_directory_chain "$optional_root_path"
  fi
done
if [[ -e /var/lib/uten-imp-updater || -L /var/lib/uten-imp-updater ]]; then
  [[ -d /var/lib/uten-imp-updater && ! -L /var/lib/uten-imp-updater ]] \
    || die '/var/lib/uten-imp-updater must be a real directory'
fi
require_root_file /usr/local/sbin/uten-imp-validate-server-env
cmp -s -- "$SERVER_ENV_VALIDATOR_SOURCE" /usr/local/sbin/uten-imp-validate-server-env \
  || die 'installed application environment validator differs from the reviewed phase3 source'
[[ -x /usr/local/sbin/uten-imp-validate-server-env ]] \
  || die 'phase3 environment validator is not executable'
/usr/local/sbin/uten-imp-validate-server-env /etc/uten-imp/server.env
require_root_file /usr/local/sbin/uten-imp-validate-migrator-env
cmp -s -- "$MIGRATOR_ENV_VALIDATOR_SOURCE" /usr/local/sbin/uten-imp-validate-migrator-env \
  || die 'installed migrator environment validator differs from the reviewed phase3 source'
[[ -x /usr/local/sbin/uten-imp-validate-migrator-env ]] \
  || die 'phase3 migrator environment validator is not executable'
/usr/local/sbin/uten-imp-validate-migrator-env /etc/uten-imp-migrator/migrator.env
require_root_file "$READINESS_GATE"
cmp -s -- "$READINESS_GATE_SOURCE" "$READINESS_GATE" \
  || die 'installed Nginx readiness gate differs from the reviewed phase3 source'
[[ -x "$READINESS_GATE" ]] || die 'Nginx readiness gate is not executable'
require_root_file /etc/systemd/system/uten-imp.service
cmp -s -- "$APP_UNIT_TEMPLATE" /etc/systemd/system/uten-imp.service \
  || die 'installed application unit differs from the reviewed phase3 template'
require_root_file "$RECOVERY_COMMIT_BOOT_UNIT"
cmp -s -- "$RECOVERY_COMMIT_BOOT_UNIT_TEMPLATE" "$RECOVERY_COMMIT_BOOT_UNIT" \
  || die 'installed recovery commit verifier unit differs from the reviewed phase3 template'
[[ "$(systemctl show --property=UnitFileState --value uten-imp-recovery-commit-verifier.service)" == enabled \
  && "$(systemctl show --property=ActiveState --value uten-imp-recovery-commit-verifier.service)" == active \
  && "$(systemctl show --property=FragmentPath --value uten-imp-recovery-commit-verifier.service)" == "$RECOVERY_COMMIT_BOOT_UNIT" \
  && -z "$(systemctl show --property=DropInPaths --value uten-imp-recovery-commit-verifier.service)" ]] \
  || die 'recovery commit verifier is not the active fixed Phase3 unit'
[[ ! -e /etc/systemd/system/uten-imp.service.d \
  && ! -L /etc/systemd/system/uten-imp.service.d ]] \
  || die 'application unit drop-ins are not permitted'
require_root_file /etc/systemd/system/uten-imp-migrate.service
cmp -s -- "$MIGRATOR_UNIT_TEMPLATE" /etc/systemd/system/uten-imp-migrate.service \
  || die 'installed migrator unit differs from the reviewed phase3 template'
[[ ! -e /etc/systemd/system/uten-imp-migrate.service.d \
  && ! -L /etc/systemd/system/uten-imp-migrate.service.d ]] \
  || die 'migrator unit drop-ins are not permitted'
migrator_after=" $(systemctl show --property=After --value uten-imp-migrate.service) "
[[ "$migrator_after" == *' network-online.target '* \
  && "$migrator_after" == *' data.mount '* \
  && "$migrator_after" == *" $POSTGRES_INSTANCE_UNIT "* ]] \
  || die 'loaded migrator unit lacks reviewed ordering-only dependencies'
[[ "$(systemctl show --property=Wants --value uten-imp-migrate.service)" \
  == network-online.target ]] \
  || die 'loaded migrator unit Wants must contain only network-online.target'
for pull_property in Requires Requisite BindsTo PartOf Upholds; do
  pull_dependencies=" $(systemctl show --property="$pull_property" --value uten-imp-migrate.service) "
  [[ "$pull_dependencies" != *" $POSTGRES_INSTANCE_UNIT "* \
    && "$pull_dependencies" != *' data.mount '* ]] \
    || die "loaded migrator unit must not pull PostgreSQL or /data through $pull_property="
done
[[ -z "$(systemctl show --property=RequiresMountsFor --value uten-imp-migrate.service)" ]] \
  || die 'loaded migrator unit must not pull /data through RequiresMountsFor='
require_root_file "$STABLE_STORAGE_BOOT_VERIFIER"
cmp -s -- "$STORAGE_BOOT_VERIFIER_SOURCE" "$STABLE_STORAGE_BOOT_VERIFIER" \
  || die 'installed storage boot verifier differs from the reviewed Phase 4 source'
[[ "$(stat -c '%U:%G:%a:%h' -- "$STABLE_STORAGE_BOOT_VERIFIER")" == root:root:644:1 ]] \
  || die 'storage boot verifier must be root:root mode 0644 with one hard link'
require_root_file "$POSTGRES_STORAGE_DROPIN"
cmp -s -- "$POSTGRES_STORAGE_DROPIN_TEMPLATE" "$POSTGRES_STORAGE_DROPIN" \
  || die 'installed PostgreSQL storage drop-in differs from the reviewed template'
[[ "$(systemctl show --property=DropInPaths --value postgresql@16-main.service)" == "$POSTGRES_STORAGE_DROPIN" ]] \
  || die 'PostgreSQL has an unreviewed or unloaded systemd drop-in set'
systemctl show --property=ExecStartPre --value postgresql@16-main.service \
  | grep -Fq '/usr/local/libexec/uten-imp-release/storage_boot_verifier.py' \
  || die 'PostgreSQL loaded unit lacks the storage boot verifier'
require_root_file "$STORAGE_OBSERVER_UNIT"
[[ "$(stat -c '%U:%G:%a:%h' -- "$STORAGE_OBSERVER_UNIT")" == root:root:644:1 ]] \
  || die 'storage observer unit must be root:root mode 0644 with one hard link'
[[ ! -e /etc/systemd/system/uten-imp-storage-observer.service.d \
  && ! -L /etc/systemd/system/uten-imp-storage-observer.service.d ]] \
  || die 'storage observer unit drop-ins are not permitted'
/usr/bin/python3 -I - "$STABLE_STORAGE_MOUNT_OBSERVER" "$STORAGE_AUTHORITY" \
  "$STORAGE_OBSERVER_UNIT_TEMPLATE" "$STORAGE_OBSERVER_UNIT" <<'PY'
import importlib.util
import os
import re
import stat
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
authority_path = Path(sys.argv[2])
template_path = Path(sys.argv[3])
unit_path = Path(sys.argv[4])
spec = importlib.util.spec_from_file_location("uten_imp_storage_observer", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load installed storage observer")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
authority = module._authority(authority_path.read_bytes())
fstab_raw = module._read_regular(
    module.FSTAB_PATH, exact_mode=None, maximum=module.MAX_FSTAB_BYTES
)
module._validate_fstab_and_data_unit(authority, fstab_raw)
if authority["schemaVersion"] == 2:
    device = os.path.realpath(authority["dataSource"])
    if not re.fullmatch(r"/dev/md\d+", device):
        raise SystemExit("legacy authority does not resolve to /dev/mdN")
    try:
        device_details = os.stat(device)
    except OSError as exc:
        raise SystemExit(f"legacy authority device cannot be stated: {exc}") from exc
    if not stat.S_ISBLK(device_details.st_mode):
        raise SystemExit("legacy authority resolved source is not a block device")
    expected = module.render_observer_unit(device)
else:
    expected = module.render_observer_unit(None)
template = template_path.read_text(encoding="utf-8")
if authority["schemaVersion"] == 3 and template != expected:
    raise SystemExit("v3 storage observer template differs from the helper contract")
if unit_path.read_text(encoding="utf-8") != expected:
    raise SystemExit("installed storage observer unit differs from its authority generation")
PY
[[ "$(systemctl show --property=LoadState --value uten-imp-storage-observer.service)" == loaded \
  && "$(systemctl show --property=FragmentPath --value uten-imp-storage-observer.service)" == "$STORAGE_OBSERVER_UNIT" \
  && -z "$(systemctl show --property=DropInPaths --value uten-imp-storage-observer.service)" \
  && "$(systemctl show --property=DevicePolicy --value uten-imp-storage-observer.service)" == closed ]] \
  || die 'loaded storage observer differs from the fixed exact-device service contract'
if find /opt/uten-imp -mindepth 1 -maxdepth 1 \
  \( -name '.updater-install.*' -o -name '.updater-rejected.*' \) -print -quit | grep -q .; then
  die 'a prior updater-build/rejected directory remains; audit it before retrying phase4'
fi

legacy_nginx_files=()
for nginx_include_dir in /etc/nginx/conf.d /etc/nginx/sites-enabled; do
  [[ -d "$nginx_include_dir" ]] || continue
  while IFS= read -r -d '' nginx_file; do
    resolved_nginx_file="$(readlink -f -- "$nginx_file")"
    if [[ "$resolved_nginx_file" != "$(readlink -m -- "$NGINX_TARGET")" ]]; then
      legacy_nginx_files+=("$nginx_file")
    fi
  done < <(grep -RIlZ -E \
    'uten_imp_backend|/opt/uten-imp/current|listen[[:space:]]+127\.0\.0\.1:8081|proxy_pass[[:space:]]+http://127\.0\.0\.1:8080|listen[[:space:]]+([^;[:space:]]+:)?(80|443)([[:space:]]|;)' \
    "$nginx_include_dir" 2>/dev/null || true)
done
if (( ${#legacy_nginx_files[@]} > 0 )); then
  printf 'Legacy Uten Nginx include(s) must be migrated through an approved change:\n' >&2
  printf '  - %s\n' "${legacy_nginx_files[@]}" >&2
  die 'refusing to install alongside a second Uten HTTP/TLS/loopback site'
fi

managed_units=(
  nginx.service
  uten-imp-migrate.service
  uten-imp.service
  uten-imp-watchdog.service
  uten-imp-watchdog.timer
  uten-imp-storage-observer.service
  uten-imp-entry-watchdog.service
  uten-imp-entry-watchdog.timer
  uten-imp-updater.service
  uten-imp-updater.timer
)
for unit in "${managed_units[@]}"; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    die "commissioning requires the unit to be inactive: $unit"
  fi
  if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    die "commissioning requires the unit to be disabled: $unit"
  fi
done
if [[ "$replace_existing" == true ]]; then
  validate_legacy_retirement_evidence "$legacy_retirement_evidence"
else
  [[ ! -e "$LEGACY_CREDENTIAL" && ! -L "$LEGACY_CREDENTIAL" \
    && ! -e "$UPDATER_ETC" && ! -L "$UPDATER_ETC" \
    && ! -e "$LEGACY_UPDATER_STATE" && ! -L "$LEGACY_UPDATER_STATE" ]] \
    || die 'pre-existing updater credential/config/state requires the audited retirement helper and explicit Phase 4 replacement contract'
fi

existing_targets=(
  "$UPDATER_DIR"
  "$UPDATER_ETC"
  /etc/systemd/system/uten-imp-updater.service
  /etc/systemd/system/uten-imp-updater.timer
  /usr/local/sbin/uten-imp-activate
  /usr/local/sbin/uten-imp-recover
  "$NGINX_TARGET"
  "$UPDATER_ENV"
  "$UPDATER_ETC/oss-pull.env.pending.example"
)
found_existing=false
for existing_target in "${existing_targets[@]}"; do
  if [[ -e "$existing_target" || -L "$existing_target" ]]; then
    found_existing=true
    [[ ! -L "$existing_target" ]] || die "managed target must not be a symlink: $existing_target"
    if [[ -f "$existing_target" ]]; then
      [[ "$(stat -c '%h' -- "$existing_target")" == 1 ]] \
        || die "managed file must have one hard link: $existing_target"
    fi
  fi
done
if [[ "$found_existing" == true && "$replace_existing" != true ]]; then
  die 'existing Phase 4 files detected; use an approved maintenance window and the explicit replacement confirmation'
fi

echo '==> Install signed Ubuntu runtime prerequisites without starting services'
apt-get update -qq
# These packages do not provide a long-running server unit. Avoid touching the
# host-global policy-rc.d hook: a power loss must not leave package service
# starts disabled for the whole machine.
apt-get install -y -qq --no-install-recommends \
  python3-venv openssh-client ca-certificates >/dev/null

echo '==> Create the privilege-separated updater identity and state boundary'
getent group uten-imp-updater >/dev/null || groupadd --system uten-imp-updater
if ! id -u uten-imp-updater >/dev/null 2>&1; then
  useradd --system --gid uten-imp-updater --home-dir /nonexistent --shell /usr/sbin/nologin uten-imp-updater
fi
[[ "$(id -gn uten-imp-updater)" == uten-imp-updater ]] || die 'updater primary group is incorrect'
updater_uid="$(id -u uten-imp-updater)"
mapfile -t updater_uid_names < <(getent passwd | awk -F: -v uid="$updater_uid" '$3 == uid {print $1}')
[[ "${#updater_uid_names[@]}" == 1 && "${updater_uid_names[0]}" == uten-imp-updater ]] \
  || die 'updater numeric UID must map to exactly one passwd name'
[[ "$(getent passwd uten-imp-updater | cut -d: -f7)" =~ ^(/usr/sbin/nologin|/sbin/nologin|/bin/false)$ ]] \
  || die 'updater account must use a nologin shell'
read -r -a updater_groups <<<"$(id -Gn uten-imp-updater)"
[[ "${#updater_groups[@]}" == 1 && "${updater_groups[0]}" == uten-imp-updater ]] \
  || die 'updater account must not have supplementary groups'
updater_gid="$(getent group uten-imp-updater | cut -d: -f3)"
mapfile -t updater_gid_names < <(getent group | awk -F: -v gid="$updater_gid" '$3 == gid {print $1}')
[[ "${#updater_gid_names[@]}" == 1 && "${updater_gid_names[0]}" == uten-imp-updater ]] \
  || die 'updater numeric GID must map to exactly one group name'
explicit_group_members="$(getent group uten-imp-updater | cut -d: -f4)"
[[ -z "$explicit_group_members" || "$explicit_group_members" == uten-imp-updater ]] \
  || die 'uten-imp-updater group contains another explicit member'
mapfile -t primary_group_users < <(getent passwd | awk -F: -v gid="$updater_gid" '$4 == gid {print $1}')
[[ "${#primary_group_users[@]}" == 1 && "${primary_group_users[0]}" == uten-imp-updater ]] \
  || die 'uten-imp-updater must be the only account with the updater primary group'
if id -u uten-imp >/dev/null 2>&1 && id -Gn uten-imp | tr ' ' '\n' | grep -Fxq uten-imp-updater; then
  die 'application account must not belong to the updater group'
fi
if [[ -f "$ALLOWED_SIGNERS" ]]; then
  [[ "$(stat -c '%U:%G:%a:%h' -- "$ALLOWED_SIGNERS")" == root:uten-imp-updater:640:1 ]] \
    || die 'existing updater allowed_signers must be root:uten-imp-updater mode 0640 with one hard link'
fi

install -d -m 0755 -o root -g root /opt/uten-imp /opt/uten-imp/releases
install -d -m 0750 -o uten-imp-updater -g uten-imp-updater /var/lib/uten-imp-updater
install -d -m 0750 -o root -g uten-imp-updater "$ROOT_STATE"
for recovery_directory in "$ROOT_STATE/recovery-evidence" "$ROOT_STATE/database-receipts" \
  "$ROOT_STATE/migration-evidence"; do
  if [[ -e "$recovery_directory" || -L "$recovery_directory" ]]; then
    [[ -d "$recovery_directory" && ! -L "$recovery_directory" ]] \
      || die "recovery state path is not a real directory: $recovery_directory"
    require_root_directory_chain "$recovery_directory"
  fi
  install -d -m 0700 -o root -g root "$recovery_directory"
done
if [[ ! -e "$OPERATION_LOCK" ]]; then
  install -m 0660 -o root -g uten-imp-updater /dev/null "$OPERATION_LOCK"
fi
[[ -f "$OPERATION_LOCK" && ! -L "$OPERATION_LOCK" ]] || die 'operation lock is not a regular file'
[[ "$(stat -c '%U:%G:%a:%h' "$OPERATION_LOCK")" == root:uten-imp-updater:660:1 ]] \
  || die 'operation lock must be root:uten-imp-updater 0660 with one hard link'
install -d -m 0750 -o root -g uten-imp-updater "$UPDATER_ETC"

if [[ "$install_allowed_signer" == true ]]; then
  allowed_signers_tmp="$(mktemp "$UPDATER_ETC/.release-allowed-signers.XXXXXX")"
  printf 'uten-imp-release %s %s\n' "$release_key_type" "$release_key_blob" >"$allowed_signers_tmp"
  chown root:uten-imp-updater "$allowed_signers_tmp"
  chmod 0640 "$allowed_signers_tmp"
  mv -fT -- "$allowed_signers_tmp" "$ALLOWED_SIGNERS"
fi

pending_example_tmp="$(mktemp "$UPDATER_ETC/.oss-pull.env.pending.XXXXXX")"
install -m 0600 -o root -g root \
  "$UPDATER_SOURCE/oss-pull.env.example" "$pending_example_tmp"
mv -fT -- "$pending_example_tmp" "$UPDATER_ETC/oss-pull.env.pending.example"
if [[ -n "$oss_env_source" ]]; then
  updater_env_tmp="$(mktemp "$UPDATER_ETC/.oss-pull.env.XXXXXX")"
  install -m 0640 -o root -g uten-imp-updater "$oss_env_source" "$updater_env_tmp"
  mv -fT -- "$updater_env_tmp" "$UPDATER_ENV"
fi

echo '==> Build the updater venv from the offline, hash-locked wheelhouse'
new_updater=''
rendered_nginx=''
expanded_nginx=''
cleanup_phase4_temporaries() {
  local status="$?" quarantine
  trap - EXIT
  for temporary_file in "${rendered_nginx:-}" "${expanded_nginx:-}"; do
    if [[ -n "$temporary_file" && "$temporary_file" == /tmp/uten-imp-nginx.* && -f "$temporary_file" && ! -L "$temporary_file" ]]; then
      rm -f -- "$temporary_file" || true
    fi
  done
  if [[ -n "${new_updater:-}" && "$new_updater" == /opt/uten-imp/.updater-install.* && -d "$new_updater" && ! -L "$new_updater" ]]; then
    if pgrep -u uten-imp-updater >/dev/null 2>&1; then
      printf 'ERROR: untrusted build process/path retained for manual incident handling: %s\n' "$new_updater" >&2
    else
      chown -R root:root "$new_updater" 2>/dev/null || true
      chmod -R go-w "$new_updater" 2>/dev/null || true
      quarantine="/opt/uten-imp/.updater-rejected.$(date -u +%Y%m%dT%H%M%SZ).$$"
      mv -T -- "$new_updater" "$quarantine" 2>/dev/null || true
      printf 'ERROR: failed updater build quarantined at %s\n' "$quarantine" >&2
    fi
  fi
  exit "$status"
}
trap cleanup_phase4_temporaries EXIT
new_updater="$(mktemp -d /opt/uten-imp/.updater-install.XXXXXX)"
chown uten-imp-updater:uten-imp-updater "$new_updater"
chmod 0750 "$new_updater"
if pgrep -u uten-imp-updater >/dev/null 2>&1; then
  die 'unexpected updater-account process exists before the isolated venv build'
fi
runuser -u uten-imp-updater -- test -r "$requirements_lock" \
  || die 'requirements lock is not readable by the unprivileged builder'
runuser -u uten-imp-updater -- test -x "$wheelhouse" \
  || die 'wheelhouse is not traversable by the unprivileged builder'
runuser -u uten-imp-updater -- /usr/bin/python3 -m venv "$new_updater/venv"
runuser -u uten-imp-updater -- env PIP_CONFIG_FILE=/dev/null PIP_NO_INPUT=1 PIP_NO_CACHE_DIR=1 \
  "$new_updater/venv/bin/python" -m pip install \
  --disable-pip-version-check --no-index --no-deps --no-compile \
  --only-binary=:all: --require-hashes \
  --find-links "$wheelhouse" --requirement "$requirements_lock"
runuser -u uten-imp-updater -- env PIP_CONFIG_FILE=/dev/null PIP_NO_INPUT=1 PIP_NO_CACHE_DIR=1 \
  "$new_updater/venv/bin/python" -m pip check
runuser -u uten-imp-updater -- env PIP_CONFIG_FILE=/dev/null PIP_NO_INPUT=1 PIP_NO_CACHE_DIR=1 \
  "$new_updater/venv/bin/python" -m pip uninstall --yes pip
if pgrep -u uten-imp-updater >/dev/null 2>&1; then
  die 'updater-account process survived the offline venv build; refusing to trust the tree'
fi
# Do not start the populated venv as root: a dependency could add executable
# .pth content. Inspect its installed metadata with isolated system Python.
/usr/bin/python3 -I - "$new_updater/venv" <<'PY'
import email.parser
import os
import pathlib
import re
import stat
import sys

venv = pathlib.Path(sys.argv[1])
for path in venv.rglob("*"):
    details = path.lstat()
    relative = path.relative_to(venv).as_posix()
    if stat.S_ISLNK(details.st_mode):
        if relative == "lib64" and os.readlink(path) == "lib":
            continue
        if re.fullmatch(r"bin/python(?:3(?:\.[0-9]+)?)?", relative):
            resolved = path.resolve(strict=True)
            if re.fullmatch(r"/usr/bin/python3(?:\.[0-9]+)?", str(resolved)):
                continue
        raise SystemExit(f"unexpected updater-venv symlink: {relative}")
    if not (stat.S_ISREG(details.st_mode) or stat.S_ISDIR(details.st_mode)):
        raise SystemExit(f"unexpected updater-venv file type: {relative}")
    if stat.S_ISREG(details.st_mode) and details.st_nlink != 1:
        raise SystemExit(f"updater-venv regular file has multiple hard links: {relative}")
site_roots = list(venv.glob("lib/python*/site-packages"))
if len(site_roots) != 1:
    raise SystemExit("unexpected venv site-packages layout")
site_root = site_roots[0]
if any(site_root.rglob("*.pth")):
    raise SystemExit("updater venv must not contain executable .pth files")
metadata_files = list(site_root.glob("oss2-*.dist-info/METADATA"))
if len(metadata_files) != 1:
    raise SystemExit("oss2 distribution metadata is missing or ambiguous")
with metadata_files[0].open("r", encoding="utf-8") as handle:
    metadata = email.parser.Parser().parse(handle)
if metadata.get("Name", "").lower() != "oss2" or metadata.get("Version") != "2.19.1":
    raise SystemExit("installed oss2 version differs from the reviewed lock")
PY
/usr/bin/python3 -I "$UPDATER_SOURCE/wheelhouse_supply_chain.py" verify \
  --lock "$requirements_lock" --wheelhouse "$wheelhouse" \
  --sums "$wheelhouse_sha256s" --sbom "$wheelhouse_sbom" \
  --attestation "$wheelhouse_attestation" --venv "$new_updater/venv"
chown -R root:root "$new_updater"
chmod -R go-w "$new_updater"
chmod 0755 "$new_updater"

install -m 0644 -o root -g root "$UPDATER_SOURCE/oss_io.py" "$new_updater/oss_io.py"
install -m 0644 -o root -g root "$UPDATER_SOURCE/release_guard.py" "$new_updater/release_guard.py"
install -m 0644 -o root -g root "$UPDATER_SOURCE/release_updater.py" "$new_updater/release_updater.py"
install -m 0644 -o root -g root "$UPDATER_SOURCE/retention_manager.py" "$new_updater/retention_manager.py"
install -m 0644 -o root -g root "$UPDATER_SOURCE/wheelhouse_supply_chain.py" "$new_updater/wheelhouse_supply_chain.py"
install -m 0644 -o root -g root "$UPDATER_SOURCE/validate_oss_pull_env.py" "$new_updater/validate_oss_pull_env.py"
install -m 0755 -o root -g root "$UPDATER_SOURCE/uten-imp-updater.sh" "$new_updater/uten-imp-updater.sh"
if find "$new_updater" -xdev -perm /022 -print -quit | grep -q .; then
  die 'new updater tree contains a group/world-writable path'
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -e "$UPDATER_DIR" ]]; then
  updater_backup="/opt/uten-imp/updater.pre-phase4.$timestamp"
  [[ ! -e "$updater_backup" ]] || die "updater backup path already exists: $updater_backup"
  mv -T -- "$UPDATER_DIR" "$updater_backup"
  printf 'Previous updater retained at %s\n' "$updater_backup"
fi
mv -T -- "$new_updater" "$UPDATER_DIR"
new_updater=''
install -m 0755 -o root -g root "$UPDATER_SOURCE/uten-imp-activate.sh" /usr/local/sbin/uten-imp-activate
install -m 0755 -o root -g root "$UPDATER_SOURCE/uten-imp-recover.sh" /usr/local/sbin/uten-imp-recover
install -m 0644 -o root -g root "$UPDATER_SOURCE/uten-imp-updater.service" /etc/systemd/system/uten-imp-updater.service
install -m 0644 -o root -g root "$UPDATER_SOURCE/uten-imp-updater.timer" /etc/systemd/system/uten-imp-updater.timer
install -d -m 0755 -o root -g root /usr/local/share/doc/uten-imp
install -m 0644 -o root -g root "$OPERATOR_GUIDE" /usr/local/share/doc/uten-imp/operator-guide.zh-CN.md

echo '==> Render and validate the exact TLS Nginx site'
rendered_nginx="$(mktemp /tmp/uten-imp-nginx.XXXXXX)"
sed \
  -e "s|__LOCAL_DOMAIN__|$domain|g" \
  -e "s|__OFFICE_CIDR__|$office_cidr|g" \
  -e "s|__VPN_CIDR__|$vpn_cidr|g" \
  -e "s|__TLS_CERT_PATH__|$tls_cert|g" \
  -e "s|__TLS_KEY_PATH__|$tls_key|g" \
  -e "s|__OSS_PUBLIC_HOST__|$oss_public_host|g" \
  "$NGINX_TEMPLATE" >"$rendered_nginx"
if grep -Eq '__[A-Z0-9_]+__' "$rendered_nginx"; then
  die 'rendered Nginx configuration still contains a placeholder'
fi
nginx_backup=''
if [[ -e "$NGINX_TARGET" ]]; then
  nginx_backup="/etc/nginx/conf.d/uten-imp.conf.pre-phase4.$timestamp"
  cp --archive -- "$NGINX_TARGET" "$nginx_backup"
fi
install -m 0644 -o root -g root "$rendered_nginx" "$NGINX_TARGET"
rm -f -- "$rendered_nginx"
rendered_nginx=''
if ! nginx -t; then
  if [[ -n "$nginx_backup" ]]; then
    mv -fT -- "$nginx_backup" "$NGINX_TARGET"
  else
    mv -T -- "$NGINX_TARGET" "/etc/nginx/conf.d/uten-imp.conf.rejected.$timestamp"
  fi
  die 'Nginx validation failed; the prior config was restored or the rejected config was quarantined'
fi
restore_nginx_and_die() {
  local reason="$1"
  if [[ -n "$nginx_backup" && -f "$nginx_backup" && ! -L "$nginx_backup" ]]; then
    mv -fT -- "$nginx_backup" "$NGINX_TARGET"
  elif [[ -f "$NGINX_TARGET" && ! -L "$NGINX_TARGET" ]]; then
    mv -T -- "$NGINX_TARGET" "/etc/nginx/conf.d/uten-imp.conf.rejected.$timestamp"
  fi
  nginx -t >/dev/null 2>&1 || true
  die "$reason; the prior config was restored or the rejected config was quarantined"
}
expanded_nginx="$(mktemp /tmp/uten-imp-nginx-expanded.XXXXXX)"
if ! nginx -T >"$expanded_nginx" 2>&1; then
  rm -f -- "$expanded_nginx"
  expanded_nginx=''
  restore_nginx_and_die 'Nginx expanded-configuration audit failed'
fi
if ! /usr/bin/python3 -I - "$expanded_nginx" <<'PY'
import collections
import sys
from pathlib import Path

expected = collections.Counter(
    {
        "listen 127.0.0.1:8081;": 1,
        "listen 80 default_server;": 1,
        "listen 443 ssl default_server;": 1,
        "listen 80;": 1,
        "listen 443 ssl http2;": 1,
    }
)
actual = collections.Counter()
tls_protocol_directives = 0
for raw in Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict").splitlines():
    line = raw.strip()
    if line.startswith("ssl_protocols "):
        protocols = line.removeprefix("ssl_protocols ").removesuffix(";").split()
        if protocols != ["TLSv1.2", "TLSv1.3"]:
            raise SystemExit(f"unapproved TLS protocol policy: {line}")
        tls_protocol_directives += 1
    if not line.startswith("listen "):
        continue
    endpoint = line.split()[1].rstrip(";")
    port = endpoint.rsplit(":", 1)[-1] if ":" in endpoint else endpoint
    if port in {"80", "443", "8081"}:
        actual[line] += 1
if actual != expected:
    raise SystemExit(f"unexpected external/ERP Nginx listeners: {dict(actual)}")
if tls_protocol_directives < 2:
    raise SystemExit("ERP TLS server blocks do not both declare TLSv1.2/TLSv1.3")
PY
then
  restore_nginx_and_die 'expanded Nginx config contains an unapproved listener'
fi
[[ "$(grep -Fc 'upstream uten_imp_backend {' "$expanded_nginx")" == 1 ]] \
  || restore_nginx_and_die 'expanded Nginx config does not contain exactly one Uten backend upstream'
[[ "$(grep -Fc 'listen 127.0.0.1:8081;' "$expanded_nginx")" == 1 ]] \
  || restore_nginx_and_die 'expanded Nginx config does not contain exactly one loopback entry probe'
[[ "$(grep -Fc 'root /opt/uten-imp/current/web;' "$expanded_nginx")" == 2 ]] \
  || restore_nginx_and_die 'expanded Nginx config contains an unexpected number of Uten Web roots'
[[ "$(grep -Fc "server_name $domain;" "$expanded_nginx")" == 2 ]] \
  || restore_nginx_and_die 'expanded Nginx config does not contain the exact HTTP redirect and TLS hosts'
[[ "$(grep -Fc 'listen 80 default_server;' "$expanded_nginx")" == 1 ]] \
  || restore_nginx_and_die 'expanded Nginx config lacks the unique unknown-Host HTTP reject boundary'
[[ "$(grep -Fc 'listen 443 ssl default_server;' "$expanded_nginx")" == 1 ]] \
  || restore_nginx_and_die 'expanded Nginx config lacks the unique unknown-SNI TLS reject boundary'
[[ "$(grep -Fc 'ssl_reject_handshake on;' "$expanded_nginx")" == 1 ]] \
  || restore_nginx_and_die 'expanded Nginx config lacks the unknown-SNI handshake rejection'
[[ "$(grep -Fc "ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';" "$expanded_nginx")" == 1 ]] \
  || restore_nginx_and_die 'expanded Nginx config lacks the reviewed TLS 1.2 cipher policy'
[[ "$(grep -Fc 'ssl_session_tickets off;' "$expanded_nginx")" == 1 ]] \
  || restore_nginx_and_die 'expanded Nginx config must disable TLS session tickets on the ERP vhost'
rm -f -- "$expanded_nginx"
expanded_nginx=''

systemctl daemon-reload
for unit in uten-imp-updater.timer uten-imp-migrate.service uten-imp.service nginx.service \
  uten-imp-watchdog.timer uten-imp-entry-watchdog.timer; do
  systemctl is-enabled --quiet "$unit" 2>/dev/null \
    && die "installer unexpectedly left a boot unit enabled: $unit"
done

if [[ -f "$UPDATER_ENV" ]]; then
  runuser -u uten-imp-updater -- \
    /usr/bin/python3 -I "$UPDATER_DIR/validate_oss_pull_env.py" "$UPDATER_ENV"
fi

if [[ "$enable_staging" == true ]]; then
  [[ -f "$UPDATER_ENV" ]] || die 'staging cannot be enabled before a validated oss-pull.env exists'
  systemctl start uten-imp-updater.service
  runuser -u uten-imp-updater -- \
    "$UPDATER_DIR/venv/bin/python" -I "$UPDATER_DIR/release_updater.py" \
    --state-dir /var/lib/uten-imp-updater \
    --allowed-signers "$ALLOWED_SIGNERS" \
    --lock-file "$OPERATION_LOCK" \
    inspect "$expected_candidate_version" >/dev/null
  timer_enable_committed=false
  rollback_timer_enablement() {
    local status="$?"
    if [[ "$timer_enable_committed" != true ]]; then
      systemctl disable --now uten-imp-updater.timer >/dev/null 2>&1 || true
    fi
    return "$status"
  }
  trap rollback_timer_enablement EXIT
  if ! systemctl enable --now uten-imp-updater.timer; then
    systemctl disable --now uten-imp-updater.timer >/dev/null 2>&1 || true
    die 'failed to enable the staging timer; disabled state was restored'
  fi
  systemctl is-active --quiet uten-imp-updater.timer \
    || die 'staging timer did not remain active'
  timer_enable_committed=true
  trap - EXIT
  printf 'SIGNED_STAGING_ENABLED: %s\n' "$expected_candidate_version"
else
  printf '%s\n' \
    'PHASE4_INSTALL_ONLY_COMPLETE' \
    'STAGING_NOT_ENABLED: validate the GET-only OSS identity and stage an expected signed candidate first.'
fi

printf '%s\n' \
  "RELEASE_SIGNING_FINGERPRINT=$actual_fingerprint" \
  'APPLICATION_NOT_STARTED' \
  'NGINX_NOT_STARTED' \
  'WATCHDOGS_NOT_STARTED'
