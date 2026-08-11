#!/usr/bin/env bash
set -euo pipefail

readonly ENTRY_URL="${UTEN_ENTRY_WATCHDOG_URL:-http://127.0.0.1:8081/index.html}"
readonly ENTRY_MARKER="${UTEN_ENTRY_WATCHDOG_MARKER:-flutter_bootstrap.js}"
readonly FAILURE_THRESHOLD="${UTEN_ENTRY_WATCHDOG_FAILURE_THRESHOLD:-4}"
readonly NGINX_SERVICE="${UTEN_ENTRY_WATCHDOG_SERVICE:-nginx.service}"
readonly STATE_DIR="${UTEN_ENTRY_WATCHDOG_STATE_DIR:-/run/uten-imp-entry-watchdog}"
readonly COUNTER_FILE="${STATE_DIR}/failures"

if [[ ! "${FAILURE_THRESHOLD}" =~ ^[1-9][0-9]*$ ]]; then
  logger -p daemon.err -t uten-imp-entry-watchdog "invalid failure threshold"
  exit 2
fi
if [[ ! "${NGINX_SERVICE}" =~ ^[A-Za-z0-9@_.:-]+\.service$ ]]; then
  logger -p daemon.err -t uten-imp-entry-watchdog "invalid nginx service name"
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

entry_body=""
if entry_body="$(curl --fail --silent --show-error --max-time 5 "${ENTRY_URL}")" &&
  grep -Fq -- "${ENTRY_MARKER}" <<<"${entry_body}"; then
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

logger -p daemon.warning -t uten-imp-entry-watchdog \
  "entry probe failure ${failures}/${FAILURE_THRESHOLD}"

if (( failures < FAILURE_THRESHOLD )); then
  exit 1
fi

logger -p daemon.err -t uten-imp-entry-watchdog \
  "entry probe failed ${FAILURE_THRESHOLD} consecutive probes; restarting ${NGINX_SERVICE}"
if systemctl restart "${NGINX_SERVICE}"; then
  write_counter 0
  logger -p daemon.notice -t uten-imp-entry-watchdog \
    "nginx restart requested successfully"
else
  logger -p daemon.err -t uten-imp-entry-watchdog \
    "nginx restart request failed"
fi
exit 1
