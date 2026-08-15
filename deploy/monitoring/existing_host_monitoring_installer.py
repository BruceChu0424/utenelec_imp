#!/usr/bin/env python3
"""Evidence-bound installer for monitoring on an existing Uten host.

``assess`` is read-only. ``record-plan`` repeats the approved assessment under
the installer lock and records one canonical root-only plan. ``apply`` captures
all source bytes through stable descriptors, records every target preimage, and
installs without starting or enabling anything. Interrupted work is continued
only by ``resume`` or reverted by evidence-bound ``rollback``.

The three timers must remain disabled and inactive through every action.  The
optional journald drop-in is intentionally outside this transaction and uses
``existing_host_journald_installer.py``; neither installer restarts journald.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, NamedTuple, Sequence

try:
    import fcntl
except ImportError:  # pragma: no cover - production is Linux.
    fcntl = None  # type: ignore[assignment]


SCHEMA_VERSION = 1
PLAN_KIND = "uten-imp-monitoring-install-plan"
TRANSACTION_KIND = "uten-imp-monitoring-install-transaction"
RECEIPT_KIND = "uten-imp-monitoring-uncommissioned-receipt"
ROLLBACK_KIND = "uten-imp-monitoring-rollback-receipt"
ASSESSMENT_KIND = "uten-imp-monitoring-read-only-assessment"
RECORD_CONFIRMATION = "RECORD REVIEWED UTEN MONITORING INSTALL PLAN"
APPLY_CONFIRMATION = "APPLY REVIEWED UTEN MONITORING INSTALL PLAN"
ROLLBACK_CONFIRMATION = "ROLLBACK UNCOMMISSIONED UTEN MONITORING INSTALLATION"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

HERE = Path(__file__).resolve().parent
DEPLOY_ROOT = HERE.parent
SYSTEMD_SOURCE = DEPLOY_ROOT / "systemd"

STATE_ROOT = Path("/var/lib/uten-imp-monitoring")
JOURNAL_ROOT = STATE_ROOT / "journal"
INSTALLER_ROOT = JOURNAL_ROOT / "installer"
PLAN_PATH = INSTALLER_ROOT / "install-plan.json"
PLAN_HISTORY = INSTALLER_ROOT / "plan-history"
TRANSACTIONS = INSTALLER_ROOT / "transactions"
ROLLBACK_RECEIPTS = INSTALLER_ROOT / "rollback-receipts"
ACTIVE_TRANSACTION = INSTALLER_ROOT / "active-transaction.json"
UNCOMMISSIONED_RECEIPT = INSTALLER_ROOT / "uncommissioned-install.json"
COMMISSIONED_MARKER = INSTALLER_ROOT / "commissioned.json"
LOCK_PATH = INSTALLER_ROOT / "installer.lock"

JOURNALD_INSTALLER_ROOT = JOURNAL_ROOT / "journald-installer"
JOURNALD_PLAN_PATH = JOURNALD_INSTALLER_ROOT / "install-plan.json"
JOURNALD_TRANSACTION_PATH = JOURNALD_INSTALLER_ROOT / "active-transaction.json"
JOURNALD_RECEIPT_PATH = JOURNALD_INSTALLER_ROOT / "uncommissioned-install.json"
JOURNALD_ROLLBACK_RECEIPTS = JOURNALD_INSTALLER_ROOT / "rollback-receipts"
JOURNALD_TRANSACTIONS = JOURNALD_INSTALLER_ROOT / "transactions"
JOURNALD_LOCK_PATH = JOURNALD_INSTALLER_ROOT / "installer.lock"
JOURNALD_TARGET = Path("/etc/systemd/journald.conf.d/60-uten-imp.conf")
JOURNALD_RECORD_CONFIRMATION = "RECORD REVIEWED UTEN JOURNALD INSTALL PLAN"
JOURNALD_APPLY_CONFIRMATION = "APPLY REVIEWED UTEN JOURNALD INSTALL PLAN"
JOURNALD_ROLLBACK_CONFIRMATION = "ROLLBACK UNCOMMISSIONED UTEN JOURNALD INSTALLATION"

LIBEXEC_DIR = Path("/usr/local/libexec/uten-imp-monitoring")
CONFIG_DIR = Path("/etc/uten-imp-monitoring")
DOC_DIR = Path("/usr/local/share/doc/uten-imp-monitoring")
SYSTEMD_DIR = Path("/etc/systemd/system")
HOST_POLICY_TARGET = CONFIG_DIR / "host-policy.json"
EXTERNAL_POLICY_TARGET = CONFIG_DIR / "external-policy.json"
HARDWARE_AUTHORITY_TARGET = CONFIG_DIR / "storage-hardware-authority.json"
FIXED_ALERT_SENDER = Path("/usr/local/libexec/uten-imp-alerting/submit")

TIMER_UNITS = (
    "uten-imp-host-monitor.timer",
    "uten-imp-external-monitor.timer",
    "uten-imp-monitor-alert-drain.timer",
)
SERVICE_UNITS = (
    "uten-imp-host-monitor.service",
    "uten-imp-external-monitor.service",
    "uten-imp-monitor-alert-drain.service",
    "uten-imp-monitor-failure@.service",
)
MANAGED_UNITS = (*SERVICE_UNITS, *TIMER_UNITS)
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_PLAN_BYTES = 4 * 1024 * 1024
COMMAND_TIMEOUT = 60
SAFE_ENVIRONMENT = {
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}


class InstallerError(RuntimeError):
    """The monitoring installation contract could not be proved."""


@dataclass(frozen=True)
class Asset:
    name: str
    source: Path
    target: Path
    mode: int


@dataclass(frozen=True)
class PolicyInput:
    name: str
    source: Path
    expected_sha256: str
    target: Path
    mode: int


class Capture(NamedTuple):
    path: Path
    payload: bytes
    fingerprint: tuple[int, ...]
    parent_chain: tuple[tuple[str, tuple[int, ...]], ...]


STATIC_ASSETS = (
    Asset("runtime-launcher", HERE / "monitor_runtime_launcher.py", LIBEXEC_DIR / "monitor_runtime_launcher.py", 0o500),
    Asset("monitoring-common", HERE / "monitoring_common.py", LIBEXEC_DIR / "monitoring_common.py", 0o400),
    Asset("alert-spool", HERE / "alert_spool.py", LIBEXEC_DIR / "alert_spool.py", 0o400),
    Asset("host-monitor", HERE / "host_monitor.py", LIBEXEC_DIR / "host_monitor.py", 0o400),
    Asset("external-probe", HERE / "external_probe.py", LIBEXEC_DIR / "external_probe.py", 0o400),
    Asset("host-service", SYSTEMD_SOURCE / "uten-imp-host-monitor.service.example", SYSTEMD_DIR / "uten-imp-host-monitor.service", 0o644),
    Asset("host-timer", SYSTEMD_SOURCE / "uten-imp-host-monitor.timer.example", SYSTEMD_DIR / "uten-imp-host-monitor.timer", 0o644),
    Asset("external-service", SYSTEMD_SOURCE / "uten-imp-external-monitor.service.example", SYSTEMD_DIR / "uten-imp-external-monitor.service", 0o644),
    Asset("external-timer", SYSTEMD_SOURCE / "uten-imp-external-monitor.timer.example", SYSTEMD_DIR / "uten-imp-external-monitor.timer", 0o644),
    Asset("drain-service", SYSTEMD_SOURCE / "uten-imp-monitor-alert-drain.service.example", SYSTEMD_DIR / "uten-imp-monitor-alert-drain.service", 0o644),
    Asset("drain-timer", SYSTEMD_SOURCE / "uten-imp-monitor-alert-drain.timer.example", SYSTEMD_DIR / "uten-imp-monitor-alert-drain.timer", 0o644),
    Asset("failure-service", SYSTEMD_SOURCE / "uten-imp-monitor-failure@.service.example", SYSTEMD_DIR / "uten-imp-monitor-failure@.service", 0o644),
    Asset("runbook", HERE / "README.zh-CN.md", DOC_DIR / "README.zh-CN.md", 0o644),
    Asset(
        "installer-runbook",
        HERE / "EXISTING_HOST_MONITORING_INSTALLER.zh-CN.md",
        DOC_DIR / "EXISTING_HOST_MONITORING_INSTALLER.zh-CN.md",
        0o644,
    ),
)

DIRECTORIES = (
    (LIBEXEC_DIR, 0o500),
    (CONFIG_DIR, 0o755),
    (DOC_DIR, 0o755),
)

UNIT_PROPERTIES = (
    "LoadState",
    "ActiveState",
    "SubState",
    "UnitFileState",
    "FragmentPath",
    "DropInPaths",
    "ExecStart",
)

EXECSTART_NEEDLES = {
    "uten-imp-host-monitor.service": "monitor_runtime_launcher.py host",
    "uten-imp-external-monitor.service": "monitor_runtime_launcher.py external",
    "uten-imp-monitor-alert-drain.service": "monitor_runtime_launcher.py drain",
    "uten-imp-monitor-failure@.service": "monitor_runtime_launcher.py failure %i",
}


def _test_mode() -> bool:
    return os.environ.get("UTEN_MONITOR_INSTALLER_TEST_MODE") == "1"


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _reject_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InstallerError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _strict_canonical_json(raw: bytes, label: str) -> dict[str, Any]:
    if len(raw) > MAX_FILE_BYTES or b"\x00" in raw:
        raise InstallerError(f"{label} exceeds the JSON safety boundary")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_pairs,
            parse_constant=lambda item: (_ for _ in ()).throw(
                InstallerError(f"{label} contains non-finite number {item}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InstallerError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict) or canonical_bytes(value) != raw:
        raise InstallerError(f"{label} is not canonical JSON")
    return value


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


def _require_root() -> None:
    if _test_mode():
        return
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise InstallerError("monitoring installer requires POSIX root")
    if fcntl is None or not hasattr(os, "O_NOFOLLOW"):
        raise InstallerError("monitoring installer requires Linux flock and O_NOFOLLOW")


def _root_parent_chain(path: Path) -> tuple[tuple[str, tuple[int, ...]], ...]:
    captured: list[tuple[str, tuple[int, ...]]] = []
    current = path.parent
    while True:
        details = current.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or (not _test_mode() and (details.st_uid != 0 or details.st_gid != 0))
            or details.st_mode & 0o022
        ):
            raise InstallerError(f"source parent chain is not root controlled: {current}")
        captured.append((str(current), _fingerprint(details)))
        if current == current.parent:
            return tuple(captured)
        current = current.parent


def _capture_source(path: Path, label: str) -> Capture:
    if not path.is_absolute() or Path(os.path.normpath(str(path))) != path:
        raise InstallerError(f"{label} path is not canonical absolute")
    try:
        before = path.lstat()
    except OSError as exc:
        raise InstallerError(f"{label} is unavailable: {path}") from exc
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or (not _test_mode() and (before.st_uid != 0 or before.st_gid != 0))
        or before.st_mode & 0o022
        or before.st_nlink != 1
        or before.st_size < 1
        or before.st_size > MAX_FILE_BYTES
    ):
        raise InstallerError(f"{label} must be one root-controlled regular file")
    chain = _root_parent_chain(path)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    elif not _test_mode():
        raise InstallerError("stable source capture requires O_NOFOLLOW")
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if _fingerprint(opened) != _fingerprint(before):
            raise InstallerError(f"{label} changed before descriptor capture")
        payload = bytearray()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
            if len(payload) > MAX_FILE_BYTES:
                raise InstallerError(f"{label} exceeded the size limit")
        final = os.fstat(descriptor)
        live = path.lstat()
        if (
            _fingerprint(final) != _fingerprint(opened)
            or _fingerprint(live) != _fingerprint(opened)
            or _root_parent_chain(path) != chain
            or len(payload) != opened.st_size
        ):
            raise InstallerError(f"{label} changed during stable capture")
        return Capture(path, bytes(payload), _fingerprint(opened), chain)
    finally:
        os.close(descriptor)


def _verify_capture_live(capture: Capture, label: str) -> None:
    try:
        live = capture.path.lstat()
    except OSError as exc:
        raise InstallerError(f"{label} disappeared after capture") from exc
    if _fingerprint(live) != capture.fingerprint or _root_parent_chain(capture.path) != capture.parent_chain:
        raise InstallerError(f"{label} path or parent chain changed after capture")


def _safe_target_observation(path: Path) -> dict[str, Any]:
    try:
        details = path.lstat()
    except FileNotFoundError:
        return {"state": "absent"}
    except OSError as exc:
        raise InstallerError(f"target cannot be inspected: {path}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or (not _test_mode() and (details.st_uid != 0 or details.st_gid != 0))
        or details.st_mode & 0o022
        or details.st_nlink != 1
        or details.st_size > MAX_FILE_BYTES
    ):
        raise InstallerError(f"target preimage is unknown or unsafe: {path}")
    capture = _capture_source(path, "target preimage")
    return {
        "state": "file",
        "sha256": sha256_bytes(capture.payload),
        "size": len(capture.payload),
        "uid": details.st_uid,
        "gid": details.st_gid,
        "mode": stat.S_IMODE(details.st_mode),
        "nlink": details.st_nlink,
    }


def _directory_observation(path: Path, mode: int) -> dict[str, Any]:
    try:
        details = path.lstat()
    except FileNotFoundError:
        parent = path.parent
        parent_details = parent.lstat()
        if (
            not stat.S_ISDIR(parent_details.st_mode)
            or stat.S_ISLNK(parent_details.st_mode)
            or (not _test_mode() and (parent_details.st_uid != 0 or parent_details.st_gid != 0))
            or parent_details.st_mode & 0o022
        ):
            raise InstallerError(f"target parent is not root controlled: {parent}")
        return {"state": "absent"}
    if (
        not stat.S_ISDIR(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or (not _test_mode() and (details.st_uid != 0 or details.st_gid != 0))
        or stat.S_IMODE(details.st_mode) != mode
    ):
        raise InstallerError(f"managed directory is not exact: {path}")
    return {"state": "directory", "uid": details.st_uid, "gid": details.st_gid, "mode": mode}


def _run_command(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=COMMAND_TIMEOUT,
            env=SAFE_ENVIRONMENT,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InstallerError(f"fixed command failed: {command[0]}") from exc


Runner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


def _parse_properties(raw: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in raw.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in UNIT_PROPERTIES or key in values:
            raise InstallerError("systemd property output is malformed")
        values[key] = value
    if set(values) != set(UNIT_PROPERTIES):
        raise InstallerError("systemd property output is incomplete")
    return values


def _unit_observation(unit: str, runner: Runner) -> dict[str, str]:
    if unit not in MANAGED_UNITS:
        raise InstallerError("unit is outside the fixed monitoring allowlist")
    command = ["/usr/bin/systemctl", "show", unit]
    command.extend(f"--property={name}" for name in UNIT_PROPERTIES)
    result = runner(command)
    if result.returncode not in (0, 1):
        raise InstallerError(f"systemctl show failed for {unit}")
    return _parse_properties(result.stdout)


def _managed_jobs(runner: Runner) -> list[str]:
    result = runner(["/usr/bin/systemctl", "list-jobs", "--no-legend", "--plain", "--no-pager"])
    if result.returncode != 0:
        raise InstallerError("systemctl could not enumerate jobs")
    jobs: list[str] = []
    for line in result.stdout.splitlines():
        columns = line.split()
        if len(columns) >= 2 and (
            columns[1] in MANAGED_UNITS
            or columns[1].startswith("uten-imp-monitor-failure@")
        ):
            jobs.append(columns[1])
    return sorted(set(jobs))


def _failure_instances(runner: Runner) -> list[dict[str, str]]:
    result = runner(
        [
            "/usr/bin/systemctl",
            "list-units",
            "--all",
            "--plain",
            "--no-legend",
            "--no-pager",
            "uten-imp-monitor-failure@*.service",
        ]
    )
    if result.returncode != 0:
        raise InstallerError("systemctl could not enumerate monitor failure instances")
    instances: list[dict[str, str]] = []
    for raw in result.stdout.splitlines():
        columns = raw.split(None, 4)
        if len(columns) < 4 or not columns[0].startswith("uten-imp-monitor-failure@"):
            raise InstallerError("monitor failure instance listing is malformed")
        instances.append(
            {
                "unit": columns[0],
                "load": columns[1],
                "active": columns[2],
                "sub": columns[3],
            }
        )
    return sorted(instances, key=lambda item: item["unit"])


def _require_quiescent(
    units: Mapping[str, Mapping[str, str]],
    jobs: Sequence[str],
    failure_instances: Sequence[Mapping[str, str]],
) -> None:
    if set(units) != set(MANAGED_UNITS) or jobs or failure_instances:
        raise InstallerError(
            "monitor unit state is incomplete or has an active job/failure instance"
        )
    for unit, value in units.items():
        if value.get("ActiveState") != "inactive":
            raise InstallerError(f"monitor unit must be inactive: {unit}")
        state = value.get("UnitFileState", "")
        if unit in TIMER_UNITS and state not in {"disabled", "not-found", ""}:
            raise InstallerError(f"monitor timer must be disabled: {unit}")
        if unit in SERVICE_UNITS and state in {"enabled", "enabled-runtime", "linked", "linked-runtime", "alias"}:
            raise InstallerError(f"monitor service unexpectedly has boot enablement: {unit}")
        if value.get("DropInPaths"):
            raise InstallerError(f"monitor unit has an unplanned loaded drop-in: {unit}")


def _sender_observation() -> dict[str, Any]:
    try:
        details = FIXED_ALERT_SENDER.lstat()
    except FileNotFoundError:
        return {"state": "absent", "drainMayBeCommissioned": False}
    if (
        not stat.S_ISREG(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or (not _test_mode() and details.st_uid != 0)
        or details.st_mode & 0o022
        or not details.st_mode & 0o100
        or details.st_nlink != 1
    ):
        raise InstallerError("fixed alert sender exists but is not a trusted root executable")
    capture = _capture_source(FIXED_ALERT_SENDER, "fixed alert sender")
    return {
        "state": "file",
        "sha256": sha256_bytes(capture.payload),
        "mode": stat.S_IMODE(details.st_mode),
        "uid": details.st_uid,
        "gid": details.st_gid,
        "nlink": details.st_nlink,
        "drainMayBeCommissioned": True,
    }


def _reject_example_source(path: Path, label: str) -> None:
    lower = str(path).lower()
    if "example" in lower or path.suffix.lower() in {".sample", ".template"}:
        raise InstallerError(f"{label} must be a现场 reviewed canonical file, not an example")


def _reject_placeholder_values(value: Any, label: str) -> None:
    if isinstance(value, str):
        lowered = value.lower()
        markers = ("example.invalid", "replace_me", "replace-me", "placeholder", "changeme")
        if any(marker in lowered for marker in markers):
            raise InstallerError(f"{label} contains a placeholder value")
    elif isinstance(value, dict):
        for item in value.values():
            _reject_placeholder_values(item, label)
    elif isinstance(value, list):
        for item in value:
            _reject_placeholder_values(item, label)


def _validate_policy_payloads(inputs: Sequence[PolicyInput], captures: Mapping[str, Capture]) -> None:
    by_name = {item.name: item for item in inputs}
    if set(by_name) != {"host-policy", "external-policy", "hardware-authority"}:
        raise InstallerError("all three canonical policy/authority inputs are required")
    parsed: dict[str, dict[str, Any]] = {}
    for name, item in by_name.items():
        _reject_example_source(item.source, name)
        capture = captures[name]
        actual = sha256_bytes(capture.payload)
        if not SHA256_RE.fullmatch(item.expected_sha256) or actual != item.expected_sha256:
            raise InstallerError(f"{name} digest differs from the explicit approved SHA-256")
        parsed[name] = _strict_canonical_json(capture.payload, name)
        _reject_placeholder_values(parsed[name], name)
    host = parsed["host-policy"]
    external = parsed["external-policy"]
    hardware = parsed["hardware-authority"]
    if host.get("format") != "uten-imp-host-monitor-policy-v1" or set(host) != {
        "format", "journald", "ntp", "hardware", "filesystems", "certificates", "units", "postgres"
    }:
        raise InstallerError("host policy top-level schema differs")
    if external.get("format") != "uten-imp-external-monitor-policy-v1" or set(external) != {"format", "checks"}:
        raise InstallerError("external policy top-level schema differs")
    if hardware.get("format") not in {
        "uten-imp-monitor-storage-hardware-authority-v1",
        "uten-imp-monitor-storage-hardware-authority-v2",
    }:
        raise InstallerError("hardware authority format differs")
    hardware_binding = host.get("hardware")
    if (
        not isinstance(hardware_binding, dict)
        or set(hardware_binding) != {"mode", "authorityPath", "authoritySha256"}
        or hardware_binding.get("mode") not in {"local-md-smart", "local-lvm-nvme"}
        or hardware_binding.get("authorityPath") != str(HARDWARE_AUTHORITY_TARGET)
    ):
        raise InstallerError("host policy does not bind the fixed installed hardware authority path")
    if hardware_binding.get("authoritySha256") != by_name["hardware-authority"].expected_sha256:
        raise InstallerError("host policy hardware authority digest differs from the approved input")
    journald = host.get("journald")
    if (
        not isinstance(journald, dict)
        or journald.get("dropInPath") != "/etc/systemd/journald.conf.d/60-uten-imp.conf"
        or not SHA256_RE.fullmatch(str(journald.get("dropInSha256", "")))
    ):
        raise InstallerError("host policy journald binding is incomplete")
    if not isinstance(host.get("ntp"), dict) or not host["ntp"]:
        raise InstallerError("host policy NTP authority is empty")
    for key in ("filesystems", "certificates", "units"):
        if not isinstance(host.get(key), list) or not host[key]:
            raise InstallerError(f"host policy {key} inventory is empty")
    if not isinstance(host.get("postgres"), dict) or not host["postgres"]:
        raise InstallerError("host policy PostgreSQL contract is empty")
    if (
        hardware.get("erpStorageAuthorityPath") != "/etc/uten-imp/storage-authority.json"
        or not SHA256_RE.fullmatch(str(hardware.get("erpStorageAuthoritySha256", "")))
        or not isinstance(hardware.get("smart"), list)
        or not hardware["smart"]
    ):
        raise InstallerError("hardware authority lacks live ERP storage/SMART binding")
    if not isinstance(external.get("checks"), list) or not external["checks"]:
        raise InstallerError("external policy contains no real check")
    for check in external["checks"]:
        url = check.get("url") if isinstance(check, dict) else None
        if (
            not isinstance(url, str)
            or not re.fullmatch(r"https://[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?(?::443)?/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*", url)
            or "?" in url
            or "#" in url
        ):
            raise InstallerError("external policy contains a non-canonical HTTPS check")


def _policy_assets(inputs: Sequence[PolicyInput]) -> tuple[Asset, ...]:
    return tuple(Asset(item.name, item.source, item.target, item.mode) for item in inputs)


def _all_assets(inputs: Sequence[PolicyInput], static_assets: Sequence[Asset]) -> tuple[Asset, ...]:
    result = (*static_assets, *_policy_assets(inputs))
    names = [item.name for item in result]
    sources = [item.source for item in result]
    targets = [item.target for item in result]
    if (
        len(set(names)) != len(names)
        or len(set(sources)) != len(sources)
        or len(set(targets)) != len(targets)
        or set(sources).intersection(targets)
    ):
        raise InstallerError("asset names/sources/targets must be unique and non-overlapping")
    return tuple(result)


def _capture_assets(
    inputs: Sequence[PolicyInput], static_assets: Sequence[Asset]
) -> tuple[tuple[Asset, ...], dict[str, Capture]]:
    assets = _all_assets(inputs, static_assets)
    captures = {
        asset.name: _capture_source(asset.source, f"reviewed source {asset.name}")
        for asset in assets
    }
    _validate_policy_payloads(
        inputs,
        {item.name: captures[item.name] for item in inputs},
    )
    return assets, captures


def _asset_source_inventory(
    assets: Sequence[Asset], captures: Mapping[str, Capture]
) -> list[dict[str, Any]]:
    return [
        {
            "name": asset.name,
            "source": str(asset.source),
            "sourceSha256": sha256_bytes(captures[asset.name].payload),
            "target": str(asset.target),
            "targetMode": asset.mode,
        }
        for asset in assets
    ]


def _dropin_inventory() -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for unit in MANAGED_UNITS:
        directory = SYSTEMD_DIR / f"{unit}.d"
        if not os.path.lexists(directory):
            result[unit] = []
            continue
        details = directory.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or (not _test_mode() and (details.st_uid != 0 or details.st_gid != 0))
            or details.st_mode & 0o022
        ):
            raise InstallerError(f"unit drop-in directory is unsafe: {directory}")
        children = sorted(item.name for item in directory.iterdir())
        if children:
            raise InstallerError(f"unknown monitor unit drop-in preimage is forbidden: {unit}")
        result[unit] = []
    return result


def _managed_directory_inventory(
    assets: Sequence[Asset], inputs: Sequence[PolicyInput]
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for path, mode in DIRECTORIES:
        result[str(path)] = {
            "desired": {"uid": 0, "gid": 0, "mode": mode},
            "observed": _directory_observation(path, mode),
        }
    expected_children = {
        str(LIBEXEC_DIR): {
            asset.target.name for asset in assets if asset.target.parent == LIBEXEC_DIR
        },
        str(CONFIG_DIR): {item.target.name for item in inputs},
        str(DOC_DIR): {
            asset.target.name for asset in assets if asset.target.parent == DOC_DIR
        },
    }
    for path_text, children in expected_children.items():
        path = Path(path_text)
        if path.is_dir() and not path.is_symlink():
            actual = {item.name for item in path.iterdir()}
            if actual - children:
                raise InstallerError(f"managed directory contains an unknown object: {path}")
        result[path_text]["allowedChildren"] = sorted(children)
    return result


def build_assessment(
    inputs: Sequence[PolicyInput],
    *,
    static_assets: Sequence[Asset] = STATIC_ASSETS,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], dict[str, Capture]]:
    assets, captures = _capture_assets(inputs, static_assets)
    targets = {str(asset.target): _safe_target_observation(asset.target) for asset in assets}
    units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
    jobs = _managed_jobs(runner)
    failures = _failure_instances(runner)
    _require_quiescent(units, jobs, failures)
    assessment = {
        "sources": _asset_source_inventory(assets, captures),
        "targets": targets,
        "directories": _managed_directory_inventory(assets, inputs),
        "dropins": _dropin_inventory(),
        "systemd": {"units": units, "jobs": jobs, "failureInstances": failures},
        "alertSender": _sender_observation(),
        "timerCommissioningAllowed": False,
        "externalProbeIndependentFailureDomainAccepted": False,
        "providerReceiptAccepted": False,
    }
    return assessment, captures


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _safe_directory(path: Path, mode: int | None = None) -> os.stat_result:
    try:
        details = path.lstat()
    except OSError as exc:
        raise InstallerError(f"required directory cannot be inspected: {path}") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or stat.S_ISLNK(details.st_mode)
        or (not _test_mode() and (details.st_uid != 0 or details.st_gid != 0))
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        raise InstallerError(f"required directory is not root controlled: {path}")
    return details


def _rename_noreplace(source: Path, destination: Path) -> None:
    if os.name != "posix":
        if _test_mode() and not os.path.lexists(destination):
            os.replace(source, destination)
            return
        raise InstallerError("atomic no-replace requires Linux renameat2")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        function = libc.renameat2
    except (AttributeError, OSError) as exc:
        raise InstallerError("renameat2 is unavailable") from exc
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    if result == 0:
        return
    number = ctypes.get_errno()
    if number == errno.EEXIST:
        raise FileExistsError(number, os.strerror(number), destination)
    raise InstallerError(f"atomic no-replace failed: {destination}")


def _atomic_directory(path: Path, mode: int) -> bool:
    if os.path.lexists(path):
        _safe_directory(path, mode)
        return False
    _safe_directory(path.parent)
    temporary = Path(tempfile.mkdtemp(prefix=f".{path.name}.install.", dir=path.parent))
    try:
        if not _test_mode():
            os.chown(temporary, 0, 0)
        temporary.chmod(mode)
        _fsync_directory(temporary)
        try:
            _rename_noreplace(temporary, path)
        except FileExistsError:
            _safe_directory(path, mode)
            return False
        _fsync_directory(path.parent)
        return True
    finally:
        if os.path.lexists(temporary):
            temporary.rmdir()


def _ensure_state_layout() -> None:
    # The monitoring state and journal are intentionally never removed by
    # rollback.  They retain installation/recovery evidence and later alert
    # history even when every managed runtime/config/unit preimage is restored.
    for path in (STATE_ROOT, JOURNAL_ROOT, INSTALLER_ROOT, PLAN_HISTORY, TRANSACTIONS, ROLLBACK_RECEIPTS):
        _atomic_directory(path, 0o700)


def _atomic_write(
    path: Path,
    payload: bytes,
    *,
    mode: int,
    replace: bool,
    uid: int = 0,
    gid: int = 0,
) -> None:
    _safe_directory(path.parent)
    original_parent_mode: int | None = None
    if _test_mode():
        parent_mode = stat.S_IMODE(path.parent.stat().st_mode)
        if not parent_mode & 0o200:
            original_parent_mode = parent_mode
            path.parent.chmod(parent_mode | 0o200)
    temporary = path.parent / f".{path.name}.install.{os.getpid()}.{os.urandom(8).hex()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, mode)
        if not _test_mode():
            os.fchown(descriptor, uid, gid)
        os.fchmod(descriptor, mode)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise InstallerError(f"short write: {path}")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        if replace:
            os.replace(temporary, path)
        else:
            try:
                _rename_noreplace(temporary, path)
            except FileExistsError as exc:
                raise InstallerError(f"refusing to overwrite evidence: {path}") from exc
        _fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if os.path.lexists(temporary):
            temporary.unlink()
        if original_parent_mode is not None:
            path.parent.chmod(original_parent_mode)


def _durable_unlink(path: Path) -> None:
    if not os.path.lexists(path):
        return
    details = path.lstat()
    if not stat.S_ISREG(details.st_mode) or stat.S_ISLNK(details.st_mode) or details.st_nlink != 1:
        raise InstallerError(f"refusing to unlink unsafe evidence: {path}")
    path.unlink()
    _fsync_directory(path.parent)


def _load_root_json(path: Path, maximum: int, label: str) -> tuple[dict[str, Any], bytes]:
    capture = _capture_source(path, label)
    if len(capture.payload) > maximum:
        raise InstallerError(f"{label} exceeds size limit")
    details = path.lstat()
    if not _test_mode() and (details.st_uid != 0 or details.st_gid != 0 or stat.S_IMODE(details.st_mode) != 0o600):
        raise InstallerError(f"{label} must be root:root 0600")
    return _strict_canonical_json(capture.payload, label), capture.payload


class InstallerLock:
    def __init__(self) -> None:
        self.descriptor = -1

    def __enter__(self) -> "InstallerLock":
        _ensure_state_layout()
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self.descriptor = os.open(LOCK_PATH, flags, 0o600)
        if not _test_mode():
            os.fchown(self.descriptor, 0, 0)
        os.fchmod(self.descriptor, 0o600)
        details = os.fstat(self.descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1:
            raise InstallerError("installer lock is unsafe")
        if fcntl is not None:
            try:
                fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise InstallerError("another monitoring installer operation is running") from exc
        elif not _test_mode():
            raise InstallerError("installer lock requires flock")
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            if fcntl is not None:
                fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


def _require_no_transaction() -> None:
    if os.path.lexists(ACTIVE_TRANSACTION):
        raise InstallerError("an interrupted monitoring transaction requires resume or rollback")
    if os.path.lexists(UNCOMMISSIONED_RECEIPT):
        raise InstallerError("an uncommissioned monitoring installation already exists")
    if os.path.lexists(COMMISSIONED_MARKER):
        raise InstallerError("monitoring is already marked commissioned")


def assess(
    inputs: Sequence[PolicyInput],
    *,
    static_assets: Sequence[Asset] = STATIC_ASSETS,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if os.path.lexists(ACTIVE_TRANSACTION) or os.path.lexists(UNCOMMISSIONED_RECEIPT):
        raise InstallerError("existing transaction evidence blocks a new assessment")
    assessment, _ = build_assessment(inputs, static_assets=static_assets, runner=runner)
    digest = sha256_bytes(canonical_bytes(assessment))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": ASSESSMENT_KIND,
        "assessmentSha256": digest,
        "assessment": assessment,
    }, digest


def _archive_plan() -> None:
    if not os.path.lexists(PLAN_PATH):
        return
    _, raw = _load_root_json(PLAN_PATH, MAX_PLAN_BYTES, "existing install plan")
    destination = PLAN_HISTORY / f"{sha256_bytes(raw)}.json"
    if os.path.lexists(destination):
        _, existing = _load_root_json(destination, MAX_PLAN_BYTES, "archived install plan")
        if existing != raw:
            raise InstallerError("archived plan digest collision")
        return
    _atomic_write(destination, raw, mode=0o600, replace=False)


def record_plan(
    inputs: Sequence[PolicyInput],
    *,
    expected_assessment_sha256: str,
    confirmation: str,
    static_assets: Sequence[Asset] = STATIC_ASSETS,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if not SHA256_RE.fullmatch(expected_assessment_sha256):
        raise InstallerError("expected assessment SHA-256 is malformed")
    if confirmation != RECORD_CONFIRMATION:
        raise InstallerError(f"confirmation must exactly equal: {RECORD_CONFIRMATION}")
    with InstallerLock():
        _require_no_transaction()
        assessment, captures = build_assessment(inputs, static_assets=static_assets, runner=runner)
        actual = sha256_bytes(canonical_bytes(assessment))
        if actual != expected_assessment_sha256:
            raise InstallerError("assessment changed after approval")
        for name, capture in captures.items():
            _verify_capture_live(capture, f"reviewed source {name}")
        plan = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": PLAN_KIND,
            "recordedAtUtc": _utc_now(),
            "assessmentSha256": actual,
            "assessment": assessment,
        }
        raw = canonical_bytes(plan)
        _archive_plan()
        _atomic_write(PLAN_PATH, raw, mode=0o600, replace=True)
        return plan, sha256_bytes(raw)


def _validate_plan(value: Mapping[str, Any], raw: bytes, expected_sha256: str) -> dict[str, Any]:
    if not SHA256_RE.fullmatch(expected_sha256) or sha256_bytes(raw) != expected_sha256:
        raise InstallerError("fixed plan SHA-256 differs")
    if set(value) != {"schemaVersion", "kind", "recordedAtUtc", "assessmentSha256", "assessment"}:
        raise InstallerError("plan schema differs")
    if value.get("schemaVersion") != SCHEMA_VERSION or value.get("kind") != PLAN_KIND:
        raise InstallerError("plan kind/version differs")
    if not isinstance(value.get("recordedAtUtc"), str) or not UTC_RE.fullmatch(str(value["recordedAtUtc"])):
        raise InstallerError("plan timestamp is malformed")
    assessment = value.get("assessment")
    if not isinstance(assessment, dict) or sha256_bytes(canonical_bytes(assessment)) != value.get("assessmentSha256"):
        raise InstallerError("plan assessment binding differs")
    return assessment


def _transaction_path(plan_sha256: str) -> Path:
    if not SHA256_RE.fullmatch(plan_sha256):
        raise InstallerError("transaction plan SHA-256 is malformed")
    return TRANSACTIONS / plan_sha256


def _current_matches(path: Path, expected: Mapping[str, Any]) -> bool:
    try:
        observed = _safe_target_observation(path)
    except InstallerError:
        return False
    return observed == dict(expected)


def _preimage_record(
    asset: Asset,
    original: Mapping[str, Any],
    mutation: Mapping[str, Any],
    destination: Path,
) -> dict[str, Any]:
    if original.get("state") == "absent":
        if os.path.lexists(asset.target):
            raise InstallerError(f"target appeared after assessment: {asset.target}")
        return {
            "name": asset.name,
            "path": str(asset.target),
            "original": dict(original),
            "preimage": None,
            "mutation": dict(mutation),
        }
    if original.get("state") != "file" or not _current_matches(asset.target, original):
        raise InstallerError(f"target changed after assessment: {asset.target}")
    capture = _capture_source(asset.target, f"preimage {asset.name}")
    digest = sha256_bytes(capture.payload)
    if digest != original.get("sha256"):
        raise InstallerError(f"target preimage digest changed: {asset.target}")
    _atomic_write(destination, capture.payload, mode=0o600, replace=False)
    return {
        "name": asset.name,
        "path": str(asset.target),
        "original": dict(original),
        "preimage": str(destination),
        "preimageSha256": digest,
        "mutation": dict(mutation),
    }


def _update_transaction(transaction: Path, record: Mapping[str, Any]) -> None:
    raw = canonical_bytes(record)
    _atomic_write(transaction / "transaction.json", raw, mode=0o600, replace=True)
    _atomic_write(ACTIVE_TRANSACTION, raw, mode=0o600, replace=True)


def _prepare_transaction(
    plan_sha256: str,
    assessment: Mapping[str, Any],
    assets: Sequence[Asset],
) -> tuple[Path, dict[str, Any]]:
    transaction = _transaction_path(plan_sha256)
    if os.path.lexists(transaction):
        raise InstallerError("transaction directory already exists for this plan")
    bootstrap = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": TRANSACTION_KIND,
        "planSha256": plan_sha256,
        "transactionPath": str(transaction),
        "phase": "preparing-preimages",
        "createdAtUtc": _utc_now(),
        "files": [],
        "createdDirectories": sorted(
            path
            for path, value in assessment.get("directories", {}).items()
            if isinstance(value, dict)
            and isinstance(value.get("observed"), dict)
            and value["observed"].get("state") == "absent"
        ),
        "originalSystemd": assessment.get("systemd"),
        "installedSystemd": None,
    }
    _atomic_write(ACTIVE_TRANSACTION, canonical_bytes(bootstrap), mode=0o600, replace=False)
    _atomic_directory(transaction, 0o700)
    preimages = transaction / "preimages"
    _atomic_directory(preimages, 0o700)
    planned_targets = assessment.get("targets")
    planned_sources = assessment.get("sources")
    if not isinstance(planned_targets, dict) or not isinstance(planned_sources, list):
        raise InstallerError("plan target/source inventory is malformed")
    sources = {item.get("name"): item for item in planned_sources if isinstance(item, dict)}
    records: list[dict[str, Any]] = []
    for index, asset in enumerate(assets):
        original = planned_targets.get(str(asset.target))
        source = sources.get(asset.name)
        if not isinstance(original, dict) or not isinstance(source, dict):
            raise InstallerError(f"plan lacks asset binding: {asset.name}")
        mutation = {
            "state": "file",
            "sha256": source.get("sourceSha256"),
            "size": None,
            "uid": 0,
            "gid": 0,
            "mode": asset.mode,
            "nlink": 1,
        }
        records.append(
            _preimage_record(
                asset,
                original,
                mutation,
                preimages / f"{index:03d}.bin",
            )
        )
    record = {
        **bootstrap,
        "phase": "prepared",
        "files": records,
    }
    _update_transaction(transaction, record)
    return transaction, record


def _expected_assets_from_plan(
    assessment: Mapping[str, Any],
    inputs: Sequence[PolicyInput],
    static_assets: Sequence[Asset],
) -> tuple[Asset, ...]:
    assets = _all_assets(inputs, static_assets)
    sources = assessment.get("sources")
    if not isinstance(sources, list):
        raise InstallerError("plan sources are malformed")
    expected = [
        {
            "name": asset.name,
            "source": str(asset.source),
            "target": str(asset.target),
            "targetMode": asset.mode,
        }
        for asset in assets
    ]
    actual = [
        {key: item.get(key) for key in ("name", "source", "target", "targetMode")}
        for item in sources
        if isinstance(item, dict)
    ]
    if actual != expected:
        raise InstallerError("CLI policy paths or fixed assets differ from the recorded plan")
    return assets


def _capture_payloads_for_plan(
    assessment: Mapping[str, Any],
    inputs: Sequence[PolicyInput],
    static_assets: Sequence[Asset],
) -> tuple[tuple[Asset, ...], dict[str, Capture]]:
    assets = _expected_assets_from_plan(assessment, inputs, static_assets)
    _, captures = _capture_assets(inputs, static_assets)
    planned = {
        item["name"]: item
        for item in assessment["sources"]
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    for asset in assets:
        value = planned.get(asset.name)
        if not isinstance(value, dict) or value.get("sourceSha256") != sha256_bytes(captures[asset.name].payload):
            raise InstallerError(f"source bytes drifted after plan recording: {asset.name}")
    return assets, captures


def _create_managed_directories(assessment: Mapping[str, Any]) -> list[str]:
    planned = assessment.get("directories")
    if not isinstance(planned, dict):
        raise InstallerError("plan directory inventory is malformed")
    created: list[str] = []
    for path, mode in DIRECTORIES:
        value = planned.get(str(path))
        if not isinstance(value, dict) or value.get("desired") != {"uid": 0, "gid": 0, "mode": mode}:
            raise InstallerError(f"plan directory desired state differs: {path}")
        observed = value.get("observed")
        current = _directory_observation(path, mode)
        if observed == {"state": "absent"}:
            # If power was lost after the atomic directory rename but before
            # the phase record, the exact root-only directory is the only
            # accepted resume state and remains in the rollback inventory.
            if current == {"state": "absent"}:
                _atomic_directory(path, mode)
            elif current.get("state") != "directory":
                raise InstallerError(f"managed directory drifted after assessment: {path}")
            created.append(str(path))
        elif current != observed:
            raise InstallerError(f"managed directory drifted after assessment: {path}")
    return sorted(created)


def _desired_observation(record: Mapping[str, Any], payload: bytes) -> dict[str, Any]:
    mutation = record.get("mutation")
    if not isinstance(mutation, dict):
        raise InstallerError("transaction mutation is malformed")
    return {
        "state": "file",
        "sha256": sha256_bytes(payload),
        "size": len(payload),
        "uid": 0 if not _test_mode() else os.getuid() if hasattr(os, "getuid") else 0,
        "gid": 0 if not _test_mode() else os.getgid() if hasattr(os, "getgid") else 0,
        "mode": mutation["mode"],
        "nlink": 1,
    }


def _install_record(record: Mapping[str, Any], asset: Asset, payload: bytes) -> None:
    path = Path(str(record.get("path", "")))
    if path != asset.target or record.get("name") != asset.name:
        raise InstallerError("transaction asset identity differs")
    original = record.get("original")
    if not isinstance(original, dict):
        raise InstallerError("transaction original target is malformed")
    desired = _desired_observation(record, payload)
    if _current_matches(path, desired):
        return
    if not _current_matches(path, original):
        raise InstallerError(f"target is neither recorded preimage nor planned bytes: {path}")
    _atomic_write(
        path,
        payload,
        mode=asset.mode,
        replace=original.get("state") == "file",
    )
    if not _current_matches(path, desired):
        raise InstallerError(f"installed target failed byte/metadata verification: {path}")


def _daemon_reload(runner: Runner) -> None:
    result = runner(["/usr/bin/systemctl", "daemon-reload"])
    if result.returncode != 0:
        raise InstallerError("systemctl daemon-reload failed")


def _verify_loaded_contract(
    assets: Sequence[Asset],
    captures: Mapping[str, Capture],
    expected_sender: Mapping[str, Any],
    runner: Runner,
) -> dict[str, Any]:
    unit_assets = {
        asset.target.name: asset
        for asset in assets
        if asset.target.parent == SYSTEMD_DIR
    }
    if set(unit_assets) != set(MANAGED_UNITS):
        raise InstallerError("installed unit asset inventory is incomplete")
    result = runner(["/usr/bin/systemd-analyze", "verify", *[str(item.target) for item in unit_assets.values()]])
    if result.returncode != 0:
        raise InstallerError("systemd-analyze verify rejected monitoring units")
    units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
    jobs = _managed_jobs(runner)
    failures = _failure_instances(runner)
    _require_quiescent(units, jobs, failures)
    for unit, value in units.items():
        if value.get("LoadState") != "loaded" or value.get("FragmentPath") != str(unit_assets[unit].target):
            raise InstallerError(f"systemd did not load the exact installed unit: {unit}")
        if unit in EXECSTART_NEEDLES and EXECSTART_NEEDLES[unit] not in value.get("ExecStart", ""):
            raise InstallerError(f"loaded ExecStart bypasses the reviewed runtime launcher: {unit}")
    installed_targets: dict[str, Any] = {}
    for asset in assets:
        observed = _safe_target_observation(asset.target)
        if (
            observed.get("state") != "file"
            or observed.get("sha256") != sha256_bytes(captures[asset.name].payload)
            or observed.get("mode") != asset.mode
            or observed.get("nlink") != 1
        ):
            raise InstallerError(f"installed target drifted before loaded verification: {asset.target}")
        installed_targets[str(asset.target)] = observed
    sender = _sender_observation()
    if sender != dict(expected_sender):
        raise InstallerError("alert sender drifted after plan recording")
    if sender["state"] == "absent" and units["uten-imp-monitor-alert-drain.timer"]["UnitFileState"] != "disabled":
        raise InstallerError("alert sender is absent but the drain timer is not disabled")
    return {
        "units": units,
        "jobs": jobs,
        "failureInstances": failures,
        "targets": installed_targets,
        "alertSender": sender,
        "timersEnabled": False,
        "timersActive": False,
    }


def _transition(transaction: Path, record: dict[str, Any], phase: str, **values: Any) -> None:
    record["phase"] = phase
    record.update(values)
    _update_transaction(transaction, record)


def _complete_apply(
    *,
    transaction: Path,
    record: dict[str, Any],
    assessment: Mapping[str, Any],
    assets: Sequence[Asset],
    captures: Mapping[str, Capture],
    runner: Runner,
    fault_hook: Callable[[str], None],
) -> tuple[dict[str, Any], str]:
    if record.get("phase") == "prepared":
        created = _create_managed_directories(assessment)
        _transition(transaction, record, "directories-ready", createdDirectories=created)
        fault_hook("directories-ready")
    elif record.get("phase") == "preparing-preimages":
        raise InstallerError("preimage preparation did not reach a resumable boundary")

    files = record.get("files")
    if not isinstance(files, list) or len(files) != len(assets):
        raise InstallerError("transaction file inventory is incomplete")
    by_name = {asset.name: asset for asset in assets}
    for index, file_record in enumerate(files):
        if not isinstance(file_record, dict) or file_record.get("name") not in by_name:
            raise InstallerError("transaction file entry is malformed")
        name = str(file_record["name"])
        _install_record(file_record, by_name[name], captures[name].payload)
        _transition(transaction, record, f"file-{index + 1:03d}-installed")
        fault_hook(f"file-{index + 1:03d}-installed")

    _transition(transaction, record, "daemon-reload-pending")
    fault_hook("daemon-reload-pending")
    _daemon_reload(runner)
    _transition(transaction, record, "daemon-reloaded")
    fault_hook("daemon-reloaded")
    loaded = _verify_loaded_contract(
        assets,
        captures,
        assessment["alertSender"],
        runner,
    )
    _transition(transaction, record, "loaded-verified", installedSystemd=loaded)
    fault_hook("loaded-verified")
    if os.path.lexists(UNCOMMISSIONED_RECEIPT):
        receipt, receipt_raw = _load_root_json(
            UNCOMMISSIONED_RECEIPT, MAX_PLAN_BYTES, "uncommissioned receipt"
        )
        expected_stable = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": RECEIPT_KIND,
            "commissioned": False,
            "planSha256": record["planSha256"],
            "transactionPath": str(transaction),
            "installedSystemd": loaded,
            "timerCommissioningAllowed": False,
            "externalProbeIndependentFailureDomainAccepted": False,
            "providerReceiptAccepted": False,
        }
        if {key: receipt.get(key) for key in expected_stable} != expected_stable:
            raise InstallerError("existing uncommissioned receipt differs")
    else:
        receipt = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": RECEIPT_KIND,
            "commissioned": False,
            "appliedAtUtc": _utc_now(),
            "planSha256": record["planSha256"],
            "transactionPath": str(transaction),
            "installedSystemd": loaded,
            "timerCommissioningAllowed": False,
            "externalProbeIndependentFailureDomainAccepted": False,
            "providerReceiptAccepted": False,
        }
        receipt_raw = canonical_bytes(receipt)
        _atomic_write(UNCOMMISSIONED_RECEIPT, receipt_raw, mode=0o600, replace=False)
    _transition(transaction, record, "committed-uncommissioned", receiptSha256=sha256_bytes(receipt_raw))
    _durable_unlink(ACTIVE_TRANSACTION)
    return receipt, sha256_bytes(receipt_raw)


def apply_plan(
    inputs: Sequence[PolicyInput],
    *,
    plan_path: Path,
    expected_plan_sha256: str,
    confirmation: str,
    static_assets: Sequence[Asset] = STATIC_ASSETS,
    runner: Runner = _run_command,
    fault_hook: Callable[[str], None] | None = None,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if plan_path != PLAN_PATH:
        raise InstallerError(f"plan path must exactly equal: {PLAN_PATH}")
    if confirmation != APPLY_CONFIRMATION:
        raise InstallerError(f"confirmation must exactly equal: {APPLY_CONFIRMATION}")
    hook = fault_hook or (lambda _phase: None)
    with InstallerLock():
        _require_no_transaction()
        plan, raw = _load_root_json(PLAN_PATH, MAX_PLAN_BYTES, "fixed install plan")
        assessment = _validate_plan(plan, raw, expected_plan_sha256)
        current, _ = build_assessment(inputs, static_assets=static_assets, runner=runner)
        if current != assessment:
            raise InstallerError("host, target or source assessment changed after plan recording")
        assets, captures = _capture_payloads_for_plan(assessment, inputs, static_assets)
        hook("sources-captured")
        for name, capture in captures.items():
            _verify_capture_live(capture, f"reviewed source {name}")
        hook("sources-reverified")
        transaction, record = _prepare_transaction(expected_plan_sha256, assessment, assets)
        hook("prepared")
        return _complete_apply(
            transaction=transaction,
            record=record,
            assessment=assessment,
            assets=assets,
            captures=captures,
            runner=runner,
            fault_hook=hook,
        )


def _load_transaction(path: Path) -> tuple[dict[str, Any], bytes]:
    value, raw = _load_root_json(path, MAX_PLAN_BYTES, "monitoring transaction")
    if value.get("schemaVersion") != SCHEMA_VERSION or value.get("kind") != TRANSACTION_KIND:
        raise InstallerError("transaction kind/version differs")
    plan_sha = value.get("planSha256")
    transaction_path = value.get("transactionPath")
    if not isinstance(plan_sha, str) or not isinstance(transaction_path, str):
        raise InstallerError("transaction identity is malformed")
    if Path(transaction_path) != _transaction_path(plan_sha):
        raise InstallerError("transaction path escapes its plan digest")
    return value, raw


def _transaction_scope(value: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: value.get(key)
        for key in (
            "schemaVersion",
            "kind",
            "planSha256",
            "transactionPath",
            "files",
            "createdDirectories",
            "originalSystemd",
        )
    }


def _preparing_transaction_scope(value: Mapping[str, Any]) -> dict[str, Any]:
    return {
        key: value.get(key)
        for key in (
            "schemaVersion",
            "kind",
            "planSha256",
            "transactionPath",
            "createdDirectories",
            "originalSystemd",
        )
    }


def _validate_transaction_inventory(
    record: Mapping[str, Any], assessment: Mapping[str, Any]
) -> None:
    plan_sha = record.get("planSha256")
    transaction_value = record.get("transactionPath")
    if not isinstance(plan_sha, str) or not isinstance(transaction_value, str):
        raise InstallerError("transaction identity is malformed")
    transaction = _transaction_path(plan_sha)
    if Path(transaction_value) != transaction:
        raise InstallerError("transaction path differs from its plan digest")
    if record.get("originalSystemd") != assessment.get("systemd"):
        raise InstallerError("transaction original systemd state differs from the plan")
    directories = assessment.get("directories")
    if not isinstance(directories, dict):
        raise InstallerError("plan directory inventory is malformed")
    planned_created = sorted(
        path
        for path, value in directories.items()
        if isinstance(value, dict)
        and isinstance(value.get("observed"), dict)
        and value["observed"].get("state") == "absent"
    )
    if record.get("createdDirectories") != planned_created:
        raise InstallerError("transaction created-directory inventory differs from the plan")
    sources = assessment.get("sources")
    targets = assessment.get("targets")
    files = record.get("files")
    if not isinstance(sources, list) or not isinstance(targets, dict) or not isinstance(files, list):
        raise InstallerError("transaction file/source inventories are malformed")
    if record.get("phase") == "preparing-preimages" and files == []:
        return
    if len(files) != len(sources):
        raise InstallerError("transaction file inventory is incomplete")
    seen: set[str] = set()
    for index, (source, item) in enumerate(zip(sources, files)):
        if not isinstance(source, dict) or not isinstance(item, dict):
            raise InstallerError("transaction file entry is malformed")
        name = source.get("name")
        target = source.get("target")
        if not isinstance(name, str) or not isinstance(target, str) or target in seen:
            raise InstallerError("transaction asset identity is malformed or duplicated")
        seen.add(target)
        original = targets.get(target)
        mutation = {
            "state": "file",
            "sha256": source.get("sourceSha256"),
            "size": None,
            "uid": 0,
            "gid": 0,
            "mode": source.get("targetMode"),
            "nlink": 1,
        }
        if (
            item.get("name") != name
            or item.get("path") != target
            or item.get("original") != original
            or item.get("mutation") != mutation
        ):
            raise InstallerError(f"transaction file binding differs from plan: {name}")
        if not isinstance(original, dict):
            raise InstallerError("transaction original target is malformed")
        if original.get("state") == "absent":
            if set(item) != {"name", "path", "original", "preimage", "mutation"} or item.get("preimage") is not None:
                raise InstallerError(f"absent preimage record is malformed: {name}")
        elif original.get("state") == "file":
            expected_preimage = transaction / "preimages" / f"{index:03d}.bin"
            if (
                set(item) != {"name", "path", "original", "preimage", "preimageSha256", "mutation"}
                or item.get("preimage") != str(expected_preimage)
                or item.get("preimageSha256") != original.get("sha256")
            ):
                raise InstallerError(f"file preimage record is malformed: {name}")
        else:
            raise InstallerError("transaction original target state is unsupported")


def resume(
    inputs: Sequence[PolicyInput],
    *,
    expected_evidence_sha256: str,
    static_assets: Sequence[Asset] = STATIC_ASSETS,
    runner: Runner = _run_command,
    fault_hook: Callable[[str], None] | None = None,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if not SHA256_RE.fullmatch(expected_evidence_sha256):
        raise InstallerError("resume evidence SHA-256 is malformed")
    hook = fault_hook or (lambda _phase: None)
    with InstallerLock():
        active, active_raw = _load_transaction(ACTIVE_TRANSACTION)
        if sha256_bytes(active_raw) != expected_evidence_sha256:
            raise InstallerError("active transaction SHA-256 differs")
        transaction = Path(active["transactionPath"])
        durable, _ = _load_transaction(transaction / "transaction.json")
        if active.get("phase") == "preparing-preimages":
            if _preparing_transaction_scope(durable) != _preparing_transaction_scope(active):
                raise InstallerError("preparing active/durable transaction scopes differ")
        elif _transaction_scope(durable) != _transaction_scope(active):
            raise InstallerError("active and durable transaction scopes differ")
        # The durable file is written first at each phase boundary and can be
        # newer after power loss.  Its immutable scope is still bound by the
        # explicitly reviewed active evidence.
        record = durable
        plan, plan_raw = _load_root_json(PLAN_PATH, MAX_PLAN_BYTES, "fixed install plan")
        assessment = _validate_plan(plan, plan_raw, str(record["planSha256"]))
        _validate_transaction_inventory(record, assessment)
        assets, captures = _capture_payloads_for_plan(assessment, inputs, static_assets)
        hook("sources-captured")
        for name, capture in captures.items():
            _verify_capture_live(capture, f"reviewed source {name}")
        if _sender_observation() != assessment.get("alertSender"):
            raise InstallerError("alert sender changed after plan recording")
        units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
        jobs = _managed_jobs(runner)
        failures = _failure_instances(runner)
        _require_quiescent(units, jobs, failures)
        _atomic_write(ACTIVE_TRANSACTION, canonical_bytes(record), mode=0o600, replace=True)
        return _complete_apply(
            transaction=transaction,
            record=record,
            assessment=assessment,
            assets=assets,
            captures=captures,
            runner=runner,
            fault_hook=hook,
        )


def _rollback_target_is_known(record: Mapping[str, Any]) -> None:
    path = Path(str(record.get("path", "")))
    original = record.get("original")
    mutation = record.get("mutation")
    if not path.is_absolute() or not isinstance(original, dict) or not isinstance(mutation, dict):
        raise InstallerError("rollback file record is malformed")
    if original.get("state") == "absent":
        if not os.path.lexists(path):
            return
        observed = _safe_target_observation(path)
        if (
            observed.get("state") != "file"
            or observed.get("sha256") != mutation.get("sha256")
            or observed.get("mode") != mutation.get("mode")
            or observed.get("nlink") != 1
        ):
            raise InstallerError(f"refusing rollback over target drift: {path}")
        return
    if original.get("state") != "file":
        raise InstallerError("rollback original state is unsupported")
    if _current_matches(path, original):
        return
    observed = _safe_target_observation(path)
    if (
        observed.get("sha256") != mutation.get("sha256")
        or observed.get("mode") != mutation.get("mode")
        or observed.get("nlink") != 1
    ):
        raise InstallerError(f"refusing rollback over target drift: {path}")


def _preflight_rollback_files(files: Sequence[Mapping[str, Any]]) -> dict[str, Capture]:
    """Authenticate every rollback input before the first managed target write."""

    preimages: dict[str, Capture] = {}
    for record in files:
        _rollback_target_is_known(record)
        original = record.get("original")
        if not isinstance(original, dict) or original.get("state") != "file":
            continue
        path = Path(str(record.get("path", "")))
        preimage_value = record.get("preimage")
        if not isinstance(preimage_value, str):
            raise InstallerError(f"rollback preimage path is missing: {path}")
        preimage = Path(preimage_value)
        capture = _capture_source(preimage, "rollback preimage")
        digest = sha256_bytes(capture.payload)
        if digest != record.get("preimageSha256") or digest != original.get("sha256"):
            raise InstallerError(f"rollback preimage digest differs: {path}")
        preimages[str(path)] = capture
    # Bind every captured pathname and parent chain once more as one all-or-none
    # preflight boundary.  Restore uses these authenticated in-memory bytes and
    # never reopens a sibling/preimage pathname after managed writes begin.
    for path, capture in preimages.items():
        _verify_capture_live(capture, f"rollback preimage for {path}")
    return preimages


def _restore_file(record: Mapping[str, Any], preimage: Capture | None) -> None:
    path = Path(str(record.get("path", "")))
    original = record.get("original")
    if not isinstance(original, dict):
        raise InstallerError("rollback file record is malformed")
    # Recheck the target immediately before its individual mutation.  The full
    # inventory has already passed the read-only preflight above.
    _rollback_target_is_known(record)
    if original.get("state") == "absent":
        if not os.path.lexists(path):
            return
        path.unlink()
        _fsync_directory(path.parent)
        return
    if _current_matches(path, original):
        return
    if preimage is None or preimage.path != Path(str(record.get("preimage", ""))):
        raise InstallerError(f"rollback preimage capture is missing: {path}")
    preimage_value = record.get("preimage")
    if not isinstance(preimage_value, str):
        raise InstallerError(f"rollback preimage path is missing: {path}")
    if sha256_bytes(preimage.payload) != record.get("preimageSha256") or sha256_bytes(preimage.payload) != original.get("sha256"):
        raise InstallerError(f"rollback preimage digest differs: {path}")
    _atomic_write(
        path,
        preimage.payload,
        uid=int(original.get("uid", 0)),
        gid=int(original.get("gid", 0)),
        mode=int(original["mode"]),
        replace=True,
    )
    if not _current_matches(path, original):
        raise InstallerError(f"restored preimage failed verification: {path}")


def _remove_created_directories(paths: Sequence[str]) -> None:
    specs = {str(path): mode for path, mode in DIRECTORIES}
    for raw in reversed(tuple(paths)):
        if raw not in specs:
            raise InstallerError("transaction created-directory inventory differs")
        path = Path(raw)
        if not os.path.lexists(path):
            continue
        _safe_directory(path, specs[raw])
        try:
            path.rmdir()
        except OSError as exc:
            raise InstallerError(f"created directory is not empty during rollback: {path}") from exc
        _fsync_directory(path.parent)


def _verify_original_systemd(original: Mapping[str, Any], runner: Runner) -> None:
    units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
    jobs = _managed_jobs(runner)
    failures = _failure_instances(runner)
    _require_quiescent(units, jobs, failures)
    if original != {"units": units, "jobs": jobs, "failureInstances": failures}:
        raise InstallerError("loaded systemd state differs after rollback")


def _rollback_record(
    transaction: Path,
    record: dict[str, Any],
    *,
    runner: Runner,
) -> dict[str, Any]:
    files = record.get("files")
    if not isinstance(files, list):
        raise InstallerError("transaction file inventory is malformed")
    if any(not isinstance(item, dict) for item in files):
        raise InstallerError("transaction rollback entry is malformed")
    preimages = _preflight_rollback_files(files)
    record["phase"] = "rollback-files-pending"
    _update_transaction(transaction, record)
    for item in reversed(files):
        _restore_file(item, preimages.get(str(item.get("path", ""))))
    _remove_created_directories(record.get("createdDirectories", []))
    record["phase"] = "rollback-daemon-reload-pending"
    _update_transaction(transaction, record)
    _daemon_reload(runner)
    record["phase"] = "rollback-daemon-reloaded"
    _update_transaction(transaction, record)
    original = record.get("originalSystemd")
    if not isinstance(original, dict):
        raise InstallerError("transaction original systemd state is malformed")
    _verify_original_systemd(original, runner)
    record["phase"] = "rolled-back"
    record["rolledBackAtUtc"] = _utc_now()
    _update_transaction(transaction, record)
    return record


def rollback(
    *,
    evidence_path: Path,
    expected_evidence_sha256: str,
    confirmation: str,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if evidence_path not in (ACTIVE_TRANSACTION, UNCOMMISSIONED_RECEIPT):
        raise InstallerError("rollback evidence must be the fixed active transaction or uncommissioned receipt")
    if not SHA256_RE.fullmatch(expected_evidence_sha256):
        raise InstallerError("rollback evidence SHA-256 is malformed")
    if confirmation != ROLLBACK_CONFIRMATION:
        raise InstallerError(f"confirmation must exactly equal: {ROLLBACK_CONFIRMATION}")
    with InstallerLock():
        if os.path.lexists(COMMISSIONED_MARKER):
            raise InstallerError("commissioned monitoring cannot use installer rollback")
        evidence, evidence_raw = _load_root_json(evidence_path, MAX_PLAN_BYTES, "rollback evidence")
        if sha256_bytes(evidence_raw) != expected_evidence_sha256:
            raise InstallerError("rollback evidence SHA-256 differs")
        if evidence_path == ACTIVE_TRANSACTION:
            active, _ = _load_transaction(ACTIVE_TRANSACTION)
            transaction = Path(active["transactionPath"])
            if active.get("phase") == "preparing-preimages" and not os.path.lexists(transaction / "transaction.json"):
                record = active
                if record.get("files") != []:
                    raise InstallerError("preparing transaction unexpectedly contains file mutations")
            else:
                durable, _ = _load_transaction(transaction / "transaction.json")
                if active.get("phase") == "preparing-preimages":
                    if _preparing_transaction_scope(active) != _preparing_transaction_scope(durable):
                        raise InstallerError("preparing active/durable rollback scopes differ")
                elif _transaction_scope(active) != _transaction_scope(durable):
                    raise InstallerError("active and durable rollback scopes differ")
                record = durable
        else:
            if evidence.get("schemaVersion") != SCHEMA_VERSION or evidence.get("kind") != RECEIPT_KIND or evidence.get("commissioned") is not False:
                raise InstallerError("rollback receipt is not an uncommissioned installation")
            plan_sha = evidence.get("planSha256")
            transaction = _transaction_path(str(plan_sha))
            record, _ = _load_transaction(transaction / "transaction.json")
        plan, plan_raw = _load_root_json(PLAN_PATH, MAX_PLAN_BYTES, "fixed install plan")
        assessment = _validate_plan(plan, plan_raw, str(record.get("planSha256", "")))
        _validate_transaction_inventory(record, assessment)
        units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
        jobs = _managed_jobs(runner)
        failures = _failure_instances(runner)
        _require_quiescent(units, jobs, failures)
        if record.get("phase") == "preparing-preimages" and record.get("files") == []:
            original = record.get("originalSystemd")
            if not isinstance(original, dict):
                raise InstallerError("preparing transaction lacks original systemd evidence")
            _verify_original_systemd(original, runner)
            record["phase"] = "rolled-back-before-mutation"
            record["rolledBackAtUtc"] = _utc_now()
            if os.path.lexists(transaction):
                _atomic_write(transaction / "transaction.json", canonical_bytes(record), mode=0o600, replace=os.path.lexists(transaction / "transaction.json"))
        else:
            record = _rollback_record(transaction, record, runner=runner)
        receipt_path = ROLLBACK_RECEIPTS / (
            datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
            + expected_evidence_sha256
            + ".json"
        )
        receipt = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": ROLLBACK_KIND,
            "rolledBackAtUtc": record["rolledBackAtUtc"],
            "planSha256": record["planSha256"],
            "transactionPath": str(transaction),
            "evidencePath": str(evidence_path),
            "evidenceSha256": expected_evidence_sha256,
            "journalPreserved": str(JOURNAL_ROOT),
            "receiptPath": str(receipt_path),
        }
        receipt_raw = canonical_bytes(receipt)
        _atomic_write(receipt_path, receipt_raw, mode=0o600, replace=False)
        # Only source pointers are retired.  Transaction/preimage/rollback
        # evidence and the complete monitoring journal remain durable.
        _durable_unlink(UNCOMMISSIONED_RECEIPT)
        _durable_unlink(ACTIVE_TRANSACTION)
        return receipt, sha256_bytes(receipt_raw)


class JournaldLock:
    def __init__(self) -> None:
        self.descriptor = -1

    def __enter__(self) -> "JournaldLock":
        for path in (
            STATE_ROOT,
            JOURNAL_ROOT,
            JOURNALD_INSTALLER_ROOT,
            JOURNALD_ROLLBACK_RECEIPTS,
            JOURNALD_TRANSACTIONS,
        ):
            _atomic_directory(path, 0o700)
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self.descriptor = os.open(JOURNALD_LOCK_PATH, flags, 0o600)
        if not _test_mode():
            os.fchown(self.descriptor, 0, 0)
        os.fchmod(self.descriptor, 0o600)
        if fcntl is not None:
            try:
                fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                raise InstallerError("another journald installer operation is running") from exc
        elif not _test_mode():
            raise InstallerError("journald installer lock requires flock")
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            if fcntl is not None:
                fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


def _validate_journald_payload(raw: bytes) -> None:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise InstallerError("journald source is not UTF-8") from exc
    if "\r" in text or "\x00" in text or not text.endswith("\n"):
        raise InstallerError("journald source bytes are not canonical LF text")
    section = ""
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            if section != "Journal":
                raise InstallerError("journald source contains an unexpected section")
            continue
        if section != "Journal" or "=" not in line:
            raise InstallerError("journald source contains an unexpected directive")
        key, value = line.split("=", 1)
        if key in values or not value:
            raise InstallerError("journald source contains a duplicate/empty directive")
        values[key] = value
    required = {
        "Storage",
        "Compress",
        "Seal",
        "SystemMaxUse",
        "SystemKeepFree",
        "SystemMaxFileSize",
        "MaxRetentionSec",
        "RateLimitIntervalSec",
        "RateLimitBurst",
    }
    if set(values) != required:
        raise InstallerError("journald source directives differ from the reviewed bounded schema")
    if values["Storage"] != "persistent" or values["Compress"] != "yes" or values["Seal"] != "yes":
        raise InstallerError("journald source does not require persistent/compressed/sealed storage")


def _journald_service_observation(runner: Runner) -> dict[str, Any]:
    properties = ("LoadState", "ActiveState", "SubState", "MainPID")
    command = ["/usr/bin/systemctl", "show", "systemd-journald.service"]
    command.extend(f"--property={name}" for name in properties)
    result = runner(command)
    if result.returncode != 0:
        raise InstallerError("systemctl could not inspect systemd-journald")
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in properties or key in values:
            raise InstallerError("journald systemd observation is malformed")
        values[key] = value
    if set(values) != set(properties) or values["LoadState"] != "loaded" or values["ActiveState"] != "active":
        raise InstallerError("systemd-journald must be loaded and active before the optional transaction")
    jobs_result = runner(["/usr/bin/systemctl", "list-jobs", "--no-legend", "--plain", "--no-pager"])
    if jobs_result.returncode != 0:
        raise InstallerError("systemctl could not enumerate journald jobs")
    jobs = [line for line in jobs_result.stdout.splitlines() if "systemd-journald.service" in line]
    if jobs:
        raise InstallerError("an active systemd-journald job blocks the optional transaction")
    return {"properties": values, "jobs": []}


def _journald_assessment(
    source: Path,
    expected_sha256: str,
    runner: Runner,
) -> tuple[dict[str, Any], Capture]:
    _reject_example_source(source, "journald source")
    if source == JOURNALD_TARGET:
        raise InstallerError("journald reviewed source must be separate from its managed target")
    if not SHA256_RE.fullmatch(expected_sha256):
        raise InstallerError("journald source SHA-256 is malformed")
    capture = _capture_source(source, "reviewed journald source")
    if sha256_bytes(capture.payload) != expected_sha256:
        raise InstallerError("journald source differs from the explicit approved SHA-256")
    _validate_journald_payload(capture.payload)
    parent = JOURNALD_TARGET.parent
    parent_observation = _directory_observation(parent, 0o755)
    return {
        "source": str(source),
        "sourceSha256": expected_sha256,
        "target": str(JOURNALD_TARGET),
        "targetMode": 0o644,
        "targetPreimage": _safe_target_observation(JOURNALD_TARGET),
        "parentPreimage": parent_observation,
        "journald": _journald_service_observation(runner),
        "restartAuthorized": False,
    }, capture


def journald_assess(
    source: Path,
    expected_sha256: str,
    *,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if os.path.lexists(JOURNALD_TRANSACTION_PATH) or os.path.lexists(JOURNALD_RECEIPT_PATH):
        raise InstallerError("existing journald transaction evidence blocks assessment")
    assessment, _ = _journald_assessment(source, expected_sha256, runner)
    digest = sha256_bytes(canonical_bytes(assessment))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "uten-imp-journald-read-only-assessment",
        "assessmentSha256": digest,
        "assessment": assessment,
    }, digest


def journald_record_plan(
    source: Path,
    source_sha256: str,
    *,
    expected_assessment_sha256: str,
    confirmation: str,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != JOURNALD_RECORD_CONFIRMATION:
        raise InstallerError(f"confirmation must exactly equal: {JOURNALD_RECORD_CONFIRMATION}")
    with JournaldLock():
        if os.path.lexists(JOURNALD_TRANSACTION_PATH) or os.path.lexists(JOURNALD_RECEIPT_PATH):
            raise InstallerError("existing journald transaction evidence blocks plan recording")
        assessment, capture = _journald_assessment(source, source_sha256, runner)
        digest = sha256_bytes(canonical_bytes(assessment))
        if digest != expected_assessment_sha256:
            raise InstallerError("journald assessment changed after approval")
        _verify_capture_live(capture, "reviewed journald source")
        plan = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": "uten-imp-journald-install-plan",
            "recordedAtUtc": _utc_now(),
            "assessmentSha256": digest,
            "assessment": assessment,
        }
        raw = canonical_bytes(plan)
        _atomic_write(JOURNALD_PLAN_PATH, raw, mode=0o600, replace=os.path.lexists(JOURNALD_PLAN_PATH))
        return plan, sha256_bytes(raw)


def _load_journald_plan(expected_sha256: str) -> tuple[dict[str, Any], bytes]:
    plan, raw = _load_root_json(JOURNALD_PLAN_PATH, MAX_PLAN_BYTES, "journald install plan")
    if sha256_bytes(raw) != expected_sha256 or plan.get("kind") != "uten-imp-journald-install-plan":
        raise InstallerError("journald install plan digest/kind differs")
    assessment = plan.get("assessment")
    if not isinstance(assessment, dict) or sha256_bytes(canonical_bytes(assessment)) != plan.get("assessmentSha256"):
        raise InstallerError("journald plan assessment binding differs")
    return assessment, raw


def _journald_transaction_path(plan_sha256: str) -> Path:
    if not SHA256_RE.fullmatch(plan_sha256):
        raise InstallerError("journald transaction plan digest is malformed")
    return JOURNALD_TRANSACTIONS / plan_sha256


def _write_journald_transaction(transaction: Path, record: Mapping[str, Any]) -> None:
    raw = canonical_bytes(record)
    _atomic_write(transaction / "transaction.json", raw, mode=0o600, replace=True)
    _atomic_write(JOURNALD_TRANSACTION_PATH, raw, mode=0o600, replace=True)


def _prepare_journald_preimage(transaction: Path, record: dict[str, Any]) -> None:
    assessment = record["assessment"]
    original = assessment["targetPreimage"]
    preimage_value = record.get("preimage")
    if original.get("state") == "absent":
        if preimage_value is not None or not _current_matches(JOURNALD_TARGET, original):
            raise InstallerError("journald absent preimage changed before mutation")
    elif original.get("state") == "file":
        expected = transaction / "preimage.bin"
        if preimage_value != str(expected):
            raise InstallerError("journald preimage path differs")
        if os.path.lexists(expected):
            capture = _capture_source(expected, "journald durable preimage")
            if sha256_bytes(capture.payload) != original.get("sha256"):
                raise InstallerError("journald durable preimage digest differs")
        else:
            if not _current_matches(JOURNALD_TARGET, original):
                raise InstallerError("journald target changed before durable preimage capture")
            capture = _capture_source(JOURNALD_TARGET, "journald target preimage")
            if sha256_bytes(capture.payload) != original.get("sha256"):
                raise InstallerError("journald target preimage digest differs")
            _atomic_write(expected, capture.payload, mode=0o600, replace=False)
    else:
        raise InstallerError("journald target preimage state is unsupported")
    record["phase"] = "prepared"
    _write_journald_transaction(transaction, record)


def _finish_journald_apply(
    transaction: Path,
    record: dict[str, Any],
    capture: Capture,
    runner: Runner,
) -> tuple[dict[str, Any], str]:
    assessment = record["assessment"]
    parent = JOURNALD_TARGET.parent
    if assessment["parentPreimage"] == {"state": "absent"}:
        _atomic_directory(parent, 0o755)
    elif _directory_observation(parent, 0o755) != assessment["parentPreimage"]:
        raise InstallerError("journald drop-in parent drifted")
    record["phase"] = "parent-ready"
    _write_journald_transaction(transaction, record)
    desired = {
        "state": "file",
        "sha256": assessment["sourceSha256"],
        "size": len(capture.payload),
        "uid": 0 if not _test_mode() else os.getuid(),
        "gid": 0 if not _test_mode() else os.getgid(),
        "mode": 0o644,
        "nlink": 1,
    }
    if not _current_matches(JOURNALD_TARGET, desired):
        if not _current_matches(JOURNALD_TARGET, assessment["targetPreimage"]):
            raise InstallerError("journald target is neither preimage nor planned bytes")
        _atomic_write(
            JOURNALD_TARGET,
            capture.payload,
            mode=0o644,
            replace=assessment["targetPreimage"].get("state") == "file",
        )
    if not _current_matches(JOURNALD_TARGET, desired):
        raise InstallerError("journald target verification failed")
    # Re-observe only.  No daemon-reload, kill, reload, try-restart or restart
    # command is issued by this independent optional transaction.
    live = _journald_service_observation(runner)
    if live != assessment["journald"]:
        raise InstallerError("journald service identity/state changed during file installation")
    record["phase"] = "installed-restart-pending"
    _write_journald_transaction(transaction, record)
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "uten-imp-journald-uncommissioned-receipt",
        "planSha256": record["planSha256"],
        "transactionPath": str(transaction),
        "appliedAtUtc": _utc_now(),
        "installedSha256": assessment["sourceSha256"],
        "restartPerformed": False,
        "activationPending": True,
    }
    receipt_raw = canonical_bytes(receipt)
    if not os.path.lexists(JOURNALD_RECEIPT_PATH):
        _atomic_write(JOURNALD_RECEIPT_PATH, receipt_raw, mode=0o600, replace=False)
    else:
        existing, existing_raw = _load_root_json(JOURNALD_RECEIPT_PATH, MAX_PLAN_BYTES, "journald receipt")
        if any(existing.get(key) != receipt.get(key) for key in receipt if key != "appliedAtUtc"):
            raise InstallerError("existing journald receipt differs")
        receipt, receipt_raw = existing, existing_raw
    record["phase"] = "committed-restart-pending"
    record["receiptSha256"] = sha256_bytes(receipt_raw)
    _write_journald_transaction(transaction, record)
    _durable_unlink(JOURNALD_TRANSACTION_PATH)
    return receipt, sha256_bytes(receipt_raw)


def journald_apply(
    source: Path,
    source_sha256: str,
    *,
    expected_plan_sha256: str,
    confirmation: str,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != JOURNALD_APPLY_CONFIRMATION:
        raise InstallerError(f"confirmation must exactly equal: {JOURNALD_APPLY_CONFIRMATION}")
    with JournaldLock():
        if os.path.lexists(JOURNALD_TRANSACTION_PATH) or os.path.lexists(JOURNALD_RECEIPT_PATH):
            raise InstallerError("existing journald transaction evidence blocks apply")
        assessment, _ = _load_journald_plan(expected_plan_sha256)
        current, capture = _journald_assessment(source, source_sha256, runner)
        if current != assessment:
            raise InstallerError("journald source/target/service assessment changed after plan recording")
        _verify_capture_live(capture, "reviewed journald source")
        transaction = _journald_transaction_path(expected_plan_sha256)
        _atomic_directory(transaction, 0o700)
        preimage = (
            str(transaction / "preimage.bin")
            if assessment["targetPreimage"].get("state") == "file"
            else None
        )
        record = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": "uten-imp-journald-install-transaction",
            "planSha256": expected_plan_sha256,
            "transactionPath": str(transaction),
            "phase": "preparing-preimage",
            "createdAtUtc": _utc_now(),
            "assessment": assessment,
            "preimage": preimage,
        }
        _atomic_write(JOURNALD_TRANSACTION_PATH, canonical_bytes(record), mode=0o600, replace=False)
        _atomic_write(transaction / "transaction.json", canonical_bytes(record), mode=0o600, replace=False)
        _prepare_journald_preimage(transaction, record)
        return _finish_journald_apply(transaction, record, capture, runner)


def _load_journald_transaction(path: Path) -> tuple[dict[str, Any], bytes]:
    value, raw = _load_root_json(path, MAX_PLAN_BYTES, "journald transaction")
    if value.get("schemaVersion") != SCHEMA_VERSION or value.get("kind") != "uten-imp-journald-install-transaction":
        raise InstallerError("journald transaction kind/version differs")
    transaction = _journald_transaction_path(str(value.get("planSha256", "")))
    if value.get("transactionPath") != str(transaction):
        raise InstallerError("journald transaction path differs from its plan digest")
    assessment = value.get("assessment")
    if not isinstance(assessment, dict) or assessment.get("target") != str(JOURNALD_TARGET):
        raise InstallerError("journald transaction assessment is malformed")
    expected_preimage = (
        str(transaction / "preimage.bin")
        if assessment.get("targetPreimage", {}).get("state") == "file"
        else None
    )
    if value.get("preimage") != expected_preimage:
        raise InstallerError("journald transaction preimage path differs")
    return value, raw


def journald_resume(
    source: Path,
    source_sha256: str,
    *,
    expected_evidence_sha256: str,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    with JournaldLock():
        active, active_raw = _load_journald_transaction(JOURNALD_TRANSACTION_PATH)
        if sha256_bytes(active_raw) != expected_evidence_sha256:
            raise InstallerError("journald active evidence SHA-256 differs")
        transaction = Path(active["transactionPath"])
        if os.path.lexists(transaction / "transaction.json"):
            durable, _ = _load_journald_transaction(transaction / "transaction.json")
        else:
            durable = active
            _atomic_write(
                transaction / "transaction.json",
                canonical_bytes(durable),
                mode=0o600,
                replace=False,
            )
        for key in ("schemaVersion", "kind", "planSha256", "transactionPath", "assessment", "preimage"):
            if active.get(key) != durable.get(key):
                raise InstallerError("journald active/durable scopes differ")
        plan_assessment, _ = _load_journald_plan(str(durable["planSha256"]))
        if durable["assessment"] != plan_assessment:
            raise InstallerError("journald transaction differs from the plan")
        current_source, capture = _journald_assessment(source, source_sha256, runner)
        # Target/parent may already be at the planned mutation after a crash;
        # all immutable source and service observations must still match.
        for key in ("source", "sourceSha256", "target", "targetMode", "journald", "restartAuthorized"):
            if current_source.get(key) != plan_assessment.get(key):
                raise InstallerError("journald source/service drifted before resume")
        _verify_capture_live(capture, "reviewed journald source")
        _atomic_write(JOURNALD_TRANSACTION_PATH, canonical_bytes(durable), mode=0o600, replace=True)
        if durable.get("phase") == "preparing-preimage":
            _prepare_journald_preimage(transaction, durable)
        return _finish_journald_apply(transaction, durable, capture, runner)


def journald_rollback(
    *,
    evidence_path: Path,
    expected_evidence_sha256: str,
    confirmation: str,
    runner: Runner = _run_command,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if evidence_path not in (JOURNALD_TRANSACTION_PATH, JOURNALD_RECEIPT_PATH):
        raise InstallerError("journald rollback evidence path is not fixed")
    if confirmation != JOURNALD_ROLLBACK_CONFIRMATION:
        raise InstallerError(f"confirmation must exactly equal: {JOURNALD_ROLLBACK_CONFIRMATION}")
    with JournaldLock():
        evidence, evidence_raw = _load_root_json(evidence_path, MAX_PLAN_BYTES, "journald rollback evidence")
        if sha256_bytes(evidence_raw) != expected_evidence_sha256:
            raise InstallerError("journald rollback evidence SHA-256 differs")
        if evidence_path == JOURNALD_TRANSACTION_PATH:
            active, _ = _load_journald_transaction(JOURNALD_TRANSACTION_PATH)
            transaction = Path(active["transactionPath"])
        else:
            if evidence.get("kind") != "uten-imp-journald-uncommissioned-receipt" or evidence.get("restartPerformed") is not False:
                raise InstallerError("journald receipt is not safely uncommissioned")
            transaction = Path(str(evidence.get("transactionPath", "")))
        if os.path.lexists(transaction / "transaction.json"):
            durable, _ = _load_journald_transaction(transaction / "transaction.json")
        elif evidence_path == JOURNALD_TRANSACTION_PATH:
            durable, _ = _load_journald_transaction(JOURNALD_TRANSACTION_PATH)
        else:
            raise InstallerError("journald durable transaction is missing")
        assessment, _ = _load_journald_plan(str(durable["planSha256"]))
        if durable["assessment"] != assessment:
            raise InstallerError("journald transaction differs from plan")
        current_service = _journald_service_observation(runner)
        if current_service != assessment["journald"]:
            raise InstallerError("journald service changed; rollback will not restart or race it")
        original = assessment["targetPreimage"]
        if original.get("state") == "absent":
            if os.path.lexists(JOURNALD_TARGET):
                observed = _safe_target_observation(JOURNALD_TARGET)
                if observed.get("sha256") != assessment["sourceSha256"] or observed.get("mode") != 0o644:
                    raise InstallerError("journald target drift blocks rollback")
                JOURNALD_TARGET.unlink()
                _fsync_directory(JOURNALD_TARGET.parent)
        else:
            if not _current_matches(JOURNALD_TARGET, original):
                observed = _safe_target_observation(JOURNALD_TARGET)
                if observed.get("sha256") != assessment["sourceSha256"] or observed.get("mode") != 0o644:
                    raise InstallerError("journald target drift blocks rollback")
                preimage = Path(str(durable.get("preimage", "")))
                capture = _capture_source(preimage, "journald rollback preimage")
                if sha256_bytes(capture.payload) != original.get("sha256"):
                    raise InstallerError("journald rollback preimage digest differs")
                _atomic_write(
                    JOURNALD_TARGET,
                    capture.payload,
                    mode=int(original["mode"]),
                    uid=int(original.get("uid", 0)),
                    gid=int(original.get("gid", 0)),
                    replace=True,
                )
        if assessment["parentPreimage"] == {"state": "absent"} and JOURNALD_TARGET.parent.is_dir():
            try:
                JOURNALD_TARGET.parent.rmdir()
            except OSError as exc:
                raise InstallerError("created journald drop-in directory is not empty") from exc
            _fsync_directory(JOURNALD_TARGET.parent.parent)
        # Explicitly no journald restart/reload.  Restored bytes take effect
        # only in a separately approved operator transaction.
        receipt_path = JOURNALD_ROLLBACK_RECEIPTS / (
            datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
            + expected_evidence_sha256
            + ".json"
        )
        receipt = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": "uten-imp-journald-rollback-receipt",
            "rolledBackAtUtc": _utc_now(),
            "planSha256": durable["planSha256"],
            "evidencePath": str(evidence_path),
            "evidenceSha256": expected_evidence_sha256,
            "receiptPath": str(receipt_path),
            "restartPerformed": False,
            "journalPreserved": str(JOURNAL_ROOT),
        }
        raw = canonical_bytes(receipt)
        _atomic_write(receipt_path, raw, mode=0o600, replace=False)
        _durable_unlink(JOURNALD_RECEIPT_PATH)
        _durable_unlink(JOURNALD_TRANSACTION_PATH)
        return receipt, sha256_bytes(raw)


def _add_policy_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--host-policy-source", type=Path, required=True)
    parser.add_argument("--host-policy-sha256", required=True)
    parser.add_argument("--external-policy-source", type=Path, required=True)
    parser.add_argument("--external-policy-sha256", required=True)
    parser.add_argument("--hardware-authority-source", type=Path, required=True)
    parser.add_argument("--hardware-authority-sha256", required=True)


def _inputs(args: argparse.Namespace) -> tuple[PolicyInput, ...]:
    return (
        PolicyInput(
            "host-policy",
            args.host_policy_source,
            args.host_policy_sha256,
            HOST_POLICY_TARGET,
            0o644,
        ),
        PolicyInput(
            "external-policy",
            args.external_policy_source,
            args.external_policy_sha256,
            EXTERNAL_POLICY_TARGET,
            0o644,
        ),
        PolicyInput(
            "hardware-authority",
            args.hardware_authority_source,
            args.hardware_authority_sha256,
            HARDWARE_AUTHORITY_TARGET,
            0o640,
        ),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    assess_parser = commands.add_parser("assess", help="read-only assessment; writes nothing")
    _add_policy_arguments(assess_parser)
    record_parser = commands.add_parser("record-plan", help="record a reviewed fixed plan")
    _add_policy_arguments(record_parser)
    record_parser.add_argument("--expected-assessment-sha256", required=True)
    record_parser.add_argument("--confirm", required=True)
    apply_parser = commands.add_parser("apply", help="install but leave all timers disabled/inactive")
    _add_policy_arguments(apply_parser)
    apply_parser.add_argument("--plan", type=Path, required=True)
    apply_parser.add_argument("--expected-plan-sha256", required=True)
    apply_parser.add_argument("--confirm", required=True)
    resume_parser = commands.add_parser("resume", help="continue an interrupted evidence-bound apply")
    _add_policy_arguments(resume_parser)
    resume_parser.add_argument("--expected-evidence-sha256", required=True)
    rollback_parser = commands.add_parser("rollback", help="restore exact preimages and preserve journal")
    rollback_parser.add_argument("--evidence", type=Path, required=True)
    rollback_parser.add_argument("--expected-evidence-sha256", required=True)
    rollback_parser.add_argument("--confirm", required=True)
    journald_assess_parser = commands.add_parser(
        "journald-assess", help="read-only assessment for the independent optional journald transaction"
    )
    journald_assess_parser.add_argument("--source", type=Path, required=True)
    journald_assess_parser.add_argument("--source-sha256", required=True)
    journald_record_parser = commands.add_parser("journald-record-plan")
    journald_record_parser.add_argument("--source", type=Path, required=True)
    journald_record_parser.add_argument("--source-sha256", required=True)
    journald_record_parser.add_argument("--expected-assessment-sha256", required=True)
    journald_record_parser.add_argument("--confirm", required=True)
    journald_apply_parser = commands.add_parser("journald-apply")
    journald_apply_parser.add_argument("--source", type=Path, required=True)
    journald_apply_parser.add_argument("--source-sha256", required=True)
    journald_apply_parser.add_argument("--expected-plan-sha256", required=True)
    journald_apply_parser.add_argument("--confirm", required=True)
    journald_resume_parser = commands.add_parser("journald-resume")
    journald_resume_parser.add_argument("--source", type=Path, required=True)
    journald_resume_parser.add_argument("--source-sha256", required=True)
    journald_resume_parser.add_argument("--expected-evidence-sha256", required=True)
    journald_rollback_parser = commands.add_parser("journald-rollback")
    journald_rollback_parser.add_argument("--evidence", type=Path, required=True)
    journald_rollback_parser.add_argument("--expected-evidence-sha256", required=True)
    journald_rollback_parser.add_argument("--confirm", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.action == "journald-assess":
            envelope, _ = journald_assess(args.source, args.source_sha256)
            sys.stdout.buffer.write(canonical_bytes(envelope))
            return 0
        if args.action == "journald-record-plan":
            _, digest = journald_record_plan(
                args.source,
                args.source_sha256,
                expected_assessment_sha256=args.expected_assessment_sha256,
                confirmation=args.confirm,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {"status": "RECORDED", "planPath": str(JOURNALD_PLAN_PATH), "planSha256": digest}
                )
            )
            return 0
        if args.action == "journald-apply":
            _, digest = journald_apply(
                args.source,
                args.source_sha256,
                expected_plan_sha256=args.expected_plan_sha256,
                confirmation=args.confirm,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {
                        "status": "APPLIED_RESTART_PENDING",
                        "receiptPath": str(JOURNALD_RECEIPT_PATH),
                        "receiptSha256": digest,
                        "restartPerformed": False,
                    }
                )
            )
            return 0
        if args.action == "journald-resume":
            _, digest = journald_resume(
                args.source,
                args.source_sha256,
                expected_evidence_sha256=args.expected_evidence_sha256,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {
                        "status": "APPLIED_RESTART_PENDING",
                        "receiptPath": str(JOURNALD_RECEIPT_PATH),
                        "receiptSha256": digest,
                        "restartPerformed": False,
                    }
                )
            )
            return 0
        if args.action == "journald-rollback":
            receipt, digest = journald_rollback(
                evidence_path=args.evidence,
                expected_evidence_sha256=args.expected_evidence_sha256,
                confirmation=args.confirm,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {
                        "status": "ROLLED_BACK_RESTART_PENDING",
                        "rollbackReceiptPath": receipt["receiptPath"],
                        "rollbackReceiptSha256": digest,
                        "restartPerformed": False,
                    }
                )
            )
            return 0
        if args.action == "assess":
            envelope, _ = assess(_inputs(args))
            sys.stdout.buffer.write(canonical_bytes(envelope))
            return 0
        if args.action == "record-plan":
            _, digest = record_plan(
                _inputs(args),
                expected_assessment_sha256=args.expected_assessment_sha256,
                confirmation=args.confirm,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {"status": "RECORDED", "planPath": str(PLAN_PATH), "planSha256": digest}
                )
            )
            return 0
        if args.action == "apply":
            _, digest = apply_plan(
                _inputs(args),
                plan_path=args.plan,
                expected_plan_sha256=args.expected_plan_sha256,
                confirmation=args.confirm,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {
                        "status": "APPLIED_UNCOMMISSIONED",
                        "receiptPath": str(UNCOMMISSIONED_RECEIPT),
                        "receiptSha256": digest,
                        "timersEnabled": False,
                    }
                )
            )
            return 0
        if args.action == "resume":
            _, digest = resume(
                _inputs(args),
                expected_evidence_sha256=args.expected_evidence_sha256,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {
                        "status": "APPLIED_UNCOMMISSIONED",
                        "receiptPath": str(UNCOMMISSIONED_RECEIPT),
                        "receiptSha256": digest,
                        "timersEnabled": False,
                    }
                )
            )
            return 0
        receipt, digest = rollback(
            evidence_path=args.evidence,
            expected_evidence_sha256=args.expected_evidence_sha256,
            confirmation=args.confirm,
        )
        sys.stdout.buffer.write(
            canonical_bytes(
                {
                    "status": "ROLLED_BACK",
                    "rollbackReceiptPath": receipt["receiptPath"],
                    "rollbackReceiptSha256": digest,
                    "journalPreserved": receipt["journalPreserved"],
                }
            )
        )
        return 0
    except InstallerError as exc:
        print(f"UTEN_MONITOR_INSTALLER_NO_GO: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
