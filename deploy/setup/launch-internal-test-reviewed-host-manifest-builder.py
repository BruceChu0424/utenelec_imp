#!/usr/bin/env python3
"""Authenticate and execute the reviewed host-manifest builder bytes.

This file is the source for an independently reviewed launcher.  Install that
exact source as root:root 0500 at ``INSTALLED_LAUNCHER`` before using it.  The
installed launcher is the trust anchor: the mutable commissioning snapshot is
never passed to Python as a script.  Instead, this launcher opens the builder
with O_NOFOLLOW, binds its descriptor and pathname metadata, hashes the bytes,
and executes only the exact bytes read from that verified descriptor.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import stat
import sys
from pathlib import Path
from typing import NamedTuple, Sequence


INSTALLED_LAUNCHER = Path(
    "/usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher"
)
BUILDER_BASENAME = "build-internal-test-reviewed-host-manifest.py"
MAX_BUILDER_BYTES = 16 * 1024 * 1024
SHA256_RE = re.compile(r"[0-9a-f]{64}")
NO_GO_PREFIX = "INTERNAL_TEST_REVIEWED_BUILDER_LAUNCH_NO_GO"


class LauncherError(RuntimeError):
    """A fail-closed launcher trust or invocation error."""


class VerifiedBuilder(NamedTuple):
    payload: bytes
    sha256: str
    device: int
    inode: int
    size: int


def fail(message: str) -> None:
    raise LauncherError(message)


def _stat_fingerprint(details: os.stat_result) -> tuple[int, ...]:
    """Return all security-relevant stable file metadata fields."""

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


def _root_parent_chain(path: Path, label: str) -> tuple[tuple[str, tuple[int, ...]], ...]:
    """Capture a non-replaceable root-owned directory chain without resolving it."""

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


def _safe_regular_file(details: os.stat_result, *, exact_mode: int | None = None) -> bool:
    return (
        stat.S_ISREG(details.st_mode)
        and not stat.S_ISLNK(details.st_mode)
        and details.st_uid == 0
        and details.st_gid == 0
        and details.st_nlink == 1
        and not details.st_mode & 0o022
        and (exact_mode is None or stat.S_IMODE(details.st_mode) == exact_mode)
    )


def validate_runtime_trust() -> None:
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        fail("launcher must run as root on the target Linux host")
    if not sys.flags.isolated or not getattr(sys.flags, "safe_path", False):
        fail("launcher must run with the fixed system Python in isolated safe-path mode (-I)")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("target kernel/Python lacks mandatory O_NOFOLLOW support")


def validate_installed_launcher() -> None:
    """Reject accidental execution from the mutable source snapshot.

    The independent pre-install digest review is what establishes trust before
    Python starts.  This post-start check is deliberately only defense in depth.
    """

    invoked = _canonical_absolute_path(os.path.abspath(__file__), "launcher")
    if invoked != INSTALLED_LAUNCHER:
        fail("launcher is not running from its fixed reviewed installation path")
    parent_before = _root_parent_chain(invoked, "launcher")
    try:
        details = invoked.lstat()
    except OSError as exc:
        raise LauncherError("cannot inspect installed launcher") from exc
    if not _safe_regular_file(details, exact_mode=0o500):
        fail("installed launcher is not root:root 0500 with a single regular link")
    if _root_parent_chain(invoked, "launcher") != parent_before:
        fail("installed launcher parent chain changed during validation")


def read_verified_builder(path: Path, expected_sha256: str) -> VerifiedBuilder:
    """Hash exact builder bytes from one stable no-follow descriptor."""

    if path.name != BUILDER_BASENAME:
        fail("builder basename differs from the fixed reviewed contract")
    if SHA256_RE.fullmatch(expected_sha256) is None:
        fail("expected builder SHA-256 is not canonical lowercase hex")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("target kernel/Python lacks mandatory O_NOFOLLOW support")

    parent_before = _root_parent_chain(path, "builder")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise LauncherError("cannot open reviewed builder safely") from exc
    try:
        opened = os.fstat(descriptor)
        try:
            live = path.lstat()
        except OSError as exc:
            raise LauncherError("cannot bind reviewed builder pathname") from exc
        if (
            not _safe_regular_file(opened)
            or not _safe_regular_file(live)
            or _stat_fingerprint(opened) != _stat_fingerprint(live)
            or not 1 <= opened.st_size <= MAX_BUILDER_BYTES
        ):
            fail("reviewed builder is not one immutable root-owned regular file")

        digest = hashlib.sha256()
        payload = bytearray()
        while True:
            try:
                block = os.read(descriptor, 1024 * 1024)
            except OSError as exc:
                raise LauncherError("cannot read reviewed builder descriptor") from exc
            if not block:
                break
            payload.extend(block)
            if len(payload) > MAX_BUILDER_BYTES:
                fail("reviewed builder exceeded the fixed size limit while reading")
            digest.update(block)

        after = os.fstat(descriptor)
        try:
            live_after = path.lstat()
        except OSError as exc:
            raise LauncherError("reviewed builder pathname changed while hashing") from exc
        if (
            _stat_fingerprint(after) != _stat_fingerprint(opened)
            or _stat_fingerprint(live_after) != _stat_fingerprint(opened)
            or _root_parent_chain(path, "builder") != parent_before
            or len(payload) != opened.st_size
        ):
            fail("reviewed builder or its parent chain changed while hashing")

        actual_sha256 = digest.hexdigest()
        if actual_sha256 != expected_sha256:
            fail("builder bytes differ from the independently reviewed SHA-256")
        return VerifiedBuilder(
            payload=bytes(payload),
            sha256=actual_sha256,
            device=opened.st_dev,
            inode=opened.st_ino,
            size=opened.st_size,
        )
    finally:
        os.close(descriptor)


def execute_verified_builder(
    verified: VerifiedBuilder,
    builder: Path,
    builder_arguments: Sequence[str],
) -> None:
    """Compile and execute only the already authenticated in-memory bytes."""

    for argument in builder_arguments:
        if argument == "--expected-builder-sha256" or argument.startswith(
            "--expected-builder-sha256="
        ):
            fail("builder digest argument is launcher-owned and cannot be overridden")
    try:
        code = compile(verified.payload, str(builder), "exec", dont_inherit=True)
    except (SyntaxError, ValueError) as exc:
        raise LauncherError("verified builder bytes cannot be compiled") from exc

    previous_argv = sys.argv
    previous_dont_write_bytecode = sys.dont_write_bytecode
    sys.argv = [
        str(builder),
        "--expected-builder-sha256",
        verified.sha256,
        *builder_arguments,
    ]
    sys.dont_write_bytecode = True
    namespace = {
        "__name__": "__main__",
        "__file__": str(builder),
        "__package__": None,
        "__cached__": None,
        "__spec__": None,
    }
    try:
        exec(code, namespace, namespace)
    finally:
        sys.argv = previous_argv
        sys.dont_write_bytecode = previous_dont_write_bytecode


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=__doc__,
        allow_abbrev=False,
        epilog="Pass builder arguments only after the mandatory -- boundary.",
    )
    result.add_argument("--builder", required=True)
    result.add_argument("--expected-builder-sha256", required=True)
    return result


def parse_invocation(arguments: Sequence[str]) -> tuple[argparse.Namespace, list[str]]:
    argument_list = list(arguments)
    if argument_list == ["--help"]:
        parser().print_help()
        raise SystemExit(0)
    try:
        boundary = argument_list.index("--")
    except ValueError:
        fail("mandatory -- boundary before builder arguments is missing")
    launcher_arguments = parser().parse_args(argument_list[:boundary])
    builder_arguments = argument_list[boundary + 1 :]
    if not builder_arguments:
        fail("at least one builder argument is required after --")
    return launcher_arguments, builder_arguments


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        validate_runtime_trust()
        validate_installed_launcher()
        parsed, builder_arguments = parse_invocation(
            sys.argv[1:] if arguments is None else arguments
        )
        builder = _canonical_absolute_path(parsed.builder, "builder")
        verified = read_verified_builder(builder, parsed.expected_builder_sha256)
        print(
            "INTERNAL_TEST_REVIEWED_BUILDER_VERIFIED "
            f"sha256={verified.sha256} dev={verified.device} "
            f"inode={verified.inode} size={verified.size}",
            file=sys.stderr,
        )
        execute_verified_builder(verified, builder, builder_arguments)
        return 0
    except LauncherError as exc:
        print(f"{NO_GO_PREFIX}: {exc}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
