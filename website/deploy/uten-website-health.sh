#!/usr/bin/env bash
# Local readiness, capacity and recovery-point monitor. External routing watches failures.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
readonly STATE=/var/lib/uten-website/runtime
readonly CONTROL=/var/lib/uten-website/control
readonly STATUS=$CONTROL/monitor/status.json
readonly ALERTS=$CONTROL/monitor/alerts
readonly RECEIPTS=/var/backups/uten-website/receipts
readonly LOCAL_BACKUPS=/var/backups/uten-website/local
readonly MAX_AGE_SECONDS=129600
readonly AUTOMATION_CHECK=/usr/local/libexec/uten-website/validate-automation-enabled
readonly GATE=/etc/nginx/snippets/uten-website-gate.conf
readonly OPEN_GATE=/usr/local/libexec/uten-website/uten-website-gate.open.conf
readonly START_GRANT=/run/uten-website-release/activation-start.json
reason=''
fail() { reason="${reason}${reason:+; }$1"; }
[[ ${EUID} -eq 0 ]] || { printf '%s\n' 'WEBSITE_MONITOR_REFUSED: must run as root' >&2; exit 1; }
[[ $# -le 1 && ($# -eq 0 || $1 == --commissioning-preflight) ]] \
  || { printf '%s\n' 'WEBSITE_MONITOR_REFUSED: unknown arguments' >&2; exit 1; }
if [[ $# -eq 0 ]]; then
  python3 -I "$AUTOMATION_CHECK" || fail 'automation commissioning evidence is invalid'
fi
for blocker in \
  "$CONTROL/activation-failed.json" "$CONTROL/activation-in-progress.json" \
  "$CONTROL/activation-restore-failed.json" "$CONTROL/interrupted-recovery-in-progress.json" \
  "$START_GRANT"; do
  [[ ! -e $blocker && ! -L $blocker ]] || fail "activation/recovery evidence exists: $blocker"
done
[[ ! -e $CONTROL/backup-failed.json ]] || fail 'backup-failed marker exists'
systemctl is-active --quiet uten-website.service || fail 'website service is not active'
systemctl is-active --quiet nginx.service || fail 'Nginx service is not active'
for unit in nginx.service uten-website-boot-gate.service uten-website.service uten-website-entry-watchdog.timer; do
  systemctl is-enabled --quiet "$unit" || fail "core autostart is disabled: $unit"
done
cmp -s -- "$GATE" "$OPEN_GATE" || fail 'Nginx entry gate is not exactly open'
nginx -t >/dev/null 2>&1 || fail 'Nginx configuration test failed'
[[ $(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true) == yes ]] || fail 'system clock is not NTP-synchronized'
if ! curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health \
  | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)=={"status":"ok"} else 1)'; then
  fail 'website readiness endpoint failed'
fi
for path in /var/lib/uten-website /var/backups/uten-website; do
  used="$(df -P "$path" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  inodes="$(df -Pi "$path" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  [[ $used =~ ^[0-9]+$ && $used -lt 80 ]] || fail "disk usage is at least 80% on $path"
  [[ $inodes =~ ^[0-9]+$ && $inodes -lt 80 ]] || fail "inode usage is at least 80% on $path"
done
backup_evidence="$(python3 -I - "$RECEIPTS" "$LOCAL_BACKUPS" "$MAX_AGE_SECONDS" <<'PY'
import datetime,hashlib,json,pathlib,re,sys,time
root=pathlib.Path(sys.argv[1]); local=pathlib.Path(sys.argv[2]); max_age=int(sys.argv[3]); valid=[]
for path in root.glob('*.json') if root.is_dir() else []:
 try:
  raw=path.read_bytes(); value=json.loads(raw)
  if raw != (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode(): continue
  if path.is_symlink() or path.stat().st_nlink!=1 or value.get('format')!='uten-website-offsite-backup-receipt-v1': continue
  m=re.fullmatch(r'(\d{8})T(\d{6})Z-[0-9a-f]{12}',value.get('snapshotId',''))
  if not m or path.name != value['snapshotId']+'.json' or not re.fullmatch(r'[0-9a-f]{64}',value.get('resticSnapshotId','')): continue
  manifest=local/value['snapshotId']/'manifest.json'
  if manifest.is_symlink() or not manifest.is_file() or hashlib.sha256(manifest.read_bytes()).hexdigest()!=value.get('localManifestSha256'): continue
  created=datetime.datetime.strptime(m.group(1)+m.group(2),'%Y%m%d%H%M%S').replace(tzinfo=datetime.timezone.utc).timestamp()
  valid.append((created,m.group(1),value['snapshotId']))
 except (OSError,ValueError,KeyError): pass
if not valid: raise SystemExit('no valid offsite backup receipt')
latest=max(valid)
if latest[0]>time.time()+300 or time.time()-latest[0] > max_age: raise SystemExit('latest successful offsite recovery point is future-dated or older than 36 hours')
if len({item[1] for item in valid}) < 7: raise SystemExit('fewer than seven distinct successful daily recovery points')
print(latest[2])
PY
)" || fail 'offsite recovery-point freshness/retention gate failed'
install -d -m 0700 -o root -g root "$(dirname "$STATUS")" "$ALERTS"
REASON=$reason BACKUP=$backup_evidence python3 -I - "$STATUS.tmp" <<'PY'
import json,os,pathlib,sys
v={'backupRecoveryPoint':os.environ['BACKUP'],'format':'uten-website-monitor-v1','reason':os.environ['REASON'],'status':'ok' if not os.environ['REASON'] else 'failed'}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
install -m 0600 -o root -g root "$STATUS.tmp" "$STATUS"
python3 -I - "$STATUS" <<'PY'
import os,pathlib,sys
p=pathlib.Path(sys.argv[1]); fd=os.open(p,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
fd=os.open(p.parent,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
PY
rm -f -- "$STATUS.tmp"
if [[ -n $reason ]]; then
  alert=$ALERTS/$(date -u +%Y%m%dT%H%M%SZ)-$$.json
  install -m 0600 -o root -g root "$STATUS" "$alert"
  python3 -I - "$alert" <<'PY'
import os,pathlib,sys
p=pathlib.Path(sys.argv[1]); fd=os.open(p,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
fd=os.open(p.parent,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
PY
  systemd-cat -t uten-website-monitor -p err -- "website production gate failed: $reason"
  printf 'WEBSITE_MONITOR_FAILED: %s alert=%s\n' "$reason" "$alert" >&2
  exit 1
fi
printf 'WEBSITE_MONITOR_OK backup=%s\n' "$backup_evidence"
