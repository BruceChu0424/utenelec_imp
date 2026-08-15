#!/usr/bin/env python3
"""Evidence-bound, fail-closed installer for an existing PostgreSQL host.

``assess`` performs read-only inspection of the managed runtime, systemd and
PostgreSQL/storage state and writes only a canonical envelope to stdout.
``record-plan`` repeats that inspection after approval and records the fixed
root-only plan only when its assessment SHA-256 is unchanged. ``apply`` rechecks
that exact plan before any managed target changes. ``rollback`` restores only
the exact uncommissioned installation bound by its receipt.

No command in this program starts, stops, enables or disables a unit.  Secrets,
repo2 policy, WORM evidence and alert-provider configuration are out of scope.
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
from typing import Any, Callable, Iterable, Mapping, Sequence

try:
    import fcntl
    import grp
    import pwd
except ImportError:  # pragma: no cover - production is Linux; allows Windows static QA.
    fcntl = None  # type: ignore[assignment]
    grp = None  # type: ignore[assignment]
    pwd = None  # type: ignore[assignment]


SCHEMA_VERSION = 1
PLAN_KIND = "uten-imp-existing-backup-install-plan"
TRANSACTION_KIND = "uten-imp-existing-backup-install-transaction"
RECEIPT_KIND = "uten-imp-existing-backup-uncommissioned-receipt"
ROLLBACK_KIND = "uten-imp-existing-backup-rollback-receipt"
PREPARATION_CLOSED_KIND = "uten-imp-existing-backup-preparation-closed-receipt"
APPLY_CONFIRMATION = "APPLY REVIEWED UTEN BACKUP INSTALL PLAN"
RECORD_CONFIRMATION = "RECORD REVIEWED UTEN BACKUP INSTALL PLAN"
ROLLBACK_CONFIRMATION = "ROLLBACK UNCOMMISSIONED UTEN BACKUP INSTALLATION"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

HERE = Path(__file__).resolve().parent
DEPLOY_ROOT = HERE.parents[1]
SYSTEMD_SOURCE = DEPLOY_ROOT / "systemd"

STATE_ROOT = Path("/var/lib/uten-imp-backup-installer")
PLAN_PATH = STATE_ROOT / "install-plan.json"
PLAN_HISTORY_DIR = STATE_ROOT / "plan-history"
TRANSACTIONS_DIR = STATE_ROOT / "transactions"
ACTIVE_TRANSACTION_PATH = STATE_ROOT / "active-transaction.json"
UNCOMMISSIONED_RECEIPT_PATH = STATE_ROOT / "uncommissioned-install.json"
COMMISSIONED_MARKER_PATH = STATE_ROOT / "commissioned.json"
ROLLBACK_RECEIPTS_DIR = STATE_ROOT / "rollback-receipts"
INSTALLER_LOCK_PATH = STATE_ROOT / "installer.lock"

LIBEXEC_DIR = Path("/usr/local/libexec/uten-imp-backup")
MAINTENANCE_DIR = Path("/var/lib/uten-imp-db-maintenance")
MAINTENANCE_LOCK = MAINTENANCE_DIR / "operation.lock"
HEALTH_STATE_DIR = Path("/var/lib/uten-imp-backup-health")
BACKUP_TRANSACTION_DIR = Path("/var/lib/uten-imp-backup-transactions")
BACKUP_TRANSACTION_RECEIPTS_DIR = BACKUP_TRANSACTION_DIR / "receipts"
BACKUP_COMMISSIONER_DIR = Path("/var/lib/uten-imp-backup-commissioner")
BACKUP_COMMISSIONER_RECEIPTS_DIR = BACKUP_COMMISSIONER_DIR / "receipts"
INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR = Path(
    "/var/lib/uten-imp-internal-test-backup-commissioner"
)
INTERNAL_TEST_FIRST_BACKUP_TRANSACTIONS_DIR = (
    INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR / "transactions"
)
INTERNAL_TEST_FIRST_BACKUP_RECEIPTS_DIR = (
    INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR / "receipts"
)

POSTGRES_META_UNIT = "postgresql.service"
POSTGRES_INSTANCE_UNIT = "postgresql@16-main.service"
TIMER_UNITS = (
    "uten-pgbackup.timer",
    "uten-pgbackup-repo2.timer",
    "uten-pgbackup-health.timer",
    "uten-pgbackup-alert-drain.timer",
)
JOB_UNITS = (
    "uten-pgbackup.service",
    "uten-pgbackup-repo2.service",
    "uten-pgbackup-health.service",
    "uten-pgbackup-alert-drain.service",
)
TEMPLATE_UNITS = ("uten-pgbackup-alert@.service",)
MANAGED_UNITS = (*JOB_UNITS, *TIMER_UNITS, *TEMPLATE_UNITS)

MAX_MANAGED_FILE_BYTES = 4 * 1024 * 1024
MAX_PLAN_BYTES = 2 * 1024 * 1024
MAX_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_DROPINS_PER_UNIT = 32
MAX_TOTAL_DROPINS = 128
COMMAND_TIMEOUT_SECONDS = 60


class InstallerError(RuntimeError):
    """The existing-host installer contract could not be proven."""


@dataclass(frozen=True)
class Identity:
    postgres_uid: int
    postgres_gid: int


@dataclass(frozen=True)
class Asset:
    name: str
    source: Path
    target: Path
    mode: int


ASSETS = (
    Asset("locked-job", HERE / "locked_job.py", LIBEXEC_DIR / "locked_job.py", 0o755),
    Asset(
        "repo2-runtime",
        HERE / "pgbackrest_repo2.py",
        LIBEXEC_DIR / "pgbackrest_repo2.py",
        0o755,
    ),
    Asset(
        "health-runtime",
        HERE / "pgbackrest_health.py",
        LIBEXEC_DIR / "pgbackrest_health.py",
        0o755,
    ),
    Asset("alert-runtime", HERE / "backup_alert.py", LIBEXEC_DIR / "backup_alert.py", 0o755),
    Asset(
        "acceptance-runtime",
        HERE / "backup_acceptance.py",
        LIBEXEC_DIR / "backup_acceptance.py",
        0o755,
    ),
    Asset(
        "commissioner-runtime",
        HERE / "backup_commissioner.py",
        LIBEXEC_DIR / "backup_commissioner.py",
        0o755,
    ),
    Asset(
        "internal-test-first-backup-producer",
        HERE / "internal_test_first_backup.py",
        LIBEXEC_DIR / "internal_test_first_backup.py",
        0o755,
    ),
    Asset(
        "internal-test-first-backup-commissioner",
        HERE / "internal_test_first_backup_commissioner.py",
        LIBEXEC_DIR / "internal_test_first_backup_commissioner.py",
        0o755,
    ),
    Asset(
        "repo1-service",
        SYSTEMD_SOURCE / "uten-pgbackup.service.example",
        Path("/etc/systemd/system/uten-pgbackup.service"),
        0o644,
    ),
    Asset(
        "repo1-timer",
        SYSTEMD_SOURCE / "uten-pgbackup.timer.example",
        Path("/etc/systemd/system/uten-pgbackup.timer"),
        0o644,
    ),
    Asset(
        "repo2-service",
        SYSTEMD_SOURCE / "uten-pgbackup-repo2.service.example",
        Path("/etc/systemd/system/uten-pgbackup-repo2.service"),
        0o644,
    ),
    Asset(
        "repo2-timer",
        SYSTEMD_SOURCE / "uten-pgbackup-repo2.timer.example",
        Path("/etc/systemd/system/uten-pgbackup-repo2.timer"),
        0o644,
    ),
    Asset(
        "health-service",
        SYSTEMD_SOURCE / "uten-pgbackup-health.service.example",
        Path("/etc/systemd/system/uten-pgbackup-health.service"),
        0o644,
    ),
    Asset(
        "health-timer",
        SYSTEMD_SOURCE / "uten-pgbackup-health.timer.example",
        Path("/etc/systemd/system/uten-pgbackup-health.timer"),
        0o644,
    ),
    Asset(
        "alert-service",
        SYSTEMD_SOURCE / "uten-pgbackup-alert@.service.example",
        Path("/etc/systemd/system/uten-pgbackup-alert@.service"),
        0o644,
    ),
    Asset(
        "alert-drain-service",
        SYSTEMD_SOURCE / "uten-pgbackup-alert-drain.service.example",
        Path("/etc/systemd/system/uten-pgbackup-alert-drain.service"),
        0o644,
    ),
    Asset(
        "alert-drain-timer",
        SYSTEMD_SOURCE / "uten-pgbackup-alert-drain.timer.example",
        Path("/etc/systemd/system/uten-pgbackup-alert-drain.timer"),
        0o644,
    ),
)

DIRECTORY_TARGETS = (
    (LIBEXEC_DIR, 0, 0, 0o755),
    (MAINTENANCE_DIR, 0, "postgres", 0o750),
    (HEALTH_STATE_DIR, 0, "postgres", 0o770),
    (BACKUP_TRANSACTION_DIR, 0, 0, 0o700),
    (BACKUP_TRANSACTION_RECEIPTS_DIR, 0, 0, 0o700),
    (BACKUP_COMMISSIONER_DIR, 0, 0, 0o700),
    (BACKUP_COMMISSIONER_RECEIPTS_DIR, 0, 0, 0o700),
    (INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR, 0, 0, 0o700),
    (INTERNAL_TEST_FIRST_BACKUP_TRANSACTIONS_DIR, 0, 0, 0o700),
    (INTERNAL_TEST_FIRST_BACKUP_RECEIPTS_DIR, 0, 0, 0o700),
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _bounded_read(path: Path, maximum: int, label: str) -> bytes:
    try:
        details = path.lstat()
    except OSError as exc:
        raise InstallerError(f"{label} cannot be stated: {path}") from exc
    if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1 or path.is_symlink():
        raise InstallerError(f"{label} must be one regular non-symlink file: {path}")
    if details.st_size < 0 or details.st_size > maximum:
        raise InstallerError(f"{label} exceeds its fixed size bound: {path}")
    try:
        value = path.read_bytes()
    except OSError as exc:
        raise InstallerError(f"{label} cannot be read: {path}") from exc
    if len(value) != details.st_size:
        raise InstallerError(f"{label} changed while it was read: {path}")
    return value


def _require_root() -> None:
    if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise InstallerError("the existing-host backup installer requires POSIX root")
    if fcntl is None or pwd is None or grp is None or not hasattr(os, "O_NOFOLLOW"):
        raise InstallerError("the installer requires Linux flock, pwd/grp and O_NOFOLLOW")


def _identity() -> Identity:
    if pwd is None or grp is None:
        raise InstallerError("the fixed postgres identity requires POSIX pwd/grp")
    try:
        account = pwd.getpwnam("postgres")
        group = grp.getgrnam("postgres")
    except KeyError as exc:
        raise InstallerError("the fixed postgres account/group is missing") from exc
    if account.pw_uid == 0 or group.gr_gid == 0 or account.pw_gid != group.gr_gid:
        raise InstallerError("postgres must be a non-root account with its fixed primary group")
    unexpected_members = [member for member in group.gr_mem if member != "postgres"]
    if unexpected_members:
        raise InstallerError("the postgres primary group contains another named member")
    return Identity(account.pw_uid, group.gr_gid)


def _require_safe_directory(path: Path, *, uid: int = 0, gid: int | None = None, mode: int | None = None) -> os.stat_result:
    try:
        details = path.lstat()
    except OSError as exc:
        raise InstallerError(f"required directory cannot be stated: {path}") from exc
    if not stat.S_ISDIR(details.st_mode) or path.is_symlink() or details.st_uid != uid:
        raise InstallerError(f"required directory is symlinked, non-directory or wrong owner: {path}")
    if gid is not None and details.st_gid != gid:
        raise InstallerError(f"required directory has the wrong group: {path}")
    actual_mode = stat.S_IMODE(details.st_mode)
    if mode is not None and actual_mode != mode:
        raise InstallerError(f"required directory has mode {actual_mode:04o}, expected {mode:04o}: {path}")
    if mode is None and actual_mode & 0o022:
        raise InstallerError(f"trusted directory is group/world-writable: {path}")
    return details


def _require_root_parent_chain(path: Path) -> None:
    current = path if path.is_dir() else path.parent
    while True:
        _require_safe_directory(current, uid=0)
        if current == Path("/"):
            return
        current = current.parent


def _safe_source_bytes(asset: Asset) -> bytes:
    source = asset.source
    try:
        resolved = source.resolve(strict=True)
    except OSError as exc:
        raise InstallerError(f"reviewed source is unavailable: {source}") from exc
    if resolved != source:
        raise InstallerError(f"reviewed source path is non-canonical or symlinked: {source}")
    details = source.lstat()
    if (
        not stat.S_ISREG(details.st_mode)
        or details.st_uid != 0
        or details.st_mode & 0o022
        or details.st_nlink != 1
    ):
        raise InstallerError(f"reviewed source must be root-owned, non-writable and single-link: {source}")
    _require_root_parent_chain(source.parent)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if not hasattr(os, "O_NOFOLLOW"):
        raise InstallerError("reviewed source capture requires O_NOFOLLOW")
    flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(source, flags)
    except OSError as exc:
        raise InstallerError(f"reviewed source cannot be stably opened: {source}") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_mode & 0o022
            or opened.st_nlink != 1
            or opened.st_size < 0
            or opened.st_size > MAX_MANAGED_FILE_BYTES
            or (opened.st_dev, opened.st_ino) != (details.st_dev, details.st_ino)
        ):
            raise InstallerError(f"reviewed source changed before stable capture: {source}")
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                raise InstallerError(f"reviewed source truncated during capture: {source}")
            chunks.append(block)
            remaining -= len(block)
        if os.read(descriptor, 1):
            raise InstallerError(f"reviewed source grew during capture: {source}")
        after = source.lstat()
        final = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino, opened.st_size, opened.st_nlink)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_nlink) or identity != (
            final.st_dev,
            final.st_ino,
            final.st_size,
            final.st_nlink,
        ):
            raise InstallerError(f"reviewed source path changed during capture: {source}")
        _require_root_parent_chain(source.parent)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _file_observation(path: Path, *, allow_missing: bool = True) -> dict[str, Any]:
    try:
        details = path.lstat()
    except FileNotFoundError:
        if allow_missing:
            return {"state": "absent"}
        raise InstallerError(f"required managed file is absent: {path}")
    except OSError as exc:
        raise InstallerError(f"managed target cannot be stated: {path}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_mode & 0o022
        or details.st_nlink != 1
    ):
        raise InstallerError(f"managed target is not a safe root-controlled file: {path}")
    raw = _bounded_read(path, MAX_MANAGED_FILE_BYTES, "managed target")
    return {
        "state": "file",
        "sha256": sha256_bytes(raw),
        "size": len(raw),
        "uid": details.st_uid,
        "gid": details.st_gid,
        "mode": stat.S_IMODE(details.st_mode),
        "nlink": details.st_nlink,
    }


def _directory_observation(path: Path, uid: int, gid: int, mode: int) -> dict[str, Any]:
    try:
        details = path.lstat()
    except FileNotFoundError:
        return {"state": "absent"}
    except OSError as exc:
        raise InstallerError(f"managed directory cannot be stated: {path}") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_uid != uid
        or details.st_gid != gid
        or stat.S_IMODE(details.st_mode) != mode
    ):
        raise InstallerError(
            f"managed directory must already be exact or absent: {path} owner={uid}:{gid} mode={mode:04o}"
        )
    return {"state": "directory", "uid": uid, "gid": gid, "mode": mode}


def _maintenance_lock_observation(identity: Identity) -> dict[str, Any]:
    try:
        details = MAINTENANCE_LOCK.lstat()
    except FileNotFoundError:
        return {"state": "absent"}
    except OSError as exc:
        raise InstallerError("database-maintenance lock cannot be stated") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or MAINTENANCE_LOCK.is_symlink()
        or details.st_uid != 0
        or details.st_gid != identity.postgres_gid
        or stat.S_IMODE(details.st_mode) != 0o660
        or details.st_nlink != 1
        or details.st_size != 0
    ):
        raise InstallerError(
            "database-maintenance lock must be root:postgres 0660, empty and single-link"
        )
    return {
        "state": "file",
        "sha256": sha256_bytes(b""),
        "size": 0,
        "uid": 0,
        "gid": identity.postgres_gid,
        "mode": 0o660,
        "nlink": 1,
    }


def _dropin_observation(unit: str) -> list[dict[str, Any]]:
    directory = Path("/etc/systemd/system") / f"{unit}.d"
    if not os.path.lexists(directory):
        return []
    _require_safe_directory(directory, uid=0)
    result: list[dict[str, Any]] = []
    try:
        children = sorted(directory.iterdir(), key=lambda item: item.name)
    except OSError as exc:
        raise InstallerError(f"unit drop-in directory cannot be enumerated: {directory}") from exc
    for child in children:
        if len(result) >= MAX_DROPINS_PER_UNIT:
            raise InstallerError(f"too many managed unit drop-ins to review safely: {unit}")
        if not child.name.endswith(".conf") or "/" in child.name or "\\" in child.name:
            raise InstallerError(f"unexpected object exists in managed drop-in directory: {child}")
        observation = _file_observation(child, allow_missing=False)
        result.append({"path": str(child), **observation})
    return result


CommandRunner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


def _run_read_only(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    if not command or not all(isinstance(item, str) and item for item in command):
        raise InstallerError("an internal fixed read-only command is malformed")
    try:
        return subprocess.run(
            list(command),
            check=False,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
            env={
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            },
        )
    except subprocess.TimeoutExpired as exc:
        raise InstallerError(f"fixed command timed out: {command[0]}") from exc
    except OSError as exc:
        raise InstallerError(f"fixed command could not execute: {command[0]}") from exc


def _parse_properties(raw: str, expected: Iterable[str]) -> dict[str, str]:
    expected_set = set(expected)
    result: dict[str, str] = {}
    for line in raw.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in expected_set or key in result:
            raise InstallerError("systemd property output is malformed or unexpected")
        result[key] = value
    if set(result) != expected_set:
        raise InstallerError("systemd property output is incomplete")
    return result


UNIT_PROPERTIES = (
    "LoadState",
    "ActiveState",
    "SubState",
    "UnitFileState",
    "FragmentPath",
    "DropInPaths",
    "Requires",
    "Requisite",
    "Wants",
    "BindsTo",
    "Upholds",
    "RequiresMountsFor",
    "After",
    "User",
    "Group",
    "ExecStart",
    "Restart",
)


def _unit_observation(
    unit: str,
    runner: CommandRunner,
    *,
    include_exec_start: bool = False,
) -> dict[str, str]:
    if unit not in (*MANAGED_UNITS, POSTGRES_META_UNIT, POSTGRES_INSTANCE_UNIT):
        raise InstallerError(f"unit is outside the fixed observation allowlist: {unit}")
    command = ["/usr/bin/systemctl", "show", unit]
    for property_name in UNIT_PROPERTIES:
        command.append(f"--property={property_name}")
    completed = runner(command)
    if completed.returncode not in (0, 1):
        raise InstallerError(f"systemctl show failed for {unit} with {completed.returncode}")
    parsed = _parse_properties(completed.stdout, UNIT_PROPERTIES)
    exec_start = parsed.pop("ExecStart")
    parsed["ExecStartSha256"] = sha256_bytes(exec_start.encode("utf-8"))
    if include_exec_start:
        parsed["ExecStart"] = exec_start
    return parsed


def _alert_instances(runner: CommandRunner) -> list[dict[str, str]]:
    completed = runner(
        [
            "/usr/bin/systemctl",
            "list-units",
            "--all",
            "--plain",
            "--no-legend",
            "--no-pager",
            "uten-pgbackup-alert@*.service",
        ]
    )
    if completed.returncode != 0:
        raise InstallerError("systemctl could not enumerate backup alert instances")
    result: list[dict[str, str]] = []
    for raw_line in completed.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        columns = line.split(None, 4)
        if len(columns) < 4 or not columns[0].startswith("uten-pgbackup-alert@"):
            raise InstallerError("backup alert instance listing is malformed")
        result.append(
            {
                "unit": columns[0],
                "load": columns[1],
                "active": columns[2],
                "sub": columns[3],
            }
        )
    return sorted(result, key=lambda item: item["unit"])


def _systemd_jobs(runner: CommandRunner) -> list[str]:
    completed = runner(
        ["/usr/bin/systemctl", "list-jobs", "--no-legend", "--plain", "--no-pager"]
    )
    if completed.returncode != 0:
        raise InstallerError("systemctl could not enumerate pending jobs")
    matches: list[str] = []
    for line in completed.stdout.splitlines():
        columns = line.split()
        if len(columns) < 2:
            continue
        unit = columns[1]
        if unit in MANAGED_UNITS or unit.startswith("uten-pgbackup-alert@"):
            matches.append(unit)
    return sorted(set(matches))


def _require_quiescent(
    units: Mapping[str, Mapping[str, str]],
    alert_instances: Sequence[Mapping[str, str]],
    jobs: Sequence[str],
    *,
    installed: bool,
) -> None:
    if set(units) != set(MANAGED_UNITS):
        raise InstallerError("managed systemd observation is incomplete")
    for unit, details in units.items():
        if details.get("ActiveState") != "inactive":
            raise InstallerError(f"managed unit must be inactive before file changes: {unit}")
        state = details.get("UnitFileState", "")
        if unit in TIMER_UNITS:
            allowed = {"disabled"} if installed else {"disabled", "not-found", ""}
            if state not in allowed:
                raise InstallerError(f"managed timer must be disabled: {unit} state={state}")
        elif state in {"enabled", "enabled-runtime", "linked", "linked-runtime", "alias"}:
            raise InstallerError(f"managed job/template unexpectedly has boot enablement: {unit}")
    if alert_instances:
        raise InstallerError("backup alert instances must be absent before installer changes")
    if jobs:
        raise InstallerError(f"managed systemd jobs are pending: {','.join(jobs)}")


def _storage_observation(runner: CommandRunner) -> dict[str, Any]:
    completed = runner(
        [
            "/usr/bin/findmnt",
            "--json",
            "--target",
            "/data",
            "--output",
            "TARGET,SOURCE,FSTYPE,OPTIONS,UUID",
        ]
    )
    if completed.returncode == 1 and not completed.stdout.strip():
        return {"mounted": False}
    if completed.returncode != 0:
        raise InstallerError("findmnt could not inspect the fixed /data target")
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise InstallerError("findmnt returned malformed JSON") from exc
    filesystems = value.get("filesystems") if isinstance(value, dict) else None
    if not isinstance(filesystems, list) or len(filesystems) != 1 or not isinstance(filesystems[0], dict):
        raise InstallerError("findmnt did not return exactly one /data observation")
    item = filesystems[0]
    expected = {"target", "source", "fstype", "options", "uuid"}
    if set(item) != expected or item.get("target") != "/data":
        raise InstallerError("findmnt /data observation has an unexpected schema")
    if not isinstance(item.get("fstype"), str) or not item["fstype"]:
        raise InstallerError("findmnt /data filesystem type is malformed")
    sensitive: dict[str, Any] = {}
    for key in ("source", "options", "uuid"):
        value = item.get(key)
        if value is not None and not isinstance(value, str):
            raise InstallerError(f"findmnt /data {key} is malformed")
        if key == "options":
            # Options are deliberately not hashed: an unknown mount can carry
            # a low-entropy inline password/token, and an unsalted digest would
            # become an offline guessing oracle.  Presence/count are enough to
            # bind the operator's review to a shape change without disclosure.
            count = 0 if value in (None, "") else len(str(value).split(","))
            sensitive["optionsPresent"] = value not in (None, "")
            sensitive["optionCount"] = count
            continue
        encoded = canonical_bytes({"value": value})
        sensitive[f"{key}Sha256"] = sha256_bytes(encoded)
    return {
        "mounted": True,
        "target": "/data",
        "fstype": item["fstype"],
        **sensitive,
    }


def _postgres_listener_observation(runner: CommandRunner) -> dict[str, Any]:
    """Observe TCP/5432 listeners without initiating a database connection."""

    completed = runner(
        [
            "/usr/bin/ss",
            "--no-header",
            "--listening",
            "--tcp",
            "--numeric",
            "sport = :5432",
        ]
    )
    if completed.returncode != 0:
        raise InstallerError("ss could not observe the fixed PostgreSQL TCP port")
    endpoints: list[str] = []
    for raw_line in completed.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        columns = line.split()
        if len(columns) < 5 or columns[0] != "LISTEN":
            raise InstallerError("ss PostgreSQL listener output is malformed")
        endpoints.append(columns[3])
    if len(endpoints) > 16:
        raise InstallerError("too many PostgreSQL TCP listeners were observed")
    canonical_endpoints = canonical_bytes(sorted(endpoints))
    return {
        "tcpPort": 5432,
        "listenerCount": len(endpoints),
        "listenerEndpointsSha256": sha256_bytes(canonical_endpoints),
        "connectionProbePerformed": False,
    }


def _machine_id_digest() -> str:
    try:
        details = Path("/etc/machine-id").lstat()
    except OSError as exc:
        raise InstallerError("machine-id cannot be stated") from exc
    if details.st_uid != 0 or details.st_mode & 0o022:
        raise InstallerError("machine-id must be root-owned and not group/world-writable")
    raw = _bounded_read(Path("/etc/machine-id"), 256, "machine-id")
    normalized = raw.strip()
    if not re.fullmatch(rb"[0-9a-f]{32}", normalized):
        raise InstallerError("machine-id is not canonical")
    return sha256_bytes(normalized)


def _source_observations(assets: Sequence[Asset]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    names: set[str] = set()
    targets: set[Path] = set()
    for asset in assets:
        if asset.name in names or asset.target in targets or not asset.target.is_absolute():
            raise InstallerError("managed asset names/targets are not unique fixed absolute paths")
        names.add(asset.name)
        targets.add(asset.target)
        raw = _safe_source_bytes(asset)
        result.append(
            {
                "name": asset.name,
                "source": str(asset.source),
                "sourceSha256": sha256_bytes(raw),
                "target": str(asset.target),
                "targetMode": asset.mode,
            }
        )
    return result


def build_assessment(
    identity: Identity,
    *,
    assets: Sequence[Asset] = ASSETS,
    runner: CommandRunner = _run_read_only,
) -> dict[str, Any]:
    sources = _source_observations(assets)
    targets = {str(asset.target): _file_observation(asset.target) for asset in assets}
    targets[str(MAINTENANCE_LOCK)] = _maintenance_lock_observation(identity)
    directories: dict[str, Any] = {}
    for path, uid, group, mode in DIRECTORY_TARGETS:
        gid = identity.postgres_gid if group == "postgres" else int(group)
        directories[str(path)] = {
            "desired": {"uid": uid, "gid": gid, "mode": mode},
            "observed": _directory_observation(path, uid, gid, mode),
        }
    units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
    alerts = _alert_instances(runner)
    jobs = _systemd_jobs(runner)
    _require_quiescent(units, alerts, jobs, installed=False)
    dropins = {unit: _dropin_observation(unit) for unit in MANAGED_UNITS}
    if sum(len(items) for items in dropins.values()) > MAX_TOTAL_DROPINS:
        raise InstallerError("too many total managed unit drop-ins to review safely")
    for unit, details in units.items():
        loaded_dropins = {item for item in details.get("DropInPaths", "").split() if item}
        captured_dropins = {item["path"] for item in dropins[unit]}
        if not loaded_dropins.issubset(captured_dropins):
            raise InstallerError(f"unit has a drop-in outside its captured /etc plan: {unit}")
    postgres = {
        POSTGRES_META_UNIT: _unit_observation(POSTGRES_META_UNIT, runner),
        POSTGRES_INSTANCE_UNIT: _unit_observation(POSTGRES_INSTANCE_UNIT, runner),
        "listenerObservation": _postgres_listener_observation(runner),
    }
    return {
        "machineIdSha256": _machine_id_digest(),
        "postgresIdentity": {
            "uid": identity.postgres_uid,
            "gid": identity.postgres_gid,
        },
        "sources": sources,
        "targets": targets,
        "directories": directories,
        "dropins": dropins,
        "systemd": {"units": units, "alertInstances": alerts, "jobs": jobs},
        "postgres": postgres,
        "storage": _storage_observation(runner),
    }


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _rename_noreplace(source: Path, destination: Path) -> None:
    """Atomically publish one same-filesystem path without an overwrite window."""

    if os.name != "posix":
        raise InstallerError("atomic no-replace publication requires Linux renameat2")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
    except (AttributeError, OSError) as exc:
        raise InstallerError("Linux libc renameat2 is unavailable") from exc
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    at_fdcwd = -100
    rename_noreplace = 1
    result = renameat2(
        at_fdcwd,
        os.fsencode(source),
        at_fdcwd,
        os.fsencode(destination),
        rename_noreplace,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        raise FileExistsError(error_number, os.strerror(error_number), destination)
    if error_number == errno.ENOSYS:
        raise InstallerError("the running Linux kernel lacks renameat2(RENAME_NOREPLACE)")
    raise InstallerError(
        f"atomic no-replace publication failed for fixed destination: {destination}"
    )


def _atomic_directory(path: Path, uid: int, gid: int, mode: int) -> bool:
    if os.path.lexists(path):
        _require_safe_directory(path, uid=uid, gid=gid, mode=mode)
        return False
    parent = path.parent
    _require_safe_directory(parent, uid=0)
    temporary = Path(tempfile.mkdtemp(prefix=f".{path.name}.install.", dir=parent))
    try:
        os.chown(temporary, uid, gid)
        temporary.chmod(mode)
        _fsync_directory(temporary)
        try:
            _rename_noreplace(temporary, path)
        except FileExistsError:
            _require_safe_directory(path, uid=uid, gid=gid, mode=mode)
            return False
        _fsync_directory(parent)
        return True
    finally:
        if os.path.lexists(temporary):
            temporary.rmdir()


def _ensure_state_layout() -> None:
    _require_safe_directory(Path("/"), uid=0)
    _require_safe_directory(Path("/var"), uid=0)
    _require_safe_directory(Path("/var/lib"), uid=0)
    _atomic_directory(STATE_ROOT, 0, 0, 0o700)
    for directory in (PLAN_HISTORY_DIR, TRANSACTIONS_DIR, ROLLBACK_RECEIPTS_DIR):
        _atomic_directory(directory, 0, 0, 0o700)


def _atomic_write(
    path: Path,
    payload: bytes,
    *,
    uid: int,
    gid: int,
    mode: int,
    replace: bool,
) -> None:
    _require_safe_directory(path.parent, uid=0)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    temporary = path.parent / f".{path.name}.install.{os.getpid()}.{os.urandom(8).hex()}"
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, mode)
        os.fchown(descriptor, uid, gid)
        os.fchmod(descriptor, mode)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise InstallerError(f"short atomic write: {path}")
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


def _durable_unlink(path: Path) -> None:
    if not os.path.lexists(path):
        return
    path.unlink()
    _fsync_directory(path.parent)


def _load_root_json(path: Path, maximum: int, label: str) -> tuple[dict[str, Any], bytes]:
    raw = _bounded_read(path, maximum, label)
    details = path.lstat()
    if details.st_uid != 0 or details.st_gid != 0 or stat.S_IMODE(details.st_mode) != 0o600:
        raise InstallerError(f"{label} must be root:root 0600")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InstallerError(f"{label} is not canonical JSON") from exc
    if not isinstance(value, dict) or canonical_bytes(value) != raw:
        raise InstallerError(f"{label} bytes are not canonical")
    return value, raw


def _best_effort_evidence_sha256(path: Path, label: str) -> str:
    """Return bounded diagnostics without ever replacing an earlier failure."""

    try:
        if not os.path.lexists(path):
            return "absent"
        _, raw = _load_root_json(path, MAX_RECEIPT_BYTES, label)
        return sha256_bytes(raw)
    except BaseException as exc:  # diagnostic-only, including a second interrupt
        return f"unreadable-{type(exc).__name__}"


class InstallerLock:
    def __init__(self) -> None:
        self.descriptor = -1

    def __enter__(self) -> "InstallerLock":
        _ensure_state_layout()
        flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        self.descriptor = os.open(INSTALLER_LOCK_PATH, flags, 0o600)
        os.fchown(self.descriptor, 0, 0)
        os.fchmod(self.descriptor, 0o600)
        details = os.fstat(self.descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != 0 or details.st_gid != 0 or details.st_nlink != 1:
            os.close(self.descriptor)
            self.descriptor = -1
            raise InstallerError("installer lock is not one root-owned regular file")
        assert fcntl is not None
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(self.descriptor)
            self.descriptor = -1
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                raise InstallerError("another backup installer operation is running") from exc
            raise InstallerError("installer lock could not be acquired") from exc
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            assert fcntl is not None
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


def _archive_existing_plan() -> None:
    if not os.path.lexists(PLAN_PATH):
        return
    _, raw = _load_root_json(PLAN_PATH, MAX_PLAN_BYTES, "existing install plan")
    digest = sha256_bytes(raw)
    destination = PLAN_HISTORY_DIR / f"{digest}.json"
    if os.path.lexists(destination):
        _, existing = _load_root_json(destination, MAX_PLAN_BYTES, "archived install plan")
        if existing != raw:
            raise InstallerError("archived plan digest collision")
        return
    _atomic_write(destination, raw, uid=0, gid=0, mode=0o600, replace=False)


def _require_no_installer_transaction() -> None:
    if os.path.lexists(STATE_ROOT):
        _require_safe_directory(STATE_ROOT, uid=0, gid=0, mode=0o700)
    if os.path.lexists(ACTIVE_TRANSACTION_PATH):
        raise InstallerError("an interrupted installer transaction requires evidence-bound rollback")
    if os.path.lexists(UNCOMMISSIONED_RECEIPT_PATH):
        raise InstallerError("an uncommissioned installation already exists; commission or rollback it")
    if os.path.lexists(COMMISSIONED_MARKER_PATH):
        raise InstallerError("the backup runtime is already marked commissioned")


def assess(
    *,
    identity: Identity | None = None,
    assets: Sequence[Asset] = ASSETS,
    runner: CommandRunner = _run_read_only,
) -> tuple[dict[str, Any], str]:
    _require_root()
    selected_identity = identity or _identity()
    _require_no_installer_transaction()
    assessment = build_assessment(selected_identity, assets=assets, runner=runner)
    assessment_sha256 = sha256_bytes(canonical_bytes(assessment))
    envelope = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "uten-imp-existing-backup-read-only-assessment",
        "assessmentSha256": assessment_sha256,
        "assessment": assessment,
    }
    return envelope, assessment_sha256


def record_plan(
    *,
    expected_assessment_sha256: str,
    confirmation: str,
    identity: Identity | None = None,
    assets: Sequence[Asset] = ASSETS,
    runner: CommandRunner = _run_read_only,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if not SHA256_RE.fullmatch(expected_assessment_sha256):
        raise InstallerError("--expected-assessment-sha256 must be 64 lowercase hex")
    if confirmation != RECORD_CONFIRMATION:
        raise InstallerError(f"--confirm must exactly equal: {RECORD_CONFIRMATION}")
    _require_no_installer_transaction()
    with InstallerLock():
        _require_no_installer_transaction()
        # Identity is part of the approved observation.  Resolve it only after
        # the writer lock is held so two administrators cannot interleave an
        # account/assessment observation with fixed-plan publication.
        selected_identity = identity or _identity()
        assessment = build_assessment(selected_identity, assets=assets, runner=runner)
        actual_assessment_sha256 = sha256_bytes(canonical_bytes(assessment))
        if actual_assessment_sha256 != expected_assessment_sha256:
            raise InstallerError("read-only assessment changed after approval; run assess and review again")
        plan = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": PLAN_KIND,
            "recordedAtUtc": _utc_now(),
            "assessmentSha256": actual_assessment_sha256,
            "assessment": assessment,
        }
        raw = canonical_bytes(plan)
        _archive_existing_plan()
        _atomic_write(PLAN_PATH, raw, uid=0, gid=0, mode=0o600, replace=True)
    return plan, sha256_bytes(raw)


def _validate_plan(value: dict[str, Any], raw: bytes, expected_sha256: str) -> dict[str, Any]:
    if not SHA256_RE.fullmatch(expected_sha256) or sha256_bytes(raw) != expected_sha256:
        raise InstallerError("fixed plan SHA-256 differs from --expected-plan-sha256")
    if set(value) != {
        "schemaVersion",
        "kind",
        "recordedAtUtc",
        "assessmentSha256",
        "assessment",
    }:
        raise InstallerError("install plan schema differs from the reviewed schema")
    if value.get("schemaVersion") != SCHEMA_VERSION or value.get("kind") != PLAN_KIND:
        raise InstallerError("install plan kind/version is unsupported")
    assessment = value.get("assessment")
    if not isinstance(assessment, dict):
        raise InstallerError("install plan assessment is malformed")
    assessment_sha = value.get("assessmentSha256")
    if not isinstance(assessment_sha, str) or sha256_bytes(canonical_bytes(assessment)) != assessment_sha:
        raise InstallerError("install plan assessment digest is inconsistent")
    return assessment


def _expected_directory_specs(identity: Identity) -> dict[str, tuple[int, int, int]]:
    return {
        str(LIBEXEC_DIR): (0, 0, 0o755),
        str(MAINTENANCE_DIR): (0, identity.postgres_gid, 0o750),
        str(HEALTH_STATE_DIR): (0, identity.postgres_gid, 0o770),
        str(BACKUP_TRANSACTION_DIR): (0, 0, 0o700),
        str(BACKUP_TRANSACTION_RECEIPTS_DIR): (0, 0, 0o700),
        str(BACKUP_COMMISSIONER_DIR): (0, 0, 0o700),
        str(BACKUP_COMMISSIONER_RECEIPTS_DIR): (0, 0, 0o700),
        str(INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR): (0, 0, 0o700),
        str(INTERNAL_TEST_FIRST_BACKUP_TRANSACTIONS_DIR): (0, 0, 0o700),
        str(INTERNAL_TEST_FIRST_BACKUP_RECEIPTS_DIR): (0, 0, 0o700),
    }


def _asset_payloads(
    plan_assessment: Mapping[str, Any], assets: Sequence[Asset]
) -> dict[str, tuple[Asset, bytes]]:
    planned_sources = plan_assessment.get("sources")
    if not isinstance(planned_sources, list):
        raise InstallerError("plan source inventory is malformed")
    by_name = {
        item.get("name"): item
        for item in planned_sources
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    if set(by_name) != {asset.name for asset in assets}:
        raise InstallerError("plan source inventory differs from the fixed installer assets")
    result: dict[str, tuple[Asset, bytes]] = {}
    for asset in assets:
        planned = by_name[asset.name]
        expected = {
            "name": asset.name,
            "source": str(asset.source),
            "target": str(asset.target),
            "targetMode": asset.mode,
        }
        if any(planned.get(key) != value for key, value in expected.items()):
            raise InstallerError(f"plan path/mode differs for fixed asset: {asset.name}")
        raw = _safe_source_bytes(asset)
        if planned.get("sourceSha256") != sha256_bytes(raw):
            raise InstallerError(f"reviewed source bytes changed after plan recording: {asset.name}")
        result[str(asset.target)] = (asset, raw)
    return result


def _validate_transaction_inventory(
    record: Mapping[str, Any],
    *,
    plan_assessment: Mapping[str, Any],
    assets: Sequence[Asset],
    identity: Identity,
) -> None:
    """Bind every rollback path and mutation to the fixed recorded plan."""

    plan_sha = record.get("planSha256")
    transaction_value = record.get("transactionPath")
    if not isinstance(plan_sha, str) or not isinstance(transaction_value, str):
        raise InstallerError("transaction identity is malformed")
    transaction = _transaction_path(plan_sha)
    if Path(transaction_value) != transaction:
        raise InstallerError("transaction directory escapes the fixed evidence root")
    if plan_assessment.get("postgresIdentity") != {
        "uid": identity.postgres_uid,
        "gid": identity.postgres_gid,
    }:
        raise InstallerError("transaction plan postgres identity differs from the host")

    directories = plan_assessment.get("directories")
    expected_specs = _expected_directory_specs(identity)
    if not isinstance(directories, dict) or set(directories) != set(expected_specs):
        raise InstallerError("transaction plan directory inventory differs from fixed targets")
    expected_created: list[str] = []
    for path_string, (uid, gid, mode) in expected_specs.items():
        value = directories.get(path_string)
        if not isinstance(value, dict) or value.get("desired") != {
            "uid": uid,
            "gid": gid,
            "mode": mode,
        }:
            raise InstallerError(f"transaction plan directory metadata differs: {path_string}")
        observed = value.get("observed")
        if not isinstance(observed, dict) or observed.get("state") not in {"absent", "directory"}:
            raise InstallerError(f"transaction plan directory state is malformed: {path_string}")
        if observed.get("state") == "absent":
            expected_created.append(path_string)
    if record.get("directories") != directories or record.get("createdDirectories") != sorted(
        expected_created
    ):
        raise InstallerError("transaction directory rollback inventory differs from the plan")
    if record.get("originalSystemd") != plan_assessment.get("systemd"):
        raise InstallerError("transaction original systemd evidence differs from the plan")

    sources = plan_assessment.get("sources")
    targets = plan_assessment.get("targets")
    dropins = plan_assessment.get("dropins")
    files = record.get("files")
    if (
        not isinstance(sources, list)
        or not isinstance(targets, dict)
        or not isinstance(dropins, dict)
        or not isinstance(files, list)
    ):
        raise InstallerError("transaction file/source/drop-in inventories are malformed")
    source_by_name: dict[str, Mapping[str, Any]] = {}
    for source in sources:
        if not isinstance(source, dict) or not isinstance(source.get("name"), str):
            raise InstallerError("transaction plan source entry is malformed")
        if source["name"] in source_by_name:
            raise InstallerError("transaction plan source names are duplicated")
        source_by_name[source["name"]] = source
    if set(source_by_name) != {asset.name for asset in assets}:
        raise InstallerError("transaction plan sources differ from fixed assets")
    expected_target_paths = {str(asset.target) for asset in assets} | {str(MAINTENANCE_LOCK)}
    if set(targets) != expected_target_paths or set(dropins) != set(MANAGED_UNITS):
        raise InstallerError("transaction plan targets/drop-in units differ from fixed scope")

    expected_records: list[tuple[str, Mapping[str, Any], Mapping[str, Any]]] = []
    for asset in assets:
        source = source_by_name[asset.name]
        expected_source = {
            "name": asset.name,
            "source": str(asset.source),
            "target": str(asset.target),
            "targetMode": asset.mode,
        }
        if any(source.get(key) != value for key, value in expected_source.items()):
            raise InstallerError(f"transaction plan source path/mode differs: {asset.name}")
        digest = source.get("sourceSha256")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise InstallerError(f"transaction plan source digest is malformed: {asset.name}")
        original = targets[str(asset.target)]
        if not isinstance(original, dict):
            raise InstallerError(f"transaction plan target observation is malformed: {asset.target}")
        expected_records.append(
            (
                str(asset.target),
                original,
                {
                    "state": "file",
                    "sha256": digest,
                    "uid": 0,
                    "gid": 0,
                    "mode": asset.mode,
                },
            )
        )

    lock_original = targets[str(MAINTENANCE_LOCK)]
    if not isinstance(lock_original, dict):
        raise InstallerError("transaction plan maintenance lock observation is malformed")
    expected_records.append(
        (
            str(MAINTENANCE_LOCK),
            lock_original,
            {
                "state": "file",
                "sha256": sha256_bytes(b""),
                "uid": 0,
                "gid": identity.postgres_gid,
                "mode": 0o660,
            },
        )
    )

    total_dropins = 0
    for unit in MANAGED_UNITS:
        unit_dropins = dropins.get(unit)
        if not isinstance(unit_dropins, list) or len(unit_dropins) > MAX_DROPINS_PER_UNIT:
            raise InstallerError(f"transaction plan drop-in count is unsafe: {unit}")
        total_dropins += len(unit_dropins)
        for item in unit_dropins:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                raise InstallerError(f"transaction plan drop-in entry is malformed: {unit}")
            path = Path(item["path"])
            if (
                path.parent != Path("/etc/systemd/system") / f"{unit}.d"
                or not path.name.endswith(".conf")
                or path.name in {"", ".", ".."}
            ):
                raise InstallerError(f"transaction plan drop-in escapes fixed scope: {path}")
            original = {key: value for key, value in item.items() if key != "path"}
            expected_records.append((str(path), original, {"state": "absent"}))
    if total_dropins > MAX_TOTAL_DROPINS:
        raise InstallerError("transaction plan total drop-in count is unsafe")
    if len(files) != len(expected_records):
        raise InstallerError("transaction rollback file inventory is incomplete")

    seen_paths: set[str] = set()
    for index, (file_record, expected) in enumerate(zip(files, expected_records)):
        if not isinstance(file_record, dict):
            raise InstallerError("transaction rollback file entry is malformed")
        expected_path, expected_original, expected_mutation = expected
        if expected_path in seen_paths:
            raise InstallerError("transaction rollback paths are duplicated")
        seen_paths.add(expected_path)
        if (
            file_record.get("path") != expected_path
            or file_record.get("original") != expected_original
            or file_record.get("mutation") != expected_mutation
        ):
            raise InstallerError(f"transaction rollback entry differs from plan: {expected_path}")
        original_state = expected_original.get("state")
        if original_state == "absent":
            if set(file_record) != {"path", "original", "preimage", "mutation"}:
                raise InstallerError(f"absent rollback entry has unexpected fields: {expected_path}")
            if file_record.get("preimage") is not None:
                raise InstallerError(f"absent rollback entry unexpectedly has a preimage: {expected_path}")
        elif original_state == "file":
            if set(file_record) != {
                "path",
                "original",
                "preimage",
                "preimageSha256",
                "mutation",
            }:
                raise InstallerError(f"file rollback entry has unexpected fields: {expected_path}")
            expected_preimage = transaction / "preimages" / f"{index:03d}.bin"
            if (
                file_record.get("preimage") != str(expected_preimage)
                or file_record.get("preimageSha256") != expected_original.get("sha256")
            ):
                raise InstallerError(f"rollback preimage is not plan-bound: {expected_path}")
        else:
            raise InstallerError(f"rollback original state is unsupported: {expected_path}")


def _transaction_path(plan_sha256: str) -> Path:
    if not SHA256_RE.fullmatch(plan_sha256):
        raise InstallerError("transaction plan digest is malformed")
    return TRANSACTIONS_DIR / plan_sha256


def _capture_file_preimage(path: Path, observation: Mapping[str, Any], destination: Path) -> dict[str, Any]:
    state = observation.get("state")
    if state == "absent":
        if os.path.lexists(path):
            raise InstallerError(f"target appeared after assessment: {path}")
        return {"path": str(path), "original": dict(observation), "preimage": None}
    if state != "file" or _file_observation(path, allow_missing=False) != dict(observation):
        raise InstallerError(f"target changed after assessment: {path}")
    raw = _bounded_read(path, MAX_MANAGED_FILE_BYTES, "preimage source")
    _atomic_write(destination, raw, uid=0, gid=0, mode=0o600, replace=False)
    return {
        "path": str(path),
        "original": dict(observation),
        "preimage": str(destination),
        "preimageSha256": sha256_bytes(raw),
    }


def _prepare_transaction(
    *,
    plan_sha256: str,
    plan_assessment: Mapping[str, Any],
    assets: Sequence[Asset],
) -> tuple[Path, dict[str, Any]]:
    transaction = _transaction_path(plan_sha256)
    if os.path.lexists(transaction):
        raise InstallerError("a transaction already exists for this plan digest")
    planned_targets = plan_assessment.get("targets")
    planned_dropins = plan_assessment.get("dropins")
    directory_records = plan_assessment.get("directories")
    if (
        not isinstance(planned_targets, dict)
        or not isinstance(planned_dropins, dict)
        or not isinstance(directory_records, dict)
    ):
        raise InstallerError("plan target/drop-in/directory inventories are malformed")
    created_directories = sorted(
        path
        for path, details in directory_records.items()
        if isinstance(details, dict)
        and isinstance(details.get("observed"), dict)
        and details["observed"].get("state") == "absent"
    )
    bootstrap_record = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": TRANSACTION_KIND,
        "planSha256": plan_sha256,
        "transactionPath": str(transaction),
        "phase": "preparing-preimages",
        "createdAtUtc": _utc_now(),
        "files": [],
        "directories": directory_records,
        "createdDirectories": created_directories,
        "originalSystemd": plan_assessment.get("systemd"),
    }
    _atomic_write(
        ACTIVE_TRANSACTION_PATH,
        canonical_bytes(bootstrap_record),
        uid=0,
        gid=0,
        mode=0o600,
        replace=False,
    )
    _atomic_directory(transaction, 0, 0, 0o700)
    preimages = transaction / "preimages"
    _atomic_directory(preimages, 0, 0, 0o700)
    records: list[dict[str, Any]] = []
    paths: set[str] = set()
    for index, asset in enumerate(assets):
        path_string = str(asset.target)
        if path_string not in planned_targets:
            raise InstallerError(f"plan lacks target preimage: {path_string}")
        record = _capture_file_preimage(
            asset.target, planned_targets[path_string], preimages / f"{index:03d}.bin"
        )
        record["mutation"] = {
            "state": "file",
            "sha256": next(
                item["sourceSha256"]
                for item in plan_assessment["sources"]
                if item["target"] == path_string
            ),
            "uid": 0,
            "gid": 0,
            "mode": asset.mode,
        }
        records.append(record)
        paths.add(path_string)
    lock_string = str(MAINTENANCE_LOCK)
    lock_observation = planned_targets.get(lock_string)
    if not isinstance(lock_observation, dict):
        raise InstallerError("plan lacks database-maintenance lock preimage")
    identity_value = plan_assessment.get("postgresIdentity")
    if not isinstance(identity_value, dict) or not isinstance(identity_value.get("gid"), int):
        raise InstallerError("plan postgres identity is malformed")
    lock_identity = Identity(
        int(identity_value.get("uid", -1)), int(identity_value["gid"])
    )
    current_lock = _maintenance_lock_observation(lock_identity)
    if current_lock != lock_observation:
        raise InstallerError("database-maintenance lock changed after assessment")
    if lock_observation.get("state") == "file":
        lock_preimage = preimages / f"{len(records):03d}.bin"
        _atomic_write(lock_preimage, b"", uid=0, gid=0, mode=0o600, replace=False)
        lock_record = {
            "path": lock_string,
            "original": dict(lock_observation),
            "preimage": str(lock_preimage),
            "preimageSha256": sha256_bytes(b""),
        }
    elif lock_observation.get("state") == "absent":
        lock_record = {
            "path": lock_string,
            "original": dict(lock_observation),
            "preimage": None,
        }
    else:
        raise InstallerError("database-maintenance lock preimage state is malformed")
    lock_record["mutation"] = {
        "state": "file",
        "sha256": sha256_bytes(b""),
        "uid": 0,
        "gid": identity_value["gid"],
        "mode": 0o660,
    }
    records.append(lock_record)
    paths.add(lock_string)
    for unit in MANAGED_UNITS:
        items = planned_dropins.get(unit)
        if not isinstance(items, list):
            raise InstallerError(f"plan drop-in inventory is malformed: {unit}")
        for item in items:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                raise InstallerError(f"plan drop-in entry is malformed: {unit}")
            path = Path(item["path"])
            expected_parent = Path("/etc/systemd/system") / f"{unit}.d"
            if path.parent != expected_parent or path.name in {"", ".", ".."}:
                raise InstallerError(f"plan drop-in path escapes the fixed unit directory: {path}")
            if str(path) in paths:
                raise InstallerError("plan contains a duplicate managed/preimage path")
            observation = {key: value for key, value in item.items() if key != "path"}
            record = _capture_file_preimage(
                path, observation, preimages / f"{len(records):03d}.bin"
            )
            record["mutation"] = {"state": "absent"}
            records.append(record)
            paths.add(str(path))
    transaction_record = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": TRANSACTION_KIND,
        "planSha256": plan_sha256,
        "transactionPath": str(transaction),
        "phase": "prepared",
        "createdAtUtc": _utc_now(),
        "files": records,
        "directories": directory_records,
        "createdDirectories": created_directories,
        "originalSystemd": plan_assessment.get("systemd"),
    }
    _validate_transaction_inventory(
        transaction_record,
        plan_assessment=plan_assessment,
        assets=assets,
        identity=lock_identity,
    )
    raw = canonical_bytes(transaction_record)
    _atomic_write(transaction / "transaction.json", raw, uid=0, gid=0, mode=0o600, replace=False)
    _atomic_write(ACTIVE_TRANSACTION_PATH, raw, uid=0, gid=0, mode=0o600, replace=True)
    return transaction, transaction_record


class DatabaseMaintenanceLock:
    def __init__(self, identity: Identity) -> None:
        self.identity = identity
        self.descriptor = -1

    def __enter__(self) -> "DatabaseMaintenanceLock":
        observation = _maintenance_lock_observation(self.identity)
        if observation.get("state") != "file":
            raise InstallerError("database-maintenance lock was not installed before acquisition")
        self.descriptor = os.open(
            MAINTENANCE_LOCK,
            os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
        )
        details = os.fstat(self.descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != self.identity.postgres_gid
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
        ):
            os.close(self.descriptor)
            self.descriptor = -1
            raise InstallerError("database-maintenance lock changed before acquisition")
        assert fcntl is not None
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(self.descriptor)
            self.descriptor = -1
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                raise InstallerError("database maintenance is already in progress") from exc
            raise InstallerError("database-maintenance lock could not be acquired") from exc
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            assert fcntl is not None
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


def _create_planned_directories(
    plan_assessment: Mapping[str, Any], identity: Identity
) -> list[str]:
    planned = plan_assessment.get("directories")
    if not isinstance(planned, dict):
        raise InstallerError("plan directory inventory is malformed")
    created: list[str] = []
    for path_string, (uid, gid, mode) in _expected_directory_specs(identity).items():
        item = planned.get(path_string)
        desired = {"uid": uid, "gid": gid, "mode": mode}
        if not isinstance(item, dict) or item.get("desired") != desired:
            raise InstallerError(f"plan directory desired state differs: {path_string}")
        path = Path(path_string)
        observed = item.get("observed")
        if not isinstance(observed, dict):
            raise InstallerError(f"plan directory observation is malformed: {path_string}")
        if _directory_observation(path, uid, gid, mode) != observed:
            raise InstallerError(f"managed directory changed after assessment: {path_string}")
        if _atomic_directory(path, uid, gid, mode):
            created.append(path_string)
    return created


def _install_maintenance_lock(identity: Identity, original: Mapping[str, Any]) -> bool:
    current = _maintenance_lock_observation(identity)
    if current != dict(original):
        raise InstallerError("database-maintenance lock changed before installation")
    if current.get("state") == "file":
        return False
    _atomic_write(
        MAINTENANCE_LOCK,
        b"",
        uid=0,
        gid=identity.postgres_gid,
        mode=0o660,
        replace=False,
    )
    if _maintenance_lock_observation(identity).get("state") != "file":
        raise InstallerError("database-maintenance lock installation did not verify")
    return True


def _remove_captured_dropins(record: Mapping[str, Any]) -> None:
    path = Path(str(record["path"]))
    original = record.get("original")
    mutation = record.get("mutation")
    if not isinstance(original, dict) or mutation != {"state": "absent"}:
        return
    if _file_observation(path, allow_missing=False) != original:
        raise InstallerError(f"unit drop-in changed before removal: {path}")
    path.unlink()
    _fsync_directory(path.parent)


def _daemon_reload(runner: CommandRunner) -> None:
    completed = runner(["/usr/bin/systemctl", "daemon-reload"])
    if completed.returncode != 0:
        raise InstallerError("systemctl daemon-reload failed")


def _systemd_verify(assets: Sequence[Asset], runner: CommandRunner) -> None:
    unit_paths = [str(asset.target) for asset in assets if asset.target.parent == Path("/etc/systemd/system")]
    completed = runner(["/usr/bin/systemd-analyze", "verify", *unit_paths])
    if completed.returncode != 0:
        raise InstallerError("systemd-analyze verify rejected the installed backup units")


EXECSTART_NEEDLES = {
    "uten-pgbackup.service": "/usr/local/libexec/uten-imp-backup/locked_job.py repo1",
    "uten-pgbackup-repo2.service": "/usr/local/libexec/uten-imp-backup/locked_job.py repo2",
    "uten-pgbackup-health.service": "/usr/local/libexec/uten-imp-backup/locked_job.py health",
    "uten-pgbackup-alert@.service": "/usr/local/libexec/uten-imp-backup/backup_alert.py emit",
    "uten-pgbackup-alert-drain.service": "/usr/local/libexec/uten-imp-backup/backup_alert.py drain",
}


def _validate_loaded_contract(
    *,
    assets: Sequence[Asset],
    runner: CommandRunner,
) -> dict[str, Any]:
    units = {
        unit: _unit_observation(unit, runner, include_exec_start=True)
        for unit in MANAGED_UNITS
    }
    alerts = _alert_instances(runner)
    jobs = _systemd_jobs(runner)
    _require_quiescent(units, alerts, jobs, installed=True)
    target_by_unit = {
        asset.target.name: asset.target
        for asset in assets
        if asset.target.parent == Path("/etc/systemd/system")
    }
    if set(target_by_unit) != set(MANAGED_UNITS):
        raise InstallerError("fixed unit asset inventory is incomplete")
    for unit, details in units.items():
        target = target_by_unit[unit]
        if details.get("LoadState") != "loaded" or details.get("FragmentPath") != str(target):
            raise InstallerError(f"systemd did not load the exact managed fragment: {unit}")
        if details.get("DropInPaths"):
            raise InstallerError(f"managed unit still has a loaded drop-in: {unit}")
        if unit in EXECSTART_NEEDLES:
            if details.get("User") != "root" or details.get("Group") != "root":
                raise InstallerError(f"managed service identity differs from root supervisor: {unit}")
            if EXECSTART_NEEDLES[unit] not in details.get("ExecStart", ""):
                raise InstallerError(f"managed service ExecStart differs: {unit}")
    for unit in MANAGED_UNITS:
        details = units[unit]
        dependencies = " ".join(
            details.get(name, "")
            for name in (
                "Requires",
                "Requisite",
                "Wants",
                "BindsTo",
                "Upholds",
                "RequiresMountsFor",
            )
        )
        if (
            POSTGRES_META_UNIT in dependencies
            or POSTGRES_INSTANCE_UNIT in dependencies
            or "data.mount" in dependencies
            or "/data" in dependencies
        ):
            raise InstallerError(f"managed unit still pulls PostgreSQL or /data: {unit}")
    for unit in (
        "uten-pgbackup.service",
        "uten-pgbackup-repo2.service",
        "uten-pgbackup-health.service",
    ):
        details = units[unit]
        if POSTGRES_INSTANCE_UNIT not in details.get("After", "").split():
            raise InstallerError(f"managed backup unit lacks PostgreSQL ordering: {unit}")
    for unit in ("uten-pgbackup.service", "uten-pgbackup-repo2.service"):
        if units[unit].get("Restart") != "on-failure":
            raise InstallerError(f"daily backup unit lacks bounded retry semantics: {unit}")
    if units["uten-pgbackup-health.service"].get("Restart") not in ("no", ""):
        raise InstallerError("health service must rely on its timer, not service restart")
    for asset in assets:
        observation = _file_observation(asset.target, allow_missing=False)
        source_raw = _safe_source_bytes(asset)
        if (
            observation.get("sha256") != sha256_bytes(source_raw)
            or observation.get("uid") != 0
            or observation.get("gid") != 0
            or observation.get("mode") != asset.mode
        ):
            raise InstallerError(f"installed asset bytes/metadata differ: {asset.name}")
    return {"units": units, "alertInstances": alerts, "jobs": jobs}


def _update_transaction(transaction: Path, value: dict[str, Any]) -> None:
    raw = canonical_bytes(value)
    _atomic_write(transaction / "transaction.json", raw, uid=0, gid=0, mode=0o600, replace=True)
    _atomic_write(ACTIVE_TRANSACTION_PATH, raw, uid=0, gid=0, mode=0o600, replace=True)


def _transition_transaction(
    transaction: Path,
    value: dict[str, Any],
    phase: str,
    **evidence: Any,
) -> None:
    value["phase"] = phase
    value.update(evidence)
    _update_transaction(transaction, value)


def _current_matches_mutation(path: Path, mutation: Mapping[str, Any]) -> bool:
    if mutation.get("state") == "absent":
        return not os.path.lexists(path)
    if mutation.get("state") != "file":
        return False
    try:
        if path == MAINTENANCE_LOCK:
            details = path.lstat()
            return (
                stat.S_ISREG(details.st_mode)
                and details.st_uid == mutation.get("uid")
                and details.st_gid == mutation.get("gid")
                and stat.S_IMODE(details.st_mode) == mutation.get("mode")
                and details.st_nlink == 1
                and details.st_size == 0
            )
        observed = _file_observation(path, allow_missing=False)
    except InstallerError:
        return False
    return all(observed.get(key) == mutation.get(key) for key in ("state", "sha256", "uid", "gid", "mode"))


def _restore_file_record(record: Mapping[str, Any]) -> None:
    path = Path(str(record.get("path", "")))
    original = record.get("original")
    mutation = record.get("mutation")
    if not path.is_absolute() or not isinstance(original, dict) or not isinstance(mutation, dict):
        raise InstallerError("transaction file record is malformed")
    original_state = original.get("state")
    if original_state == "absent":
        if not os.path.lexists(path):
            return
        if not _current_matches_mutation(path, mutation):
            raise InstallerError(f"refusing rollback over unexpected target bytes: {path}")
        path.unlink()
        _fsync_directory(path.parent)
        return
    if original_state != "file":
        raise InstallerError(f"transaction original state is unsupported: {path}")
    if os.path.lexists(path):
        current_is_original = False
        try:
            if path == MAINTENANCE_LOCK:
                current_is_original = _current_matches_mutation(path, original)
            else:
                current_is_original = _file_observation(path, allow_missing=False) == original
        except InstallerError:
            current_is_original = False
        if not current_is_original and not _current_matches_mutation(path, mutation):
            raise InstallerError(f"refusing rollback over unexpected target bytes: {path}")
        if current_is_original:
            return
    preimage_value = record.get("preimage")
    if not isinstance(preimage_value, str):
        raise InstallerError(f"transaction preimage path is missing: {path}")
    preimage = Path(preimage_value)
    raw = _bounded_read(preimage, MAX_MANAGED_FILE_BYTES, "transaction preimage")
    if sha256_bytes(raw) != record.get("preimageSha256") or sha256_bytes(raw) != original.get("sha256"):
        raise InstallerError(f"transaction preimage digest differs: {path}")
    _atomic_write(
        path,
        raw,
        uid=int(original["uid"]),
        gid=int(original["gid"]),
        mode=int(original["mode"]),
        replace=True,
    )


def _remove_created_directories(
    created: Sequence[str], identity: Identity
) -> None:
    specs = _expected_directory_specs(identity)
    for path_string in reversed(tuple(created)):
        if path_string not in specs:
            raise InstallerError("transaction contains an unexpected created directory")
        path = Path(path_string)
        uid, gid, mode = specs[path_string]
        if not os.path.lexists(path):
            continue
        _require_safe_directory(path, uid=uid, gid=gid, mode=mode)
        try:
            path.rmdir()
        except OSError as exc:
            raise InstallerError(f"created directory is not empty during rollback: {path}") from exc
        _fsync_directory(path.parent)


def _restore_transaction(
    transaction: Path,
    record: dict[str, Any],
    identity: Identity,
    runner: CommandRunner,
) -> dict[str, Any]:
    files = record.get("files")
    created = record.get("createdDirectories", [])
    if not isinstance(files, list) or not isinstance(created, list):
        raise InstallerError("transaction restore inventory is malformed")
    maintenance_records = [
        item
        for item in files
        if isinstance(item, dict) and item.get("path") == str(MAINTENANCE_LOCK)
    ]
    if len(maintenance_records) != 1:
        raise InstallerError("transaction must contain exactly one maintenance-lock record")
    maintenance_record = maintenance_records[0]
    _transition_transaction(transaction, record, "rollback-files-pending")
    for file_record in reversed(files):
        if not isinstance(file_record, dict):
            raise InstallerError("transaction file restore entry is malformed")
        if file_record is maintenance_record:
            # Keep the named lock inode present until all runtime/unit restore
            # and loaded-state verification is finished.  Unlinking it while
            # its descriptor is flocked would allow a second inode/lock to be
            # created and a concurrent database transaction to overlap.
            continue
        preimage_value = file_record.get("preimage")
        if preimage_value is not None:
            preimage = Path(str(preimage_value))
            if (
                preimage.parent != transaction / "preimages"
                or not re.fullmatch(r"[0-9]{3}\.bin", preimage.name)
            ):
                raise InstallerError("transaction preimage path escapes its fixed directory")
        _restore_file_record(file_record)
    non_maintenance_directories = [
        item for item in created if item != str(MAINTENANCE_DIR)
    ]
    _remove_created_directories(non_maintenance_directories, identity)
    _transition_transaction(transaction, record, "rollback-daemon-reload-pending")
    _daemon_reload(runner)
    _transition_transaction(transaction, record, "rollback-daemon-reloaded")
    original_systemd = record.get("originalSystemd")
    if not isinstance(original_systemd, dict):
        raise InstallerError("transaction original systemd evidence is malformed")
    _verify_original_systemd(original_systemd, runner)
    _transition_transaction(transaction, record, "rollback-loaded-verified")
    _transition_transaction(transaction, record, "rollback-maintenance-lock-pending")
    _restore_file_record(maintenance_record)
    if str(MAINTENANCE_DIR) in created:
        _remove_created_directories([str(MAINTENANCE_DIR)], identity)
    _transition_transaction(
        transaction,
        record,
        "rolled-back",
        rolledBackAtUtc=_utc_now(),
    )
    return record


def _verify_original_systemd(
    original: Mapping[str, Any], runner: CommandRunner
) -> None:
    units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
    alerts = _alert_instances(runner)
    jobs = _systemd_jobs(runner)
    _require_quiescent(units, alerts, jobs, installed=False)
    if original != {"units": units, "alertInstances": alerts, "jobs": jobs}:
        raise InstallerError("systemd loaded state differs after rollback")


def _assert_fixed_plan_argument(path: Path) -> None:
    if path != PLAN_PATH:
        raise InstallerError(f"--plan must exactly equal the fixed path: {PLAN_PATH}")


def _load_transaction(path: Path) -> tuple[dict[str, Any], bytes]:
    value, raw = _load_root_json(path, MAX_RECEIPT_BYTES, "installer transaction evidence")
    if value.get("schemaVersion") != SCHEMA_VERSION or value.get("kind") != TRANSACTION_KIND:
        raise InstallerError("installer transaction evidence has an unsupported kind/version")
    transaction_value = value.get("transactionPath")
    plan_sha = value.get("planSha256")
    if not isinstance(transaction_value, str) or not isinstance(plan_sha, str):
        raise InstallerError("installer transaction identity is malformed")
    transaction = Path(transaction_value)
    if transaction != _transaction_path(plan_sha):
        raise InstallerError("installer transaction path is not bound to its plan digest")
    return value, raw


def _require_same_transaction_scope(
    first: Mapping[str, Any],
    second: Mapping[str, Any],
    *,
    include_files: bool,
) -> None:
    keys = [
        "schemaVersion",
        "kind",
        "planSha256",
        "transactionPath",
        "directories",
        "createdDirectories",
        "originalSystemd",
    ]
    if include_files:
        keys.append("files")
    if any(first.get(key) != second.get(key) for key in keys):
        raise InstallerError("active and durable transaction scopes differ")


def _close_preparation_failure(
    *,
    plan_sha256: str,
    original_systemd: Mapping[str, Any],
    failure: BaseException,
) -> tuple[dict[str, Any], str] | None:
    """Close a caught preimage-preparation failure before managed mutation.

    ``_prepare_transaction`` writes the active bootstrap before creating its
    evidence directory, but it never changes a managed runtime, unit, drop-in,
    lock or directory.  A caught exception can therefore be closed without a
    file rollback.  We retain a root-only receipt and remove the active marker
    only after that receipt is durable.  A power loss is different: the active
    marker remains and must use the evidence-bound ``rollback`` command.
    """

    if not os.path.lexists(ACTIVE_TRANSACTION_PATH):
        return None
    active, _ = _load_transaction(ACTIVE_TRANSACTION_PATH)
    expected_transaction = _transaction_path(plan_sha256)
    if (
        active.get("planSha256") != plan_sha256
        or active.get("transactionPath") != str(expected_transaction)
        or active.get("phase") != "preparing-preimages"
        or active.get("originalSystemd") != dict(original_systemd)
    ):
        raise InstallerError("preparation failure active evidence differs from this apply")
    closed_at = _utc_now()
    closed = {
        **active,
        "phase": "preparation-failed-before-managed-mutation",
        "closedAtUtc": closed_at,
        "failureType": type(failure).__name__,
    }
    if os.path.lexists(expected_transaction):
        _require_safe_directory(expected_transaction, uid=0, gid=0, mode=0o700)
        transaction_evidence = expected_transaction / "transaction.json"
        _atomic_write(
            transaction_evidence,
            canonical_bytes(closed),
            uid=0,
            gid=0,
            mode=0o600,
            replace=os.path.lexists(transaction_evidence),
        )
    receipt_path = ROLLBACK_RECEIPTS_DIR / f"preparation-{plan_sha256}.json"
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": PREPARATION_CLOSED_KIND,
        "closedAtUtc": closed_at,
        "planSha256": plan_sha256,
        "transactionPath": str(expected_transaction),
        "phase": closed["phase"],
        "failureType": closed["failureType"],
        "managedTargetsChanged": False,
        "receiptPath": str(receipt_path),
    }
    receipt_raw = canonical_bytes(receipt)
    _atomic_write(
        receipt_path,
        receipt_raw,
        uid=0,
        gid=0,
        mode=0o600,
        replace=False,
    )
    _durable_unlink(ACTIVE_TRANSACTION_PATH)
    return receipt, sha256_bytes(receipt_raw)


def apply_plan(
    *,
    plan_path: Path,
    expected_plan_sha256: str,
    confirmation: str,
    assets: Sequence[Asset] = ASSETS,
    runner: CommandRunner = _run_read_only,
    fault_hook: Callable[[str], None] | None = None,
) -> tuple[dict[str, Any], str]:
    _require_root()
    _assert_fixed_plan_argument(plan_path)
    if confirmation != APPLY_CONFIRMATION:
        raise InstallerError(f"--confirm must exactly equal: {APPLY_CONFIRMATION}")
    hook = fault_hook or (lambda _phase: None)
    with InstallerLock():
        _require_no_installer_transaction()
        plan, plan_raw = _load_root_json(PLAN_PATH, MAX_PLAN_BYTES, "fixed install plan")
        plan_assessment = _validate_plan(plan, plan_raw, expected_plan_sha256)
        identity_value = plan_assessment.get("postgresIdentity")
        if not isinstance(identity_value, dict):
            raise InstallerError("plan postgres identity is malformed")
        identity = _identity()
        if identity_value != {"uid": identity.postgres_uid, "gid": identity.postgres_gid}:
            raise InstallerError("postgres identity changed after plan recording")
        current = build_assessment(identity, assets=assets, runner=runner)
        if current != plan_assessment:
            raise InstallerError("host/source assessment changed after plan recording; assess again")
        payloads = _asset_payloads(plan_assessment, assets)
        try:
            transaction, record = _prepare_transaction(
                plan_sha256=expected_plan_sha256,
                plan_assessment=plan_assessment,
                assets=assets,
            )
        except BaseException as preparation_error:
            closure_error: BaseException | None = None
            closure_result: tuple[dict[str, Any], str] | None = None
            try:
                closure_result = _close_preparation_failure(
                    plan_sha256=expected_plan_sha256,
                    original_systemd=plan_assessment["systemd"],
                    failure=preparation_error,
                )
            except BaseException as exc:
                closure_error = exc
            if closure_error is None:
                closure_status = (
                    "the root-only failure evidence was closed at "
                    f"{closure_result[0]['receiptPath']} with SHA-256 {closure_result[1]}"
                    if closure_result is not None
                    else "no active transaction evidence had been created"
                )
                raise InstallerError(
                    "apply failed before managed mutation and "
                    f"{closure_status}: {preparation_error}"
                ) from preparation_error
            active_sha = _best_effort_evidence_sha256(
                ACTIVE_TRANSACTION_PATH, "active transaction"
            )
            raise InstallerError(
                f"apply failed before managed mutation: {preparation_error}; evidence closure "
                f"also failed: {closure_error}; active evidence SHA-256 {active_sha}"
            ) from preparation_error
        original_error: BaseException | None = None
        rollback_error: BaseException | None = None
        try:
            hook("prepared")
            created = _create_planned_directories(plan_assessment, identity)
            expected_created = set(record["createdDirectories"])
            if set(created) != expected_created:
                raise InstallerError("created directory set differs from the durable transaction plan")
            _transition_transaction(transaction, record, "directories-ready")
            hook("directories-ready")
            lock_original = next(
                item["original"] for item in record["files"] if item["path"] == str(MAINTENANCE_LOCK)
            )
            _install_maintenance_lock(identity, lock_original)
            with DatabaseMaintenanceLock(identity):
                _transition_transaction(transaction, record, "maintenance-lock-held")
                hook("maintenance-lock-held")
                for file_record in record["files"]:
                    if file_record["path"] == str(MAINTENANCE_LOCK):
                        continue
                    if file_record["mutation"].get("state") == "absent":
                        _remove_captured_dropins(file_record)
                        continue
                    asset, raw = payloads[file_record["path"]]
                    original = file_record["original"]
                    if original.get("state") == "absent":
                        if os.path.lexists(asset.target):
                            raise InstallerError(f"managed target appeared before install: {asset.target}")
                    elif _file_observation(asset.target, allow_missing=False) != original:
                        raise InstallerError(f"managed target changed before install: {asset.target}")
                    _atomic_write(
                        asset.target,
                        raw,
                        uid=0,
                        gid=0,
                        mode=asset.mode,
                        replace=True,
                    )
                _transition_transaction(transaction, record, "files-installed")
                hook("files-installed")
                _transition_transaction(transaction, record, "daemon-reload-pending")
                hook("daemon-reload-pending")
                _daemon_reload(runner)
                _transition_transaction(transaction, record, "daemon-reloaded")
                hook("daemon-reloaded")
                _transition_transaction(transaction, record, "loaded-verification-pending")
                hook("loaded-verification-pending")
                _systemd_verify(assets, runner)
                loaded = _validate_loaded_contract(assets=assets, runner=runner)
                _transition_transaction(
                    transaction,
                    record,
                    "loaded-verified",
                    installedSystemd=loaded,
                )
                hook("loaded-verified")
                installed_targets = {
                    str(asset.target): _file_observation(asset.target, allow_missing=False)
                    for asset in assets
                }
                installed_targets[str(MAINTENANCE_LOCK)] = _maintenance_lock_observation(identity)
                receipt = {
                    "schemaVersion": SCHEMA_VERSION,
                    "kind": RECEIPT_KIND,
                    "commissioned": False,
                    "appliedAtUtc": _utc_now(),
                    "planSha256": expected_plan_sha256,
                    "transactionPath": str(transaction),
                    "installedTargets": installed_targets,
                    "installedSystemd": loaded,
                }
                receipt_raw = canonical_bytes(receipt)
                _atomic_write(
                    UNCOMMISSIONED_RECEIPT_PATH,
                    receipt_raw,
                    uid=0,
                    gid=0,
                    mode=0o600,
                    replace=False,
                )
                _transition_transaction(
                    transaction,
                    record,
                    "receipt-written",
                    receiptSha256=sha256_bytes(receipt_raw),
                )
                hook("receipt-written")
        except BaseException as exc:
            original_error = exc
            try:
                # If the failure occurred while the context held the database
                # lock, its __exit__ has now released it. Reacquire before any
                # rollback mutation so another root transaction cannot overlap.
                if _maintenance_lock_observation(identity).get("state") == "file":
                    with DatabaseMaintenanceLock(identity):
                        _restore_transaction(transaction, record, identity, runner)
                else:
                    _restore_transaction(transaction, record, identity, runner)
                _durable_unlink(UNCOMMISSIONED_RECEIPT_PATH)
                _durable_unlink(ACTIVE_TRANSACTION_PATH)
            except BaseException as rollback_exc:
                rollback_error = rollback_exc
        if original_error is not None:
            if rollback_error is None:
                raise InstallerError(
                    f"apply failed and was automatically rolled back: {original_error}"
                ) from original_error
            active_sha = _best_effort_evidence_sha256(
                ACTIVE_TRANSACTION_PATH, "active transaction"
            )
            raise InstallerError(
                f"apply failed: {original_error}; automatic rollback also failed: "
                f"{rollback_error}; use evidence-bound rollback with active SHA-256 {active_sha}"
            ) from original_error
        _transition_transaction(
            transaction,
            record,
            "committed-uncommissioned",
            committedAtUtc=_utc_now(),
        )
        _durable_unlink(ACTIVE_TRANSACTION_PATH)
        receipt, receipt_raw = _load_root_json(
            UNCOMMISSIONED_RECEIPT_PATH, MAX_RECEIPT_BYTES, "uncommissioned receipt"
        )
        return receipt, sha256_bytes(receipt_raw)


def _validate_receipt(value: dict[str, Any]) -> tuple[str, Path]:
    if set(value) != {
        "schemaVersion",
        "kind",
        "commissioned",
        "appliedAtUtc",
        "planSha256",
        "transactionPath",
        "installedTargets",
        "installedSystemd",
    }:
        raise InstallerError("uncommissioned receipt schema differs")
    if (
        value.get("schemaVersion") != SCHEMA_VERSION
        or value.get("kind") != RECEIPT_KIND
        or value.get("commissioned") is not False
    ):
        raise InstallerError("receipt is not an uncommissioned installer receipt")
    plan_sha = value.get("planSha256")
    transaction_value = value.get("transactionPath")
    if not isinstance(plan_sha, str) or not isinstance(transaction_value, str):
        raise InstallerError("receipt transaction identity is malformed")
    transaction = Path(transaction_value)
    if transaction != _transaction_path(plan_sha):
        raise InstallerError("receipt transaction path differs from its plan digest")
    return plan_sha, transaction


def _verify_receipt_installed_state(
    receipt: Mapping[str, Any], identity: Identity, runner: CommandRunner
) -> None:
    targets = receipt.get("installedTargets")
    if not isinstance(targets, dict):
        raise InstallerError("receipt installed target inventory is malformed")
    expected_paths = {str(asset.target) for asset in ASSETS} | {str(MAINTENANCE_LOCK)}
    if set(targets) != expected_paths:
        raise InstallerError("receipt installed target inventory is incomplete")
    for asset in ASSETS:
        if _file_observation(asset.target, allow_missing=False) != targets[str(asset.target)]:
            raise InstallerError(f"installed asset drifted after apply: {asset.target}")
    if _maintenance_lock_observation(identity) != targets[str(MAINTENANCE_LOCK)]:
        raise InstallerError("database-maintenance lock drifted after apply")
    units = {
        unit: _unit_observation(unit, runner, include_exec_start=True)
        for unit in MANAGED_UNITS
    }
    alerts = _alert_instances(runner)
    jobs = _systemd_jobs(runner)
    _require_quiescent(units, alerts, jobs, installed=True)
    if receipt.get("installedSystemd") != {
        "units": units,
        "alertInstances": alerts,
        "jobs": jobs,
    }:
        raise InstallerError("loaded systemd state drifted after uncommissioned apply")


def _require_first_backup_commissioning_never_started() -> None:
    """Asset rollback must not strand an active or evidenced local recovery layer."""

    _require_safe_directory(
        INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR,
        uid=0,
        gid=0,
        mode=0o700,
    )
    _require_safe_directory(
        INTERNAL_TEST_FIRST_BACKUP_TRANSACTIONS_DIR,
        uid=0,
        gid=0,
        mode=0o700,
    )
    _require_safe_directory(
        INTERNAL_TEST_FIRST_BACKUP_RECEIPTS_DIR,
        uid=0,
        gid=0,
        mode=0o700,
    )
    expected_children = {"transactions", "receipts"}
    actual_children = {
        path.name for path in INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR.iterdir()
    }
    if actual_children != expected_children:
        raise InstallerError(
            "internal-test first-backup plan/secret/transaction evidence blocks asset rollback"
        )
    if any(INTERNAL_TEST_FIRST_BACKUP_TRANSACTIONS_DIR.iterdir()) or any(
        INTERNAL_TEST_FIRST_BACKUP_RECEIPTS_DIR.iterdir()
    ):
        raise InstallerError(
            "internal-test first-backup transaction/receipt evidence blocks asset rollback"
        )


def _retire_rollback_source_evidence(
    *,
    rollback_receipt_path: Path,
    expected_rollback_receipt_sha256: str,
    fault_hook: Callable[[str], None] | None = None,
) -> None:
    """Retire source evidence while preserving one replayable record at every boundary.

    The durable rollback receipt is verified first.  The stale uncommissioned
    receipt is then removed before the active transaction.  If power is lost
    between those unlinks, the active transaction remains and rollback is
    idempotently replayable against already-restored preimages.
    """

    _, rollback_raw = _load_root_json(
        rollback_receipt_path, MAX_RECEIPT_BYTES, "rollback receipt"
    )
    if sha256_bytes(rollback_raw) != expected_rollback_receipt_sha256:
        raise InstallerError("durable rollback receipt digest differs before evidence retirement")
    hook = fault_hook or (lambda _phase: None)
    _durable_unlink(UNCOMMISSIONED_RECEIPT_PATH)
    hook("uncommissioned-receipt-retired")
    _durable_unlink(ACTIVE_TRANSACTION_PATH)
    hook("active-transaction-retired")


def rollback(
    *,
    evidence_path: Path,
    expected_evidence_sha256: str,
    confirmation: str,
    runner: CommandRunner = _run_read_only,
    fault_hook: Callable[[str], None] | None = None,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if evidence_path not in (ACTIVE_TRANSACTION_PATH, UNCOMMISSIONED_RECEIPT_PATH):
        raise InstallerError(
            "--evidence must be the fixed active transaction or uncommissioned receipt path"
        )
    if not SHA256_RE.fullmatch(expected_evidence_sha256):
        raise InstallerError("--expected-evidence-sha256 must be 64 lowercase hex")
    if confirmation != ROLLBACK_CONFIRMATION:
        raise InstallerError(f"--confirm must exactly equal: {ROLLBACK_CONFIRMATION}")
    with InstallerLock():
        if os.path.lexists(COMMISSIONED_MARKER_PATH):
            raise InstallerError("commissioned backup automation cannot use installer rollback")
        _require_first_backup_commissioning_never_started()
        evidence, evidence_raw = _load_root_json(
            evidence_path, MAX_RECEIPT_BYTES, "rollback evidence"
        )
        if sha256_bytes(evidence_raw) != expected_evidence_sha256:
            raise InstallerError("rollback evidence SHA-256 differs")
        receipt: dict[str, Any] | None = None
        preparing_only = False
        if evidence_path == UNCOMMISSIONED_RECEIPT_PATH:
            receipt = evidence
            plan_sha, transaction = _validate_receipt(receipt)
            transaction_record, _ = _load_transaction(transaction / "transaction.json")
            if transaction_record.get("planSha256") != plan_sha:
                raise InstallerError("receipt and durable transaction plan digests differ")
        else:
            transaction_record, _ = _load_transaction(ACTIVE_TRANSACTION_PATH)
            plan_sha = str(transaction_record.get("planSha256", ""))
            transaction = Path(transaction_record["transactionPath"])
            durable_path = transaction / "transaction.json"
            if transaction_record.get("phase") == "preparing-preimages":
                preparing_only = True
                if os.path.lexists(durable_path):
                    durable_record, _ = _load_transaction(durable_path)
                    if durable_record.get("phase") != "prepared":
                        raise InstallerError(
                            "a preparing active record cannot be paired with post-prepare mutation"
                        )
                    _require_same_transaction_scope(
                        transaction_record,
                        durable_record,
                        include_files=False,
                    )
            elif os.path.lexists(durable_path):
                durable_record, _ = _load_transaction(durable_path)
                # Each phase is written to the durable transaction first and
                # then to the active mirror.  A power loss can make the durable
                # phase newer, but rollback remains bound to the exact active
                # bytes reviewed by the operator.  Only immutable scope must
                # match before the active record is used.
                _require_same_transaction_scope(
                    transaction_record,
                    durable_record,
                    include_files=True,
                )
            else:
                raise InstallerError("durable transaction record is missing after mutation could begin")
        plan, plan_raw = _load_root_json(PLAN_PATH, MAX_PLAN_BYTES, "fixed install plan")
        assessment = _validate_plan(plan, plan_raw, plan_sha)
        identity = _identity()
        if assessment.get("postgresIdentity") != {
            "uid": identity.postgres_uid,
            "gid": identity.postgres_gid,
        }:
            raise InstallerError("rollback plan postgres identity differs from the host")
        if preparing_only:
            assessment_directories = assessment.get("directories")
            if not isinstance(assessment_directories, dict):
                raise InstallerError("preparing transaction plan directories are malformed")
            expected_created = sorted(
                path
                for path, value in assessment_directories.items()
                if isinstance(value, dict)
                and isinstance(value.get("observed"), dict)
                and value["observed"].get("state") == "absent"
            )
            if (
                transaction_record.get("files") != []
                or transaction_record.get("directories") != assessment.get("directories")
                or transaction_record.get("createdDirectories") != expected_created
                or transaction_record.get("originalSystemd") != assessment.get("systemd")
            ):
                raise InstallerError("preparing transaction evidence differs from its fixed plan")
            if build_assessment(identity, assets=ASSETS, runner=runner) != assessment:
                raise InstallerError(
                    "host changed during interrupted preimage preparation; review before rollback"
                )
        else:
            _validate_transaction_inventory(
                transaction_record,
                plan_assessment=assessment,
                assets=ASSETS,
                identity=identity,
            )
        units = {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}
        alerts = _alert_instances(runner)
        jobs = _systemd_jobs(runner)
        _require_quiescent(units, alerts, jobs, installed=False)
        if receipt is not None:
            _verify_receipt_installed_state(receipt, identity, runner)
        try:
            if preparing_only:
                original_systemd = transaction_record.get("originalSystemd")
                if not isinstance(original_systemd, dict):
                    raise InstallerError("transaction original systemd evidence is malformed")
                _verify_original_systemd(original_systemd, runner)
                rolled_back = {
                    **transaction_record,
                    "phase": "rolled-back-before-mutation",
                    "rolledBackAtUtc": _utc_now(),
                }
                if os.path.lexists(transaction):
                    _require_safe_directory(transaction, uid=0, gid=0, mode=0o700)
                    _atomic_write(
                        transaction / "transaction.json",
                        canonical_bytes(rolled_back),
                        uid=0,
                        gid=0,
                        mode=0o600,
                        replace=os.path.lexists(transaction / "transaction.json"),
                    )
            elif _maintenance_lock_observation(identity).get("state") == "file":
                with DatabaseMaintenanceLock(identity):
                    rolled_back = _restore_transaction(
                        transaction, transaction_record, identity, runner
                    )
            else:
                rolled_back = _restore_transaction(
                    transaction, transaction_record, identity, runner
                )
            if not preparing_only:
                original_systemd = transaction_record.get("originalSystemd")
                if not isinstance(original_systemd, dict):
                    raise InstallerError("transaction original systemd evidence is malformed")
                _verify_original_systemd(original_systemd, runner)
            receipt_name = (
                datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
                + expected_evidence_sha256
                + ".json"
            )
            rollback_path = ROLLBACK_RECEIPTS_DIR / receipt_name
            rollback_receipt = {
                "schemaVersion": SCHEMA_VERSION,
                "kind": ROLLBACK_KIND,
                "rolledBackAtUtc": rolled_back["rolledBackAtUtc"],
                "planSha256": rolled_back["planSha256"],
                "transactionPath": str(transaction),
                "evidencePath": str(evidence_path),
                "evidenceSha256": expected_evidence_sha256,
                "receiptPath": str(rollback_path),
            }
            rollback_raw = canonical_bytes(rollback_receipt)
            _atomic_write(
                rollback_path,
                rollback_raw,
                uid=0,
                gid=0,
                mode=0o600,
                replace=False,
            )
            rollback_sha256 = sha256_bytes(rollback_raw)
            _retire_rollback_source_evidence(
                rollback_receipt_path=rollback_path,
                expected_rollback_receipt_sha256=rollback_sha256,
                fault_hook=fault_hook,
            )
            return rollback_receipt, rollback_sha256
        except BaseException as exc:
            raise InstallerError(
                f"evidence-bound rollback failed and all evidence was retained: {exc}"
            ) from exc


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser(
        "assess",
        help="read-only inspection; emit canonical assessment and SHA-256 to stdout",
    )
    record = subparsers.add_parser(
        "record-plan",
        help="repeat the approved read-only assessment and write the fixed plan",
    )
    record.add_argument("--expected-assessment-sha256", required=True)
    record.add_argument("--confirm", required=True)
    apply_command = subparsers.add_parser(
        "apply",
        help="apply only the fixed recorded plan; no unit is started or enabled",
    )
    apply_command.add_argument("--plan", required=True, type=Path)
    apply_command.add_argument("--expected-plan-sha256", required=True)
    apply_command.add_argument("--confirm", required=True)
    rollback_command = subparsers.add_parser(
        "rollback",
        help="restore exact preimages from fixed uncommissioned evidence",
    )
    rollback_command.add_argument("--evidence", required=True, type=Path)
    rollback_command.add_argument("--expected-evidence-sha256", required=True)
    rollback_command.add_argument("--confirm", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.action == "assess":
            envelope, _ = assess()
            sys.stdout.buffer.write(canonical_bytes(envelope))
            return 0
        if args.action == "record-plan":
            _, plan_sha = record_plan(
                expected_assessment_sha256=args.expected_assessment_sha256,
                confirmation=args.confirm,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {
                        "planPath": str(PLAN_PATH),
                        "planSha256": plan_sha,
                        "status": "RECORDED",
                    }
                )
            )
            return 0
        if args.action == "apply":
            _, receipt_sha = apply_plan(
                plan_path=args.plan,
                expected_plan_sha256=args.expected_plan_sha256,
                confirmation=args.confirm,
            )
            sys.stdout.buffer.write(
                canonical_bytes(
                    {
                        "receiptPath": str(UNCOMMISSIONED_RECEIPT_PATH),
                        "receiptSha256": receipt_sha,
                        "status": "APPLIED_UNCOMMISSIONED",
                    }
                )
            )
            return 0
        receipt, rollback_sha = rollback(
            evidence_path=args.evidence,
            expected_evidence_sha256=args.expected_evidence_sha256,
            confirmation=args.confirm,
        )
        sys.stdout.buffer.write(
            canonical_bytes(
                {
                    "planSha256": receipt["planSha256"],
                    "rollbackReceiptPath": receipt["receiptPath"],
                    "rollbackReceiptSha256": rollback_sha,
                    "status": "ROLLED_BACK",
                }
            )
        )
        return 0
    except InstallerError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
