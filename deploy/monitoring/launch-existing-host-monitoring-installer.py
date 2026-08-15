#!/usr/bin/env python3
"""Authenticate and execute the frozen existing-host monitoring installer.

Install this launcher separately as root:root 0500 at ``INSTALLED_LAUNCHER``.
Install the exact source-bundle allowlist below as root:root 0400 files inside
root:root 0500 directories.  The launcher never imports or path-executes the
installer: it compiles only bytes captured through a stable O_NOFOLLOW
descriptor after SHA-256, pathname, inventory and parent-chain verification.
"""

from __future__ import annotations

import hashlib
import os
import re
import stat
import sys
from pathlib import Path
from typing import NamedTuple, Sequence


INSTALLED_LAUNCHER = Path("/usr/local/sbin/uten-imp-existing-monitoring-installer")
SOURCE_BUNDLE_ROOT = Path("/usr/local/share/uten-imp-monitoring-installer-source")
INSTALLED_INSTALLER = SOURCE_BUNDLE_ROOT / "deploy/monitoring/existing_host_monitoring_installer.py"
SOURCE_BUNDLE_RELATIVE_FILES = (
    "deploy/monitoring/existing_host_monitoring_installer.py",
    "deploy/monitoring/monitor_runtime_launcher.py",
    "deploy/monitoring/monitoring_common.py",
    "deploy/monitoring/alert_spool.py",
    "deploy/monitoring/host_monitor.py",
    "deploy/monitoring/external_probe.py",
    "deploy/monitoring/README.zh-CN.md",
    "deploy/monitoring/EXISTING_HOST_MONITORING_INSTALLER.zh-CN.md",
    "deploy/systemd/uten-imp-host-monitor.service.example",
    "deploy/systemd/uten-imp-host-monitor.timer.example",
    "deploy/systemd/uten-imp-external-monitor.service.example",
    "deploy/systemd/uten-imp-external-monitor.timer.example",
    "deploy/systemd/uten-imp-monitor-alert-drain.service.example",
    "deploy/systemd/uten-imp-monitor-alert-drain.timer.example",
    "deploy/systemd/uten-imp-monitor-failure@.service.example",
)
REVIEWED_SOURCE_SHA256 = {
    "deploy/monitoring/existing_host_monitoring_installer.py": "903e5bf56305d127bb0f00940ba65075d7c8616130b71283ec3aaf6215b09c6a",
    "deploy/monitoring/monitor_runtime_launcher.py": "c9d43a645ba6ebef0a368f1bcaab057db9d991c2e9985ccc12df6f58d068a2fb",
    "deploy/monitoring/monitoring_common.py": "82b88da8b6707a352a9531db6feff12930bc058af39cbd7ff2442e7b7e4772c9",
    "deploy/monitoring/alert_spool.py": "12ce37f6dc9e86472c379957ffae8b0603bdc730ae2c66a83cf6b7f44a59c810",
    "deploy/monitoring/host_monitor.py": "197c35eae0997c3302bf5fe1acd9c7c5255b16c48a203c94b9afffa0dd40fe59",
    "deploy/monitoring/external_probe.py": "33782a7975e933ac4686bcca06272451f69325bc217da57eeb52a5539aacbdd4",
    "deploy/monitoring/README.zh-CN.md": "bcf2c24e12443b9ddf6c0d748c1b76ea3dfbd7c71aaae513e71087adfa3ef96f",
    "deploy/monitoring/EXISTING_HOST_MONITORING_INSTALLER.zh-CN.md": "e0702563b6abec87c5af876e80558d65f80dcdf8d0a752d9f1013a185d051856",
    "deploy/systemd/uten-imp-host-monitor.service.example": "590dd468dd32c4cf397ccd6d5cef1880d7375be402c59ab472bb8b65e906fde0",
    "deploy/systemd/uten-imp-host-monitor.timer.example": "e0a0426ead69dfe6e4b8e0b651a7e36164c0bf8b6bfd0251a1bdb710f4d6dd8e",
    "deploy/systemd/uten-imp-external-monitor.service.example": "c9a25bb8d75eee759b707f8179988b0689ed41b44dbabf068daf0ca75602e752",
    "deploy/systemd/uten-imp-external-monitor.timer.example": "b992edd591f6b9c2afd9fe3b2f189d61086227be1725fe20f51a1c77d393b2cd",
    "deploy/systemd/uten-imp-monitor-alert-drain.service.example": "11f1a36d054f9f756f905cf1e7274256abaf9e69bae7e2fc5c559c0e293d598e",
    "deploy/systemd/uten-imp-monitor-alert-drain.timer.example": "1a36a33bea2484fa5633d3af9109f225127c00366e52991ae13a2cb1efd005d1",
    "deploy/systemd/uten-imp-monitor-failure@.service.example": "d8b6262db9142418e0b4c3675a8dfb4a6e2cdc5f1aa60ccb4028999fcb084036",
}
REVIEWED_INSTALLER_SHA256 = REVIEWED_SOURCE_SHA256[
    "deploy/monitoring/existing_host_monitoring_installer.py"
]
INSTALLER_MODE = 0o400
BUNDLE_DIRECTORY_MODE = 0o500
LAUNCHER_MODE = 0o500
MAX_FILE_BYTES = 16 * 1024 * 1024
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SAFE_ENVIRONMENT = {
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}
NO_GO = "UTEN_MONITOR_INSTALLER_LAUNCH_NO_GO"


class LauncherError(RuntimeError):
    """The monitoring installer launcher trust boundary failed."""


class VerifiedInstaller(NamedTuple):
    payload: bytes
    sha256: str
    device: int
    inode: int
    size: int


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
    result: list[tuple[str, tuple[int, ...]]] = []
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise LauncherError("cannot inspect parent chain") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            raise LauncherError("parent chain is not root controlled")
        result.append((str(current), _fingerprint(details)))
        if current == current.parent:
            return tuple(result)
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


def validate_environment() -> None:
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise LauncherError("launcher requires root on POSIX")
    if not sys.flags.isolated or not getattr(sys.flags, "safe_path", False):
        raise LauncherError("launcher requires system Python isolated mode (-I)")
    if not sys.dont_write_bytecode:
        raise LauncherError("launcher requires bytecode writes disabled (-B)")
    if not hasattr(os, "O_NOFOLLOW"):
        raise LauncherError("launcher requires O_NOFOLLOW")


def validate_installed_launcher() -> None:
    invoked = Path(os.path.abspath(__file__))
    if invoked != INSTALLED_LAUNCHER:
        raise LauncherError("launcher is not running from its fixed installed path")
    before = _root_parent_chain(invoked)
    details = invoked.lstat()
    if not _safe_file(details, LAUNCHER_MODE):
        raise LauncherError("installed launcher must be root:root 0500 single-link")
    if _root_parent_chain(invoked) != before:
        raise LauncherError("launcher parent chain changed during validation")


def _expected_children() -> dict[Path, set[str]]:
    files = {Path(value) for value in SOURCE_BUNDLE_RELATIVE_FILES}
    if len(files) != len(SOURCE_BUNDLE_RELATIVE_FILES):
        raise LauncherError("compiled source-bundle allowlist is duplicated")
    children: dict[Path, set[str]] = {Path("."): set()}
    for relative in files:
        if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
            raise LauncherError("compiled source-bundle path is unsafe")
        parent = Path(".")
        for part in relative.parts:
            children.setdefault(parent, set()).add(part)
            parent = parent / part
    return {
        path: value
        for path, value in children.items()
        if path == Path(".") or path not in files
    }


def validate_bundle_inventory() -> tuple[tuple[str, tuple[int, ...]], ...]:
    expected_files = {Path(value) for value in SOURCE_BUNDLE_RELATIVE_FILES}
    if set(REVIEWED_SOURCE_SHA256) != set(SOURCE_BUNDLE_RELATIVE_FILES):
        raise LauncherError("reviewed source digest inventory differs from the allowlist")
    if any(not SHA256_RE.fullmatch(value) for value in REVIEWED_SOURCE_SHA256.values()):
        raise LauncherError("reviewed source digest inventory is malformed")
    if INSTALLED_INSTALLER.relative_to(SOURCE_BUNDLE_ROOT) not in expected_files:
        raise LauncherError("fixed installer is absent from the source-bundle allowlist")
    parent_before = _root_parent_chain(SOURCE_BUNDLE_ROOT / ".inventory-anchor")
    captured: list[tuple[str, tuple[int, ...]]] = []
    for relative, expected in sorted(_expected_children().items(), key=lambda item: str(item[0])):
        directory = SOURCE_BUNDLE_ROOT if relative == Path(".") else SOURCE_BUNDLE_ROOT / relative
        details = directory.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != BUNDLE_DIRECTORY_MODE
        ):
            raise LauncherError("source-bundle directory metadata differs")
        actual = {entry.name for entry in os.scandir(directory)}
        if actual != expected:
            raise LauncherError("source bundle has a missing or unexpected object")
        captured.append((str(directory), _fingerprint(details)))
    for relative in sorted(expected_files, key=str):
        path = SOURCE_BUNDLE_ROOT / relative
        details = path.lstat()
        if not _safe_file(details, INSTALLER_MODE) or not 1 <= details.st_size <= MAX_FILE_BYTES:
            raise LauncherError("source-bundle file metadata differs")
        captured.append((str(path), _fingerprint(details)))
    if _root_parent_chain(SOURCE_BUNDLE_ROOT / ".inventory-anchor") != parent_before:
        raise LauncherError("source-bundle parent chain changed during inventory validation")
    return tuple(captured)


def _read_verified_source(path: Path, expected_sha256: str, *, keep_payload: bool) -> VerifiedInstaller:
    try:
        relative = path.relative_to(SOURCE_BUNDLE_ROOT).as_posix()
    except ValueError as exc:
        raise LauncherError("reviewed source path escapes the source bundle") from exc
    if REVIEWED_SOURCE_SHA256.get(relative) != expected_sha256 or not SHA256_RE.fullmatch(expected_sha256):
        raise LauncherError("embedded reviewed source digest is malformed")
    parent_before = _root_parent_chain(path)
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        opened = os.fstat(descriptor)
        live = path.lstat()
        if (
            not _safe_file(opened, INSTALLER_MODE)
            or not _safe_file(live, INSTALLER_MODE)
            or _fingerprint(opened) != _fingerprint(live)
            or not 1 <= opened.st_size <= MAX_FILE_BYTES
        ):
            raise LauncherError(f"frozen source metadata differs: {relative}")
        payload = bytearray()
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
            digest.update(block)
            if len(payload) > MAX_FILE_BYTES:
                raise LauncherError(f"frozen source exceeds its size bound: {relative}")
        final = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            _fingerprint(final) != _fingerprint(opened)
            or _fingerprint(live_after) != _fingerprint(opened)
            or _root_parent_chain(path) != parent_before
            or len(payload) != opened.st_size
        ):
            raise LauncherError(f"frozen source changed during capture: {relative}")
        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise LauncherError(f"source bytes differ from the embedded reviewed SHA-256: {relative}")
        return VerifiedInstaller(
            bytes(payload) if keep_payload else b"",
            actual,
            opened.st_dev,
            opened.st_ino,
            opened.st_size,
        )
    finally:
        os.close(descriptor)


def read_verified_installer() -> VerifiedInstaller:
    return _read_verified_source(
        INSTALLED_INSTALLER,
        REVIEWED_INSTALLER_SHA256,
        keep_payload=True,
    )


def read_verified_bundle() -> VerifiedInstaller:
    verified_installer: VerifiedInstaller | None = None
    installer_relative = INSTALLED_INSTALLER.relative_to(SOURCE_BUNDLE_ROOT).as_posix()
    for relative in SOURCE_BUNDLE_RELATIVE_FILES:
        captured = _read_verified_source(
            SOURCE_BUNDLE_ROOT / relative,
            REVIEWED_SOURCE_SHA256[relative],
            keep_payload=relative == installer_relative,
        )
        if relative == installer_relative:
            verified_installer = captured
    if verified_installer is None:
        raise LauncherError("reviewed source bundle did not yield the installer")
    return verified_installer


def parse_arguments(arguments: Sequence[str]) -> list[str]:
    values = list(arguments)
    if not values or values[0] != "--" or len(values) < 2:
        raise LauncherError("mandatory -- boundary before installer arguments is missing")
    result = values[1:]
    if any(not value or any(character in value for character in ("\x00", "\r", "\n")) for value in result):
        raise LauncherError("installer arguments contain an empty/control value")
    return result


def execute(verified: VerifiedInstaller, arguments: Sequence[str]) -> None:
    try:
        code = compile(verified.payload, str(INSTALLED_INSTALLER), "exec", dont_inherit=True)
    except (SyntaxError, ValueError) as exc:
        raise LauncherError("verified installer cannot compile") from exc
    prior_argv = sys.argv
    prior_environment = dict(os.environ)
    prior_directory = os.getcwd()
    prior_umask = os.umask(0o077)
    sys.argv = [str(INSTALLED_INSTALLER), *arguments]
    os.environ.clear()
    os.environ.update(SAFE_ENVIRONMENT)
    os.chdir("/")
    namespace = {
        "__name__": "__main__",
        "__file__": str(INSTALLED_INSTALLER),
        "__package__": None,
        "__cached__": None,
        "__spec__": None,
    }
    try:
        exec(code, namespace, namespace)
    finally:
        os.chdir(prior_directory)
        os.environ.clear()
        os.environ.update(prior_environment)
        sys.argv = prior_argv
        os.umask(prior_umask)


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        validate_environment()
        validate_installed_launcher()
        installer_arguments = parse_arguments(sys.argv[1:] if arguments is None else arguments)
        inventory = validate_bundle_inventory()
        verified = read_verified_bundle()
        if validate_bundle_inventory() != inventory:
            raise LauncherError("source-bundle inventory changed before execution")
        print(
            "UTEN_MONITOR_INSTALLER_VERIFIED "
            f"sha256={verified.sha256} dev={verified.device} inode={verified.inode} size={verified.size}",
            file=sys.stderr,
        )
        execute(verified, installer_arguments)
        return 0
    except (LauncherError, OSError, ValueError) as exc:
        print(f"{NO_GO}: {exc}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
