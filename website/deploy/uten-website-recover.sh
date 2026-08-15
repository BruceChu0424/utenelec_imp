#!/usr/bin/env bash
# Evidence-driven reopening after activation failure. Never remove the marker.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly STATE=/var/lib/uten-website/runtime
readonly CONTROL=/var/lib/uten-website/control
readonly MARKER=$CONTROL/activation-failed.json
readonly IN_PROGRESS=$CONTROL/activation-in-progress.json
readonly RESTORE_FAILED=$CONTROL/activation-restore-failed.json
readonly RECOVERY_PROGRESS=$CONTROL/interrupted-recovery-in-progress.json
readonly START_GRANT=/run/uten-website-release/activation-start.json
readonly PLANS=$CONTROL/recovery-plans
readonly ARCHIVE=$CONTROL/incidents/recovered-markers
readonly CURRENT=/opt/uten-website/current
readonly GATE=/etc/nginx/snippets/uten-website-gate.conf
readonly OPEN_GATE=/usr/local/libexec/uten-website/uten-website-gate.open.conf
readonly CLOSED_GATE=/usr/local/libexec/uten-website/uten-website-gate.closed.conf
readonly STATE_TOOL=/usr/local/libexec/uten-website/paired_state.py
readonly BOOT_GUARD=/usr/local/libexec/uten-website/uten-website-boot-guard
readonly STORAGE_CHECK=/usr/local/libexec/uten-website/validate-storage
readonly LOCK=/run/uten-website-release/activation.lock
readonly STATE_LOCK=/run/uten-website-release/state-mutation.lock
readonly LOCK_TOOL=/usr/local/libexec/uten-website/open_root_lock.py

die() { printf 'WEBSITE_RECOVERY_REFUSED: %s\n' "$*" >&2; exit 1; }
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
state_lock_held=false
acquire_state_lock() {
  if ! $state_lock_held; then
    python3 -I "$LOCK_TOOL" "$STATE_LOCK" || die 'state-mutation lock file is unsafe'
    exec 8<>"$STATE_LOCK"
    flock -n 8 || die 'backup or another recovery owns the state-mutation lock'
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
[[ $# -ge 1 ]] || die 'usage: uten-website-recover assess | apply --evidence-sha SHA --confirmation REOPEN-RESTORED-WEBSITE'
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
python3 -I "$LOCK_TOOL" "$LOCK" || die 'activation/recovery lock file is unsafe'
exec 9<>"$LOCK"
flock -n 9 || die 'activation/recovery lock is held'
acquire_state_lock
if ! "$STORAGE_CHECK"; then
  "$BOOT_GUARD" close || systemctl stop nginx.service || true
  die 'authoritative state/backup storage identity failed after the mutation lock was acquired'
fi
[[ -f $MARKER && ! -L $MARKER ]] || die 'activation failure marker is missing'
[[ ! -e $IN_PROGRESS && ! -L $IN_PROGRESS && ! -e $RESTORE_FAILED && ! -L $RESTORE_FAILED && \
   ! -e $RECOVERY_PROGRESS && ! -L $RECOVERY_PROGRESS && ! -e $START_GRANT && ! -L $START_GRANT ]] \
  || die 'another activation/recovery marker or one-time start grant still blocks normal recovery'
cmp -s -- "$GATE" "$CLOSED_GATE" || die 'ingress gate is not in the exact closed state'
install -d -m 0700 -o root -g root "$PLANS" "$ARCHIVE"

marker_values="$(python3 -I - "$MARKER" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); raw=p.read_bytes(); v=json.loads(raw)
if raw != (json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode(): raise SystemExit('marker is not canonical')
if set(v) != {'failureReason','format','planSha256','previousRelease','snapshot','status','version'} or v['format']!='uten-website-activation-failed-v1': raise SystemExit('marker contract differs')
for key in ('previousRelease','snapshot','version'):
 if '\n' in str(v[key]) or '\t' in str(v[key]): raise SystemExit('unsafe marker value')
print(v['previousRelease']); print(v['snapshot']); print(v['version'])
PY
)" || die 'activation marker validation failed'
previous="$(printf '%s\n' "$marker_values" | sed -n '1p')"
snapshot="$(printf '%s\n' "$marker_values" | sed -n '2p')"
version="$(printf '%s\n' "$marker_values" | sed -n '3p')"
if [[ -n $previous ]]; then
  [[ $previous == /opt/uten-website/releases/* && $(dirname -- "$previous") == /opt/uten-website/releases && -d $previous ]] \
    || die 'marker previous release is unavailable'
fi
[[ -d $snapshot && ! -L $snapshot ]] || die 'marker paired snapshot is unavailable'
python3 -I "$STATE_TOOL" verify --snapshot "$snapshot"
if [[ -n $previous ]]; then
  [[ -L $CURRENT && $(readlink -f -- "$CURRENT") == "$previous" ]] || die 'current does not point at the restored previous release'
  if ! systemctl is-active --quiet uten-website.service; then
    release_state_lock
    systemctl start uten-website.service
    acquire_state_lock
  fi
  systemctl is-active --quiet uten-website.service || die 'restored previous service is not active'
  /usr/local/libexec/uten-website/validate-runtime
  curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health \
    | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)=={"status":"ok"} else 1)' \
    || die 'restored previous release is not ready'
else
  [[ ! -e $CURRENT && ! -L $CURRENT ]] || die 'first activation recovery must leave current absent'
  ! systemctl is-active --quiet uten-website.service || die 'first activation recovery must leave the service stopped'
fi

live_evidence="$(python3 -I - "$snapshot/manifest.json" /var/lib/uten-website/runtime/website.db /var/lib/uten-website/runtime/uploads <<'PY'
import hashlib,json,os,pathlib,sys
manifest=json.load(open(sys.argv[1],encoding='utf-8'))
def digest(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for c in iter(lambda:f.read(1024*1024),b''):h.update(c)
 return h.hexdigest()
if digest(sys.argv[2]) != manifest['database']['sha256']: raise SystemExit('live database differs from restored snapshot')
actual=[]
for root,dirs,files in os.walk(sys.argv[3],followlinks=False):
 dirs.sort(); files.sort()
 for name in files:
  p=pathlib.Path(root)/name; rel=p.relative_to(sys.argv[3]).as_posix()
  actual.append({'path':rel,'sha256':digest(p),'sizeBytes':p.stat().st_size})
if actual != manifest['uploads']['files']: raise SystemExit('live uploads differ from restored snapshot')
print(hashlib.sha256((json.dumps({'database':manifest['database']['sha256'],'uploads':actual},sort_keys=True,separators=(',',':'))+'\n').encode()).hexdigest())
PY
)" || die 'live paired-state evidence differs from recovery point'

plan=$PLANS/$version.json
if [[ $ACTION == assess ]]; then
  MARKER=$MARKER SNAPSHOT=$snapshot PREVIOUS=$previous LIVE=$live_evidence VERSION=$version \
    python3 -I - "$plan.tmp" <<'PY'
import hashlib,json,os,pathlib,sys
d=lambda p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
v={'currentRelease':os.environ['PREVIOUS'],'liveStateEvidenceSha256':os.environ['LIVE'],'markerSha256':d(os.environ['MARKER']),'snapshotManifestSha256':d(pathlib.Path(os.environ['SNAPSHOT'])/'manifest.json'),'version':os.environ['VERSION']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
  install -m 0600 -o root -g root "$plan.tmp" "$plan"
  durable_file "$plan"
  rm -f -- "$plan.tmp"
  sha="$(sha256sum -- "$plan" | awk '{print $1}')"
  printf 'WEBSITE_RECOVERY_ASSESSED version=%s evidence_sha256=%s previous=%s\n' "$version" "$sha" "$previous"
  exit 0
fi

[[ $ACTION == apply ]] || die 'action must be assess or apply'
if [[ -n $previous ]]; then
  expected_confirmation=REOPEN-RESTORED-WEBSITE
else
  expected_confirmation=ACKNOWLEDGE-RESTORED-FIRST-WEBSITE-ACTIVATION
fi
[[ $EVIDENCE_SHA =~ ^[0-9a-f]{64}$ && $CONFIRMATION == "$expected_confirmation" ]] \
  || die 'exact evidence SHA and context-bound typed confirmation are required'
[[ -f $plan && ! -L $plan ]] || die 'recovery assessment plan is missing'
[[ $(sha256sum -- "$plan" | awk '{print $1}') == "$EVIDENCE_SHA" ]] || die 'recovery evidence SHA differs'
PLAN=$plan MARKER=$MARKER SNAPSHOT=$snapshot PREVIOUS=$previous LIVE=$live_evidence VERSION=$version \
  python3 -I - <<'PY'
import hashlib,json,os,pathlib
d=lambda p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
p=pathlib.Path(os.environ['PLAN']); raw=p.read_bytes(); v=json.loads(raw)
expected={'currentRelease':os.environ['PREVIOUS'],'liveStateEvidenceSha256':os.environ['LIVE'],'markerSha256':d(os.environ['MARKER']),'snapshotManifestSha256':d(pathlib.Path(os.environ['SNAPSHOT'])/'manifest.json'),'version':os.environ['VERSION']}
if raw != (json.dumps(v,sort_keys=True,separators=(',',':'))+'\n').encode() or v != expected: raise SystemExit('recovery evidence changed after assessment')
PY

archive_name=$ARCHIVE/$(date -u +%Y%m%dT%H%M%SZ)-$version.json
archive_created=false
recovery_succeeded=false
restore_marker_on_failure() {
  status=$?
  trap - ERR EXIT
  set +e
  if $archive_created && ! $recovery_succeeded && [[ ! -e $MARKER && ! -L $MARKER && -f $archive_name && ! -L $archive_name ]]; then
    mv -- "$archive_name" "$MARKER"
    durable_file "$MARKER"
  fi
  "$BOOT_GUARD" close >/dev/null 2>&1 || systemctl stop nginx.service >/dev/null 2>&1 || true
  exit "$status"
}
trap restore_marker_on_failure ERR EXIT
mv -- "$MARKER" "$archive_name"
chmod 0600 "$archive_name"
durable_file "$archive_name"
archive_created=true
python3 -I - "$CONTROL" <<'PY'
import os,sys
fd=os.open(sys.argv[1],os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
PY
if [[ -n $previous ]]; then
  release_state_lock
  "$BOOT_GUARD" recover-ready
  cmp -s -- "$GATE" "$OPEN_GATE" || die 'full signed recovery validation did not durably open the exact reviewed gate'
  recovery_succeeded=true
  trap - ERR EXIT
  printf 'WEBSITE_RECOVERY_OK version=%s archived_marker=%s\n' "$version" "$archive_name"
else
  cmp -s -- "$GATE" "$CLOSED_GATE" || die 'first activation recovery unexpectedly changed the closed gate'
  systemctl disable --now uten-website-entry-watchdog.timer uten-website.service
  recovery_succeeded=true
  trap - ERR EXIT
  printf 'WEBSITE_FIRST_ACTIVATION_STATE_RESTORED version=%s archived_marker=%s next=repeat-reviewed-activation\n' "$version" "$archive_name"
fi
