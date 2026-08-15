#!/usr/bin/env bash
# Short stop-the-world snapshot so SQLite rows and local CMS media form one point.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

readonly STATE=/var/lib/uten-website/runtime
readonly CONTROL=/var/lib/uten-website/control
readonly DB=$STATE/website.db
readonly UPLOADS=$STATE/uploads
readonly LOCAL=/var/backups/uten-website/local
readonly RECEIPTS=/var/backups/uten-website/receipts
readonly TOOL=/usr/local/libexec/uten-website/paired_state.py
readonly BOOT_GUARD=/usr/local/libexec/uten-website/uten-website-boot-guard
readonly GATE=/etc/nginx/snippets/uten-website-gate.conf
readonly OPEN_GATE=/usr/local/libexec/uten-website/uten-website-gate.open.conf
readonly CLOSED_GATE=/usr/local/libexec/uten-website/uten-website-gate.closed.conf
readonly RESTIC_ENV=/etc/uten-website/restic-append-only.env
readonly FAILURE=$CONTROL/backup-failed.json
readonly LOCK=/run/uten-website-release/backup-repository.lock
readonly STATE_LOCK=/run/uten-website-release/state-mutation.lock
readonly LOCK_TOOL=/usr/local/libexec/uten-website/open_root_lock.py
readonly AUTOMATION_CHECK=/usr/local/libexec/uten-website/validate-automation-enabled
readonly STORAGE_CHECK=/usr/local/libexec/uten-website/validate-storage
readonly START_GRANT=/run/uten-website-release/activation-start.json
readonly CURRENT=/opt/uten-website/current

die() { printf 'WEBSITE_BACKUP_REFUSED: %s\n' "$*" >&2; exit 1; }
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
precommission=false
if [[ $# -eq 0 ]]; then
  :
elif [[ $# -eq 3 && $1 == --precommission && $2 == --confirmation && $3 == CREATE-PRECOMMISSION-WEBSITE-RECOVERY-POINT ]]; then
  precommission=true
  [[ $(systemctl is-enabled uten-website-backup.timer 2>/dev/null || true) == disabled && \
     $(systemctl is-active uten-website-backup.timer 2>/dev/null || true) == inactive && \
     ! -e $CONTROL/commissioning/automation-enabled.json && ! -L $CONTROL/commissioning/automation-enabled.json && \
     ! -e $CONTROL/commissioning/automation-in-progress.json && ! -L $CONTROL/commissioning/automation-in-progress.json ]] \
    || die 'precommission backup requires disabled timer and no commissioning marker'
else
  die 'usage: uten-website-paired-backup [--precommission --confirmation CREATE-PRECOMMISSION-WEBSITE-RECOVERY-POINT]'
fi
# Never mint a recovery-point receipt from a snapshot that is not yet bound to
# the signed schema, database authority, exact references/ledger and recovered
# media state.  This is intentionally before locks, service stops or writes.
die 'production paired backup source NO-GO: semantic snapshot binding and interrupted-media recovery are not yet closed'
for blocker in \
  "$CONTROL/activation-failed.json" "$CONTROL/activation-in-progress.json" \
  "$CONTROL/activation-restore-failed.json" "$CONTROL/interrupted-recovery-in-progress.json" \
  "$START_GRANT"; do
  [[ ! -e $blocker && ! -L $blocker ]] || die "activation/recovery evidence must finish before backup: $blocker"
done
[[ -x $TOOL && -f $RESTIC_ENV && ! -L $RESTIC_ENV ]] || die 'paired-state tool or append-only restic environment is missing'
[[ $(stat -c '%U:%G:%a:%h' "$RESTIC_ENV") == root:root:600:1 ]] || die 'restic append-only environment must be root:root 0600 with one link'
python3 -I "$LOCK_TOOL" "$LOCK" || die 'backup lock file is unsafe'
exec 9<>"$LOCK"; flock -n 9 || die 'backup lock is held'
python3 -I "$LOCK_TOOL" "$STATE_LOCK" || die 'state-mutation lock file is unsafe'
exec 8<>"$STATE_LOCK"; flock -n 8 || die 'state-mutation lock is held'
if ! "$STORAGE_CHECK"; then
  "$BOOT_GUARD" close || systemctl stop nginx.service || true
  die 'authoritative state/backup storage identity failed after the mutation lock was acquired'
fi
install -d -m 0700 -o root -g root "$LOCAL" "$RECEIPTS"

bootstrap_precommission=false
if $precommission && [[ ! -e $CURRENT && ! -L $CURRENT ]]; then
  [[ $(systemctl is-enabled uten-website.service 2>/dev/null || true) == disabled && \
     $(systemctl is-active uten-website.service 2>/dev/null || true) == inactive && \
     $(systemctl is-enabled uten-website-entry-watchdog.timer 2>/dev/null || true) == disabled && \
     $(systemctl is-active uten-website-entry-watchdog.timer 2>/dev/null || true) == inactive && \
     -f $GATE && ! -L $GATE && -f $CLOSED_GATE && ! -L $CLOSED_GATE ]] \
    || die 'first-host recovery point requires app/watchdog disabled and an exact closed gate'
  cmp -s -- "$GATE" "$CLOSED_GATE" || die 'first-host recovery point requires exact closed ingress'
  bootstrap_precommission=true
fi

health() {
  curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health \
    | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)=={"status":"ok"} else 1)'
}
write_failure() {
  REASON=$1 python3 -I - "$FAILURE.tmp" <<'PY'
import json,os,pathlib,sys
v={'format':'uten-website-backup-failed-v1','reason':os.environ['REASON']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
  publish_root_file "$FAILURE.tmp" "$FAILURE"
}

quiesced=false
state_lock_held=true
release_state_lock() {
  if $state_lock_held; then
    flock -u 8
    exec 8>&-
    state_lock_held=false
  fi
}
on_exit() {
  status=$?
  trap - EXIT ERR
  if $quiesced; then
    release_state_lock || true
    if $bootstrap_precommission; then
      "$BOOT_GUARD" close || systemctl stop nginx.service || true
    else
      systemctl start uten-website.service || true
      if health; then "$BOOT_GUARD" backup-ready || "$BOOT_GUARD" close || true; else "$BOOT_GUARD" close || true; fi
    fi
  fi
  if (( status != 0 )); then
    write_failure "paired/offsite backup command failed with status $status" || true
    printf 'WEBSITE_BACKUP_FAILED: durable marker=%s\n' "$FAILURE" >&2
  fi
  exit "$status"
}
trap on_exit EXIT ERR

id="$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 6)"
snapshot=$LOCAL/$id
quiescence=$LOCAL/.$id.quiescence.json
"$BOOT_GUARD" close
systemctl stop uten-website.service
[[ $(systemctl is-active uten-website.service || true) == inactive ]] || die 'website did not stop for paired snapshot'
quiesced=true
nonce="$(openssl rand -hex 16)"
DB=$DB UPLOADS=$UPLOADS NONCE=$nonce python3 -I - "$quiescence.tmp" <<'PY'
import json,os,pathlib,sys
v={'database':os.environ['DB'],'gateClosed':True,'nonce':os.environ['NONCE'],'serviceStopped':True,'uploads':os.environ['UPLOADS']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$quiescence.tmp" "$quiescence"
python3 -I "$TOOL" snapshot --database "$DB" --uploads "$UPLOADS" --output "$snapshot" --snapshot-id "$id" --quiescence-receipt "$quiescence"
rm -f -- "$quiescence"
release_state_lock
if $bootstrap_precommission; then
  "$BOOT_GUARD" close
  cmp -s -- "$GATE" "$CLOSED_GATE" || die 'first-host backup did not preserve the exact closed gate'
else
  systemctl start uten-website.service
  for _ in {1..20}; do health && break; sleep 1; done
  health || die 'website did not recover after local snapshot; ingress stays closed'
  "$BOOT_GUARD" backup-ready
  cmp -s -- "$GATE" "$OPEN_GATE" || die 'full signed post-backup gate did not load the exact open template'
fi
quiesced=false

# restic encryption is mandatory. The credential represented by this file must
# be append-only at the remote repository; pruning uses a different root-only
# credential and is never part of this daily writer.
set -a
# shellcheck disable=SC1090
source "$RESTIC_ENV"
set +a
[[ ${UTEN_WEBSITE_RESTIC_APPEND_ONLY:-} == true ]] || die 'append-only restic acknowledgement is absent'
json_output="$(mktemp --tmpdir="$LOCAL" .restic-output.XXXXXX)"
restic backup --json --tag uten-website --tag "recovery-point:$id" "$snapshot" >"$json_output"
snapshot_sha="$(sha256sum -- "$snapshot/manifest.json" | awk '{print $1}')"
restic_snapshot="$(python3 -I - "$json_output" <<'PY'
import json,sys
summary=None
for line in open(sys.argv[1],encoding='utf-8'):
 value=json.loads(line)
 if value.get('message_type')=='summary': summary=value
if not summary or not summary.get('snapshot_id'): raise SystemExit('restic summary has no snapshot_id')
print(summary['snapshot_id'])
PY
)"
rm -f -- "$json_output"
ID=$id RESTIC=$restic_snapshot MANIFEST=$snapshot_sha python3 -I - "$RECEIPTS/$id.json.tmp" <<'PY'
import json,os,pathlib,sys
v={'format':'uten-website-offsite-backup-receipt-v1','localManifestSha256':os.environ['MANIFEST'],'resticSnapshotId':os.environ['RESTIC'],'snapshotId':os.environ['ID']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(v,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
publish_root_file "$RECEIPTS/$id.json.tmp" "$RECEIPTS/$id.json"
[[ ! -e $FAILURE ]] || mv -- "$FAILURE" "$RECEIPTS/$id.previous-failure.json"
trap - EXIT ERR
printf 'WEBSITE_BACKUP_OK id=%s restic_snapshot=%s receipt=%s\n' "$id" "$restic_snapshot" "$RECEIPTS/$id.json"
