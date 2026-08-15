#!/usr/bin/env python3
"""Small, dependency-free primitives shared by the host monitoring probes.

The production scripts are installed together in one root-owned directory and
load this file by its absolute sibling path while running Python in isolated
mode.  This module intentionally contains no network client and no provider
credentials.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import stat
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


MAX_JSON_BYTES = 1024 * 1024
SAFE_ENVIRONMENT = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
}
ISSUE_CODE = re.compile(r"^[a-z0-9](?:[a-z0-9_.-]{0,126}[a-z0-9])?$")
UTC_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class MonitoringError(RuntimeError):
    """A monitoring contract or observation failed safely."""


def test_mode() -> bool:
    return os.environ.get("UTEN_MONITOR_TEST_MODE") == "1"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_text(value: datetime | None = None) -> str:
    current = value or utc_now()
    return current.astimezone(timezone.utc).replace(microsecond=0).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MonitoringError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise MonitoringError(f"non-finite JSON number: {value}")


def strict_json(raw: bytes, *, canonical: bool = False) -> Any:
    if len(raw) > MAX_JSON_BYTES:
        raise MonitoringError("JSON exceeds the one-MiB limit")
    if b"\x00" in raw:
        raise MonitoringError("JSON contains NUL")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MonitoringError("input is not strict UTF-8 JSON") from exc
    if canonical and canonical_json(value) != raw:
        raise MonitoringError("JSON is not canonical")
    return value


def _no_follow_flag() -> int:
    return getattr(os, "O_NOFOLLOW", 0)


def read_regular(
    path: Path,
    *,
    maximum: int = MAX_JSON_BYTES,
    expected_mode: int | None = None,
    require_root: bool = False,
) -> bytes:
    try:
        before = path.lstat()
    except OSError as exc:
        raise MonitoringError(f"required regular file is unavailable: {path}") from exc
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or path.is_symlink():
        raise MonitoringError(f"path is not one regular non-symlink file: {path}")
    if before.st_size > maximum:
        raise MonitoringError(f"file exceeds its size limit: {path}")
    if expected_mode is not None and stat.S_IMODE(before.st_mode) != expected_mode:
        raise MonitoringError(f"file mode differs from policy: {path}")
    if require_root and not test_mode() and (before.st_uid != 0 or before.st_gid != 0):
        raise MonitoringError(f"file is not root-owned: {path}")
    descriptor = os.open(path, os.O_RDONLY | _no_follow_flag())
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise MonitoringError(f"file changed while being opened: {path}")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(remaining, 64 * 1024))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(raw) > maximum:
        raise MonitoringError(f"file exceeds its size limit: {path}")
    return raw


def read_json_file(
    path: Path,
    *,
    canonical: bool,
    expected_mode: int | None,
    require_root: bool,
    maximum: int = MAX_JSON_BYTES,
) -> tuple[bytes, Any]:
    raw = read_regular(
        path,
        maximum=maximum,
        expected_mode=expected_mode,
        require_root=require_root,
    )
    return raw, strict_json(raw, canonical=canonical)


def assert_private_directory(path: Path, *, create: bool) -> None:
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        info = path.lstat()
    except OSError as exc:
        raise MonitoringError(f"state directory is unavailable: {path}") from exc
    if path.is_symlink() or not stat.S_ISDIR(info.st_mode):
        raise MonitoringError(f"state path is not a directory: {path}")
    if not test_mode() and (
        info.st_uid != 0
        or info.st_gid != 0
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise MonitoringError(f"state directory must be root:root 0700: {path}")


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_all(descriptor: int, raw: bytes) -> None:
    view = memoryview(raw)
    while view:
        written = os.write(descriptor, view)
        if written < 1:
            raise OSError("short write")
        view = view[written:]


def atomic_new(path: Path, raw: bytes, *, mode: int = 0o600) -> None:
    if path.exists() or path.is_symlink():
        raise MonitoringError(f"refusing to overwrite existing evidence: {path}")
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _no_follow_flag(),
        mode,
    )
    try:
        _write_all(descriptor, raw)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    fsync_directory(path.parent)


def atomic_replace(path: Path, raw: bytes, *, mode: int = 0o600) -> None:
    if path.is_symlink():
        raise MonitoringError(f"refusing to replace symlink state: {path}")
    if path.exists():
        existing = path.lstat()
        if not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1:
            raise MonitoringError(f"refusing to replace unsafe state: {path}")
        if not test_mode() and (
            existing.st_uid != 0
            or existing.st_gid != 0
            or stat.S_IMODE(existing.st_mode) != mode
        ):
            raise MonitoringError(f"existing state ownership/mode is unsafe: {path}")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=str(path.parent)
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        _write_all(descriptor, raw)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()


def safe_unlink(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or path.is_symlink():
        raise MonitoringError(f"refusing to unlink unsafe state: {path}")
    path.unlink()
    fsync_directory(path.parent)


def run_command(
    arguments: Sequence[str],
    *,
    timeout: int = 15,
    accepted: Iterable[int] = (0,),
) -> subprocess.CompletedProcess[str]:
    if not arguments or not os.path.isabs(arguments[0]):
        raise MonitoringError("monitor commands require a fixed absolute executable")
    try:
        result = subprocess.run(
            list(arguments),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=SAFE_ENVIRONMENT,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise MonitoringError(f"read-only command failed: {arguments[0]}") from exc
    if result.returncode not in set(accepted):
        raise MonitoringError(
            f"read-only command returned {result.returncode}: {arguments[0]}"
        )
    return result


def clean_text(value: str, *, maximum: int = 512) -> str:
    cleaned = " ".join(value.split())
    if not cleaned:
        raise MonitoringError("empty monitoring text")
    if len(cleaned) > maximum:
        cleaned = cleaned[: maximum - 3] + "..."
    if re.search(
        r"(?i)(password|passwd|secret|token|credential|access[_-]?key|private[_-]?key)",
        cleaned,
    ):
        return "sensitive diagnostic suppressed; inspect root-only local evidence"
    return cleaned


def issue(
    code: str,
    severity: str,
    summary: str,
    required_action: str,
) -> dict[str, str]:
    if not ISSUE_CODE.fullmatch(code):
        raise MonitoringError(f"invalid issue code: {code}")
    if severity not in {"warning", "critical"}:
        raise MonitoringError(f"invalid issue severity: {severity}")
    return {
        "code": code,
        "severity": severity,
        "summary": clean_text(summary),
        "requiredAction": clean_text(required_action),
    }


def validate_no_nonfinite(value: Any) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise MonitoringError("non-finite value is forbidden")
    if isinstance(value, Mapping):
        for item in value.values():
            validate_no_nonfinite(item)
    elif isinstance(value, list):
        for item in value:
            validate_no_nonfinite(item)


def write_report(path: Path, report: dict[str, Any]) -> bytes:
    validate_no_nonfinite(report)
    raw = canonical_json(report)
    if len(raw) > MAX_JSON_BYTES:
        raise MonitoringError("monitoring report exceeds one MiB")
    atomic_replace(path, raw, mode=0o600)
    return raw


def parse_utc(value: str) -> datetime:
    if not UTC_TIMESTAMP.fullmatch(value):
        raise MonitoringError("timestamp is not canonical UTC seconds")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    )
