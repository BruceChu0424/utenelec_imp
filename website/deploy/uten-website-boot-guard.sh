#!/usr/bin/env bash
# Root-owned boot/exit/reconciliation gate. It never stages or activates code.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly STATE=/var/lib/uten-website/runtime
readonly CONTROL=/var/lib/uten-website/control
readonly GATE=/etc/nginx/snippets/uten-website-gate.conf
readonly OPEN_GATE=/usr/local/libexec/uten-website/uten-website-gate.open.conf
readonly CLOSED_GATE=/usr/local/libexec/uten-website/uten-website-gate.closed.conf
readonly STORAGE_CHECK=/usr/local/libexec/uten-website/validate-storage
readonly RUNTIME_CHECK=/usr/local/libexec/uten-website/validate-runtime
readonly STATE_TOOL=/usr/local/libexec/uten-website/paired_state.py
readonly RELEASE_TOOL=/usr/local/libexec/uten-website/website_release.py
readonly LOCK_TOOL=/usr/local/libexec/uten-website/open_root_lock.py
readonly SIGNERS=/etc/uten-website/release-allowed-signers
readonly AUTHORITY_RECEIPT=/etc/uten-website/database-authority.json
readonly CURRENT=/opt/uten-website/current
readonly RUNTIME_CONTROL=/run/uten-website-release
readonly ACTIVATION_LOCK=$RUNTIME_CONTROL/activation.lock
readonly STATE_MUTATION_LOCK=$RUNTIME_CONTROL/state-mutation.lock
readonly GATE_LOCK=$RUNTIME_CONTROL/gate.lock
readonly FAILED=$CONTROL/activation-failed.json
readonly IN_PROGRESS=$CONTROL/activation-in-progress.json
readonly RESTORE_FAILED=$CONTROL/activation-restore-failed.json
readonly RECOVERY_PROGRESS=$CONTROL/interrupted-recovery-in-progress.json
readonly START_GRANT=$RUNTIME_CONTROL/activation-start.json
readonly START_GRANT_RECEIPTS=$CONTROL/activation-start-grants-consumed

die() {
  printf 'WEBSITE_BOOT_GUARD_REFUSED: %s\n' "$*" >&2
  # 78 is a persistent fail-closed prestart condition.  The service unit does
  # not restart on it; an operator recovery/watchdog explicitly starts later.
  [[ ${ACTION:-} == prestart ]] && exit 78
  exit 1
}
[[ ${EUID} -eq 0 ]] || die 'boot guard must run as root'
[[ $# -eq 1 ]] || die 'usage: uten-website-boot-guard prepare|prestart|ready|recover-ready|backup-ready|close|reconcile'
readonly ACTION=$1
[[ $ACTION =~ ^(prepare|prestart|ready|recover-ready|backup-ready|close|reconcile)$ ]] || die 'unknown action'
for command_name in cmp curl dirname env flock install mv nginx node python3 readlink runuser sed stat systemctl timedatectl; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

durable_file() {
  python3 -I - "$1" <<'PY'
import os,pathlib,sys
p=pathlib.Path(sys.argv[1]); fd=os.open(p,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
fd=os.open(p.parent,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
PY
}

for root_lock in "$GATE_LOCK" "$ACTIVATION_LOCK" "$STATE_MUTATION_LOCK"; do
  python3 -I "$LOCK_TOOL" "$root_lock" || die "root lock file is unsafe: $root_lock"
done
exec 8<>"$GATE_LOCK"
flock -w 20 8 || die 'gate lock remained busy for 20 seconds'

set_gate() {
  local source=$1 label=$2
  [[ -f $source && ! -L $source ]] || { printf 'WEBSITE_GATE_ERROR: reviewed %s gate template is missing\n' "$label" >&2; return 1; }
  install -m 0644 -o root -g root "$source" "$GATE.new" || return 1
  mv -Tf -- "$GATE.new" "$GATE" || return 1
  durable_file "$GATE" || return 1
  if ! nginx -t; then
    printf 'WEBSITE_GATE_ERROR: Nginx configuration test failed for %s gate\n' "$label" >&2
    return 1
  fi
  if systemctl is-active --quiet nginx.service; then
    if ! systemctl reload nginx.service; then
      printf 'WEBSITE_GATE_ERROR: Nginx could not load %s gate\n' "$label" >&2
      return 1
    fi
  fi
  return 0
}

close_gate() {
  if ! set_gate "$CLOSED_GATE" closed; then
    systemctl stop nginx.service >/dev/null 2>&1 || true
    printf '%s\n' 'WEBSITE_ENTRY_CONTAINED: Nginx stopped because the closed gate could not be proved' >&2
    return 1
  fi
  printf '%s\n' 'WEBSITE_ENTRY_CLOSED'
}

maintenance_lock_held() {
  local lock=$1 fd=$2
  eval "exec ${fd}>\"$lock\""
  if flock -n "$fd"; then
    flock -u "$fd"
    return 1
  fi
  return 0
}

autostart_intent_enabled() {
  local unit
  for unit in nginx.service uten-website-boot-gate.service uten-website.service uten-website-entry-watchdog.timer; do
    systemctl is-enabled --quiet "$unit" || return 1
  done
  return 0
}

start_website_unlocked() {
  # systemctl waits for ExecStartPre/ExecStartPost.  Those guards need this
  # same lock, so never call systemctl start while fd 8 still owns it.
  close_gate || return 1
  flock -u 8 || return 1
  exec 8>&-
  systemctl start uten-website.service
}

blocked_by_evidence() {
  [[ -e $FAILED || -L $FAILED || -e $IN_PROGRESS || -L $IN_PROGRESS || -e $RESTORE_FAILED || -L $RESTORE_FAILED || -e $RECOVERY_PROGRESS || -L $RECOVERY_PROGRESS ]]
}

strict_ready_action() {
  [[ $ACTION == recover-ready || $ACTION == backup-ready ]]
}

validate_trust_boundary() {
  [[ -d $RUNTIME_CONTROL && ! -L $RUNTIME_CONTROL && $(stat -c '%U:%G:%a' -- "$RUNTIME_CONTROL") == root:root:700 ]] || return 1
  [[ $(stat -c '%U:%G:%a' -- /usr/local/libexec/uten-website) == root:root:755 ]] || return 1
  local executable
  for executable in \
    "$STORAGE_CHECK" "$RUNTIME_CHECK" "$STATE_TOOL" "$RELEASE_TOOL" "$LOCK_TOOL" \
    /usr/local/libexec/uten-website/uten-website-boot-guard; do
    [[ -f $executable && ! -L $executable && $(stat -c '%U:%G:%a:%h' -- "$executable") == root:root:755:1 ]] \
      || return 1
  done
  local data
  for data in "$OPEN_GATE" "$CLOSED_GATE" "$SIGNERS" "$AUTHORITY_RECEIPT"; do
    [[ -f $data && ! -L $data && $(stat -c '%U:%G:%a:%h' -- "$data") == root:root:644:1 ]] \
      || return 1
  done
  [[ -f $GATE && ! -L $GATE && $(stat -c '%U:%G:%a:%h' -- "$GATE") == root:root:644:1 ]] \
    || return 1
  return 0
}

validate_failed_restore() {
  local values previous snapshot
  values="$(python3 -I - "$FAILED" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); value=json.loads(raw)
expected={'failureReason','format','planSha256','previousRelease','snapshot','status','version'}
if raw != (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode(): raise SystemExit('failure marker is not canonical')
if set(value)!=expected or value.get('format')!='uten-website-activation-failed-v1': raise SystemExit('failure marker contract differs')
print(value['previousRelease']); print(value['snapshot'])
PY
)" || die 'activation-failed marker validation failed'
  previous="$(printf '%s\n' "$values" | sed -n '1p')"
  snapshot="$(printf '%s\n' "$values" | sed -n '2p')"
  [[ -n $previous && $previous == /opt/uten-website/releases/* && $(dirname -- "$previous") == /opt/uten-website/releases && -d $previous && ! -L $previous ]] \
    || die 'failed activation has no usable previous immutable release'
  [[ -L $CURRENT && $(readlink -f -- "$CURRENT") == "$previous" ]] \
    || die 'current does not identify the proved previous release'
  python3 -I "$STATE_TOOL" verify-restored-live --snapshot "$snapshot" \
    --database "$STATE/website.db" --uploads "$STATE/uploads"
}

validate_release_database() {
  local -a media_mode=()
  case ${1:-strict} in
    strict) ;;
    metadata) media_mode=(--metadata-only) ;;
    allow-inflight) media_mode=(--metadata-only --allow-inflight) ;;
    *) return 1 ;;
  esac
  "$RUNTIME_CHECK" --boot || return 1
  python3 -I "$RELEASE_TOOL" verify-installed --release "$CURRENT" --allowed-signers "$SIGNERS" \
    || return 1
  runuser -u uten-website -- /usr/bin/python3 -I "$STATE_TOOL" verify-live \
    --database "$STATE/website.db" --uploads "$STATE/uploads" \
    --authority-receipt "$AUTHORITY_RECEIPT" \
    --signed-manifest "$CURRENT/.release-evidence/manifest.json" "${media_mode[@]}" \
    || return 1
  runuser -u uten-website -- /usr/bin/env DATABASE_URL=file:/var/lib/uten-website/runtime/website.db \
    /usr/bin/node "$CURRENT/prisma-runtime/node_modules/prisma/build/index.js" migrate status \
      --schema "$CURRENT/prisma-runtime/prisma/schema.prisma" \
    || return 1
  return 0
}

consume_activation_start_grant() {
  local activation_id runtime_consumed receipt receipt_temporary
  activation_id="$(python3 -I - "$START_GRANT" "$IN_PROGRESS" "$CURRENT" "$STATE/website.db" <<'PY'
import hashlib,json,os,pathlib,re,stat,sys

def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()

def checked_json(path, expected_mode):
    info=path.lstat()
    if path.is_symlink() or not path.is_file() or info.st_uid!=0 or info.st_gid!=0 or stat.S_IMODE(info.st_mode)!=expected_mode or info.st_nlink!=1:
        raise SystemExit(f'unsafe root evidence: {path}')
    raw=path.read_bytes(); value=json.loads(raw)
    if raw!=canonical(value): raise SystemExit(f'non-canonical root evidence: {path}')
    return raw,value

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda:source.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()

grant_path=pathlib.Path(sys.argv[1]); marker_path=pathlib.Path(sys.argv[2])
current=pathlib.Path(sys.argv[3]); database=pathlib.Path(sys.argv[4])
grant_raw,grant=checked_json(grant_path,0o600)
marker_raw,marker=checked_json(marker_path,0o600)
marker_keys={'activationId','format','planSha256','previousRelease','snapshot','version'}
if set(marker)!=marker_keys or marker.get('format')!='uten-website-activation-in-progress-v1': raise SystemExit('activation marker contract differs')
activation_id=str(marker['activationId'])
if not re.fullmatch(r'\d{8}T\d{6}Z-[0-9a-f]{12}',activation_id): raise SystemExit('activation id is invalid')
snapshot=pathlib.Path(str(marker['snapshot']))
if snapshot.parent!=pathlib.Path('/var/backups/uten-website/local') or snapshot.name!=activation_id: raise SystemExit('activation snapshot path differs')
manifest=snapshot/'manifest.json'
target=current.resolve(strict=True)
release_manifest=target/'.release-evidence/manifest.json'
expected={
 'activationId':activation_id,
 'bootId':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text(encoding='ascii').strip(),
 'currentTarget':str(target),
 'databaseSha256':digest(database),
 'format':'uten-website-activation-start-grant-v1',
 'inProgressSha256':hashlib.sha256(marker_raw).hexdigest(),
 'manifestSha256':digest(release_manifest),
 'planSha256':marker['planSha256'],
 'snapshotManifestSha256':digest(manifest),
 'version':marker['version'],
}
if grant!=expected: raise SystemExit('one-time activation start grant differs from current transaction')
print(activation_id)
PY
)" || die 'one-time activation start grant validation failed'
  runtime_consumed="$START_GRANT.consumed-$activation_id-$$"
  receipt="$START_GRANT_RECEIPTS/$activation_id.json"
  [[ ! -e $runtime_consumed && ! -L $runtime_consumed && ! -e $receipt && ! -L $receipt ]] \
    || die 'activation start grant was already consumed'
  # Same-filesystem rename in /run is the atomic one-time consumption point.
  mv -Tf -- "$START_GRANT" "$runtime_consumed"
  install -d -m 0700 -o root -g root "$START_GRANT_RECEIPTS"
  receipt_temporary="$receipt.tmp-$$"
  [[ ! -e $receipt_temporary && ! -L $receipt_temporary ]] || die 'activation grant receipt temporary already exists'
  install -m 0600 -o root -g root "$runtime_consumed" "$receipt_temporary"
  durable_file "$receipt_temporary"
  mv -Tf -- "$receipt_temporary" "$receipt"
  durable_file "$receipt"
  rm -f -- "$runtime_consumed"
}

failed_has_previous_release() {
  python3 -I - "$FAILED" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); value=json.loads(raw)
if raw != (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode(): raise SystemExit(2)
raise SystemExit(0 if value.get('format')=='uten-website-activation-failed-v1' and value.get('previousRelease') else 1)
PY
}

ready_gate() {
  if ! validate_trust_boundary || ! "$STORAGE_CHECK"; then
    close_gate || true
    printf '%s\n' 'WEBSITE_ENTRY_REFUSED: storage/runtime prerequisite failed' >&2
    return 1
  fi
  if blocked_by_evidence; then
    close_gate || return 1
    printf '%s\n' 'WEBSITE_ENTRY_HELD_CLOSED: activation evidence requires operator recovery'
    ! strict_ready_action || return 1
    return 0
  fi
  if maintenance_lock_held "$STATE_MUTATION_LOCK" 7 || \
     { [[ $ACTION != recover-ready ]] && maintenance_lock_held "$ACTIVATION_LOCK" 6; }; then
    close_gate || return 1
    printf '%s\n' 'WEBSITE_ENTRY_HELD_CLOSED: approved maintenance owns the state lock'
    ! strict_ready_action || return 1
    return 0
  fi
  if [[ $(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true) != yes ]]; then
    close_gate || return 1
    printf '%s\n' 'WEBSITE_ENTRY_HELD_CLOSED: system clock is not NTP-synchronized'
    ! strict_ready_action || return 1
    return 0
  fi
  if ! autostart_intent_enabled; then
    close_gate || return 1
    printf '%s\n' 'WEBSITE_ENTRY_HELD_CLOSED: core autostart has not been commissioned or was intentionally disabled'
    ! strict_ready_action || return 1
    return 0
  fi
  media_mode=metadata
  if [[ $ACTION == reconcile ]] && systemctl is-active --quiet uten-website.service; then
    media_mode=allow-inflight
  fi
  if ! validate_release_database "$media_mode"; then
    close_gate || true
    printf '%s\n' 'WEBSITE_ENTRY_REFUSED: signed release, live state or Prisma status drifted' >&2
    return 1
  fi
  for _ in {1..30}; do
    if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health \
        | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)=={"status":"ok"} else 1)'; then
      if ! set_gate "$OPEN_GATE" open; then
        close_gate || true
        return 1
      fi
      printf '%s\n' 'WEBSITE_ENTRY_OPEN: local readiness, state, storage and time gates passed'
      return 0
    fi
    sleep 1
  done
  close_gate || true
  printf '%s\n' 'WEBSITE_ENTRY_REFUSED: website did not become locally ready within 30 seconds' >&2
  return 1
}

case "$ACTION" in
  close)
    close_gate || exit 1
    ;;
  prepare)
    if ! validate_trust_boundary; then
      systemctl stop nginx.service >/dev/null 2>&1 || true
      die 'root helper, signing trust or gate ownership/mode drifted'
    fi
    close_gate || exit 1
    "$STORAGE_CHECK"
    ;;
  prestart)
    if ! validate_trust_boundary; then
      systemctl stop nginx.service >/dev/null 2>&1 || true
      die 'root helper, signing trust or gate ownership/mode drifted'
    fi
    close_gate || exit 1
    "$STORAGE_CHECK"
    ! maintenance_lock_held "$STATE_MUTATION_LOCK" 7 \
      || die 'state mutation/snapshot owns live state; Node startup is forbidden until it releases the lock'
    activation_start_authorized=false
    if [[ -e $IN_PROGRESS || -L $IN_PROGRESS ]]; then
      [[ -f $IN_PROGRESS && ! -L $IN_PROGRESS ]] || die 'activation-in-progress evidence has an unsafe shape'
      maintenance_lock_held "$ACTIVATION_LOCK" 6 \
        || die 'interrupted activation must be restored before Node starts'
      [[ ! -e $FAILED && ! -L $FAILED ]] || die 'activation evidence is contradictory'
      activation_start_authorized=true
    fi
    [[ ! -e $RESTORE_FAILED && ! -L $RESTORE_FAILED ]] || die 'unproved activation restore forbids Node startup'
    [[ ! -e $RECOVERY_PROGRESS && ! -L $RECOVERY_PROGRESS ]] || die 'interrupted recovery phase evidence forbids Node startup'
    if [[ -e $FAILED || -L $FAILED ]]; then
      validate_failed_restore
    fi
    validate_release_database || die 'signed release or exact live Prisma state failed before Node startup'
    if $activation_start_authorized; then
      consume_activation_start_grant
    else
      [[ ! -e $START_GRANT && ! -L $START_GRANT ]] || die 'orphan activation start grant forbids Node startup'
    fi
    ;;
  ready)
    ready_gate
    ;;
  recover-ready)
    ready_gate
    ;;
  backup-ready)
    ready_gate
    ;;
  reconcile)
    if ! validate_trust_boundary || ! "$STORAGE_CHECK"; then
      close_gate || true
      systemctl stop uten-website.service >/dev/null 2>&1 || true
      die 'persistent storage is unsafe; service stopped and ingress closed'
    fi
    if ! autostart_intent_enabled; then
      close_gate || true
      printf '%s\n' 'WEBSITE_ENTRY_HELD_CLOSED: automatic recovery disabled by operator/commissioning state'
      exit 0
    fi
    # Activation/recovery owns the gate transition while holding this lock.
    # Do not race its final recover-ready/open+cmp window by closing or reopening
    # the gate from the watchdog; the transaction will leave durable evidence on
    # failure and the next interval will reconcile after the lock is released.
    if maintenance_lock_held "$ACTIVATION_LOCK" 6; then
      printf '%s\n' 'WEBSITE_ENTRY_UNCHANGED: approved activation/recovery owns the gate transition'
      exit 0
    fi
    if [[ -e $IN_PROGRESS || -L $IN_PROGRESS ]]; then
      close_gate || true
      systemctl stop uten-website.service >/dev/null 2>&1 || true
      die 'orphan interrupted activation evidence requires a reviewed restore; service stopped'
    fi
    if [[ -e $RESTORE_FAILED || -L $RESTORE_FAILED || -e $RECOVERY_PROGRESS || -L $RECOVERY_PROGRESS ]]; then
      close_gate || true
      systemctl stop uten-website.service >/dev/null 2>&1 || true
      die 'activation recovery evidence requires a reviewed restore; service stopped'
    fi
    if [[ -e $FAILED || -L $FAILED ]]; then
      close_gate || true
      if failed_has_previous_release && ! systemctl is-active --quiet uten-website.service; then
        start_website_unlocked
      fi
      printf '%s\n' 'WEBSITE_ENTRY_HELD_CLOSED: restored service available only for recovery assessment'
      exit 0
    fi
    if ! systemctl is-active --quiet uten-website.service; then
      start_website_unlocked
    else
      if ! ready_gate; then
        close_gate || true
        systemctl stop uten-website.service >/dev/null 2>&1 || true
        die 'active website drifted; service stopped and ingress contained'
      fi
    fi
    ;;
esac
