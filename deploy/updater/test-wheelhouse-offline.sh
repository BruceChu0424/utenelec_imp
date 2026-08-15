#!/usr/bin/env bash
# Install and test the updater on Ubuntu 24.04 with Docker networking disabled.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE PIP_INDEX_URL PIP_EXTRA_INDEX_URL

docker_bin="${UTEN_DOCKER_BIN:-docker}"
unset UTEN_DOCKER_BIN

die() {
  printf 'OFFLINE_WHEELHOUSE_TEST_REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: bash deploy/updater/test-wheelhouse-offline.sh --supply-chain /absolute/generated-directory\n'
}

supply_chain=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --supply-chain) [[ "$#" -ge 2 ]] || die 'missing --supply-chain value'; supply_chain="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$supply_chain" == /* && -d "$supply_chain" && ! -L "$supply_chain" ]] \
  || die '--supply-chain must be an absolute real directory'
if [[ "$docker_bin" == */* ]]; then
  [[ "$docker_bin" == /* && -x "$docker_bin" ]] || die 'UTEN_DOCKER_BIN must name an executable absolute path'
else
  docker_bin="$(command -v "$docker_bin")" || die 'docker is required'
fi

readonly SCRIPT_FILE="$(realpath -e -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(dirname -- "$SCRIPT_FILE")"
readonly PROJECT_ROOT="$(realpath -e -- "$SCRIPT_DIR/../..")"
readonly DOCKERFILE="$SCRIPT_DIR/wheelhouse/Dockerfile.ubuntu24-test"
[[ -f "$DOCKERFILE" && ! -L "$DOCKERFILE" ]] || die 'offline-test Dockerfile is missing or unsafe'

context="$SCRIPT_DIR/wheelhouse"
dockerfile="$DOCKERFILE"
supply_mount="$supply_chain"
project_mount="$PROJECT_ROOT"
if [[ "$docker_bin" == *.exe ]]; then
  command -v wslpath >/dev/null || die 'wslpath is required with a Windows Docker client'
  context="$(wslpath -w -- "$SCRIPT_DIR/wheelhouse")"
  dockerfile="$(wslpath -w -- "$DOCKERFILE")"
  supply_mount="$(wslpath -w -- "$supply_chain")"
  project_mount="$(wslpath -w -- "$PROJECT_ROOT")"
fi

image="uten-imp-wheelhouse-offline-test:$PPID-$$"
runtime_volume="uten-imp-wheelhouse-offline-runtime-$PPID-$$"
cleanup() {
  local status="$?"
  trap - EXIT
  "$docker_bin" volume rm --force "$runtime_volume" >/dev/null 2>&1 || true
  "$docker_bin" image rm --force "$image" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

"$docker_bin" build --pull=false --network default --tag "$image" \
  --file "$dockerfile" "$context"
"$docker_bin" volume create "$runtime_volume" >/dev/null

# Root creates and verifies the production-shaped venv in a disposable volume.
# A separate verifier container then mounts that venv read-only.  Neither phase
# has an external network, Linux capabilities, a writable image root, repository
# writes, or pip indexes.
"$docker_bin" run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 --user 0:0 \
  --tmpfs /tmp:rw,nosuid,nodev,mode=1777,size=64m \
  --mount "type=volume,src=$runtime_volume,dst=/runtime" \
  --mount "type=bind,src=$supply_mount,dst=/supply,readonly" \
  --mount "type=bind,src=$project_mount,dst=/repo,readonly" \
  --env PIP_CONFIG_FILE=/dev/null --env PIP_NO_INPUT=1 --env PIP_NO_CACHE_DIR=1 \
  --env PYTHONDONTWRITEBYTECODE=1 \
  "$image" bash -lc '
    set -Eeuo pipefail
    test ! -s /proc/net/route || ! grep -Eq "^[^[:space:]]+[[:space:]]+00000000[[:space:]]" /proc/net/route
    python3 -m venv /runtime/venv
    /runtime/venv/bin/python -m pip install \
      --disable-pip-version-check --no-index --no-deps --no-compile \
      --only-binary=:all: --require-hashes --find-links /supply/wheelhouse \
      --requirement /supply/updater-requirements.lock
    /runtime/venv/bin/python -m pip check
    /runtime/venv/bin/python -m pip uninstall --yes pip
    test -z "$(find /runtime/venv/lib/python3.12/site-packages -maxdepth 1 -iname "pip*.dist-info" -print -quit)"
    chmod -R a-w /runtime/venv
    /usr/bin/python3 -I /repo/deploy/updater/wheelhouse_supply_chain.py verify \
      --lock /supply/updater-requirements.lock \
      --wheelhouse /supply/wheelhouse \
      --sums /supply/updater-wheelhouse.SHA256SUMS \
      --sbom /supply/updater-wheelhouse.cdx.json \
      --attestation /supply/updater-wheelhouse.attestation.json \
      --venv /runtime/venv
  '

"$docker_bin" run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 --user 10001:10001 \
  --tmpfs /tmp:rw,nosuid,nodev,exec,uid=10001,gid=10001,mode=1777,size=64m \
  --mount "type=volume,src=$runtime_volume,dst=/runtime,readonly" \
  --mount "type=bind,src=$supply_mount,dst=/supply,readonly" \
  --mount "type=bind,src=$project_mount,dst=/repo,readonly" \
  --env HOME=/tmp --env PYTHONDONTWRITEBYTECODE=1 \
  "$image" bash -lc '
    set -Eeuo pipefail
    test ! -s /proc/net/route || ! grep -Eq "^[^[:space:]]+[[:space:]]+00000000[[:space:]]" /proc/net/route
    /runtime/venv/bin/python -I - <<'PY'
import crcmod
import cryptography
import oss2
import requests

assert oss2.__version__ == "2.19.1"
assert isinstance(crcmod.mkCrcFun(0x104C11DB7)(b"uten-imp"), int)
assert requests.__version__ == "2.34.2"
assert cryptography.__version__ == "50.0.0"
PY
    /runtime/venv/bin/python -I -m unittest discover \
      -s /repo/deploy/updater -p "test*.py" -v
  '

trap - EXIT
"$docker_bin" volume rm --force "$runtime_volume" >/dev/null
"$docker_bin" image rm --force "$image" >/dev/null
printf 'OFFLINE_UBUNTU24_WHEELHOUSE_TEST_PASS\n'
