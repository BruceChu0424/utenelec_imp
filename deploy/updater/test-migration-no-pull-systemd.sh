#!/usr/bin/env bash
# Disposable Ubuntu 24.04 VM regression: a direct migrator start must not pull
# the database or data dependency online before the authorization gates run.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die 'run only as root inside a disposable VM'
[[ "${UTEN_DISPOSABLE_SYSTEMD_TEST:-}" == YES ]] \
  || die 'set UTEN_DISPOSABLE_SYSTEMD_TEST=YES only on a disposable VM'
[[ "$(ps -p 1 -o comm=)" == systemd ]] || die 'systemd must be PID 1'

readonly SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/systemd/uten-imp-migrate.service.example"
readonly TOKEN="$$"
readonly MIGRATOR="uten-test-migration-nopull-${TOKEN}.service"
readonly DATABASE="uten-test-database-sentinel-${TOKEN}.service"
readonly DATA="uten-test-data-sentinel-${TOKEN}.service"
readonly UNIT_ROOT=/run/systemd/system
readonly WORK="/run/uten-test-migration-nopull-${TOKEN}"
readonly PROOF="$WORK/migrator-ran"
readonly DATABASE_PROOF="$WORK/database-ran"
readonly DATA_PROOF="$WORK/data-ran"

for path in "$SOURCE" "$UNIT_ROOT"; do
  [[ ! -L "$path" ]] || die "test prerequisite is symlinked: $path"
done
[[ -f "$SOURCE" ]] || die "missing migrator template: $SOURCE"
install -d -m 0700 -o root -g root "$WORK"

cleanup() {
  local status="$?"
  trap - EXIT
  systemctl stop "$MIGRATOR" "$DATABASE" "$DATA" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_ROOT/$MIGRATOR" "$UNIT_ROOT/$DATABASE" "$UNIT_ROOT/$DATA"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f -- "$PROOF" "$DATABASE_PROOF" "$DATA_PROOF"
  rmdir -- "$WORK" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cat >"$UNIT_ROOT/$DATABASE" <<EOF
[Service]
Type=oneshot
ExecStart=/usr/bin/touch $DATABASE_PROOF
RemainAfterExit=yes
EOF
cat >"$UNIT_ROOT/$DATA" <<EOF
[Service]
Type=oneshot
ExecStart=/usr/bin/touch $DATA_PROOF
RemainAfterExit=yes
EOF

# Preserve and exercise the template Unit graph while replacing only the two
# sentinels. The simplified Service body fails before its payload can run.
awk -v database="$DATABASE" -v data="$DATA" -v proof="$PROOF" '
  /^\[Service\]$/ {
    print "[Service]"
    print "Type=oneshot"
    print "ExecStartPre=/usr/bin/false"
    print "ExecStart=/usr/bin/touch " proof
    exit
  }
  {
    gsub(/postgresql@16-main\.service/, database)
    gsub(/data\.mount/, data)
    print
  }
' "$SOURCE" >"$UNIT_ROOT/$MIGRATOR"

systemctl daemon-reload
after=" $(systemctl show --property=After --value "$MIGRATOR") "
[[ "$after" == *" $DATABASE "* && "$after" == *" $DATA "* ]] \
  || die 'rendered test migrator lost ordering dependencies'
for property in Requires Requisite BindsTo PartOf Upholds; do
  dependencies=" $(systemctl show --property="$property" --value "$MIGRATOR") "
  [[ "$dependencies" != *" $DATABASE "* && "$dependencies" != *" $DATA "* ]] \
    || die "migrator unexpectedly pulls a sentinel through $property="
done
[[ -z "$(systemctl show --property=RequiresMountsFor --value "$MIGRATOR")" ]] \
  || die 'migrator unexpectedly has RequiresMountsFor='

if systemctl start "$MIGRATOR"; then
  die 'direct migrator start unexpectedly passed its fail-closed pre-start gate'
fi
for sentinel in "$DATABASE" "$DATA"; do
  systemctl is-active --quiet "$sentinel" \
    && die "direct migrator start pulled a sentinel online: $sentinel"
done
[[ ! -e "$PROOF" && ! -e "$DATABASE_PROOF" && ! -e "$DATA_PROOF" ]] \
  || die 'a protected payload ran during the direct-start regression'

printf '%s\n' 'MIGRATION_DIRECT_START_NO_PULL_OK'
