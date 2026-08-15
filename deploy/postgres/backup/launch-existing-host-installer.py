#!/usr/bin/env python3
"""Authenticate and execute the frozen existing-host backup installer bytes.

This file is the source for an independently reviewed root-only launcher.
Install these exact launcher bytes as root:root 0500 at ``INSTALLED_LAUNCHER``.
The separately reviewed source bundle must preserve the repository's ``deploy``
layout and install the frozen installer as root:root 0400 at
``INSTALLED_INSTALLER``.  The launcher never imports that file or asks Python to
execute its pathname.  It opens the fixed pathname with O_NOFOLLOW, binds the
descriptor to stable pathname and parent metadata, verifies the embedded
SHA-256, and compiles/executes only the bytes captured from that descriptor.
"""

from __future__ import annotations

import hashlib
import os
import re
import stat
import sys
from pathlib import Path
from typing import NamedTuple, Sequence


INSTALLED_LAUNCHER = Path("/usr/local/sbin/uten-imp-existing-backup-installer")
INSTALLED_INSTALLER = Path(
    "/usr/local/share/uten-imp-backup-installer-source/"
    "deploy/postgres/backup/existing_host_installer.py"
)
SOURCE_BUNDLE_ROOT = Path("/usr/local/share/uten-imp-backup-installer-source")
SOURCE_BUNDLE_RELATIVE_FILES = (
    "deploy/postgres/backup/existing_host_installer.py",
    "deploy/postgres/backup/locked_job.py",
    "deploy/postgres/backup/pgbackrest_repo2.py",
    "deploy/postgres/backup/pgbackrest_health.py",
    "deploy/postgres/backup/backup_alert.py",
    "deploy/postgres/backup/backup_acceptance.py",
    "deploy/postgres/backup/backup_commissioner.py",
    "deploy/postgres/backup/internal_test_first_backup.py",
    "deploy/postgres/backup/internal_test_first_backup_commissioner.py",
    "deploy/systemd/uten-pgbackup.service.example",
    "deploy/systemd/uten-pgbackup.timer.example",
    "deploy/systemd/uten-pgbackup-repo2.service.example",
    "deploy/systemd/uten-pgbackup-repo2.timer.example",
    "deploy/systemd/uten-pgbackup-health.service.example",
    "deploy/systemd/uten-pgbackup-health.timer.example",
    "deploy/systemd/uten-pgbackup-alert@.service.example",
    "deploy/systemd/uten-pgbackup-alert-drain.service.example",
    "deploy/systemd/uten-pgbackup-alert-drain.timer.example",
)
REVIEWED_INSTALLER_SHA256 = (
    "512b7c7132c2016d1557723b90bef520349b5cbd7875af296d6d0554b9ade727"
)
INSTALLER_MODE = 0o400
SOURCE_DIRECTORY_MODE = 0o500
LAUNCHER_MODE = 0o500
MAX_INSTALLER_BYTES = 16 * 1024 * 1024
SHA256_RE = re.compile(r"[0-9a-f]{64}")
NO_GO_PREFIX = "UTEN_EXISTING_BACKUP_INSTALLER_LAUNCH_NO_GO"
SANITIZED_ENVIRONMENT = {
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}


class LauncherError(RuntimeError):
    """The installed launcher or frozen installer trust contract failed."""


class VerifiedInstaller(NamedTuple):
    payload: bytes
    sha256: str
    device: int
    inode: int
    size: int


def fail(message: str) -> None:
    raise LauncherError(message)


def _stat_fingerprint(details: os.stat_result) -> tuple[int, ...]:
    """Return all stable metadata used to bind a descriptor to its pathname."""

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


def _canonical_absolute_path(raw: str, label: str) -> Path:
    if (
        not raw
        or "\x00" in raw
        or not os.path.isabs(raw)
        or os.path.normpath(raw) != raw
    ):
        fail(f"{label} path is not canonical and absolute")
    return Path(raw)


def _root_parent_chain(
    path: Path, label: str
) -> tuple[tuple[str, tuple[int, ...]], ...]:
    """Capture a root-owned, non-writable, non-symlink directory chain."""

    captured: list[tuple[str, tuple[int, ...]]] = []
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise LauncherError(f"cannot inspect {label} parent chain") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail(f"{label} parent chain is not root controlled")
        captured.append((str(current), _stat_fingerprint(details)))
        if current == current.parent:
            return tuple(captured)
        current = current.parent


def _safe_regular_file(details: os.stat_result, *, exact_mode: int) -> bool:
    return (
        stat.S_ISREG(details.st_mode)
        and not stat.S_ISLNK(details.st_mode)
        and details.st_uid == 0
        and details.st_gid == 0
        and details.st_nlink == 1
        and stat.S_IMODE(details.st_mode) == exact_mode
    )


def _safe_bundle_directory(details: os.stat_result) -> bool:
    return (
        stat.S_ISDIR(details.st_mode)
        and not stat.S_ISLNK(details.st_mode)
        and details.st_uid == 0
        and details.st_gid == 0
        and stat.S_IMODE(details.st_mode) == SOURCE_DIRECTORY_MODE
    )


def _expected_bundle_children() -> dict[Path, set[str]]:
    """Build the exact directory allowlist compiled into this launcher."""

    result: dict[Path, set[str]] = {Path("."): set()}
    seen: set[Path] = set()
    for raw in SOURCE_BUNDLE_RELATIVE_FILES:
        relative = Path(raw)
        if (
            not raw
            or "\x00" in raw
            or relative.is_absolute()
            or relative.parts in ((), (".",))
            or any(part in ("", ".", "..") for part in relative.parts)
            or relative in seen
        ):
            fail("compiled source-bundle allowlist is malformed")
        seen.add(relative)
        parent = Path(".")
        for part in relative.parts:
            result.setdefault(parent, set()).add(part)
            parent = parent / part
        result.setdefault(relative.parent, set()).add(relative.name)
    return {
        path: children
        for path, children in result.items()
        if path == Path(".") or path not in seen
    }


def validate_source_bundle_inventory() -> tuple[tuple[str, tuple[int, ...]], ...]:
    """Reject missing/extra objects and unsafe metadata in the fixed source bundle."""

    root = _canonical_absolute_path(str(SOURCE_BUNDLE_ROOT), "source bundle")
    if root != SOURCE_BUNDLE_ROOT:
        fail("source-bundle root differs from the compiled fixed path")
    expected_files = {Path(value) for value in SOURCE_BUNDLE_RELATIVE_FILES}
    installer_relative = INSTALLED_INSTALLER.relative_to(SOURCE_BUNDLE_ROOT)
    if installer_relative not in expected_files:
        fail("fixed installer is absent from the compiled source-bundle allowlist")

    parent_before = _root_parent_chain(root / ".inventory-anchor", "source bundle")
    expected_children = _expected_bundle_children()
    captured: list[tuple[str, tuple[int, ...]]] = []
    for relative_directory in sorted(expected_children, key=str):
        directory = root if relative_directory == Path(".") else root / relative_directory
        try:
            directory_details = directory.lstat()
        except OSError as exc:
            raise LauncherError("cannot inspect fixed source-bundle directory") from exc
        if not _safe_bundle_directory(directory_details):
            fail("source-bundle directories must be root:root 0500 and non-symlinked")
        try:
            with os.scandir(directory) as entries:
                actual_children = {entry.name for entry in entries}
        except OSError as exc:
            raise LauncherError("cannot enumerate fixed source-bundle directory") from exc
        if actual_children != expected_children[relative_directory]:
            fail("source bundle has a missing or unexpected object")
        captured.append((str(directory), _stat_fingerprint(directory_details)))

    for relative_file in sorted(expected_files, key=str):
        path = root / relative_file
        try:
            details = path.lstat()
        except OSError as exc:
            raise LauncherError("cannot inspect fixed source-bundle file") from exc
        if (
            not _safe_regular_file(details, exact_mode=INSTALLER_MODE)
            or not 1 <= details.st_size <= MAX_INSTALLER_BYTES
        ):
            fail("source-bundle files must be root:root 0400 single-link regular files")
        captured.append((str(path), _stat_fingerprint(details)))

    if _root_parent_chain(root / ".inventory-anchor", "source bundle") != parent_before:
        fail("source-bundle parent chain changed during inventory validation")
    return tuple(captured)


def validate_runtime_trust() -> None:
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        fail("launcher must run as root on the target Linux host")
    if not sys.flags.isolated or not getattr(sys.flags, "safe_path", False):
        fail("launcher requires the fixed system Python in isolated mode (-I)")
    if not sys.dont_write_bytecode:
        fail("launcher requires bytecode writes to be disabled (-B)")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("target kernel/Python lacks mandatory O_NOFOLLOW support")


def validate_installed_launcher() -> None:
    """Reject execution from the mutable source checkout."""

    invoked = _canonical_absolute_path(os.path.abspath(__file__), "launcher")
    if invoked != INSTALLED_LAUNCHER:
        fail("launcher is not running from its fixed reviewed installation path")
    parent_before = _root_parent_chain(invoked, "launcher")
    try:
        details = invoked.lstat()
    except OSError as exc:
        raise LauncherError("cannot inspect installed launcher") from exc
    if not _safe_regular_file(details, exact_mode=LAUNCHER_MODE):
        fail("installed launcher is not root:root 0500 with one regular link")
    if _root_parent_chain(invoked, "launcher") != parent_before:
        fail("installed launcher parent chain changed during validation")


def read_verified_installer() -> VerifiedInstaller:
    """Read exact installer bytes from one stable no-follow descriptor."""

    installer = _canonical_absolute_path(str(INSTALLED_INSTALLER), "installer")
    if installer != INSTALLED_INSTALLER:
        fail("installer path differs from the compiled fixed source-bundle path")
    if SHA256_RE.fullmatch(REVIEWED_INSTALLER_SHA256) is None:
        fail("embedded installer SHA-256 is not canonical lowercase hex")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("target kernel/Python lacks mandatory O_NOFOLLOW support")

    parent_before = _root_parent_chain(installer, "installer")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(installer, flags)
    except OSError as exc:
        raise LauncherError("cannot open frozen installer safely") from exc
    try:
        opened = os.fstat(descriptor)
        try:
            live = installer.lstat()
        except OSError as exc:
            raise LauncherError("cannot bind frozen installer pathname") from exc
        if (
            not _safe_regular_file(opened, exact_mode=INSTALLER_MODE)
            or not _safe_regular_file(live, exact_mode=INSTALLER_MODE)
            or _stat_fingerprint(opened) != _stat_fingerprint(live)
            or not 1 <= opened.st_size <= MAX_INSTALLER_BYTES
        ):
            fail("frozen installer is not one immutable root:root 0400 regular file")

        digest = hashlib.sha256()
        payload = bytearray()
        while True:
            try:
                block = os.read(descriptor, 1024 * 1024)
            except OSError as exc:
                raise LauncherError("cannot read frozen installer descriptor") from exc
            if not block:
                break
            payload.extend(block)
            if len(payload) > MAX_INSTALLER_BYTES:
                fail("frozen installer exceeded the fixed size limit while reading")
            digest.update(block)

        after = os.fstat(descriptor)
        try:
            live_after = installer.lstat()
        except OSError as exc:
            raise LauncherError("frozen installer pathname changed while hashing") from exc
        if (
            _stat_fingerprint(after) != _stat_fingerprint(opened)
            or _stat_fingerprint(live_after) != _stat_fingerprint(opened)
            or _root_parent_chain(installer, "installer") != parent_before
            or len(payload) != opened.st_size
        ):
            fail("frozen installer or its parent chain changed while hashing")

        actual_sha256 = digest.hexdigest()
        if actual_sha256 != REVIEWED_INSTALLER_SHA256:
            fail("installer bytes differ from the embedded independently reviewed SHA-256")
        return VerifiedInstaller(
            payload=bytes(payload),
            sha256=actual_sha256,
            device=opened.st_dev,
            inode=opened.st_ino,
            size=opened.st_size,
        )
    finally:
        os.close(descriptor)


def parse_installer_arguments(arguments: Sequence[str]) -> list[str]:
    """Require one unambiguous boundary and reject control characters."""

    values = list(arguments)
    if not values or values[0] != "--":
        fail("mandatory leading -- boundary before installer arguments is missing")
    installer_arguments = values[1:]
    if not installer_arguments:
        fail("at least one installer argument is required after --")
    for argument in installer_arguments:
        if not isinstance(argument, str) or not argument or any(
            character in argument for character in ("\x00", "\r", "\n")
        ):
            fail("installer arguments contain an empty or control-character value")
    return installer_arguments


def execute_verified_installer(
    verified: VerifiedInstaller, installer_arguments: Sequence[str]
) -> None:
    """Compile and execute only authenticated bytes under a fixed process view."""

    try:
        code = compile(
            verified.payload,
            str(INSTALLED_INSTALLER),
            "exec",
            dont_inherit=True,
        )
    except (SyntaxError, ValueError) as exc:
        raise LauncherError("verified installer bytes cannot be compiled") from exc

    previous_argv = sys.argv
    previous_environment = dict(os.environ)
    previous_dont_write_bytecode = sys.dont_write_bytecode
    previous_directory = os.getcwd()
    previous_umask = os.umask(0o077)
    sys.argv = [str(INSTALLED_INSTALLER), *installer_arguments]
    sys.dont_write_bytecode = True
    os.environ.clear()
    os.environ.update(SANITIZED_ENVIRONMENT)
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
        os.chdir(previous_directory)
        os.environ.clear()
        os.environ.update(previous_environment)
        sys.argv = previous_argv
        sys.dont_write_bytecode = previous_dont_write_bytecode
        os.umask(previous_umask)


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        validate_runtime_trust()
        validate_installed_launcher()
        installer_arguments = parse_installer_arguments(
            sys.argv[1:] if arguments is None else arguments
        )
        bundle_before = validate_source_bundle_inventory()
        verified = read_verified_installer()
        if validate_source_bundle_inventory() != bundle_before:
            fail("source-bundle inventory changed before installer execution")
        print(
            "UTEN_EXISTING_BACKUP_INSTALLER_VERIFIED "
            f"sha256={verified.sha256} dev={verified.device} "
            f"inode={verified.inode} size={verified.size}",
            file=sys.stderr,
        )
        execute_verified_installer(verified, installer_arguments)
        return 0
    except LauncherError as exc:
        print(f"{NO_GO_PREFIX}: {exc}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
