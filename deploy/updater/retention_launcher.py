#!/usr/bin/env python3
"""Pinned in-memory launcher for the root release-retention manager.

The launcher is the only supported runtime entrypoint.  It captures
``release_updater.py`` and ``retention_manager.py`` from stable ``O_NOFOLLOW``
descriptors, verifies explicit SHA-256 pins, and executes the captured bytes in
memory.  The manager receives the already authenticated updater module and an
attestor that repeats both leaf checks before any persistent write or alert.

``APPROVED_RELEASE_UPDATER_SHA256`` is updated only after the updater bytes are
frozen and independently reviewed.  Production launch and installer plan
recording refuse an unresolved or stale pin.  Tests inject real temporary
digests into ``load_runtime`` and never substitute a fake production digest.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
import types
from pathlib import Path
from typing import Any, Callable, NamedTuple


RUNTIME_DIR = Path("/opt/uten-imp/updater")
LAUNCHER_PATH = RUNTIME_DIR / "retention_launcher.py"
RELEASE_UPDATER_PATH = RUNTIME_DIR / "release_updater.py"
RETENTION_MANAGER_PATH = RUNTIME_DIR / "retention_manager.py"

# Reviewed from the final release_updater.py bytes in this cascade.
APPROVED_RELEASE_UPDATER_SHA256: str | None = (
    "40ee8071e28ba96f297d6b872aebbefdecb005a9ed6023b01b2edab36f594df0"
)

# Updated from the final retention_manager.py bytes in this same change.
APPROVED_RETENTION_MANAGER_SHA256: str | None = (
    "a215b82f03c2e97aaf861091a223945de31e53bbd895ef524ad448149f0a303d"
)

MAX_MODULE_BYTES = 16 * 1024 * 1024
SHA256_RE = re.compile(r"[0-9a-f]{64}")
NO_GO_PREFIX = "UTEN_RELEASE_RETENTION_RUNTIME_NO_GO"


class RuntimeTrustError(RuntimeError):
    """A fixed runtime path, metadata fingerprint, or digest is untrusted."""


class RuntimePins(NamedTuple):
    release_updater_sha256: str
    retention_manager_sha256: str


class VerifiedSource(NamedTuple):
    path: Path
    payload: bytes
    sha256: str
    fingerprint: tuple[int, ...]


def fail(message: str) -> None:
    raise RuntimeTrustError(message)


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


def _canonical_absolute(path: Path, label: str) -> Path:
    raw = str(path)
    if (
        not raw
        or "\x00" in raw
        or not os.path.isabs(raw)
        or os.path.normpath(raw) != raw
    ):
        fail(f"{label} path is not canonical and absolute")
    return path


def _root_parent_chain(path: Path) -> tuple[tuple[str, tuple[int, ...]], ...]:
    captured: list[tuple[str, tuple[int, ...]]] = []
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise RuntimeTrustError("cannot inspect runtime parent chain") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail("runtime parent chain is not root controlled")
        captured.append((str(current), _fingerprint(details)))
        if current == current.parent:
            return tuple(captured)
        current = current.parent


def _validate_pin(value: str, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        fail(f"{label} SHA-256 pin is unresolved or malformed")
    return value


def capture_pinned_source(
    path: Path,
    expected_sha256: str,
    *,
    require_root_control: bool,
    exact_mode: int = 0o644,
) -> VerifiedSource:
    """Capture one immutable byte snapshot and bind it to its live pathname."""

    path = _canonical_absolute(path, "runtime module")
    expected_sha256 = _validate_pin(expected_sha256, path.name)
    if not hasattr(os, "O_NOFOLLOW"):
        fail("target Python lacks mandatory O_NOFOLLOW support")
    parent_before = _root_parent_chain(path) if require_root_control else ()
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise RuntimeTrustError(f"cannot safely open pinned runtime module: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        live = path.lstat()
        if (
            not stat.S_ISREG(opened.st_mode)
            or stat.S_ISLNK(live.st_mode)
            or opened.st_nlink != 1
            or _fingerprint(opened) != _fingerprint(live)
            or not 1 <= opened.st_size <= MAX_MODULE_BYTES
        ):
            fail(f"pinned runtime module is not one stable regular file: {path}")
        if require_root_control and (
            opened.st_uid != 0
            or opened.st_gid != 0
            or stat.S_IMODE(opened.st_mode) != exact_mode
            or opened.st_mode & 0o022
        ):
            fail(f"pinned runtime module is not root:root {exact_mode:04o}: {path}")

        payload = bytearray()
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
            digest.update(block)
            if len(payload) > MAX_MODULE_BYTES:
                fail("pinned runtime module exceeded its fixed size limit")

        after = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            len(payload) != opened.st_size
            or _fingerprint(opened) != _fingerprint(after)
            or _fingerprint(opened) != _fingerprint(live_after)
            or (require_root_control and _root_parent_chain(path) != parent_before)
        ):
            fail(f"pinned runtime module or path changed while captured: {path}")
        actual = digest.hexdigest()
        if actual != expected_sha256:
            fail(f"pinned runtime module digest differs: {path}")
        return VerifiedSource(path, bytes(payload), actual, _fingerprint(opened))
    except OSError as exc:
        raise RuntimeTrustError(f"cannot capture pinned runtime module: {path}") from exc
    finally:
        os.close(descriptor)


def _execute_module(
    source: VerifiedSource,
    module_name: str,
    injected_globals: dict[str, Any] | None = None,
) -> types.ModuleType:
    if not module_name or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]{2,127}", module_name):
        fail("in-memory runtime module name is malformed")
    module = types.ModuleType(module_name)
    module.__file__ = str(source.path)
    module.__package__ = ""
    module.__loader__ = None
    module.__spec__ = None
    if injected_globals:
        module.__dict__.update(injected_globals)
    try:
        code = compile(source.payload, str(source.path), "exec", dont_inherit=True, optimize=0)
    except (SyntaxError, ValueError) as exc:
        raise RuntimeTrustError("pinned runtime module cannot be compiled") from exc
    previous = sys.modules.get(module_name)
    sys.modules[module_name] = module
    try:
        exec(code, module.__dict__, module.__dict__)
        return module
    except BaseException:
        if previous is None:
            sys.modules.pop(module_name, None)
        else:
            sys.modules[module_name] = previous
        raise


def load_runtime(
    *,
    release_updater_path: Path,
    retention_manager_path: Path,
    pins: RuntimePins,
    require_root_control: bool,
) -> types.ModuleType:
    """Load authenticated updater then manager, and inject a live attestor."""

    updater_source = capture_pinned_source(
        release_updater_path,
        pins.release_updater_sha256,
        require_root_control=require_root_control,
    )
    updater = _execute_module(
        updater_source,
        "uten_imp_release_updater_for_retention",
    )
    manager_source = capture_pinned_source(
        retention_manager_path,
        pins.retention_manager_sha256,
        require_root_control=require_root_control,
    )

    def attest() -> None:
        capture_pinned_source(
            release_updater_path,
            pins.release_updater_sha256,
            require_root_control=require_root_control,
        )
        capture_pinned_source(
            retention_manager_path,
            pins.retention_manager_sha256,
            require_root_control=require_root_control,
        )

    manager = _execute_module(
        manager_source,
        "uten_imp_retention_manager",
        {
            "_UTEN_PREVERIFIED_RELEASE_UPDATER": updater,
            "_UTEN_PREVERIFIED_RELEASE_UPDATER_PATH": str(release_updater_path),
            "_UTEN_RETENTION_RUNTIME_TRUST_ATTESTOR": attest,
        },
    )
    # Refuse a path swap between manager execution and its first command.
    attest()
    return manager


def _validate_production_process() -> None:
    if os.name != "posix" or os.geteuid() != 0:
        fail("retention runtime launcher must run as root on Linux")
    if not sys.flags.isolated or not getattr(sys.flags, "safe_path", False):
        fail("retention runtime launcher requires system Python isolated mode (-I)")
    if not sys.dont_write_bytecode:
        fail("retention runtime launcher requires bytecode writes disabled (-B)")
    invoked = Path(os.path.abspath(__file__))
    if invoked != LAUNCHER_PATH:
        fail("retention runtime launcher is outside its fixed installation path")
    parent_before = _root_parent_chain(invoked)
    details = invoked.lstat()
    if (
        not stat.S_ISREG(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or details.st_uid != 0
        or details.st_gid != 0
        or details.st_nlink != 1
        or stat.S_IMODE(details.st_mode) != 0o644
    ):
        fail("installed retention launcher is not root:root 0644")
    if _root_parent_chain(invoked) != parent_before:
        fail("installed retention launcher parent chain changed")


def main() -> int:
    try:
        _validate_production_process()
        pins = RuntimePins(
            _validate_pin(
                APPROVED_RELEASE_UPDATER_SHA256,  # type: ignore[arg-type]
                "release updater",
            ),
            _validate_pin(
                APPROVED_RETENTION_MANAGER_SHA256,  # type: ignore[arg-type]
                "retention manager",
            ),
        )
        os.environ.clear()
        os.environ.update(
            {
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            }
        )
        manager = load_runtime(
            release_updater_path=RELEASE_UPDATER_PATH,
            retention_manager_path=RETENTION_MANAGER_PATH,
            pins=pins,
            require_root_control=True,
        )
        entrypoint = getattr(manager, "main", None)
        if not callable(entrypoint):
            fail("authenticated retention manager has no callable main")
        return int(entrypoint())
    except (OSError, RuntimeError, ValueError) as exc:
        print(
            json.dumps(
                {
                    "error": str(exc),
                    "kind": "uten-imp-retention-runtime-trust-error",
                    "schemaVersion": 1,
                    "status": "failed-closed",
                },
                ensure_ascii=True,
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        print(f"{NO_GO_PREFIX}: authenticated runtime was not executed", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
