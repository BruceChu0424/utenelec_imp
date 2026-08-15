#!/usr/bin/env bash
# Restore to an isolated disposable directory; never mutates live website state.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
readonly TOOL=/usr/local/libexec/uten-website/paired_state.py
readonly ROOT=/var/lib/uten-website/control/restore-drills
[[ ${EUID} -eq 0 ]] || { echo 'WEBSITE_RESTORE_DRILL_REFUSED: must run as root' >&2; exit 1; }
[[ $# -eq 1 ]] || { echo 'usage: uten-website-restore-drill /var/backups/uten-website/local/SNAPSHOT_ID' >&2; exit 1; }
snapshot="$(readlink -f -- "$1")"
[[ $snapshot == /var/backups/uten-website/local/* && $(dirname -- "$snapshot") == /var/backups/uten-website/local ]] \
  || { echo 'WEBSITE_RESTORE_DRILL_REFUSED: snapshot is outside fixed local recovery points' >&2; exit 1; }
id="${snapshot##*/}"
destination=$ROOT/$id
[[ ! -e $destination && ! -L $destination ]] || { echo 'WEBSITE_RESTORE_DRILL_REFUSED: drill destination exists' >&2; exit 1; }
install -d -m 0700 -o root -g root "$ROOT"
python3 -I "$TOOL" verify --snapshot "$snapshot"
python3 -I "$TOOL" restore --snapshot "$snapshot" --destination "$destination"
receipt=$destination/restore-receipt.json
[[ -f $receipt && ! -L $receipt ]] || { echo 'WEBSITE_RESTORE_DRILL_REFUSED: receipt missing' >&2; exit 1; }
printf 'WEBSITE_RESTORE_DRILL_OK snapshot=%s receipt=%s\n' "$snapshot" "$receipt"
