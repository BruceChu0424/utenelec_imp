#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset BASH_ENV CDPATH ENV

readonly HEALTH_URL="${UTEN_WATCHDOG_HEALTH_URL:-http://127.0.0.1:8080/actuator/health/liveness}"
readonly FAILURE_THRESHOLD="${UTEN_WATCHDOG_FAILURE_THRESHOLD:-4}"
readonly STATE_DIR="${UTEN_WATCHDOG_STATE_DIR:-/run/uten-imp-watchdog}"
readonly COUNTER_FILE="${STATE_DIR}/failures"
readonly RECOVERY_STATE_FILE="${STATE_DIR}/recovery-attempts"
readonly SERVICE=uten-imp.service
readonly TIMER=uten-imp-watchdog.timer
readonly POSTGRES_META_SERVICE=postgresql.service
readonly POSTGRES_SERVICE=postgresql@16-main.service
readonly DATA_MOUNT_UNIT=data.mount
readonly STORAGE_AUTHORITY=/etc/uten-imp/storage-authority.json
readonly STORAGE_BOOT_VERIFIER=/usr/local/libexec/uten-imp-release/storage_boot_verifier.py
readonly STORAGE_HOST_OBSERVER=/usr/local/libexec/uten-imp-release/storage_mount_observer.py
readonly STORAGE_OBSERVER_UNIT=uten-imp-storage-observer.service
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
      logger -p daemon.warning -t uten-imp-watchdog \
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
  now="$(read_uptime_seconds)" || {
    logger -p daemon.err -t uten-imp-watchdog "cannot read monotonic uptime"
    return 1
  }
  if [[ -e "${RECOVERY_STATE_FILE}" || -L "${RECOVERY_STATE_FILE}" ]]; then
    [[ -f "${RECOVERY_STATE_FILE}" && ! -L "${RECOVERY_STATE_FILE}" ]] || {
      logger -p daemon.err -t uten-imp-watchdog "unsafe recovery-attempt state"
      return 1
    }
    read -r attempts last_uptime extra <"${RECOVERY_STATE_FILE}" || {
      logger -p daemon.err -t uten-imp-watchdog "unreadable recovery-attempt state"
      return 1
    }
    [[ "${attempts}" =~ ^[0-9]+$ && "${last_uptime}" =~ ^[0-9]+$ && -z "${extra}" ]] || {
      logger -p daemon.err -t uten-imp-watchdog "invalid recovery-attempt state"
      return 1
    }
    (( attempts <= MAX_TRACKED_RECOVERY_ATTEMPTS )) || {
      logger -p daemon.err -t uten-imp-watchdog "recovery-attempt state exceeds policy"
      return 1
    }
  fi
  if (( last_uptime > now )); then
    logger -p daemon.err -t uten-imp-watchdog "recovery-attempt monotonic time moved backwards"
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
    logger -p daemon.warning -t uten-imp-watchdog \
      "automatic recovery is inside its bounded backoff window (${required_delay}s)"
    return 1
  fi
  if (( attempts < MAX_TRACKED_RECOVERY_ATTEMPTS )); then
    attempts=$((attempts + 1))
  fi
  if ! write_recovery_state "${attempts}" "${now}"; then
    logger -p daemon.err -t uten-imp-watchdog \
      "cannot durably reserve the automatic recovery backoff state"
    return 1
  fi
  logger -p daemon.warning -t uten-imp-watchdog \
    "reserved automatic recovery attempt ${attempts}; later failures back off to a 30-minute ceiling"
}

prepare_data_mount_observation() {
  /usr/bin/python3 -I "${STORAGE_HOST_OBSERVER}" prepare-request
}

verify_and_consume_data_mount_observation() {
  /usr/bin/python3 -I "${STORAGE_HOST_OBSERVER}" verify-and-consume
}

verify_mounted_storage() {
  /usr/bin/python3 -I "${STORAGE_BOOT_VERIFIER}"
}

acquire_operation_gate() {
  [[ -f "${OPERATION_LOCK}" && ! -L "${OPERATION_LOCK}" ]] || {
    logger -p daemon.err -t uten-imp-watchdog "shared operation lock is missing or unsafe"
    return 1
  }
  [[ "$(stat -c '%U:%G:%a:%h' -- "${OPERATION_LOCK}")" == root:uten-imp-updater:660:1 ]] || {
    logger -p daemon.err -t uten-imp-watchdog "shared operation lock ownership or mode is unsafe"
    return 1
  }
  # flock supports an exclusive advisory lock on a read-only descriptor. Keep
  # the watchdog unable to modify the root/updater coordination inode.
  exec 8<"${OPERATION_LOCK}"
  flock -n 8 || {
    logger -p daemon.notice -t uten-imp-watchdog \
      "release operation is in progress; watchdog recovery skipped"
    return 1
  }
  # A release transaction can create its marker immediately before taking the
  # same lock. Recheck after owning the lock so a threshold crossing cannot
  # race activation or controlled recovery.
  transaction_is_clear
}

database_is_ready() {
  /usr/bin/pg_isready -q -h 127.0.0.1 -p 5432 -d uten_imp -t 2
}

recovery_enablement_is_clear() {
  systemctl is-enabled --quiet "${TIMER}" || {
    logger -p daemon.notice -t uten-imp-watchdog \
      "watchdog timer is intentionally disabled; recovery skipped"
    return 1
  }
  systemctl is-enabled --quiet "${SERVICE}" || {
    logger -p daemon.notice -t uten-imp-watchdog \
      "application boot unit is intentionally disabled; recovery skipped"
    return 1
  }
  systemctl is-enabled --quiet "${POSTGRES_META_SERVICE}" || {
    logger -p daemon.err -t uten-imp-watchdog \
      "PostgreSQL meta boot unit is not enabled; recovery refused"
    return 1
  }
  systemctl is-enabled --quiet "${POSTGRES_SERVICE}" || {
    logger -p daemon.err -t uten-imp-watchdog \
      "PostgreSQL instance boot unit is not enabled; recovery refused"
    return 1
  }
}

recheck_recovery_authorization() {
  # An activator writes its durable marker before waiting for operation.lock,
  # and an administrator can disable a unit while this process holds the lock.
  # Recheck both classes of intent immediately before every recovery action.
  transaction_is_clear && recovery_enablement_is_clear
}

if curl --fail --silent --show-error --max-time 5 "${HEALTH_URL}" \
  | jq -e '.status == "UP"' >/dev/null; then
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

logger -p daemon.warning -t uten-imp-watchdog \
  "liveness failure ${failures}/${FAILURE_THRESHOLD}"

if (( failures < FAILURE_THRESHOLD )); then
  exit 1
fi

logger -p daemon.err -t uten-imp-watchdog \
  "liveness failed ${FAILURE_THRESHOLD} consecutive probes; evaluating bounded recovery"

acquire_operation_gate || exit 1
recovery_enablement_is_clear || exit 1
[[ -L /opt/uten-imp/current && -r /opt/uten-imp/current/server/uten-imp-server.jar ]] || {
  logger -p daemon.err -t uten-imp-watchdog \
    "current release link or application JAR is unavailable; recovery refused"
  exit 1
}

recovery_attempt_reserved=false
data_mount_active=false
data_is_mounted=false
systemctl is-active --quiet "${DATA_MOUNT_UNIT}" && data_mount_active=true
mountpoint --quiet /data && data_is_mounted=true
if [[ "${data_mount_active}" != true || "${data_is_mounted}" != true ]]; then
  reserve_recovery_attempt || exit 1
  recovery_attempt_reserved=true
  recheck_recovery_authorization || exit 1
  if ! prepare_data_mount_observation; then
    logger -p daemon.err -t uten-imp-watchdog \
      "could not publish a short-lived /data host-observation request; automatic mount remains closed"
    exit 1
  fi
  recheck_recovery_authorization || exit 1
  systemctl start "${STORAGE_OBSERVER_UNIT}" || {
    logger -p daemon.err -t uten-imp-watchdog \
      "exact-device /data host observation failed; automatic mount remains closed"
    exit 1
  }
  if ! verify_and_consume_data_mount_observation; then
    logger -p daemon.err -t uten-imp-watchdog \
      "fresh /data host-observation receipt could not be consumed; automatic mount remains closed"
    exit 1
  fi
  recheck_recovery_authorization || exit 1
  systemctl reset-failed "${DATA_MOUNT_UNIT}" || {
    logger -p daemon.err -t uten-imp-watchdog \
      "could not reset the failed /data mount unit"
    exit 1
  }
  systemctl start "${DATA_MOUNT_UNIT}" || {
    logger -p daemon.err -t uten-imp-watchdog \
      "bounded /data mount start failed after read-only identity preflight"
    exit 1
  }
fi
mountpoint --quiet /data || {
  logger -p daemon.err -t uten-imp-watchdog \
    "/data is not mounted after bounded recovery"
  exit 1
}
systemctl is-active --quiet "${DATA_MOUNT_UNIT}" || {
  logger -p daemon.err -t uten-imp-watchdog \
    "/data is mounted but data.mount is not active; application recovery remains closed"
  exit 1
}
if ! verify_mounted_storage; then
  logger -p daemon.err -t uten-imp-watchdog \
    "mounted /data failed the fixed root storage verifier; database recovery remains closed"
  exit 1
fi

if ! database_is_ready; then
  if systemctl is-active --quiet "${POSTGRES_SERVICE}"; then
    logger -p daemon.warning -t uten-imp-watchdog \
      "PostgreSQL is active but not ready; waiting without restarting the database"
    exit 1
  fi
  if [[ "${recovery_attempt_reserved}" != true ]]; then
    reserve_recovery_attempt || exit 1
    recovery_attempt_reserved=true
  fi
  recheck_recovery_authorization || exit 1
  systemctl reset-failed "${POSTGRES_SERVICE}"
  systemctl start "${POSTGRES_SERVICE}" || {
    logger -p daemon.err -t uten-imp-watchdog "bounded PostgreSQL start failed"
    exit 1
  }
  database_ready=false
  for _ in {1..15}; do
    if database_is_ready; then
      database_ready=true
      break
    fi
    sleep 2
  done
  [[ "${database_ready}" == true ]] || {
    logger -p daemon.err -t uten-imp-watchdog \
      "PostgreSQL did not become ready after the bounded recovery start"
    exit 1
  }
else
  if [[ "${recovery_attempt_reserved}" != true ]]; then
    reserve_recovery_attempt || exit 1
    recovery_attempt_reserved=true
  fi
  recheck_recovery_authorization || exit 1
fi

recheck_recovery_authorization || exit 1
database_is_ready || {
  logger -p daemon.warning -t uten-imp-watchdog \
    "PostgreSQL readiness was lost before application restart; recovery deferred"
  exit 1
}
systemctl reset-failed "${SERVICE}"
if systemctl restart "${SERVICE}"; then
  logger -p daemon.notice -t uten-imp-watchdog \
    "bounded restart requested; attempt state remains until a later liveness probe proves recovery"
else
  logger -p daemon.err -t uten-imp-watchdog "bounded application restart failed"
fi
exit 1
