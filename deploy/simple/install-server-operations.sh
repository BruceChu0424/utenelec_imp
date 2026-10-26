#!/usr/bin/env bash
# One-time host installation. Never starts a release update or changes the DB.
# Source is the reviewed deploy/simple directory, including units/.
set -euo pipefail
umask 077
SRC=${1:?Usage: sudo bash install-server-operations.sh /reviewed/deploy/simple}
[ "$(id -u)" -eq 0 ] || { echo 'Root is required' >&2; exit 1; }
for f in host_operations.py operations_storage.py update_schedule.py maintenance_recovery.py uten-imp-updater.sh \
  units/uten-imp-operations.service units/uten-imp-update-job.service \
  uten-imp-updater.tmpfiles.conf operations.example.json; do
  [ -f "$SRC/$f" ] && [ ! -L "$SRC/$f" ] || { echo "Missing reviewed source: $f" >&2; exit 1; }
done
PAIRED_SOURCE="$SRC/../postgres/backup/paired_internal_backup.py"
MARKET_BACKUP_SOURCE="$SRC/../postgres/backup/market_state_backup.py"
CLIENT_BACKUP_SOURCE="$SRC/../postgres/backup/client_release_state_backup.py"
[ -f "$PAIRED_SOURCE" ] && [ ! -L "$PAIRED_SOURCE" ] || {
  echo 'Missing reviewed paired backup helper from the same source checkout' >&2; exit 1
}
[ -f "$MARKET_BACKUP_SOURCE" ] && [ ! -L "$MARKET_BACKUP_SOURCE" ] || {
  echo 'Missing reviewed market-state backup helper from the same source checkout' >&2; exit 1
}
[ -f "$CLIENT_BACKUP_SOURCE" ] && [ ! -L "$CLIENT_BACKUP_SOURCE" ] || {
  echo 'Missing reviewed client-release backup helper from the same source checkout' >&2; exit 1
}
for asset in maintenance.html maintenance.css maintenance.js; do
  [ -f "$SRC/../../web/$asset" ] && [ ! -L "$SRC/../../web/$asset" ] \
    || { echo "Missing reviewed maintenance asset: $asset" >&2; exit 1; }
done
[ -x /usr/bin/systemd-tmpfiles ] || { echo 'systemd-tmpfiles is required' >&2; exit 1; }
getent passwd uten-imp >/dev/null
getent group uten-imp >/dev/null
safe_lock_file() {
  [ ! -L "$1" ] && { [ ! -e "$1" ] || { [ -f "$1" ] \
    && [ "$(stat -c %u "$1")" = 0 ] && [ "$(stat -c %h "$1")" = 1 ] \
    && [ "$((8#$(stat -c %a "$1") & 0022))" = 0 ]; }; } \
    || { echo 'Unsafe operations lock file' >&2; exit 1; }
}
atomic_install() {
  local source=$1 target=$2 mode=$3 temporary
  temporary=$(mktemp "${target}.install.XXXXXXXX")
  if ! install -o root -g root -m "$mode" "$source" "$temporary"; then
    rm -f -- "$temporary"; exit 1
  fi
  /usr/bin/python3 -I -c 'import os,sys; f=os.open(sys.argv[1],os.O_RDONLY|os.O_NOFOLLOW); os.fsync(f); os.close(f)' "$temporary"
  if ! mv -Tf -- "$temporary" "$target"; then
    rm -f -- "$temporary"; exit 1
  fi
  /usr/bin/python3 -I -c 'import os,sys; f=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY); os.fsync(f); os.close(f)' "$(dirname "$target")"
}
for directory in /var/lib/uten-imp-operations /run/uten-imp-updater /etc/uten-imp-updater; do
  [ ! -L "$directory" ] || { echo 'Unsafe operations directory' >&2; exit 1; }
  if [ -e "$directory" ]; then
    [ -d "$directory" ] && [ "$(stat -c %u "$directory")" = 0 ] \
      && [ "$((8#$(stat -c %a "$directory") & 0022))" = 0 ] \
      || { echo 'Unsafe existing operations directory' >&2; exit 1; }
  fi
  install -d -o root -g root -m 0700 "$directory"
done
for directory in /usr/local/lib/uten-imp /etc/uten-imp /etc/tmpfiles.d /var/lib/uten-imp-public; do
  [ ! -L "$directory" ] || { echo 'Unsafe deployment directory' >&2; exit 1; }
  if [ -e "$directory" ]; then
    [ -d "$directory" ] && [ "$(stat -c %u "$directory")" = 0 ] \
      && [ "$((8#$(stat -c %a "$directory") & 0022))" = 0 ] \
      || { echo 'Unsafe existing deployment directory' >&2; exit 1; }
  fi
  install -d -o root -g root -m 0755 "$directory"
done
for private_file in /etc/uten-imp-updater/source.env /etc/uten-imp/operations.json /etc/uten-imp-updater.env; do
  if [ -e "$private_file" ] || [ -L "$private_file" ]; then
    safe_lock_file "$private_file"
    [ "$((8#$(stat -c %a "$private_file") & 0077))" = 0 ] \
      || { echo 'Deployment configuration must remain root-private' >&2; exit 1; }
  fi
done
# Hold both fixed new locks while replacing helpers. Also exclude an old CLI
# updater which started before this installation and still owns the legacy lock.
if [ -e /etc/tmpfiles.d/uten-imp-updater.conf ] || [ -L /etc/tmpfiles.d/uten-imp-updater.conf ]; then
  safe_lock_file /etc/tmpfiles.d/uten-imp-updater.conf
fi
safe_lock_file /run/uten-imp-updater/updater.lock
exec 8>/run/uten-imp-updater/updater.lock
flock -n 8 || { echo 'An updater is running' >&2; exit 1; }
safe_lock_file /var/lib/uten-imp-operations/operations.lock
exec 7>/var/lib/uten-imp-operations/operations.lock
flock -n 7 || { echo 'An operations job is running' >&2; exit 1; }
if [ -e /run/lock/uten-imp-updater.lock ] || [ -L /run/lock/uten-imp-updater.lock ]; then
  safe_lock_file /run/lock/uten-imp-updater.lock
  exec 6<>/run/lock/uten-imp-updater.lock
  flock -n 6 || { echo 'A legacy updater is running' >&2; exit 1; }
fi
if [ -e /etc/uten-imp/paired-internal-backup.json ]; then
  # The private host config supplies this root; no RPC/caller path is involved.
  paired_lock=$(/usr/bin/python3 -I - <<'PY'
import json, os, pathlib, stat
p = pathlib.Path('/etc/uten-imp/paired-internal-backup.json')
s = p.lstat()
if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077 or s.st_size > 16384:
    raise SystemExit('Unsafe paired backup configuration')
root = pathlib.Path(json.loads(p.read_text()).get('backup_root', '/data/uten-imp-backups/paired'))
if not root.is_absolute() or root != root.resolve(strict=True) or root == pathlib.Path('/'):
    raise SystemExit('Unsafe paired backup root')
for directory in (root, *root.parents):
    s = directory.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
        raise SystemExit('Unsafe paired backup ancestor')
print(root / '.backup.lock')
PY
)
  safe_lock_file "$paired_lock"
  exec 5<>"$paired_lock"
  flock -n 5 || { echo 'A paired backup is running' >&2; exit 1; }
fi
# Refuse to replace helpers underneath a running deployment.
if systemctl is-active --quiet uten-imp-update-job.service || systemctl is-active --quiet uten-imp-updater.service; then
  echo 'An update is running; finish it before installing host operations.' >&2; exit 1
fi
if systemctl is-active --quiet uten-paired-internal-backup.service; then
  echo 'A paired backup is running; finish it before installing host operations.' >&2; exit 1
fi
backup_dir=$(mktemp -d /var/backups/uten-imp-operations-install.XXXXXXXX)
chmod 0700 "$backup_dir"
for f in /usr/local/sbin/uten-imp-updater /etc/systemd/system/uten-imp-updater.service \
  /usr/local/lib/uten-imp/host_operations.py /usr/local/lib/uten-imp/operations_storage.py \
  /usr/local/lib/uten-imp/update_schedule.py \
  /usr/local/lib/uten-imp/maintenance_recovery.py \
  /usr/local/lib/uten-imp/paired_internal_backup.py \
  /usr/local/lib/uten-imp/market_state_backup.py \
  /usr/local/lib/uten-imp/client_release_state_backup.py \
  /var/lib/uten-imp-public/maintenance.html \
  /var/lib/uten-imp-public/maintenance.css \
  /var/lib/uten-imp-public/maintenance.js \
  /etc/tmpfiles.d/uten-imp-updater.conf \
  /etc/systemd/system/uten-imp-updater.timer /etc/systemd/system/uten-imp-operations.service \
  /etc/systemd/system/uten-imp-update-job.service; do
  [ ! -f "$f" ] || cp -a -- "$f" "$backup_dir/"
done
timer_definition=$(systemctl list-unit-files --type=timer --no-legend --plain uten-imp-updater.timer)
if [ -n "$timer_definition" ]; then
  systemctl disable --now uten-imp-updater.timer
fi
timer_loaded=$(systemctl list-units --all --type=timer --no-legend --plain uten-imp-updater.timer)
if [ -n "$timer_loaded" ]; then
  systemctl stop uten-imp-updater.timer
fi
install -d -o root -g root -m 0755 /usr/local/lib/uten-imp
install -d -o root -g root -m 0700 /etc/uten-imp-updater /var/lib/uten-imp-operations
install -d -o root -g root -m 0700 /run/uten-imp-updater
install -d -o root -g root -m 0755 /etc/uten-imp
if [ ! -e /etc/uten-imp-updater/source.env ]; then
  if [ -f /etc/uten-imp-updater.env ] && [ ! -L /etc/uten-imp-updater.env ]; then
    atomic_install /etc/uten-imp-updater.env /etc/uten-imp-updater/source.env 0600
  else
    atomic_install /dev/null /etc/uten-imp-updater/source.env 0600
  fi
fi
if [ ! -e /etc/uten-imp/operations.json ]; then
  # Adopt only the root-managed paired backup's legacy originals path. Never
  # infer it from an RPC argument or expose it as a deletable resource.
  initial_config=$(mktemp /etc/uten-imp/operations.json.initial.XXXXXXXX)
  /usr/bin/python3 -I - "$SRC/operations.example.json" "$initial_config" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
paired = pathlib.Path('/etc/uten-imp/paired-internal-backup.json')
if paired.exists():
    # File ownership/mode/symlink and the shared backup lock were checked above.
    legacy = json.loads(paired.read_text()).get('local_media_root')
    active = value['storage']['uploads_root']
    if legacy is not None:
        path = pathlib.Path(legacy)
        if not path.is_absolute() or str(path) != str(path.resolve(strict=True)):
            raise SystemExit('Unsafe paired legacy originals root')
        if path != pathlib.Path(active):
            value['storage']['legacy_uploads_root'] = str(path)
pathlib.Path(sys.argv[2]).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
PY
  atomic_install "$initial_config" /etc/uten-imp/operations.json 0600
  rm -f -- "$initial_config"
fi
for helper in host_operations.py operations_storage.py update_schedule.py maintenance_recovery.py; do
  atomic_install "$SRC/$helper" "/usr/local/lib/uten-imp/$helper" 0644
done
# Independent of current/web: the first update from an old release must already
# have a maintenance page before current can switch to the new build.
for asset in maintenance.html maintenance.css maintenance.js; do
  atomic_install "$SRC/../../web/$asset" "/var/lib/uten-imp-public/$asset" 0644
done
atomic_install "$MARKET_BACKUP_SOURCE" /usr/local/lib/uten-imp/market_state_backup.py 0644
atomic_install "$CLIENT_BACKUP_SOURCE" /usr/local/lib/uten-imp/client_release_state_backup.py 0644
atomic_install "$PAIRED_SOURCE" /usr/local/lib/uten-imp/paired_internal_backup.py 0644
atomic_install "$SRC/uten-imp-updater.sh" /usr/local/sbin/uten-imp-updater 0755
for unit in uten-imp-operations.service uten-imp-update-job.service; do
  atomic_install "$SRC/units/$unit" "/etc/systemd/system/$unit" 0644
done
# The shared lock directory must exist before either unit's mount namespace is
# assembled. ExecStartPre runs too late after a reboot clears /run, and assigning
# it to one unit's RuntimeDirectory would remove it while the other still uses it.
atomic_install "$SRC/uten-imp-updater.tmpfiles.conf" /etc/tmpfiles.d/uten-imp-updater.conf 0644
/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/uten-imp-updater.conf
systemctl daemon-reload
systemctl enable uten-imp-operations.service
systemctl restart uten-imp-operations.service
echo "Host operations installed. Previous helpers/units saved privately at $backup_dir"
echo 'Configure release source in System Settings. No OSS request or release activation was performed.'
