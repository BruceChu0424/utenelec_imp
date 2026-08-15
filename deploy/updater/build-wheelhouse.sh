#!/usr/bin/env bash
# Build the updater wheelhouse in a no-secret, digest-pinned and network-separated container.
set -Eeuo pipefail
umask 0077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE PIP_INDEX_URL PIP_EXTRA_INDEX_URL

docker_bin="${UTEN_DOCKER_BIN:-docker}"
unset UTEN_DOCKER_BIN

readonly BUILDER_IMAGE='python:3.12.11-slim-bookworm@sha256:519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7'
readonly SOURCE_DATE_EPOCH=1711929600

die() {
  printf 'WHEELHOUSE_BUILD_REFUSED: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash deploy/updater/build-wheelhouse.sh \
    --output /absolute/output/directory \
    --commit 40_lowercase_hex \
    --timestamp YYYY-MM-DDTHH:MM:SSZ

The output directory must not exist. Network access is used only to download
hash-locked wheels, build tools, and source archives. Source build execution
runs in a second container with --network none and no repository mount.
EOF
}

output=''
commit=''
timestamp=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output) [[ "$#" -ge 2 ]] || die 'missing --output value'; output="$2"; shift 2 ;;
    --commit) [[ "$#" -ge 2 ]] || die 'missing --commit value'; commit="$2"; shift 2 ;;
    --timestamp) [[ "$#" -ge 2 ]] || die 'missing --timestamp value'; timestamp="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die '--commit must be 40 lowercase hexadecimal characters'
[[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || die '--timestamp must be canonical second-precision UTC'
[[ "$output" == /* ]] || die '--output must be an absolute path'
[[ ! -e "$output" && ! -L "$output" ]] || die '--output must not already exist'
if [[ "$docker_bin" == */* ]]; then
  [[ "$docker_bin" == /* && -x "$docker_bin" ]] || die 'UTEN_DOCKER_BIN must name an executable absolute path'
else
  docker_bin="$(command -v "$docker_bin")" || die 'docker is required'
fi
command -v python3 >/dev/null || die 'python3 is required'

readonly SCRIPT_FILE="$(realpath -e -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(dirname -- "$SCRIPT_FILE")"
readonly CONFIG_DIR="$SCRIPT_DIR/wheelhouse"
readonly TOOL="$SCRIPT_DIR/wheelhouse_supply_chain.py"
readonly REQUIREMENTS_INPUT="$CONFIG_DIR/requirements.in"
readonly RUNTIME_LOCK="$CONFIG_DIR/requirements.lock"
readonly SOURCE_LOCK="$CONFIG_DIR/source-requirements.lock"
readonly BUILD_LOCK="$CONFIG_DIR/build-requirements.lock"
for file in "$TOOL" "$REQUIREMENTS_INPUT" "$RUNTIME_LOCK" "$SOURCE_LOCK" "$BUILD_LOCK"; do
  [[ -f "$file" && ! -L "$file" ]] || die "required reviewed input is missing or unsafe: $file"
done

output_parent="$(dirname -- "$output")"
[[ -d "$output_parent" && ! -L "$output_parent" ]] || die 'output parent must be a real directory'
work="$(mktemp -d "$output_parent/.uten-wheelhouse-build.XXXXXX")"
staged="$(mktemp -d "$output_parent/.uten-wheelhouse-output.XXXXXX")"
cleanup() {
  local status="$?"
  trap - EXIT
  if [[ -d "$work" && "$work" == "$output_parent"/.uten-wheelhouse-build.* ]]; then
    rm -rf -- "$work"
  fi
  if [[ -d "$staged" && "$staged" == "$output_parent"/.uten-wheelhouse-output.* ]]; then
    rm -rf -- "$staged"
  fi
  exit "$status"
}
trap cleanup EXIT

install -m 0444 "$TOOL" "$work/wheelhouse_supply_chain.py"
install -m 0444 "$RUNTIME_LOCK" "$work/requirements.lock"
install -m 0444 "$SOURCE_LOCK" "$work/source-requirements.lock"
install -m 0444 "$BUILD_LOCK" "$work/build-requirements.lock"
python3 -I "$TOOL" render-binary-lock \
  --lock "$RUNTIME_LOCK" --source-lock "$SOURCE_LOCK" \
  --output "$work/binary-requirements.lock"

mount_source="$work"
if [[ "$docker_bin" == *.exe ]]; then
  command -v wslpath >/dev/null || die 'wslpath is required with a Windows Docker client'
  mount_source="$(wslpath -w -- "$work")"
fi
readonly host_uid="$(id -u)"
readonly host_gid="$(id -g)"
[[ "$host_uid" != 0 && "$host_gid" != 0 ]] \
  || die 'wheelhouse build must run as an unprivileged host user and group'

"$docker_bin" pull "$BUILDER_IMAGE" >/dev/null
[[ "$("$docker_bin" image inspect --format '{{.Os}}/{{.Architecture}}' "$BUILDER_IMAGE")" == linux/amd64 ]] \
  || die 'builder image is not linux/amd64'

# This container downloads only. The source downloader never invokes package metadata.
"$docker_bin" run --rm --network bridge --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 \
  --tmpfs /tmp:rw,nosuid,nodev,exec,size=512m \
  --mount "type=bind,src=$mount_source,dst=/work" \
  --user "$host_uid:$host_gid" --env HOME=/tmp \
  --env PIP_CONFIG_FILE=/dev/null --env PIP_NO_INPUT=1 \
  "$BUILDER_IMAGE" sh -lc '
    set -eu
    python -I /work/wheelhouse_supply_chain.py download-sources \
      --source-lock /work/source-requirements.lock --destination /work/sources
    mkdir -p /work/build-tools /work/binary-wheels
    python -m pip download --disable-pip-version-check --no-deps \
      --only-binary=:all: --require-hashes --index-url https://pypi.org/simple \
      --dest /work/build-tools --requirement /work/build-requirements.lock
    python -m pip download --disable-pip-version-check --no-deps \
      --only-binary=:all: --require-hashes --index-url https://pypi.org/simple \
      --platform manylinux_2_34_x86_64 --platform manylinux_2_28_x86_64 \
      --platform manylinux_2_17_x86_64 --platform manylinux2014_x86_64 --platform any \
      --python-version 3.12 --implementation cp --abi cp312 --abi abi3 --abi none \
      --dest /work/binary-wheels --requirement /work/binary-requirements.lock
  '

# Untrusted sdist build code receives no network, repository, Docker socket, or secrets.
"$docker_bin" run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 256 \
  --tmpfs /tmp:rw,nosuid,nodev,exec,size=512m \
  --mount "type=bind,src=$mount_source,dst=/work" \
  --user "$host_uid:$host_gid" --env HOME=/tmp \
  --env PIP_CONFIG_FILE=/dev/null --env PIP_NO_INPUT=1 --env PIP_NO_CACHE_DIR=1 \
  --env PYTHONHASHSEED=0 --env SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  --env LC_ALL=C.UTF-8 \
  "$BUILDER_IMAGE" sh -lc '
    set -eu
    python -m venv /tmp/build-venv
    /tmp/build-venv/bin/python -m pip install --disable-pip-version-check --no-index --no-deps \
      --only-binary=:all: --require-hashes --find-links /work/build-tools \
      --requirement /work/build-requirements.lock
    mkdir -p /work/built-wheels /work/wheelhouse
    CC=/bin/false /tmp/build-venv/bin/python -m pip wheel --disable-pip-version-check --no-index \
      --no-deps --no-build-isolation --wheel-dir /work/built-wheels \
      /work/sources/aliyun-python-sdk-core-2.16.0.tar.gz \
      /work/sources/crcmod-1.7.tar.gz /work/sources/oss2-2.19.1.tar.gz
    cp /work/binary-wheels/*.whl /work/built-wheels/*.whl /work/wheelhouse/
  '

python3 -I "$TOOL" render-runtime-lock \
  --wheelhouse "$work/wheelhouse" --output "$work/generated-requirements.lock"
cmp -s -- "$work/generated-requirements.lock" "$RUNTIME_LOCK" \
  || die 'reviewed runtime lock is not the canonical exact lock for the built wheelhouse'

install -d -m 0755 "$staged/wheelhouse" "$staged/build-evidence"
install -m 0444 "$work"/wheelhouse/*.whl "$staged/wheelhouse/"
install -m 0444 "$REQUIREMENTS_INPUT" "$staged/updater-requirements.in"
install -m 0444 "$RUNTIME_LOCK" "$staged/updater-requirements.lock"
install -m 0444 "$SOURCE_LOCK" "$staged/build-evidence/source-requirements.lock"
install -m 0444 "$BUILD_LOCK" "$staged/build-evidence/build-requirements.lock"

python3 -I "$TOOL" generate \
  --requirements-input "$REQUIREMENTS_INPUT" --source-lock "$SOURCE_LOCK" \
  --build-lock "$BUILD_LOCK" --builder-script "$SCRIPT_FILE" \
  --verifier-source "$TOOL" --lock "$RUNTIME_LOCK" \
  --wheelhouse "$staged/wheelhouse" \
  --sums "$staged/updater-wheelhouse.SHA256SUMS" \
  --sbom "$staged/updater-wheelhouse.cdx.json" \
  --attestation "$staged/updater-wheelhouse.attestation.json" \
  --commit "$commit" --timestamp "$timestamp" --builder-image "$BUILDER_IMAGE"
python3 -I "$TOOL" verify \
  --lock "$staged/updater-requirements.lock" --wheelhouse "$staged/wheelhouse" \
  --sums "$staged/updater-wheelhouse.SHA256SUMS" \
  --sbom "$staged/updater-wheelhouse.cdx.json" \
  --attestation "$staged/updater-wheelhouse.attestation.json"

chmod -R a-w "$staged"
mv -T -- "$staged" "$output"
staged=''
trap - EXIT
rm -rf -- "$work"
printf 'WHEELHOUSE_BUILD_COMPLETE: %s\n' "$output"
