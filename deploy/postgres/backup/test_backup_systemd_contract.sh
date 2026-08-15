#!/usr/bin/env bash
# Destructive only to uniquely named /run systemd test units on an explicit disposable VM.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${UTEN_RUN_SYSTEMD_BACKUP_TESTS:-}" == 'I_ACKNOWLEDGE_THIS_IS_A_DISPOSABLE_SYSTEMD_VM' ]] \
  || die 'set the exact disposable-VM confirmation before loading test units'
[[ "${EUID}" -eq 0 ]] || die 'the disposable systemd contract test requires root'
[[ "$(ps -p 1 -o comm=)" == systemd ]] || die 'PID 1 is not systemd'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SYSTEMD_SOURCE="$(cd -- "$SCRIPT_DIR/../../systemd" && pwd -P)"
readonly TOKEN="uten-imp-backup-contract-$$"
[[ "$TOKEN" =~ ^uten-imp-backup-contract-[1-9][0-9]*$ ]] || die 'unsafe test token'
readonly WORK="$(mktemp -d "/tmp/${TOKEN}.XXXXXX")"
readonly PG_UNIT="${TOKEN}-postgres.service"
readonly DATA_SENTINEL_UNIT="${TOKEN}-data-mount-sentinel.service"
readonly REPO1_UNIT="${TOKEN}-repo1.service"
readonly REPO2_UNIT="${TOKEN}-repo2.service"
readonly HEALTH_UNIT="${TOKEN}-health.service"
readonly PG_PROOF="/run/${TOKEN}-postgres-started"
readonly DATA_PROOF="/run/${TOKEN}-data-mount-started"
readonly REPO1_PROOF="/run/${TOKEN}-repo1-started"
readonly REPO2_PROOF="/run/${TOKEN}-repo2-started"
readonly HEALTH_PROOF="/run/${TOKEN}-health-started"
readonly -a TEST_UNITS=("$REPO1_UNIT" "$REPO2_UNIT" "$HEALTH_UNIT" "$PG_UNIT" "$DATA_SENTINEL_UNIT")
declare -a UNIT_PATHS=()

cleanup() {
  local path
  systemctl stop "${TEST_UNITS[@]}" >/dev/null 2>&1 || true
  for path in "${UNIT_PATHS[@]}"; do
    [[ "$path" == "/run/systemd/system/${TOKEN}-"*.service ]] \
      || die "refusing unsafe test-unit cleanup path: $path"
    rm -f -- "$path"
  done
  rm -f -- "$PG_PROOF" "$DATA_PROOF" "$REPO1_PROOF" "$REPO2_PROOF" "$HEALTH_PROOF"
  systemctl daemon-reload >/dev/null 2>&1 || true
  [[ "$WORK" == "/tmp/${TOKEN}."* ]] || die 'refusing unsafe temporary cleanup path'
  rm -rf -- "$WORK"
}
trap cleanup EXIT

install_test_unit() {
  local source="$1" unit="$2" destination="/run/systemd/system/$2"
  [[ ! -e "$destination" && ! -L "$destination" ]] \
    || die "test unit unexpectedly exists: $destination"
  install -m 0644 -o root -g root "$source" "$destination"
  UNIT_PATHS+=("$destination")
}

cat >"$WORK/$PG_UNIT" <<EOF
[Unit]
Description=Disposable inactive PostgreSQL sentinel
[Service]
Type=oneshot
ExecStart=/usr/bin/touch $PG_PROOF
RemainAfterExit=yes
EOF
cat >"$WORK/$DATA_SENTINEL_UNIT" <<EOF
[Unit]
Description=Disposable inactive data.mount sentinel
[Service]
Type=oneshot
ExecStart=/usr/bin/touch $DATA_PROOF
RemainAfterExit=yes
EOF

render_backup_test_unit() {
  local source="$1" destination="$2" proof="$3"
  sed \
    -e "s/postgresql@16-main.service/$PG_UNIT/g" \
    -e "s/uten-pgbackup-repo2.service/$REPO2_UNIT/g" \
    -e "s/uten-pgbackup.service/$REPO1_UNIT/g" \
    -e '/^OnFailure=/d' \
    -e '/^ExecStartPre=/d' \
    -e 's#^ExecStart=.*#ExecStart=/usr/bin/false#' \
    -e 's/^Restart=.*/Restart=no/' \
    -e '/^RestartSec=/d' \
    "$source" >"$destination"
}

render_backup_test_unit "$SYSTEMD_SOURCE/uten-pgbackup.service.example" "$WORK/$REPO1_UNIT" "$REPO1_PROOF"
render_backup_test_unit "$SYSTEMD_SOURCE/uten-pgbackup-repo2.service.example" "$WORK/$REPO2_UNIT" "$REPO2_PROOF"
render_backup_test_unit "$SYSTEMD_SOURCE/uten-pgbackup-health.service.example" "$WORK/$HEALTH_UNIT" "$HEALTH_PROOF"

install_test_unit "$WORK/$PG_UNIT" "$PG_UNIT"
install_test_unit "$WORK/$DATA_SENTINEL_UNIT" "$DATA_SENTINEL_UNIT"
install_test_unit "$WORK/$REPO1_UNIT" "$REPO1_UNIT"
install_test_unit "$WORK/$REPO2_UNIT" "$REPO2_UNIT"
install_test_unit "$WORK/$HEALTH_UNIT" "$HEALTH_UNIT"
systemctl daemon-reload

for unit in "$REPO1_UNIT" "$REPO2_UNIT" "$HEALTH_UNIT"; do
  requires="$(systemctl show "$unit" --property=Requires --value)"
  requisite="$(systemctl show "$unit" --property=Requisite --value)"
  requires_mounts="$(systemctl show "$unit" --property=RequiresMountsFor --value)"
  [[ " $requires " != *" $PG_UNIT "* ]] || die "$unit still loads PostgreSQL as Requires"
  [[ " $requires " != *" $DATA_SENTINEL_UNIT "* ]] || die "$unit still loads the data mount sentinel as Requires"
  [[ " $requisite " != *" $PG_UNIT "* ]] || die "$unit still loads PostgreSQL as Requisite"
  [[ " $requisite " != *" $DATA_SENTINEL_UNIT "* ]] || die "$unit still loads the data mount sentinel as Requisite"
  [[ -z "$requires_mounts" ]] || die "$unit unexpectedly loaded RequiresMountsFor=$requires_mounts"
  if systemctl start "$unit"; then
    die "$unit unexpectedly passed its simulated in-helper preflight"
  fi
  systemctl is-active --quiet "$PG_UNIT" && die "$unit pulled the inactive PostgreSQL sentinel up"
  systemctl is-active --quiet "$DATA_SENTINEL_UNIT" && die "$unit pulled the data.mount sentinel up"
done

[[ ! -e "$PG_PROOF" && ! -e "$DATA_PROOF" ]] \
  || die 'an inactive PostgreSQL/data sentinel was executed'
[[ ! -e "$REPO1_PROOF" && ! -e "$REPO2_PROOF" && ! -e "$HEALTH_PROOF" ]] \
  || die 'a backup/health ExecStart ran despite inactive PostgreSQL'
printf '%s\n' 'BACKUP_SYSTEMD_NO_PULL_DEPENDENCY_CONTRACT_OK'
