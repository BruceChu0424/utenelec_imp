#!/usr/bin/env python3
"""Authenticate and execute the frozen release-retention installer bytes.

An independent bootstrap installs this launcher as root:root 0500 and the
exact allowlisted source bundle as root:root 0400/0500.  The launcher opens the
installer through ``O_NOFOLLOW``, verifies its reviewed SHA-256, and executes
only the captured in-memory bytes.  It never imports or executes the installer
pathname directly.
"""

from __future__ import annotations

import hashlib
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, NamedTuple, Sequence


INSTALLED_LAUNCHER = Path("/usr/local/sbin/uten-imp-release-retention-installer")
SOURCE_BUNDLE_ROOT = Path(
    "/usr/local/share/uten-imp-release-retention-installer-source"
)
INSTALLED_INSTALLER = (
    SOURCE_BUNDLE_ROOT / "deploy/setup/install-release-retention.py"
)
SOURCE_BUNDLE_RELATIVE_FILES = (
    "deploy/setup/install-release-retention.py",
    "deploy/updater/release_updater.py",
    "deploy/updater/release_guard.py",
    "deploy/updater/retention_manager.py",
    "deploy/updater/retention_launcher.py",
    "deploy/updater/uten-imp-retention.sh",
    "deploy/updater/retention-policy.json.example",
    "deploy/systemd/uten-imp-retention.service.example",
    "deploy/systemd/uten-imp-retention.timer.example",
    "deploy/systemd/uten-imp-retention-alert@.service.example",
)

# Updated from the final installer bytes in this same change.
REVIEWED_INSTALLER_SHA256: str | None = (
    "70fd80b59a5d5f59062ecd4a32d0550d65d9b92cee098664245029a15616cce7"
)

INSTALLER_MODE = 0o400
SOURCE_DIRECTORY_MODE = 0o500
LAUNCHER_MODE = 0o500
MAX_INSTALLER_BYTES = 16 * 1024 * 1024
SHA256_RE = re.compile(r"[0-9a-f]{64}")
NO_GO_PREFIX = "UTEN_RELEASE_RETENTION_INSTALL_LAUNCH_NO_GO"


class LauncherError(RuntimeError):
    pass


class VerifiedInstaller(NamedTuple):
    payload: bytes
    sha256: str
    fingerprint: tuple[int, ...]


def fail(message: str) -> None:
    raise LauncherError(message)


def _fingerprint(details: os.stat_result) -> tuple[int, ...]:
    return (
        details.st_dev,
        details.st_ino,
        details.st_mode,
        details.st_uid,
        details.st_gid,
        details.st_nlink,
        details.st_size,
        details.st_mtime_ns,
        details.st_ctime_ns,
    )


def _root_parent_chain(path: Path) -> tuple[tuple[str, tuple[int, ...]], ...]:
    captured: list[tuple[str, tuple[int, ...]]] = []
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise LauncherError("cannot inspect launcher parent chain") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail("launcher parent chain is not root controlled")
        captured.append((str(current), _fingerprint(details)))
        if current == current.parent:
            return tuple(captured)
        current = current.parent


def _safe_file(details: os.stat_result, mode: int) -> bool:
    return (
        stat.S_ISREG(details.st_mode)
        and not stat.S_ISLNK(details.st_mode)
        and details.st_uid == 0
        and details.st_gid == 0
        and details.st_nlink == 1
        and stat.S_IMODE(details.st_mode) == mode
    )


def _expected_children() -> dict[Path, set[str]]:
    result: dict[Path, set[str]] = {Path("."): set()}
    files: set[Path] = set()
    for raw in SOURCE_BUNDLE_RELATIVE_FILES:
        path = Path(raw)
        if (
            not raw
            or path.is_absolute()
            or any(part in ("", ".", "..") for part in path.parts)
            or path in files
        ):
            fail("compiled source-bundle allowlist is malformed")
        files.add(path)
        parent = Path(".")
        for part in path.parts:
            result.setdefault(parent, set()).add(part)
            parent /= part
    return {
        path: children
        for path, children in result.items()
        if path == Path(".") or path not in files
    }


def validate_source_bundle() -> tuple[tuple[str, tuple[int, ...]], ...]:
    expected_files = {Path(value) for value in SOURCE_BUNDLE_RELATIVE_FILES}
    expected_children = _expected_children()
    captured: list[tuple[str, tuple[int, ...]]] = []
    parent_before = _root_parent_chain(SOURCE_BUNDLE_ROOT / ".anchor")
    for relative, children in sorted(expected_children.items(), key=lambda item: str(item[0])):
        directory = SOURCE_BUNDLE_ROOT if relative == Path(".") else SOURCE_BUNDLE_ROOT / relative
        details = directory.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != SOURCE_DIRECTORY_MODE
        ):
            fail("source-bundle directory metadata is unsafe")
        with os.scandir(directory) as entries:
            actual = {entry.name for entry in entries}
        if actual != children:
            fail("source bundle has a missing or unexpected object")
        captured.append((str(directory), _fingerprint(details)))
    for relative in sorted(expected_files, key=str):
        path = SOURCE_BUNDLE_ROOT / relative
        details = path.lstat()
        if not _safe_file(details, INSTALLER_MODE) or not 1 <= details.st_size <= MAX_INSTALLER_BYTES:
            fail("source-bundle file metadata is unsafe")
        captured.append((str(path), _fingerprint(details)))
    if _root_parent_chain(SOURCE_BUNDLE_ROOT / ".anchor") != parent_before:
        fail("source-bundle parent chain changed during inventory")
    return tuple(captured)


def read_verified_installer(
    *,
    expected_sha256: str | None = REVIEWED_INSTALLER_SHA256,
    require_root_control: bool = True,
    path: Path = INSTALLED_INSTALLER,
) -> VerifiedInstaller:
    if not isinstance(expected_sha256, str) or SHA256_RE.fullmatch(expected_sha256) is None:
        fail("reviewed installer SHA-256 pin is unresolved")
    parent_before = _root_parent_chain(path) if require_root_control else ()
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise LauncherError("cannot safely open frozen installer") from exc
    try:
        opened = os.fstat(descriptor)
        live = path.lstat()
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or _fingerprint(opened) != _fingerprint(live)
            or not 1 <= opened.st_size <= MAX_INSTALLER_BYTES
            or (require_root_control and not _safe_file(opened, INSTALLER_MODE))
        ):
            fail("frozen installer is not one stable approved regular file")
        payload = bytearray()
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
            digest.update(block)
            if len(payload) > MAX_INSTALLER_BYTES:
                fail("frozen installer exceeded its size limit")
        after = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            len(payload) != opened.st_size
            or _fingerprint(opened) != _fingerprint(after)
            or _fingerprint(opened) != _fingerprint(live_after)
            or (require_root_control and _root_parent_chain(path) != parent_before)
        ):
            fail("frozen installer or pathname changed while captured")
        actual = digest.hexdigest()
        if actual != expected_sha256:
            fail("frozen installer differs from its independently reviewed SHA-256")
        return VerifiedInstaller(bytes(payload), actual, _fingerprint(opened))
    finally:
        os.close(descriptor)


def parse_arguments(arguments: Sequence[str]) -> list[str]:
    values = list(arguments)
    if not values or values[0] != "--" or len(values) < 2:
        fail("mandatory -- boundary and installer command are required")
    result = values[1:]
    if any(
        not isinstance(value, str)
        or not value
        or any(character in value for character in ("\x00", "\r", "\n"))
        for value in result
    ):
        fail("installer arguments contain an empty or control-character value")
    return result


def execute_verified(verified: VerifiedInstaller, arguments: Sequence[str]) -> None:
    try:
        code = compile(verified.payload, str(INSTALLED_INSTALLER), "exec", dont_inherit=True)
    except (SyntaxError, ValueError) as exc:
        raise LauncherError("verified installer cannot be compiled") from exc
    previous_argv = sys.argv
    previous_environment = dict(os.environ)
    previous_directory = os.getcwd()
    previous_bytecode = sys.dont_write_bytecode
    previous_umask = os.umask(0o077)
    namespace: dict[str, Any] = {
        "__name__": "__main__",
        "__file__": str(INSTALLED_INSTALLER),
        "__package__": None,
        "__cached__": None,
        "__spec__": None,
    }
    try:
        sys.argv = [str(INSTALLED_INSTALLER), *arguments]
        sys.dont_write_bytecode = True
        os.environ.clear()
        os.environ.update(
            {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"}
        )
        os.chdir("/")
        exec(code, namespace, namespace)
    finally:
        os.chdir(previous_directory)
        os.environ.clear()
        os.environ.update(previous_environment)
        sys.argv = previous_argv
        sys.dont_write_bytecode = previous_bytecode
        os.umask(previous_umask)


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        if os.name != "posix" or os.geteuid() != 0:
            fail("launcher must run as root on Linux")
        if not sys.flags.isolated or not getattr(sys.flags, "safe_path", False):
            fail("launcher requires system Python isolated mode (-I)")
        if not sys.dont_write_bytecode:
            fail("launcher requires bytecode writes disabled (-B)")
        invoked = Path(os.path.abspath(__file__))
        if invoked != INSTALLED_LAUNCHER:
            fail("launcher is outside its fixed installation path")
        details = invoked.lstat()
        if not _safe_file(details, LAUNCHER_MODE):
            fail("installed launcher is not root:root 0500")
        installer_arguments = parse_arguments(sys.argv[1:] if arguments is None else arguments)
        inventory = validate_source_bundle()
        verified = read_verified_installer()
        if validate_source_bundle() != inventory:
            fail("source bundle changed before installer execution")
        execute_verified(verified, installer_arguments)
        return 0
    except (LauncherError, OSError, ValueError) as exc:
        print(f"{NO_GO_PREFIX}: {exc}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
