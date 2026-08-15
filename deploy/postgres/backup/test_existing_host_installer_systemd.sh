#!/usr/bin/env bash
# Loads exact backup unit names only in /run on an explicitly disposable systemd VM.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${UTEN_RUN_EXISTING_BACKUP_INSTALLER_SYSTEMD_TESTS:-}" == \
  'I_ACKNOWLEDGE_THIS_IS_A_DISPOSABLE_SYSTEMD_VM' ]] \
  || die 'set the exact disposable-VM confirmation before loading exact unit names'
[[ "$EUID" -eq 0 ]] || die 'the disposable loaded-unit test requires root'
[[ "$(ps -p 1 -o comm=)" == systemd ]] || die 'PID 1 is not systemd'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SYSTEMD_SOURCE="$(cd -- "$SCRIPT_DIR/../../systemd" && pwd -P)"
readonly TOKEN="uten-existing-backup-systemd-$$"
[[ "$TOKEN" =~ ^uten-existing-backup-systemd-[1-9][0-9]*$ ]] || die 'unsafe test token'
readonly WORK="$(mktemp -d "/tmp/${TOKEN}.XXXXXX")"
readonly -a SERVICES=(
  uten-pgbackup.service
  uten-pgbackup-repo2.service
  uten-pgbackup-health.service
  uten-pgbackup-alert@.service
  uten-pgbackup-alert-drain.service
)
readonly -a TIMERS=(
  uten-pgbackup.timer
  uten-pgbackup-repo2.timer
  uten-pgbackup-health.timer
  uten-pgbackup-alert-drain.timer
)
readonly -a UNITS=("${SERVICES[@]}" "${TIMERS[@]}")
declare -a INSTALLED=()

cleanup() {
  local path
  for path in "${INSTALLED[@]}"; do
    [[ "$path" == /run/systemd/system/uten-pgbackup*.service ||
      "$path" == /run/systemd/system/uten-pgbackup*.timer ]] \
      || die "refusing unsafe unit cleanup path: $path"
    rm -f -- "$path"
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  [[ "$WORK" == "/tmp/${TOKEN}."* ]] || die 'refusing unsafe temporary cleanup path'
  rm -rf -- "$WORK"
}
trap cleanup EXIT

source_for_unit() {
  local unit="$1"
  printf '%s/%s.example\n' "$SYSTEMD_SOURCE" "$unit"
}

for unit in "${UNITS[@]}"; do
  source="$(source_for_unit "$unit")"
  [[ -f "$source" && ! -L "$source" ]] || die "reviewed source is missing/symlinked: $source"
  current_load="$(systemctl show "$unit" --property=LoadState --value)"
  [[ "$current_load" == not-found ]] \
    || die "disposable VM already knows $unit (LoadState=$current_load)"
  [[ ! -e "/run/systemd/system/$unit" && ! -L "/run/systemd/system/$unit" ]] \
    || die "runtime unit path already exists: $unit"
  if [[ "$unit" == *.service ]]; then
    sed -e 's#^ExecStart=.*#ExecStart=/usr/bin/true#' "$source" >"$WORK/$unit"
  else
    cp -- "$source" "$WORK/$unit"
  fi
done

cat >"$WORK/postgresql@16-main.service" <<'EOF'
[Unit]
Description=Disposable verify-only PostgreSQL ordering target
[Service]
Type=oneshot
ExecStart=/usr/bin/true
EOF
systemd-analyze verify "$WORK"/*.service "$WORK"/*.timer

for unit in "${UNITS[@]}"; do
  destination="/run/systemd/system/$unit"
  install -m 0644 -o root -g root "$(source_for_unit "$unit")" "$destination"
  INSTALLED+=("$destination")
done
systemctl daemon-reload

for unit in "${UNITS[@]}"; do
  fragment="$(systemctl show "$unit" --property=FragmentPath --value)"
  dropins="$(systemctl show "$unit" --property=DropInPaths --value)"
  active="$(systemctl show "$unit" --property=ActiveState --value)"
  [[ "$fragment" == "/run/systemd/system/$unit" ]] \
    || die "$unit loaded an unexpected FragmentPath=$fragment"
  [[ -z "$dropins" ]] || die "$unit loaded unexpected DropInPaths=$dropins"
  [[ "$active" == inactive ]] || die "$unit unexpectedly became active: $active"
  [[ "$(stat -c '%U:%G:%a:%h' "$fragment")" == root:root:644:1 ]] \
    || die "$unit fragment metadata is not root:root 0644 single-link"
done

for timer in "${TIMERS[@]}"; do
  state="$(systemctl show "$timer" --property=UnitFileState --value)"
  [[ "$state" == disabled ]] || die "$timer must remain disabled, got $state"
done

for unit in "${UNITS[@]}"; do
  for property in Requires Requisite Wants BindsTo Upholds; do
    dependencies="$(systemctl show "$unit" --property="$property" --value)"
    [[ " $dependencies " != *' postgresql.service '* &&
      " $dependencies " != *' postgresql@16-main.service '* &&
      " $dependencies " != *' data.mount '* ]] \
      || die "$unit pulls PostgreSQL or /data through $property=$dependencies"
  done
  mounts="$(systemctl show "$unit" --property=RequiresMountsFor --value)"
  [[ -z "$mounts" ]] || die "$unit pulls a mount through RequiresMountsFor=$mounts"
done

for service in \
  uten-pgbackup.service \
  uten-pgbackup-repo2.service \
  uten-pgbackup-health.service; do
  after="$(systemctl show "$service" --property=After --value)"
  [[ " $after " == *' postgresql@16-main.service '* ]] \
    || die "$service lacks PostgreSQL ordering"
done

while read -r _job_id job_unit _job_type _job_state _rest; do
  [[ -z "${job_unit:-}" ]] && continue
  case "$job_unit" in
    uten-pgbackup*.service|uten-pgbackup*.timer)
      die "managed unit unexpectedly has a pending job: $job_unit"
      ;;
  esac
done < <(systemctl list-jobs --no-legend --plain --no-pager)

alert_instances="$(systemctl list-units --all --plain --no-legend --no-pager \
  'uten-pgbackup-alert@*.service')"
[[ -z "$alert_instances" ]] || die 'an alert instance unexpectedly exists'

printf '%s\n' 'EXISTING_BACKUP_INSTALLER_LOADED_UNITS_DISABLED_INACTIVE_OK'
