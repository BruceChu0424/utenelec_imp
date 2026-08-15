#!/usr/bin/env bash
# Two-step restoration after power loss during an approved website activation.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly STATE=/var/lib/uten-website/runtime
readonly CONTROL=/var/lib/uten-website/control
readonly DB=$STATE/website.db
readonly UPLOADS=$STATE/uploads
readonly IN_PROGRESS=$CONTROL/activation-in-progress.json
readonly FAILED=$CONTROL/activation-failed.json
readonly RESTORE_FAILED=$CONTROL/activation-restore-failed.json
readonly RECOVERY_PROGRESS=$CONTROL/interrupted-recovery-in-progress.json
readonly CURRENT=/opt/uten-website/current
readonly RELEASES=/opt/uten-website/releases
readonly PLANS=$CONTROL/recovery-plans
readonly INCIDENTS=$CONTROL/incidents
readonly GATE=/etc/nginx/snippets/uten-website-gate.conf
readonly CLOSED_GATE=/usr/local/libexec/uten-website/uten-website-gate.closed.conf
readonly STATE_TOOL=/usr/local/libexec/uten-website/paired_state.py
readonly STORAGE_CHECK=/usr/local/libexec/uten-website/validate-storage
readonly LOCK=/run/uten-website-release/activation.lock
readonly STATE_LOCK=/run/uten-website-release/state-mutation.lock
readonly START_GRANT=/run/uten-website-release/activation-start.json
readonly LOCK_TOOL=/usr/local/libexec/uten-website/open_root_lock.py

die() { printf 'WEBSITE_INTERRUPTED_RECOVERY_REFUSED: %s\n' "$*" >&2; exit 1; }
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
release_state_lock() {
  if $state_lock_held; then
    flock -u 8
    exec 8>&-
    state_lock_held=false
  fi
}

[[ ${EUID} -eq 0 ]] || die 'must run as root'
[[ $# -ge 1 ]] || die 'usage: uten-website-recover-interrupted assess | apply --evidence-sha SHA --confirmation RESTORE-INTERRUPTED-WEBSITE-VERSION'
readonly ACTION=$1
shift
EVIDENCE_SHA=''
CONFIRMATION=''
while (($#)); do
  case "$1" in
    --evidence-sha) [[ $# -ge 2 ]] || die '--evidence-sha needs a value'; EVIDENCE_SHA=$2; shift 2 ;;
    --confirmation) [[ $# -ge 2 ]] || die '--confirmation needs a value'; CONFIRMATION=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $ACTION == assess || $ACTION == apply ]] || die 'action must be assess or apply'
for command_name in cmp curl dirname find flock install mktemp mv python3 readlink sha256sum systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done
python3 -I "$LOCK_TOOL" "$LOCK" || die 'activation/recovery lock file is unsafe'
exec 9<>"$LOCK"
flock -n 9 || die 'activation/recovery lock is held'
python3 -I "$LOCK_TOOL" "$STATE_LOCK" || die 'state-mutation lock file is unsafe'
exec 8<>"$STATE_LOCK"
flock -n 8 || die 'backup or another recovery owns the state-mutation lock'
state_lock_held=true
"$STORAGE_CHECK"
cmp -s -- "$GATE" "$CLOSED_GATE" || die 'ingress gate is not in the exact closed state'
if [[ (-e $FAILED || -L $FAILED) && (-e $RECOVERY_PROGRESS || -L $RECOVERY_PROGRESS) ]]; then
  [[ -f $FAILED && ! -L $FAILED && -f $RECOVERY_PROGRESS && ! -L $RECOVERY_PROGRESS ]] \
    || die 'interrupted recovery finalization evidence has an unsafe shape'
  resume_values="$(python3 -I - "$FAILED" "$RECOVERY_PROGRESS" "$IN_PROGRESS" <<'PY'
import hashlib,json,pathlib,re,sys
def load(path):
 p=pathlib.Path(path); raw=p.read_bytes(); value=json.loads(raw)
 if raw!=(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode(): raise SystemExit(f'non-canonical evidence: {p}')
 return raw,value
failed_raw,failed=load(sys.argv[1]); progress_raw,progress=load(sys.argv[2]); in_progress=pathlib.Path(sys.argv[3])
if set(failed)!={'failureReason','format','planSha256','previousRelease','snapshot','status','version'} or failed.get('format')!='uten-website-activation-failed-v1': raise SystemExit('failed marker contract differs')
progress_format=progress.get('format')
if progress_format=='uten-website-interrupted-recovery-progress-v1':
 if set(progress)!={'activationId','attempt','format','incident','phase','planSha256'} or progress.get('phase')!='restored-verified': raise SystemExit('interrupted recovery progress is not safely finalizable')
 kind='interrupted-recovery'; activation_id=str(progress['activationId'])
 attempt=pathlib.Path(str(progress['attempt'])); incident=pathlib.Path(str(progress['incident']))
 if attempt.parent!=pathlib.Path('/var/lib/uten-website/control/interrupted-recovery-work')/activation_id or not re.fullmatch(r'attempt\.[A-Za-z0-9]+',attempt.name): raise SystemExit('recovery attempt path differs')
 if incident!=pathlib.Path('/var/lib/uten-website/control/incidents')/(activation_id+'-interrupted')/attempt.name: raise SystemExit('recovery incident path differs')
 evidence_sha=str(progress['planSha256'])
elif progress_format=='uten-website-activation-failure-finalization-v1':
 expected={'activationId','format','incident','phase','planSha256','previousRelease','snapshot','version'}
 if set(progress)!=expected or progress.get('phase')!='restored-verified': raise SystemExit('activation failure finalization is not safely resumable')
 kind='activation-failure'; activation_id=str(progress['activationId']); attempt=''
 incident=pathlib.Path(str(progress['incident']))
 if incident!=pathlib.Path('/var/lib/uten-website/control/incidents')/activation_id: raise SystemExit('activation failure incident path differs')
 for key in ('planSha256','previousRelease','snapshot','version'):
  if progress[key]!=failed[key]: raise SystemExit(f'activation failure progress differs for {key}')
 evidence_sha=hashlib.sha256(progress_raw).hexdigest()
else:
 raise SystemExit('unknown recovery finalization format')
if not re.fullmatch(r'\d{8}T\d{6}Z-[0-9a-f]{12}',activation_id): raise SystemExit('activation id differs')
if pathlib.Path(str(failed['snapshot'])).name!=activation_id: raise SystemExit('failed snapshot and progress differ')
if in_progress.exists() or in_progress.is_symlink():
 _,marker=load(in_progress)
 expected_marker={'activationId','format','planSha256','previousRelease','snapshot','version'}
 if set(marker)!=expected_marker or marker.get('format')!='uten-website-activation-in-progress-v1' or marker.get('activationId')!=activation_id or marker.get('snapshot')!=failed['snapshot'] or marker.get('version')!=failed['version'] or marker.get('planSha256')!=failed['planSha256'] or marker.get('previousRelease')!=failed['previousRelease']: raise SystemExit('in-progress and finalization markers differ')
print(kind); print(activation_id); print(attempt); print(incident); print(evidence_sha); print(failed['previousRelease']); print(failed['snapshot']); print(failed['version'])
PY
)" || die 'interrupted recovery finalization evidence validation failed'
  resume_kind="$(printf '%s\n' "$resume_values" | sed -n '1p')"
  resume_activation_id="$(printf '%s\n' "$resume_values" | sed -n '2p')"
  resume_attempt="$(printf '%s\n' "$resume_values" | sed -n '3p')"
  resume_incident="$(printf '%s\n' "$resume_values" | sed -n '4p')"
  resume_plan_sha="$(printf '%s\n' "$resume_values" | sed -n '5p')"
  resume_previous="$(printf '%s\n' "$resume_values" | sed -n '6p')"
  resume_snapshot="$(printf '%s\n' "$resume_values" | sed -n '7p')"
  resume_version="$(printf '%s\n' "$resume_values" | sed -n '8p')"
  if [[ $ACTION == assess ]]; then
    printf 'WEBSITE_INTERRUPTED_RECOVERY_FINALIZATION_PENDING version=%s evidence_sha256=%s confirmation=RESTORE-INTERRUPTED-WEBSITE-%s\n' "$resume_version" "$resume_plan_sha" "$resume_version"
    exit 0
  fi
  [[ $EVIDENCE_SHA == "$resume_plan_sha" && $CONFIRMATION == "RESTORE-INTERRUPTED-WEBSITE-$resume_version" ]] \
    || die 'original evidence SHA and version-bound confirmation are required to resume finalization'
  [[ -d $resume_incident && ! -L $resume_incident ]] || die 'recovery incident evidence is unavailable'
  if [[ $resume_kind == interrupted-recovery ]]; then
    [[ -d $resume_attempt && ! -L $resume_attempt ]] || die 'recovery attempt evidence is unavailable'
    resume_completion=interrupted-recovery-progress.completed.json
  elif [[ $resume_kind == activation-failure && -z $resume_attempt ]]; then
    resume_completion=activation-failure-finalization.completed.json
  else
    die 'recovery finalization kind differs'
  fi
  python3 -I "$STATE_TOOL" verify-restored-live --snapshot "$resume_snapshot" --database "$DB" --uploads "$UPLOADS"
  if [[ -n $resume_previous ]]; then
    [[ -L $CURRENT && $(readlink -f -- "$CURRENT") == "$resume_previous" ]] || die 'resumed finalization current differs from restored previous release'
  else
    [[ ! -e $CURRENT && ! -L $CURRENT ]] || die 'resumed first-activation finalization unexpectedly has current'
  fi
  if [[ -e $IN_PROGRESS || -L $IN_PROGRESS ]]; then
    [[ ! -e $resume_incident/activation-in-progress.json && ! -L $resume_incident/activation-in-progress.json ]] || die 'duplicate in-progress archive exists'
    mv -- "$IN_PROGRESS" "$resume_incident/activation-in-progress.json"
    durable_file "$resume_incident/activation-in-progress.json"
  fi
  if [[ -e $RESTORE_FAILED || -L $RESTORE_FAILED ]]; then
    [[ -f $RESTORE_FAILED && ! -L $RESTORE_FAILED && ! -e $resume_incident/activation-restore-failed.json && ! -L $resume_incident/activation-restore-failed.json ]] || die 'restore-failure archive state is unsafe'
    mv -- "$RESTORE_FAILED" "$resume_incident/activation-restore-failed.json"
    durable_file "$resume_incident/activation-restore-failed.json"
  fi
  [[ ! -e $resume_incident/$resume_completion && ! -L $resume_incident/$resume_completion ]] || die 'completed recovery progress archive already exists'
  mv -- "$RECOVERY_PROGRESS" "$resume_incident/$resume_completion"
  durable_file "$resume_incident/$resume_completion"
  durable_directory "$resume_incident"
  durable_directory "$CONTROL"
  if [[ -n $resume_previous ]]; then
    release_state_lock
    systemctl start uten-website.service
    /usr/local/libexec/uten-website/validate-runtime
  else
    systemctl disable --now uten-website-entry-watchdog.timer uten-website.service
  fi
  printf 'WEBSITE_INTERRUPTED_RECOVERY_FINALIZED version=%s marker=%s next=uten-website-recover-assess\n' "$resume_version" "$FAILED"
  exit 0
fi
[[ -f $IN_PROGRESS && ! -L $IN_PROGRESS ]] || die 'durable interrupted-activation evidence is missing'
[[ ! -e $FAILED && ! -L $FAILED ]] || die 'activation-failed evidence already exists; use uten-website-recover'
cmp -s -- "$GATE" "$CLOSED_GATE" || die 'ingress gate is not in the exact closed state'
install -d -m 0700 -o root -g root "$PLANS" "$INCIDENTS"

marker_values="$(python3 -I - "$IN_PROGRESS" <<'PY'
import json,pathlib,re,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); v=json.loads(raw)
if raw != (json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode(): raise SystemExit('marker is not canonical')
expected={'activationId','format','planSha256','previousRelease','snapshot','version'}
if set(v)!=expected or v['format']!='uten-website-activation-in-progress-v1': raise SystemExit('marker contract differs')
if not re.fullmatch(r'\d{8}T\d{6}Z-[0-9a-f]{12}',v['activationId']): raise SystemExit('activation ID differs')
if not re.fullmatch(r'[0-9a-f]{64}',v['planSha256']): raise SystemExit('plan SHA differs')
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?',v['version']): raise SystemExit('version differs')
for key in ('previousRelease','snapshot'):
 if not isinstance(v[key],str) or '\n' in v[key] or '\t' in v[key]: raise SystemExit('unsafe path in marker')
print(v['activationId']); print(v['previousRelease']); print(v['snapshot']); print(v['version']); print(v['planSha256'])
PY
)" || die 'interrupted marker validation failed'
activation_id="$(printf '%s\n' "$marker_values" | sed -n '1p')"
previous="$(printf '%s\n' "$marker_values" | sed -n '2p')"
snapshot="$(printf '%s\n' "$marker_values" | sed -n '3p')"
version="$(printf '%s\n' "$marker_values" | sed -n '4p')"
activation_plan_sha="$(printf '%s\n' "$marker_values" | sed -n '5p')"
if [[ -n $previous ]]; then
  [[ $previous == "$RELEASES/"* && $(dirname -- "$previous") == "$RELEASES" && -d $previous && ! -L $previous ]] \
    || die 'previous immutable release is unavailable'
fi
[[ $snapshot == /var/backups/uten-website/local/$activation_id && -d $snapshot && ! -L $snapshot ]] \
  || die 'marker does not bind the expected paired snapshot'
python3 -I "$STATE_TOOL" verify --snapshot "$snapshot"

start_grant_sha=''
if [[ -e $START_GRANT || -L $START_GRANT ]]; then
  start_grant_sha="$(python3 -I - "$START_GRANT" "$IN_PROGRESS" <<'PY'
import hashlib,json,pathlib,re,stat,sys
def canonical(v): return (json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode()
grant_path=pathlib.Path(sys.argv[1]); marker_path=pathlib.Path(sys.argv[2]); info=grant_path.lstat()
if grant_path.is_symlink() or not grant_path.is_file() or info.st_uid!=0 or info.st_gid!=0 or stat.S_IMODE(info.st_mode)!=0o600 or info.st_nlink!=1: raise SystemExit('unsafe activation start grant')
raw=grant_path.read_bytes(); grant=json.loads(raw); marker_raw=marker_path.read_bytes(); marker=json.loads(marker_raw)
if raw!=canonical(grant): raise SystemExit('activation start grant is not canonical')
keys={'activationId','bootId','currentTarget','databaseSha256','format','inProgressSha256','manifestSha256','planSha256','snapshotManifestSha256','version'}
if set(grant)!=keys or grant.get('format')!='uten-website-activation-start-grant-v1': raise SystemExit('activation start grant contract differs')
if grant['activationId']!=marker['activationId'] or grant['planSha256']!=marker['planSha256'] or grant['version']!=marker['version']: raise SystemExit('activation start grant transaction differs')
if grant['inProgressSha256']!=hashlib.sha256(marker_raw).hexdigest(): raise SystemExit('activation start grant marker digest differs')
if not re.fullmatch(r'[0-9a-f-]{36}',str(grant['bootId'])) or not str(grant['currentTarget']).startswith('/opt/uten-website/releases/') or any(not re.fullmatch(r'[0-9a-f]{64}',str(grant[k])) for k in ('databaseSha256','manifestSha256','snapshotManifestSha256')): raise SystemExit('activation start grant evidence is malformed')
print(hashlib.sha256(raw).hexdigest())
PY
)" || die 'unconsumed activation start grant is unsafe'
fi

live_fingerprint() {
  python3 -I - "$CURRENT" "$DB" "$UPLOADS" <<'PY'
import hashlib,json,os,pathlib,stat,sys
current,db,uploads=map(pathlib.Path,sys.argv[1:])
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
 return h.hexdigest()
def item(path):
 try: info=path.lstat()
 except FileNotFoundError: return {'kind':'missing'}
 if stat.S_ISREG(info.st_mode): return {'kind':'file','sha256':digest(path),'sizeBytes':info.st_size}
 if stat.S_ISDIR(info.st_mode): return {'kind':'directory'}
 if stat.S_ISLNK(info.st_mode): return {'kind':'symlink','target':os.readlink(path)}
 return {'kind':'special','mode':stat.S_IFMT(info.st_mode)}
value={'current':item(current),'database':item(db),'sidecars':{},'uploads':[]}
for suffix in ('-journal','-shm','-wal'):
 value['sidecars'][suffix]=item(pathlib.Path(str(db)+suffix))
if uploads.exists() and uploads.is_dir() and not uploads.is_symlink():
 count=0; total=0
 for root,dirs,files in os.walk(uploads,topdown=True,followlinks=False):
  dirs.sort(); files.sort()
  for name in dirs+files:
   path=pathlib.Path(root)/name; rel=path.relative_to(uploads).as_posix(); evidence=item(path)
   value['uploads'].append({'path':rel,**evidence}); count+=1; total+=int(evidence.get('sizeBytes',0))
   if count>500000 or total>500*1024**3: raise SystemExit('live uploads exceed reviewed evidence limits')
raw=(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
print(hashlib.sha256(raw).hexdigest())
PY
}

current_release="$(readlink -f -- "$CURRENT" 2>/dev/null || true)"
[[ -z $current_release || $current_release == "$RELEASES/"* ]] || die 'current symlink leaves the release root'
live="$(live_fingerprint)" || die 'cannot fingerprint interrupted live state'
if [[ -f $RESTORE_FAILED && ! -L $RESTORE_FAILED ]]; then
  restore_failed_sha="$(sha256sum -- "$RESTORE_FAILED" | awk '{print $1}')"
else
  restore_failed_sha=''
fi
if [[ -f $RECOVERY_PROGRESS && ! -L $RECOVERY_PROGRESS ]]; then
  recovery_progress_sha="$(sha256sum -- "$RECOVERY_PROGRESS" | awk '{print $1}')"
else
  recovery_progress_sha=''
fi
plan=$PLANS/interrupted-$activation_id.json

if [[ $ACTION == assess ]]; then
  MARKER=$IN_PROGRESS SNAPSHOT=$snapshot CURRENT_RELEASE=$current_release LIVE=$live VERSION=$version ACTIVATION_ID=$activation_id RESTORE_FAILED_SHA=$restore_failed_sha RECOVERY_PROGRESS_SHA=$recovery_progress_sha START_GRANT_SHA=$start_grant_sha \
    python3 -I - "$plan.tmp" <<'PY'
import hashlib,json,os,pathlib,sys
d=lambda p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
v={'activationId':os.environ['ACTIVATION_ID'],'currentRelease':os.environ['CURRENT_RELEASE'],'liveStateFingerprintSha256':os.environ['LIVE'],'markerSha256':d(os.environ['MARKER']),'recoveryProgressSha256':os.environ['RECOVERY_PROGRESS_SHA'],'restoreFailureSha256':os.environ['RESTORE_FAILED_SHA'],'snapshotManifestSha256':d(pathlib.Path(os.environ['SNAPSHOT'])/'manifest.json'),'startGrantSha256':os.environ['START_GRANT_SHA'],'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
  publish_root_file "$plan.tmp" "$plan"
  sha="$(sha256sum -- "$plan" | awk '{print $1}')"
  printf 'WEBSITE_INTERRUPTED_RECOVERY_ASSESSED version=%s evidence_sha256=%s previous=%s\n' "$version" "$sha" "$previous"
  exit 0
fi

[[ $EVIDENCE_SHA =~ ^[0-9a-f]{64}$ && $CONFIRMATION == "RESTORE-INTERRUPTED-WEBSITE-$version" ]] \
  || die 'exact evidence SHA and version-bound typed confirmation are required'
[[ -f $plan && ! -L $plan && $(sha256sum -- "$plan" | awk '{print $1}') == "$EVIDENCE_SHA" ]] \
  || die 'interrupted recovery assessment is missing or changed'
PLAN=$plan MARKER=$IN_PROGRESS SNAPSHOT=$snapshot CURRENT_RELEASE=$current_release LIVE=$live VERSION=$version ACTIVATION_ID=$activation_id RESTORE_FAILED_SHA=$restore_failed_sha RECOVERY_PROGRESS_SHA=$recovery_progress_sha START_GRANT_SHA=$start_grant_sha \
  python3 -I - <<'PY'
import hashlib,json,os,pathlib
d=lambda p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
p=pathlib.Path(os.environ['PLAN']); raw=p.read_bytes(); v=json.loads(raw)
expected={'activationId':os.environ['ACTIVATION_ID'],'currentRelease':os.environ['CURRENT_RELEASE'],'liveStateFingerprintSha256':os.environ['LIVE'],'markerSha256':d(os.environ['MARKER']),'recoveryProgressSha256':os.environ['RECOVERY_PROGRESS_SHA'],'restoreFailureSha256':os.environ['RESTORE_FAILED_SHA'],'snapshotManifestSha256':d(pathlib.Path(os.environ['SNAPSHOT'])/'manifest.json'),'startGrantSha256':os.environ['START_GRANT_SHA'],'version':os.environ['VERSION']}
if raw!=(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode() or v!=expected: raise SystemExit('interrupted recovery evidence changed after assessment')
manifest=json.loads((pathlib.Path(os.environ['SNAPSHOT'])/'manifest.json').read_text())
required=int(manifest['database']['sizeBytes'])+int(manifest['uploads']['totalBytes'])+1024**3
state=pathlib.Path('/var/lib/uten-website'); stats=os.statvfs(state); free=stats.f_bavail*stats.f_frsize
if free<required: raise SystemExit(f'insufficient state-volume headroom: need {required}, have {free}')
PY

systemctl stop uten-website.service
work_root=$CONTROL/interrupted-recovery-work/$activation_id
incident_root=$INCIDENTS/$activation_id-interrupted
install -d -m 0700 -o root -g root "$work_root" "$incident_root"
if [[ -f $RECOVERY_PROGRESS && ! -L $RECOVERY_PROGRESS ]]; then
  previous_progress=$work_root/previous-progress-$(sha256sum -- "$RECOVERY_PROGRESS" | awk '{print $1}').json
  [[ ! -e $previous_progress && ! -L $previous_progress ]] || die 'previous recovery progress archive already exists'
  mv -- "$RECOVERY_PROGRESS" "$previous_progress"
  durable_file "$previous_progress"
fi
attempt="$(mktemp -d --tmpdir="$work_root" attempt.XXXXXX)"
chmod 0700 "$attempt"
attempt_name="${attempt##*/}"
incident=$incident_root/$attempt_name
install -d -m 0700 -o root -g root "$incident"
if [[ -n $start_grant_sha ]]; then
  [[ $(sha256sum -- "$START_GRANT" | awk '{print $1}') == "$start_grant_sha" ]] || die 'activation start grant changed before quarantine'
  install -m 0600 -o root -g root "$START_GRANT" "$incident/activation-start-grant.unconsumed.json"
  durable_file "$incident/activation-start-grant.unconsumed.json"
  rm -f -- "$START_GRANT"
fi
restore_dir=$attempt/restored
write_progress() {
  local phase=$1
  ACTIVATION_ID=$activation_id ATTEMPT=$attempt INCIDENT=$incident PHASE=$phase PLAN_SHA=$EVIDENCE_SHA \
    python3 -I - "$RECOVERY_PROGRESS.tmp" <<'PY'
import json,os,pathlib,sys
v={'activationId':os.environ['ACTIVATION_ID'],'attempt':os.environ['ATTEMPT'],'format':'uten-website-interrupted-recovery-progress-v1','incident':os.environ['INCIDENT'],'phase':os.environ['PHASE'],'planSha256':os.environ['PLAN_SHA']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
  publish_root_file "$RECOVERY_PROGRESS.tmp" "$RECOVERY_PROGRESS"
}
write_progress planned
python3 -I "$STATE_TOOL" restore --snapshot "$snapshot" --destination "$restore_dir"
write_progress snapshot-restored
[[ ! -e $DB && ! -L $DB ]] || mv -- "$DB" "$incident/website.db.interrupted"
for suffix in -journal -shm -wal; do
  sidecar=$DB$suffix
  [[ ! -e $sidecar && ! -L $sidecar ]] || mv -- "$sidecar" "$incident/website.db$suffix.interrupted"
done
[[ ! -e $UPLOADS && ! -L $UPLOADS ]] || mv -- "$UPLOADS" "$incident/uploads.interrupted"
write_progress live-quarantined
mv -- "$restore_dir/website.db" "$DB"
mv -- "$restore_dir/uploads" "$UPLOADS"
mv -- "$restore_dir/restore-receipt.json" "$incident/restore-receipt.json"
rmdir -- "$restore_dir"
chown uten-website:uten-website "$DB"
chmod 0600 "$DB"
chown -R uten-website:uten-website-media "$UPLOADS"
find "$UPLOADS" -type d -exec chmod 2750 {} +
find "$UPLOADS" -type f -exec chmod 0640 {} +
if [[ -n $previous ]]; then
  current_candidate=$CURRENT.interrupted-$activation_id-$attempt_name
  [[ ! -e $current_candidate && ! -L $current_candidate ]] || die 'attempt-unique current candidate already exists'
  ln -s -- "$previous" "$current_candidate"
  mv -Tf -- "$current_candidate" "$CURRENT"
elif [[ -L $CURRENT ]]; then
  mv -- "$CURRENT" "$incident/current.interrupted-link"
fi
durable_directory "$STATE"
durable_directory "$incident"
durable_directory "$(dirname -- "$incident")"
durable_directory "$CONTROL"
durable_directory /opt/uten-website
python3 -I "$STATE_TOOL" verify-restored-live --snapshot "$snapshot" --database "$DB" --uploads "$UPLOADS"
if [[ -n $previous ]]; then
  [[ -L $CURRENT && $(readlink -f -- "$CURRENT") == "$previous" ]] || die 'restored current link is not durable/consistent'
else
  [[ ! -e $CURRENT && ! -L $CURRENT ]] || die 'first activation restore left an unexpected current link'
  systemctl disable --now uten-website-entry-watchdog.timer uten-website.service
fi
write_progress restored-verified

VERSION=$version PLAN_SHA=$activation_plan_sha SNAPSHOT=$snapshot PREVIOUS=$previous \
  python3 -I - "$FAILED.tmp" <<'PY'
import json,os,pathlib,sys
v={'failureReason':'host interruption after paired snapshot and before durable activation completion','format':'uten-website-activation-failed-v1','planSha256':os.environ['PLAN_SHA'],'previousRelease':os.environ['PREVIOUS'],'snapshot':os.environ['SNAPSHOT'],'status':125,'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$FAILED.tmp" "$FAILED"
mv -- "$IN_PROGRESS" "$incident/activation-in-progress.json"
durable_file "$incident/activation-in-progress.json"
if [[ -f $RESTORE_FAILED && ! -L $RESTORE_FAILED ]]; then
  mv -- "$RESTORE_FAILED" "$incident/activation-restore-failed.json"
  durable_file "$incident/activation-restore-failed.json"
fi
mv -- "$RECOVERY_PROGRESS" "$incident/interrupted-recovery-progress.completed.json"
durable_file "$incident/interrupted-recovery-progress.completed.json"
durable_directory "$CONTROL"
if [[ -n $previous ]]; then
  release_state_lock
  systemctl start uten-website.service
  /usr/local/libexec/uten-website/validate-runtime
  curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health \
    | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)=={"status":"ok"} else 1)' \
    || die 'restored service is not ready; ingress remains closed'
fi
printf 'WEBSITE_INTERRUPTED_RECOVERY_RESTORED version=%s marker=%s next=uten-website-recover-assess\n' "$version" "$FAILED"
