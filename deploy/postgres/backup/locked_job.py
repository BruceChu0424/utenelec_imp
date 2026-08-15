#!/usr/bin/env python3
"""Run one fixed PostgreSQL backup job under the shared maintenance lock.

The command line selects only one reviewed job name.  Paths, executables and
arguments are constants so neither systemd nor an operator can inject a
different command.  The lock is held from the first preflight through the
backup and its success-only expiry step (or through the whole health check).
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
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping

try:
    import fcntl
except ImportError:  # pragma: no cover - production is POSIX; permits Windows static QA.
    fcntl = None  # type: ignore[assignment]

try:
    import pwd
except ImportError:  # pragma: no cover - production is POSIX; permits Windows static QA.
    pwd = None  # type: ignore[assignment]


POSTGRES_USER = "postgres"
MAINTENANCE_DIRECTORY = Path("/var/lib/uten-imp-db-maintenance")
MAINTENANCE_LOCK = MAINTENANCE_DIRECTORY / "operation.lock"
RELEASE_STATE_DIRECTORY = Path("/var/lib/uten-imp-release")
COMMISSIONER_STATE_DIRECTORY = Path("/var/lib/uten-imp-backup-commissioner")
COMMISSIONER_ACTIVE_TRANSACTION = COMMISSIONER_STATE_DIRECTORY / "active-transaction.json"
HEALTH_STATE_DIRECTORY = Path("/var/lib/uten-imp-backup-health")
HEALTH_REPORT = Path("/var/lib/uten-imp-backup-health/health.json")
TRANSACTION_STATE_DIRECTORY = Path("/var/lib/uten-imp-backup-transactions")
TRANSACTION_RECEIPT_DIRECTORY = TRANSACTION_STATE_DIRECTORY / "receipts"
ACTIVE_TRANSACTION_PATHS = {
    "repo1": TRANSACTION_STATE_DIRECTORY / "repo1.active.json",
    "repo2": TRANSACTION_STATE_DIRECTORY / "repo2.active.json",
}
TRANSACTION_SCHEMA_VERSION = 1
TRANSACTION_KIND = "uten-imp-pgbackrest-backup-transaction"
TRANSACTION_RECEIPT_KIND = "uten-imp-pgbackrest-backup-transaction-receipt"
RECONCILE_RECEIPT_KIND = "uten-imp-pgbackrest-backup-reconcile-receipt"
RECONCILE_ABORT_CONFIRMATION = "ABORT VERIFIED UTEN BACKUP TRANSACTION WITHOUT NEW BACKUP"
RECONCILE_EXPIRE_CONFIRMATION = "RESUME EXPIRE FOR VERIFIED UTEN BACKUP TRANSACTION"
RECONCILE_COMPLETE_CONFIRMATION = "FINALIZE VERIFIED UTEN BACKUP TRANSACTION"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
TRANSACTION_ID_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$")
BACKUP_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$")
MAX_EVIDENCE_BYTES = 4 * 1024 * 1024
RELEASE_TRANSACTION_MARKERS = (
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

MOUNT_PREFLIGHT = ("/usr/bin/mountpoint", "--quiet", "/data")
POSTGRES_PREFLIGHT = (
    "/usr/bin/pg_isready",
    "-q",
    "-h",
    "127.0.0.1",
    "-p",
    "5432",
    "-d",
    "uten_imp",
    "-t",
    "10",
)
PGBACKREST_BASE = (
    "/usr/bin/pgbackrest",
    "--config=/etc/pgbackrest.conf",
    "--config-include-path=/etc/pgbackrest/conf.d",
    "--stanza=uten-imp",
)
PGBACKREST_INFO_BASE = PGBACKREST_BASE + ("--output=json",)
REPO2_PREFLIGHT = (
    "/usr/bin/python3",
    "-I",
    "/usr/local/libexec/uten-imp-backup/pgbackrest_repo2.py",
    "validate-active",
)
HEALTH_COMMAND = (
    "/usr/bin/python3",
    "-I",
    "/usr/local/libexec/uten-imp-backup/pgbackrest_health.py",
    "live",
    "--policy",
    "/etc/uten-imp-backup/repo2-policy.json",
    "--config",
    "/etc/pgbackrest.conf",
    "--config-include-path",
    "/etc/pgbackrest/conf.d",
    "--report",
    str(HEALTH_REPORT),
)


class LockedJobError(RuntimeError):
    """A fixed job could not run under the reviewed lock contract."""


class TerminalLockedJobError(LockedJobError):
    """A backup committed; automatic retry could create another full backup."""


@dataclass(frozen=True)
class JobPlan:
    steps: tuple[tuple[str, ...], ...]
    backup_step: int | None
    repository: int | None


JOB_PLANS = {
    "repo1": JobPlan(
        steps=(
            MOUNT_PREFLIGHT,
            POSTGRES_PREFLIGHT,
            PGBACKREST_BASE
            + ("--repo=1", "--no-expire-auto", "--type=full", "backup"),
            PGBACKREST_BASE + ("--repo=1", "expire"),
        ),
        backup_step=3,
        repository=1,
    ),
    "repo2": JobPlan(
        steps=(
            MOUNT_PREFLIGHT,
            POSTGRES_PREFLIGHT,
            REPO2_PREFLIGHT,
            PGBACKREST_BASE + ("--repo=2", "check"),
            PGBACKREST_BASE
            + ("--repo=2", "--no-expire-auto", "--type=full", "backup"),
            PGBACKREST_BASE + ("--repo=2", "expire"),
        ),
        backup_step=5,
        repository=2,
    ),
    "health": JobPlan(
        steps=(
            MOUNT_PREFLIGHT,
            POSTGRES_PREFLIGHT,
            REPO2_PREFLIGHT,
            HEALTH_COMMAND,
        ),
        backup_step=None,
        repository=None,
    ),
}

FIXED_ENVIRONMENT = {
    "HOME": "/var/lib/postgresql",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "LOGNAME": POSTGRES_USER,
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "USER": POSTGRES_USER,
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _active_path(job_name: str) -> Path:
    try:
        return ACTIVE_TRANSACTION_PATHS[job_name]
    except KeyError as exc:
        raise LockedJobError("durable transactions exist only for fixed backup jobs") from exc


def _secure_transaction_directory(path: Path) -> None:
    try:
        details = path.lstat()
    except OSError as exc:
        raise LockedJobError(f"fixed backup transaction directory is unavailable: {path}") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o700
    ):
        raise LockedJobError(
            f"fixed backup transaction directory must be root:root 0700: {path}"
        )


def assert_transaction_layout() -> None:
    for parent in (Path("/"), Path("/var"), Path("/var/lib")):
        _assert_safe_root_directory(parent)
    _secure_transaction_directory(TRANSACTION_STATE_DIRECTORY)
    _secure_transaction_directory(TRANSACTION_RECEIPT_DIRECTORY)


def _bounded_root_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    try:
        details = path.lstat()
    except OSError as exc:
        raise LockedJobError(f"{label} cannot be stated") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o600
        or details.st_nlink != 1
        or details.st_size < 1
        or details.st_size > MAX_EVIDENCE_BYTES
    ):
        raise LockedJobError(f"{label} must be root:root 0600, single-link and bounded")
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise LockedJobError(f"{label} cannot be read") from exc
    if len(raw) != details.st_size:
        raise LockedJobError(f"{label} changed while being read")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LockedJobError(f"{label} is not canonical JSON") from exc
    if not isinstance(value, dict) or _canonical_bytes(value) != raw:
        raise LockedJobError(f"{label} bytes are not canonical")
    return value, raw


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
    if os.name != "posix":
        raise LockedJobError("durable no-replace evidence requires Linux renameat2")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
    except (AttributeError, OSError) as exc:
        raise LockedJobError("Linux libc renameat2 is unavailable") from exc
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
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        raise LockedJobError("refusing to overwrite backup transaction evidence")
    if error_number == errno.ENOSYS:
        raise LockedJobError("running Linux kernel lacks renameat2(RENAME_NOREPLACE)")
    raise LockedJobError("atomic backup transaction evidence publication failed")


def _atomic_root_json(path: Path, value: Mapping[str, Any], *, replace: bool) -> bytes:
    assert_transaction_layout()
    if path.parent not in (TRANSACTION_STATE_DIRECTORY, TRANSACTION_RECEIPT_DIRECTORY):
        raise LockedJobError("backup transaction evidence path escapes the fixed state root")
    raw = _canonical_bytes(dict(value))
    if len(raw) > MAX_EVIDENCE_BYTES:
        raise LockedJobError("backup transaction evidence exceeds its fixed bound")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_NOFOLLOW
        | getattr(os, "O_CLOEXEC", 0)
    )
    temporary = path.parent / (
        f".{path.name}.write.{os.getpid()}.{secrets.token_hex(8)}"
    )
    descriptor = -1
    try:
        descriptor = os.open(temporary, flags, 0o600)
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, 0o600)
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                raise LockedJobError("short durable backup transaction write")
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
    _, verified = _bounded_root_json(path, "durable backup transaction evidence")
    if verified != raw:
        raise LockedJobError("durable backup transaction evidence changed after write")
    return raw


def _durable_unlink(path: Path) -> None:
    if path.parent not in (TRANSACTION_STATE_DIRECTORY, TRANSACTION_RECEIPT_DIRECTORY):
        raise LockedJobError("backup transaction unlink path escapes fixed state root")
    if not os.path.lexists(path):
        return
    path.unlink()
    _fsync_directory(path.parent)


def _validate_inventory(value: Mapping[str, Any], repository: int) -> dict[str, Any]:
    if set(value) != {"repository", "stanza", "backups", "inventorySha256"}:
        raise LockedJobError("pgBackRest inventory evidence schema differs")
    if value.get("repository") != repository or value.get("stanza") != "uten-imp":
        raise LockedJobError("pgBackRest inventory repository/stanza differs")
    backups = value.get("backups")
    if not isinstance(backups, list):
        raise LockedJobError("pgBackRest inventory backup list is malformed")
    normalized: list[dict[str, Any]] = []
    labels: set[str] = set()
    for item in backups:
        if not isinstance(item, dict) or set(item) != {"label", "type", "stopEpoch"}:
            raise LockedJobError("pgBackRest inventory backup entry is malformed")
        label = item.get("label")
        backup_type = item.get("type")
        stop_epoch = item.get("stopEpoch")
        if (
            not isinstance(label, str)
            or not BACKUP_LABEL_RE.fullmatch(label)
            or label in labels
            or backup_type not in {"full", "diff", "incr"}
            or isinstance(stop_epoch, bool)
            or not isinstance(stop_epoch, int)
            or stop_epoch < 1
        ):
            raise LockedJobError("pgBackRest inventory backup identity is invalid")
        labels.add(label)
        normalized.append(
            {"label": label, "type": backup_type, "stopEpoch": stop_epoch}
        )
    normalized.sort(key=lambda item: item["label"])
    expected_sha = _sha256(_canonical_bytes(normalized))
    if value.get("inventorySha256") != expected_sha:
        raise LockedJobError("pgBackRest inventory digest is inconsistent")
    return {
        "repository": repository,
        "stanza": "uten-imp",
        "backups": normalized,
        "inventorySha256": expected_sha,
    }


def parse_pgbackrest_inventory(raw: bytes, repository: int) -> dict[str, Any]:
    if repository not in (1, 2) or len(raw) > MAX_EVIDENCE_BYTES:
        raise LockedJobError("pgBackRest inventory request or response is unsafe")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LockedJobError("pgBackRest inventory is not JSON") from exc
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        raise LockedJobError("pgBackRest inventory must contain exactly one stanza")
    stanza = value[0]
    status = stanza.get("status")
    backups = stanza.get("backup")
    if (
        stanza.get("name") != "uten-imp"
        or not isinstance(status, dict)
        or status.get("code") != 0
        or not isinstance(backups, list)
    ):
        raise LockedJobError("pgBackRest stanza is missing, ambiguous or unhealthy")
    normalized: list[dict[str, Any]] = []
    labels: set[str] = set()
    for item in backups:
        if not isinstance(item, dict) or item.get("error", False) is not False:
            raise LockedJobError("pgBackRest inventory contains an unhealthy backup")
        label = item.get("label")
        backup_type = item.get("type")
        timestamp = item.get("timestamp")
        stop_epoch = timestamp.get("stop") if isinstance(timestamp, dict) else None
        if (
            not isinstance(label, str)
            or not BACKUP_LABEL_RE.fullmatch(label)
            or label in labels
            or backup_type not in {"full", "diff", "incr"}
            or isinstance(stop_epoch, bool)
            or not isinstance(stop_epoch, int)
            or stop_epoch < 1
        ):
            raise LockedJobError("pgBackRest inventory backup identity is invalid")
        labels.add(label)
        normalized.append(
            {"label": label, "type": backup_type, "stopEpoch": stop_epoch}
        )
    normalized.sort(key=lambda item: item["label"])
    return {
        "repository": repository,
        "stanza": "uten-imp",
        "backups": normalized,
        "inventorySha256": _sha256(_canonical_bytes(normalized)),
    }


def _inventory_labels(value: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    backups = value.get("backups")
    if not isinstance(backups, list):
        raise LockedJobError("transaction inventory backup list is malformed")
    return {str(item["label"]): item for item in backups if isinstance(item, dict)}


def _exact_new_full(
    before: Mapping[str, Any], after: Mapping[str, Any], repository: int
) -> dict[str, Any]:
    normalized_before = _validate_inventory(before, repository)
    normalized_after = _validate_inventory(after, repository)
    old = _inventory_labels(normalized_before)
    new = _inventory_labels(normalized_after)
    if not set(old).issubset(new):
        raise LockedJobError("pgBackRest inventory lost a pre-existing backup before expire")
    added = sorted(set(new) - set(old))
    if len(added) != 1 or new[added[0]].get("type") != "full":
        raise LockedJobError("backup command did not produce exactly one new successful full")
    return dict(new[added[0]])


def _validate_after_expire(
    post_backup: Mapping[str, Any], final: Mapping[str, Any], committed_label: str, repository: int
) -> None:
    post = _inventory_labels(_validate_inventory(post_backup, repository))
    current = _inventory_labels(_validate_inventory(final, repository))
    if committed_label not in current or not set(current).issubset(post):
        raise LockedJobError("post-expire inventory lost the committed full or gained an unknown backup")


def _postgres_identity() -> tuple[int, int]:
    if pwd is None:
        raise LockedJobError("the fixed postgres service identity requires POSIX pwd support")
    try:
        record = pwd.getpwnam(POSTGRES_USER)
    except KeyError as exc:
        raise LockedJobError("the fixed postgres service identity does not exist") from exc
    if record.pw_uid == 0 or record.pw_gid == 0:
        raise LockedJobError("the postgres service identity must be non-root")
    return record.pw_uid, record.pw_gid


def _require_root_supervisor() -> None:
    if os.geteuid() != 0 or os.getegid() != 0:
        raise LockedJobError(
            "the fixed backup supervisor must run as root and drop every child to postgres"
        )


def _assert_safe_root_directory(path: Path) -> os.stat_result:
    try:
        details = path.lstat()
    except OSError as exc:
        raise LockedJobError("a fixed release-state parent cannot be safely inspected") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or details.st_uid != 0
        or details.st_mode & 0o022
    ):
        raise LockedJobError(
            "a fixed release-state parent must be a root-owned non-writable directory"
        )
    return details


def assert_no_release_transaction_markers() -> None:
    """Fail if a fixed transaction gate exists or its parent cannot be proven safe."""

    for parent in (Path("/"), Path("/var"), Path("/var/lib")):
        _assert_safe_root_directory(parent)
    assert_no_commissioner_transaction_marker()
    try:
        before = RELEASE_STATE_DIRECTORY.lstat()
    except FileNotFoundError:
        # Phase 2 creates the local backup before the release runtime exists.
        # A missing leaf under the already-proven /var/lib chain cannot conceal
        # any of the four fixed children.
        return
    except OSError as exc:
        raise LockedJobError("the fixed release-state directory cannot be inspected") from exc
    if (
        not stat.S_ISDIR(before.st_mode)
        or before.st_uid != 0
        or before.st_mode & 0o022
    ):
        raise LockedJobError(
            "the fixed release-state directory is symlinked, non-root or writable"
        )
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        descriptor = os.open(RELEASE_STATE_DIRECTORY, flags)
    except OSError as exc:
        raise LockedJobError("the fixed release-state directory cannot be safely opened") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_mode & 0o022
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise LockedJobError("the fixed release-state directory changed during inspection")
        for marker_name in RELEASE_TRANSACTION_MARKERS:
            try:
                os.stat(marker_name, dir_fd=descriptor, follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise LockedJobError(
                    "a fixed release transaction marker cannot be safely inspected"
                ) from exc
            raise LockedJobError("a release activation or recovery transaction gate is present")
    finally:
        os.close(descriptor)
def assert_no_commissioner_transaction_marker() -> None:
    """Block jobs throughout a staged backup-automation commissioning transaction."""

    for parent in (Path("/"), Path("/var"), Path("/var/lib")):
        _assert_safe_root_directory(parent)
    try:
        before = COMMISSIONER_STATE_DIRECTORY.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise LockedJobError("the fixed backup commissioner directory cannot be inspected") from exc
    if (
        not stat.S_ISDIR(before.st_mode)
        or COMMISSIONER_STATE_DIRECTORY.is_symlink()
        or before.st_uid != 0
        or before.st_gid != 0
        or stat.S_IMODE(before.st_mode) != 0o700
    ):
        raise LockedJobError(
            "the fixed backup commissioner directory must be root:root 0700"
        )
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        descriptor = os.open(COMMISSIONER_STATE_DIRECTORY, flags)
    except OSError as exc:
        raise LockedJobError("the fixed backup commissioner directory cannot be safely opened") from exc
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise LockedJobError("the backup commissioner directory changed during inspection")
        try:
            os.stat(
                COMMISSIONER_ACTIVE_TRANSACTION.name,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return
        except OSError as exc:
            raise LockedJobError(
                "the backup commissioner transaction marker cannot be safely inspected"
            ) from exc
        raise TerminalLockedJobError(
            "a staged backup commissioner transaction blocks automatic backup jobs"
        )
    finally:
        os.close(descriptor)


def assert_health_state_directory() -> None:
    """Require the fixed postgres-writable leaf without weakening root evidence."""

    for parent in (Path("/"), Path("/var"), Path("/var/lib")):
        _assert_safe_root_directory(parent)
    _, postgres_gid = _postgres_identity()
    try:
        before = HEALTH_STATE_DIRECTORY.lstat()
    except OSError as exc:
        raise LockedJobError("the fixed backup-health state directory is unavailable") from exc
    if (
        not stat.S_ISDIR(before.st_mode)
        or before.st_uid != 0
        or before.st_gid != postgres_gid
        or stat.S_IMODE(before.st_mode) != 0o770
    ):
        raise LockedJobError(
            "the backup-health state directory must be root:postgres mode 0770"
        )
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        descriptor = os.open(HEALTH_STATE_DIRECTORY, flags)
    except OSError as exc:
        raise LockedJobError(
            "the fixed backup-health state directory cannot be safely opened"
        ) from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_gid != postgres_gid
            or stat.S_IMODE(opened.st_mode) != 0o770
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise LockedJobError(
                "the fixed backup-health state directory changed during inspection"
            )
    finally:
        os.close(descriptor)


class MaintenanceLock(AbstractContextManager["MaintenanceLock"]):
    """Securely open and non-blockingly hold the fixed database-maintenance lock."""

    def __init__(self, *, read_only: bool = False) -> None:
        self.descriptor: int | None = None
        self.read_only = read_only

    def __enter__(self) -> "MaintenanceLock":
        if os.name != "posix" or fcntl is None or not hasattr(os, "O_NOFOLLOW"):
            raise LockedJobError("the database maintenance lock requires POSIX flock and O_NOFOLLOW")
        _require_root_supervisor()
        _, postgres_gid = _postgres_identity()
        try:
            directory = MAINTENANCE_DIRECTORY.lstat()
        except FileNotFoundError as exc:
            raise LockedJobError("the fixed database maintenance directory is missing") from exc
        if (
            not stat.S_ISDIR(directory.st_mode)
            or directory.st_uid != 0
            or directory.st_gid != postgres_gid
            or stat.S_IMODE(directory.st_mode) != 0o750
        ):
            raise LockedJobError(
                "the database maintenance directory must be root:postgres mode 0750"
            )

        flags = (
            (os.O_RDONLY if self.read_only else os.O_RDWR)
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0)
        )
        try:
            before = MAINTENANCE_LOCK.lstat()
            descriptor = os.open(MAINTENANCE_LOCK, flags)
        except OSError as exc:
            raise LockedJobError("the fixed database maintenance lock cannot be opened") from exc
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_gid != postgres_gid
            or stat.S_IMODE(opened.st_mode) != 0o660
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            os.close(descriptor)
            raise LockedJobError(
                "the database maintenance lock must be one root:postgres 0660 regular file"
            )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(descriptor)
            raise LockedJobError("another database maintenance operation is already running") from exc
        except OSError as exc:
            os.close(descriptor)
            raise LockedJobError("the database maintenance lock could not be acquired") from exc
        self.descriptor = descriptor
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor is not None:
            assert fcntl is not None
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


def _run_fixed(command: tuple[str, ...]) -> None:
    postgres_uid, postgres_gid = _postgres_identity()
    subprocess.run(
        list(command),
        check=True,
        stdin=subprocess.DEVNULL,
        env=dict(FIXED_ENVIRONMENT),
        user=postgres_uid,
        group=postgres_gid,
        extra_groups=(),
        umask=0o077,
    )


def _run_fixed_capture(command: tuple[str, ...]) -> bytes:
    postgres_uid, postgres_gid = _postgres_identity()
    try:
        completed = subprocess.run(
            list(command),
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=dict(FIXED_ENVIRONMENT),
            user=postgres_uid,
            group=postgres_gid,
            extra_groups=(),
            umask=0o077,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LockedJobError("fixed pgBackRest inventory command could not complete") from exc
    if completed.returncode != 0 or len(completed.stdout) > MAX_EVIDENCE_BYTES:
        raise LockedJobError("fixed pgBackRest inventory command failed")
    return completed.stdout


def capture_inventory(repository: int) -> dict[str, Any]:
    if repository not in (1, 2):
        raise LockedJobError("fixed backup repository is invalid")
    raw = _run_fixed_capture(PGBACKREST_INFO_BASE + (f"--repo={repository}", "info"))
    return parse_pgbackrest_inventory(raw, repository)


def _command_sha(command: tuple[str, ...]) -> str:
    return _sha256(_canonical_bytes(list(command)))


def _base_transaction(
    job_name: str,
    repository: int,
    pre_inventory: Mapping[str, Any],
    backup_command: tuple[str, ...],
    expire_command: tuple[str, ...],
) -> dict[str, Any]:
    created = _utc_now()
    return {
        "schemaVersion": TRANSACTION_SCHEMA_VERSION,
        "kind": TRANSACTION_KIND,
        "transactionId": (
            datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
            + secrets.token_hex(16)
        ),
        "job": job_name,
        "repository": repository,
        "phase": "running",
        "createdAtUtc": created,
        "updatedAtUtc": created,
        "preInventory": _validate_inventory(pre_inventory, repository),
        "backupCommandSha256": _command_sha(backup_command),
        "expireCommandSha256": _command_sha(expire_command),
    }


def _validate_transaction(value: Mapping[str, Any], job_name: str) -> dict[str, Any]:
    plan = JOB_PLANS.get(job_name)
    if plan is None or plan.repository not in (1, 2) or plan.backup_step is None:
        raise LockedJobError("backup transaction job is invalid")
    repository = plan.repository
    base_keys = {
        "schemaVersion",
        "kind",
        "transactionId",
        "job",
        "repository",
        "phase",
        "createdAtUtc",
        "updatedAtUtc",
        "preInventory",
        "backupCommandSha256",
        "expireCommandSha256",
    }
    phase = value.get("phase")
    phase_keys = {
        "running": set(),
        "committed": {"postBackupInventory", "committedBackup", "committedAtUtc"},
        "expire-pending": {
            "postBackupInventory",
            "committedBackup",
            "committedAtUtc",
            "expireStartedAtUtc",
        },
        "complete": {
            "postBackupInventory",
            "committedBackup",
            "committedAtUtc",
            "expireStartedAtUtc",
            "finalInventory",
            "completedAtUtc",
        },
        "uncertain": {
            "lastProvenPhase",
            "uncertainAtUtc",
            "uncertainReason",
            "provenPostBackupInventory",
            "provenCommittedBackup",
            "provenCommittedAtUtc",
            "provenExpireStartedAtUtc",
        },
    }
    if phase not in phase_keys or set(value) != base_keys | phase_keys[str(phase)]:
        raise LockedJobError("backup transaction phase schema differs")
    if (
        value.get("schemaVersion") != TRANSACTION_SCHEMA_VERSION
        or value.get("kind") != TRANSACTION_KIND
        or value.get("job") != job_name
        or value.get("repository") != repository
        or not isinstance(value.get("transactionId"), str)
        or not TRANSACTION_ID_RE.fullmatch(str(value["transactionId"]))
        or not SHA256_RE.fullmatch(str(value.get("backupCommandSha256", "")))
        or not SHA256_RE.fullmatch(str(value.get("expireCommandSha256", "")))
    ):
        raise LockedJobError("backup transaction identity is invalid")
    backup_command = plan.steps[plan.backup_step - 1]
    expire_command = plan.steps[plan.backup_step]
    if (
        value.get("backupCommandSha256") != _command_sha(backup_command)
        or value.get("expireCommandSha256") != _command_sha(expire_command)
    ):
        raise LockedJobError("backup transaction fixed-command binding differs")
    result = dict(value)
    result["preInventory"] = _validate_inventory(value["preInventory"], repository)

    def validate_committed(prefix: str = "") -> None:
        inventory_key = (
            "postBackupInventory" if not prefix else prefix + "PostBackupInventory"
        )
        backup_key = "committedBackup" if not prefix else prefix + "CommittedBackup"
        inventory = _validate_inventory(value[inventory_key], repository)
        backup = value.get(backup_key)
        if not isinstance(backup, dict) or set(backup) != {"label", "type", "stopEpoch"}:
            raise LockedJobError("backup transaction committed-backup evidence is malformed")
        expected = _exact_new_full(result["preInventory"], inventory, repository)
        if dict(backup) != expected:
            raise LockedJobError("backup transaction committed-backup evidence differs")
        result[inventory_key] = inventory

    if phase in {"committed", "expire-pending", "complete"}:
        validate_committed()
    if phase == "complete":
        result["finalInventory"] = _validate_inventory(value["finalInventory"], repository)
        _validate_after_expire(
            result["postBackupInventory"],
            result["finalInventory"],
            result["committedBackup"]["label"],
            repository,
        )
    if phase == "uncertain":
        last = value.get("lastProvenPhase")
        if last not in {"running", "committed", "expire-pending"}:
            raise LockedJobError("backup transaction uncertain boundary is invalid")
        proven = (
            value.get("provenPostBackupInventory"),
            value.get("provenCommittedBackup"),
            value.get("provenCommittedAtUtc"),
            value.get("provenExpireStartedAtUtc"),
        )
        if last == "running" and proven != (None, None, None, None):
            raise LockedJobError("running uncertainty must not claim committed evidence")
        if last in {"committed", "expire-pending"}:
            validate_committed("proven")
            if not isinstance(value.get("provenCommittedAtUtc"), str):
                raise LockedJobError("committed uncertainty lacks its timestamp")
            if last == "committed" and value.get("provenExpireStartedAtUtc") is not None:
                raise LockedJobError("committed uncertainty falsely claims expire start")
            if last == "expire-pending" and not isinstance(
                value.get("provenExpireStartedAtUtc"), str
            ):
                raise LockedJobError("expire uncertainty lacks its timestamp")
        reason = value.get("uncertainReason")
        if not isinstance(reason, str) or not re.fullmatch(r"[a-z0-9-]{3,64}", reason):
            raise LockedJobError("backup transaction uncertainty reason is invalid")
    return result


def _load_active(job_name: str) -> tuple[dict[str, Any], bytes]:
    value, raw = _bounded_root_json(_active_path(job_name), "active backup transaction")
    return _validate_transaction(value, job_name), raw


def _write_active(job_name: str, value: Mapping[str, Any], *, replace: bool) -> bytes:
    validated = _validate_transaction(value, job_name)
    return _atomic_root_json(_active_path(job_name), validated, replace=replace)


def assert_no_pending_backup_transactions() -> None:
    assert_transaction_layout()
    pending: list[str] = []
    for job_name, path in ACTIVE_TRANSACTION_PATHS.items():
        if not os.path.lexists(path):
            continue
        _load_active(job_name)
        pending.append(job_name)
    if pending:
        raise TerminalLockedJobError(
            "an unresolved durable backup transaction blocks every automatic backup job: "
            + ",".join(sorted(pending))
        )


class DurableBackupTransaction:
    def __init__(
        self,
        job_name: str,
        *,
        inventory_provider: Callable[[int], dict[str, Any]] = capture_inventory,
    ) -> None:
        plan = JOB_PLANS.get(job_name)
        if plan is None or plan.repository not in (1, 2) or plan.backup_step is None:
            raise LockedJobError("durable transaction requires repo1 or repo2")
        self.job_name = job_name
        self.plan = plan
        self.repository = plan.repository
        self.inventory_provider = inventory_provider
        self.record: dict[str, Any] | None = None

    def begin(self) -> None:
        assert_no_pending_backup_transactions()
        pre = self.inventory_provider(self.repository)
        backup_command = self.plan.steps[self.plan.backup_step - 1]
        expire_command = self.plan.steps[self.plan.backup_step]
        record = _base_transaction(
            self.job_name,
            self.repository,
            pre,
            backup_command,
            expire_command,
        )
        _write_active(self.job_name, record, replace=False)
        self.record = record

    def _require_record(self) -> dict[str, Any]:
        if self.record is None:
            raise LockedJobError("durable backup transaction was not started")
        return self.record

    def _replace(self, record: Mapping[str, Any]) -> None:
        validated = _validate_transaction(record, self.job_name)
        _write_active(self.job_name, validated, replace=True)
        self.record = validated

    def backup_returned_success(self) -> None:
        record = self._require_record()
        try:
            post = self.inventory_provider(self.repository)
            committed = _exact_new_full(
                record["preInventory"], post, self.repository
            )
        except BaseException as exc:
            self.mark_uncertain("backup-post-inventory-unavailable")
            raise TerminalLockedJobError(
                "backup returned success but exact committed inventory could not be proven"
            ) from exc
        updated = {
            **record,
            "phase": "committed",
            "updatedAtUtc": _utc_now(),
            "postBackupInventory": post,
            "committedBackup": committed,
            "committedAtUtc": _utc_now(),
        }
        self._replace(updated)

    def mark_expire_pending(self) -> None:
        record = self._require_record()
        if record.get("phase") != "committed":
            raise LockedJobError("expire may begin only after committed evidence")
        self._replace(
            {
                **record,
                "phase": "expire-pending",
                "updatedAtUtc": _utc_now(),
                "expireStartedAtUtc": _utc_now(),
            }
        )

    def mark_uncertain(self, reason: str) -> None:
        record = self._require_record()
        phase = str(record.get("phase"))
        if phase == "uncertain":
            return
        if phase not in {"running", "committed", "expire-pending"}:
            raise LockedJobError("only an incomplete backup transaction can become uncertain")
        uncertain = {
            key: value
            for key, value in record.items()
            if key
            in {
                "schemaVersion",
                "kind",
                "transactionId",
                "job",
                "repository",
                "createdAtUtc",
                "preInventory",
                "backupCommandSha256",
                "expireCommandSha256",
            }
        }
        uncertain.update(
            {
                "phase": "uncertain",
                "updatedAtUtc": _utc_now(),
                "lastProvenPhase": phase,
                "uncertainAtUtc": _utc_now(),
                "uncertainReason": reason,
                "provenPostBackupInventory": record.get("postBackupInventory"),
                "provenCommittedBackup": record.get("committedBackup"),
                "provenCommittedAtUtc": record.get("committedAtUtc"),
                "provenExpireStartedAtUtc": record.get("expireStartedAtUtc"),
            }
        )
        self._replace(uncertain)

    def complete(self) -> tuple[dict[str, Any], str]:
        record = self._require_record()
        if record.get("phase") != "expire-pending":
            raise LockedJobError("backup transaction cannot complete before expire")
        try:
            final = self.inventory_provider(self.repository)
            _validate_after_expire(
                record["postBackupInventory"],
                final,
                record["committedBackup"]["label"],
                self.repository,
            )
        except BaseException as exc:
            self.mark_uncertain("expire-post-inventory-unavailable")
            raise TerminalLockedJobError(
                "expire returned success but final inventory could not be proven"
            ) from exc
        completed = {
            **record,
            "phase": "complete",
            "updatedAtUtc": _utc_now(),
            "finalInventory": final,
            "completedAtUtc": _utc_now(),
        }
        self._replace(completed)
        receipt = {
            "schemaVersion": TRANSACTION_SCHEMA_VERSION,
            "kind": TRANSACTION_RECEIPT_KIND,
            "transaction": completed,
            "containsSecrets": False,
        }
        receipt_path = TRANSACTION_RECEIPT_DIRECTORY / (
            f"{self.job_name}-{completed['transactionId']}.json"
        )
        receipt_raw = _atomic_root_json(receipt_path, receipt, replace=False)
        _durable_unlink(_active_path(self.job_name))
        return receipt, _sha256(receipt_raw)


def run_job(
    job_name: str,
    *,
    lock_factory: Callable[[], AbstractContextManager[object]] = MaintenanceLock,
    runner: Callable[[tuple[str, ...]], None] = _run_fixed,
    marker_gate: Callable[[], None] = assert_no_release_transaction_markers,
    health_state_gate: Callable[[], None] = assert_health_state_directory,
    pending_gate: Callable[[], None] = assert_no_pending_backup_transactions,
    transaction_factory: Callable[[str], DurableBackupTransaction] = DurableBackupTransaction,
) -> None:
    try:
        plan = JOB_PLANS[job_name]
    except KeyError as exc:
        raise LockedJobError("unknown fixed backup job") from exc
    if plan.backup_step is not None and (
        plan.backup_step < 1
        or plan.backup_step >= len(plan.steps)
        or plan.steps[plan.backup_step - 1][-1] != "backup"
        or plan.steps[plan.backup_step][-1] != "expire"
    ):
        raise LockedJobError("the fixed backup success boundary is malformed")
    backup_completed = False
    transaction_started = False
    transaction: DurableBackupTransaction | None = None
    try:
        with lock_factory():
            pending_gate()
            if plan.backup_step is None:
                for index, command in enumerate(plan.steps, start=1):
                    marker_gate()
                    if job_name == "health" and index == 1:
                        health_state_gate()
                    runner(command)
                marker_gate()
                return

            assert plan.repository in (1, 2)
            assert plan.backup_step is not None
            for index, command in enumerate(
                plan.steps[: plan.backup_step - 1], start=1
            ):
                marker_gate()
                try:
                    runner(command)
                except subprocess.CalledProcessError as exc:
                    error_type = (
                        TerminalLockedJobError if exc.returncode < 0 else LockedJobError
                    )
                    raise error_type(
                        f"fixed {job_name} job failed at reviewed step {index} with exit {exc.returncode}"
                    ) from exc
            marker_gate()
            transaction = transaction_factory(job_name)
            transaction.begin()
            transaction_started = True
            backup_command = plan.steps[plan.backup_step - 1]
            try:
                runner(backup_command)
            except BaseException as exc:
                try:
                    transaction.mark_uncertain("backup-command-interrupted")
                except BaseException:
                    # The durable running phase remains authoritative if even
                    # the best-effort uncertainty transition cannot complete.
                    pass
                if isinstance(exc, subprocess.CalledProcessError):
                    detail = f"exit {exc.returncode}"
                else:
                    detail = type(exc).__name__
                raise TerminalLockedJobError(
                    f"fixed {job_name} backup command ended with uncertain commit state ({detail})"
                ) from exc
            transaction.backup_returned_success()
            backup_completed = True
            try:
                marker_gate()
            except LockedJobError as exc:
                raise TerminalLockedJobError(
                    "a release gate appeared after the full backup; durable reconcile is required"
                ) from exc
            transaction.mark_expire_pending()
            expire_command = plan.steps[plan.backup_step]
            try:
                runner(expire_command)
            except BaseException as exc:
                try:
                    transaction.mark_uncertain("expire-command-interrupted")
                except BaseException:
                    pass
                raise TerminalLockedJobError(
                    f"fixed {job_name} expire command ended at an uncertain boundary"
                ) from exc
            marker_gate()
            transaction.complete()
            marker_gate()
    except TerminalLockedJobError:
        raise
    except BaseException as exc:
        # This outer boundary also covers failures in the lock context manager
        # and unexpected exceptions from a fixed runner or marker gate. Once a
        # full backup returned success, no later failure may auto-create another
        # full. A signal/timeout is terminal even earlier because commit state is
        # unknowable to the supervisor.
        uncertain_interruption = isinstance(
            exc, (KeyboardInterrupt, SystemExit, subprocess.TimeoutExpired)
        ) or (isinstance(exc, subprocess.CalledProcessError) and exc.returncode < 0)
        pending_exists = False
        if job_name in ACTIVE_TRANSACTION_PATHS:
            try:
                pending_exists = os.path.lexists(_active_path(job_name))
            except BaseException:
                pending_exists = True
        if backup_completed or transaction_started or pending_exists or uncertain_interruption:
            raise TerminalLockedJobError(
                f"fixed {job_name} job ended with durable committed/uncertain evidence; automatic retry is blocked"
            ) from exc
        if isinstance(exc, LockedJobError):
            raise
        raise LockedJobError(
            f"fixed {job_name} job failed before the backup success boundary"
        ) from exc


def _runtime_quiescence(job_name: str) -> dict[str, Any]:
    unit = {
        "repo1": "uten-pgbackup.service",
        "repo2": "uten-pgbackup-repo2.service",
    }.get(job_name)
    if unit is None:
        raise LockedJobError("reconcile runtime observation job is invalid")
    command = [
        "/usr/bin/systemctl",
        "show",
        unit,
        "--property=LoadState",
        "--property=ActiveState",
        "--property=SubState",
        "--property=MainPID",
        "--property=Result",
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            env={
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            },
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LockedJobError("systemd backup runtime could not be observed") from exc
    if completed.returncode != 0:
        raise LockedJobError("systemd backup runtime observation failed")
    properties: dict[str, str] = {}
    expected = {"LoadState", "ActiveState", "SubState", "MainPID", "Result"}
    for line in completed.stdout.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in expected or key in properties:
            raise LockedJobError("systemd backup runtime observation is malformed")
        properties[key] = value
    if set(properties) != expected:
        raise LockedJobError("systemd backup runtime observation is incomplete")
    try:
        processes = subprocess.run(
            ["/usr/bin/pgrep", "--exact", "pgbackrest"],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            env={
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            },
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LockedJobError("pgBackRest process state could not be observed") from exc
    if processes.returncode not in (0, 1):
        raise LockedJobError("pgBackRest process observation failed")
    quiescent = (
        properties["LoadState"] == "loaded"
        and properties["ActiveState"] == "inactive"
        and properties["MainPID"] == "0"
        and processes.returncode == 1
    )
    return {
        "unit": unit,
        "loadState": properties["LoadState"],
        "activeState": properties["ActiveState"],
        "subState": properties["SubState"],
        "mainPid": properties["MainPID"],
        "result": properties["Result"],
        "pgBackRestProcessPresent": processes.returncode == 0,
        "quiescent": quiescent,
    }


def _classification(
    record: Mapping[str, Any], current: Mapping[str, Any]
) -> tuple[str, str]:
    job_name = str(record["job"])
    repository = int(record["repository"])
    current_inventory = _validate_inventory(current, repository)
    pre = _validate_inventory(record["preInventory"], repository)
    pre_labels = _inventory_labels(pre)
    current_labels = _inventory_labels(current_inventory)
    phase = record.get("phase")
    if phase == "complete":
        final = _validate_inventory(record["finalInventory"], repository)
        if current_inventory == final:
            return "finalize-complete", "durable complete phase matches current inventory"
        return "none", "current inventory differs from durable complete evidence"

    committed_inventory: Mapping[str, Any] | None = None
    committed_backup: Mapping[str, Any] | None = None
    if phase in {"committed", "expire-pending"}:
        committed_inventory = record["postBackupInventory"]
        committed_backup = record["committedBackup"]
    elif phase == "uncertain" and record.get("lastProvenPhase") in {
        "committed",
        "expire-pending",
    }:
        committed_inventory = record["provenPostBackupInventory"]
        committed_backup = record["provenCommittedBackup"]

    if committed_inventory is not None and committed_backup is not None:
        post = _inventory_labels(_validate_inventory(committed_inventory, repository))
        label = str(committed_backup["label"])
        if label in current_labels and set(current_labels).issubset(post):
            return "resume-expire", "exact committed full remains and no unknown backup exists"
        return "none", "committed full is missing or current inventory gained an unknown backup"

    if set(current_labels) == set(pre_labels) and all(
        current_labels[label] == pre_labels[label] for label in pre_labels
    ):
        return "abort-retry", "current inventory exactly matches the pre-backup inventory"
    try:
        _exact_new_full(pre, current_inventory, repository)
    except LockedJobError:
        return "none", "current inventory cannot prove zero or exactly one new successful full"
    return "resume-expire", "current inventory proves exactly one new successful full"


def _transaction_assessment_locked(
    job_name: str,
    *,
    inventory_provider: Callable[[int], dict[str, Any]] = capture_inventory,
    runtime_observer: Callable[[str], dict[str, Any]] = _runtime_quiescence,
) -> dict[str, Any]:
    record, raw = _load_active(job_name)
    runtime = runtime_observer(job_name)
    current = inventory_provider(int(record["repository"]))
    action, reason = _classification(record, current)
    if runtime.get("quiescent") is not True:
        action = "none"
        reason = "backup service or pgBackRest process is not quiescent"
    return {
        "schemaVersion": 1,
        "kind": "uten-imp-backup-transaction-read-only-assessment",
        "job": job_name,
        "transactionId": record["transactionId"],
        "activeEvidencePath": str(_active_path(job_name)),
        "activeEvidenceSha256": _sha256(raw),
        "durablePhase": record["phase"],
        "currentInventory": _validate_inventory(
            current, int(record["repository"])
        ),
        "runtime": runtime,
        "eligibleAction": action,
        "reason": reason,
        "containsSecrets": False,
    }


def transaction_assess(
    job_name: str,
    *,
    lock_factory: Callable[[], AbstractContextManager[object]] = lambda: MaintenanceLock(
        read_only=True
    ),
    inventory_provider: Callable[[int], dict[str, Any]] = capture_inventory,
    runtime_observer: Callable[[str], dict[str, Any]] = _runtime_quiescence,
) -> tuple[dict[str, Any], str]:
    _require_root_supervisor()
    assert_transaction_layout()
    with lock_factory():
        assessment = _transaction_assessment_locked(
            job_name,
            inventory_provider=inventory_provider,
            runtime_observer=runtime_observer,
        )
    digest = _sha256(_canonical_bytes(assessment))
    return {
        "assessment": assessment,
        "assessmentSha256": digest,
    }, digest


def _write_or_verify_reconcile_receipt(path: Path, value: Mapping[str, Any]) -> bytes:
    expected = _canonical_bytes(dict(value))
    if os.path.lexists(path):
        _existing, raw = _bounded_root_json(path, "backup reconcile receipt")
        if raw != expected:
            raise LockedJobError("existing backup reconcile receipt bytes differ")
        return raw
    return _atomic_root_json(path, value, replace=False)


def _normal_completion_receipt(record: Mapping[str, Any]) -> tuple[dict[str, Any], Path]:
    receipt = {
        "schemaVersion": TRANSACTION_SCHEMA_VERSION,
        "kind": TRANSACTION_RECEIPT_KIND,
        "transaction": dict(record),
        "containsSecrets": False,
    }
    path = TRANSACTION_RECEIPT_DIRECTORY / (
        f"{record['job']}-{record['transactionId']}.json"
    )
    return receipt, path


def transaction_reconcile(
    job_name: str,
    *,
    action: str,
    expected_active_sha256: str,
    expected_assessment_sha256: str,
    confirmation: str,
    lock_factory: Callable[[], AbstractContextManager[object]] = MaintenanceLock,
    inventory_provider: Callable[[int], dict[str, Any]] = capture_inventory,
    runtime_observer: Callable[[str], dict[str, Any]] = _runtime_quiescence,
    runner: Callable[[tuple[str, ...]], None] = _run_fixed,
    marker_gate: Callable[[], None] = assert_no_release_transaction_markers,
) -> tuple[dict[str, Any], str]:
    _require_root_supervisor()
    assert_transaction_layout()
    confirmations = {
        "abort-retry": RECONCILE_ABORT_CONFIRMATION,
        "resume-expire": RECONCILE_EXPIRE_CONFIRMATION,
        "finalize-complete": RECONCILE_COMPLETE_CONFIRMATION,
    }
    if action not in confirmations or confirmation != confirmations[action]:
        raise LockedJobError("reconcile action/typed confirmation differs")
    if not SHA256_RE.fullmatch(expected_active_sha256) or not SHA256_RE.fullmatch(
        expected_assessment_sha256
    ):
        raise LockedJobError("reconcile evidence SHA-256 is malformed")
    with lock_factory():
        marker_gate()
        assessment = _transaction_assessment_locked(
            job_name,
            inventory_provider=inventory_provider,
            runtime_observer=runtime_observer,
        )
        actual_assessment_sha = _sha256(_canonical_bytes(assessment))
        if (
            assessment["activeEvidenceSha256"] != expected_active_sha256
            or actual_assessment_sha != expected_assessment_sha256
            or assessment["eligibleAction"] != action
        ):
            raise LockedJobError("reconcile evidence/action changed after approval")
        record, active_raw = _load_active(job_name)
        if _sha256(active_raw) != expected_active_sha256:
            raise LockedJobError("active backup transaction changed after assessment")
        reconcile_receipt = {
            "schemaVersion": 1,
            "kind": RECONCILE_RECEIPT_KIND,
            "transactionId": record["transactionId"],
            "job": job_name,
            "action": action,
            "activeEvidenceSha256": expected_active_sha256,
            "assessmentSha256": expected_assessment_sha256,
            "approvedEvidenceUpdatedAtUtc": record["updatedAtUtc"],
            "containsSecrets": False,
        }
        reconcile_path = TRANSACTION_RECEIPT_DIRECTORY / (
            f"{job_name}-{record['transactionId']}-reconcile-{action}-"
            f"{expected_assessment_sha256}.json"
        )
        reconcile_raw = _write_or_verify_reconcile_receipt(
            reconcile_path, reconcile_receipt
        )
        if action == "abort-retry":
            _durable_unlink(_active_path(job_name))
            result = {
                **reconcile_receipt,
                "status": "ABORTED_WITH_PROVEN_NO_NEW_BACKUP",
                "receiptPath": str(reconcile_path),
            }
            return result, _sha256(reconcile_raw)
        if action == "finalize-complete":
            completion_receipt, completion_path = _normal_completion_receipt(record)
            _write_or_verify_reconcile_receipt(completion_path, completion_receipt)
            _durable_unlink(_active_path(job_name))
            result = {
                **reconcile_receipt,
                "status": "FINALIZED_ALREADY_COMPLETE",
                "receiptPath": str(reconcile_path),
                "completionReceiptPath": str(completion_path),
            }
            return result, _sha256(reconcile_raw)

        plan = JOB_PLANS[job_name]
        assert plan.repository in (1, 2) and plan.backup_step is not None
        if record["phase"] in {"committed", "expire-pending"}:
            post_inventory = record["postBackupInventory"]
            committed = record["committedBackup"]
            committed_at = record["committedAtUtc"]
        elif record["phase"] == "uncertain" and record.get("lastProvenPhase") in {
            "committed",
            "expire-pending",
        }:
            post_inventory = record["provenPostBackupInventory"]
            committed = record["provenCommittedBackup"]
            committed_at = record["provenCommittedAtUtc"]
        else:
            post_inventory = assessment["currentInventory"]
            committed = _exact_new_full(
                record["preInventory"], post_inventory, plan.repository
            )
            committed_at = _utc_now()
        committed_record = {
            key: value
            for key, value in record.items()
            if key
            in {
                "schemaVersion",
                "kind",
                "transactionId",
                "job",
                "repository",
                "createdAtUtc",
                "preInventory",
                "backupCommandSha256",
                "expireCommandSha256",
            }
        }
        committed_record.update(
            {
                "phase": "committed",
                "updatedAtUtc": _utc_now(),
                "postBackupInventory": post_inventory,
                "committedBackup": committed,
                "committedAtUtc": committed_at,
            }
        )
        transaction = DurableBackupTransaction(
            job_name, inventory_provider=inventory_provider
        )
        transaction.record = _validate_transaction(committed_record, job_name)
        transaction._replace(transaction.record)
        marker_gate()
        transaction.mark_expire_pending()
        expire_command = plan.steps[plan.backup_step]
        try:
            runner(expire_command)
        except BaseException as exc:
            try:
                transaction.mark_uncertain("expire-command-interrupted")
            except BaseException:
                pass
            raise TerminalLockedJobError(
                "evidence-bound reconcile attempted only expire, but its result is uncertain"
            ) from exc
        marker_gate()
        _completion, completion_sha = transaction.complete()
        result = {
            **reconcile_receipt,
            "status": "EXPIRE_ONLY_COMPLETED",
            "receiptPath": str(reconcile_path),
            "completionReceiptSha256": completion_sha,
        }
        return result, _sha256(reconcile_raw)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "action",
        choices=(
            "repo1",
            "repo2",
            "health",
            "transaction-assess",
            "transaction-reconcile",
        ),
    )
    result.add_argument("transaction_job", nargs="?", choices=("repo1", "repo2"))
    result.add_argument(
        "--reconcile-action",
        choices=("abort-retry", "resume-expire", "finalize-complete"),
    )
    result.add_argument("--expected-active-sha256")
    result.add_argument("--expected-assessment-sha256")
    result.add_argument("--confirm")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.action in JOB_PLANS:
            if (
                args.transaction_job is not None
                or args.reconcile_action is not None
                or args.expected_active_sha256 is not None
                or args.expected_assessment_sha256 is not None
                or args.confirm is not None
            ):
                raise LockedJobError("automatic fixed job does not accept reconcile arguments")
            run_job(args.action)
            return 0
        if args.transaction_job is None:
            raise LockedJobError("transaction command requires repo1 or repo2")
        if args.action == "transaction-assess":
            if any(
                value is not None
                for value in (
                    args.reconcile_action,
                    args.expected_active_sha256,
                    args.expected_assessment_sha256,
                    args.confirm,
                )
            ):
                raise LockedJobError("read-only transaction assess accepts no write arguments")
            envelope, _ = transaction_assess(args.transaction_job)
            sys.stdout.buffer.write(_canonical_bytes(envelope))
            return 0
        if any(
            value is None
            for value in (
                args.reconcile_action,
                args.expected_active_sha256,
                args.expected_assessment_sha256,
                args.confirm,
            )
        ):
            raise LockedJobError("transaction reconcile requires action, hashes and confirmation")
        receipt, receipt_sha = transaction_reconcile(
            args.transaction_job,
            action=args.reconcile_action,
            expected_active_sha256=args.expected_active_sha256,
            expected_assessment_sha256=args.expected_assessment_sha256,
            confirmation=args.confirm,
        )
        sys.stdout.buffer.write(
            _canonical_bytes(
                {
                    "status": receipt["status"],
                    "receiptPath": receipt["receiptPath"],
                    "receiptSha256": receipt_sha,
                    "containsSecrets": False,
                }
            )
        )
        return 0
    except TerminalLockedJobError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 78
    except LockedJobError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
