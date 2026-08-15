#!/usr/bin/env bash
# Root-only persistent-volume identity/capacity gate used before every start.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() { printf 'WEBSITE_STORAGE_REFUSED: %s\n' "$*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || die 'validator must run as root'

readonly CONFIG=/etc/uten-website/storage.env
readonly STATE=/var/lib/uten-website
readonly RUNTIME=$STATE/runtime
readonly CONTROL=$STATE/control
readonly UPDATER=$STATE/updater
readonly BACKUPS=/var/backups/uten-website

for command_name in df findmnt python3 stat; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done
[[ -f $CONFIG && ! -L $CONFIG ]] || die "$CONFIG must be a regular file"
[[ $(stat -c '%U:%G:%a:%h' -- "$CONFIG") == root:root:600:1 ]] \
  || die "$CONFIG must be root:root mode 0600 with one hard link"

values="$(python3 -I - "$CONFIG" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
raw = path.read_bytes()
if not raw or len(raw) > 4096 or b"\0" in raw or b"\r" in raw:
    raise SystemExit("storage.env must be small canonical UTF-8 text")
try:
    text = raw.decode("ascii")
except UnicodeDecodeError as exc:
    raise SystemExit("storage.env must contain ASCII only") from exc

expected = {
    "STATE_FS_UUID",
    "STATE_FS_TYPE",
    "BACKUP_FS_UUID",
    "BACKUP_FS_TYPE",
    "STATE_MIN_FREE_MIB",
    "BACKUP_MIN_FREE_MIB",
}
values = {}
for number, line in enumerate(text.splitlines(), 1):
    if not line or line.startswith("#"):
        continue
    match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=([A-Za-z0-9._-]+)", line)
    if not match:
        raise SystemExit(f"storage.env line {number} is not canonical KEY=value data")
    key, value = match.groups()
    if key not in expected or key in values:
        raise SystemExit(f"storage.env contains an unknown or duplicate key: {key}")
    values[key] = value
if set(values) != expected:
    raise SystemExit(f"storage.env exact key set differs: {sorted(expected - set(values))}")
for key in ("STATE_FS_UUID", "BACKUP_FS_UUID"):
    if not re.fullmatch(r"[A-Fa-f0-9][A-Fa-f0-9-]{7,63}", values[key]):
        raise SystemExit(f"{key} is not a canonical filesystem UUID")
if values["STATE_FS_UUID"].casefold() == values["BACKUP_FS_UUID"].casefold():
    raise SystemExit("state and local backup must not share one filesystem UUID")
for key in ("STATE_FS_TYPE", "BACKUP_FS_TYPE"):
    if values[key] not in {"ext4", "xfs"}:
        raise SystemExit(f"{key} must be ext4 or xfs")
for key in ("STATE_MIN_FREE_MIB", "BACKUP_MIN_FREE_MIB"):
    if not re.fullmatch(r"[1-9][0-9]*", values[key]):
        raise SystemExit(f"{key} must be a canonical positive integer")
    amount = int(values[key])
    if not 1024 <= amount <= 1048576:
        raise SystemExit(f"{key} is outside the reviewed 1 GiB to 1 TiB range")
print(values["STATE_FS_UUID"])
print(values["STATE_FS_TYPE"])
print(values["BACKUP_FS_UUID"])
print(values["BACKUP_FS_TYPE"])
print(values["STATE_MIN_FREE_MIB"])
print(values["BACKUP_MIN_FREE_MIB"])
PY
)" || die 'storage.env validation failed'

state_uuid="$(printf '%s\n' "$values" | sed -n '1p')"
state_type="$(printf '%s\n' "$values" | sed -n '2p')"
backup_uuid="$(printf '%s\n' "$values" | sed -n '3p')"
backup_type="$(printf '%s\n' "$values" | sed -n '4p')"
state_min="$(printf '%s\n' "$values" | sed -n '5p')"
backup_min="$(printf '%s\n' "$values" | sed -n '6p')"

check_mount() {
  local path=$1 expected_uuid=$2 expected_type=$3 minimum_mib=$4 label=$5
  [[ -d $path && ! -L $path ]] || die "$label mount target is missing or is a symlink: $path"
  local fields target uuid fs_type options
  fields="$(findmnt -rn -T "$path" -o TARGET,UUID,FSTYPE,OPTIONS)" \
    || die "cannot resolve $label filesystem"
  read -r target uuid fs_type options <<<"$fields"
  [[ $target == "$path" ]] || die "$label path is not an exact mount point: resolved $target"
  local mount_tree
  mount_tree="$(findmnt -rn -R -T "$path" -o TARGET)" \
    || die "cannot enumerate $label filesystem submounts"
  [[ $mount_tree == "$path" ]] \
    || die "$label filesystem contains a nested mount; DB/uploads/backup authority would be ambiguous"
  [[ ${uuid,,} == ${expected_uuid,,} ]] || die "$label filesystem UUID differs"
  [[ $fs_type == "$expected_type" ]] || die "$label filesystem type differs"
  for required_option in rw nodev nosuid noexec; do
    [[ ",$options," == *",$required_option,"* ]] || die "$label mount lacks $required_option"
  done
  local available_mib inode_used
  available_mib="$(df -Pm "$path" | awk 'NR==2 {print $4}')"
  inode_used="$(df -Pi "$path" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  [[ $available_mib =~ ^[0-9]+$ && $available_mib -ge $minimum_mib ]] \
    || die "$label filesystem has less than ${minimum_mib} MiB free"
  [[ $inode_used =~ ^[0-9]+$ && $inode_used -lt 90 ]] \
    || die "$label filesystem has fewer than 10% inodes free"
}

check_mount "$STATE" "$state_uuid" "$state_type" "$state_min" state
check_mount "$BACKUPS" "$backup_uuid" "$backup_type" "$backup_min" backup
[[ $(stat -c '%U:%G:%a' -- "$STATE") == root:root:755 ]] \
  || die 'state mount root must remain root:root mode 0755'
[[ $(stat -c '%U:%G:%a' -- "$CONTROL") == root:root:700 ]] \
  || die 'root control directory must be root:root mode 0700'
[[ $(stat -c '%U:%G:%a' -- "$RUNTIME") == uten-website:uten-website:750 ]] \
  || die 'application runtime directory identity differs'
[[ $(stat -c '%U:%G:%a' -- "$UPDATER") == uten-website-updater:uten-website-updater:700 ]] \
  || die 'updater state directory identity differs'
[[ $(stat -c '%U:%G:%a' -- "$BACKUPS") == root:root:700 ]] \
  || die 'backup mount root must be root:root mode 0700'
printf 'WEBSITE_STORAGE_OK state_uuid=%s backup_uuid=%s\n' "$state_uuid" "$backup_uuid"
