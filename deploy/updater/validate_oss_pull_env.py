#!/usr/bin/env python3
"""Fail-closed validation for the downloader EnvironmentFile without printing secrets."""

from __future__ import annotations

import re
import stat
import sys
import urllib.parse
from pathlib import Path


MAX_BYTES = 64 * 1024
ALLOWED_KEYS = {
    "OSS_ACCESS_KEY_ID",
    "OSS_ACCESS_KEY_SECRET",
    "OSS_BUCKET",
    "OSS_ENDPOINT",
    "OSS_SECURITY_TOKEN",
}
REQUIRED_KEYS = {
    "OSS_ACCESS_KEY_ID",
    "OSS_ACCESS_KEY_SECRET",
    "OSS_BUCKET",
    "OSS_ENDPOINT",
}
KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
ACCESS_KEY_RE = re.compile(r"^[A-Za-z0-9._-]{8,128}$")
SECRET_RE = re.compile(r"^[A-Za-z0-9._~+/=:%-]{16,4096}$")
BUCKET_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")
HOST_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)
FORBIDDEN_VALUE_CHARS = frozenset({" ", "\t", "'", '"', "\\", "`", "$", "#", ";"})


def fail(message: str) -> None:
    print(f"OSS pull environment rejected: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_directory_chain(path: Path, updater_gid: int) -> None:
    current = path
    first = True
    while True:
        details = current.lstat()
        if not stat.S_ISDIR(details.st_mode) or current.is_symlink():
            fail(f"unsafe directory in trusted path: {current}")
        if details.st_uid != 0 or stat.S_IMODE(details.st_mode) & 0o022:
            fail(f"trusted directory is not root-controlled: {current}")
        if first and (
            details.st_gid != updater_gid or stat.S_IMODE(details.st_mode) != 0o750
        ):
            fail("/etc/uten-imp-updater must be root:uten-imp-updater mode 0750")
        if current == current.parent:
            break
        current = current.parent
        first = False


def validate_metadata(path: Path) -> None:
    import grp

    try:
        updater_gid = grp.getgrnam("uten-imp-updater").gr_gid
    except KeyError:
        fail("dedicated updater group does not exist")
    validate_directory_chain(path.parent, updater_gid)
    details = path.lstat()
    if not stat.S_ISREG(details.st_mode) or path.is_symlink():
        fail("environment file must be a regular non-symlink file")
    if details.st_uid != 0 or details.st_gid != updater_gid:
        fail("environment file must be root:uten-imp-updater")
    if stat.S_IMODE(details.st_mode) != 0o640:
        fail("environment file mode must be 0640")
    if details.st_nlink != 1:
        fail("environment file must have exactly one hard link")
    if details.st_size < 1 or details.st_size > MAX_BYTES:
        fail("environment file size is outside the accepted range")


def validate_source_metadata(path: Path) -> None:
    details = path.lstat()
    if not stat.S_ISREG(details.st_mode) or path.is_symlink():
        fail("credential source must be a regular non-symlink file")
    if details.st_uid != 0 or details.st_gid != 0:
        fail("credential source must be root:root")
    if stat.S_IMODE(details.st_mode) != 0o600:
        fail("credential source mode must be 0600")
    if details.st_nlink != 1:
        fail("credential source must have exactly one hard link")
    if details.st_size < 1 or details.st_size > MAX_BYTES:
        fail("credential source size is outside the accepted range")
    current = path.parent
    while True:
        parent_details = current.lstat()
        if not stat.S_ISDIR(parent_details.st_mode) or current.is_symlink():
            fail(f"unsafe directory in credential-source path: {current}")
        if parent_details.st_uid != 0 or stat.S_IMODE(parent_details.st_mode) & 0o022:
            fail(f"credential-source directory is not root-controlled: {current}")
        if current == current.parent:
            break
        current = current.parent


def validate_endpoint(value: str) -> None:
    parsed = urllib.parse.urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
        or parsed.hostname != parsed.hostname.lower()
        or not HOST_RE.fullmatch(parsed.hostname)
    ):
        fail("OSS_ENDPOINT must be a lowercase HTTPS origin without credentials, port, or path")


def parse(path: Path) -> dict[str, str]:
    raw = path.read_bytes()
    if not raw.endswith(b"\n"):
        fail("environment file must end with a newline")
    if b"\x00" in raw or b"\r" in raw:
        fail("environment file contains forbidden control bytes")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        fail("environment file must be canonical ASCII")
    values: dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line or line.startswith("#"):
            continue
        if line != line.strip() or line[0].isspace():
            fail(f"line {line_number} has leading or trailing whitespace")
        if line.count("=") < 1:
            fail(f"line {line_number} is not KEY=value")
        key, value = line.split("=", 1)
        if not KEY_RE.fullmatch(key) or key not in ALLOWED_KEYS:
            fail(f"line {line_number} contains an unsupported key")
        if key in values:
            fail(f"duplicate key: {key}")
        if not value or any(character in FORBIDDEN_VALUE_CHARS for character in value):
            fail(f"{key} requires an unquoted canonical value")
        if any(ord(character) < 0x21 or ord(character) == 0x7F for character in value):
            fail(f"{key} contains a control character")
        if re.search(r"(?i)(replace|pending|changeme)", value):
            fail(f"{key} still contains a placeholder")
        values[key] = value
    missing = REQUIRED_KEYS - values.keys()
    if missing:
        fail("missing one or more required OSS keys")
    return values


def main() -> int:
    source_mode = len(sys.argv) == 3 and sys.argv[1] == "--source"
    if len(sys.argv) == 2:
        path = Path(sys.argv[1])
        if path != Path("/etc/uten-imp-updater/oss-pull.env"):
            fail("only the fixed production environment path is accepted")
        validate_metadata(path)
    elif source_mode:
        path = Path(sys.argv[2])
        if not path.is_absolute():
            fail("credential source path must be absolute")
        validate_source_metadata(path)
    else:
        fail(
            "usage: validate_oss_pull_env.py /etc/uten-imp-updater/oss-pull.env "
            "| --source /ROOT_CONTROLLED/oss-pull.env"
        )
    values = parse(path)
    if not ACCESS_KEY_RE.fullmatch(values["OSS_ACCESS_KEY_ID"]):
        fail("OSS_ACCESS_KEY_ID has an invalid shape")
    if not SECRET_RE.fullmatch(values["OSS_ACCESS_KEY_SECRET"]):
        fail("OSS_ACCESS_KEY_SECRET has an invalid shape")
    token = values.get("OSS_SECURITY_TOKEN")
    if token is not None and not SECRET_RE.fullmatch(token):
        fail("OSS_SECURITY_TOKEN has an invalid shape")
    if not BUCKET_RE.fullmatch(values["OSS_BUCKET"]):
        fail("OSS_BUCKET has an invalid shape")
    validate_endpoint(values["OSS_ENDPOINT"])
    print("OSS_PULL_ENV_SOURCE_VALID" if source_mode else "OSS_PULL_ENV_VALID")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
