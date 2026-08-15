#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset BASH_ENV CDPATH ENV

readonly ENTRY_URL="${UTEN_ENTRY_WATCHDOG_URL:-http://127.0.0.1:8081/index.html}"
readonly ENTRY_MARKER="${UTEN_ENTRY_WATCHDOG_MARKER:-flutter_bootstrap.js}"
readonly FAILURE_THRESHOLD="${UTEN_ENTRY_WATCHDOG_FAILURE_THRESHOLD:-4}"
readonly NGINX_SERVICE="${UTEN_ENTRY_WATCHDOG_SERVICE:-nginx.service}"
readonly STATE_DIR="${UTEN_ENTRY_WATCHDOG_STATE_DIR:-/run/uten-imp-entry-watchdog}"
readonly COUNTER_FILE="${STATE_DIR}/failures"
readonly RECOVERY_STATE_FILE="${STATE_DIR}/recovery-attempts"
readonly TIMER=uten-imp-entry-watchdog.timer
readonly APPLICATION_SERVICE=uten-imp.service
readonly READINESS_URL=http://127.0.0.1:8080/actuator/health/readiness
readonly OPERATION_LOCK=/var/lib/uten-imp-release/operation.lock
readonly MAX_TRACKED_RECOVERY_ATTEMPTS=1000000
readonly -a TRANSACTION_MARKERS=(
  /var/lib/uten-imp-release/activation-failed.json
  /var/lib/uten-imp-release/activation-in-progress.json
  /var/lib/uten-imp-release/boot-enablement-in-progress.json
  /var/lib/uten-imp-release/recovery-in-progress.json
  /var/lib/uten-imp-release/recovery-ingress-pending.json
  /var/lib/uten-imp-release/recovery-ingress-authorization.json
  /var/lib/uten-imp-release/recovery-ingress-finalizing.json
  /var/lib/uten-imp-release/internal-test-onboarding-adoption.json
  /var/lib/uten-imp-release/internal-test-activation-reauthorization.json
)

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

write_recovery_state() {
  local attempts="$1" last_uptime="$2"
  local temporary=''
  temporary="$(mktemp "${STATE_DIR}/.recovery-attempts.XXXXXX")" || return 1
  if ! printf '%s %s\n' "${attempts}" "${last_uptime}" >"${temporary}"; then
    rm -f -- "${temporary}" >/dev/null 2>&1 || :
    return 1
  fi
  if ! chmod 0640 "${temporary}"; then
    rm -f -- "${temporary}" >/dev/null 2>&1 || :
    return 1
  fi
  if ! mv -f -- "${temporary}" "${RECOVERY_STATE_FILE}"; then
    rm -f -- "${temporary}" >/dev/null 2>&1 || :
    return 1
  fi
}

transaction_is_clear() {
  local marker
  for marker in "${TRANSACTION_MARKERS[@]}"; do
    if [[ -e "${marker}" || -L "${marker}" ]]; then
      logger -p daemon.warning -t uten-imp-entry-watchdog \
        "recovery action blocked by a persistent release transaction marker"
      return 1
    fi
  done
}

read_uptime_seconds() {
  local uptime remainder
  read -r uptime remainder </proc/uptime || return 1
  uptime="${uptime%%.*}"
  [[ "${uptime}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${uptime}"
}

reserve_recovery_attempt() {
  local now attempts=0 last_uptime=0 extra='' required_delay=0
  now="$(read_uptime_seconds)" || return 1
  if [[ -e "${RECOVERY_STATE_FILE}" || -L "${RECOVERY_STATE_FILE}" ]]; then
    [[ -f "${RECOVERY_STATE_FILE}" && ! -L "${RECOVERY_STATE_FILE}" ]] || return 1
    read -r attempts last_uptime extra <"${RECOVERY_STATE_FILE}" || return 1
    [[ "${attempts}" =~ ^[0-9]+$ && "${last_uptime}" =~ ^[0-9]+$ && -z "${extra}" ]] \
      || return 1
    (( attempts <= MAX_TRACKED_RECOVERY_ATTEMPTS )) || return 1
  fi
  if (( last_uptime > now )); then
    logger -p daemon.err -t uten-imp-entry-watchdog \
      "recovery-attempt monotonic time moved backwards"
    return 1
  fi
  case "${attempts}" in
    0) required_delay=0 ;;
    1) required_delay=120 ;;
    2) required_delay=300 ;;
    3) required_delay=900 ;;
    *) required_delay=1800 ;;
  esac
  if (( last_uptime > 0 && now - last_uptime < required_delay )); then
    logger -p daemon.warning -t uten-imp-entry-watchdog \
      "automatic Nginx recovery is inside its bounded backoff window (${required_delay}s)"
    return 1
  fi
  if (( attempts < MAX_TRACKED_RECOVERY_ATTEMPTS )); then
    attempts=$((attempts + 1))
  fi
  if ! write_recovery_state "${attempts}" "${now}"; then
    logger -p daemon.err -t uten-imp-entry-watchdog \
      "cannot durably reserve the automatic recovery backoff state"
    return 1
  fi
  logger -p daemon.warning -t uten-imp-entry-watchdog \
    "reserved automatic Nginx recovery attempt ${attempts}; later failures back off to a 30-minute ceiling"
}

acquire_operation_gate() {
  [[ -f "${OPERATION_LOCK}" && ! -L "${OPERATION_LOCK}" ]] || return 1
  [[ "$(stat -c '%U:%G:%a:%h' -- "${OPERATION_LOCK}")" == root:uten-imp-updater:660:1 ]] \
    || return 1
  exec 8<"${OPERATION_LOCK}"
  flock -n 8 || {
    logger -p daemon.notice -t uten-imp-entry-watchdog \
      "release operation is in progress; entry recovery skipped"
    return 1
  }
  transaction_is_clear
}

application_is_ready() {
  curl --fail --silent --show-error --max-time 5 "${READINESS_URL}" \
    | jq -e '.status == "UP"' >/dev/null
}

entry_is_healthy() {
  local entry_body=''
  entry_body="$(curl --fail --silent --show-error --max-time 5 "${ENTRY_URL}")" \
    || return 1
  grep -Fq -- "${ENTRY_MARKER}" <<<"${entry_body}" || return 1
  application_is_ready
}

require_recovery_enablement() {
  systemctl is-enabled --quiet "${TIMER}" || {
    logger -p daemon.notice -t uten-imp-entry-watchdog \
      "entry watchdog timer is intentionally disabled; recovery skipped"
    return 1
  }
  systemctl is-enabled --quiet "${NGINX_SERVICE}" || {
    logger -p daemon.notice -t uten-imp-entry-watchdog \
      "Nginx boot unit is intentionally disabled; recovery skipped"
    return 1
  }
  systemctl is-enabled --quiet "${APPLICATION_SERVICE}" || {
    logger -p daemon.err -t uten-imp-entry-watchdog \
      "application boot unit is disabled; entry recovery refused"
    return 1
  }
}

close_ingress_for_readiness_failure() {
  transaction_is_clear || return 1
  if systemctl is-active --quiet "${NGINX_SERVICE}"; then
    if ! systemctl stop "${NGINX_SERVICE}"; then
      logger -p daemon.crit -t uten-imp-entry-watchdog \
        "backend readiness is DOWN and Nginx could not be stopped"
      return 1
    fi
  fi
  if [[ "$(systemctl show "${NGINX_SERVICE}" --property=ActiveState --value)" != inactive ]]; then
    logger -p daemon.crit -t uten-imp-entry-watchdog \
      "backend readiness is DOWN but Nginx is not proven inactive"
    return 1
  fi
  logger -p daemon.err -t uten-imp-entry-watchdog \
    "backend readiness remained DOWN at the failure threshold; Nginx ingress is closed"
}

if entry_is_healthy; then
  write_counter 0
  write_recovery_state 0 0
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
  "entry probe failed ${FAILURE_THRESHOLD} consecutive probes; evaluating bounded recovery"

acquire_operation_gate || exit 1
systemctl is-active --quiet "${APPLICATION_SERVICE}" || {
  logger -p daemon.warning -t uten-imp-entry-watchdog \
    "application is not active; closing ingress until the backend watchdog recovers it"
  close_ingress_for_readiness_failure || exit 1
  exit 1
}
application_is_ready || {
  close_ingress_for_readiness_failure || exit 1
  exit 1
}
require_recovery_enablement || exit 1
reserve_recovery_attempt || exit 1
transaction_is_clear || exit 1
require_recovery_enablement || exit 1
systemctl is-active --quiet "${APPLICATION_SERVICE}" || exit 1
application_is_ready || {
  close_ingress_for_readiness_failure || exit 1
  exit 1
}
systemctl reset-failed "${NGINX_SERVICE}"
if systemctl is-active --quiet "${NGINX_SERVICE}"; then
  nginx_action=restart
else
  nginx_action=start
fi
if systemctl "${nginx_action}" "${NGINX_SERVICE}"; then
  logger -p daemon.notice -t uten-imp-entry-watchdog \
    "bounded Nginx ${nginx_action} requested; attempt state remains until a later static-plus-readiness probe proves recovery"
else
  logger -p daemon.err -t uten-imp-entry-watchdog "bounded Nginx ${nginx_action} failed"
fi
exit 1
