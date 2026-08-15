#!/usr/bin/env python3
"""Authenticate the complete monitoring runtime before executing one action.

The installed services never import or execute a sibling pathname.  This
launcher captures the four fixed runtime files with ``O_NOFOLLOW``, binds each
descriptor to the live pathname and root-controlled parent chain, verifies the
reviewed SHA-256 values below, and compiles only the captured bytes.  All
runtime modules are preloaded in memory before the selected action can write
state or use the network.
"""

from __future__ import annotations

import hashlib
import os
import stat
import sys
import types
from pathlib import Path
from typing import Any, NamedTuple, Sequence


INSTALLED_DIRECTORY = Path("/usr/local/libexec/uten-imp-monitoring")
INSTALLED_LAUNCHER = INSTALLED_DIRECTORY / "monitor_runtime_launcher.py"
RUNTIME_FILES = {
    "monitoring_common.py": "82b88da8b6707a352a9531db6feff12930bc058af39cbd7ff2442e7b7e4772c9",
    "alert_spool.py": "12ce37f6dc9e86472c379957ffae8b0603bdc730ae2c66a83cf6b7f44a59c810",
    "host_monitor.py": "197c35eae0997c3302bf5fe1acd9c7c5255b16c48a203c94b9afffa0dd40fe59",
    "external_probe.py": "33782a7975e933ac4686bcca06272451f69325bc217da57eeb52a5539aacbdd4",
}
MODULE_NAMES = {
    "monitoring_common.py": "uten_imp_monitoring_common",
    "alert_spool.py": "uten_imp_monitoring_alert_spool",
    "host_monitor.py": "uten_imp_host_monitor",
    "external_probe.py": "uten_imp_external_probe",
}
ALLOWED_FAILURE_UNITS = {
    "uten-imp-host-monitor.service",
    "uten-imp-external-monitor.service",
}
MAX_RUNTIME_BYTES = 4 * 1024 * 1024
DIRECTORY_MODE = 0o500
RUNTIME_MODE = 0o400
LAUNCHER_MODE = 0o500
SAFE_ENVIRONMENT = {
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}
NO_GO = "UTEN_MONITOR_RUNTIME_NO_GO"


class RuntimeTrustError(RuntimeError):
    """The installed monitoring runtime trust boundary could not be proved."""


class CapturedFile(NamedTuple):
    path: Path
    payload: bytes
    sha256: str
    fingerprint: tuple[int, ...]


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


def _safe_root_file(details: os.stat_result, mode: int) -> bool:
    return (
        stat.S_ISREG(details.st_mode)
        and not stat.S_ISLNK(details.st_mode)
        and details.st_uid == 0
        and details.st_gid == 0
        and details.st_nlink == 1
        and stat.S_IMODE(details.st_mode) == mode
    )


def _parent_chain(path: Path) -> tuple[tuple[str, tuple[int, ...]], ...]:
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
            raise RuntimeTrustError("runtime parent chain is not root controlled")
        captured.append((str(current), _fingerprint(details)))
        if current == current.parent:
            return tuple(captured)
        current = current.parent


def validate_runtime_environment() -> None:
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise RuntimeTrustError("monitor runtime requires root on POSIX")
    if not sys.flags.isolated or not getattr(sys.flags, "safe_path", False):
        raise RuntimeTrustError("monitor runtime requires system Python isolated mode (-I)")
    if not sys.dont_write_bytecode:
        raise RuntimeTrustError("monitor runtime requires bytecode writes disabled (-B)")
    if not hasattr(os, "O_NOFOLLOW"):
        raise RuntimeTrustError("monitor runtime requires O_NOFOLLOW")


def validate_installed_launcher() -> None:
    invoked = Path(os.path.abspath(__file__))
    if invoked != INSTALLED_LAUNCHER:
        raise RuntimeTrustError("launcher is not running from its fixed path")
    before = _parent_chain(invoked)
    try:
        details = invoked.lstat()
    except OSError as exc:
        raise RuntimeTrustError("installed launcher cannot be inspected") from exc
    if not _safe_root_file(details, LAUNCHER_MODE):
        raise RuntimeTrustError("installed launcher must be root:root 0500 single-link")
    if _parent_chain(invoked) != before:
        raise RuntimeTrustError("launcher parent chain changed during validation")


def _capture(path: Path, expected_sha256: str) -> CapturedFile:
    if path.parent != INSTALLED_DIRECTORY or path.name not in RUNTIME_FILES:
        raise RuntimeTrustError("runtime path is outside the fixed inventory")
    if len(expected_sha256) != 64 or any(value not in "0123456789abcdef" for value in expected_sha256):
        raise RuntimeTrustError("compiled runtime digest is malformed")
    parent_before = _parent_chain(path)
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise RuntimeTrustError(f"cannot safely open runtime: {path.name}") from exc
    try:
        opened = os.fstat(descriptor)
        live = path.lstat()
        if (
            not _safe_root_file(opened, RUNTIME_MODE)
            or not _safe_root_file(live, RUNTIME_MODE)
            or _fingerprint(opened) != _fingerprint(live)
            or not 1 <= opened.st_size <= MAX_RUNTIME_BYTES
        ):
            raise RuntimeTrustError(f"runtime metadata is unsafe: {path.name}")
        payload = bytearray()
        digest = hashlib.sha256()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
            digest.update(block)
            if len(payload) > MAX_RUNTIME_BYTES:
                raise RuntimeTrustError(f"runtime exceeds size bound: {path.name}")
        final = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            _fingerprint(final) != _fingerprint(opened)
            or _fingerprint(live_after) != _fingerprint(opened)
            or _parent_chain(path) != parent_before
            or len(payload) != opened.st_size
        ):
            raise RuntimeTrustError(f"runtime changed during capture: {path.name}")
        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise RuntimeTrustError(f"runtime digest differs: {path.name}")
        return CapturedFile(path, bytes(payload), actual, _fingerprint(opened))
    finally:
        os.close(descriptor)


def capture_runtime() -> dict[str, CapturedFile]:
    try:
        directory = INSTALLED_DIRECTORY.lstat()
    except OSError as exc:
        raise RuntimeTrustError("runtime directory cannot be inspected") from exc
    if (
        not stat.S_ISDIR(directory.st_mode)
        or stat.S_ISLNK(directory.st_mode)
        or directory.st_uid != 0
        or directory.st_gid != 0
        or stat.S_IMODE(directory.st_mode) != DIRECTORY_MODE
    ):
        raise RuntimeTrustError("runtime directory must be root:root 0500")
    expected_children = set(RUNTIME_FILES) | {INSTALLED_LAUNCHER.name}
    try:
        actual_children = {entry.name for entry in os.scandir(INSTALLED_DIRECTORY)}
    except OSError as exc:
        raise RuntimeTrustError("runtime directory cannot be enumerated") from exc
    if actual_children != expected_children:
        raise RuntimeTrustError("runtime directory has a missing or unexpected object")
    directory_before = _fingerprint(directory)
    captured = {
        name: _capture(INSTALLED_DIRECTORY / name, digest)
        for name, digest in RUNTIME_FILES.items()
    }
    try:
        directory_after = INSTALLED_DIRECTORY.lstat()
        children_after = {entry.name for entry in os.scandir(INSTALLED_DIRECTORY)}
    except OSError as exc:
        raise RuntimeTrustError("runtime directory changed during capture") from exc
    if _fingerprint(directory_after) != directory_before or children_after != expected_children:
        raise RuntimeTrustError("runtime inventory changed during capture")
    return captured


def _compile_module(captured: CapturedFile, module_name: str) -> types.ModuleType:
    try:
        code = compile(captured.payload, str(captured.path), "exec", dont_inherit=True)
    except (SyntaxError, ValueError) as exc:
        raise RuntimeTrustError(f"captured runtime cannot compile: {captured.path.name}") from exc
    module = types.ModuleType(module_name)
    module.__file__ = str(captured.path)
    module.__package__ = None
    module.__cached__ = None
    module.__spec__ = None
    sys.modules[module_name] = module
    exec(code, module.__dict__, module.__dict__)
    return module


def preload_modules(captured: dict[str, CapturedFile]) -> dict[str, Any]:
    modules: dict[str, Any] = {}
    for filename in (
        "monitoring_common.py",
        "alert_spool.py",
        "host_monitor.py",
        "external_probe.py",
    ):
        modules[filename] = _compile_module(captured[filename], MODULE_NAMES[filename])
    return modules


def _selected_action(arguments: Sequence[str]) -> tuple[str, list[str]]:
    values = list(arguments)
    if values == ["host"]:
        return "host_monitor.py", ["check"]
    if values == ["external"]:
        return "external_probe.py", ["check"]
    if values == ["drain"]:
        return "alert_spool.py", ["drain"]
    if len(values) == 2 and values[0] == "failure" and values[1] in ALLOWED_FAILURE_UNITS:
        return "alert_spool.py", ["unit-failure", "--unit", values[1]]
    raise RuntimeTrustError("runtime action is outside the fixed allowlist")


def execute(arguments: Sequence[str]) -> int:
    target_filename, target_arguments = _selected_action(arguments)
    captured = capture_runtime()
    modules = preload_modules(captured)
    target = modules[target_filename]
    entry = getattr(target, "main", None)
    if not callable(entry):
        raise RuntimeTrustError("captured runtime has no callable main")
    prior_argv = sys.argv
    prior_environment = dict(os.environ)
    prior_umask = os.umask(0o077)
    prior_directory = os.getcwd()
    sys.argv = [str(captured[target_filename].path), *target_arguments]
    os.environ.clear()
    os.environ.update(SAFE_ENVIRONMENT)
    os.chdir("/")
    try:
        result = entry()
    finally:
        os.chdir(prior_directory)
        os.environ.clear()
        os.environ.update(prior_environment)
        sys.argv = prior_argv
        os.umask(prior_umask)
    if not isinstance(result, int) or isinstance(result, bool):
        raise RuntimeTrustError("captured runtime returned a non-integer status")
    return result


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        validate_runtime_environment()
        validate_installed_launcher()
        return execute(sys.argv[1:] if arguments is None else arguments)
    except (RuntimeTrustError, OSError, ValueError) as exc:
        print(f"{NO_GO}: {exc}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
