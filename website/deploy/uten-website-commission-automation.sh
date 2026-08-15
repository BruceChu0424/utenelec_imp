#!/usr/bin/env bash
# Evidence-bound one-time enablement for backup + health only. Never stages code.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly CONTROL=/var/lib/uten-website/control
readonly COMMISSION=$CONTROL/commissioning
readonly PLAN=$COMMISSION/automation-plan.json
readonly RECEIPTS=$COMMISSION/receipts
readonly FAILURES=$COMMISSION/failures
readonly ACCEPTANCE=/etc/uten-website/automation-acceptance.json
readonly EVIDENCE_DIR=/etc/uten-website/automation-evidence
readonly STORAGE_CHECK=/usr/local/libexec/uten-website/validate-storage
readonly HEALTH=/usr/local/libexec/uten-website/uten-website-health
readonly RESTORE_DRILLS=$CONTROL/restore-drills
readonly IN_PROGRESS=$COMMISSION/automation-in-progress.json
readonly ENABLED_MARKER=$COMMISSION/automation-enabled.json
readonly STAGE_OPT_IN=/etc/uten-website/enable-auto-staging
readonly LOCK=/run/uten-website-release/commission.lock
readonly LOCK_TOOL=/usr/local/libexec/uten-website/open_root_lock.py

die() { printf 'WEBSITE_AUTOMATION_COMMISSION_REFUSED: %s\n' "$*" >&2; exit 1; }
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
publish_root_file() {
  local temporary=$1 destination=$2
  [[ -f $temporary && ! -L $temporary ]] || die "atomic evidence temporary is unsafe: $temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  durable_file "$temporary"
  mv -Tf -- "$temporary" "$destination"
  durable_file "$destination"
}

[[ ${EUID} -eq 0 ]] || die 'must run as root'
[[ $# -ge 1 ]] || die 'usage: uten-website-commission-automation plan | apply --plan-sha SHA --confirmation ENABLE-WEBSITE-BACKUP-AND-HEALTH-TIMERS | recover --confirmation DISABLE-INCOMPLETE-WEBSITE-AUTOMATION'
readonly ACTION=$1
shift
PLAN_SHA=''
CONFIRMATION=''
while (($#)); do
  case "$1" in
    --plan-sha) [[ $# -ge 2 ]] || die '--plan-sha needs a value'; PLAN_SHA=$2; shift 2 ;;
    --confirmation) [[ $# -ge 2 ]] || die '--confirmation needs a value'; CONFIRMATION=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $ACTION == plan || $ACTION == apply || $ACTION == recover ]] || die 'action must be plan, apply or recover'
if [[ $ACTION != recover ]]; then
  # Recovery remains callable to disable a host interrupted by an older
  # candidate.  New plan/apply is rejected before a lock or persistent path is
  # created until backup/media recovery has completed its source contract.
  die 'production automation source NO-GO: semantic paired backup and interrupted-media recovery are not yet closed'
fi
for command_name in chown chmod cmp date flock install mv python3 sha256sum stat systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
python3 -I "$LOCK_TOOL" "$LOCK" || die 'commissioning lock file is unsafe'
exec 9<>"$LOCK"
flock -n 9 || die 'automation commissioning lock is held'
"$STORAGE_CHECK"
install -d -m 0700 -o root -g root "$COMMISSION" "$RECEIPTS" "$FAILURES"
if [[ $ACTION == recover ]]; then
  [[ $CONFIRMATION == DISABLE-INCOMPLETE-WEBSITE-AUTOMATION && -f $IN_PROGRESS && ! -L $IN_PROGRESS ]] \
    || die 'typed recovery confirmation and a safe in-progress marker are required'
  python3 -I - "$IN_PROGRESS" <<'PY'
import json,pathlib,re,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); v=json.loads(raw)
if raw!=(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode() or set(v)!={'format','planSha256'} or v.get('format')!='uten-website-automation-commission-in-progress-v1' or not re.fullmatch(r'[0-9a-f]{64}',str(v.get('planSha256',''))): raise SystemExit('commissioning progress contract differs')
PY
  systemctl disable --now uten-website-stage.timer uten-website-backup.timer uten-website-health.timer
  [[ $(systemctl is-enabled uten-website-backup.timer 2>/dev/null || true) == disabled && \
     $(systemctl is-active uten-website-backup.timer 2>/dev/null || true) == inactive && \
     $(systemctl is-enabled uten-website-health.timer 2>/dev/null || true) == disabled && \
     $(systemctl is-active uten-website-health.timer 2>/dev/null || true) == inactive && \
     $(systemctl is-enabled uten-website-stage.timer 2>/dev/null || true) == disabled && \
     $(systemctl is-active uten-website-stage.timer 2>/dev/null || true) == inactive ]] \
    || die 'incomplete timers could not be disabled'
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
  if [[ -e $ENABLED_MARKER || -L $ENABLED_MARKER ]]; then
    [[ -f $ENABLED_MARKER && ! -L $ENABLED_MARKER ]] || die 'enabled marker has an unsafe shape'
    mv -- "$ENABLED_MARKER" "$FAILURES/$stamp-automation-enabled.json"
    durable_file "$FAILURES/$stamp-automation-enabled.json"
  fi
  mv -- "$IN_PROGRESS" "$FAILURES/$stamp-automation-in-progress.json"
  durable_file "$FAILURES/$stamp-automation-in-progress.json"
  printf 'WEBSITE_AUTOMATION_INCOMPLETE_DISABLED evidence=%s\n' "$FAILURES/$stamp-automation-in-progress.json"
  exit 0
fi
[[ ! -e $IN_PROGRESS && ! -L $IN_PROGRESS && ! -e $ENABLED_MARKER && ! -L $ENABLED_MARKER ]] \
  || die 'existing commissioning state must be recovered or is already commissioned'
[[ ! -e $CONTROL/activation-failed.json && ! -e $CONTROL/activation-in-progress.json && ! -e $CONTROL/activation-restore-failed.json ]] \
  || die 'activation evidence must be fully recovered first'
[[ ! -e $CONTROL/backup-failed.json ]] || die 'backup failure evidence must be resolved first'
systemctl is-active --quiet uten-website.service || die 'website service must be active'
[[ -f $ACCEPTANCE && ! -L $ACCEPTANCE && -d $EVIDENCE_DIR && ! -L $EVIDENCE_DIR ]] \
  || die 'root-owned automation acceptance/evidence is missing'
[[ $(stat -c '%U:%G:%a:%h' "$ACCEPTANCE") == root:root:600:1 ]] \
  || die 'automation acceptance must be root:root 0600 with one link'
for evidence in alert-delivery.json capacity.json power-loss.json; do
  path=$EVIDENCE_DIR/$evidence
  [[ -f $path && ! -L $path && $(stat -c '%U:%G:%a:%h' "$path") == root:root:600:1 ]] \
    || die "unsafe commissioning evidence: $path"
done

# This command independently revalidates seven distinct off-site recovery days,
# freshness, capacity and local readiness. It also emits durable alert evidence
# on failure, so a plan cannot be created from an unhealthy host.
"$HEALTH" --commissioning-preflight

collect_plan() {
  local output=$1 backup_enabled=$2 backup_active=$3 health_enabled=$4 health_active=$5 stage_enabled=$6 stage_active=$7
  ACCEPTANCE=$ACCEPTANCE EVIDENCE_DIR=$EVIDENCE_DIR RESTORE_DRILLS=$RESTORE_DRILLS \
  BACKUP_ENABLED=$backup_enabled BACKUP_ACTIVE=$backup_active HEALTH_ENABLED=$health_enabled HEALTH_ACTIVE=$health_active \
  STAGE_ENABLED=$stage_enabled STAGE_ACTIVE=$stage_active \
    python3 -I - "$output" <<'PY'
import datetime,hashlib,json,os,pathlib,re,sys
def canonical(value): return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
def checked(path,maximum=1024*1024):
 p=pathlib.Path(path); info=p.lstat()
 if p.is_symlink() or not p.is_file() or info.st_nlink!=1 or info.st_size<2 or info.st_size>maximum: raise SystemExit(f'unsafe evidence file: {p}')
 raw=p.read_bytes(); value=json.loads(raw)
 if raw!=canonical(value): raise SystemExit(f'evidence is not canonical JSON: {p}')
 return p,raw,value
acceptance_path,acceptance_raw,acceptance=checked(os.environ['ACCEPTANCE'])
expected={'acceptedAtUtc','alertDeliveryEvidenceSha256','capacityEvidenceSha256','format','powerLossEvidenceSha256','restoreDrillReceiptSha256','reviewers'}
if set(acceptance)!=expected or acceptance['format']!='uten-website-automation-acceptance-v1': raise SystemExit('acceptance contract differs')
stamp=datetime.datetime.fromisoformat(acceptance['acceptedAtUtc'].replace('Z','+00:00'))
now=datetime.datetime.now(datetime.timezone.utc)
if stamp.tzinfo is None or stamp>now or (now-stamp).total_seconds()>7*86400: raise SystemExit('acceptance is future-dated or older than seven days')
reviewers=acceptance['reviewers']
if not isinstance(reviewers,list) or len(reviewers)!=2 or len(set(reviewers))!=2 or any(not isinstance(v,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9 ._@-]{2,127}',v) for v in reviewers): raise SystemExit('two distinct named reviewers are required')
evidence={}
for name,key in [('alert-delivery.json','alertDeliveryEvidenceSha256'),('capacity.json','capacityEvidenceSha256'),('power-loss.json','powerLossEvidenceSha256')]:
 path,raw,_=checked(pathlib.Path(os.environ['EVIDENCE_DIR'])/name)
 digest=hashlib.sha256(raw).hexdigest()
 if acceptance[key]!=digest: raise SystemExit(f'{name} digest differs from acceptance')
 evidence[name]=digest
drills=[]
for path in pathlib.Path(os.environ['RESTORE_DRILLS']).glob('*/restore-receipt.json') if pathlib.Path(os.environ['RESTORE_DRILLS']).is_dir() else []:
 try:
  checked_path,raw,value=checked(path)
  if set(value)!={'databaseSha256','format','snapshotId','uploadsFileCount'} or value['format']!='uten-website-restore-drill-v1': continue
  match=re.fullmatch(r'(\d{8}T\d{6}Z)-[0-9a-f]{12}',str(value['snapshotId']))
  if not match: continue
  stamp=datetime.datetime.strptime(match.group(1),'%Y%m%dT%H%M%SZ').replace(tzinfo=datetime.timezone.utc)
  if stamp>now: continue
  drills.append((stamp,checked_path,hashlib.sha256(raw).hexdigest()))
 except (OSError,ValueError,KeyError,TypeError,json.JSONDecodeError): pass
if not drills: raise SystemExit('no valid isolated restore-drill receipt')
_,drill,drill_sha=max(drills)
if acceptance['restoreDrillReceiptSha256']!=drill_sha: raise SystemExit('latest restore-drill receipt differs from acceptance')
unit_paths=[pathlib.Path('/etc/systemd/system/uten-website-backup.service'),pathlib.Path('/etc/systemd/system/uten-website-backup.timer'),pathlib.Path('/etc/systemd/system/uten-website-health.service'),pathlib.Path('/etc/systemd/system/uten-website-health.timer'),pathlib.Path('/etc/systemd/system/uten-website-stage.service'),pathlib.Path('/etc/systemd/system/uten-website-stage.timer')]
units={}
for path in unit_paths:
 info=path.lstat()
 if path.is_symlink() or not path.is_file() or info.st_uid!=0 or info.st_gid!=0 or (info.st_mode&0o777)!=0o644 or info.st_nlink!=1: raise SystemExit(f'unit file is unsafe: {path}')
 units[path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
helper_paths=[pathlib.Path(v) for v in ('/usr/local/libexec/uten-website/uten-website-paired-backup','/usr/local/libexec/uten-website/uten-website-health','/usr/local/libexec/uten-website/validate-automation-enabled','/usr/local/libexec/uten-website/validate-storage','/usr/local/libexec/uten-website/paired_state.py','/usr/local/libexec/uten-website/website_release.py','/usr/local/libexec/uten-website/open_root_lock.py','/usr/local/libexec/uten-website/uten-website-boot-guard')]
helpers={}
for path in helper_paths:
 info=path.lstat()
 if path.is_symlink() or not path.is_file() or info.st_uid!=0 or info.st_gid!=0 or (info.st_mode&0o777)!=0o755 or info.st_nlink!=1: raise SystemExit(f'execution helper is unsafe: {path}')
 helpers[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
value={'acceptanceSha256':hashlib.sha256(acceptance_raw).hexdigest(),'evidenceSha256':evidence,'executionSha256':helpers,'format':'uten-website-automation-commission-plan-v1','restoreDrillReceipt':str(drill),'restoreDrillReceiptSha256':drill_sha,'timerState':{'backup':{'active':os.environ['BACKUP_ACTIVE'],'enabled':os.environ['BACKUP_ENABLED']},'health':{'active':os.environ['HEALTH_ACTIVE'],'enabled':os.environ['HEALTH_ENABLED']},'stage':{'active':os.environ['STAGE_ACTIVE'],'enabled':os.environ['STAGE_ENABLED'],'optIn':'absent'}},'unitSha256':units}
pathlib.Path(sys.argv[1]).write_bytes(canonical(value))
PY
}

backup_enabled="$(systemctl is-enabled uten-website-backup.timer 2>/dev/null || true)"
backup_active="$(systemctl is-active uten-website-backup.timer 2>/dev/null || true)"
health_enabled="$(systemctl is-enabled uten-website-health.timer 2>/dev/null || true)"
health_active="$(systemctl is-active uten-website-health.timer 2>/dev/null || true)"
stage_enabled="$(systemctl is-enabled uten-website-stage.timer 2>/dev/null || true)"
stage_active="$(systemctl is-active uten-website-stage.timer 2>/dev/null || true)"
[[ $backup_enabled == disabled && $backup_active == inactive && $health_enabled == disabled && $health_active == inactive && \
   $stage_enabled == disabled && $stage_active == inactive && ! -e $STAGE_OPT_IN && ! -L $STAGE_OPT_IN ]] \
  || die 'backup/health/stage timers must be disabled and inactive, with staging opt-in absent, before commissioning'

temporary=$COMMISSION/.automation-plan.$$.json
trap 'rm -f -- "$temporary"' EXIT
collect_plan "$temporary" "$backup_enabled" "$backup_active" "$health_enabled" "$health_active" "$stage_enabled" "$stage_active"
if [[ $ACTION == plan ]]; then
  publish_root_file "$temporary" "$PLAN"
  sha="$(sha256sum -- "$PLAN" | awk '{print $1}')"
  printf 'WEBSITE_AUTOMATION_COMMISSION_PLAN sha256=%s timers=backup,health staging=disabled\n' "$sha"
  exit 0
fi

[[ $PLAN_SHA =~ ^[0-9a-f]{64}$ && $CONFIRMATION == ENABLE-WEBSITE-BACKUP-AND-HEALTH-TIMERS ]] \
  || die 'exact plan SHA and typed confirmation are required'
[[ -f $PLAN && ! -L $PLAN && $(sha256sum -- "$PLAN" | awk '{print $1}') == "$PLAN_SHA" ]] \
  || die 'commission plan is missing or changed'
cmp -s -- "$PLAN" "$temporary" || die 'host acceptance, evidence, units or timer state changed after planning'

commissioned=false
on_failure() {
  status=$?
  trap - ERR EXIT
  set +e
  if ! $commissioned; then
    systemctl disable --now uten-website-stage.timer uten-website-backup.timer uten-website-health.timer
    stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
    for marker in "$IN_PROGRESS" "$ENABLED_MARKER"; do
      [[ ! -e $marker && ! -L $marker ]] || mv -- "$marker" "$FAILURES/$stamp-${marker##*/}"
    done
  fi
  exit "$status"
}
trap on_failure ERR EXIT
PLAN_SHA=$PLAN_SHA python3 -I - "$IN_PROGRESS.tmp" <<'PY'
import json,os,pathlib,sys
value={'format':'uten-website-automation-commission-in-progress-v1','planSha256':os.environ['PLAN_SHA']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$IN_PROGRESS.tmp" "$IN_PROGRESS"
systemctl enable --now uten-website-backup.timer uten-website-health.timer
[[ $(systemctl is-enabled uten-website-backup.timer) == enabled && $(systemctl is-active uten-website-backup.timer) == active ]] \
  || die 'backup timer did not become enabled and active'
[[ $(systemctl is-enabled uten-website-health.timer) == enabled && $(systemctl is-active uten-website-health.timer) == active ]] \
  || die 'health timer did not become enabled and active'
[[ $(systemctl is-enabled uten-website-stage.timer 2>/dev/null || true) == disabled && \
   $(systemctl is-active uten-website-stage.timer 2>/dev/null || true) == inactive && \
   ! -e $STAGE_OPT_IN && ! -L $STAGE_OPT_IN ]] \
  || die 'staging timer or opt-in changed during commissioning'
receipt=$RECEIPTS/$(date -u +%Y%m%dT%H%M%SZ)-$PLAN_SHA.json
PLAN_SHA=$PLAN_SHA python3 -I - "$receipt.tmp" <<'PY'
import json,os,pathlib,sys
value={'backupTimer':'enabled-active','format':'uten-website-automation-commission-receipt-v1','healthTimer':'enabled-active','planSha256':os.environ['PLAN_SHA'],'stageTimer':'disabled-inactive-opt-in-absent'}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$receipt.tmp" "$receipt"
PLAN_SHA=$PLAN_SHA RECEIPT=$receipt python3 -I - "$ENABLED_MARKER.tmp" <<'PY'
import hashlib,json,os,pathlib,sys
receipt=pathlib.Path(os.environ['RECEIPT'])
value={'format':'uten-website-automation-enabled-v1','planSha256':os.environ['PLAN_SHA'],'receipt':str(receipt),'receiptSha256':hashlib.sha256(receipt.read_bytes()).hexdigest()}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$ENABLED_MARKER.tmp" "$ENABLED_MARKER"
mv -- "$IN_PROGRESS" "$receipt.in-progress.json"
durable_file "$receipt.in-progress.json"
durable_file "$ENABLED_MARKER"
commissioned=true
trap - ERR EXIT
printf 'WEBSITE_AUTOMATION_COMMISSIONED receipt=%s backup=enabled-active health=enabled-active stage=disabled-inactive-opt-in-absent\n' "$receipt"
