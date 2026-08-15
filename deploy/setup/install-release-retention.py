#!/usr/bin/env python3
"""Evidence-bound installer for release-retention controls.

The installer never enables, disables, starts, or stops a unit.  Its only
write-capable flow is ``assess -> record-plan -> apply/resume`` and every write
occurs while the shared release ``operation.lock`` is held.  Rollback restores
only exact transaction preimages and removes only empty directories created by
that transaction; it never traverses or deletes release/evidence contents.
"""

from __future__ import annotations

import argparse
import ast
import fcntl
import grp
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, NamedTuple, Sequence


SCHEMA_VERSION = 1
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_JSON_BYTES = 4 * 1024 * 1024
SHA256_RE = re.compile(r"[0-9a-f]{64}")
APPROVER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@-]{2,63}")
APPROVAL_REFERENCE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}")
TRANSACTION_RE = re.compile(r"tx-[0-9a-f]{32}")
PLAN_RE = re.compile(r"plan-[0-9a-f]{64}\.json")
TRANSACTION_PHASE_RE = re.compile(
    r"(?:preparing-preimages|preimage-[0-9]{3}-(?:captured|recovered)|prepared|"
    r"directories-ready|asset-[0-9]{3}-installed|daemon-reload-pending|"
    r"verified-timers-disabled|completed|rollback-assets-pending|"
    r"rollback-asset-[0-9]{3}|rolled-back)"
)
NO_GO_PREFIX = "UTEN_RELEASE_RETENTION_INSTALL_NO_GO"


class InstallerError(RuntimeError):
    """The assessed or recorded installation contract is not safe to mutate."""


def fail(message: str) -> None:
    raise InstallerError(message)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def canonical_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_sha256(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value))


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


@dataclass(frozen=True)
class Layout:
    source_root: Path
    root_state: Path = Path("/var/lib/uten-imp-release")
    updater_state: Path = Path("/var/lib/uten-imp-updater")
    release_base: Path = Path("/opt/uten-imp")
    policy_dir: Path = Path("/etc/uten-imp-release-retention")
    systemd_dir: Path = Path("/etc/systemd/system")
    local_sbin: Path = Path("/usr/local/sbin")

    @property
    def lock_path(self) -> Path:
        return self.root_state / "operation.lock"

    @property
    def installer_state(self) -> Path:
        return self.root_state / "retention-installer"

    @property
    def plans_dir(self) -> Path:
        return self.installer_state / "plans"

    @property
    def transactions_dir(self) -> Path:
        return self.installer_state / "transactions"

    @property
    def receipts_dir(self) -> Path:
        return self.installer_state / "receipts"

    @property
    def active_path(self) -> Path:
        return self.installer_state / "active.json"

    @property
    def updater_runtime_dir(self) -> Path:
        return self.release_base / "updater"

    @property
    def live_policy(self) -> Path:
        return self.policy_dir / "policy.json"


@dataclass(frozen=True)
class Asset:
    name: str
    source: Path
    target: Path
    mode: int


@dataclass(frozen=True)
class ManagedDirectory:
    path: Path
    mode: int


class Completed(NamedTuple):
    returncode: int
    stdout: str
    stderr: str


CommandRunner = Callable[[Sequence[str]], Completed]
PhaseHook = Callable[[str], None]


def default_runner(command: Sequence[str]) -> Completed:
    completed = subprocess.run(
        list(command),
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
        env={
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
        },
    )
    return Completed(completed.returncode, completed.stdout, completed.stderr)


def default_layout() -> Layout:
    # The reviewed launcher sets __file__ to its frozen source-bundle path.
    return Layout(source_root=Path(__file__).resolve().parents[2])


def assets(layout: Layout) -> tuple[Asset, ...]:
    updater = layout.source_root / "deploy/updater"
    systemd = layout.source_root / "deploy/systemd"
    result = (
        Asset(
            "retention-manager",
            updater / "retention_manager.py",
            layout.updater_runtime_dir / "retention_manager.py",
            0o644,
        ),
        Asset(
            "retention-launcher",
            updater / "retention_launcher.py",
            layout.updater_runtime_dir / "retention_launcher.py",
            0o644,
        ),
        Asset(
            "retention-entrypoint",
            updater / "uten-imp-retention.sh",
            layout.local_sbin / "uten-imp-retention",
            0o755,
        ),
        Asset(
            "policy-example",
            updater / "retention-policy.json.example",
            layout.policy_dir / "policy.json.example",
            0o600,
        ),
        Asset(
            "retention-service",
            systemd / "uten-imp-retention.service.example",
            layout.systemd_dir / "uten-imp-retention.service",
            0o644,
        ),
        Asset(
            "retention-timer",
            systemd / "uten-imp-retention.timer.example",
            layout.systemd_dir / "uten-imp-retention.timer",
            0o644,
        ),
        Asset(
            "retention-alert-service",
            systemd / "uten-imp-retention-alert@.service.example",
            layout.systemd_dir / "uten-imp-retention-alert@.service",
            0o644,
        ),
    )
    if any(item.target == layout.live_policy for item in result):
        fail("policy example must never target the live policy path")
    return result


def managed_directories(layout: Layout) -> tuple[ManagedDirectory, ...]:
    return (
        ManagedDirectory(layout.policy_dir, 0o700),
        ManagedDirectory(layout.root_state / "retention-receipts", 0o700),
        ManagedDirectory(layout.root_state / "retention-alerts", 0o700),
        ManagedDirectory(layout.root_state / "retention-verify", 0o700),
        ManagedDirectory(layout.root_state / "retention-quarantine", 0o700),
        ManagedDirectory(layout.root_state / "retention-quarantine/staging", 0o700),
        ManagedDirectory(layout.release_base / ".retention-quarantine", 0o700),
    )


def _canonical_path(path: Path, label: str) -> Path:
    raw = str(path)
    if (
        not raw
        or "\x00" in raw
        or not os.path.isabs(raw)
        or os.path.normpath(raw) != raw
    ):
        fail(f"{label} path is not canonical and absolute")
    return path


def _safe_parent_chain(path: Path, *, expected_uid: int = 0) -> None:
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise InstallerError(f"cannot inspect parent chain for {path}") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != expected_uid
            or details.st_mode & 0o022
        ):
            fail(f"parent chain is not trusted for {path}")
        if current == current.parent:
            return
        current = current.parent


def _stable_read(
    path: Path,
    *,
    maximum_bytes: int,
    expected_uid: int | None = None,
    expected_gid: int | None = None,
    exact_mode: int | None = None,
) -> tuple[bytes, os.stat_result]:
    path = _canonical_path(path, "file")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("target Python lacks O_NOFOLLOW")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise InstallerError(f"cannot safely open {path}") from exc
    try:
        opened = os.fstat(descriptor)
        live = path.lstat()
        if (
            not stat.S_ISREG(opened.st_mode)
            or stat.S_ISLNK(live.st_mode)
            or opened.st_nlink != 1
            or _fingerprint(opened) != _fingerprint(live)
            or opened.st_mode & 0o022
            or not 1 <= opened.st_size <= maximum_bytes
            or (expected_uid is not None and opened.st_uid != expected_uid)
            or (expected_gid is not None and opened.st_gid != expected_gid)
            or (exact_mode is not None and stat.S_IMODE(opened.st_mode) != exact_mode)
        ):
            fail(f"file ownership/mode/type/link/size is unsafe: {path}")
        payload = bytearray()
        while True:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - len(payload)))
            if not block:
                break
            payload.extend(block)
            if len(payload) > maximum_bytes:
                fail(f"file exceeds its fixed size limit: {path}")
        after = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            len(payload) != opened.st_size
            or _fingerprint(opened) != _fingerprint(after)
            or _fingerprint(opened) != _fingerprint(live_after)
        ):
            fail(f"file changed while captured: {path}")
        return bytes(payload), opened
    finally:
        os.close(descriptor)


def observe_file(
    path: Path,
    *,
    expected_uid: int = 0,
    expected_gid: int = 0,
    exact_mode: int | None = None,
) -> dict[str, Any]:
    if not os.path.lexists(path):
        return {"path": str(path), "state": "missing"}
    try:
        raw, details = _stable_read(
            path,
            maximum_bytes=MAX_FILE_BYTES,
            expected_uid=expected_uid,
            expected_gid=expected_gid,
            exact_mode=exact_mode,
        )
    except (OSError, InstallerError) as exc:
        return {"error": str(exc), "path": str(path), "state": "unsafe"}
    return {
        "gid": details.st_gid,
        "mode": stat.S_IMODE(details.st_mode),
        "path": str(path),
        "sha256": sha256_bytes(raw),
        "size": len(raw),
        "state": "present",
        "uid": details.st_uid,
    }


def observe_operation_lock(path: Path, expected_gid: int) -> dict[str, Any]:
    if not os.path.lexists(path):
        return {"path": str(path), "state": "missing"}
    try:
        details = path.lstat()
    except OSError as exc:
        return {"error": str(exc), "path": str(path), "state": "unsafe"}
    if (
        not stat.S_ISREG(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or details.st_uid != 0
        or details.st_gid != expected_gid
        or details.st_nlink != 1
        or stat.S_IMODE(details.st_mode) != 0o660
    ):
        return {
            "error": "operation.lock is not exact root:approved-group 0660",
            "path": str(path),
            "state": "unsafe",
        }
    return {
        "gid": details.st_gid,
        "mode": 0o660,
        "path": str(path),
        "size": details.st_size,
        "state": "present",
        "uid": details.st_uid,
    }


def observe_directory(
    path: Path, mode: int, *, planned_paths: Iterable[Path] = ()
) -> dict[str, Any]:
    if not os.path.lexists(path):
        try:
            planned = set(planned_paths)
            ancestor = path.parent
            while not os.path.lexists(ancestor):
                if ancestor not in planned:
                    fail(f"missing parent is outside the managed directory plan: {ancestor}")
                ancestor = ancestor.parent
            _safe_parent_chain(ancestor / ".retention-parent-anchor")
        except InstallerError as exc:
            return {"error": str(exc), "path": str(path), "state": "unsafe"}
        return {"mode": mode, "path": str(path), "state": "missing"}
    try:
        details = path.lstat()
    except OSError as exc:
        return {"error": str(exc), "path": str(path), "state": "unsafe"}
    if (
        not stat.S_ISDIR(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != mode
    ):
        return {
            "error": "managed directory is not exact root:root mode",
            "path": str(path),
            "state": "unsafe",
        }
    return {"mode": mode, "path": str(path), "state": "present"}


def strict_json(raw: bytes, label: str) -> dict[str, Any]:
    def object_hook(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if not isinstance(key, str) or key in result:
                fail(f"{label} has a duplicate or non-string key")
            result[key] = value
        return result

    try:
        text = raw.decode("utf-8")
        value = json.loads(text, object_pairs_hook=object_hook)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InstallerError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


POLICY_KEYS = {
    "criticalFreePercent",
    "incomingTtlSeconds",
    "installedProjectHardBytes",
    "installedProjectId",
    "keepVerifiedCandidates",
    "keepVerifiedInstalled",
    "minimumAgeSeconds",
    "minimumFreeBytes",
    "minimumFreePercent",
    "schemaVersion",
    "stagingProjectHardBytes",
    "stagingProjectId",
    "warningFreePercent",
}


def validate_policy(value: Mapping[str, Any]) -> dict[str, int]:
    if set(value) != POLICY_KEYS:
        fail("live retention policy exact key set is invalid")
    result: dict[str, int] = {}
    for key in POLICY_KEYS:
        item = value[key]
        if not isinstance(item, int) or isinstance(item, bool) or item < 0:
            fail(f"live retention policy {key} is not a non-negative integer")
        result[key] = item
    if result["schemaVersion"] != 1:
        fail("live retention policy schema is unsupported")
    if min(result["keepVerifiedCandidates"], result["keepVerifiedInstalled"]) < 3:
        fail("live retention policy keep counts are below the safety floor")
    if not (
        result["minimumFreePercent"]
        < result["criticalFreePercent"]
        < result["warningFreePercent"]
    ):
        fail("live retention policy free-space thresholds are unordered")
    if result["stagingProjectId"] == result["installedProjectId"]:
        fail("live retention policy project IDs must differ")
    return result


def observe_live_policy(layout: Layout) -> dict[str, Any]:
    observed = observe_file(
        layout.live_policy, expected_uid=0, expected_gid=0, exact_mode=0o600
    )
    if observed["state"] != "present":
        return observed
    raw, _details = _stable_read(
        layout.live_policy,
        maximum_bytes=MAX_JSON_BYTES,
        expected_uid=0,
        expected_gid=0,
        exact_mode=0o600,
    )
    try:
        policy = validate_policy(strict_json(raw, "live retention policy"))
    except InstallerError as exc:
        return {
            **observed,
            "error": str(exc),
            "state": "unsafe",
        }
    return {
        **observed,
        "canonicalSha256": canonical_sha256(policy),
        "value": policy,
    }


def _literal_assignment(raw: bytes, name: str) -> Any:
    try:
        tree = ast.parse(raw.decode("utf-8"))
    except (UnicodeDecodeError, SyntaxError) as exc:
        raise InstallerError("trusted Python source cannot be parsed") from exc
    matches: list[Any] = []
    for node in tree.body:
        if isinstance(node, ast.Assign):
            names = [target.id for target in node.targets if isinstance(target, ast.Name)]
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names = [node.target.id]
        else:
            continue
        if name in names:
            try:
                matches.append(ast.literal_eval(node.value))
            except (ValueError, TypeError) as exc:
                raise InstallerError(f"{name} is not a literal trust pin") from exc
    if len(matches) != 1:
        fail(f"trusted source must define {name} exactly once")
    return matches[0]


def _runtime_pins(launcher_raw: bytes) -> tuple[str | None, str | None]:
    return (
        _literal_assignment(launcher_raw, "APPROVED_RELEASE_UPDATER_SHA256"),
        _literal_assignment(launcher_raw, "APPROVED_RETENTION_MANAGER_SHA256"),
    )


def _systemctl_state(runner: CommandRunner, action: str, unit: str) -> str:
    completed = runner(("/usr/bin/systemctl", action, unit))
    value = completed.stdout.strip()
    if "\n" in value or not value:
        return f"error:{completed.returncode}:{value or completed.stderr.strip()}"
    return value


def observe_systemd(runner: CommandRunner) -> dict[str, Any]:
    units = (
        "uten-imp-retention.timer",
        "uten-imp-updater.timer",
        "uten-imp-retention.service",
        "uten-imp-updater.service",
    )
    result: dict[str, Any] = {}
    for unit in units:
        result[unit] = {
            "active": _systemctl_state(runner, "is-active", unit),
            "enabled": _systemctl_state(runner, "is-enabled", unit),
        }
    return result


def _source_observation(
    path: Path,
    *,
    trusted_source_uid: int,
    trusted_source_gid: int,
    trusted_source_mode: int | None,
) -> tuple[dict[str, Any], bytes | None]:
    observed = observe_file(
        path,
        expected_uid=trusted_source_uid,
        expected_gid=trusted_source_gid,
        exact_mode=trusted_source_mode,
    )
    if observed["state"] != "present":
        return observed, None
    raw, _details = _stable_read(
        path,
        maximum_bytes=MAX_FILE_BYTES,
        expected_uid=trusted_source_uid,
        expected_gid=trusted_source_gid,
        exact_mode=trusted_source_mode,
    )
    return observed, raw


def _dependency_assessment(
    layout: Layout,
    *,
    trusted_source_uid: int,
    trusted_source_gid: int,
    trusted_source_mode: int | None,
    approved_release_updater_sha256: str | None,
    approved_manager_sha256: str | None,
) -> tuple[dict[str, Any], list[str]]:
    blockers: list[str] = []
    updater_source = layout.source_root / "deploy/updater/release_updater.py"
    guard_source = layout.source_root / "deploy/updater/release_guard.py"
    manager_source = layout.source_root / "deploy/updater/retention_manager.py"
    updater_source_observed, updater_raw = _source_observation(
        updater_source,
        trusted_source_uid=trusted_source_uid,
        trusted_source_gid=trusted_source_gid,
        trusted_source_mode=trusted_source_mode,
    )
    guard_source_observed, guard_raw = _source_observation(
        guard_source,
        trusted_source_uid=trusted_source_uid,
        trusted_source_gid=trusted_source_gid,
        trusted_source_mode=trusted_source_mode,
    )
    manager_source_observed, manager_raw = _source_observation(
        manager_source,
        trusted_source_uid=trusted_source_uid,
        trusted_source_gid=trusted_source_gid,
        trusted_source_mode=trusted_source_mode,
    )
    updater_target = observe_file(
        layout.updater_runtime_dir / "release_updater.py",
        expected_uid=0,
        expected_gid=0,
        exact_mode=0o644,
    )
    guard_target = observe_file(
        layout.updater_runtime_dir / "release_guard.py",
        expected_uid=0,
        expected_gid=0,
        exact_mode=0o644,
    )
    if approved_release_updater_sha256 is None:
        blockers.append("release updater SHA-256 approval pin is not frozen")
    elif not isinstance(approved_release_updater_sha256, str) or SHA256_RE.fullmatch(
        approved_release_updater_sha256
    ) is None:
        blockers.append("release updater SHA-256 approval pin is malformed")
    if approved_manager_sha256 is None or not isinstance(
        approved_manager_sha256, str
    ) or SHA256_RE.fullmatch(approved_manager_sha256) is None:
        blockers.append("retention manager SHA-256 approval pin is unresolved")
    for label, observation in (
        ("release updater source", updater_source_observed),
        ("release updater target", updater_target),
        ("release guard source", guard_source_observed),
        ("release guard target", guard_target),
        ("retention manager source", manager_source_observed),
    ):
        if observation["state"] != "present":
            blockers.append(f"{label} is missing or unsafe")
    if approved_release_updater_sha256 is not None:
        for label, observation in (
            ("source", updater_source_observed),
            ("installed target", updater_target),
        ):
            if (
                observation.get("state") == "present"
                and observation.get("sha256") != approved_release_updater_sha256
            ):
                blockers.append(f"release updater {label} differs from its approved pin")
    if (
        approved_manager_sha256 is not None
        and manager_source_observed.get("state") == "present"
        and manager_source_observed.get("sha256") != approved_manager_sha256
    ):
        blockers.append("retention manager source differs from its launcher pin")

    guard_pin: str | None = None
    if updater_raw is not None:
        try:
            value = _literal_assignment(updater_raw, "_GUARD_SHA256")
            if isinstance(value, str) and SHA256_RE.fullmatch(value):
                guard_pin = value
            else:
                blockers.append("release updater guard pin is malformed")
        except InstallerError as exc:
            blockers.append(str(exc))
    if guard_pin is not None:
        for label, observation in (
            ("source", guard_source_observed),
            ("installed target", guard_target),
        ):
            if observation.get("sha256") != guard_pin:
                blockers.append(f"release guard {label} differs from updater's embedded pin")

    # Keep raw values out of evidence; their SHA and exact paths are sufficient.
    _ = guard_raw, manager_raw
    return (
        {
            "releaseGuard": {
                "approvedSha256": guard_pin,
                "source": guard_source_observed,
                "target": guard_target,
            },
            "releaseUpdater": {
                "approvedSha256": approved_release_updater_sha256,
                "source": updater_source_observed,
                "target": updater_target,
            },
            "retentionManager": {
                "approvedSha256": approved_manager_sha256,
                "source": manager_source_observed,
            },
        },
        blockers,
    )


def build_assessment(
    layout: Layout,
    *,
    runner: CommandRunner = default_runner,
    trusted_source_uid: int = 0,
    trusted_source_gid: int = 0,
    trusted_source_mode: int | None = 0o400,
    pins_override: tuple[str | None, str | None] | None = None,
    lock_gid: int | None = None,
) -> dict[str, Any]:
    blockers: list[str] = []
    asset_records: list[dict[str, Any]] = []
    launcher_raw: bytes | None = None
    for item in assets(layout):
        source, raw = _source_observation(
            item.source,
            trusted_source_uid=trusted_source_uid,
            trusted_source_gid=trusted_source_gid,
            trusted_source_mode=trusted_source_mode,
        )
        target = observe_file(item.target, expected_uid=0, expected_gid=0)
        if source["state"] != "present" or raw is None:
            blockers.append(f"asset source is missing or unsafe: {item.name}")
        if target["state"] == "unsafe":
            blockers.append(f"asset target has an unknown preimage: {item.name}")
        if item.name == "retention-launcher":
            launcher_raw = raw
        asset_records.append(
            {
                "mode": item.mode,
                "name": item.name,
                "source": str(item.source),
                "sourceSha256": source.get("sha256"),
                "sourceSize": source.get("size"),
                "target": str(item.target),
                "targetPreimage": target,
            }
        )

    if pins_override is not None:
        updater_pin, manager_pin = pins_override
    elif launcher_raw is not None:
        try:
            updater_pin, manager_pin = _runtime_pins(launcher_raw)
        except InstallerError as exc:
            blockers.append(str(exc))
            updater_pin, manager_pin = None, None
    else:
        updater_pin, manager_pin = None, None
    dependencies, dependency_blockers = _dependency_assessment(
        layout,
        trusted_source_uid=trusted_source_uid,
        trusted_source_gid=trusted_source_gid,
        trusted_source_mode=trusted_source_mode,
        approved_release_updater_sha256=updater_pin,
        approved_manager_sha256=manager_pin,
    )
    blockers.extend(dependency_blockers)

    directory_contracts = managed_directories(layout)
    planned_directory_paths = {item.path for item in directory_contracts}
    directories = [
        observe_directory(
            item.path, item.mode, planned_paths=planned_directory_paths
        )
        for item in directory_contracts
    ]
    blockers.extend(
        f"managed directory is unsafe: {item['path']}"
        for item in directories
        if item["state"] == "unsafe"
    )

    required_existing = (
        layout.root_state,
        layout.updater_state,
        layout.release_base,
        layout.release_base / "releases",
        layout.updater_runtime_dir,
        layout.systemd_dir,
        layout.local_sbin,
    )
    existing: list[dict[str, Any]] = []
    for path in required_existing:
        try:
            details = path.lstat()
            valid = (
                stat.S_ISDIR(details.st_mode)
                and not stat.S_ISLNK(details.st_mode)
                and details.st_uid == 0
                and not details.st_mode & 0o022
            )
        except OSError:
            valid = False
        existing.append({"path": str(path), "valid": valid})
        if not valid:
            blockers.append(f"required existing directory is missing or unsafe: {path}")

    if lock_gid is None:
        try:
            lock_gid = grp.getgrnam("uten-imp-updater").gr_gid
        except KeyError:
            lock_gid = -1
    lock = observe_operation_lock(layout.lock_path, lock_gid)
    if lock["state"] != "present":
        blockers.append("shared release operation.lock is missing or unsafe")

    systemd = observe_systemd(runner)
    for timer in ("uten-imp-retention.timer", "uten-imp-updater.timer"):
        if systemd[timer] != {"active": "inactive", "enabled": "disabled"}:
            blockers.append(f"timer must already be disabled and inactive: {timer}")
    for service in ("uten-imp-retention.service", "uten-imp-updater.service"):
        if systemd[service]["active"] != "inactive":
            blockers.append(f"service must already be inactive: {service}")

    live_policy = observe_live_policy(layout)
    if live_policy["state"] == "unsafe":
        blockers.append("live retention policy is unsafe or non-canonical")

    assessment = {
        "assets": asset_records,
        "blockers": sorted(set(blockers)),
        "dependencies": dependencies,
        "directories": directories,
        "kind": "uten-imp-release-retention-install-assessment",
        "livePolicy": live_policy,
        "operationLock": lock,
        "requiredExistingDirectories": existing,
        "schemaVersion": SCHEMA_VERSION,
        "systemd": systemd,
    }
    return assessment


class OperationLock:
    def __init__(self, path: Path, expected_gid: int) -> None:
        self.path = path
        self.expected_gid = expected_gid
        self.descriptor: int | None = None

    def __enter__(self) -> "OperationLock":
        flags = os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        try:
            descriptor = os.open(self.path, flags)
        except OSError as exc:
            raise InstallerError("cannot open shared release operation.lock") from exc
        try:
            opened = os.fstat(descriptor)
            live = self.path.lstat()
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != 0
                or opened.st_gid != self.expected_gid
                or stat.S_IMODE(opened.st_mode) != 0o660
                or opened.st_nlink != 1
                or _fingerprint(opened) != _fingerprint(live)
            ):
                fail("shared release operation.lock metadata is unsafe")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(descriptor)
            raise
        self.descriptor = descriptor
        return self

    def __exit__(self, *_args: object) -> None:
        if self.descriptor is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _mkdir_exact(path: Path, mode: int) -> bool:
    if os.path.lexists(path):
        observed = observe_directory(path, mode)
        if observed["state"] != "present":
            fail(f"directory changed or is unsafe: {path}")
        return False
    _safe_parent_chain(path)
    os.mkdir(path, mode)
    os.chown(path, 0, 0)
    os.chmod(path, mode)
    _fsync_directory(path.parent)
    return True


def _ensure_installer_state(layout: Layout) -> None:
    for path in (
        layout.installer_state,
        layout.plans_dir,
        layout.transactions_dir,
        layout.receipts_dir,
    ):
        _mkdir_exact(path, 0o700)


def _write_all(descriptor: int, raw: bytes) -> None:
    view = memoryview(raw)
    while view:
        written = os.write(descriptor, view)
        if written < 1:
            fail("atomic file write made no progress")
        view = view[written:]


def atomic_create(path: Path, raw: bytes, mode: int = 0o600) -> None:
    if os.path.lexists(path):
        fail(f"refusing to overwrite existing evidence: {path}")
    parent_fd = os.open(
        path.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    descriptor: int | None = None
    try:
        descriptor = os.open(
            path.name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
            mode,
            dir_fd=parent_fd,
        )
        _write_all(descriptor, raw)
        os.fchmod(descriptor, mode)
        os.fchown(descriptor, 0, 0)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.fsync(parent_fd)
    except BaseException:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(path.name, dir_fd=parent_fd)
            os.fsync(parent_fd)
        except OSError:
            pass
        raise
    finally:
        os.close(parent_fd)


def atomic_replace(path: Path, raw: bytes, mode: int, uid: int = 0, gid: int = 0) -> None:
    parent_fd = os.open(
        path.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    name = f".{path.name}.tmp-{uuid.uuid4().hex}"
    descriptor: int | None = None
    try:
        descriptor = os.open(
            name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
            mode,
            dir_fd=parent_fd,
        )
        _write_all(descriptor, raw)
        os.fchmod(descriptor, mode)
        os.fchown(descriptor, uid, gid)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(name, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(name, dir_fd=parent_fd)
        except OSError:
            pass
        os.close(parent_fd)


def _current_lock_gid() -> int:
    try:
        return grp.getgrnam("uten-imp-updater").gr_gid
    except KeyError as exc:
        raise InstallerError("required uten-imp-updater group is absent") from exc


def _load_json_file(
    path: Path,
    *,
    expected_sha256: str | None,
    label: str,
    maximum_bytes: int = MAX_JSON_BYTES,
) -> tuple[dict[str, Any], bytes]:
    raw, _details = _stable_read(
        path,
        maximum_bytes=maximum_bytes,
        expected_uid=0,
        expected_gid=0,
        exact_mode=0o600,
    )
    actual = sha256_bytes(raw)
    if expected_sha256 is not None and actual != expected_sha256:
        fail(f"{label} SHA-256 differs from the approved argument")
    return strict_json(raw, label), raw


def _validate_approval_value(value: str, regex: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or regex.fullmatch(value) is None:
        fail(f"{label} is not canonical")
    return value


def assess(
    layout: Layout,
    *,
    runner: CommandRunner = default_runner,
) -> tuple[dict[str, Any], str]:
    assessment = build_assessment(layout, runner=runner)
    digest = canonical_sha256(assessment)
    return (
        {
            "assessment": assessment,
            "assessmentSha256": digest,
            "kind": "uten-imp-release-retention-install-assessment-envelope",
            "schemaVersion": SCHEMA_VERSION,
        },
        digest,
    )


def record_plan(
    layout: Layout,
    *,
    expected_assessment_sha256: str,
    approver_one: str,
    approver_two: str,
    approval_reference: str,
    runner: CommandRunner = default_runner,
    assessment_options: Mapping[str, Any] | None = None,
) -> tuple[Path, dict[str, Any], str]:
    if SHA256_RE.fullmatch(expected_assessment_sha256) is None:
        fail("expected assessment SHA-256 is malformed")
    approver_one = _validate_approval_value(
        approver_one, APPROVER_RE, "first approver"
    )
    approver_two = _validate_approval_value(
        approver_two, APPROVER_RE, "second approver"
    )
    if approver_one == approver_two:
        fail("two distinct approvers are mandatory")
    approval_reference = _validate_approval_value(
        approval_reference, APPROVAL_REFERENCE_RE, "approval reference"
    )
    options = dict(assessment_options or {})
    lock_gid_value = options.get("lock_gid")
    lock_gid = _current_lock_gid() if lock_gid_value is None else int(lock_gid_value)
    options["lock_gid"] = lock_gid
    with OperationLock(layout.lock_path, lock_gid):
        assessment = build_assessment(layout, runner=runner, **options)
        assessment_sha = canonical_sha256(assessment)
        if assessment_sha != expected_assessment_sha256:
            fail("host/source assessment changed before plan recording")
        if assessment["blockers"]:
            fail("assessment contains NO-GO blockers; no plan was written")
        plan = {
            "approval": {
                "approvalReference": approval_reference,
                "approverOne": approver_one,
                "approverTwo": approver_two,
                "statementSha256": canonical_sha256(
                    {
                        "approvalReference": approval_reference,
                        "approverOne": approver_one,
                        "approverTwo": approver_two,
                        "assessmentSha256": assessment_sha,
                    }
                ),
            },
            "assessment": assessment,
            "assessmentSha256": assessment_sha,
            "kind": "uten-imp-release-retention-install-plan",
            "recordedAtUtc": utc_now(),
            "schemaVersion": SCHEMA_VERSION,
        }
        raw = canonical_bytes(plan)
        plan_sha = sha256_bytes(raw)
        _ensure_installer_state(layout)
        path = layout.plans_dir / f"plan-{assessment_sha}.json"
        atomic_create(path, raw)
        return path, plan, plan_sha


def _require_fixed_plan_path(layout: Layout, path: Path) -> None:
    if path.parent != layout.plans_dir or PLAN_RE.fullmatch(path.name) is None:
        fail("plan path escapes the fixed installer plans directory")


def _validate_plan(
    layout: Layout, path: Path, expected_sha256: str
) -> tuple[dict[str, Any], bytes]:
    _require_fixed_plan_path(layout, path)
    if SHA256_RE.fullmatch(expected_sha256) is None:
        fail("expected plan SHA-256 is malformed")
    plan, raw = _load_json_file(
        path,
        expected_sha256=expected_sha256,
        label="release retention install plan",
    )
    if set(plan) != {
        "approval",
        "assessment",
        "assessmentSha256",
        "kind",
        "recordedAtUtc",
        "schemaVersion",
    }:
        fail("install plan exact key set is invalid")
    if (
        plan.get("kind") != "uten-imp-release-retention-install-plan"
        or plan.get("schemaVersion") != SCHEMA_VERSION
        or not isinstance(plan.get("assessment"), dict)
        or canonical_sha256(plan["assessment"]) != plan.get("assessmentSha256")
        or plan["assessment"].get("blockers") != []
    ):
        fail("install plan assessment binding is invalid")
    approval = plan.get("approval")
    if not isinstance(approval, dict) or set(approval) != {
        "approvalReference",
        "approverOne",
        "approverTwo",
        "statementSha256",
    }:
        fail("install plan two-person approval is malformed")
    if approval["approverOne"] == approval["approverTwo"]:
        fail("install plan approvers are not distinct")
    expected_statement = canonical_sha256(
        {
            "approvalReference": approval["approvalReference"],
            "approverOne": approval["approverOne"],
            "approverTwo": approval["approverTwo"],
            "assessmentSha256": plan["assessmentSha256"],
        }
    )
    if approval.get("statementSha256") != expected_statement:
        fail("install plan approval statement digest is invalid")
    return plan, raw


def _matches_observation(path: Path, expected: Mapping[str, Any]) -> bool:
    if expected.get("state") == "missing":
        return not os.path.lexists(path)
    if expected.get("state") != "present":
        return False
    current = observe_file(
        path,
        expected_uid=int(expected["uid"]),
        expected_gid=int(expected["gid"]),
        exact_mode=int(expected["mode"]),
    )
    return current == dict(expected)


def _asset_payloads(
    plan: Mapping[str, Any],
    *,
    trusted_source_uid: int,
    trusted_source_gid: int,
    trusted_source_mode: int | None,
) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    for record in plan["assessment"]["assets"]:
        path = Path(record["source"])
        raw, _details = _stable_read(
            path,
            maximum_bytes=MAX_FILE_BYTES,
            expected_uid=trusted_source_uid,
            expected_gid=trusted_source_gid,
            exact_mode=trusted_source_mode,
        )
        if (
            sha256_bytes(raw) != record["sourceSha256"]
            or len(raw) != record["sourceSize"]
        ):
            fail(f"asset source drifted after plan recording: {record['name']}")
        result[str(record["target"])] = raw
    return result


def _verify_resume_dependencies(
    layout: Layout,
    plan: Mapping[str, Any],
    *,
    trusted_source_uid: int,
    trusted_source_gid: int,
    trusted_source_mode: int | None,
) -> None:
    expected = plan["assessment"]["dependencies"]
    updater_pin = expected["releaseUpdater"]["approvedSha256"]
    manager_pin = expected["retentionManager"]["approvedSha256"]
    current, blockers = _dependency_assessment(
        layout,
        trusted_source_uid=trusted_source_uid,
        trusted_source_gid=trusted_source_gid,
        trusted_source_mode=trusted_source_mode,
        approved_release_updater_sha256=updater_pin,
        approved_manager_sha256=manager_pin,
    )
    if blockers or current != expected:
        fail("release updater/guard/manager trust dependencies drifted before resume")


def _validate_transaction_plan_binding(
    layout: Layout,
    transaction: Path,
    record: Mapping[str, Any],
    plan: Mapping[str, Any],
) -> None:
    if (
        record.get("kind") != "uten-imp-release-retention-install-transaction"
        or record.get("schemaVersion") != SCHEMA_VERSION
        or record.get("transactionPath") != str(transaction)
        or record.get("planSha256") != sha256_bytes(canonical_bytes(plan))
        or record.get("approval") != plan["approval"]
        or record.get("livePolicy") != plan["assessment"]["livePolicy"]
        or record.get("systemdPreimage") != plan["assessment"]["systemd"]
    ):
        fail("transaction evidence is not bound to its approved plan")
    asset_records = record.get("assets")
    planned_assets = plan["assessment"]["assets"]
    if not isinstance(asset_records, list) or len(asset_records) != len(planned_assets):
        fail("transaction asset evidence is malformed")
    for index, (actual, planned) in enumerate(zip(asset_records, planned_assets)):
        if not isinstance(actual, dict) or set(actual) != {
            "desiredMode",
            "desiredSha256",
            "name",
            "original",
            "preimage",
            "target",
        }:
            fail("transaction asset evidence has an invalid key set")
        expected = {
            "desiredMode": planned["mode"],
            "desiredSha256": planned["sourceSha256"],
            "name": planned["name"],
            "original": planned["targetPreimage"],
            "target": planned["target"],
        }
        if any(actual.get(key) != value for key, value in expected.items()):
            fail("transaction asset evidence differs from its approved plan")
        preimage = actual.get("preimage")
        expected_preimage = transaction / "preimages" / f"{index:03d}.bin"
        if preimage is not None and preimage != str(expected_preimage):
            fail("transaction preimage evidence escapes its fixed directory")
    created = record.get("createdDirectories")
    allowed = {str(item.path) for item in managed_directories(layout)}
    if (
        not isinstance(created, list)
        or any(not isinstance(value, str) for value in created)
        or len(created) != len(set(created))
        or not set(created).issubset(allowed)
    ):
        fail("transaction created-directory evidence is malformed")
    phase = record.get("phase")
    if not isinstance(phase, str) or TRANSACTION_PHASE_RE.fullmatch(phase) is None:
        fail("transaction phase evidence is malformed")


def _transaction_path(layout: Layout, raw: str) -> Path:
    path = Path(raw)
    if path.parent != layout.transactions_dir or TRANSACTION_RE.fullmatch(path.name) is None:
        fail("transaction path escapes its fixed evidence directory")
    return path


def _transaction_record_path(transaction: Path) -> Path:
    return transaction / "transaction.json"


def _write_transaction(transaction: Path, record: dict[str, Any]) -> str:
    path = _transaction_record_path(transaction)
    raw = canonical_bytes(record)
    atomic_replace(path, raw, 0o600)
    return sha256_bytes(raw)


def _load_transaction(
    layout: Layout, transaction: Path, expected_sha256: str | None
) -> tuple[dict[str, Any], bytes]:
    transaction = _transaction_path(layout, str(transaction))
    record, raw = _load_json_file(
        _transaction_record_path(transaction),
        expected_sha256=expected_sha256,
        label="release retention install transaction",
    )
    if (
        not isinstance(record.get("planPath"), str)
        or not isinstance(record.get("planSha256"), str)
        or SHA256_RE.fullmatch(record["planSha256"]) is None
        or not isinstance(record.get("assets"), list)
        or not isinstance(record.get("livePolicy"), dict)
        or not isinstance(record.get("systemdPreimage"), dict)
    ):
        fail("release retention install transaction header is malformed")
    return record, raw


def _create_transaction(
    layout: Layout,
    *,
    plan_path: Path,
    plan_sha256: str,
    plan: Mapping[str, Any],
) -> tuple[Path, dict[str, Any], str]:
    if os.path.lexists(layout.active_path):
        fail("another retention installation transaction is active")
    transaction = layout.transactions_dir / f"tx-{uuid.uuid4().hex}"
    os.mkdir(transaction, 0o700)
    os.chown(transaction, 0, 0)
    os.mkdir(transaction / "preimages", 0o700)
    os.chown(transaction / "preimages", 0, 0)
    _fsync_directory(transaction)
    _fsync_directory(layout.transactions_dir)
    records: list[dict[str, Any]] = []
    for asset_record in plan["assessment"]["assets"]:
        original = asset_record["targetPreimage"]
        if original["state"] not in {"missing", "present"}:
            fail(f"target has an unknown preimage: {asset_record['target']}")
        records.append(
            {
                "desiredMode": asset_record["mode"],
                "desiredSha256": asset_record["sourceSha256"],
                "name": asset_record["name"],
                "original": original,
                "preimage": None,
                "target": asset_record["target"],
            }
        )
    record = {
        "approval": plan["approval"],
        "assets": records,
        "createdDirectories": [],
        "kind": "uten-imp-release-retention-install-transaction",
        "livePolicy": plan["assessment"]["livePolicy"],
        "phase": "preparing-preimages",
        "planPath": str(plan_path),
        "planSha256": plan_sha256,
        "schemaVersion": SCHEMA_VERSION,
        "startedAtUtc": utc_now(),
        "systemdPreimage": plan["assessment"]["systemd"],
        "transactionPath": str(transaction),
    }
    transaction_sha = _write_transaction(transaction, record)
    active = {
        "planSha256": plan_sha256,
        "schemaVersion": SCHEMA_VERSION,
        "transactionPath": str(transaction),
    }
    atomic_create(layout.active_path, canonical_bytes(active))
    return transaction, record, transaction_sha


def _ensure_preimages(
    transaction: Path,
    record: dict[str, Any],
    hook: PhaseHook,
) -> None:
    for index, asset_record in enumerate(record["assets"]):
        original = asset_record["original"]
        if original["state"] == "missing":
            if asset_record.get("preimage") is not None:
                fail("missing target unexpectedly has a rollback preimage")
            continue
        preimage = transaction / "preimages" / f"{index:03d}.bin"
        recorded = asset_record.get("preimage")
        if recorded is None and os.path.lexists(preimage):
            if not _matches_observation(Path(asset_record["target"]), original):
                fail("target changed before orphan preimage recovery")
            raw, _details = _stable_read(
                preimage,
                maximum_bytes=MAX_FILE_BYTES,
                expected_uid=0,
                expected_gid=0,
                exact_mode=0o600,
            )
            if sha256_bytes(raw) != original["sha256"] or len(raw) != original["size"]:
                fail("orphan transaction preimage differs from the approved target")
            asset_record["preimage"] = str(preimage)
            _transition(transaction, record, f"preimage-{index:03d}-recovered", hook)
            continue
        if recorded is not None:
            if recorded != str(preimage):
                fail("transaction preimage path is not canonical")
            raw, _details = _stable_read(
                preimage,
                maximum_bytes=MAX_FILE_BYTES,
                expected_uid=0,
                expected_gid=0,
                exact_mode=0o600,
            )
            if sha256_bytes(raw) != original["sha256"] or len(raw) != original["size"]:
                fail("durable transaction preimage differs from the approved target")
            continue
        target = Path(asset_record["target"])
        if not _matches_observation(target, original):
            fail(f"target drifted before durable preimage capture: {target}")
        raw, _details = _stable_read(
            target,
            maximum_bytes=MAX_FILE_BYTES,
            expected_uid=int(original["uid"]),
            expected_gid=int(original["gid"]),
            exact_mode=int(original["mode"]),
        )
        atomic_create(preimage, raw)
        asset_record["preimage"] = str(preimage)
        _transition(transaction, record, f"preimage-{index:03d}-captured", hook)
    _transition(transaction, record, "prepared", hook)


def _unlink_durable(path: Path) -> None:
    if not os.path.lexists(path):
        return
    details = path.lstat()
    if not stat.S_ISREG(details.st_mode) or stat.S_ISLNK(details.st_mode):
        fail(f"refusing to unlink non-regular transaction file: {path}")
    os.unlink(path)
    _fsync_directory(path.parent)


def _desired_observation(path: Path, digest: str, mode: int) -> dict[str, Any]:
    return observe_file(path, expected_uid=0, expected_gid=0, exact_mode=mode)


def _is_desired(path: Path, digest: str, mode: int) -> bool:
    observed = _desired_observation(path, digest, mode)
    return observed.get("state") == "present" and observed.get("sha256") == digest


def _policy_matches(layout: Layout, expected: Mapping[str, Any]) -> bool:
    return observe_live_policy(layout) == dict(expected)


def _require_quiescent_systemd(runner: CommandRunner, context: str) -> dict[str, Any]:
    states = observe_systemd(runner)
    for timer in ("uten-imp-retention.timer", "uten-imp-updater.timer"):
        if states[timer] != {"active": "inactive", "enabled": "disabled"}:
            fail(f"{context}: timer is not disabled and inactive: {timer}")
    for service in ("uten-imp-retention.service", "uten-imp-updater.service"):
        if states[service]["active"] != "inactive":
            fail(f"{context}: service is not inactive: {service}")
    return states


def _transition(
    transaction: Path,
    record: dict[str, Any],
    phase: str,
    hook: PhaseHook,
) -> str:
    record["phase"] = phase
    digest = _write_transaction(transaction, record)
    hook(phase)
    return digest


def _verify_systemd_after_apply(
    layout: Layout,
    *,
    runner: CommandRunner,
) -> dict[str, Any]:
    unit_paths = (
        layout.systemd_dir / "uten-imp-retention.service",
        layout.systemd_dir / "uten-imp-retention.timer",
        layout.systemd_dir / "uten-imp-retention-alert@.service",
    )
    verified = runner(("/usr/bin/systemd-analyze", "verify", *(str(path) for path in unit_paths)))
    if verified.returncode != 0:
        fail("systemd-analyze verify rejected retention units")
    reloaded = runner(("/usr/bin/systemctl", "daemon-reload"))
    if reloaded.returncode != 0:
        fail("systemctl daemon-reload failed")
    states = observe_systemd(runner)
    for timer in ("uten-imp-retention.timer", "uten-imp-updater.timer"):
        if states[timer] != {"active": "inactive", "enabled": "disabled"}:
            fail(f"timer did not remain disabled and inactive: {timer}")
    for service in ("uten-imp-retention.service", "uten-imp-updater.service"):
        if states[service]["active"] != "inactive":
            fail(f"service became active during asset installation: {service}")
    for unit, expected in (
        ("uten-imp-retention.service", unit_paths[0]),
        ("uten-imp-retention.timer", unit_paths[1]),
        ("uten-imp-retention-alert@.service", unit_paths[2]),
    ):
        shown = runner(
            (
                "/usr/bin/systemctl",
                "show",
                unit,
                "--property=FragmentPath",
                "--value",
            )
        )
        if shown.returncode != 0 or shown.stdout.strip() != str(expected):
            fail(f"systemd did not load the installed retention fragment: {unit}")
    return states


def _verify_assets_installed(record: Mapping[str, Any]) -> None:
    for asset_record in record["assets"]:
        if not _is_desired(
            Path(asset_record["target"]),
            asset_record["desiredSha256"],
            int(asset_record["desiredMode"]),
        ):
            fail(f"installed asset failed digest/mode verification: {asset_record['target']}")


def _finish_success(
    layout: Layout,
    transaction: Path,
    record: dict[str, Any],
    *,
    states: Mapping[str, Any],
    hook: PhaseHook,
) -> tuple[dict[str, Any], str]:
    receipt_path = layout.receipts_dir / f"{transaction.name}.installed.json"
    if record.get("phase") == "completed":
        existing, raw = _load_json_file(
            Path(record["receiptPath"]),
            expected_sha256=record["receiptSha256"],
            label="retention installation receipt",
        )
        _unlink_durable(layout.active_path)
        return existing, sha256_bytes(raw)
    if os.path.lexists(receipt_path):
        receipt, existing_raw = _load_json_file(
            receipt_path,
            expected_sha256=None,
            label="retention installation receipt",
        )
        expected_fields = {
            "approval": record["approval"],
            "kind": "uten-imp-release-retention-install-receipt",
            "livePolicy": record["livePolicy"],
            "planPath": record["planPath"],
            "planSha256": record["planSha256"],
            "schemaVersion": SCHEMA_VERSION,
            "status": "installed-uncommissioned-timers-disabled",
            "systemd": states,
            "transactionPath": str(transaction),
        }
        if any(receipt.get(key) != value for key, value in expected_fields.items()):
            fail("existing install receipt differs during crash recovery")
        raw = existing_raw
    else:
        receipt = {
            "approval": record["approval"],
            "completedAtUtc": utc_now(),
            "kind": "uten-imp-release-retention-install-receipt",
            "livePolicy": record["livePolicy"],
            "planPath": record["planPath"],
            "planSha256": record["planSha256"],
            "schemaVersion": SCHEMA_VERSION,
            "status": "installed-uncommissioned-timers-disabled",
            "systemd": states,
            "transactionPath": str(transaction),
        }
        raw = canonical_bytes(receipt)
        atomic_create(receipt_path, raw)
    record["approval"] = record["approval"]
    record["receiptPath"] = str(receipt_path)
    record["receiptSha256"] = sha256_bytes(raw)
    _transition(transaction, record, "completed", hook)
    _unlink_durable(layout.active_path)
    return receipt, sha256_bytes(raw)


def _continue_apply(
    layout: Layout,
    *,
    transaction: Path,
    record: dict[str, Any],
    plan: Mapping[str, Any],
    payloads: Mapping[str, bytes],
    runner: CommandRunner,
    hook: PhaseHook,
) -> tuple[dict[str, Any], str]:
    if not _policy_matches(layout, record["livePolicy"]):
        fail("live retention policy changed after approval")
    created = set(record.get("createdDirectories", []))
    for directory in plan["assessment"]["directories"]:
        path = Path(directory["path"])
        state = directory["state"]
        mode = int(directory["mode"])
        if state == "present":
            if observe_directory(path, mode)["state"] != "present":
                fail(f"managed directory drifted after plan approval: {path}")
        elif state == "missing":
            if not os.path.lexists(path):
                _mkdir_exact(path, mode)
            elif observe_directory(path, mode)["state"] != "present":
                fail(f"planned directory appeared with unsafe metadata: {path}")
            created.add(str(path))
        else:
            fail(f"managed directory has an unknown approved state: {path}")
        record["createdDirectories"] = sorted(created)
        _write_transaction(transaction, record)
    _transition(transaction, record, "directories-ready", hook)

    for index, asset_record in enumerate(record["assets"]):
        target = Path(asset_record["target"])
        desired_sha = asset_record["desiredSha256"]
        desired_mode = int(asset_record["desiredMode"])
        if _is_desired(target, desired_sha, desired_mode):
            pass
        elif _matches_observation(target, asset_record["original"]):
            payload = payloads.get(str(target))
            if payload is None or sha256_bytes(payload) != desired_sha:
                fail(f"approved asset payload is unavailable: {target}")
            atomic_replace(target, payload, desired_mode)
        else:
            fail(f"asset target drifted after plan approval: {target}")
        if not _is_desired(target, desired_sha, desired_mode):
            fail(f"asset target verification failed after atomic write: {target}")
        _transition(transaction, record, f"asset-{index:03d}-installed", hook)

    _verify_assets_installed(record)
    if not _policy_matches(layout, record["livePolicy"]):
        fail("live retention policy changed during installation")
    _transition(transaction, record, "daemon-reload-pending", hook)
    states = _verify_systemd_after_apply(layout, runner=runner)
    _transition(transaction, record, "verified-timers-disabled", hook)
    _verify_assets_installed(record)
    if not _policy_matches(layout, record["livePolicy"]):
        fail("live retention policy changed after systemd verification")
    return _finish_success(
        layout, transaction, record, states=states, hook=hook
    )


def _load_active(layout: Layout) -> dict[str, Any]:
    value, _raw = _load_json_file(
        layout.active_path,
        expected_sha256=None,
        label="active retention installer transaction",
    )
    if set(value) != {"planSha256", "schemaVersion", "transactionPath"}:
        fail("active retention installer evidence is malformed")
    if value.get("schemaVersion") != SCHEMA_VERSION:
        fail("active retention installer evidence schema is unsupported")
    _transaction_path(layout, value["transactionPath"])
    return value


def apply_plan(
    layout: Layout,
    *,
    plan_path: Path,
    expected_plan_sha256: str,
    confirm: str,
    runner: CommandRunner = default_runner,
    hook: PhaseHook = lambda _phase: None,
    assessment_options: Mapping[str, Any] | None = None,
) -> tuple[dict[str, Any], str]:
    if confirm != f"APPLY-RELEASE-RETENTION:{expected_plan_sha256}":
        fail("apply confirmation is not bound to the exact plan SHA-256")
    options = dict(assessment_options or {})
    lock_gid_value = options.get("lock_gid")
    lock_gid = _current_lock_gid() if lock_gid_value is None else int(lock_gid_value)
    options["lock_gid"] = lock_gid
    with OperationLock(layout.lock_path, lock_gid):
        plan, _raw = _validate_plan(layout, plan_path, expected_plan_sha256)
        if os.path.lexists(layout.active_path):
            fail("an active transaction exists; use resume or rollback")
        current = build_assessment(layout, runner=runner, **options)
        if current != plan["assessment"]:
            fail("host/source/preimage assessment drifted; apply made no managed mutation")
        payloads = _asset_payloads(
            plan,
            trusted_source_uid=int(options.get("trusted_source_uid", 0)),
            trusted_source_gid=int(options.get("trusted_source_gid", 0)),
            trusted_source_mode=options.get("trusted_source_mode", 0o400),
        )
        transaction, record, _transaction_sha = _create_transaction(
            layout,
            plan_path=plan_path,
            plan_sha256=expected_plan_sha256,
            plan=plan,
        )
        _write_transaction(transaction, record)
        hook("transaction-active")
        _ensure_preimages(transaction, record, hook)
        return _continue_apply(
            layout,
            transaction=transaction,
            record=record,
            plan=plan,
            payloads=payloads,
            runner=runner,
            hook=hook,
        )


def resume(
    layout: Layout,
    *,
    transaction: Path,
    expected_transaction_sha256: str,
    confirm: str,
    runner: CommandRunner = default_runner,
    hook: PhaseHook = lambda _phase: None,
    source_options: Mapping[str, Any] | None = None,
) -> tuple[dict[str, Any], str]:
    if confirm != f"RESUME-RELEASE-RETENTION:{expected_transaction_sha256}":
        fail("resume confirmation is not bound to the transaction SHA-256")
    options = dict(source_options or {})
    lock_gid_value = options.get("lock_gid")
    lock_gid = _current_lock_gid() if lock_gid_value is None else int(lock_gid_value)
    with OperationLock(layout.lock_path, lock_gid):
        record, _raw = _load_transaction(
            layout, transaction, expected_transaction_sha256
        )
        active = _load_active(layout) if os.path.lexists(layout.active_path) else None
        if active is not None and active["transactionPath"] != str(transaction):
            fail("active transaction differs from the approved resume evidence")
        plan_path = Path(record["planPath"])
        plan, _plan_raw = _validate_plan(
            layout, plan_path, record["planSha256"]
        )
        _validate_transaction_plan_binding(layout, transaction, record, plan)
        phase = record.get("phase")
        if phase == "completed":
            return _finish_success(
                layout,
                transaction,
                record,
                states=record["systemdPreimage"],
                hook=hook,
            )
        if phase == "rolled-back" or (
            isinstance(phase, str) and phase.startswith("rollback-")
        ):
            fail("rolled-back transaction cannot be resumed as an installation")
        payloads = _asset_payloads(
            plan,
            trusted_source_uid=int(options.get("trusted_source_uid", 0)),
            trusted_source_gid=int(options.get("trusted_source_gid", 0)),
            trusted_source_mode=options.get("trusted_source_mode", 0o400),
        )
        _verify_resume_dependencies(
            layout,
            plan,
            trusted_source_uid=int(options.get("trusted_source_uid", 0)),
            trusted_source_gid=int(options.get("trusted_source_gid", 0)),
            trusted_source_mode=options.get("trusted_source_mode", 0o400),
        )
        if not _policy_matches(layout, record["livePolicy"]):
            fail("live retention policy changed before resume")
        _require_quiescent_systemd(runner, "resume refused")
        if active is None:
            # Evidence-bound adoption closes the narrow crash window between
            # durable transaction creation and active-marker creation.  All
            # source, dependency, policy and timer checks precede this write.
            atomic_create(
                layout.active_path,
                canonical_bytes(
                    {
                        "planSha256": record["planSha256"],
                        "schemaVersion": SCHEMA_VERSION,
                        "transactionPath": str(transaction),
                    }
                ),
            )
        _ensure_preimages(transaction, record, hook)
        return _continue_apply(
            layout,
            transaction=transaction,
            record=record,
            plan=plan,
            payloads=payloads,
            runner=runner,
            hook=hook,
        )


def _preflight_rollback(record: Mapping[str, Any]) -> None:
    for asset_record in record["assets"]:
        target = Path(asset_record["target"])
        if _is_desired(
            target,
            asset_record["desiredSha256"],
            int(asset_record["desiredMode"]),
        ) or _matches_observation(target, asset_record["original"]):
            continue
        fail(f"rollback refuses unexpected target drift: {target}")


def _restore_asset(asset_record: Mapping[str, Any]) -> None:
    target = Path(asset_record["target"])
    original = asset_record["original"]
    if _matches_observation(target, original):
        return
    if not _is_desired(
        target,
        asset_record["desiredSha256"],
        int(asset_record["desiredMode"]),
    ):
        fail(f"rollback target no longer equals installed or original bytes: {target}")
    if original["state"] == "missing":
        details = target.lstat()
        if not stat.S_ISREG(details.st_mode) or stat.S_ISLNK(details.st_mode):
            fail(f"rollback refuses to unlink non-regular installed asset: {target}")
        os.unlink(target)
        _fsync_directory(target.parent)
        return
    preimage_value = asset_record.get("preimage")
    if not isinstance(preimage_value, str):
        fail(f"rollback preimage is absent: {target}")
    preimage = Path(preimage_value)
    transaction = preimage.parent.parent
    if preimage.parent != transaction / "preimages" or not re.fullmatch(
        r"[0-9]{3}\.bin", preimage.name
    ):
        fail("rollback preimage path escapes its fixed transaction directory")
    raw, _details = _stable_read(
        preimage,
        maximum_bytes=MAX_FILE_BYTES,
        expected_uid=0,
        expected_gid=0,
        exact_mode=0o600,
    )
    if sha256_bytes(raw) != original["sha256"] or len(raw) != original["size"]:
        fail(f"rollback preimage digest/size differs: {target}")
    atomic_replace(
        target,
        raw,
        int(original["mode"]),
        int(original["uid"]),
        int(original["gid"]),
    )


def _remove_created_empty_directories(
    layout: Layout, created_directories: Iterable[str]
) -> None:
    protected = {
        layout.release_base / "releases",
        layout.root_state / "recovery-evidence",
        layout.root_state / "database-receipts",
    }
    allowed = {item.path for item in managed_directories(layout)}
    paths = sorted(
        {Path(value) for value in created_directories},
        key=lambda value: len(value.parts),
        reverse=True,
    )
    if any(path not in allowed or path in protected for path in paths):
        fail("rollback created-directory evidence escapes its fixed allowlist")
    for path in paths:
        if not os.path.lexists(path):
            continue
        observed = next(
            item for item in managed_directories(layout) if item.path == path
        )
        if observe_directory(path, observed.mode)["state"] != "present":
            fail(f"rollback refuses changed transaction-created directory: {path}")
        try:
            os.rmdir(path)
        except OSError as exc:
            raise InstallerError(
                f"rollback leaves non-empty transaction-created directory untouched: {path}"
            ) from exc
        _fsync_directory(path.parent)


def rollback(
    layout: Layout,
    *,
    transaction: Path,
    expected_transaction_sha256: str,
    confirm: str,
    runner: CommandRunner = default_runner,
    hook: PhaseHook = lambda _phase: None,
    lock_gid: int | None = None,
) -> tuple[dict[str, Any], str]:
    if confirm != f"ROLLBACK-RELEASE-RETENTION:{expected_transaction_sha256}":
        fail("rollback confirmation is not bound to the transaction SHA-256")
    if lock_gid is None:
        lock_gid = _current_lock_gid()
    with OperationLock(layout.lock_path, lock_gid):
        record, _raw = _load_transaction(
            layout, transaction, expected_transaction_sha256
        )
        active = _load_active(layout) if os.path.lexists(layout.active_path) else None
        if active is not None and active["transactionPath"] != str(transaction):
            fail("rollback evidence differs from the active transaction")
        plan, _plan_raw = _validate_plan(
            layout, Path(record["planPath"]), record["planSha256"]
        )
        _validate_transaction_plan_binding(layout, transaction, record, plan)
        if not _policy_matches(layout, record["livePolicy"]):
            fail("live retention policy changed; rollback made no asset mutation")
        _preflight_rollback(record)
        _transition(transaction, record, "rollback-assets-pending", hook)
        for index, asset_record in reversed(list(enumerate(record["assets"]))):
            _restore_asset(asset_record)
            _transition(transaction, record, f"rollback-asset-{index:03d}", hook)
        reloaded = runner(("/usr/bin/systemctl", "daemon-reload"))
        if reloaded.returncode != 0:
            fail("systemctl daemon-reload failed during rollback")
        current_systemd = observe_systemd(runner)
        if current_systemd != record["systemdPreimage"]:
            fail("systemd state differs after exact asset rollback")
        if not _policy_matches(layout, record["livePolicy"]):
            fail("live retention policy changed during rollback")
        _remove_created_empty_directories(
            layout, record.get("createdDirectories", [])
        )
        receipt_path = layout.receipts_dir / f"{transaction.name}.rollback.json"
        if os.path.lexists(receipt_path):
            receipt, existing_raw = _load_json_file(
                receipt_path,
                expected_sha256=None,
                label="retention installer rollback receipt",
            )
            expected_fields = {
                "approval": record["approval"],
                "kind": "uten-imp-release-retention-install-rollback-receipt",
                "planSha256": record["planSha256"],
                "schemaVersion": SCHEMA_VERSION,
                "status": "exact-preimages-restored",
                "transactionPath": str(transaction),
            }
            if any(receipt.get(key) != value for key, value in expected_fields.items()):
                fail("existing rollback receipt differs")
            receipt_raw = existing_raw
        else:
            receipt = {
                "approval": record["approval"],
                "completedAtUtc": utc_now(),
                "kind": "uten-imp-release-retention-install-rollback-receipt",
                "planSha256": record["planSha256"],
                "schemaVersion": SCHEMA_VERSION,
                "status": "exact-preimages-restored",
                "transactionPath": str(transaction),
            }
            receipt_raw = canonical_bytes(receipt)
            atomic_create(receipt_path, receipt_raw)
        record["rollbackReceiptPath"] = str(receipt_path)
        record["rollbackReceiptSha256"] = sha256_bytes(receipt_raw)
        _transition(transaction, record, "rolled-back", hook)
        _unlink_durable(layout.active_path)
        return receipt, sha256_bytes(receipt_raw)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Evidence-bound release-retention asset installer"
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("assess", help="read-only assessment; writes nothing")
    record = commands.add_parser(
        "record-plan", help="record an exact two-person-approved assessment"
    )
    record.add_argument("--expected-assessment-sha256", required=True)
    record.add_argument("--approver-one", required=True)
    record.add_argument("--approver-two", required=True)
    record.add_argument("--approval-reference", required=True)
    apply_command = commands.add_parser(
        "apply", help="apply the exact recorded plan without commissioning timers"
    )
    apply_command.add_argument("--plan", required=True, type=Path)
    apply_command.add_argument("--expected-plan-sha256", required=True)
    apply_command.add_argument("--confirm", required=True)
    resume_command = commands.add_parser(
        "resume", help="resume one exact interrupted transaction"
    )
    resume_command.add_argument("--transaction", required=True, type=Path)
    resume_command.add_argument("--expected-transaction-sha256", required=True)
    resume_command.add_argument("--confirm", required=True)
    rollback_command = commands.add_parser(
        "rollback", help="restore only exact transaction preimages"
    )
    rollback_command.add_argument("--transaction", required=True, type=Path)
    rollback_command.add_argument("--expected-transaction-sha256", required=True)
    rollback_command.add_argument("--confirm", required=True)
    return parser


def main() -> int:
    try:
        if os.name != "posix" or os.geteuid() != 0:
            fail("installer must run as root on Linux")
        args = build_parser().parse_args()
        layout = default_layout()
        if args.command == "assess":
            envelope, digest = assess(layout)
            print(canonical_bytes(envelope).decode("utf-8"), end="")
            print(f"ASSESSMENT_SHA256={digest}", file=sys.stderr)
            return 1 if envelope["assessment"]["blockers"] else 0
        if args.command == "record-plan":
            path, _plan, digest = record_plan(
                layout,
                expected_assessment_sha256=args.expected_assessment_sha256,
                approver_one=args.approver_one,
                approver_two=args.approver_two,
                approval_reference=args.approval_reference,
            )
            print(
                canonical_bytes(
                    {"planPath": str(path), "planSha256": digest, "status": "recorded"}
                ).decode("utf-8"),
                end="",
            )
            return 0
        if args.command == "apply":
            receipt, digest = apply_plan(
                layout,
                plan_path=args.plan,
                expected_plan_sha256=args.expected_plan_sha256,
                confirm=args.confirm,
            )
        elif args.command == "resume":
            receipt, digest = resume(
                layout,
                transaction=args.transaction,
                expected_transaction_sha256=args.expected_transaction_sha256,
                confirm=args.confirm,
            )
        else:
            receipt, digest = rollback(
                layout,
                transaction=args.transaction,
                expected_transaction_sha256=args.expected_transaction_sha256,
                confirm=args.confirm,
            )
        print(
            canonical_bytes(
                {"receipt": receipt, "receiptSha256": digest}
            ).decode("utf-8"),
            end="",
        )
        return 0
    except (InstallerError, OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"{NO_GO_PREFIX}: {exc}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
