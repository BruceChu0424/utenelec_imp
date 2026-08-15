#!/usr/bin/env bash
# Root-only, two-step atomic website activation. Automatic invocation is forbidden.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly BASE=/opt/uten-website
readonly RELEASES=$BASE/releases
readonly CURRENT=$BASE/current
readonly STATE=/var/lib/uten-website/runtime
readonly CONTROL=/var/lib/uten-website/control
readonly STAGED=/var/lib/uten-website/updater/staged
readonly PLANS=$CONTROL/activation-plans
readonly RECEIPTS=$CONTROL/activation-receipts
readonly BACKUPS=/var/backups/uten-website/local
readonly OFFSITE_RECEIPTS=/var/backups/uten-website/receipts
readonly DB=$STATE/website.db
readonly UPLOADS=$STATE/uploads
readonly MARKER=$CONTROL/activation-failed.json
readonly IN_PROGRESS=$CONTROL/activation-in-progress.json
readonly RESTORE_FAILED=$CONTROL/activation-restore-failed.json
readonly RECOVERY_PROGRESS=$CONTROL/interrupted-recovery-in-progress.json
readonly GATE=/etc/nginx/snippets/uten-website-gate.conf
readonly OPEN_GATE=/usr/local/libexec/uten-website/uten-website-gate.open.conf
readonly CLOSED_GATE=/usr/local/libexec/uten-website/uten-website-gate.closed.conf
readonly RELEASE_TOOL=/usr/local/libexec/uten-website/website_release.py
readonly STATE_TOOL=/usr/local/libexec/uten-website/paired_state.py
readonly BOOT_GUARD=/usr/local/libexec/uten-website/uten-website-boot-guard
readonly STORAGE_CHECK=/usr/local/libexec/uten-website/validate-storage
readonly SIGNERS=/etc/uten-website/release-allowed-signers
readonly AUTHORITY_RECEIPT=/etc/uten-website/database-authority.json
readonly LOCK=/run/uten-website-release/activation.lock
readonly STATE_LOCK=/run/uten-website-release/state-mutation.lock
readonly ATTEMPT_FAILURES=$CONTROL/activation-attempt-failures
readonly START_GRANT=/run/uten-website-release/activation-start.json
readonly START_GRANT_RECEIPTS=$CONTROL/activation-start-grants-consumed
readonly START_GRANT_ABORTED=$CONTROL/activation-start-grants-aborted
readonly LOCK_TOOL=/usr/local/libexec/uten-website/open_root_lock.py

die() { printf 'WEBSITE_ACTIVATION_REFUSED: %s\n' "$*" >&2; exit 1; }
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
durable_directory() {
  python3 -I - "$1" <<'PY'
import os,sys
fd=os.open(sys.argv[1],os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
PY
}
publish_root_file() {
  local temporary=$1 destination=$2 mode=${3:-0600}
  [[ -f $temporary && ! -L $temporary ]] || die "atomic evidence temporary is unsafe: $temporary"
  chown root:root "$temporary"
  chmod "$mode" "$temporary"
  durable_file "$temporary"
  mv -Tf -- "$temporary" "$destination"
  durable_file "$destination"
}
state_lock_held=false
acquire_state_lock() {
  if ! $state_lock_held; then
    python3 -I "$LOCK_TOOL" "$STATE_LOCK" || die 'state-mutation lock file is unsafe'
    exec 8<>"$STATE_LOCK"
    flock -n 8 || die 'backup or recovery owns the state-mutation lock'
    state_lock_held=true
  fi
}
release_state_lock() {
  if $state_lock_held; then
    flock -u 8
    exec 8>&-
    state_lock_held=false
  fi
}
[[ ${EUID} -eq 0 ]] || die 'must run as root'
for command_name in curl env flock install ln mv nginx node python3 readlink runuser sha256sum stat systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
[[ $# -ge 2 ]] || die 'usage: uten-website-activate plan VERSION | apply VERSION --plan-sha SHA --confirmation ACTIVATE-WEBSITE-VERSION'
readonly ACTION=$1
readonly VERSION=$2
shift 2
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die 'version is not canonical SemVer'

PLAN_SHA=''
CONFIRMATION=''
while (($#)); do
  case "$1" in
    --plan-sha) [[ $# -ge 2 ]] || die '--plan-sha needs a value'; PLAN_SHA=$2; shift 2 ;;
    --confirmation) [[ $# -ge 2 ]] || die '--confirmation needs a value'; CONFIRMATION=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ $ACTION == apply ]]; then
  # Deliberate source-level production stop.  The signed release, schema and
  # authority/ledger verifier remain usable for read-only planning, but apply
  # must stay unreachable until an evidence-driven interrupted-media recovery
  # tool, semantic paired-backup format and legacy onboarding are complete.
  die 'production activation source NO-GO: media recovery, semantic paired backup and legacy onboarding are not yet closed'
fi

readonly PUBLICATION=$STAGED/$VERSION
readonly PLAN=$PLANS/$VERSION.json
python3 -I "$LOCK_TOOL" "$LOCK" || die 'activation lock file is unsafe'
exec 9<>"$LOCK"
flock -n 9 || die 'another activation holds the lock'
acquire_state_lock
if ! "$STORAGE_CHECK"; then
  "$BOOT_GUARD" close || systemctl stop nginx.service || true
  die 'authoritative state/backup storage identity failed after the mutation lock was acquired'
fi
[[ ! -e $MARKER && ! -L $MARKER ]] || die 'activation-failed evidence exists; use the recovery tool, never delete it'
[[ ! -e $IN_PROGRESS && ! -L $IN_PROGRESS ]] || die 'interrupted activation evidence exists; use the recovery tool, never delete it'
[[ ! -e $RESTORE_FAILED && ! -L $RESTORE_FAILED ]] || die 'unproved restore evidence exists; use the recovery tool, never delete it'
[[ ! -e $RECOVERY_PROGRESS && ! -L $RECOVERY_PROGRESS ]] || die 'recovery finalization evidence exists; use the recovery tool, never delete it'
[[ -d $PUBLICATION && ! -L $PUBLICATION ]] || die "staged publication is missing: $PUBLICATION"
[[ -x $RELEASE_TOOL && -x $STATE_TOOL ]] || die 'root-owned verifier/paired-state tools are missing'
[[ -f $SIGNERS && ! -L $SIGNERS ]] || die 'website release trust root is missing'
python3 -I "$RELEASE_TOOL" verify --publication "$PUBLICATION" --allowed-signers "$SIGNERS" --expected-version "$VERSION"

offsite_receipt="$(python3 -I - "$OFFSITE_RECEIPTS" "$BACKUPS" <<'PY'
import datetime,hashlib,json,pathlib,re,sys
receipts=pathlib.Path(sys.argv[1]); backups=pathlib.Path(sys.argv[2]); valid=[]
now=datetime.datetime.now(datetime.timezone.utc)
for path in receipts.glob('*.json') if receipts.is_dir() else []:
 try:
  if path.is_symlink() or not path.is_file() or path.stat().st_nlink!=1: continue
  raw=path.read_bytes(); value=json.loads(raw)
  if raw != (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode(): continue
  if set(value)!={'format','localManifestSha256','resticSnapshotId','snapshotId'} or value['format']!='uten-website-offsite-backup-receipt-v1': continue
  match=re.fullmatch(r'(\d{8}T\d{6}Z)-[0-9a-f]{12}',value['snapshotId'])
  if not match or path.name != value['snapshotId']+'.json' or not re.fullmatch(r'[0-9a-f]{64}',value['localManifestSha256']) or not re.fullmatch(r'[0-9a-f]{64}',value['resticSnapshotId']): continue
  created=datetime.datetime.strptime(match.group(1),'%Y%m%dT%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
  if created>now or (now-created).total_seconds()>129600: continue
  manifest=backups/value['snapshotId']/'manifest.json'
  if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_nlink!=1 or hashlib.sha256(manifest.read_bytes()).hexdigest()!=value['localManifestSha256']: continue
  valid.append((created,path))
 except (OSError,ValueError,KeyError,TypeError): pass
if not valid: raise SystemExit('no fresh byte-bound offsite website backup receipt')
print(max(valid)[1])
PY
)" || die 'a fresh verified offsite paired backup is required before activation planning'
[[ -f $offsite_receipt && ! -L $offsite_receipt ]] || die 'selected offsite backup receipt is unsafe'

current_release=''
if [[ -L $CURRENT ]]; then
  current_release="$(readlink -f -- "$CURRENT")"
  [[ $current_release == "$RELEASES/"* && $(dirname -- "$current_release") == "$RELEASES" ]] \
    || die 'current release leaves the controlled release directory'
fi
core_service_enabled="$(systemctl is-enabled uten-website.service 2>/dev/null || true)"
core_watchdog_enabled="$(systemctl is-enabled uten-website-entry-watchdog.timer 2>/dev/null || true)"
[[ $(systemctl is-enabled nginx.service 2>/dev/null || true) == enabled && \
   $(systemctl is-enabled uten-website-boot-gate.service 2>/dev/null || true) == enabled ]] \
  || die 'Nginx and the fail-closed boot gate must be enabled before activation'
if [[ -z $current_release ]]; then
  [[ $core_service_enabled == disabled && $core_watchdog_enabled == disabled ]] \
    || die 'first activation requires app/watchdog disabled exactly as prepared by the fresh-host installer'
else
  [[ $core_service_enabled == enabled && $core_watchdog_enabled == enabled ]] \
    || die 'existing production autostart was intentionally disabled; do not override incident isolation with activation'
fi

if [[ $ACTION == plan ]]; then
  [[ $# -eq 0 ]] || die 'plan accepts no additional arguments'
  [[ -f $DB && ! -L $DB && -d $UPLOADS && ! -L $UPLOADS ]] || die 'live paired state is not ready'
  install -d -m 0700 -o root -g root "$PLANS" "$RECEIPTS" "$BACKUPS"
  temporary="$(mktemp --tmpdir="$PLANS" .activation-plan.XXXXXX)"
  trap 'rm -f -- "$temporary"' EXIT
  PUBLICATION=$PUBLICATION CURRENT_RELEASE=$current_release DB=$DB SIGNERS=$SIGNERS VERSION=$VERSION OFFSITE_RECEIPT=$offsite_receipt \
  CORE_SERVICE_ENABLED=$core_service_enabled CORE_WATCHDOG_ENABLED=$core_watchdog_enabled \
    python3 -I - "$temporary" <<'PY'
import hashlib, json, os, pathlib, sys
def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest()
publication=pathlib.Path(os.environ['PUBLICATION'])
manifest=publication/'manifest.json'
value={
  'currentRelease': os.environ['CURRENT_RELEASE'],
  'coreAutostartBefore': {'service':os.environ['CORE_SERVICE_ENABLED'],'watchdog':os.environ['CORE_WATCHDOG_ENABLED']},
  'databaseSha256': digest(os.environ['DB']),
  'manifestSha256': digest(manifest),
  'offsiteReceipt': os.environ['OFFSITE_RECEIPT'],
  'offsiteReceiptSha256': digest(os.environ['OFFSITE_RECEIPT']),
  'publication': str(publication),
  'signersSha256': digest(os.environ['SIGNERS']),
  'version': os.environ['VERSION'],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
  publish_root_file "$temporary" "$PLAN"
  plan_sha="$(sha256sum -- "$PLAN" | awk '{print $1}')"
  printf 'WEBSITE_ACTIVATION_PLAN version=%s sha256=%s current=%s\n' "$VERSION" "$plan_sha" "${current_release:-NONE}"
  exit 0
fi

[[ $ACTION == apply ]] || die 'action must be plan or apply'
[[ $PLAN_SHA =~ ^[0-9a-f]{64}$ ]] || die '--plan-sha must be a lowercase SHA-256'
[[ $CONFIRMATION == "ACTIVATE-WEBSITE-$VERSION" ]] || die 'typed activation confirmation differs'
[[ -f $PLAN && ! -L $PLAN ]] || die 'root-owned activation plan is missing'
actual_plan_sha="$(sha256sum -- "$PLAN" | awk '{print $1}')"
[[ $actual_plan_sha == "$PLAN_SHA" ]] || die 'activation plan SHA differs'

PUBLICATION=$PUBLICATION CURRENT_RELEASE=$current_release DB=$DB SIGNERS=$SIGNERS VERSION=$VERSION OFFSITE_RECEIPT=$offsite_receipt \
  CORE_SERVICE_ENABLED=$core_service_enabled CORE_WATCHDOG_ENABLED=$core_watchdog_enabled \
  python3 -I - "$PLAN" <<'PY'
import hashlib,json,os,pathlib,sys
def digest(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for c in iter(lambda:f.read(1024*1024),b''): h.update(c)
 return h.hexdigest()
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); v=json.loads(raw)
if raw != (json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode(): raise SystemExit('plan is not canonical')
expected={'coreAutostartBefore':{'service':os.environ['CORE_SERVICE_ENABLED'],'watchdog':os.environ['CORE_WATCHDOG_ENABLED']},'currentRelease':os.environ['CURRENT_RELEASE'],'databaseSha256':digest(os.environ['DB']),'manifestSha256':digest(pathlib.Path(os.environ['PUBLICATION'])/'manifest.json'),'offsiteReceipt':os.environ['OFFSITE_RECEIPT'],'offsiteReceiptSha256':digest(os.environ['OFFSITE_RECEIPT']),'publication':os.environ['PUBLICATION'],'signersSha256':digest(os.environ['SIGNERS']),'version':os.environ['VERSION']}
if v != expected: raise SystemExit('live state or signed publication changed after planning')
PY

health_check() {
  curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health \
    | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)=={"status":"ok"} else 1)'
}

activation_id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6)"
snapshot_id=$activation_id
snapshot=$BACKUPS/$snapshot_id
quiescence=$PLANS/$VERSION.quiescence.json
new_release=''
failure_reason='activation interrupted before completion'
activation_succeeded=false
activation_committed=false

on_failure() {
  local status=$?
  trap - ERR EXIT
  set +e
  "$BOOT_GUARD" close || systemctl stop nginx.service || true
  systemctl stop uten-website.service || true
  if [[ -f $START_GRANT && ! -L $START_GRANT && $(stat -c '%U:%G:%a:%h' -- "$START_GRANT" 2>/dev/null) == root:root:600:1 ]]; then
    install -d -m 0700 -o root -g root "$START_GRANT_ABORTED"
    install -m 0600 -o root -g root "$START_GRANT" "$START_GRANT_ABORTED/$activation_id.json"
    durable_file "$START_GRANT_ABORTED/$activation_id.json"
    rm -f -- "$START_GRANT"
  fi
  rm -f -- "$START_GRANT".tmp-* || true
  if $activation_committed; then
    release_state_lock
    install -d -m 0700 -o root -g root "$ATTEMPT_FAILURES"
    ACTIVATION_ID=$activation_id FAILURE_REASON=$failure_reason STATUS=$status VERSION=$VERSION RECEIPT=$RECEIPTS/$activation_id.json \
      python3 -I - "$ATTEMPT_FAILURES/$activation_id.committed-pending-ingress.json.tmp" <<'PY'
import hashlib,json,os,pathlib,sys
receipt=pathlib.Path(os.environ['RECEIPT'])
v={'activationId':os.environ['ACTIVATION_ID'],'activationReceipt':str(receipt),'activationReceiptSha256':hashlib.sha256(receipt.read_bytes()).hexdigest(),'failureReason':os.environ['FAILURE_REASON'],'format':'uten-website-activation-committed-pending-ingress-v1','originalStatus':int(os.environ['STATUS']),'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
    publish_root_file "$ATTEMPT_FAILURES/$activation_id.committed-pending-ingress.json.tmp" "$ATTEMPT_FAILURES/$activation_id.committed-pending-ingress.json"
    printf 'WEBSITE_ACTIVATION_COMMITTED_ENTRY_PENDING: signed state committed; ingress remains closed; watchdog may reopen only after full gates pass; receipt=%s\n' "$ATTEMPT_FAILURES/$activation_id.committed-pending-ingress.json" >&2
    exit "$status"
  fi
  if [[ -z $current_release ]]; then
    systemctl disable --now uten-website-entry-watchdog.timer uten-website.service || true
  fi
  if [[ ! -e $IN_PROGRESS && ! -L $IN_PROGRESS ]]; then
    local pre_mutation_recovered=false
    install -d -m 0700 -o root -g root "$ATTEMPT_FAILURES"
    release_state_lock
    if [[ -n $current_release && -d $current_release && ! -L $current_release && -L $CURRENT && $(readlink -f -- "$CURRENT") == "$current_release" ]]; then
      if systemctl start uten-website.service && "$BOOT_GUARD" recover-ready; then
        pre_mutation_recovered=true
      else
        systemctl stop uten-website.service || true
        close_status=0
        "$BOOT_GUARD" close || close_status=$?
        (( close_status == 0 )) || systemctl stop nginx.service || true
      fi
    fi
    ACTIVATION_ID=$activation_id FAILURE_REASON=$failure_reason STATUS=$status VERSION=$VERSION PREVIOUS=$current_release RECOVERED=$pre_mutation_recovered \
      python3 -I - "$ATTEMPT_FAILURES/$activation_id.json.tmp" <<'PY'
import json,os,pathlib,sys
v={'activationId':os.environ['ACTIVATION_ID'],'failureReason':os.environ['FAILURE_REASON'],'format':'uten-website-pre-mutation-activation-failure-v1','originalStatus':int(os.environ['STATUS']),'previousRelease':os.environ['PREVIOUS'],'previousServiceRecovered':os.environ['RECOVERED']=='true','version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
    publish_root_file "$ATTEMPT_FAILURES/$activation_id.json.tmp" "$ATTEMPT_FAILURES/$activation_id.json"
    printf 'WEBSITE_ACTIVATION_ABORTED_BEFORE_MUTATION: receipt=%s previous_recovered=%s\n' "$ATTEMPT_FAILURES/$activation_id.json" "$pre_mutation_recovered" >&2
    exit "$status"
  fi
  acquire_state_lock
  local restore_dir=$CONTROL/.activation-restore-$activation_id
  local incident=$CONTROL/incidents/$activation_id
  local restore_proved=false
  if [[ -d $snapshot && ! -L $snapshot ]]; then
    if (
      set -Eeuo pipefail
      [[ ! -e $restore_dir && ! -L $restore_dir ]] || exit 1
      python3 -I "$STATE_TOOL" restore --snapshot "$snapshot" --destination "$restore_dir" || exit 1
      install -d -m 0700 -o root -g root "$incident" || exit 1
      [[ ! -e $DB && ! -L $DB ]] || mv -- "$DB" "$incident/website.db.failed" || exit 1
      for suffix in -journal -shm -wal; do
        sidecar=$DB$suffix
        [[ ! -e $sidecar && ! -L $sidecar ]] || mv -- "$sidecar" "$incident/website.db$suffix.failed" || exit 1
      done
      [[ ! -e $UPLOADS && ! -L $UPLOADS ]] || mv -- "$UPLOADS" "$incident/uploads.failed" || exit 1
      mv -- "$restore_dir/website.db" "$DB" || exit 1
      mv -- "$restore_dir/uploads" "$UPLOADS" || exit 1
      mv -- "$restore_dir/restore-receipt.json" "$incident/restore-receipt.json" || exit 1
      rmdir -- "$restore_dir" || exit 1
      chown uten-website:uten-website "$DB" || exit 1
      chmod 0600 "$DB" || exit 1
      chown -R uten-website:uten-website-media "$UPLOADS" || exit 1
      find "$UPLOADS" -type d -exec chmod 2750 {} + || exit 1
      find "$UPLOADS" -type f -exec chmod 0640 {} + || exit 1
      if [[ -n $current_release && -d $current_release && ! -L $current_release ]]; then
        ln -s -- "$current_release" "$CURRENT.recovery-$activation_id" || exit 1
        mv -Tf -- "$CURRENT.recovery-$activation_id" "$CURRENT" || exit 1
      elif [[ -L $CURRENT ]]; then
        mv -- "$CURRENT" "$incident/current.failed-link" || exit 1
      fi
      durable_directory "$STATE" || exit 1
      durable_directory "$incident" || exit 1
      durable_directory "$(dirname -- "$incident")" || exit 1
      durable_directory "$CONTROL" || exit 1
      durable_directory "$BASE" || exit 1
      python3 -I "$STATE_TOOL" verify-restored-live --snapshot "$snapshot" --database "$DB" --uploads "$UPLOADS" || exit 1
      if [[ -n $current_release ]]; then
        [[ -L $CURRENT && $(readlink -f -- "$CURRENT") == "$current_release" ]] || exit 1
      else
        [[ ! -e $CURRENT && ! -L $CURRENT ]] || exit 1
      fi
    ); then
      restore_proved=true
    fi
  fi

  if $restore_proved; then
    # This marker makes every power-loss boundary in the FAILED/IN_PROGRESS
    # transition resumable.  It is published only after the restored live pair,
    # previous current link and all affected parent directories were fsynced.
    ACTIVATION_ID=$activation_id VERSION=$VERSION PLAN_SHA=$PLAN_SHA SNAPSHOT=$snapshot PREVIOUS=$current_release INCIDENT=$incident \
      python3 -I - "$RECOVERY_PROGRESS.tmp" <<'PY'
import json,os,pathlib,sys
v={'activationId':os.environ['ACTIVATION_ID'],'format':'uten-website-activation-failure-finalization-v1','incident':os.environ['INCIDENT'],'phase':'restored-verified','planSha256':os.environ['PLAN_SHA'],'previousRelease':os.environ['PREVIOUS'],'snapshot':os.environ['SNAPSHOT'],'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
    publish_root_file "$RECOVERY_PROGRESS.tmp" "$RECOVERY_PROGRESS"
    FAILURE_REASON=$failure_reason STATUS=$status VERSION=$VERSION PLAN_SHA=$PLAN_SHA SNAPSHOT=$snapshot PREVIOUS=$current_release \
      python3 -I - "$MARKER.tmp" <<'PY'
import json,os,pathlib,sys
v={'failureReason':os.environ['FAILURE_REASON'],'format':'uten-website-activation-failed-v1','planSha256':os.environ['PLAN_SHA'],'previousRelease':os.environ['PREVIOUS'],'snapshot':os.environ['SNAPSHOT'],'status':int(os.environ['STATUS']),'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
    publish_root_file "$MARKER.tmp" "$MARKER"
    if [[ -f $IN_PROGRESS && ! -L $IN_PROGRESS ]]; then
      mv -- "$IN_PROGRESS" "$incident/activation-in-progress.json"
      durable_file "$incident/activation-in-progress.json"
      durable_directory "$CONTROL"
    fi
    mv -- "$RECOVERY_PROGRESS" "$incident/activation-failure-finalization.completed.json"
    durable_file "$incident/activation-failure-finalization.completed.json"
    durable_directory "$incident"
    durable_directory "$CONTROL"
    if [[ -n $current_release && -d $current_release ]]; then
      release_state_lock
      systemctl start uten-website.service || true
    fi
    printf 'WEBSITE_ACTIVATION_FAILED: paired restore proved; ingress closed; run uten-website-recover assess\n' >&2
  else
    ACTIVATION_ID=$activation_id FAILURE_REASON=$failure_reason STATUS=$status VERSION=$VERSION SNAPSHOT=$snapshot PREVIOUS=$current_release \
      python3 -I - "$RESTORE_FAILED.tmp" <<'PY'
import json,os,pathlib,sys
v={'activationId':os.environ['ACTIVATION_ID'],'failureReason':os.environ['FAILURE_REASON'],'format':'uten-website-activation-restore-failed-v1','originalStatus':int(os.environ['STATUS']),'previousRelease':os.environ['PREVIOUS'],'snapshot':os.environ['SNAPSHOT'],'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
    publish_root_file "$RESTORE_FAILED.tmp" "$RESTORE_FAILED"
    printf 'WEBSITE_ACTIVATION_RESTORE_UNPROVED: service stopped and ingress closed; never delete %s\n' "$RESTORE_FAILED" >&2
  fi
  release_state_lock
  exit "$status"
}
trap on_failure ERR EXIT

"$BOOT_GUARD" close
systemctl stop uten-website.service
[[ $(systemctl is-active uten-website.service || true) == inactive ]] || { failure_reason='website service did not stop'; false; }
nonce="$(openssl rand -hex 16)"
DB=$DB UPLOADS=$UPLOADS NONCE=$nonce python3 -I - "$quiescence.tmp" <<'PY'
import json,os,pathlib,sys
v={'database':os.environ['DB'],'gateClosed':True,'nonce':os.environ['NONCE'],'serviceStopped':True,'uploads':os.environ['UPLOADS']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$quiescence.tmp" "$quiescence"
failure_reason='paired pre-activation snapshot failed'
python3 -I "$STATE_TOOL" snapshot --database "$DB" --uploads "$UPLOADS" --output "$snapshot" --snapshot-id "$snapshot_id" --quiescence-receipt "$quiescence"

# From this point onward extraction/migration/current switching may change live
# behavior.  Persist one crash-recovery marker first so a hard power loss can
# never be mistaken for a completed activation on the next boot.
ACTIVATION_ID=$activation_id VERSION=$VERSION PLAN_SHA=$PLAN_SHA SNAPSHOT=$snapshot PREVIOUS=$current_release \
  python3 -I - "$IN_PROGRESS.tmp" <<'PY'
import json,os,pathlib,sys
v={'activationId':os.environ['ACTIVATION_ID'],'format':'uten-website-activation-in-progress-v1','planSha256':os.environ['PLAN_SHA'],'previousRelease':os.environ['PREVIOUS'],'snapshot':os.environ['SNAPSHOT'],'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$IN_PROGRESS.tmp" "$IN_PROGRESS"

commit12="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["commitSha"][:12])' "$PUBLICATION/manifest.json")"
new_release=$RELEASES/$VERSION-$commit12
[[ ! -e $new_release && ! -L $new_release ]] || { failure_reason='target release already exists'; false; }
failure_reason='signed artifact extraction failed'
python3 -I "$RELEASE_TOOL" extract --publication "$PUBLICATION" --allowed-signers "$SIGNERS" --expected-version "$VERSION" --destination "$new_release"
chown -R root:root "$new_release"
[[ ! -e $new_release/.next/cache && ! -L $new_release/.next/cache ]] || { failure_reason='release contains a cache path'; false; }
ln -s /var/cache/uten-website "$new_release/.next/cache"
durable_directory "$new_release/.next"
durable_directory "$new_release"

failure_reason='Prisma production migration gate failed'
runuser -u uten-website -- /usr/bin/env DATABASE_URL=file:/var/lib/uten-website/runtime/website.db \
  /usr/bin/node "$new_release/prisma-runtime/node_modules/prisma/build/index.js" migrate deploy \
    --schema "$new_release/prisma-runtime/prisma/schema.prisma"
runuser -u uten-website -- /usr/bin/env DATABASE_URL=file:/var/lib/uten-website/runtime/website.db \
  /usr/bin/node "$new_release/prisma-runtime/node_modules/prisma/build/index.js" migrate status \
    --schema "$new_release/prisma-runtime/prisma/schema.prisma"
failure_reason='database authority/media ledger binding failed'
authority_binding_receipt=$RECEIPTS/$activation_id.authority-binding.json
[[ ! -e $authority_binding_receipt && ! -L $authority_binding_receipt ]] \
  || { failure_reason='authority binding receipt already exists'; false; }
/usr/bin/python3 -I "$STATE_TOOL" initialize-authority \
  --database "$DB" --uploads "$UPLOADS" \
  --authority-receipt "$AUTHORITY_RECEIPT" \
  --signed-manifest "$new_release/.release-evidence/manifest.json" \
  --paired-snapshot "$snapshot" \
  --activation-plan "$PLAN" --activation-marker "$IN_PROGRESS" \
  --drop-to-user uten-website >"$authority_binding_receipt.tmp"
python3 -I - "$authority_binding_receipt.tmp" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); value=json.loads(raw)
if raw!=(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode(): raise SystemExit('authority binding evidence is not canonical')
expected={'activationMarkerSha256','activationPlanSha256','authorityUuid','databaseSchemaSha256','firstBinding','format','liveDatabaseSha256','media','pairedSnapshotId','pairedSnapshotManifestSha256','signedManifestSha256','toolSha256','totalBytes'}
if set(value)!=expected or value.get('format')!='uten-website-authority-binding-evidence-v1': raise SystemExit('authority binding evidence contract differs')
PY
chown root:root "$authority_binding_receipt.tmp"
chmod 0600 "$authority_binding_receipt.tmp"
mv -Tf -- "$authority_binding_receipt.tmp" "$authority_binding_receipt"
durable_file "$authority_binding_receipt"
runuser -u uten-website -- /usr/bin/python3 -I "$STATE_TOOL" verify-live \
  --database "$DB" --uploads "$UPLOADS" \
  --authority-receipt "$AUTHORITY_RECEIPT" \
  --signed-manifest "$new_release/.release-evidence/manifest.json"

failure_reason='atomic release switch or runtime validation failed'
ln -s -- "$new_release" "$CURRENT.next-$activation_id"
mv -Tf -- "$CURRENT.next-$activation_id" "$CURRENT"
durable_directory "$BASE"
/usr/local/libexec/uten-website/validate-runtime
[[ ! -e $START_GRANT && ! -L $START_GRANT ]] || { failure_reason='orphan activation start grant exists'; false; }
start_grant_receipt=$START_GRANT_RECEIPTS/$activation_id.json
[[ ! -e $start_grant_receipt && ! -L $start_grant_receipt ]] || { failure_reason='activation start grant receipt already exists'; false; }
failure_reason='one-time activation start authorization failed'
ACTIVATION_ID=$activation_id VERSION=$VERSION PLAN_SHA=$PLAN_SHA SNAPSHOT=$snapshot CURRENT=$CURRENT DB=$DB IN_PROGRESS=$IN_PROGRESS \
  python3 -I - "$START_GRANT.tmp-$activation_id" <<'PY'
import hashlib,json,os,pathlib,sys
def digest(path):
 h=hashlib.sha256()
 with pathlib.Path(path).open('rb') as source:
  for chunk in iter(lambda:source.read(1024*1024),b''): h.update(chunk)
 return h.hexdigest()
marker=pathlib.Path(os.environ['IN_PROGRESS']); marker_raw=marker.read_bytes()
current=pathlib.Path(os.environ['CURRENT']).resolve(strict=True)
value={
 'activationId':os.environ['ACTIVATION_ID'],
 'bootId':pathlib.Path('/proc/sys/kernel/random/boot_id').read_text(encoding='ascii').strip(),
 'currentTarget':str(current),
 'databaseSha256':digest(os.environ['DB']),
 'format':'uten-website-activation-start-grant-v1',
 'inProgressSha256':hashlib.sha256(marker_raw).hexdigest(),
 'manifestSha256':digest(current/'.release-evidence/manifest.json'),
 'planSha256':os.environ['PLAN_SHA'],
 'snapshotManifestSha256':digest(pathlib.Path(os.environ['SNAPSHOT'])/'manifest.json'),
 'version':os.environ['VERSION'],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
chown root:root "$START_GRANT.tmp-$activation_id"
chmod 0600 "$START_GRANT.tmp-$activation_id"
mv -Tf -- "$START_GRANT.tmp-$activation_id" "$START_GRANT"
durable_file "$START_GRANT"
start_grant_sha="$(sha256sum -- "$START_GRANT" | awk '{print $1}')"
release_state_lock
systemctl start uten-website.service
[[ ! -e $START_GRANT && ! -L $START_GRANT ]] || { failure_reason='activation start grant was not consumed'; false; }
[[ -f $start_grant_receipt && ! -L $start_grant_receipt && \
   $(stat -c '%U:%G:%a:%h' -- "$start_grant_receipt") == root:root:600:1 && \
   $(sha256sum -- "$start_grant_receipt" | awk '{print $1}') == "$start_grant_sha" ]] \
  || { failure_reason='exact durable activation start grant consumption receipt is missing'; false; }
failure_reason='new website readiness probe failed'
for _ in {1..20}; do health_check && break; sleep 1; done
health_check

if [[ -z $current_release ]]; then
  failure_reason='first signed activation core autostart commissioning failed'
  systemctl enable uten-website.service
  systemctl enable --now uten-website-entry-watchdog.timer
fi
[[ $(systemctl is-enabled uten-website.service 2>/dev/null || true) == enabled && \
   $(systemctl is-enabled uten-website-entry-watchdog.timer 2>/dev/null || true) == enabled && \
   $(systemctl is-active uten-website-entry-watchdog.timer 2>/dev/null || true) == active ]] \
  || { failure_reason='core app/watchdog autostart could not be proved enabled and active'; false; }

VERSION=$VERSION PLAN_SHA=$PLAN_SHA SNAPSHOT=$snapshot PREVIOUS=$current_release RELEASE=$new_release OFFSITE=$offsite_receipt \
  python3 -I - "$RECEIPTS/$activation_id.json.tmp" <<'PY'
import hashlib,json,os,pathlib,sys
offsite=pathlib.Path(os.environ['OFFSITE'])
v={'coreAutostart':'enabled','format':'uten-website-activation-receipt-v1','newRelease':os.environ['RELEASE'],'offsiteReceipt':str(offsite),'offsiteReceiptSha256':hashlib.sha256(offsite.read_bytes()).hexdigest(),'planSha256':os.environ['PLAN_SHA'],'previousRelease':os.environ['PREVIOUS'],'snapshot':os.environ['SNAPSHOT'],'status':'activated','version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$RECEIPTS/$activation_id.json.tmp" "$RECEIPTS/$activation_id.json"
mv -- "$IN_PROGRESS" "$RECEIPTS/$activation_id.in-progress.json"
durable_file "$RECEIPTS/$activation_id.in-progress.json"
durable_directory "$CONTROL"
activation_committed=true
failure_reason='committed website failed final signed ingress validation'
"$BOOT_GUARD" recover-ready
cmp -s -- "$GATE" "$OPEN_GATE" || { failure_reason='committed website did not load the exact reviewed open gate'; false; }
activation_succeeded=true
trap - ERR EXIT
printf 'WEBSITE_ACTIVATION_OK version=%s release=%s receipt=%s\n' "$VERSION" "$new_release" "$RECEIPTS/$activation_id.json"
