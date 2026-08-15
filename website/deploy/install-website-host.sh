#!/usr/bin/env bash
# Fresh-host installer. Run only after the documented read-only server audit.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
die() { printf 'WEBSITE_INSTALL_REFUSED: %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die 'must run as root'
[[ $# -eq 16 && $1 == --allowed-signers && $3 == --nginx-worker-user && \
   $5 == --expected-state-uuid && $7 == --expected-state-fstype && \
   $9 == --expected-backup-uuid && $11 == --expected-backup-fstype && \
   $13 == --expected-database-authority-uuid && $15 == --confirmation ]] \
  || die 'usage: install-website-host.sh --allowed-signers FILE --nginx-worker-user OBSERVED_USER --expected-state-uuid UUID --expected-state-fstype ext4|xfs --expected-backup-uuid UUID --expected-backup-fstype ext4|xfs --expected-database-authority-uuid UUID --confirmation PREPARE-EMPTY-WEBSITE-HOST-STATE-UUID-BACKUP-UUID-DB-AUTHORITY-UUID'
signers="$(readlink -f -- "$2")"
nginx_worker=$4
expected_state_uuid=${6,,}
expected_state_type=$8
expected_backup_uuid=${10,,}
expected_backup_type=$12
expected_database_authority_uuid=${14,,}
expected_confirmation="PREPARE-EMPTY-WEBSITE-HOST-STATE-$expected_state_uuid-BACKUP-$expected_backup_uuid-DB-AUTHORITY-$expected_database_authority_uuid"
[[ $expected_state_uuid =~ ^[a-f0-9][a-f0-9-]{7,63}$ && $expected_backup_uuid =~ ^[a-f0-9][a-f0-9-]{7,63}$ && \
   $expected_state_uuid != "$expected_backup_uuid" && $expected_state_type =~ ^(ext4|xfs)$ && $expected_backup_type =~ ^(ext4|xfs)$ ]] \
  || die 'out-of-band expected storage identities are invalid or not distinct'
[[ $expected_database_authority_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die 'out-of-band database authority UUID is not canonical lowercase UUID text'
[[ ${16} == "$expected_confirmation" ]] || die 'typed fresh-host confirmation does not bind storage and database authority identities'
[[ -f $signers && ! -L $signers ]] || die 'reviewed website allowed-signers file is missing'
[[ $nginx_worker =~ ^[a-z_][a-z0-9_-]{0,31}$ && $nginx_worker != root && $nginx_worker != uten-website && $nginx_worker != uten-website-updater ]] \
  || die 'Nginx worker identity is invalid or conflicts with website identities'
getent passwd "$nginx_worker" >/dev/null || die 'observed Nginx worker identity does not exist'
[[ ! -e /opt/uten-website/current && ! -e /var/lib/uten-website/runtime/website.db ]] \
  || die 'host is not empty; use a separately reviewed existing-host migration, never this installer'
for stale_path in \
  /etc/uten-website/enable-auto-staging \
  /etc/systemd/system/uten-website.service \
  /etc/systemd/system/uten-website-boot-gate.service \
  /etc/systemd/system/uten-website-entry-watchdog.service \
  /etc/systemd/system/uten-website-entry-watchdog.timer \
  /etc/systemd/system/uten-website-stage.service \
  /etc/systemd/system/uten-website-stage.timer \
  /etc/systemd/system/uten-website-backup.service \
  /etc/systemd/system/uten-website-backup.timer \
  /etc/systemd/system/uten-website-health.service \
  /etc/systemd/system/uten-website-health.timer; do
  [[ ! -e $stale_path && ! -L $stale_path ]] \
    || die "fresh host contains old website automation/configuration: $stale_path"
done
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for command_name in awk chmod chown curl find findmnt flock getent groupadd install mountpoint mv nginx node openssl ossutil python3 readlink restic rm setfacl sha256sum ssh-keygen stat systemctl systemd-analyze useradd usermod; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing prerequisite: $command_name"
done
python3 -I - <<'PY'
import sys
if sys.version_info < (3,10): raise SystemExit('Python 3.10+ is required')
PY
node -e 'const [major,minor]=process.versions.node.split(".").map(Number); if(major<22 || (major===22&&minor<13))process.exit(1)' \
  || die 'Node.js 22.13+ is required'
[[ $(readlink -f -- "$(command -v node)") == /usr/bin/node ]] \
  || die 'systemd template pins Node to /usr/bin/node; reviewed binary differs'
[[ $(readlink -f -- "$(command -v python3)") == /usr/bin/python3 ]] \
  || die 'root helpers pin Python to /usr/bin/python3; reviewed binary differs'

# Runtime state and local recovery points must be dedicated persistent volumes.
# Exact UUIDs prevent a failed mount from silently redirecting SQLite/uploads or
# backups into an empty directory on the root filesystem after a reboot.
for mount_target in /var/lib/uten-website /var/backups/uten-website; do
  [[ -d $mount_target && ! -L $mount_target ]] || die "fresh dedicated mount must exist: $mount_target"
  mountpoint -q "$mount_target" || die "path is not an exact mount point: $mount_target"
  [[ $(findmnt -rn -R -T "$mount_target" -o TARGET) == "$mount_target" ]] \
    || die "fresh dedicated mount contains a nested mount: $mount_target"
  unexpected="$(find -P "$mount_target" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)"
  [[ -z $unexpected ]] || die "fresh dedicated mount contains unexpected state: $unexpected"
  if [[ -e $mount_target/lost+found || -L $mount_target/lost+found ]]; then
    [[ -d $mount_target/lost+found && ! -L $mount_target/lost+found && $(stat -c '%U:%G:%a' "$mount_target/lost+found") == root:root:700 ]] \
      || die "lost+found has an unsafe shape: $mount_target/lost+found"
  fi
done
state_mount="$(findmnt -rn -T /var/lib/uten-website -o TARGET,SOURCE,UUID,FSTYPE,OPTIONS)" || die 'cannot inspect state mount'
backup_mount="$(findmnt -rn -T /var/backups/uten-website -o TARGET,SOURCE,UUID,FSTYPE,OPTIONS)" || die 'cannot inspect backup mount'
read -r state_target state_source state_uuid state_type state_options <<<"$state_mount"
read -r backup_target backup_source backup_uuid backup_type backup_options <<<"$backup_mount"
[[ $state_target == /var/lib/uten-website && $backup_target == /var/backups/uten-website ]] \
  || die 'state/backup mount target differs'
[[ $state_uuid =~ ^[A-Fa-f0-9][A-Fa-f0-9-]{7,63}$ && $backup_uuid =~ ^[A-Fa-f0-9][A-Fa-f0-9-]{7,63}$ ]] \
  || die 'state/backup filesystems must expose stable UUIDs'
[[ ${state_uuid,,} != ${backup_uuid,,} ]] || die 'state and local backup must use different filesystems'
[[ $state_type =~ ^(ext4|xfs)$ && $backup_type =~ ^(ext4|xfs)$ ]] || die 'state/backup filesystems must be ext4 or xfs'
[[ ${state_uuid,,} == "$expected_state_uuid" && $state_type == "$expected_state_type" && \
   ${backup_uuid,,} == "$expected_backup_uuid" && $backup_type == "$expected_backup_type" ]] \
  || die 'mounted storage identity differs from the out-of-band reviewed UUID/FSTYPE values'
for options in "$state_options" "$backup_options"; do
  for required_option in rw nodev nosuid noexec; do
    [[ ",$options," == *",$required_option,"* ]] || die "persistent mount lacks $required_option"
  done
done

getent group uten-website >/dev/null || groupadd --system uten-website
getent group uten-website-media >/dev/null || groupadd --system uten-website-media
getent passwd uten-website >/dev/null || useradd --system --gid uten-website --home-dir /var/lib/uten-website/runtime --shell /usr/sbin/nologin uten-website
getent group uten-website-updater >/dev/null || groupadd --system uten-website-updater
getent passwd uten-website-updater >/dev/null || useradd --system --gid uten-website-updater --home-dir /var/lib/uten-website/updater --shell /usr/sbin/nologin uten-website-updater
usermod --append --groups uten-website-media "$nginx_worker"

install -d -m 0755 -o root -g root /opt/uten-website /opt/uten-website/releases /usr/local/libexec/uten-website
install -d -m 0755 -o root -g root /var/lib/uten-website
install -d -m 0750 -o uten-website -g uten-website /var/lib/uten-website/runtime /var/cache/uten-website
install -d -m 0700 -o root -g root /var/lib/uten-website/control /var/lib/uten-website/control/activation-start-grants-consumed /var/lib/uten-website/control/media-incidents
install -d -m 0700 -o uten-website-updater -g uten-website-updater /var/lib/uten-website/updater /var/lib/uten-website/updater/staged
install -d -m 2750 -o uten-website -g uten-website-media /var/lib/uten-website/runtime/uploads
install -d -m 2700 -o uten-website -g uten-website-media /var/lib/uten-website/runtime/upload-staging
install -d -m 0700 -o root -g root /var/backups/uten-website /var/backups/uten-website/local /var/backups/uten-website/receipts /etc/uten-website /etc/nginx/snippets /etc/systemd/system/nginx.service.d
setfacl -m g:uten-website-media:--x /var/lib/uten-website/runtime

install -m 0755 -o root -g root "$source_dir/validate-runtime.sh" /usr/local/libexec/uten-website/validate-runtime
install -m 0755 -o root -g root "$source_dir/validate-storage.sh" /usr/local/libexec/uten-website/validate-storage
install -m 0755 -o root -g root "$source_dir/uten-website-boot-guard.sh" /usr/local/libexec/uten-website/uten-website-boot-guard
install -m 0755 -o root -g root "$source_dir/website_release.py" /usr/local/libexec/uten-website/website_release.py
install -m 0755 -o root -g root "$source_dir/paired_state.py" /usr/local/libexec/uten-website/paired_state.py
install -m 0755 -o root -g root "$source_dir/open_root_lock.py" /usr/local/libexec/uten-website/open_root_lock.py
install -m 0755 -o root -g root "$source_dir/validate_automation_enabled.py" /usr/local/libexec/uten-website/validate-automation-enabled
install -m 0755 -o root -g root "$source_dir/uten-website-activate.sh" /usr/local/sbin/uten-website-activate
install -m 0755 -o root -g root "$source_dir/uten-website-recover.sh" /usr/local/sbin/uten-website-recover
install -m 0755 -o root -g root "$source_dir/uten-website-recover-interrupted.sh" /usr/local/sbin/uten-website-recover-interrupted
install -m 0755 -o root -g root "$source_dir/uten-website-paired-backup.sh" /usr/local/libexec/uten-website/uten-website-paired-backup
install -m 0755 -o root -g root "$source_dir/uten-website-backup-retention.sh" /usr/local/sbin/uten-website-backup-retention
install -m 0755 -o root -g root "$source_dir/uten-website-restore-drill.sh" /usr/local/sbin/uten-website-restore-drill
install -m 0755 -o root -g root "$source_dir/uten-website-health.sh" /usr/local/libexec/uten-website/uten-website-health
install -m 0755 -o root -g root "$source_dir/uten-website-commission-automation.sh" /usr/local/sbin/uten-website-commission-automation
install -m 0755 -o root -g root "$source_dir/uten-website-stage.sh" /usr/local/libexec/uten-website/uten-website-stage
install -m 0644 -o root -g root "$source_dir/uten-website-gate.open.conf" /usr/local/libexec/uten-website/uten-website-gate.open.conf
install -m 0644 -o root -g root "$source_dir/uten-website-gate.closed.conf" /usr/local/libexec/uten-website/uten-website-gate.closed.conf
install -m 0644 -o root -g root "$source_dir/uten-website-gate.closed.conf" /etc/nginx/snippets/uten-website-gate.conf
install -m 0644 -o root -g root "$signers" /etc/uten-website/release-allowed-signers
DATABASE_AUTHORITY_UUID=$expected_database_authority_uuid python3 -I - /etc/uten-website/database-authority.json.tmp <<'PY'
import json,os,pathlib,sys
value={'authorityUuid':os.environ['DATABASE_AUTHORITY_UUID'],'format':'uten-website-database-authority-v1','schemaVersion':1}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
install -m 0644 -o root -g root /etc/uten-website/database-authority.json.tmp /etc/uten-website/database-authority.json
rm -f -- /etc/uten-website/database-authority.json.tmp
STATE_UUID=$state_uuid STATE_TYPE=$state_type BACKUP_UUID=$backup_uuid BACKUP_TYPE=$backup_type \
  python3 -I - /etc/uten-website/storage.env.tmp <<'PY'
import os,pathlib,sys
value=(
 f"STATE_FS_UUID={os.environ['STATE_UUID']}\n"
 f"STATE_FS_TYPE={os.environ['STATE_TYPE']}\n"
 f"BACKUP_FS_UUID={os.environ['BACKUP_UUID']}\n"
 f"BACKUP_FS_TYPE={os.environ['BACKUP_TYPE']}\n"
 "STATE_MIN_FREE_MIB=4096\n"
 "BACKUP_MIN_FREE_MIB=8192\n"
)
pathlib.Path(sys.argv[1]).write_text(value,encoding='ascii')
PY
install -m 0600 -o root -g root /etc/uten-website/storage.env.tmp /etc/uten-website/storage.env
rm -f -- /etc/uten-website/storage.env.tmp

install -m 0644 -o root -g root "$source_dir/uten-website.service.example" /etc/systemd/system/uten-website.service
install -m 0644 -o root -g root "$source_dir/uten-website-boot-gate.service.example" /etc/systemd/system/uten-website-boot-gate.service
install -m 0644 -o root -g root "$source_dir/nginx-website-boot-gate-override.conf.example" /etc/systemd/system/nginx.service.d/uten-website-boot-gate.conf
install -m 0644 -o root -g root "$source_dir/uten-website-entry-watchdog.service.example" /etc/systemd/system/uten-website-entry-watchdog.service
install -m 0644 -o root -g root "$source_dir/uten-website-entry-watchdog.timer.example" /etc/systemd/system/uten-website-entry-watchdog.timer
install -m 0644 -o root -g root "$source_dir/uten-website-stage.service.example" /etc/systemd/system/uten-website-stage.service
install -m 0644 -o root -g root "$source_dir/uten-website-stage.timer.example" /etc/systemd/system/uten-website-stage.timer
install -m 0644 -o root -g root "$source_dir/uten-website-backup.service.example" /etc/systemd/system/uten-website-backup.service
install -m 0644 -o root -g root "$source_dir/uten-website-backup.timer.example" /etc/systemd/system/uten-website-backup.timer
install -m 0644 -o root -g root "$source_dir/uten-website-health.service.example" /etc/systemd/system/uten-website-health.service
install -m 0644 -o root -g root "$source_dir/uten-website-health.timer.example" /etc/systemd/system/uten-website-health.timer
systemd-analyze verify /etc/systemd/system/uten-website-boot-gate.service /etc/systemd/system/uten-website.service /etc/systemd/system/uten-website-entry-watchdog.service /etc/systemd/system/uten-website-entry-watchdog.timer /etc/systemd/system/uten-website-stage.service /etc/systemd/system/uten-website-stage.timer /etc/systemd/system/uten-website-backup.service /etc/systemd/system/uten-website-backup.timer /etc/systemd/system/uten-website-health.service /etc/systemd/system/uten-website-health.timer
systemctl daemon-reload
systemctl enable nginx.service uten-website-boot-gate.service
systemctl disable --now uten-website.service uten-website-entry-watchdog.timer uten-website-stage.timer uten-website-backup.timer uten-website-health.timer
for disabled_unit in uten-website.service uten-website-entry-watchdog.timer uten-website-stage.timer uten-website-backup.timer uten-website-health.timer; do
  [[ $(systemctl is-enabled "$disabled_unit" 2>/dev/null || true) == disabled && \
     $(systemctl is-active "$disabled_unit" 2>/dev/null || true) == inactive ]] \
    || die "fresh-host automation unit is not disabled and inactive: $disabled_unit"
done
[[ ! -e /etc/uten-website/enable-auto-staging && ! -L /etc/uten-website/enable-auto-staging ]] \
  || die 'automatic staging opt-in unexpectedly exists'
systemctl start uten-website-boot-gate.service
systemctl start nginx.service
systemctl is-active --quiet uten-website-boot-gate.service nginx.service \
  || die 'closed boot gate and Nginx did not become active'
nginx -t
install_receipt=/var/lib/uten-website/control/host-install-receipt.json
[[ ! -e $install_receipt && ! -L $install_receipt ]] || die 'fresh-host install receipt unexpectedly exists'
STATE_UUID=${state_uuid,,} STATE_TYPE=$state_type STATE_SOURCE=$state_source \
BACKUP_UUID=${backup_uuid,,} BACKUP_TYPE=$backup_type BACKUP_SOURCE=$backup_source \
DATABASE_AUTHORITY_UUID=$expected_database_authority_uuid \
NGINX_WORKER=$nginx_worker SIGNERS_SHA="$(sha256sum -- /etc/uten-website/release-allowed-signers | awk '{print $1}')" \
  python3 -I - "$install_receipt.tmp" <<'PY'
import datetime,json,os,pathlib,sys
value={
 'backupFilesystem':{'fstype':os.environ['BACKUP_TYPE'],'observedSource':os.environ['BACKUP_SOURCE'],'uuid':os.environ['BACKUP_UUID']},
 'coreUnits':{'nginx':'enabled-active','uten-website-boot-gate':'enabled-active'},
 'databaseAuthorityUuid':os.environ['DATABASE_AUTHORITY_UUID'],
 'disabledUnits':['uten-website.service','uten-website-entry-watchdog.timer','uten-website-stage.timer','uten-website-backup.timer','uten-website-health.timer'],
 'format':'uten-website-fresh-host-install-receipt-v1',
 'installedAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z'),
 'nginxWorker':os.environ['NGINX_WORKER'],
 'releaseAllowedSignersSha256':os.environ['SIGNERS_SHA'],
 'stateFilesystem':{'fstype':os.environ['STATE_TYPE'],'observedSource':os.environ['STATE_SOURCE'],'uuid':os.environ['STATE_UUID']},
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',encoding='utf-8')
PY
chown root:root "$install_receipt.tmp"
chmod 0600 "$install_receipt.tmp"
python3 -I - "$install_receipt.tmp" <<'PY'
import os,pathlib,sys
path=pathlib.Path(sys.argv[1]); fd=os.open(path,os.O_RDONLY)
try: os.fsync(fd)
finally: os.close(fd)
PY
mv -Tf -- "$install_receipt.tmp" "$install_receipt"
python3 -I - "$install_receipt" <<'PY'
import os,pathlib,sys
path=pathlib.Path(sys.argv[1])
for target in (path,path.parent):
 fd=os.open(target,os.O_RDONLY)
 try: os.fsync(fd)
 finally: os.close(fd)
PY
printf '%s\n' 'WEBSITE_HOST_PREPARED_GATE_CLOSED: restore paired state and stage a signed release; app/watchdog/automation timers remain disabled until proved activation'
