#!/usr/bin/env bash
# Root-owned ExecStartPre guard for the isolated Next.js website service.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

[[ $# -le 1 ]] || { printf '%s\n' 'WEBSITE_RUNTIME_REFUSED: usage: validate-runtime [--boot]' >&2; exit 1; }
if [[ $# -eq 1 ]]; then
  [[ $1 == --boot ]] || { printf '%s\n' 'WEBSITE_RUNTIME_REFUSED: unknown validation mode' >&2; exit 1; }
  readonly BOOT_MODE=true
else
  readonly BOOT_MODE=false
fi

die() {
  printf 'WEBSITE_RUNTIME_REFUSED: %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die 'validator must run as root'
for command_name in dirname find getfacl od readlink sed stat tr; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

readonly BASE=/opt/uten-website
readonly RELEASES=$BASE/releases
readonly CURRENT=$BASE/current
readonly EXPECTED_STATE=/var/lib/uten-website/runtime
readonly EXPECTED_UPLOADS=/var/lib/uten-website/runtime/uploads
readonly EXPECTED_UPLOAD_STAGING=/var/lib/uten-website/runtime/upload-staging
readonly EXPECTED_CACHE=/var/cache/uten-website
readonly EXPECTED_DATABASE=/var/lib/uten-website/runtime/website.db
readonly ENV_FILE=/etc/uten-website/website.env
readonly ENV_DIR=/etc/uten-website

for directory in "$BASE" "$RELEASES" "$EXPECTED_STATE" "$EXPECTED_UPLOADS" "$EXPECTED_UPLOAD_STAGING" "$EXPECTED_CACHE"; do
  [[ -d "$directory" && ! -L "$directory" ]] || die "required real directory is missing: $directory"
done
[[ -L "$CURRENT" ]] || die "$CURRENT must be a symbolic link"
[[ "$(find -P "$CURRENT" -maxdepth 0 -type l -user root -print)" == "$CURRENT" ]] \
  || die 'current symlink must be root-owned'

for controlled_directory in "$BASE" "$RELEASES"; do
  [[ "$(stat -c '%u' -- "$controlled_directory")" == 0 ]] \
    || die "controlled directory is not root-owned: $controlled_directory"
  controlled_mode="$(stat -c '%a' -- "$controlled_directory")"
  (( (8#$controlled_mode & 022) == 0 )) \
    || die "controlled directory is group/world-writable: $controlled_directory"
done

release="$(readlink -f -- "$CURRENT")"
[[ -n "$release" && -d "$release" && ! -L "$release" ]] || die 'current does not resolve to a real release directory'
[[ "$(dirname -- "$release")" == "$RELEASES" ]] \
  || die "current must resolve to a direct child of $RELEASES"

unsafe_entry="$(find -P "$release" -xdev \
  ! -type l \( ! -user root -o -perm /022 \) -print -quit)"
[[ -z "$unsafe_entry" ]] \
  || die "release tree contains a non-root-owned or writable entry: $unsafe_entry"

[[ -f "$release/server.js" && ! -L "$release/server.js" ]] || die 'standalone server.js is missing or unsafe'
[[ ! -e "$release/public/uploads" && ! -L "$release/public/uploads" ]] \
  || die 'immutable release must not contain or link a runtime uploads path'
[[ -L "$release/.next/cache" ]] || die 'runtime cache path must be a symlink'
[[ "$(readlink -f -- "$release/.next/cache")" == "$EXPECTED_CACHE" ]] \
  || die "cache symlink must resolve exactly to $EXPECTED_CACHE"

while IFS= read -r release_link; do
  [[ -z "$release_link" ]] && continue
  case "$release_link" in
    "$release/.next/cache") ;;
    *) die "release tree contains an unexpected symbolic link: $release_link" ;;
  esac
done < <(find -P "$release" -xdev -type l -print)

for state_directory in "$EXPECTED_STATE" "$EXPECTED_CACHE"; do
  [[ "$(stat -c '%U:%G' -- "$state_directory")" == 'uten-website:uten-website' ]] \
    || die "runtime state must be owned by uten-website: $state_directory"
  [[ "$(stat -c '%a' -- "$state_directory")" == 750 ]] \
    || die "runtime state must be exact mode 0750 so the service can write without world access: $state_directory"
done

expected_state_acl=$'user::rwx\ngroup::r-x\ngroup:uten-website-media:--x\nmask::r-x\nother::---'
actual_state_acl="$(getfacl -cp -- "$EXPECTED_STATE" | sed '/^$/d')"
[[ "$actual_state_acl" == "$expected_state_acl" ]] \
  || die "$EXPECTED_STATE must grant only traverse access to uten-website-media"

[[ "$(stat -c '%U:%G:%a' -- "$EXPECTED_UPLOADS")" == 'uten-website:uten-website-media:2750' ]] \
  || die "$EXPECTED_UPLOADS must be uten-website:uten-website-media mode 2750"
[[ "$(stat -c '%U:%G:%a' -- "$EXPECTED_UPLOAD_STAGING")" == 'uten-website:uten-website-media:2700' ]] \
  || die "$EXPECTED_UPLOAD_STAGING must be uten-website:uten-website-media mode 2700"
unsafe_staging_type="$(find -P "$EXPECTED_UPLOAD_STAGING" -xdev -mindepth 1 ! -type f -print -quit)"
[[ -z "$unsafe_staging_type" ]] || die "upload staging contains a symlink/directory/special file: $unsafe_staging_type"
unsafe_staging_file="$(find -P "$EXPECTED_UPLOAD_STAGING" -xdev -type f \
  \( ! -user uten-website -o ! -group uten-website-media -o ! -perm 0640 -o ! -links 1 \) -print -quit)"
[[ -z "$unsafe_staging_file" ]] || die "upload staging file ownership/mode/link count is unsafe: $unsafe_staging_file"
if ! $BOOT_MODE; then
  unsafe_upload_type="$(find -P "$EXPECTED_UPLOADS" -xdev -mindepth 1 ! -type d ! -type f -print -quit)"
  [[ -z "$unsafe_upload_type" ]] || die "uploads tree contains a symlink or special file: $unsafe_upload_type"
  unsafe_upload_directory="$(find -P "$EXPECTED_UPLOADS" -xdev -mindepth 1 -type d \
    \( ! -user uten-website -o ! -group uten-website-media -o ! -perm 2750 \) -print -quit)"
  [[ -z "$unsafe_upload_directory" ]] \
    || die "uploads directory ownership or mode is unsafe: $unsafe_upload_directory"
  unsafe_upload_file="$(find -P "$EXPECTED_UPLOADS" -xdev -type f \
    \( ! -user uten-website -o ! -group uten-website-media -o ! -perm 0640 -o ! -links 1 -o -size 0c \) -print -quit)"
  [[ -z "$unsafe_upload_file" ]] \
    || die "uploads file ownership, mode, link count or size is unsafe: $unsafe_upload_file"
  while IFS= read -r -d '' upload_entry; do
    upload_name="${upload_entry##*/}"
    [[ "$upload_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "uploads entry has an unsafe filename: $upload_entry"
    if [[ -f "$upload_entry" && ! "$upload_name" =~ \.(gif|jpe?g|png|webp)$ ]]; then
      die "uploads file has an unapproved extension: $upload_entry"
    fi
  done < <(find -P "$EXPECTED_UPLOADS" -xdev -mindepth 1 -print0)
fi

[[ -f "$EXPECTED_DATABASE" && ! -L "$EXPECTED_DATABASE" ]] \
  || die "$EXPECTED_DATABASE must be an explicitly restored regular SQLite file"
[[ "$(stat -c '%U:%G:%a:%h' -- "$EXPECTED_DATABASE")" == 'uten-website:uten-website:600:1' ]] \
  || die "$EXPECTED_DATABASE must be uten-website:uten-website mode 0600 with one hard link"
database_size="$(stat -c '%s' -- "$EXPECTED_DATABASE")"
(( database_size >= 4096 )) || die "$EXPECTED_DATABASE is too small to be an approved SQLite database"
database_header="$(od -An -N16 -tx1 -- "$EXPECTED_DATABASE" | tr -d '[:space:]')"
[[ "$database_header" == 53514c69746520666f726d6174203300 ]] \
  || die "$EXPECTED_DATABASE does not have the SQLite 3 file header"

[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "$ENV_FILE must be a regular file"
[[ -d "$ENV_DIR" && ! -L "$ENV_DIR" ]] || die "$ENV_DIR must be a real directory"
[[ "$(stat -c '%U:%G:%a' -- "$ENV_DIR")" == 'root:uten-website:750' ]] \
  || die "$ENV_DIR must be root:uten-website mode 0750"
[[ "$(stat -c '%U:%G:%a' -- "$ENV_FILE")" == 'root:uten-website:640' ]] \
  || die "$ENV_FILE must be root:uten-website mode 0640"
[[ "$(stat -c '%h' -- "$ENV_FILE")" == 1 ]] || die "$ENV_FILE must have one hard link"

[[ -x /usr/bin/python3 ]] || die '/usr/bin/python3 is required for strict website.env validation'
/usr/bin/python3 -I - "$ENV_FILE" <<'PY'
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

path = Path(sys.argv[1])
raw = path.read_bytes()
if not raw or len(raw) > 64 * 1024 or b"\0" in raw or b"\r" in raw:
    raise SystemExit("website.env must be non-empty, below 64 KiB, and contain no NUL/CR bytes")
try:
    text = raw.decode("utf-8")
except UnicodeDecodeError as exc:
    raise SystemExit("website.env must be UTF-8") from exc

allowed = {
    "DATABASE_URL",
    "UPLOADS_DIR",
    "AUTH_SECRET",
    "SITE_URL",
    "INQUIRY_TRUSTED_CLIENT_IP_HEADER",
    "ADMIN_TRUSTED_CLIENT_IP_HEADER",
    "INQUIRY_RATE_CLIENT_MINUTE",
    "INQUIRY_RATE_CLIENT_HOUR",
    "INQUIRY_RATE_GLOBAL_MINUTE",
    "INQUIRY_RATE_GLOBAL_HOUR",
    "ALLOW_DESTRUCTIVE_SEED",
}
# IMP 询盘推送是可选链路：两个键要么同时出现，要么同时缺席（缺席=官网只落本地库）。
optional = {"IMP_INGEST_URL", "IMP_INGEST_TOKEN"}
values = {}
for number, line in enumerate(text.splitlines(), 1):
    if not line or line.startswith("#"):
        continue
    match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=([^\s'\"\\`$#;]+)", line)
    if not match:
        raise SystemExit(f"website.env line {number} is not canonical KEY=value data")
    key, value = match.groups()
    if key not in allowed and key not in optional:
        raise SystemExit(f"website.env contains unapproved key {key}")
    if key in values:
        raise SystemExit(f"website.env contains duplicate key {key}")
    values[key] = value
if set(values) - optional != allowed:
    missing = sorted(allowed - set(values))
    raise SystemExit(f"website.env exact key set is incomplete: {missing}")
if optional & set(values) and optional - set(values):
    raise SystemExit("IMP_INGEST_URL and IMP_INGEST_TOKEN must be configured as a pair")

if values["DATABASE_URL"] != "file:/var/lib/uten-website/runtime/website.db":
    raise SystemExit("DATABASE_URL must point exactly to the backed-up persistent SQLite file")
if values["UPLOADS_DIR"] != "/var/lib/uten-website/runtime/uploads":
    raise SystemExit("UPLOADS_DIR must point exactly to the durable shared media directory")
if values["ALLOW_DESTRUCTIVE_SEED"] != "false":
    raise SystemExit("ALLOW_DESTRUCTIVE_SEED must be false in the runtime service")
if values["INQUIRY_TRUSTED_CLIENT_IP_HEADER"] != "x-real-ip" or values["ADMIN_TRUSTED_CLIENT_IP_HEADER"] != "x-real-ip":
    raise SystemExit("trusted client IP headers must match the Nginx x-real-ip overwrite boundary")

secret = values["AUTH_SECRET"]
normalized = re.sub(r"[^a-z0-9]", "", secret.casefold())
forbidden = (
    "changeme", "replaceme", "placeholder", "password", "secret", "uten",
    "website", "production", "development", "default", "example", "0123456789",
    "abcdefghijklmnopqrstuvwxyz",
)
random_hex = re.fullmatch(r"[A-Fa-f0-9]{64,}", secret) is not None
random_base64 = (
    re.fullmatch(r"[A-Za-z0-9+/_-]+={0,2}", secret) is not None
    and re.search(r"[a-z]", secret)
    and re.search(r"[A-Z]", secret)
    and re.search(r"[0-9]", secret)
)
if len(secret) < 43 or len(set(secret)) < 16 or any(marker in normalized for marker in forbidden) or not (random_hex or random_base64):
    raise SystemExit("AUTH_SECRET is weak or looks like a placeholder")

site = urlsplit(values["SITE_URL"])
if (
    site.scheme != "https" or not site.hostname or site.username or site.password
    or site.port not in (None, 443) or site.path not in ("", "/")
    or site.query or site.fragment or site.hostname != site.hostname.lower()
    or not re.fullmatch(r"(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", site.hostname)
):
    raise SystemExit("SITE_URL must be one canonical lowercase HTTPS origin")

limits = {
    "INQUIRY_RATE_CLIENT_MINUTE": (1, 100),
    "INQUIRY_RATE_CLIENT_HOUR": (1, 1_000),
    "INQUIRY_RATE_GLOBAL_MINUTE": (1, 10_000),
    "INQUIRY_RATE_GLOBAL_HOUR": (1, 100_000),
}
parsed = {}
for key, (minimum, maximum) in limits.items():
    value = values[key]
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise SystemExit(f"{key} must be a canonical positive integer")
    parsed[key] = int(value)
    if not minimum <= parsed[key] <= maximum:
        raise SystemExit(f"{key} is outside the reviewed application range")
if parsed["INQUIRY_RATE_CLIENT_HOUR"] < parsed["INQUIRY_RATE_CLIENT_MINUTE"]:
    raise SystemExit("client hourly rate must be at least the client minute rate")
if parsed["INQUIRY_RATE_GLOBAL_MINUTE"] < parsed["INQUIRY_RATE_CLIENT_MINUTE"]:
    raise SystemExit("global minute rate must be at least the client minute rate")
if parsed["INQUIRY_RATE_GLOBAL_HOUR"] < parsed["INQUIRY_RATE_GLOBAL_MINUTE"]:
    raise SystemExit("global hourly rate must be at least the global minute rate")

if "IMP_INGEST_URL" in values:
    ingest = urlsplit(values["IMP_INGEST_URL"])
    if (
        ingest.scheme != "https" or not ingest.hostname or ingest.username or ingest.password
        or ingest.query or ingest.fragment
        or ingest.path != "/api/website-inquiries/ingest"
    ):
        raise SystemExit("IMP_INGEST_URL must be one HTTPS URL with the exact /api/website-inquiries/ingest path")
    token = values["IMP_INGEST_TOKEN"]
    token_normalized = re.sub(r"[^a-z0-9]", "", token.casefold())
    if (
        len(token) < 32 or len(set(token)) < 12
        or any(marker in token_normalized for marker in forbidden)
    ):
        raise SystemExit("IMP_INGEST_TOKEN is weak or looks like a placeholder")
PY

printf '%s\n' 'WEBSITE_RUNTIME_OK'
