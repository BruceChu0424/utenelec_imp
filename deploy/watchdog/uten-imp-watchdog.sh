#!/usr/bin/env bash
set -euo pipefail

readonly HEALTH_URL="${UTEN_WATCHDOG_HEALTH_URL:-http://127.0.0.1:8080/actuator/health/liveness}"
readonly FAILURE_THRESHOLD="${UTEN_WATCHDOG_FAILURE_THRESHOLD:-4}"
readonly STATE_DIR="${UTEN_WATCHDOG_STATE_DIR:-/run/uten-imp-watchdog}"
readonly COUNTER_FILE="${STATE_DIR}/failures"

if [[ ! "${FAILURE_THRESHOLD}" =~ ^[1-9][0-9]*$ ]]; then
  logger -p daemon.err -t uten-imp-watchdog "invalid failure threshold"
  exit 2
fi

mkdir -p -- "${STATE_DIR}"
chmod 0750 "${STATE_DIR}"
exec 9>"${STATE_DIR}/lock"
flock -n 9 || exit 0

write_counter() {
  local value="$1"
  local temporary
  temporary="$(mktemp "${STATE_DIR}/.failures.XXXXXX")"
  printf '%s\n' "${value}" >"${temporary}"
  chmod 0640 "${temporary}"
  mv -f -- "${temporary}" "${COUNTER_FILE}"
}

if curl --fail --silent --show-error --max-time 5 "${HEALTH_URL}" \
  | jq -e '.status == "UP"' >/dev/null; then
  write_counter 0
  exit 0
fi

failures=0
if [[ -r "${COUNTER_FILE}" ]]; then
  read -r failures <"${COUNTER_FILE}" || failures=0
fi
if [[ ! "${failures}" =~ ^[0-9]+$ ]]; then
  failures=0
fi
failures=$((failures + 1))
write_counter "${failures}"

logger -p daemon.warning -t uten-imp-watchdog \
  "liveness failure ${failures}/${FAILURE_THRESHOLD}"

if (( failures < FAILURE_THRESHOLD )); then
  exit 1
fi

logger -p daemon.err -t uten-imp-watchdog \
  "liveness failed ${FAILURE_THRESHOLD} consecutive probes; restarting uten-imp.service"
if systemctl restart uten-imp.service; then
  write_counter 0
  logger -p daemon.notice -t uten-imp-watchdog \
    "restart requested successfully"
else
  logger -p daemon.err -t uten-imp-watchdog \
    "restart request failed"
fi
exit 1
