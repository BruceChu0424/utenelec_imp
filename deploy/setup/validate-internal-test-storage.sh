#!/usr/bin/env bash
# Read-only startup preflight for the fixed NVMe-backed attachment namespace.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly DATA_ROOT=/data
readonly APP_ROOT=/data/uten-imp
readonly ATTACHMENT_ROOT=/data/uten-imp/attachments
readonly STAGING_ROOT=/data/uten-imp/attachments/staging
readonly FINAL_ROOT=/data/uten-imp/attachments/final

die() {
  printf 'INTERNAL_TEST_STORAGE_INVALID: %s\n' "$*" >&2
  exit 1
}

require_directory() {
  local path="$1" metadata="$2"
  [[ -d "$path" && ! -L "$path" ]] || die "$path must be a real directory"
  [[ "$(realpath -e -- "$path")" == "$path" ]] || die "$path must be canonical"
  [[ "$(stat -c '%U:%G:%a' "$path")" == "$metadata" ]] \
    || die "$path must be $metadata"
}

[[ "${EUID}" -eq 0 ]] || die 'run this preflight as root'
/usr/bin/mountpoint --quiet "$DATA_ROOT" || die '/data must be a mounted filesystem'

source_device="$(/usr/bin/findmnt -n -o SOURCE --target "$DATA_ROOT")"
filesystem="$(/usr/bin/findmnt -n -o FSTYPE --target "$DATA_ROOT")"
mount_options="$(/usr/bin/findmnt -n -o OPTIONS --target "$DATA_ROOT")"
capacity_bytes="$(/usr/bin/findmnt -b -n -o SIZE --target "$DATA_ROOT")"
[[ "$source_device" == /dev/mapper/* ]] || die '/data must come from the commissioned LVM logical volume'
[[ "$(/usr/bin/lsblk -d -n -o TYPE "$source_device" | tr -d '[:space:]')" == lvm ]] \
  || die '/data source must be an LVM logical volume'
[[ "$(/usr/bin/lsblk -d -n -o ROTA "$source_device" | tr -d '[:space:]')" == 0 ]] \
  || die '/data source must be non-rotational storage'
[[ "$filesystem" == ext4 ]] || die '/data must use ext4'
for option in rw nodev nosuid noexec; do
  [[ ",$mount_options," == *",$option,"* ]] || die "/data mount must include $option"
done
(( capacity_bytes >= 300 * 1024 * 1024 * 1024 )) \
  || die '/data must provide at least 300 GiB for the commissioned test layout'

require_directory "$DATA_ROOT" root:root:755
require_directory "$APP_ROOT" root:root:755
require_directory "$ATTACHMENT_ROOT" root:uten-imp:750
require_directory "$STAGING_ROOT" uten-imp:uten-imp:750
require_directory "$FINAL_ROOT" uten-imp:uten-imp:750

root_device="$(stat -c '%d' "$DATA_ROOT")"
for path in "$APP_ROOT" "$ATTACHMENT_ROOT" "$STAGING_ROOT" "$FINAL_ROOT"; do
  [[ "$(stat -c '%d' "$path")" == "$root_device" ]] \
    || die "$path crosses the commissioned /data filesystem boundary"
done

[[ -z "$(find "$ATTACHMENT_ROOT" -xdev -type l -print -quit)" ]] \
  || die 'attachment storage must not contain symbolic links'
/usr/sbin/runuser -u uten-imp -- /usr/bin/test -r "$STAGING_ROOT" \
  || die 'service account cannot read staging'
/usr/sbin/runuser -u uten-imp -- /usr/bin/test -w "$STAGING_ROOT" \
  || die 'service account cannot write staging'
/usr/sbin/runuser -u uten-imp -- /usr/bin/test -r "$FINAL_ROOT" \
  || die 'service account cannot read final storage'
/usr/sbin/runuser -u uten-imp -- /usr/bin/test -w "$FINAL_ROOT" \
  || die 'service account cannot write final storage'
if /usr/sbin/runuser -u uten-imp -- /usr/bin/test -w "$APP_ROOT"; then
  die 'service account must not be able to replace the attachment root'
fi

printf 'INTERNAL_TEST_STORAGE_OK source_type=lvm rotational=0 filesystem=ext4 capacity_bytes=%s path=%s\n' \
  "$capacity_bytes" "$ATTACHMENT_ROOT"
