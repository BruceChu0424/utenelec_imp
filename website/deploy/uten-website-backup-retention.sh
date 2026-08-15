#!/usr/bin/env bash
# Root-controlled pruning; daily append-only writer never receives delete authority.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
readonly LOCAL=/var/backups/uten-website/local
readonly RECEIPTS=/var/backups/uten-website/receipts
readonly ENV_FILE=/etc/uten-website/restic-retention.env
readonly AUDIT=/var/backups/uten-website/retention-receipts
readonly LOCK=/run/uten-website-release/backup-repository.lock
readonly LOCK_TOOL=/usr/local/libexec/uten-website/open_root_lock.py
die() { printf 'WEBSITE_RETENTION_REFUSED: %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die 'must run as root'
[[ $# -eq 2 && $1 == --confirmation && $2 == PRUNE-WEBSITE-RECOVERY-POINTS ]] \
  || die 'exact typed confirmation is required'
[[ -f $ENV_FILE && ! -L $ENV_FILE && $(stat -c '%U:%G:%a:%h' "$ENV_FILE") == root:root:600:1 ]] \
  || die 'separate restic retention environment must be root:root 0600 with one link'
python3 -I "$LOCK_TOOL" "$LOCK" || die 'backup lock file is unsafe'
exec 9<>"$LOCK"; flock -n 9 || die 'backup/retention lock is held'
install -d -m 0700 -o root -g root "$AUDIT"

candidates="$(python3 -I - "$LOCAL" "$RECEIPTS" <<'PY'
import hashlib,json,pathlib,re,sys
local=pathlib.Path(sys.argv[1]); receipts=pathlib.Path(sys.argv[2]); valid=[]
for receipt in receipts.glob('*.json') if receipts.is_dir() else []:
 try:
  if receipt.is_symlink() or not receipt.is_file() or receipt.stat().st_nlink!=1: continue
  raw=receipt.read_bytes(); value=json.loads(raw)
  if raw != (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode() or value.get('format')!='uten-website-offsite-backup-receipt-v1': continue
  match=re.fullmatch(r'(\d{8})T\d{6}Z-[0-9a-f]{12}',value.get('snapshotId',''))
  if not match or receipt.name!=value['snapshotId']+'.json': continue
  point=local/value['snapshotId']; manifest=point/'manifest.json'
  if point.is_symlink() or not point.is_dir() or point.parent!=local or manifest.is_symlink() or not manifest.is_file(): continue
  if hashlib.sha256(manifest.read_bytes()).hexdigest()!=value.get('localManifestSha256'): continue
  valid.append((match.group(1),value['snapshotId']))
 except (OSError,ValueError,TypeError): pass
days=sorted({day for day,_ in valid},reverse=True)
if len(days)<8: raise SystemExit('need at least eight distinct successful days before any pruning')
keep=set(days[:7])
for day,snapshot_id in sorted(valid):
 if day not in keep: print(snapshot_id)
PY
)" || die 'cannot prove seven successful daily recovery points'
[[ -n $candidates ]] || die 'no recovery point is eligible for pruning'

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ ${UTEN_WEBSITE_RESTIC_RETENTION:-} == true ]] || die 'retention credential acknowledgement is absent'
restic forget --dry-run --tag uten-website --keep-daily 7
restic forget --tag uten-website --keep-daily 7 --prune

candidate_file="$(mktemp --tmpdir="$AUDIT" .candidates.XXXXXX)"
printf '%s\n' "$candidates" >"$candidate_file"
python3 -I - "$LOCAL" "$RECEIPTS" "$candidate_file" <<'PY'
import os,pathlib,re,shutil,sys
local=pathlib.Path(sys.argv[1]).resolve(); receipts=pathlib.Path(sys.argv[2]).resolve()
ids=pathlib.Path(sys.argv[3]).read_text().splitlines()
if not ids: raise SystemExit('empty retention candidate set')
for snapshot_id in ids:
 if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}',snapshot_id): raise SystemExit('unsafe retention id')
 point=local/snapshot_id; receipt=receipts/(snapshot_id+'.json')
 if point.parent!=local or point.is_symlink() or not point.is_dir(): raise SystemExit('unsafe local recovery point')
 if receipt.parent!=receipts or receipt.is_symlink() or not receipt.is_file(): raise SystemExit('unsafe recovery receipt')
 shutil.rmtree(point); receipt.unlink()
for directory in (local,receipts):
 descriptor=os.open(directory,os.O_RDONLY)
 try: os.fsync(descriptor)
 finally: os.close(descriptor)
PY
audit_id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6)"
CANDIDATES=$candidates python3 -I - "$AUDIT/$audit_id.json.tmp" <<'PY'
import json,os,pathlib,sys
v={'deletedLocalRecoveryPoints':os.environ['CANDIDATES'].splitlines(),'format':'uten-website-retention-receipt-v1','keptSuccessfulDailyPoints':7}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
install -m 0600 -o root -g root "$AUDIT/$audit_id.json.tmp" "$AUDIT/$audit_id.json"
python3 -I - "$AUDIT/$audit_id.json" <<'PY'
import os,pathlib,sys
p=pathlib.Path(sys.argv[1]); fd=os.open(p,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
fd=os.open(p.parent,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
PY
rm -f -- "$AUDIT/$audit_id.json.tmp" "$candidate_file"
printf 'WEBSITE_RETENTION_OK receipt=%s deleted=%s\n' "$AUDIT/$audit_id.json" "$(printf '%s\n' "$candidates" | wc -l)"
