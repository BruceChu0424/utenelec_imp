#!/usr/bin/env bash
# Fixed Nginx startup gate: never expose the ERP entry before the backend is ready.
set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset BASH_ENV CDPATH ENV

readonly READINESS_URL=http://127.0.0.1:8080/actuator/health/readiness
readonly DEADLINE_SECONDS=75
readonly MAX_BODY_BYTES=65536

if [[ "$#" -ne 0 ]]; then
  logger -p daemon.err -t uten-imp-readiness-gate \
    'fixed readiness gate accepts no arguments'
  exit 2
fi

deadline=$((SECONDS + DEADLINE_SECONDS))
while (( SECONDS < deadline )); do
  body=''
  if body="$(
    curl --fail --silent --show-error \
      --connect-timeout 2 --max-time 3 --max-filesize "${MAX_BODY_BYTES}" \
      --header 'Accept: application/json' \
      "${READINESS_URL}" 2>/dev/null
  )" && jq -e 'type == "object" and .status == "UP"' <<<"${body}" >/dev/null; then
    exit 0
  fi
  sleep 2
done

logger -p daemon.err -t uten-imp-readiness-gate \
  'backend readiness did not become UP before the bounded Nginx startup deadline'
exit 1
