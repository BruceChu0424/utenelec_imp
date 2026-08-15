#!/usr/bin/env python3
"""Evidence-bound commissioner for the already installed backup automation.

``assess`` is strictly read-only.  ``record-plan`` is the first operation that
writes local evidence.  ``apply`` and each ``resume`` invocation advance at
most one reviewed timer stage while a durable marker keeps all backup jobs
fail-closed.  ``rollback`` restores the exact initial disabled/inactive map.

This utility never writes pgBackRest secrets or policy, never starts a backup
job, PostgreSQL or /data, and never enables release staging/retention timers.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
from contextlib import AbstractContextManager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

try:
    import fcntl
except ImportError:  # pragma: no cover - production is Linux; permits Windows static QA.
    fcntl = None  # type: ignore[assignment]


SCHEMA_VERSION = 1
ASSESSMENT_KIND = "uten-imp-backup-commission-read-only-assessment"
PLAN_KIND = "uten-imp-backup-commission-plan"
TRANSACTION_KIND = "uten-imp-backup-commission-transaction"
COMMISSIONED_KIND = "uten-imp-existing-backup-commissioned-marker"
COMMISSION_RECEIPT_KIND = "uten-imp-backup-commission-receipt"
ROLLBACK_RECEIPT_KIND = "uten-imp-backup-commission-rollback-receipt"

RECORD_CONFIRMATION = "RECORD REVIEWED UTEN BACKUP COMMISSION PLAN"
APPLY_CONFIRMATION = "APPLY REVIEWED UTEN BACKUP COMMISSION PLAN"
RESUME_CONFIRMATION = "RESUME REVIEWED UTEN BACKUP COMMISSION TRANSACTION"
ROLLBACK_CONFIRMATION = "ROLLBACK UNFINISHED UTEN BACKUP COMMISSION TRANSACTION"

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
REFERENCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+=-]{2,511}$")
MAX_JSON_BYTES = 4 * 1024 * 1024
COMMAND_TIMEOUT_SECONDS = 60

STATE_ROOT = Path("/var/lib/uten-imp-backup-commissioner")
RECEIPTS_DIR = STATE_ROOT / "receipts"
PLAN_PATH = STATE_ROOT / "commission-plan.json"
ACTIVE_PATH = STATE_ROOT / "active-transaction.json"
LOCK_PATH = STATE_ROOT / "commissioner.lock"

INSTALLER_ROOT = Path("/var/lib/uten-imp-backup-installer")
UNCOMMISSIONED_RECEIPT_PATH = INSTALLER_ROOT / "uncommissioned-install.json"
COMMISSIONED_MARKER_PATH = INSTALLER_ROOT / "commissioned.json"
INSTALLER_ACTIVE_PATH = INSTALLER_ROOT / "active-transaction.json"

ACCEPTANCE_DIR = Path("/var/lib/uten-imp-backup/acceptance-receipts")
BACKUP_ACCEPTANCE_PATH = ACCEPTANCE_DIR / "commissioning-backup-acceptance.json"
CAPACITY_ACCEPTANCE_PATH = ACCEPTANCE_DIR / "commissioning-capacity-quota.json"
MAINTENANCE_LOCK_PATH = Path("/var/lib/uten-imp-db-maintenance/operation.lock")
BACKUP_TRANSACTION_PATHS = (
    Path("/var/lib/uten-imp-backup-transactions/repo1.active.json"),
    Path("/var/lib/uten-imp-backup-transactions/repo2.active.json"),
)

STAGES = (
    ("alert-drain", "uten-pgbackup-alert-drain.timer", "uten-pgbackup-alert-drain.service"),
    ("repo1", "uten-pgbackup.timer", "uten-pgbackup.service"),
    ("health", "uten-pgbackup-health.timer", "uten-pgbackup-health.service"),
    ("repo2", "uten-pgbackup-repo2.timer", "uten-pgbackup-repo2.service"),
)
TIMER_UNITS = tuple(item[1] for item in STAGES)
JOB_UNITS = tuple(item[2] for item in STAGES)
TEMPLATE_UNITS = ("uten-pgbackup-alert@.service",)
MANAGED_UNITS = (*JOB_UNITS, *TIMER_UNITS, *TEMPLATE_UNITS)

LIBEXEC = Path("/usr/local/libexec/uten-imp-backup")
EXPECTED_INSTALLED_TARGETS = (
    LIBEXEC / "locked_job.py",
    LIBEXEC / "pgbackrest_repo2.py",
    LIBEXEC / "pgbackrest_health.py",
    LIBEXEC / "backup_alert.py",
    LIBEXEC / "backup_acceptance.py",
    LIBEXEC / "backup_commissioner.py",
    Path("/etc/systemd/system/uten-pgbackup.service"),
    Path("/etc/systemd/system/uten-pgbackup.timer"),
    Path("/etc/systemd/system/uten-pgbackup-repo2.service"),
    Path("/etc/systemd/system/uten-pgbackup-repo2.timer"),
    Path("/etc/systemd/system/uten-pgbackup-health.service"),
    Path("/etc/systemd/system/uten-pgbackup-health.timer"),
    Path("/etc/systemd/system/uten-pgbackup-alert@.service"),
    Path("/etc/systemd/system/uten-pgbackup-alert-drain.service"),
    Path("/etc/systemd/system/uten-pgbackup-alert-drain.timer"),
    MAINTENANCE_LOCK_PATH,
)

RELEASE_MARKERS = tuple(
    Path("/var/lib/uten-imp-release") / name
    for name in (
        "activation-failed.json",
        "activation-in-progress.json",
        "boot-enablement-in-progress.json",
        "recovery-in-progress.json",
        "recovery-ingress-pending.json",
        "recovery-ingress-authorization.json",
        "recovery-ingress-finalizing.json",
        "internal-test-onboarding-adoption.json",
        "internal-test-activation-reauthorization.json",
    )
)
BUSINESS_CHECKS = {
    "finance",
    "inventory",
    "production",
    "sales",
    "procurement",
    "audit",
    "attachments",
}
CAPACITY_MECHANISMS = {
    "xfs-project-quota",
    "zfs-dataset-quota",
    "lvm-thin-hard-limit",
    "dedicated-filesystem-size-bound",
}


class CommissionerError(RuntimeError):
    """Commissioning evidence or the bounded state transition is unsafe."""


CommandRunner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not UTC_RE.fullmatch(value):
        raise CommissionerError(f"{label} must use canonical UTC seconds")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise CommissionerError(f"{label} is not a real UTC timestamp") from exc


def _recent(value: Any, label: str, maximum_seconds: int) -> datetime:
    parsed = _utc(value, label)
    age = (datetime.now(timezone.utc) - parsed).total_seconds()
    if age < 0 or age > maximum_seconds:
        raise CommissionerError(f"{label} is outside its acceptance window")
    return parsed


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _strict_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CommissionerError(f"JSON object contains duplicate key: {key}")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> None:
    raise CommissionerError(f"JSON contains non-finite numeric token: {value}")


def _strict_json(raw: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            raw,
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CommissionerError(f"{label} cannot be read as strict JSON") from exc
    if not isinstance(value, dict):
        raise CommissionerError(f"{label} must contain exactly one JSON object")
    return value


def _require_root() -> None:
    if os.name != "posix" or os.geteuid() != 0 or os.getegid() != 0:
        raise CommissionerError("backup commissioner requires POSIX root")


def _secure_directory(path: Path, mode: int = 0o700) -> None:
    try:
        details = path.lstat()
    except OSError as exc:
        raise CommissionerError(f"required fixed directory is unavailable: {path}") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != mode
    ):
        raise CommissionerError(f"fixed directory must be root:root {mode:04o}: {path}")


def _assert_state_layout() -> None:
    _secure_directory(STATE_ROOT)
    _secure_directory(RECEIPTS_DIR)


def _read_root_json(
    path: Path, label: str, *, canonical: bool = False
) -> tuple[dict[str, Any], bytes]:
    try:
        details = path.lstat()
    except OSError as exc:
        raise CommissionerError(f"{label} is unavailable at its fixed path") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o600
        or details.st_nlink != 1
        or details.st_size < 2
        or details.st_size > MAX_JSON_BYTES
    ):
        raise CommissionerError(f"{label} must be bounded root:root 0600 single-link")
    try:
        raw = path.read_bytes()
        value = _strict_json(raw, label)
    except OSError as exc:
        raise CommissionerError(f"{label} cannot be read as JSON") from exc
    if len(raw) != details.st_size or not isinstance(value, dict):
        raise CommissionerError(f"{label} changed or is not one object")
    if canonical and canonical_bytes(value) != raw:
        raise CommissionerError(f"{label} is not canonical JSON")
    return value, raw


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _rename_noreplace(source: Path, destination: Path) -> None:
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
    except (AttributeError, OSError) as exc:
        raise CommissionerError("Linux renameat2 is required for durable evidence") from exc
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    result = renameat2(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    if result == 0:
        return
    number = ctypes.get_errno()
    if number == errno.EEXIST:
        raise CommissionerError("refusing to overwrite durable commissioner evidence")
    raise CommissionerError("durable no-replace commissioner publication failed")


def _write_state_json(path: Path, value: Mapping[str, Any], *, replace: bool) -> bytes:
    _assert_state_layout()
    if path.parent not in (STATE_ROOT, RECEIPTS_DIR):
        raise CommissionerError("commissioner state write escapes its fixed root")
    raw = canonical_bytes(dict(value))
    if len(raw) > MAX_JSON_BYTES:
        raise CommissionerError("commissioner state exceeds its fixed bound")
    temporary = path.parent / f".{path.name}.write.{os.getpid()}.{secrets.token_hex(8)}"
    descriptor = -1
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, 0o600)
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise CommissionerError("short commissioner evidence write")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        if replace:
            os.replace(temporary, path)
        else:
            _rename_noreplace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if os.path.lexists(temporary):
            temporary.unlink()
    _value, verified = _read_root_json(path, "written commissioner evidence", canonical=True)
    if verified != raw:
        raise CommissionerError("commissioner evidence changed after publication")
    return raw


def _write_or_verify(path: Path, value: Mapping[str, Any]) -> bytes:
    expected = canonical_bytes(dict(value))
    if os.path.lexists(path):
        _existing, raw = _read_root_json(path, "existing commissioner receipt", canonical=True)
        if raw != expected:
            raise CommissionerError("existing commissioner receipt bytes differ")
        return raw
    return _write_state_json(path, value, replace=False)


def _durable_unlink(path: Path) -> None:
    if path.parent not in (STATE_ROOT, RECEIPTS_DIR):
        raise CommissionerError("commissioner unlink escapes its fixed root")
    if os.path.lexists(path):
        path.unlink()
        _fsync_directory(path.parent)


class CommissionerLock(AbstractContextManager["CommissionerLock"]):
    def __init__(self) -> None:
        self.descriptor = -1

    def __enter__(self) -> "CommissionerLock":
        if fcntl is None:
            raise CommissionerError("commissioner locking requires POSIX flock")
        _assert_state_layout()
        self.descriptor = os.open(
            LOCK_PATH,
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        details = os.fstat(self.descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != 0o600
            or details.st_nlink != 1
        ):
            raise CommissionerError("commissioner lock metadata differs")
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise CommissionerError("another commissioner operation is running") from exc
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            assert fcntl is not None
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


class MaintenanceLock(AbstractContextManager["MaintenanceLock"]):
    def __init__(self) -> None:
        self.descriptor = -1

    def __enter__(self) -> "MaintenanceLock":
        if fcntl is None:
            raise CommissionerError("database-maintenance locking requires POSIX flock")
        self.descriptor = os.open(
            MAINTENANCE_LOCK_PATH,
            os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
        )
        details = os.fstat(self.descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
            or details.st_size != 0
        ):
            raise CommissionerError("database-maintenance lock metadata differs")
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            raise CommissionerError("another database maintenance operation is running") from exc
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            assert fcntl is not None
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


def _run(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
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
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CommissionerError(f"fixed command could not complete: {command[0]}") from exc


def _properties(raw: str, expected: set[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in raw.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in expected or key in result:
            raise CommissionerError("systemd property output is malformed")
        result[key] = value
    if set(result) != expected:
        raise CommissionerError("systemd property output is incomplete")
    return result


def _unit_observation(unit: str, runner: CommandRunner) -> dict[str, str]:
    if unit not in MANAGED_UNITS:
        raise CommissionerError("systemd observation escaped fixed unit allowlist")
    expected = {
        "LoadState",
        "ActiveState",
        "SubState",
        "UnitFileState",
        "FragmentPath",
        "DropInPaths",
    }
    completed = runner(
        [
            "/usr/bin/systemctl",
            "show",
            unit,
            *[f"--property={item}" for item in sorted(expected)],
        ]
    )
    if completed.returncode != 0:
        raise CommissionerError(f"systemd could not inspect fixed unit: {unit}")
    return _properties(completed.stdout, expected)


def _observe_systemd(runner: CommandRunner) -> dict[str, dict[str, str]]:
    return {unit: _unit_observation(unit, runner) for unit in MANAGED_UNITS}


def _require_no_managed_systemd_jobs(runner: CommandRunner) -> None:
    completed = runner(
        ["/usr/bin/systemctl", "list-jobs", "--no-legend", "--plain", "--no-pager"]
    )
    if completed.returncode != 0:
        raise CommissionerError("systemd pending jobs cannot be inspected")
    pending: set[str] = set()
    for line in completed.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and (
            fields[1] in MANAGED_UNITS or fields[1].startswith("uten-pgbackup-alert@")
        ):
            pending.add(fields[1])
    if pending:
        raise CommissionerError(
            "managed systemd jobs are pending: " + ",".join(sorted(pending))
        )


def _require_no_pending_evidence() -> None:
    for path in (*BACKUP_TRANSACTION_PATHS, *RELEASE_MARKERS, INSTALLER_ACTIVE_PATH):
        if os.path.lexists(path):
            raise CommissionerError(f"pending transaction evidence blocks commissioning: {path}")


def _file_observation(path: Path) -> dict[str, Any]:
    try:
        details = path.lstat()
    except OSError as exc:
        raise CommissionerError(f"installed target is unavailable: {path}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_mode & 0o022
        or details.st_nlink != 1
        or details.st_size < 0
        or details.st_size > MAX_JSON_BYTES
    ):
        raise CommissionerError(f"installed target metadata is unsafe: {path}")
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise CommissionerError(f"installed target cannot be read: {path}") from exc
    if len(raw) != details.st_size:
        raise CommissionerError(f"installed target changed while read: {path}")
    return {
        "state": "file",
        "sha256": sha256_bytes(raw),
        "size": len(raw),
        "uid": details.st_uid,
        "gid": details.st_gid,
        "mode": stat.S_IMODE(details.st_mode),
        "nlink": details.st_nlink,
    }


def _installed_evidence() -> dict[str, Any]:
    receipt, raw = _read_root_json(
        UNCOMMISSIONED_RECEIPT_PATH, "uncommissioned installer receipt", canonical=True
    )
    if (
        set(receipt)
        != {
            "schemaVersion",
            "kind",
            "commissioned",
            "appliedAtUtc",
            "planSha256",
            "transactionPath",
            "installedTargets",
            "installedSystemd",
        }
        or receipt.get("schemaVersion") != 1
        or receipt.get("kind") != "uten-imp-existing-backup-uncommissioned-receipt"
        or receipt.get("commissioned") is not False
        or not SHA256_RE.fullmatch(str(receipt.get("planSha256", "")))
    ):
        raise CommissionerError("uncommissioned installer receipt schema/identity differs")
    targets = receipt.get("installedTargets")
    expected_paths = {str(path) for path in EXPECTED_INSTALLED_TARGETS}
    if not isinstance(targets, dict) or set(targets) != expected_paths:
        raise CommissionerError("installer receipt target inventory differs from commissioner scope")
    actual: dict[str, Any] = {}
    for path in EXPECTED_INSTALLED_TARGETS:
        observation = _file_observation(path)
        if observation != targets[str(path)]:
            raise CommissionerError(f"installed target drifted after installer receipt: {path}")
        actual[str(path)] = observation
    return {
        "path": str(UNCOMMISSIONED_RECEIPT_PATH),
        "sha256": sha256_bytes(raw),
        "planSha256": receipt["planSha256"],
        "installedTargets": actual,
    }


def _validate_backup_acceptance(value: Mapping[str, Any]) -> dict[str, Any]:
    expected = {
        "schemaVersion",
        "receiptType",
        "successful",
        "completedAtUtc",
        "approvalReference",
        "targetVersion",
        "flywayHeadVersion",
        "flywayMigrationCount",
        "flywayMigrationSetSha256",
        "databaseIdentity",
        "continuousWal",
        "repositories",
        "healthReportSha256",
        "wormEvidence",
        "wormEvidenceSha256",
        "activeRepo2Preflight",
        "signedReleaseEvidence",
        "externalAlertEvidence",
        "isolatedPitrEvidence",
        "remoteImmutabilityVerifiedSeparately",
        "externalAlertDeliveryVerifiedSeparately",
        "isolatedRepo2PitrVerifiedSeparately",
    }
    if (
        set(value) != expected
        or value.get("schemaVersion") != 1
        or value.get("receiptType") != "backup-acceptance-detail"
        or value.get("successful") is not True
        or value.get("remoteImmutabilityVerifiedSeparately") is not True
        or value.get("externalAlertDeliveryVerifiedSeparately") is not True
        or value.get("isolatedRepo2PitrVerifiedSeparately") is not True
    ):
        raise CommissionerError("backup acceptance receipt is not the successful detailed schema")
    completed = _recent(value.get("completedAtUtc"), "backup acceptance completedAtUtc", 86400)
    repositories = value.get("repositories")
    if not isinstance(repositories, list) or len(repositories) != 2:
        raise CommissionerError("backup acceptance lacks both repositories")
    restore_counts: dict[str, int] = {}
    latest_wal: list[str] = []
    for expected_repo, repository in enumerate(repositories, start=1):
        if not isinstance(repository, dict) or repository.get("repo") != expected_repo:
            raise CommissionerError("backup acceptance repository identity/order differs")
        count = repository.get("successfulFullRestorePoints")
        points = repository.get("restorePoints")
        if (
            isinstance(count, bool)
            or not isinstance(count, int)
            or count < 7
            or not isinstance(points, list)
            or len(points) < 7
        ):
            raise CommissionerError(f"repo{expected_repo} lacks seven successful restore points")
        labels = [item.get("label") for item in points if isinstance(item, dict)]
        if len(labels) != len(points) or len(set(labels)) != len(labels):
            raise CommissionerError(f"repo{expected_repo} restore-point inventory is ambiguous")
        wal = repository.get("latestArchivedWal")
        if not isinstance(wal, str) or not re.fullmatch(r"[0-9A-F]{24}", wal):
            raise CommissionerError(f"repo{expected_repo} latest WAL identity is invalid")
        latest_wal.append(wal)
        restore_counts[f"repo{expected_repo}"] = count
    continuous = value.get("continuousWal")
    if (
        not isinstance(continuous, dict)
        or continuous.get("lastArchivedWal") != latest_wal[0]
        or len(set(latest_wal)) != 1
    ):
        raise CommissionerError("continuous WAL and both repository WAL inventories differ")
    worm = value.get("wormEvidence")
    if (
        not isinstance(worm, dict)
        or worm.get("status") != "VERIFIED"
        or worm.get("versioningEnabled") is not True
        or worm.get("immutabilityMode") not in {"COMPLIANCE", "GOVERNANCE-LOCKED"}
        or worm.get("credentialsIndependent") is not True
        or worm.get("failureDomainIndependent") is not True
        or _utc(worm.get("expiresAtUtc"), "WORM expiry") <= datetime.now(timezone.utc)
    ):
        raise CommissionerError("current remote immutable/WORM evidence is missing")
    alert = value.get("externalAlertEvidence")
    if (
        not isinstance(alert, dict)
        or set(alert) != {"eventId", "providerMessageId", "eventSha256", "receiptSha256"}
        or not alert.get("providerMessageId")
        or not SHA256_RE.fullmatch(str(alert.get("eventSha256", "")))
        or not SHA256_RE.fullmatch(str(alert.get("receiptSha256", "")))
    ):
        raise CommissionerError("external alert delivery receipt is incomplete")
    pitr = value.get("isolatedPitrEvidence")
    checks = pitr.get("checks") if isinstance(pitr, dict) else None
    if (
        not isinstance(pitr, dict)
        or pitr.get("repository") != 2
        or not isinstance(checks, dict)
        or set(checks) != BUSINESS_CHECKS
        or any(not isinstance(item, dict) or item.get("status") != "PASS" for item in checks.values())
        or not SHA256_RE.fullmatch(str(pitr.get("restoreReceiptSha256", "")))
        or not SHA256_RE.fullmatch(str(pitr.get("businessAcceptanceSha256", "")))
    ):
        raise CommissionerError("isolated repo2 PITR/business acceptance is incomplete")
    if not SHA256_RE.fullmatch(str(value.get("flywayMigrationSetSha256", ""))):
        raise CommissionerError("signed migration-set binding is malformed")
    return {
        "completedAtUtc": completed.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "targetVersion": value.get("targetVersion"),
        "flywayHeadVersion": value.get("flywayHeadVersion"),
        "flywayMigrationCount": value.get("flywayMigrationCount"),
        "flywayMigrationSetSha256": value.get("flywayMigrationSetSha256"),
        "restorePointCounts": restore_counts,
        "latestArchivedWal": latest_wal[0],
        "wormExpiresAtUtc": worm["expiresAtUtc"],
        "alertProviderMessageIdSha256": sha256_bytes(str(alert["providerMessageId"]).encode()),
        "pitrBackupSet": pitr.get("backupSet"),
    }


def _validate_capacity(value: Mapping[str, Any]) -> dict[str, Any]:
    expected = {
        "schemaVersion",
        "receiptType",
        "status",
        "checkedAtUtc",
        "mountTarget",
        "backupScope",
        "quotaScope",
        "quotaMechanism",
        "quotaEnforced",
        "quotaBytes",
        "usedBytes",
        "availableBytes",
        "minimumFreeBytes",
        "largestObservedFullBackupBytes",
        "simultaneousFullReserveBytes",
        "alertThresholdBytes",
        "powerLossRecoveryTested",
        "filesystemFullFailureTested",
        "evidenceReference",
        "acceptanceOwner",
        "secondReviewer",
    }
    if (
        set(value) != expected
        or value.get("schemaVersion") != 1
        or value.get("receiptType") != "backup-capacity-quota-acceptance"
        or value.get("status") != "PASS"
        or value.get("mountTarget") != "/data"
        or value.get("backupScope") != "/data/backups"
        or value.get("quotaEnforced") is not True
        or value.get("quotaMechanism") not in CAPACITY_MECHANISMS
        or value.get("powerLossRecoveryTested") is not True
        or value.get("filesystemFullFailureTested") is not True
    ):
        raise CommissionerError("capacity/quota acceptance schema or status differs")
    checked = _recent(value.get("checkedAtUtc"), "capacity acceptance checkedAtUtc", 7 * 86400)
    numbers: dict[str, int] = {}
    for key in (
        "quotaBytes",
        "usedBytes",
        "availableBytes",
        "minimumFreeBytes",
        "largestObservedFullBackupBytes",
        "simultaneousFullReserveBytes",
        "alertThresholdBytes",
    ):
        item = value.get(key)
        if isinstance(item, bool) or not isinstance(item, int) or item < 0:
            raise CommissionerError(f"capacity {key} is invalid")
        numbers[key] = item
    if (
        numbers["quotaBytes"] <= 0
        or numbers["largestObservedFullBackupBytes"] <= 0
        or numbers["quotaBytes"] - numbers["usedBytes"] != numbers["availableBytes"]
        or numbers["simultaneousFullReserveBytes"]
        < 2 * numbers["largestObservedFullBackupBytes"]
        or numbers["minimumFreeBytes"] < numbers["largestObservedFullBackupBytes"]
        or numbers["availableBytes"]
        < numbers["simultaneousFullReserveBytes"] + numbers["minimumFreeBytes"]
        or numbers["alertThresholdBytes"]
        < numbers["simultaneousFullReserveBytes"] + numbers["minimumFreeBytes"]
    ):
        raise CommissionerError("capacity headroom cannot contain simultaneous catch-up safely")
    quota_scope = value.get("quotaScope")
    if not isinstance(quota_scope, str) or not re.fullmatch(
        r"/data/backups/[A-Za-z0-9][A-Za-z0-9._/-]{2,255}", quota_scope
    ):
        raise CommissionerError("capacity quotaScope is invalid")
    for key in ("evidenceReference", "acceptanceOwner", "secondReviewer"):
        item = value.get(key)
        if not isinstance(item, str) or not REFERENCE_RE.fullmatch(item):
            raise CommissionerError(f"capacity {key} is invalid")
    if value["acceptanceOwner"] == value["secondReviewer"]:
        raise CommissionerError("capacity acceptance requires an independent second reviewer")
    return {
        "checkedAtUtc": checked.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "quotaMechanism": value["quotaMechanism"],
        "quotaBytes": numbers["quotaBytes"],
        "usedBytes": numbers["usedBytes"],
        "availableBytes": numbers["availableBytes"],
        "simultaneousFullReserveBytes": numbers["simultaneousFullReserveBytes"],
        "minimumFreeBytes": numbers["minimumFreeBytes"],
        "evidenceReferenceSha256": sha256_bytes(value["evidenceReference"].encode()),
    }


def _acceptance_evidence() -> dict[str, Any]:
    backup, backup_raw = _read_root_json(BACKUP_ACCEPTANCE_PATH, "backup acceptance receipt")
    capacity, capacity_raw = _read_root_json(CAPACITY_ACCEPTANCE_PATH, "capacity acceptance receipt")
    return {
        "backup": {
            "path": str(BACKUP_ACCEPTANCE_PATH),
            "sha256": sha256_bytes(backup_raw),
            "validated": _validate_backup_acceptance(backup),
        },
        "capacity": {
            "path": str(CAPACITY_ACCEPTANCE_PATH),
            "sha256": sha256_bytes(capacity_raw),
            "validated": _validate_capacity(capacity),
        },
    }


def _validate_fragments(units: Mapping[str, Mapping[str, str]]) -> None:
    for unit in MANAGED_UNITS:
        details = units.get(unit)
        if (
            not isinstance(details, Mapping)
            or details.get("LoadState") != "loaded"
            or details.get("FragmentPath") != f"/etc/systemd/system/{unit}"
            or details.get("DropInPaths") not in ("", None)
        ):
            raise CommissionerError(f"loaded systemd fragment/drop-ins differ: {unit}")


def _require_initial_systemd(units: Mapping[str, Mapping[str, str]]) -> None:
    _validate_fragments(units)
    for timer in TIMER_UNITS:
        details = units[timer]
        if details.get("UnitFileState") != "disabled" or details.get("ActiveState") != "inactive":
            raise CommissionerError(f"timer must remain disabled/inactive before commission: {timer}")
    for job in JOB_UNITS:
        if units[job].get("ActiveState") != "inactive":
            raise CommissionerError(f"backup job must be inactive before commission: {job}")


def build_assessment(*, runner: CommandRunner = _run) -> dict[str, Any]:
    _require_no_pending_evidence()
    if os.path.lexists(ACTIVE_PATH):
        raise CommissionerError("an interrupted commission transaction requires resume or rollback")
    if os.path.lexists(COMMISSIONED_MARKER_PATH):
        raise CommissionerError("backup automation is already commissioned")
    installed = _installed_evidence()
    acceptance = _acceptance_evidence()
    units = _observe_systemd(runner)
    _require_no_managed_systemd_jobs(runner)
    _require_initial_systemd(units)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": ASSESSMENT_KIND,
        "installer": installed,
        "acceptance": acceptance,
        "systemd": {unit: units[unit] for unit in MANAGED_UNITS},
        "stages": [item[0] for item in STAGES],
        "allTimersInitiallyDisabledInactive": True,
        "stagingOrRetentionAutomationInScope": False,
        "containsSecrets": False,
    }


def assess(*, runner: CommandRunner = _run) -> tuple[dict[str, Any], str]:
    _require_root()
    _assert_state_layout()
    assessment = build_assessment(runner=runner)
    digest = sha256_bytes(canonical_bytes(assessment))
    return {
        "assessment": assessment,
        "assessmentSha256": digest,
    }, digest


def record_plan(
    *, expected_assessment_sha256: str, confirmation: str, runner: CommandRunner = _run
) -> tuple[dict[str, Any], str]:
    _require_root()
    if not SHA256_RE.fullmatch(expected_assessment_sha256):
        raise CommissionerError("expected assessment SHA-256 is malformed")
    if confirmation != RECORD_CONFIRMATION:
        raise CommissionerError(f"typed confirmation must equal: {RECORD_CONFIRMATION}")
    with CommissionerLock():
        assessment = build_assessment(runner=runner)
        actual = sha256_bytes(canonical_bytes(assessment))
        if actual != expected_assessment_sha256:
            raise CommissionerError("read-only assessment changed after approval")
        plan = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": PLAN_KIND,
            "recordedAtUtc": _utc_now(),
            "assessmentSha256": actual,
            "assessment": assessment,
        }
        raw = _write_state_json(PLAN_PATH, plan, replace=os.path.lexists(PLAN_PATH))
    return plan, sha256_bytes(raw)


def _load_plan(expected_sha256: str) -> tuple[dict[str, Any], dict[str, Any], bytes]:
    if not SHA256_RE.fullmatch(expected_sha256):
        raise CommissionerError("expected plan SHA-256 is malformed")
    value, raw = _read_root_json(PLAN_PATH, "commission plan", canonical=True)
    if sha256_bytes(raw) != expected_sha256:
        raise CommissionerError("commission plan digest differs")
    if set(value) != {"schemaVersion", "kind", "recordedAtUtc", "assessmentSha256", "assessment"}:
        raise CommissionerError("commission plan schema differs")
    assessment = value.get("assessment")
    if (
        value.get("schemaVersion") != SCHEMA_VERSION
        or value.get("kind") != PLAN_KIND
        or not isinstance(assessment, dict)
        or value.get("assessmentSha256") != sha256_bytes(canonical_bytes(assessment))
    ):
        raise CommissionerError("commission plan identity/digest is invalid")
    return value, assessment, raw


def _set_active(record: Mapping[str, Any], *, replace: bool) -> bytes:
    return _write_state_json(ACTIVE_PATH, record, replace=replace)


def _load_active(expected_sha256: str | None = None) -> tuple[dict[str, Any], bytes]:
    value, raw = _read_root_json(ACTIVE_PATH, "active commission transaction", canonical=True)
    if expected_sha256 is not None and (
        not SHA256_RE.fullmatch(expected_sha256) or sha256_bytes(raw) != expected_sha256
    ):
        raise CommissionerError("active commission evidence digest differs")
    if (
        value.get("schemaVersion") != SCHEMA_VERSION
        or value.get("kind") != TRANSACTION_KIND
        or not SHA256_RE.fullmatch(str(value.get("planSha256", "")))
        or value.get("phase")
        not in {
            "stage-pending",
            "stage-complete",
            "commission-marker-pending",
            "commission-marker-written",
            "receipt-pending",
            "receipt-written",
            "rollback-pending",
        }
        or not isinstance(value.get("completedStages"), list)
        or value.get("completedStages")
        != [item[0] for item in STAGES[: len(value["completedStages"])] ]
        or not isinstance(value.get("originalSystemd"), dict)
    ):
        raise CommissionerError("active commission transaction schema/state differs")
    return value, raw


def _revalidate_evidence(plan_assessment: Mapping[str, Any]) -> None:
    if _installed_evidence() != plan_assessment.get("installer"):
        raise CommissionerError("installed runtime/receipt evidence drifted")
    if _acceptance_evidence() != plan_assessment.get("acceptance"):
        raise CommissionerError("backup/capacity acceptance evidence drifted or expired")
    _require_no_pending_evidence()


def _run_systemctl(runner: CommandRunner, *arguments: str) -> None:
    allowed_verbs = {"enable", "disable", "start", "stop", "reset-failed"}
    if not arguments or arguments[0] not in allowed_verbs:
        raise CommissionerError("commissioner systemctl mutation is outside fixed verbs")
    for item in arguments:
        if item.endswith(".timer") and item not in TIMER_UNITS:
            raise CommissionerError("commissioner timer mutation escaped fixed allowlist")
        if item.endswith(".service") and item not in JOB_UNITS:
            raise CommissionerError("commissioner service mutation escaped fixed allowlist")
    completed = runner(["/usr/bin/systemctl", *arguments])
    if completed.returncode != 0:
        raise CommissionerError(f"fixed systemctl {arguments[0]} failed")


def _contain_job(job: str, runner: CommandRunner) -> None:
    _run_systemctl(runner, "stop", job)
    _run_systemctl(runner, "reset-failed", job)


def _desired_timer(unit: str, units: Mapping[str, Mapping[str, str]]) -> bool:
    details = units[unit]
    return details.get("UnitFileState") == "enabled" and details.get("ActiveState") == "active"


def _initial_timer(unit: str, units: Mapping[str, Mapping[str, str]]) -> bool:
    details = units[unit]
    return details.get("UnitFileState") == "disabled" and details.get("ActiveState") == "inactive"


def _verify_stage_map(record: Mapping[str, Any], runner: CommandRunner, *, pending_ok: bool) -> dict[str, Any]:
    units = _observe_systemd(runner)
    _validate_fragments(units)
    completed = len(record["completedStages"])
    for index, (_name, timer, _job) in enumerate(STAGES):
        if index < completed:
            if not _desired_timer(timer, units):
                raise CommissionerError(f"completed stage timer drifted: {timer}")
        elif pending_ok and index == completed:
            if not (_initial_timer(timer, units) or _desired_timer(timer, units)):
                raise CommissionerError(f"pending stage timer is in an ambiguous state: {timer}")
        elif not _initial_timer(timer, units):
            raise CommissionerError(f"future stage timer changed early: {timer}")
    for job in JOB_UNITS:
        if units[job].get("ActiveState") not in {"inactive", "failed"}:
            raise CommissionerError(f"backup job is not quiescent during commission: {job}")
    return units


def _restore_initial_map(record: Mapping[str, Any], runner: CommandRunner) -> None:
    original = record.get("originalSystemd")
    if not isinstance(original, dict):
        raise CommissionerError("rollback lacks original systemd evidence")
    for _name, timer, job in reversed(STAGES):
        _run_systemctl(runner, "disable", "--now", timer)
        _contain_job(job, runner)
    units = _observe_systemd(runner)
    _require_initial_systemd(units)
    for timer in TIMER_UNITS:
        before = original.get(timer)
        if not isinstance(before, dict) or not _initial_timer(timer, {timer: before}):
            raise CommissionerError("original timer map was not disabled/inactive")


def _rollback_locked(
    record: dict[str, Any], runner: CommandRunner, *, reason: str
) -> tuple[dict[str, Any], str]:
    if os.path.lexists(COMMISSIONED_MARKER_PATH):
        raise CommissionerError("commissioned automation cannot use pre-commission rollback")
    record = {**record, "phase": "rollback-pending", "updatedAtUtc": _utc_now()}
    _set_active(record, replace=True)
    _restore_initial_map(record, runner)
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": ROLLBACK_RECEIPT_KIND,
        "planSha256": record["planSha256"],
        "transactionId": record["transactionId"],
        "rolledBackAtUtc": _utc_now(),
        "reason": reason,
        "restoredTimerMap": {
            timer: {"unitFileState": "disabled", "activeState": "inactive"}
            for timer in TIMER_UNITS
        },
        "containsSecrets": False,
    }
    path = RECEIPTS_DIR / f"rollback-{record['transactionId']}.json"
    raw = _write_or_verify(path, receipt)
    _durable_unlink(ACTIVE_PATH)
    return {**receipt, "receiptPath": str(path)}, sha256_bytes(raw)


def _commission_marker(record: Mapping[str, Any], plan: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": COMMISSIONED_KIND,
        "commissioned": True,
        "commissionedAtUtc": _utc_now(),
        "planSha256": record["planSha256"],
        "installerReceiptSha256": plan["assessment"]["installer"]["sha256"],
        "backupAcceptanceSha256": plan["assessment"]["acceptance"]["backup"]["sha256"],
        "capacityAcceptanceSha256": plan["assessment"]["acceptance"]["capacity"]["sha256"],
        "enabledTimers": list(TIMER_UNITS),
        "stagingOrRetentionAutomationEnabled": False,
        "containsSecrets": False,
    }


def _validate_existing_commission_marker(
    marker: Mapping[str, Any], record: Mapping[str, Any], plan: Mapping[str, Any]
) -> None:
    expected_keys = {
        "schemaVersion",
        "kind",
        "commissioned",
        "commissionedAtUtc",
        "planSha256",
        "installerReceiptSha256",
        "backupAcceptanceSha256",
        "capacityAcceptanceSha256",
        "enabledTimers",
        "stagingOrRetentionAutomationEnabled",
        "containsSecrets",
    }
    assessment = plan.get("assessment")
    if not isinstance(assessment, Mapping):
        raise CommissionerError("commission plan assessment is malformed")
    installer = assessment.get("installer")
    acceptance = assessment.get("acceptance")
    if not isinstance(installer, Mapping) or not isinstance(acceptance, Mapping):
        raise CommissionerError("commission plan evidence binding is malformed")
    backup = acceptance.get("backup")
    capacity = acceptance.get("capacity")
    if not isinstance(backup, Mapping) or not isinstance(capacity, Mapping):
        raise CommissionerError("commission plan acceptance binding is malformed")
    if (
        set(marker) != expected_keys
        or marker.get("schemaVersion") != SCHEMA_VERSION
        or marker.get("kind") != COMMISSIONED_KIND
        or marker.get("commissioned") is not True
        or marker.get("planSha256") != record.get("planSha256")
        or marker.get("installerReceiptSha256") != installer.get("sha256")
        or marker.get("backupAcceptanceSha256") != backup.get("sha256")
        or marker.get("capacityAcceptanceSha256") != capacity.get("sha256")
        or marker.get("enabledTimers") != list(TIMER_UNITS)
        or marker.get("stagingOrRetentionAutomationEnabled") is not False
        or marker.get("containsSecrets") is not False
    ):
        raise CommissionerError("existing commissioned marker differs from approved evidence")
    _utc(marker.get("commissionedAtUtc"), "commissioned marker commissionedAtUtc")


def _write_installer_marker(value: Mapping[str, Any]) -> bytes:
    expected = canonical_bytes(dict(value))
    if os.path.lexists(COMMISSIONED_MARKER_PATH):
        existing, raw = _read_root_json(COMMISSIONED_MARKER_PATH, "commissioned marker", canonical=True)
        if raw != expected or existing.get("commissioned") is not True:
            raise CommissionerError("existing commissioned marker differs")
        return raw
    temporary = INSTALLER_ROOT / f".commissioned.write.{os.getpid()}.{secrets.token_hex(8)}"
    descriptor = -1
    try:
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
        )
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, 0o600)
        view = memoryview(expected)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise CommissionerError("short commissioned marker write")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        _rename_noreplace(temporary, COMMISSIONED_MARKER_PATH)
        _fsync_directory(INSTALLER_ROOT)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if os.path.lexists(temporary):
            temporary.unlink()
    return expected


def _finalize_locked(
    record: dict[str, Any], plan: Mapping[str, Any]
) -> tuple[dict[str, Any], str]:
    if os.path.lexists(COMMISSIONED_MARKER_PATH):
        marker, marker_raw = _read_root_json(
            COMMISSIONED_MARKER_PATH, "commissioned marker", canonical=True
        )
        _validate_existing_commission_marker(marker, record, plan)
    else:
        record = {
            **record,
            "phase": "commission-marker-pending",
            "updatedAtUtc": _utc_now(),
        }
        _set_active(record, replace=True)
        marker = _commission_marker(record, plan)
        marker_raw = _write_installer_marker(marker)
    record = {
        **record,
        "phase": "commission-marker-written",
        "updatedAtUtc": _utc_now(),
        "commissionedMarkerSha256": sha256_bytes(marker_raw),
    }
    _set_active(record, replace=True)
    record = {**record, "phase": "receipt-pending", "updatedAtUtc": _utc_now()}
    _set_active(record, replace=True)
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": COMMISSION_RECEIPT_KIND,
        "commissioned": True,
        "commissionedAtUtc": marker["commissionedAtUtc"],
        "planSha256": record["planSha256"],
        "transactionId": record["transactionId"],
        "commissionedMarkerSha256": sha256_bytes(marker_raw),
        "enabledTimers": list(TIMER_UNITS),
        "containsSecrets": False,
    }
    path = RECEIPTS_DIR / f"commissioned-{record['transactionId']}.json"
    receipt_raw = _write_or_verify(path, receipt)
    record = {
        **record,
        "phase": "receipt-written",
        "updatedAtUtc": _utc_now(),
        "commissionReceiptSha256": sha256_bytes(receipt_raw),
    }
    _set_active(record, replace=True)
    _durable_unlink(ACTIVE_PATH)
    return {**receipt, "receiptPath": str(path)}, sha256_bytes(receipt_raw)


def _advance_locked(
    record: dict[str, Any], plan: Mapping[str, Any], runner: CommandRunner
) -> tuple[dict[str, Any], str]:
    assessment = plan["assessment"]
    _revalidate_evidence(assessment)
    for _name, _timer, job in STAGES:
        _contain_job(job, runner)
    units = _verify_stage_map(record, runner, pending_ok=True)
    completed = len(record["completedStages"])
    if completed == len(STAGES):
        return _finalize_locked(record, plan)
    name, timer, job = STAGES[completed]
    if record.get("phase") != "stage-pending":
        record = {**record, "phase": "stage-pending", "updatedAtUtc": _utc_now()}
        _set_active(record, replace=True)
    if _initial_timer(timer, units):
        # Enablement is separated from timer start.  This prevents Persistent=
        # catch-up from racing before the durable stage intent exists.  The
        # active commissioner marker and maintenance lock make any catch-up
        # service fail closed; we then contain/reset that expected gate failure.
        _run_systemctl(runner, "enable", timer)
        _run_systemctl(runner, "start", timer)
    _contain_job(job, runner)
    units = _observe_systemd(runner)
    if not _desired_timer(timer, units):
        raise CommissionerError(f"commission stage did not enable/start exact timer: {timer}")
    record = {
        **record,
        "phase": "stage-complete",
        "updatedAtUtc": _utc_now(),
        "completedStages": [*record["completedStages"], name],
    }
    raw = _set_active(record, replace=True)
    if len(record["completedStages"]) == len(STAGES):
        return _finalize_locked(record, plan)
    return {
        "status": "STAGE_COMPLETED",
        "completedStage": name,
        "nextStage": STAGES[len(record["completedStages"])][0],
        "activeEvidencePath": str(ACTIVE_PATH),
        "activeEvidenceSha256": sha256_bytes(raw),
        "containsSecrets": False,
    }, sha256_bytes(raw)


def apply_plan(
    *, expected_plan_sha256: str, confirmation: str, runner: CommandRunner = _run
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != APPLY_CONFIRMATION:
        raise CommissionerError(f"typed confirmation must equal: {APPLY_CONFIRMATION}")
    with CommissionerLock(), MaintenanceLock():
        if os.path.lexists(ACTIVE_PATH) or os.path.lexists(COMMISSIONED_MARKER_PATH):
            raise CommissionerError("commission apply requires no active/commissioned marker")
        plan, assessment, _raw = _load_plan(expected_plan_sha256)
        current = build_assessment(runner=runner)
        if current != assessment:
            raise CommissionerError("commission assessment changed after plan approval")
        original = assessment["systemd"]
        record = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": TRANSACTION_KIND,
            "transactionId": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
            + secrets.token_hex(16),
            "planSha256": expected_plan_sha256,
            "phase": "stage-pending",
            "createdAtUtc": _utc_now(),
            "updatedAtUtc": _utc_now(),
            "completedStages": [],
            "originalSystemd": original,
        }
        _set_active(record, replace=False)
        try:
            return _advance_locked(record, plan, runner)
        except BaseException as exc:
            try:
                _rollback_locked(record, runner, reason="automatic-apply-failure")
            except BaseException as rollback_exc:
                raise CommissionerError(
                    f"commission apply failed: {exc}; automatic rollback failed: {rollback_exc}"
                ) from exc
            raise CommissionerError(f"commission apply failed and rolled back: {exc}") from exc


def resume(
    *, expected_active_sha256: str, confirmation: str, runner: CommandRunner = _run
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != RESUME_CONFIRMATION:
        raise CommissionerError(f"typed confirmation must equal: {RESUME_CONFIRMATION}")
    with CommissionerLock(), MaintenanceLock():
        record, _raw = _load_active(expected_active_sha256)
        plan, _assessment, _plan_raw = _load_plan(str(record["planSha256"]))
        if os.path.lexists(COMMISSIONED_MARKER_PATH):
            marker, marker_raw = _read_root_json(
                COMMISSIONED_MARKER_PATH, "commissioned marker", canonical=True
            )
            if marker.get("planSha256") != record["planSha256"]:
                raise CommissionerError("commissioned marker differs from active transaction")
            # Power loss after marker publication may resume final receipt only.
            record = {
                **record,
                "phase": "commission-marker-written",
                "updatedAtUtc": _utc_now(),
                "commissionedMarkerSha256": sha256_bytes(marker_raw),
            }
            _set_active(record, replace=True)
            return _finalize_locked(record, plan)
        try:
            if record["phase"] == "stage-complete":
                record = {**record, "phase": "stage-pending", "updatedAtUtc": _utc_now()}
                _set_active(record, replace=True)
            return _advance_locked(record, plan, runner)
        except BaseException as exc:
            try:
                _rollback_locked(record, runner, reason="automatic-resume-failure")
            except BaseException as rollback_exc:
                raise CommissionerError(
                    f"commission resume failed: {exc}; automatic rollback failed: {rollback_exc}"
                ) from exc
            raise CommissionerError(f"commission resume failed and rolled back: {exc}") from exc


def rollback(
    *, expected_active_sha256: str, confirmation: str, runner: CommandRunner = _run
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != ROLLBACK_CONFIRMATION:
        raise CommissionerError(f"typed confirmation must equal: {ROLLBACK_CONFIRMATION}")
    with CommissionerLock(), MaintenanceLock():
        record, _raw = _load_active(expected_active_sha256)
        return _rollback_locked(record, runner, reason="operator-approved-rollback")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("assess")
    record = commands.add_parser("record-plan")
    record.add_argument("--expected-assessment-sha256", required=True)
    record.add_argument("--confirm", required=True)
    apply_command = commands.add_parser("apply")
    apply_command.add_argument("--plan", type=Path, default=PLAN_PATH)
    apply_command.add_argument("--expected-plan-sha256", required=True)
    apply_command.add_argument("--confirm", required=True)
    for name in ("resume", "rollback"):
        command = commands.add_parser(name)
        command.add_argument("--expected-active-sha256", required=True)
        command.add_argument("--confirm", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.action == "assess":
            envelope, _ = assess()
            sys.stdout.buffer.write(canonical_bytes(envelope))
            return 0
        if args.action == "record-plan":
            _plan, digest = record_plan(
                expected_assessment_sha256=args.expected_assessment_sha256,
                confirmation=args.confirm,
            )
            result = {"status": "PLAN_RECORDED", "planPath": str(PLAN_PATH), "planSha256": digest}
        elif args.action == "apply":
            if args.plan != PLAN_PATH:
                raise CommissionerError("apply accepts only the fixed commission plan path")
            result, digest = apply_plan(
                expected_plan_sha256=args.expected_plan_sha256,
                confirmation=args.confirm,
            )
        elif args.action == "resume":
            result, digest = resume(
                expected_active_sha256=args.expected_active_sha256,
                confirmation=args.confirm,
            )
        else:
            result, digest = rollback(
                expected_active_sha256=args.expected_active_sha256,
                confirmation=args.confirm,
            )
        sys.stdout.buffer.write(canonical_bytes({**result, "resultSha256": digest}))
        return 0
    except CommissionerError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
