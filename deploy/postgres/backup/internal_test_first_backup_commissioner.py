#!/usr/bin/env python3
"""Commission the first local pgBackRest recovery layer for internal-test.

The read-only assessment takes no locks and writes nothing.  ``record-plan``
records exact reviewed authority and stages a new root-only repo1 cipher without
activating it.  ``apply``/``resume`` hold the release-operation lock first and
the shared database-maintenance lock second.  Every durable phase is O_EXCL and
hash-linked.  The repository boundary is recorded before stanza-create; after
that boundary this program never removes repository/WAL bytes or automatically
rolls configuration back.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import pwd
import re
import secrets
import stat
import subprocess
import sys
import time
import types
from contextlib import AbstractContextManager, nullcontext
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, NoReturn, Sequence

try:
    import fcntl
except ImportError:  # pragma: no cover - production is POSIX only.
    fcntl = None  # type: ignore[assignment]


SCHEMA_VERSION = 1
ASSESSMENT_KIND = "uten-imp-internal-test-first-backup-assessment"
PLAN_KIND = "uten-imp-internal-test-first-backup-plan"
PHASE_KIND = "uten-imp-internal-test-first-backup-phase"
TERMINAL_KIND = "uten-imp-internal-test-first-backup-commissioning-receipt"
ROLLBACK_KIND = "uten-imp-internal-test-first-backup-pre-repository-rollback"

RECORD_CONFIRMATION = "RECORD REVIEWED INTERNAL TEST FIRST BACKUP PLAN"
APPLY_CONFIRMATION = "APPLY REVIEWED INTERNAL TEST FIRST BACKUP PLAN"
ROLLBACK_CONFIRMATION = "ROLLBACK BEFORE INTERNAL TEST BACKUP REPOSITORY MUTATION"

STATE_ROOT = Path("/var/lib/uten-imp-internal-test-backup-commissioner")
PLAN_PATH = STATE_ROOT / "commission-plan.json"
STAGED_CIPHER = STATE_ROOT / "repo1.cipher.staged"
TRANSACTIONS_ROOT = STATE_ROOT / "transactions"
RECEIPTS_ROOT = STATE_ROOT / "receipts"
ACTIVE_PATH = STATE_ROOT / "active-transaction.json"
FIRST_BACKUP_RECEIPT = Path(
    "/var/lib/uten-imp-internal-test-first-backup/first-backup.json"
)

RELEASE_ROOT = Path("/var/lib/uten-imp-release")
RELEASE_LOCK = RELEASE_ROOT / "operation.lock"
MAINTENANCE_ROOT = Path("/var/lib/uten-imp-db-maintenance")
MAINTENANCE_LOCK = MAINTENANCE_ROOT / "operation.lock"

INSTALLED_ROOT = Path("/usr/local/libexec/uten-imp-backup")
INSTALLED_COMMISSIONER = INSTALLED_ROOT / "internal_test_first_backup_commissioner.py"
INSTALLED_PRODUCER = INSTALLED_ROOT / "internal_test_first_backup.py"
INSTALLED_LOCKED_JOB = INSTALLED_ROOT / "locked_job.py"
INSTALLER_RECEIPT = Path("/var/lib/uten-imp-backup-installer/uncommissioned-install.json")

PGBACKREST_CONFIG = Path("/etc/pgbackrest.conf")
PGBACKREST_INCLUDE_ROOT = Path("/etc/pgbackrest")
PGBACKREST_INCLUDE_DIR = Path("/etc/pgbackrest/conf.d")
ARCHIVE_OVERRIDE = Path(
    "/etc/postgresql/16/main/conf.d/zz-uten-imp-internal-test-backup.conf"
)
INTERNAL_TEST_ARCHIVE_DISABLED = Path(
    "/etc/postgresql/16/main/conf.d/99-uten-imp-internal-test.conf"
)
CIPHER_DIRECTORY = Path("/etc/uten-imp-postgres/pgbackrest")
CIPHER_TARGET = CIPHER_DIRECTORY / "repo1.cipher"
REPOSITORY = Path("/data/backups/pgbackrest")
PGDATA = Path("/data/postgresql/16/main")
PGBACKREST_SERVICE = "uten-pgbackup.service"
PGBACKREST_TIMER = "uten-pgbackup.timer"
PGBACKREST_SERVICE_FILE = Path("/etc/systemd/system/uten-pgbackup.service")
PGBACKREST_TIMER_FILE = Path("/etc/systemd/system/uten-pgbackup.timer")
POSTGRES_UNIT = "postgresql@16-main.service"

MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_SOURCE_BYTES = 4 * 1024 * 1024
MIN_FREE_BYTES = 4 * 1024 * 1024 * 1024
MIN_FREE_PERCENT = 20
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

ARCHIVE_OVERRIDE_BYTES = (
    b"# Uten IMP internal-test local-recovery-only archive authority.\n"
    b"# This does not grant restore or production authority.\n"
    b"archive_mode = on\n"
    b"archive_command = 'pgbackrest --stanza=uten-imp archive-push %p'\n"
)

PGBACKREST_BASE = (
    "/usr/bin/pgbackrest",
    "--config=/etc/pgbackrest.conf",
    "--config-include-path=/etc/pgbackrest/conf.d",
    "--stanza=uten-imp",
)
STANZA_CREATE = PGBACKREST_BASE + ("--repo=1", "stanza-create")
REPO_CHECK = PGBACKREST_BASE + ("--repo=1", "check")
REPO_INFO = PGBACKREST_BASE + ("--repo=1", "--output=json", "info")

FIXED_ENV = {
    "HOME": "/var/lib/postgresql",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "LOGNAME": "postgres",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "USER": "postgres",
}

TIMER_UNITS = (
    "uten-imp-entry-watchdog.timer",
    "uten-imp-watchdog.timer",
    "uten-imp-updater.timer",
    "uten-pgbackup.timer",
    "uten-pgbackup-repo2.timer",
    "uten-pgbackup-health.timer",
    "uten-pgbackup-alert-drain.timer",
)
QUIESCENT_SERVICES = (
    "nginx.service",
    "uten-imp.service",
    "uten-imp-entry-watchdog.service",
    "uten-imp-watchdog.service",
    "uten-imp-updater.service",
    "uten-pgbackup.service",
    "uten-pgbackup-repo2.service",
    "uten-pgbackup-health.service",
    "uten-pgbackup-alert-drain.service",
)
EXTERNAL_MARKERS = (
    RELEASE_ROOT / "activation-failed.json",
    RELEASE_ROOT / "activation-in-progress.json",
    RELEASE_ROOT / "boot-enablement-in-progress.json",
    RELEASE_ROOT / "recovery-in-progress.json",
    RELEASE_ROOT / "recovery-ingress-pending.json",
    RELEASE_ROOT / "recovery-ingress-authorization.json",
    RELEASE_ROOT / "recovery-ingress-finalizing.json",
    RELEASE_ROOT / "internal-test-onboarding-adoption.json",
    RELEASE_ROOT / "internal-test-activation-reauthorization.json",
    Path("/run/uten-imp-release/start-authorization.json"),
    Path("/run/uten-imp-migration-authorization/migration-authorization.json"),
    Path("/var/lib/uten-imp-internal-test-commissioning/active.json"),
    Path("/var/lib/uten-imp-internal-test-host-preparation/mutation-active.json"),
    Path("/var/lib/uten-imp-nvme-commissioning/active.json"),
    Path("/var/lib/uten-imp-backup-installer/active-transaction.json"),
    Path("/var/lib/uten-imp-backup-commissioner/active-transaction.json"),
    Path("/var/lib/uten-imp-backup-transactions/repo1.active.json"),
    Path("/var/lib/uten-imp-backup-transactions/repo2.active.json"),
)

PHASES = (
    "started",
    "preimages-captured",
    "configuration-installed",
    "daemon-reloaded",
    "postgres-restart-authorized",
    "postgres-restarted-verified",
    "repository-mutation-authorized",
    "stanza-created-check-passed",
    "pid1-full-authorized",
    "pid1-full-complete",
    "first-backup-receipt-authorized",
    "first-backup-receipt-complete",
    "terminal",
)
REPOSITORY_BOUNDARY = "repository-mutation-authorized"


class CommissioningError(RuntimeError):
    """The controlled first-backup transaction cannot proceed."""


def fail(message: str) -> NoReturn:
    raise CommissioningError(message)


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or re.fullmatch(
        r"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z",
        value,
    ) is None:
        fail(f"{label} is not a strict UTC timestamp")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise CommissioningError(f"{label} is not a real UTC timestamp") from exc


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _reject_constant(value: str) -> NoReturn:
    fail(f"non-finite JSON constant is forbidden: {value}")


def strict_json_value_bytes(raw: bytes, label: str) -> Any:
    if not raw or len(raw) > MAX_JSON_BYTES or b"\0" in raw or raw.startswith(b"\xef\xbb\xbf"):
        fail(f"{label} bytes are outside the strict bound")
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise CommissioningError(f"{label} is not strict UTF-8") from exc

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                fail(f"{label} contains duplicate key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(text, object_pairs_hook=pairs, parse_constant=_reject_constant)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise CommissioningError(f"{label} is invalid strict JSON") from exc
    return value


def strict_json_bytes(raw: bytes, label: str) -> dict[str, Any]:
    value = strict_json_value_bytes(raw, label)
    if not isinstance(value, dict):
        fail(f"{label} must be one JSON object")
    return value


def _require_root() -> None:
    if os.name != "posix" or fcntl is None or not hasattr(os, "O_NOFOLLOW"):
        fail("commissioning requires POSIX flock and O_NOFOLLOW")
    if os.geteuid() != 0:
        fail("commissioning must run as root")


def _root_chain(path: Path) -> None:
    current = path
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise CommissioningError(f"trusted parent is unavailable: {current}") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or current.is_symlink()
            or details.st_uid != 0
            or details.st_mode & 0o022
        ):
            fail(f"trusted parent escaped root control: {current}")
        if current == Path("/"):
            return
        current = current.parent


def capture_file(
    path: Path,
    label: str,
    *,
    uid: int = 0,
    gid: int | None = None,
    mode: int | None = None,
    maximum: int = MAX_SOURCE_BYTES,
) -> tuple[bytes, dict[str, Any]]:
    _root_chain(path.parent)
    try:
        before = path.lstat()
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    except OSError as exc:
        raise CommissioningError(f"{label} cannot be stably opened: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != uid
            or (gid is not None and opened.st_gid != gid)
            or (mode is not None and stat.S_IMODE(opened.st_mode) != mode)
            or opened.st_nlink != 1
            or opened.st_size < 0
            or opened.st_size > maximum
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            fail(f"{label} metadata differs from its fixed contract: {path}")
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                fail(f"{label} was truncated during capture: {path}")
            chunks.append(block)
            remaining -= len(block)
        if os.read(descriptor, 1):
            fail(f"{label} grew during capture: {path}")
        after = path.lstat()
        final = os.fstat(descriptor)
        identity = (opened.st_dev, opened.st_ino, opened.st_size, opened.st_nlink)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_nlink) or identity != (
            final.st_dev,
            final.st_ino,
            final.st_size,
            final.st_nlink,
        ):
            fail(f"{label} path changed during capture: {path}")
        raw = b"".join(chunks)
        return raw, {
            "dev": opened.st_dev,
            "gid": opened.st_gid,
            "ino": opened.st_ino,
            "mode": stat.S_IMODE(opened.st_mode),
            "nlink": opened.st_nlink,
            "path": str(path),
            "sha256": sha256_bytes(raw),
            "size": len(raw),
            "uid": opened.st_uid,
        }
    finally:
        os.close(descriptor)


def _safe_directory(path: Path, *, uid: int, gid: int, mode: int) -> os.stat_result:
    _root_chain(path.parent)
    try:
        before = path.lstat()
        flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_DIRECTORY", 0)
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise CommissioningError(f"required directory cannot be opened: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != uid
            or opened.st_gid != gid
            or stat.S_IMODE(opened.st_mode) != mode
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            fail(f"required directory metadata differs: {path}")
        return opened
    finally:
        os.close(descriptor)


def _directory_entries(path: Path, *, uid: int, gid: int, mode: int) -> tuple[os.stat_result, list[str]]:
    details = _safe_directory(path, uid=uid, gid=gid, mode=mode)
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        entries = sorted(os.listdir(descriptor))
        after = os.fstat(descriptor)
        if (after.st_dev, after.st_ino) != (details.st_dev, details.st_ino):
            fail(f"directory changed during inventory: {path}")
        return after, entries
    finally:
        os.close(descriptor)


def _read_root_json(path: Path, label: str, *, mode: int = 0o600) -> tuple[dict[str, Any], bytes]:
    raw, _ = capture_file(path, label, mode=mode, maximum=MAX_JSON_BYTES)
    value = strict_json_bytes(raw, label)
    if raw != canonical_bytes(value):
        fail(f"{label} is not canonical JSON")
    return value, raw


def _atomic_write(
    path: Path,
    raw: bytes,
    *,
    uid: int,
    gid: int,
    mode: int,
    replace: bool,
) -> None:
    _root_chain(path.parent)
    parent_flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    parent_flags |= getattr(os, "O_DIRECTORY", 0)
    parent_fd = os.open(path.parent, parent_flags)
    temporary = f".{path.name}.commission.{os.getpid()}.{secrets.token_hex(8)}"
    descriptor = -1
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=parent_fd,
        )
        os.fchown(descriptor, uid, gid)
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            if written <= 0:
                fail(f"durable write made no progress: {path}")
            offset += written
        os.fsync(descriptor)
        created = os.fstat(descriptor)
        os.close(descriptor)
        descriptor = -1
        if replace:
            os.replace(temporary, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        else:
            _rename_noreplace(path.parent / temporary, path)
        os.fsync(parent_fd)
        verified_raw, verified = capture_file(path, "published file", uid=uid, gid=gid, mode=mode, maximum=max(MAX_JSON_BYTES, len(raw)))
        if verified_raw != raw or (verified["dev"], verified["ino"]) != (created.st_dev, created.st_ino):
            fail(f"published bytes or identity changed: {path}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        os.close(parent_fd)


def _rename_noreplace(source: Path, destination: Path) -> None:
    """Linux atomic publication with no overwrite or hard-link interval."""

    if os.name != "posix":
        fail("atomic no-replace publication requires Linux renameat2")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
    except (AttributeError, OSError) as exc:
        raise CommissioningError("Linux libc renameat2 is unavailable") from exc
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    result = renameat2(
        -100,
        os.fsencode(source),
        -100,
        os.fsencode(destination),
        1,
    )
    if result == 0:
        return
    number = ctypes.get_errno()
    if number == errno.EEXIST:
        raise CommissioningError(f"exclusive evidence path already exists: {destination}")
    if number == errno.ENOSYS:
        fail("running kernel lacks renameat2(RENAME_NOREPLACE)")
    raise CommissioningError(
        f"atomic no-replace publication failed: {destination}: errno={number}"
    )


def _exclusive_json(path: Path, value: Mapping[str, Any]) -> str:
    raw = canonical_bytes(dict(value))
    _atomic_write(path, raw, uid=0, gid=0, mode=0o600, replace=False)
    return sha256_bytes(raw)


def _durable_unlink(path: Path) -> None:
    _root_chain(path.parent)
    parent_fd = os.open(
        path.parent,
        os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.unlink(path.name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _durable_rmdir(path: Path) -> None:
    _root_chain(path.parent)
    parent_fd = os.open(
        path.parent,
        os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0),
    )
    try:
        os.rmdir(path.name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _interrupted_temporary_pattern(path: Path) -> re.Pattern[str]:
    return re.compile(
        rf"^\.{re.escape(path.name)}\.commission\.[1-9][0-9]*\.[0-9a-f]{{16}}$"
    )


def _remove_interrupted_temporaries(
    path: Path,
    *,
    uid: int,
    gid: int,
    mode: int,
    maximum: int,
) -> None:
    """Remove only unpublished same-target temp in the reversible boundary."""

    if not os.path.lexists(path.parent):
        return
    _root_chain(path.parent)
    pattern = _interrupted_temporary_pattern(path)
    for candidate in sorted(path.parent.iterdir(), key=lambda item: item.name):
        if pattern.fullmatch(candidate.name) is None:
            continue
        _raw, observation = capture_file(
            candidate,
            "interrupted unpublished temporary",
            uid=uid,
            maximum=maximum,
        )
        allowed_metadata = {
            (0, 0o600),
            (gid, 0o600),
            (gid, mode),
        }
        if (observation["gid"], observation["mode"]) not in allowed_metadata:
            fail(f"interrupted temporary metadata is not a writer stage: {candidate}")
        _durable_unlink(candidate)


def _exec_captured(raw: bytes, path: Path, name: str) -> Any:
    if not raw or b"\0" in raw or len(raw) > MAX_SOURCE_BYTES:
        fail(f"captured Python source is outside the reviewed boundary: {path}")
    try:
        code = compile(raw, str(path), "exec", dont_inherit=True)
    except (SyntaxError, UnicodeDecodeError) as exc:
        raise CommissioningError(f"captured Python source cannot compile: {path}") from exc
    module = types.ModuleType(name)
    module.__file__ = str(path)
    previous = sys.modules.get(name)
    sys.modules[name] = module
    try:
        exec(code, module.__dict__)
    except BaseException:
        if previous is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = previous
        raise
    return module


def load_producer() -> tuple[Any, dict[str, Any]]:
    raw, observation = capture_file(
        INSTALLED_PRODUCER,
        "installed first-backup producer",
        mode=0o755,
        maximum=2 * 1024 * 1024,
    )
    module = _exec_captured(raw, INSTALLED_PRODUCER, "uten_first_backup_producer_for_commissioning")
    for name in (
        "load_authority",
        "observe_live_database",
        "produce_first_backup_receipt",
        "parse_latest_full",
        "find_locked_job_receipt",
    ):
        if not callable(getattr(module, name, None)):
            fail(f"installed first-backup producer lacks reviewed API: {name}")
    return module, observation


def assert_external_markers_absent() -> None:
    for marker in EXTERNAL_MARKERS:
        parent = marker.parent
        while not os.path.lexists(parent):
            if parent == Path("/"):
                fail(f"blocking marker has no authenticated parent: {marker}")
            parent = parent.parent
        _root_chain(parent)
        if parent != marker.parent:
            continue
        flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_DIRECTORY", 0)
        descriptor = os.open(parent, flags)
        try:
            try:
                os.stat(marker.name, dir_fd=descriptor, follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise CommissioningError(
                    f"blocking marker cannot be safely inspected: {marker}"
                ) from exc
            fail(f"blocking release/commissioning marker is present: {marker}")
        finally:
            os.close(descriptor)


class MaintenanceLock(AbstractContextManager["MaintenanceLock"]):
    def __init__(self) -> None:
        self.descriptor = -1

    def __enter__(self) -> "MaintenanceLock":
        _require_root()
        postgres = pwd.getpwnam("postgres")
        _safe_directory(MAINTENANCE_ROOT, uid=0, gid=postgres.pw_gid, mode=0o750)
        before = MAINTENANCE_LOCK.lstat()
        descriptor = os.open(
            MAINTENANCE_LOCK,
            os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
        )
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_gid != postgres.pw_gid
            or stat.S_IMODE(opened.st_mode) != 0o660
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            os.close(descriptor)
            fail("database maintenance lock differs from root:postgres 0660 single-link contract")
        try:
            assert fcntl is not None
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(descriptor)
            raise CommissioningError("database maintenance is already in progress") from exc
        self.descriptor = descriptor
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor >= 0:
            assert fcntl is not None
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


def _run(command: Sequence[str], *, timeout: int = 60, stdout: bool = True) -> subprocess.CompletedProcess[bytes]:
    try:
        completed = subprocess.run(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if stdout else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"},
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CommissioningError(f"fixed command could not complete: {command[0]}") from exc
    if completed.returncode != 0 or len(completed.stdout or b"") > MAX_JSON_BYTES:
        fail(f"fixed command exited non-zero: {command[0]}")
    return completed


def _run_as_postgres(command: Sequence[str], *, timeout: int = 600, capture: bool = False) -> bytes:
    try:
        completed = subprocess.run(
            ["/usr/sbin/runuser", "-u", "postgres", "--", *command],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=FIXED_ENV,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CommissioningError("fixed pgBackRest command could not complete") from exc
    output = completed.stdout or b""
    if completed.returncode != 0 or len(output) > MAX_JSON_BYTES:
        fail("fixed pgBackRest command exited non-zero")
    return output


SYSTEMD_PROPERTIES = (
    "LoadState",
    "ActiveState",
    "SubState",
    "UnitFileState",
    "MainPID",
    "FragmentPath",
    "DropInPaths",
    "User",
    "Group",
    "ExecStart",
)


def observe_unit(unit: str) -> dict[str, Any]:
    command = ["/usr/bin/systemctl", "show", unit, "--no-pager"]
    for name in SYSTEMD_PROPERTIES:
        command.extend(("--property", name))
    raw = _run(command).stdout
    values: dict[str, str] = {}
    for line in raw.decode("utf-8", errors="strict").splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in values or key not in SYSTEMD_PROPERTIES:
            fail(f"systemd returned malformed properties for {unit}")
        values[key] = value
    if set(values) != set(SYSTEMD_PROPERTIES):
        fail(f"systemd omitted fixed properties for {unit}")
    try:
        pid = int(values.pop("MainPID"))
    except ValueError as exc:
        raise CommissioningError(f"systemd MainPID is malformed for {unit}") from exc
    return {**values, "MainPID": pid}


def observe_systemd() -> dict[str, Any]:
    timers = {unit: observe_unit(unit) for unit in TIMER_UNITS}
    services = {unit: observe_unit(unit) for unit in QUIESCENT_SERVICES}
    postgres = observe_unit(POSTGRES_UNIT)
    for unit, value in timers.items():
        if (
            value["LoadState"] != "loaded"
            or value["UnitFileState"] != "disabled"
            or value["ActiveState"] not in {"inactive", "failed"}
            or value["MainPID"] != 0
        ):
            fail(f"timer is not installed, disabled and stopped: {unit}")
    for unit, value in services.items():
        if value["LoadState"] != "loaded" or value["ActiveState"] not in {"inactive", "failed"} or value["MainPID"] != 0:
            fail(f"entry/runtime service is not stopped: {unit}")
    backup = services[PGBACKREST_SERVICE]
    if (
        backup["FragmentPath"] != str(PGBACKREST_SERVICE_FILE)
        or backup["DropInPaths"]
        or backup["User"] not in {"", "root"}
        or backup["Group"] not in {"", "root"}
        or "/usr/local/libexec/uten-imp-backup/locked_job.py repo1" not in backup["ExecStart"]
    ):
        fail("PID1 repo1 service differs from the fixed locked_job contract")
    timer = timers[PGBACKREST_TIMER]
    if timer["FragmentPath"] != str(PGBACKREST_TIMER_FILE) or timer["DropInPaths"]:
        fail("repo1 timer differs from its fixed no-drop-in contract")
    if postgres["LoadState"] != "loaded" or postgres["ActiveState"] != "active" or postgres["MainPID"] <= 1:
        fail("PostgreSQL instance is not one active PID1-owned unit")
    return {"postgres": postgres, "services": services, "timers": timers}


def observe_loopback() -> dict[str, Any]:
    raw = _run(["/usr/bin/ss", "-H", "-ltn", "sport", "=", ":5432"]).stdout
    endpoints: list[str] = []
    for line in raw.decode("utf-8", errors="strict").splitlines():
        columns = line.split()
        if len(columns) < 4:
            fail("loopback listener observation is malformed")
        endpoint = columns[3]
        if endpoint.endswith(":5432"):
            endpoints.append(endpoint)
    if not endpoints or any(
        endpoint.startswith(("0.0.0.0:", "*:", "[::]:"))
        or not endpoint.startswith(("127.0.0.1:", "[::1]:"))
        for endpoint in endpoints
    ):
        fail("PostgreSQL 5432 is not loopback-only")
    return {"endpoints": sorted(set(endpoints)), "outputSha256": sha256_bytes(raw)}


def _database_identity(producer: Any, authority: Mapping[str, Any], *, archive_on: bool) -> dict[str, Any]:
    if archive_on:
        return producer.observe_live_database(authority)
    updater = authority["updater"]
    observed = updater.observe_live_database()
    evidence = updater.validate_live_database_against_signed_release(
        observed,
        target_manifest=authority["info"],
        require_internal_role_acl=False,
    )
    if observed.get("archiveMode") != "off" or observed.get("archiveCommand") not in {"", None} or observed.get("inRecovery") is not False:
        fail("preimage PostgreSQL must be writable with archive_mode=off and empty archive_command")
    expected_acl = updater.internal_test_role_acl_contract()
    if observed.get("roleAclContract") != expected_acl:
        fail("internal-test role/ACL contract changed")
    identity = {
        "canonicalHistorySha256": evidence["flyway"]["canonicalHistorySha256"],
        "headVersion": evidence["flyway"]["headVersion"],
        "roleAclContractSha256": hashlib.sha256(
            json.dumps(expected_acl, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest(),
        "signedProjectionSha256": evidence["flyway"]["signedProjectionSha256"],
        "successfulMigrationCount": evidence["flyway"]["successfulMigrationCount"],
        "systemIdentifier": evidence["systemIdentifier"],
        "timeline": evidence["timeline"],
    }
    if identity != authority["onboarding"].get("databaseIdentity"):
        fail("live database identity/Flyway projection differs from onboarding")
    return identity


def _observe_blank_config(postgres_gid: int) -> dict[str, Any]:
    if not os.path.lexists(PGBACKREST_CONFIG):
        return {"state": "absent"}
    raw, observation = capture_file(
        PGBACKREST_CONFIG,
        "pgBackRest preimage",
        gid=postgres_gid,
        mode=0o640,
        maximum=64 * 1024,
    )
    for line in raw.decode("utf-8", errors="strict").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            fail("existing pgBackRest config is not an empty/comment-only new-cluster preimage")
    return {"state": "file", **observation}


def _observe_absent(path: Path, label: str) -> dict[str, Any]:
    if os.path.lexists(path):
        fail(f"{label} must be absent before commissioning: {path}")
    parent = path.parent
    while not os.path.lexists(parent):
        if parent == Path("/"):
            fail(f"{label} has no authenticated existing parent: {path}")
        parent = parent.parent
    _root_chain(parent)
    return {"state": "absent", "path": str(path)}


def _observe_repository(postgres_uid: int, postgres_gid: int) -> dict[str, Any]:
    details, entries = _directory_entries(REPOSITORY, uid=postgres_uid, gid=postgres_gid, mode=0o750)
    if entries:
        fail("repo1 is not empty; old or partially initialized repositories are refused")
    return {
        "dev": details.st_dev,
        "entries": entries,
        "gid": details.st_gid,
        "ino": details.st_ino,
        "mode": 0o750,
        "path": str(REPOSITORY),
        "state": "empty-directory",
        "uid": details.st_uid,
    }


def _observe_optional_directory(
    path: Path,
    *,
    uid: int,
    gid: int,
    mode: int,
    allowed_entries: set[str],
) -> dict[str, Any]:
    if not os.path.lexists(path):
        _observe_absent(path, "optional directory")
        return {"path": str(path), "state": "absent"}
    details, entries = _directory_entries(path, uid=uid, gid=gid, mode=mode)
    if set(entries) - allowed_entries:
        fail(f"optional directory contains an unknown preimage: {path}")
    return {
        "dev": details.st_dev,
        "entries": entries,
        "gid": gid,
        "ino": details.st_ino,
        "mode": mode,
        "path": str(path),
        "state": "directory",
        "uid": uid,
    }


def _database_size_bytes() -> int:
    raw = _run_as_postgres(
        (
            "/usr/bin/psql",
            "-X",
            "-A",
            "-t",
            "-v",
            "ON_ERROR_STOP=1",
            "-d",
            "uten_imp",
            "-c",
            "SELECT pg_database_size(current_database())::bigint;",
        ),
        timeout=60,
        capture=True,
    ).strip()
    if not raw.isdigit():
        fail("live database size query returned a non-integer")
    return int(raw)


def _capacity(database_size: int) -> dict[str, Any]:
    value = os.statvfs(REPOSITORY)
    free = value.f_bavail * value.f_frsize
    total = value.f_blocks * value.f_frsize
    required = max(MIN_FREE_BYTES, database_size * 2 + 1024 * 1024 * 1024)
    percent = (free * 100 // total) if total else 0
    if free < required or percent < MIN_FREE_PERCENT:
        fail("repo1 capacity is below the reviewed first-full headroom")
    return {
        "databaseSizeBytes": database_size,
        "freeBytesFloorGiB": free // (1024**3),
        "freePercent": percent,
        "requiredBytes": required,
        "totalBytesFloorGiB": total // (1024**3),
    }


def _asset_observations(postgres_gid: int) -> dict[str, Any]:
    specifications = (
        (INSTALLED_COMMISSIONER, 0, 0, 0o755, "commissioner"),
        (INSTALLED_PRODUCER, 0, 0, 0o755, "producer"),
        (INSTALLED_LOCKED_JOB, 0, 0, 0o755, "lockedJob"),
        (PGBACKREST_SERVICE_FILE, 0, 0, 0o644, "repo1Service"),
        (PGBACKREST_TIMER_FILE, 0, 0, 0o644, "repo1Timer"),
        (INSTALLER_RECEIPT, 0, 0, 0o600, "installerReceipt"),
        (INTERNAL_TEST_ARCHIVE_DISABLED, 0, 0, 0o644, "archiveDisabledPreimage"),
    )
    result: dict[str, Any] = {}
    for path, uid, gid, mode, name in specifications:
        _raw, observation = capture_file(path, name, uid=uid, gid=gid, mode=mode)
        result[name] = observation
    return result


def _pgbackrest_tool_observation() -> dict[str, Any]:
    _raw, binary = capture_file(
        Path("/usr/bin/pgbackrest"),
        "pgBackRest binary",
        mode=0o755,
        maximum=32 * 1024 * 1024,
    )
    output = _run(["/usr/bin/pgbackrest", "version"]).stdout
    try:
        version = output.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError as exc:
        raise CommissioningError("pgBackRest version is not strict UTF-8") from exc
    if re.fullmatch(r"pgBackRest [0-9]+(?:\.[0-9]+){1,3}", version) is None:
        fail("pgBackRest version output is malformed")
    return {
        "binary": binary,
        "version": version,
        "versionOutputSha256": sha256_bytes(output),
    }


def _authority_summary(authority: Mapping[str, Any]) -> dict[str, Any]:
    contract = authority["contract"]
    storage = {
        key: contract[key]
        for key in sorted(contract)
        if key.startswith("storage") and (key.endswith("Sha256") or key.endswith("Path"))
    }
    return {
        "candidate": authority["fingerprintFields"]["candidateBinding"],
        "candidatePayloadInventorySha256": authority["fingerprintFields"]["candidatePayloadInventorySha256"],
        "fingerprint": authority["fingerprint"],
        "onboardingReceiptSha256": authority["fingerprintFields"]["onboardingSha256"],
        "onboardingStatus": authority["onboarding"]["status"],
        "onboardingTransactionId": authority["onboarding"]["transactionId"],
        "runtimeContractSha256": authority["fingerprintFields"]["runtimeContractSha256"],
        "storage": storage,
        "transactionManifestSha256": authority["fingerprintFields"]["transactionManifestSha256"],
    }


def _stable_binding(assessment: Mapping[str, Any]) -> dict[str, Any]:
    systemd = assessment["systemd"]
    postgres = dict(systemd["postgres"])
    postgres.pop("MainPID", None)
    return {
        "archiveOverridePreimage": assessment["archiveOverridePreimage"],
        "assets": assessment["assets"],
        "authority": assessment["authority"],
        "cipherDirectoryPreimage": assessment["cipherDirectoryPreimage"],
        "cipherTargetPreimage": assessment["cipherTargetPreimage"],
        "databaseIdentity": assessment["databaseIdentity"],
        "firstBackupReceiptPreimage": assessment["firstBackupReceiptPreimage"],
        "loopbackEndpoints": assessment["loopback"]["endpoints"],
        "pgBackRestTool": assessment["pgBackRestTool"],
        "pgBackRestIncludeDirPreimage": assessment["pgBackRestIncludeDirPreimage"],
        "pgBackRestIncludeRootPreimage": assessment["pgBackRestIncludeRootPreimage"],
        "pgBackRestConfigPreimage": assessment["pgBackRestConfigPreimage"],
        "postgresSystemd": postgres,
        "repository": assessment["repository"],
        "services": systemd["services"],
        "timers": systemd["timers"],
    }


def build_assessment(
    *,
    producer_loader: Callable[[], tuple[Any, dict[str, Any]]] = load_producer,
    systemd_observer: Callable[[], dict[str, Any]] = observe_systemd,
    loopback_observer: Callable[[], dict[str, Any]] = observe_loopback,
    allow_active: bool = False,
) -> dict[str, Any]:
    _require_root()
    if os.path.lexists(ACTIVE_PATH) and not allow_active:
        fail("an interrupted first-backup transaction requires resume")
    if os.path.lexists(RECEIPTS_ROOT / "terminal.json"):
        fail("first-backup commissioning is already terminal")
    assert_external_markers_absent()
    postgres = pwd.getpwnam("postgres")
    _safe_directory(STATE_ROOT, uid=0, gid=0, mode=0o700)
    _safe_directory(TRANSACTIONS_ROOT, uid=0, gid=0, mode=0o700)
    _safe_directory(RECEIPTS_ROOT, uid=0, gid=0, mode=0o700)
    producer, _producer_source = producer_loader()
    producer.assert_no_markers()
    authority = producer.load_authority()
    identity = _database_identity(producer, authority, archive_on=False)
    repository = _observe_repository(postgres.pw_uid, postgres.pw_gid)
    assessment = {
        "assets": _asset_observations(postgres.pw_gid),
        "archiveOverridePreimage": _observe_absent(
            ARCHIVE_OVERRIDE, "archive override"
        ),
        "authority": _authority_summary(authority),
        "capacity": _capacity(_database_size_bytes()),
        "cipherDirectoryPreimage": _observe_optional_directory(
            CIPHER_DIRECTORY,
            uid=0,
            gid=postgres.pw_gid,
            mode=0o750,
            allowed_entries=set(),
        ),
        "cipherTargetPreimage": _observe_absent(
            CIPHER_TARGET, "repo1 cipher target"
        ),
        "databaseIdentity": identity,
        "deploymentProfile": "internal-test",
        "firstBackupReceiptPreimage": _observe_absent(
            FIRST_BACKUP_RECEIPT, "first-backup receipt"
        ),
        "loopback": loopback_observer(),
        "pgBackRestConfigPreimage": _observe_blank_config(postgres.pw_gid),
        "pgBackRestIncludeDirPreimage": _observe_optional_directory(
            PGBACKREST_INCLUDE_DIR,
            uid=0,
            gid=0,
            mode=0o755,
            allowed_entries=set(),
        ),
        "pgBackRestIncludeRootPreimage": _observe_optional_directory(
            PGBACKREST_INCLUDE_ROOT,
            uid=0,
            gid=0,
            mode=0o755,
            allowed_entries={"conf.d"},
        ),
        "pgBackRestTool": _pgbackrest_tool_observation(),
        "repository": repository,
        "systemd": systemd_observer(),
    }
    assessment["stableBindingSha256"] = sha256_bytes(canonical_bytes(_stable_binding(assessment)))
    return assessment


def assess(**kwargs: Any) -> tuple[dict[str, Any], str]:
    assessment = build_assessment(**kwargs)
    digest = sha256_bytes(canonical_bytes(assessment))
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": ASSESSMENT_KIND,
        "assessmentSha256": digest,
        "assessment": assessment,
    }, digest


def _render_pgbackrest(secret: bytes) -> bytes:
    try:
        value = secret.decode("ascii").strip()
    except UnicodeDecodeError as exc:
        raise CommissioningError("staged repo1 cipher is not ASCII") from exc
    if re.fullmatch(r"[0-9a-f]{64}", value) is None or secret != (value + "\n").encode("ascii"):
        fail("staged repo1 cipher must be one generated 64-lowercase-hex line")
    return (
        "[global]\n"
        "repo1-path=/data/backups/pgbackrest\n"
        "repo1-cipher-type=aes-256-cbc\n"
        f"repo1-cipher-pass={value}\n"
        "repo1-retention-full-type=count\n"
        "repo1-retention-full=7\n"
        "repo1-retention-archive-type=full\n"
        "repo1-hardlink=y\n"
        "repo1-bundle=y\n"
        "process-max=4\n"
        "log-level-console=info\n"
        "log-level-file=detail\n"
        "start-fast=y\n"
        "stop-auto=y\n"
        "spool-path=/var/spool/pgbackrest\n\n"
        "[uten-imp]\n"
        "pg1-path=/data/postgresql/16/main\n"
        "pg1-port=5432\n"
    ).encode("utf-8")


def _default_release_lock(producer: Any) -> AbstractContextManager[Any]:
    authority = producer.load_authority()
    return authority["updater"].StateLock(RELEASE_LOCK)


def record_plan(
    *,
    expected_assessment_sha256: str,
    confirmation: str,
    assessor: Callable[[], dict[str, Any]] = build_assessment,
    producer_loader: Callable[[], tuple[Any, dict[str, Any]]] = load_producer,
    release_lock_factory: Callable[[], AbstractContextManager[Any]] | None = None,
    token_hex: Callable[[int], str] = secrets.token_hex,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != RECORD_CONFIRMATION or SHA256_RE.fullmatch(expected_assessment_sha256) is None:
        fail("record-plan confirmation or assessment SHA-256 differs")
    if os.path.lexists(ACTIVE_PATH):
        fail("an active first-backup transaction already exists")
    if os.path.lexists(PLAN_PATH):
        existing, existing_raw = _read_root_json(PLAN_PATH, "existing first-backup plan")
        existing, _ = _load_plan(sha256_bytes(existing_raw))
        if existing.get("assessmentSha256") != expected_assessment_sha256:
            fail("existing first-backup plan names another assessment")
        _secret, secret_observation = capture_file(
            STAGED_CIPHER, "staged repo1 cipher", mode=0o600, maximum=128
        )
        if secret_observation["sha256"] != existing.get("repo1CipherSha256"):
            fail("existing first-backup plan lost its staged cipher binding")
        return existing, sha256_bytes(existing_raw)
    producer, _ = producer_loader()
    lock = release_lock_factory() if release_lock_factory else _default_release_lock(producer)
    with lock:
        assert_external_markers_absent()
        producer.assert_no_markers()
        current = assessor()
        if sha256_bytes(canonical_bytes(current)) != expected_assessment_sha256:
            fail("read-only assessment changed before plan recording")
        if not os.path.lexists(STAGED_CIPHER):
            secret = (token_hex(32) + "\n").encode("ascii")
            _render_pgbackrest(secret)
            _atomic_write(STAGED_CIPHER, secret, uid=0, gid=0, mode=0o600, replace=False)
        secret, secret_observation = capture_file(STAGED_CIPHER, "staged repo1 cipher", mode=0o600, maximum=128)
        target = _render_pgbackrest(secret)
        plan = {
            "assessment": current,
            "assessmentSha256": expected_assessment_sha256,
            "archiveOverrideSha256": sha256_bytes(ARCHIVE_OVERRIDE_BYTES),
            "containsSecrets": False,
            "kind": PLAN_KIND,
            "pgBackRestTargetSha256": sha256_bytes(target),
            "recordedAtUtc": _utc_now(),
            "repo1CipherSha256": secret_observation["sha256"],
            "schemaVersion": SCHEMA_VERSION,
            "stableBindingSha256": current["stableBindingSha256"],
        }
        raw = canonical_bytes(plan)
        _atomic_write(PLAN_PATH, raw, uid=0, gid=0, mode=0o600, replace=False)
        return plan, sha256_bytes(raw)


def _load_plan(expected_sha256: str) -> tuple[dict[str, Any], bytes]:
    value, raw = _read_root_json(PLAN_PATH, "first-backup plan")
    if SHA256_RE.fullmatch(expected_sha256) is None or sha256_bytes(raw) != expected_sha256:
        fail("fixed first-backup plan SHA-256 differs")
    expected_keys = {
        "assessment",
        "assessmentSha256",
        "archiveOverrideSha256",
        "containsSecrets",
        "kind",
        "pgBackRestTargetSha256",
        "recordedAtUtc",
        "repo1CipherSha256",
        "schemaVersion",
        "stableBindingSha256",
    }
    if set(value) != expected_keys or value.get("kind") != PLAN_KIND or value.get("schemaVersion") != SCHEMA_VERSION or value.get("containsSecrets") is not False:
        fail("first-backup plan schema differs")
    assessment = value.get("assessment")
    if not isinstance(assessment, dict) or sha256_bytes(canonical_bytes(assessment)) != value.get("assessmentSha256"):
        fail("first-backup plan assessment digest differs")
    if value.get("stableBindingSha256") != assessment.get("stableBindingSha256"):
        fail("first-backup stable binding differs")
    _parse_utc(value.get("recordedAtUtc"), "first-backup plan timestamp")
    return value, raw


class PhaseLedger:
    def __init__(self, transaction: Path, plan_sha256: str) -> None:
        self.transaction = transaction
        self.plan_sha256 = plan_sha256
        self.phases_dir = transaction / "phases"

    def load(self) -> list[dict[str, Any]]:
        _safe_directory(self.transaction, uid=0, gid=0, mode=0o700)
        _safe_directory(self.phases_dir, uid=0, gid=0, mode=0o700)
        all_entries = sorted(self.phases_dir.iterdir(), key=lambda path: path.name)
        phase_temp = re.compile(
            r"^\.[0-9]{3}-[a-z0-9-]+\.json\.commission\.[1-9][0-9]*\.[0-9a-f]{16}$"
        )
        entries: list[Path] = []
        for path in all_entries:
            if phase_temp.fullmatch(path.name):
                capture_file(
                    path,
                    "interrupted unpublished phase temporary",
                    mode=0o600,
                    maximum=MAX_JSON_BYTES,
                )
                continue
            entries.append(path)
        values: list[dict[str, Any]] = []
        previous = None
        for index, path in enumerate(entries):
            expected_name = f"{index:03d}-{PHASES[index]}.json" if index < len(PHASES) else ""
            if path.name != expected_name:
                fail("transaction phase namespace is non-contiguous or unknown")
            value, raw = _read_root_json(path, "transaction phase")
            if (
                set(value) != {"containsSecrets", "evidence", "kind", "phase", "planSha256", "previousPhaseSha256", "recordedAtUtc", "schemaVersion"}
                or value.get("kind") != PHASE_KIND
                or value.get("schemaVersion") != SCHEMA_VERSION
                or value.get("containsSecrets") is not False
                or value.get("phase") != PHASES[index]
                or value.get("planSha256") != self.plan_sha256
                or value.get("previousPhaseSha256") != previous
                or not isinstance(value.get("evidence"), dict)
            ):
                fail("transaction phase chain differs")
            _parse_utc(value.get("recordedAtUtc"), "transaction phase timestamp")
            previous = sha256_bytes(raw)
            values.append(value)
        return values

    def names(self) -> list[str]:
        return [value["phase"] for value in self.load()]

    def append(self, phase: str, evidence: Mapping[str, Any]) -> str:
        current = self.load()
        index = len(current)
        if index >= len(PHASES) or PHASES[index] != phase:
            fail(f"transaction phase is out of order: {phase}")
        previous = None
        if current:
            previous_path = self.phases_dir / f"{index - 1:03d}-{PHASES[index - 1]}.json"
            _value, previous_raw = _read_root_json(previous_path, "previous transaction phase")
            previous = sha256_bytes(previous_raw)
        value = {
            "containsSecrets": False,
            "evidence": dict(evidence),
            "kind": PHASE_KIND,
            "phase": phase,
            "planSha256": self.plan_sha256,
            "previousPhaseSha256": previous,
            "recordedAtUtc": _utc_now(),
            "schemaVersion": SCHEMA_VERSION,
        }
        return _exclusive_json(self.phases_dir / f"{index:03d}-{phase}.json", value)


def _ensure_transaction(plan_sha256: str) -> tuple[Path, PhaseLedger]:
    transaction = TRANSACTIONS_ROOT / plan_sha256
    _mkdir_exact(
        transaction, uid=0, gid=0, mode=0o700, allow_incomplete_creation=True
    )
    expected_children = {"phases", "preimages"}
    actual_children = {item.name for item in transaction.iterdir()}
    if actual_children - expected_children:
        fail("transaction directory contains an unexpected entry")
    for name in sorted(expected_children):
        child = transaction / name
        _mkdir_exact(
            child, uid=0, gid=0, mode=0o700, allow_incomplete_creation=True
        )
    directory_fd = os.open(transaction, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    os.fsync(directory_fd)
    os.close(directory_fd)
    root_fd = os.open(TRANSACTIONS_ROOT, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    os.fsync(root_fd)
    os.close(root_fd)
    _safe_directory(transaction / "preimages", uid=0, gid=0, mode=0o700)
    if not os.path.lexists(ACTIVE_PATH):
        _exclusive_json(
            ACTIVE_PATH,
            {
                "containsSecrets": False,
                "kind": "uten-imp-internal-test-first-backup-active",
                "planSha256": plan_sha256,
                "schemaVersion": SCHEMA_VERSION,
                "transactionPath": str(transaction),
            },
        )
    active, _raw = _read_root_json(ACTIVE_PATH, "active first-backup transaction")
    if (
        set(active)
        != {
            "containsSecrets",
            "kind",
            "planSha256",
            "schemaVersion",
            "transactionPath",
        }
        or active.get("containsSecrets") is not False
        or active.get("kind") != "uten-imp-internal-test-first-backup-active"
        or active.get("schemaVersion") != SCHEMA_VERSION
        or active.get("planSha256") != plan_sha256
        or active.get("transactionPath") != str(transaction)
    ):
        fail("active first-backup transaction names another plan")
    return transaction, PhaseLedger(transaction, plan_sha256)


def _validate_terminal(
    value: Mapping[str, Any],
    plan_sha256: str,
    *,
    transaction_path: Path | None = None,
) -> None:
    first_receipt = value.get("firstBackupReceipt")
    expected_transaction = transaction_path or (TRANSACTIONS_ROOT / plan_sha256)
    if (
        set(value)
        != {
            "completedAtUtc",
            "containsSecrets",
            "firstBackupReceipt",
            "kind",
            "localRecoveryOnly",
            "planSha256",
            "productionAuthority",
            "repositoryMutationIsIrreversible",
            "restoreVerified",
            "schemaVersion",
            "status",
            "transactionPath",
        }
        or value.get("kind") != TERMINAL_KIND
        or value.get("schemaVersion") != SCHEMA_VERSION
        or value.get("containsSecrets") is not False
        or value.get("localRecoveryOnly") is not True
        or value.get("productionAuthority") is not False
        or value.get("restoreVerified") is not False
        or value.get("repositoryMutationIsIrreversible") is not True
        or value.get("status") != "COMMISSIONED_LOCAL_FIRST_FULL_ENTRY_CLOSED"
        or value.get("planSha256") != plan_sha256
        or value.get("transactionPath") != str(expected_transaction)
        or not isinstance(first_receipt, dict)
        or set(first_receipt) != {"path", "sha256"}
        or first_receipt.get("path") != str(FIRST_BACKUP_RECEIPT)
        or SHA256_RE.fullmatch(str(first_receipt.get("sha256", ""))) is None
    ):
        fail("terminal first-backup commissioning receipt schema differs")
    _parse_utc(value.get("completedAtUtc"), "terminal commissioning timestamp")


def _verify_terminal_first_receipt_reference(value: Mapping[str, Any]) -> None:
    reference = value["firstBackupReceipt"]
    raw, _observation = capture_file(
        FIRST_BACKUP_RECEIPT,
        "terminal-bound first-backup receipt",
        mode=0o600,
        maximum=MAX_JSON_BYTES,
    )
    if sha256_bytes(raw) != reference["sha256"]:
        fail("terminal-bound first-backup receipt bytes changed")


def _capture_preimage(transaction: Path, plan: Mapping[str, Any]) -> dict[str, Any]:
    preimage = plan["assessment"]["pgBackRestConfigPreimage"]
    destination = transaction / "preimages" / "pgbackrest.conf"
    if preimage.get("state") == "absent":
        if os.path.lexists(PGBACKREST_CONFIG):
            fail("pgBackRest config appeared after plan recording")
        return {"pgBackRestConfigState": "absent"}
    postgres_gid = pwd.getpwnam("postgres").pw_gid
    raw, observed = capture_file(PGBACKREST_CONFIG, "pgBackRest preimage", gid=postgres_gid, mode=0o640, maximum=64 * 1024)
    if {"state": "file", **observed} != preimage:
        fail("pgBackRest config preimage changed after plan recording")
    if not os.path.lexists(destination):
        _atomic_write(destination, raw, uid=0, gid=0, mode=0o600, replace=False)
    copied, copied_observation = capture_file(destination, "captured pgBackRest preimage", mode=0o600, maximum=64 * 1024)
    if copied != raw:
        fail("captured pgBackRest preimage bytes differ")
    return {"pgBackRestConfigState": "file", "preimagePath": str(destination), "preimageSha256": copied_observation["sha256"]}


def _mkdir_exact(
    path: Path,
    *,
    uid: int,
    gid: int,
    mode: int,
    allow_incomplete_creation: bool = False,
) -> None:
    if not os.path.lexists(path):
        _root_chain(path.parent)
        os.mkdir(path, mode)
        os.chown(path, uid, gid)
        os.chmod(path, mode)
        parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        os.fsync(parent_fd)
        os.close(parent_fd)
    elif allow_incomplete_creation:
        details = path.lstat()
        actual_mode = stat.S_IMODE(details.st_mode)
        if (
            stat.S_ISDIR(details.st_mode)
            and not path.is_symlink()
            and details.st_uid == uid
            and details.st_gid in {0, gid}
            and actual_mode & ~mode == 0
            and (details.st_gid != gid or actual_mode != mode)
        ):
            os.chown(path, uid, gid)
            os.chmod(path, mode)
            parent_fd = os.open(
                path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
            )
            os.fsync(parent_fd)
            os.close(parent_fd)
    _safe_directory(path, uid=uid, gid=gid, mode=mode)


def _materialize_configuration(plan: Mapping[str, Any]) -> dict[str, Any]:
    postgres = pwd.getpwnam("postgres")
    secret, secret_observation = capture_file(STAGED_CIPHER, "staged repo1 cipher", mode=0o600, maximum=128)
    if secret_observation["sha256"] != plan["repo1CipherSha256"]:
        fail("staged repo1 cipher changed after plan recording")
    config = _render_pgbackrest(secret)
    if sha256_bytes(config) != plan["pgBackRestTargetSha256"]:
        fail("rendered pgBackRest target digest differs from plan")
    if sha256_bytes(ARCHIVE_OVERRIDE_BYTES) != plan["archiveOverrideSha256"]:
        fail("archive override source differs from plan")
    assessment = plan["assessment"]
    _mkdir_exact(
        CIPHER_DIRECTORY,
        uid=0,
        gid=postgres.pw_gid,
        mode=0o750,
        allow_incomplete_creation=assessment["cipherDirectoryPreimage"]["state"]
        == "absent",
    )
    _mkdir_exact(
        PGBACKREST_INCLUDE_ROOT,
        uid=0,
        gid=0,
        mode=0o755,
        allow_incomplete_creation=assessment["pgBackRestIncludeRootPreimage"]["state"]
        == "absent",
    )
    _mkdir_exact(
        PGBACKREST_INCLUDE_DIR,
        uid=0,
        gid=0,
        mode=0o755,
        allow_incomplete_creation=assessment["pgBackRestIncludeDirPreimage"]["state"]
        == "absent",
    )

    targets = (
        (CIPHER_TARGET, secret, 0, postgres.pw_gid, 0o640, plan["repo1CipherSha256"]),
        (PGBACKREST_CONFIG, config, 0, postgres.pw_gid, 0o640, plan["pgBackRestTargetSha256"]),
        (ARCHIVE_OVERRIDE, ARCHIVE_OVERRIDE_BYTES, 0, postgres.pw_gid, 0o640, plan["archiveOverrideSha256"]),
    )
    for path, raw, uid, gid, mode, digest in targets:
        _remove_interrupted_temporaries(
            path,
            uid=uid,
            gid=gid,
            mode=mode,
            maximum=max(64 * 1024, len(raw)),
        )
        if os.path.lexists(path):
            existing, observed = capture_file(path, "resumable configuration target", uid=uid, gid=gid, mode=mode, maximum=max(64 * 1024, len(raw)))
            if existing != raw or observed["sha256"] != digest:
                # PGBACKREST_CONFIG may still be its exact recorded blank preimage.
                if path == PGBACKREST_CONFIG and {"state": "file", **observed} == plan["assessment"]["pgBackRestConfigPreimage"]:
                    _atomic_write(path, raw, uid=uid, gid=gid, mode=mode, replace=True)
                    continue
                fail(f"configuration target differs during resume: {path}")
        else:
            _atomic_write(path, raw, uid=uid, gid=gid, mode=mode, replace=False)
    return {
        "archiveOverrideSha256": plan["archiveOverrideSha256"],
        "pgBackRestTargetSha256": plan["pgBackRestTargetSha256"],
        "repo1CipherSha256": plan["repo1CipherSha256"],
    }


def _verify_materialized_configuration(plan: Mapping[str, Any]) -> None:
    postgres_gid = pwd.getpwnam("postgres").pw_gid
    _safe_directory(CIPHER_DIRECTORY, uid=0, gid=postgres_gid, mode=0o750)
    _safe_directory(PGBACKREST_INCLUDE_ROOT, uid=0, gid=0, mode=0o755)
    _details, root_entries = _directory_entries(
        PGBACKREST_INCLUDE_ROOT, uid=0, gid=0, mode=0o755
    )
    if root_entries != ["conf.d"]:
        fail("pgBackRest include root changed after configuration publication")
    _details, include_entries = _directory_entries(
        PGBACKREST_INCLUDE_DIR, uid=0, gid=0, mode=0o755
    )
    if include_entries:
        fail("pgBackRest include directory gained an unreviewed config")
    for path, digest, mode in (
        (CIPHER_TARGET, plan["repo1CipherSha256"], 0o640),
        (PGBACKREST_CONFIG, plan["pgBackRestTargetSha256"], 0o640),
        (ARCHIVE_OVERRIDE, plan["archiveOverrideSha256"], 0o640),
    ):
        _raw, observed = capture_file(
            path,
            "materialized first-backup configuration",
            gid=postgres_gid,
            mode=mode,
            maximum=64 * 1024,
        )
        if observed["sha256"] != digest:
            fail("materialized first-backup configuration drifted")


def _systemctl(action: str, unit: str | None = None, *, timeout: int = 900) -> None:
    if action not in {"daemon-reload", "restart", "start", "reset-failed"}:
        fail("unreviewed systemctl action was refused")
    command = ["/usr/bin/systemctl", action]
    if unit is not None:
        command.append(unit)
    _run(command, timeout=timeout, stdout=False)


def _post_restart_evidence(
    producer: Any,
    authority: Mapping[str, Any],
    plan: Mapping[str, Any],
) -> dict[str, Any]:
    identity = _database_identity(producer, authority, archive_on=True)
    if identity != plan["assessment"]["databaseIdentity"]:
        fail("system identifier/timeline/Flyway drifted across PostgreSQL restart")
    systemd = observe_systemd()
    before_postgres = dict(plan["assessment"]["systemd"]["postgres"])
    after_postgres = dict(systemd["postgres"])
    before_pid = before_postgres.pop("MainPID")
    after_pid = after_postgres.pop("MainPID")
    if before_postgres != after_postgres or after_pid <= 1 or after_pid == before_pid:
        fail("PostgreSQL systemd contract did not survive one proven restart")
    loopback = observe_loopback()
    if loopback["endpoints"] != plan["assessment"]["loopback"]["endpoints"]:
        fail("PostgreSQL loopback listener set drifted across restart")
    return {"databaseIdentity": identity, "loopback": loopback, "postgresMainPID": after_pid, "systemd": systemd}


def _verified_restart_preimage(
    producer: Any,
    authority: Mapping[str, Any],
    plan: Mapping[str, Any],
) -> dict[str, Any]:
    """Prove the only remaining mismatch is the planned archive restart."""

    identity = _database_identity(producer, authority, archive_on=False)
    if identity != plan["assessment"]["databaseIdentity"]:
        fail("database identity drifted before the authorized restart")
    systemd = observe_systemd()
    expected_postgres = dict(plan["assessment"]["systemd"]["postgres"])
    current_postgres = dict(systemd["postgres"])
    expected_postgres.pop("MainPID", None)
    current_pid = current_postgres.pop("MainPID", None)
    if current_postgres != expected_postgres or not isinstance(current_pid, int) or current_pid <= 1:
        fail("PostgreSQL systemd contract drifted before the authorized restart")
    loopback = observe_loopback()
    if loopback["endpoints"] != plan["assessment"]["loopback"]["endpoints"]:
        fail("PostgreSQL listener drifted before the authorized restart")
    postgres_gid = pwd.getpwnam("postgres").pw_gid
    for path, digest, mode in (
        (PGBACKREST_CONFIG, plan["pgBackRestTargetSha256"], 0o640),
        (ARCHIVE_OVERRIDE, plan["archiveOverrideSha256"], 0o640),
    ):
        _raw, observed = capture_file(
            path,
            "authorized restart configuration",
            gid=postgres_gid,
            mode=mode,
            maximum=64 * 1024,
        )
        if observed["sha256"] != digest:
            fail("authorized restart configuration drifted")
    return {"databaseIdentity": identity, "loopback": loopback, "postgresMainPID": current_pid}


def _repository_has_bytes() -> bool:
    postgres = pwd.getpwnam("postgres")
    _details, entries = _directory_entries(REPOSITORY, uid=postgres.pw_uid, gid=postgres.pw_gid, mode=0o750)
    return bool(entries)


def _stanza_create_and_check(producer: Any, authority: Mapping[str, Any]) -> dict[str, Any]:
    # stanza-create is the first repo/WAL mutation and is deliberately safe to
    # repeat after a kill; pgBackRest validates an already-created stanza.
    _run_as_postgres(STANZA_CREATE, timeout=300)
    _run_as_postgres(REPO_CHECK, timeout=300)
    raw = _run_as_postgres(REPO_INFO, timeout=120, capture=True)
    identity = _database_identity(producer, authority, archive_on=True)
    value = strict_json_value_bytes(raw, "pgBackRest info")
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        fail("new repo1 info must contain exactly one stanza")
    stanza = value[0]
    repositories = stanza.get("repo")
    matching_repo = (
        [item for item in repositories if isinstance(item, dict) and item.get("key") == 1]
        if isinstance(repositories, list)
        else []
    )
    databases = stanza.get("db")
    matching_database = (
        [
            item
            for item in databases
            if isinstance(item, dict)
            and str(item.get("system-id")) == identity["systemIdentifier"]
        ]
        if isinstance(databases, list)
        else []
    )
    if (
        stanza.get("name") != "uten-imp"
        or not isinstance(stanza.get("status"), dict)
        or stanza["status"].get("code") != 0
        or len(matching_repo) != 1
        or not isinstance(matching_repo[0].get("status"), dict)
        or matching_repo[0]["status"].get("code") != 0
        or len(matching_database) != 1
        or stanza.get("backup") != []
    ):
        fail("new repo1 stanza/system identity is unhealthy, ambiguous, or already has backups")
    return {
        "infoSha256": sha256_bytes(raw),
        "repositoryHasBytes": _repository_has_bytes(),
        "systemIdentifier": identity["systemIdentifier"],
        "timeline": identity["timeline"],
    }


def _run_pid1_full() -> dict[str, Any]:
    before = observe_systemd()
    if before["timers"][PGBACKREST_TIMER]["UnitFileState"] != "disabled":
        fail("repo1 timer became enabled before first full")
    _systemctl("reset-failed", PGBACKREST_SERVICE)
    _systemctl("start", PGBACKREST_SERVICE, timeout=12 * 60 * 60)
    after = observe_systemd()
    if after["timers"][PGBACKREST_TIMER]["UnitFileState"] != "disabled" or after["timers"][PGBACKREST_TIMER]["ActiveState"] not in {"inactive", "failed"}:
        fail("repo1 timer changed during PID1-owned first full")
    if after["services"][PGBACKREST_SERVICE]["ActiveState"] != "inactive":
        fail("PID1-owned first full did not return to inactive success")
    return {"service": PGBACKREST_SERVICE, "timerEnabled": False, "completedAtUtc": _utc_now()}


def _repo1_backup_state(producer: Any, authority: Mapping[str, Any]) -> dict[str, Any]:
    identity = _database_identity(producer, authority, archive_on=True)
    raw = _run_as_postgres(REPO_INFO, timeout=120, capture=True)
    value = strict_json_value_bytes(raw, "pgBackRest repo1 inventory")
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        fail("repo1 inventory must contain exactly one stanza")
    stanza = value[0]
    databases = stanza.get("db")
    matching_database = (
        [
            item
            for item in databases
            if isinstance(item, dict)
            and str(item.get("system-id")) == identity["systemIdentifier"]
        ]
        if isinstance(databases, list)
        else []
    )
    backups = stanza.get("backup")
    if (
        stanza.get("name") != "uten-imp"
        or not isinstance(stanza.get("status"), dict)
        or stanza["status"].get("code") != 0
        or len(matching_database) != 1
        or not isinstance(backups, list)
    ):
        fail("repo1 inventory differs from the live cluster")
    if not backups:
        return {"backupCount": 0, "infoSha256": sha256_bytes(raw)}
    onboarding_completed = _parse_utc(
        authority["onboarding"]["completedAtUtc"], "onboarding completion"
    )
    try:
        latest = producer.parse_latest_full(
            raw,
            identity=identity,
            onboarding_completed_at=onboarding_completed,
            now=datetime.now(timezone.utc),
        )
        locked = producer.find_locked_job_receipt(latest)
    except Exception as exc:
        raise CommissioningError(
            "repo1 already has backup bytes without one matching fresh full/locked_job receipt"
        ) from exc
    if len(backups) != 1:
        fail("first-full transaction produced more than one backup; automatic retry is forbidden")
    return {
        "backupCount": 1,
        "backupLabel": latest["label"],
        "infoSha256": sha256_bytes(raw),
        "lockedJobReceipt": locked,
        "walStart": latest["walStart"],
        "walStop": latest["walStop"],
    }


def _wait_existing_pid1_full(
    *,
    timeout_seconds: int = 12 * 60 * 60,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    while True:
        service = observe_unit(PGBACKREST_SERVICE)
        if service["ActiveState"] not in {"active", "activating", "reloading"}:
            return
        if time.monotonic() >= deadline:
            fail("existing PID1 first-full service did not become terminal")
        sleep(5)


def _reconcile_or_run_pid1_full(
    producer: Any,
    authority: Mapping[str, Any],
) -> dict[str, Any]:
    before = _repo1_backup_state(producer, authority)
    if before["backupCount"] == 1:
        return {**before, "reconciledAfterInterruption": True, "timerEnabled": False}

    active_marker = Path("/var/lib/uten-imp-backup-transactions/repo1.active.json")
    service = observe_unit(PGBACKREST_SERVICE)
    service_running = service["ActiveState"] in {"active", "activating", "reloading"}
    if os.path.lexists(active_marker):
        if not service_running:
            fail("locked_job repo1 transaction is active but PID1 service is not running; reconcile it first")
        _wait_existing_pid1_full()
    elif service_running:
        fail("PID1 repo1 service is running without its durable locked_job transaction")
    else:
        _run_pid1_full()

    after = _repo1_backup_state(producer, authority)
    if after["backupCount"] != 1:
        fail("PID1 first-full completed without one matching locked_job terminal receipt")
    return {**after, "reconciledAfterInterruption": service_running, "timerEnabled": False}


def _pid1_full_authorization_preimage(
    producer: Any,
    authority: Mapping[str, Any],
) -> dict[str, Any]:
    """Prove no full/locked_job activity preceded durable PID1 authorization."""

    backup = _repo1_backup_state(producer, authority)
    if backup.get("backupCount") != 0:
        fail("repo1 gained a backup before durable PID1 full authorization")
    active_marker = Path("/var/lib/uten-imp-backup-transactions/repo1.active.json")
    if os.path.lexists(active_marker):
        fail("locked_job activity preceded durable PID1 full authorization")
    systemd = observe_systemd()
    service = systemd["services"][PGBACKREST_SERVICE]
    timer = systemd["timers"][PGBACKREST_TIMER]
    if (
        service["ActiveState"] not in {"inactive", "failed"}
        or service["MainPID"] != 0
        or timer["UnitFileState"] != "disabled"
        or timer["ActiveState"] not in {"inactive", "failed"}
        or timer["MainPID"] != 0
    ):
        fail("PID1 repo1 service/timer is not quiescent before full authorization")
    return {
        "infoSha256": backup["infoSha256"],
        "serviceActiveState": service["ActiveState"],
        "serviceMainPID": service["MainPID"],
        "timerActiveState": timer["ActiveState"],
        "timerEnabled": False,
    }


def _first_receipt_evidence(producer: Any, authority: Mapping[str, Any]) -> dict[str, Any]:
    receipt_path = producer.FIRST_BACKUP_RECEIPT
    if receipt_path != FIRST_BACKUP_RECEIPT:
        fail("installed producer first-backup receipt path differs from the fixed contract")
    if os.path.lexists(receipt_path):
        value, raw = _read_root_json(receipt_path, "first-backup receipt")
        if (
            set(value)
            != {
                "backup",
                "check",
                "containsSecrets",
                "createdAtUtc",
                "databaseIdentity",
                "deploymentProfile",
                "evidenceSetSha256",
                "expiresAt",
                "kind",
                "localRecoveryOnly",
                "onboarding",
                "productionAuthority",
                "producer",
                "restoreVerified",
                "schemaVersion",
                "status",
                "version",
            }
            or value.get("kind") != producer.RECEIPT_KIND
            or value.get("schemaVersion") != producer.SCHEMA_VERSION
            or value.get("status") != producer.RECEIPT_STATUS
            or value.get("containsSecrets") is not False
            or value.get("deploymentProfile") != "internal-test"
            or value.get("localRecoveryOnly") is not True
            or value.get("restoreVerified") is not False
            or value.get("productionAuthority") is not False
            or value.get("version") != authority["binding"]["version"]
            or value.get("databaseIdentity") != authority["onboarding"]["databaseIdentity"]
        ):
            fail("existing first-backup receipt differs from this authority")
        now = datetime.now(timezone.utc)
        created = _parse_utc(value.get("createdAtUtc"), "first-backup receipt creation")
        expires = _parse_utc(value.get("expiresAt"), "first-backup receipt expiry")
        if created > now or expires <= now or expires <= created:
            fail("existing first-backup receipt is not currently valid")
        onboarding = value.get("onboarding")
        expected_onboarding_sha = authority["fingerprintFields"]["onboardingSha256"]
        if (
            not isinstance(onboarding, dict)
            or onboarding.get("path") != str(producer.ONBOARDING_RECEIPT)
            or onboarding.get("sha256") != expected_onboarding_sha
            or onboarding.get("transactionId")
            != authority["onboarding"]["transactionId"]
        ):
            fail("existing first-backup receipt names another onboarding authority")
        producer_value = value.get("producer")
        _producer_raw, producer_observation = capture_file(
            INSTALLED_PRODUCER,
            "installed first-backup producer",
            mode=0o755,
            maximum=2 * 1024 * 1024,
        )
        if producer_value != {
            "path": str(INSTALLED_PRODUCER),
            "sha256": producer_observation["sha256"],
        }:
            fail("existing first-backup receipt producer changed")
        backup = value.get("backup")
        if not isinstance(backup, dict) or backup.get("repository") != 1:
            fail("existing first-backup receipt lacks fixed repo1 evidence")
        locked_path = Path(str(backup.get("lockedJobReceiptPath", "")))
        if locked_path.parent != producer.BACKUP_TRANSACTION_RECEIPTS:
            fail("existing first-backup receipt escaped locked_job receipts")
        locked_raw, _locked_observation = capture_file(
            locked_path,
            "locked_job terminal receipt",
            mode=0o600,
            maximum=MAX_JSON_BYTES,
        )
        if sha256_bytes(locked_raw) != backup.get("lockedJobReceiptSha256"):
            fail("existing first-backup locked_job receipt digest changed")
        return {"path": str(receipt_path), "sha256": sha256_bytes(raw)}
    receipt, digest = producer.produce_first_backup_receipt(
        lock_factory=lambda: nullcontext(),
        require_environment=True,
    )
    if receipt.get("localRecoveryOnly") is not True or receipt.get("productionAuthority") is not False:
        fail("first-backup producer returned authority outside local recovery")
    return {"path": str(receipt_path), "sha256": digest}


def _recover_authorized_partial_first_receipt() -> dict[str, Any]:
    """Remove only a non-JSON producer half-write after durable authorization.

    A canonical JSON object, including one with an unknown schema, is never
    deleted here; normal strict receipt validation must accept it or contain
    the transaction.  The authorization phase proves the fixed path was absent
    before the producer was allowed to create it.
    """

    if not os.path.lexists(FIRST_BACKUP_RECEIPT):
        return {"partialReceiptRemoved": False}
    raw, observation = capture_file(
        FIRST_BACKUP_RECEIPT,
        "authorized first-backup receipt attempt",
        mode=0o600,
        maximum=MAX_JSON_BYTES,
    )
    if b"\0" in raw or raw.startswith(b"\xef\xbb\xbf"):
        fail("authorized first-backup receipt attempt has impossible producer bytes")
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise CommissioningError(
            "authorized first-backup receipt attempt is not producer UTF-8"
        ) from exc
    try:
        json.loads(text)
    except json.JSONDecodeError:
        _durable_unlink(FIRST_BACKUP_RECEIPT)
        return {
            "partialReceiptRemoved": True,
            "partialReceiptSha256": observation["sha256"],
        }
    value = strict_json_bytes(raw, "authorized first-backup receipt attempt")
    if raw != canonical_bytes(value):
        fail("authorized first-backup receipt is structured but non-canonical")
    return {"partialReceiptRemoved": False}


def _current_stable_binding(assessment: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_bytes(_stable_binding(assessment)))


def _revalidate_static_authority(
    plan: Mapping[str, Any],
    authority: Mapping[str, Any],
) -> None:
    postgres_gid = pwd.getpwnam("postgres").pw_gid
    if _authority_summary(authority) != plan["assessment"]["authority"]:
        fail("candidate/onboarding/runtime/storage authority drifted after plan recording")
    if _asset_observations(postgres_gid) != plan["assessment"]["assets"]:
        fail("installed first-backup source/unit authority drifted after plan recording")
    if _pgbackrest_tool_observation() != plan["assessment"]["pgBackRestTool"]:
        fail("pgBackRest binary/version drifted after plan recording")


def apply_plan(
    *,
    expected_plan_sha256: str,
    confirmation: str,
    producer_loader: Callable[[], tuple[Any, dict[str, Any]]] = load_producer,
    assessor: Callable[[], dict[str, Any]] = lambda: build_assessment(allow_active=True),
    release_lock_factory: Callable[[], AbstractContextManager[Any]] | None = None,
    maintenance_lock_factory: Callable[[], AbstractContextManager[Any]] = MaintenanceLock,
    fault_hook: Callable[[str], None] | None = None,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != APPLY_CONFIRMATION:
        fail("apply/resume confirmation differs")
    plan, _plan_raw = _load_plan(expected_plan_sha256)
    producer, _ = producer_loader()
    authority = producer.load_authority()
    lock = release_lock_factory() if release_lock_factory else _default_release_lock(producer)
    hook = fault_hook or (lambda _phase: None)
    with lock:
        assert_external_markers_absent()
        producer.assert_no_markers()
        _revalidate_static_authority(plan, authority)
        terminal_path = RECEIPTS_ROOT / "terminal.json"
        if os.path.lexists(terminal_path):
            terminal, raw = _read_root_json(terminal_path, "terminal first-backup commissioning receipt")
            _validate_terminal(terminal, expected_plan_sha256)
            _verify_terminal_first_receipt_reference(terminal)
            if os.path.lexists(ACTIVE_PATH):
                transaction, ledger = _ensure_transaction(expected_plan_sha256)
                names = ledger.names()
                if names and names[-1] == "first-backup-receipt-complete":
                    ledger.append(
                        "terminal",
                        {
                            "receiptPath": str(terminal_path),
                            "receiptSha256": sha256_bytes(raw),
                        },
                    )
                _durable_unlink(ACTIVE_PATH)
            return terminal, sha256_bytes(raw)
        transaction, ledger = _ensure_transaction(expected_plan_sha256)
        phases = ledger.names()
        if "configuration-installed" in phases:
            _verify_materialized_configuration(plan)
        if not phases:
            current = assessor()
            if current.get("stableBindingSha256") != plan["stableBindingSha256"] or _current_stable_binding(current) != plan["stableBindingSha256"]:
                fail("stable source/database/storage/preimage binding drifted before mutation")
            ledger.append("started", {"stableBindingSha256": plan["stableBindingSha256"]})
            hook("started")

        with maintenance_lock_factory():
            phases = ledger.names()
            if "configuration-installed" not in phases:
                current = assessor()
                if (
                    current.get("stableBindingSha256")
                    != plan["stableBindingSha256"]
                    or _current_stable_binding(current)
                    != plan["stableBindingSha256"]
                ):
                    fail("stable authority/preimage drifted before configuration mutation")
            elif "postgres-restart-authorized" not in phases:
                # A resumed transaction must not daemon-reload or retroactively
                # authorize a restart after identity/listener/systemd drift.
                _verified_restart_preimage(producer, authority, plan)
            phases = ledger.names()
            if "preimages-captured" not in phases:
                evidence = _capture_preimage(transaction, plan)
                ledger.append("preimages-captured", evidence)
                hook("preimages-captured")
            phases = ledger.names()
            if "configuration-installed" not in phases:
                evidence = _materialize_configuration(plan)
                ledger.append("configuration-installed", evidence)
                hook("configuration-installed")
            phases = ledger.names()
            if "daemon-reloaded" not in phases:
                _systemctl("daemon-reload")
                ledger.append("daemon-reloaded", {"completed": True})
                hook("daemon-reloaded")
            phases = ledger.names()
            if "postgres-restart-authorized" not in phases:
                pre_restart = _verified_restart_preimage(
                    producer, authority, plan
                )
                ledger.append(
                    "postgres-restart-authorized",
                    {
                        "databaseIdentity": pre_restart["databaseIdentity"],
                        "loopback": pre_restart["loopback"],
                        "preRestartMainPID": pre_restart["postgresMainPID"],
                    },
                )
                hook("postgres-restart-authorized")
            phases = ledger.names()
            if "postgres-restarted-verified" not in phases:
                try:
                    evidence = _post_restart_evidence(producer, authority, plan)
                except CommissioningError:
                    _verified_restart_preimage(producer, authority, plan)
                    assert_external_markers_absent()
                    producer.assert_no_markers()
                    _systemctl("restart", POSTGRES_UNIT, timeout=900)
                    evidence = _post_restart_evidence(producer, authority, plan)
                ledger.append("postgres-restarted-verified", evidence)
                hook("postgres-restarted-verified")
            phases = ledger.names()
            if REPOSITORY_BOUNDARY not in phases:
                postgres = pwd.getpwnam("postgres")
                _details, entries = _directory_entries(REPOSITORY, uid=postgres.pw_uid, gid=postgres.pw_gid, mode=0o750)
                if entries:
                    fail("repo1 gained bytes before the durable repository boundary")
                ledger.append(REPOSITORY_BOUNDARY, {"automaticDeletionForbidden": True, "repositoryPath": str(REPOSITORY)})
                hook(REPOSITORY_BOUNDARY)
            phases = ledger.names()
            if "stanza-created-check-passed" not in phases:
                evidence = _stanza_create_and_check(producer, authority)
                if not evidence["repositoryHasBytes"]:
                    fail("stanza-create/check produced no durable repo1 bytes")
                ledger.append("stanza-created-check-passed", evidence)
                hook("stanza-created-check-passed")
            phases = ledger.names()
            if "pid1-full-authorized" not in phases:
                pre_full = _pid1_full_authorization_preimage(producer, authority)
                ledger.append(
                    "pid1-full-authorized",
                    {
                        **pre_full,
                        "service": PGBACKREST_SERVICE,
                        "timerMustRemainDisabled": True,
                    },
                )
                hook("pid1-full-authorized")

        # The fixed PID1 service must acquire the same maintenance lock itself.
        # We retain the outer release lock, release maintenance here, and then
        # reacquire maintenance in the same global order before receipt minting.
        phases = ledger.names()
        if "pid1-full-complete" not in phases:
            assert_external_markers_absent()
            producer.assert_no_markers()
            evidence = _reconcile_or_run_pid1_full(producer, authority)
            ledger.append("pid1-full-complete", evidence)
            hook("pid1-full-complete")

        with maintenance_lock_factory():
            assert_external_markers_absent()
            producer.assert_no_markers()
            authority = producer.load_authority()
            _revalidate_static_authority(plan, authority)
            _verify_materialized_configuration(plan)
            phases = ledger.names()
            if "first-backup-receipt-authorized" not in phases:
                if os.path.lexists(FIRST_BACKUP_RECEIPT):
                    fail("first-backup receipt appeared before durable producer authorization")
                ledger.append(
                    "first-backup-receipt-authorized",
                    {
                        "fixedReceiptPath": str(FIRST_BACKUP_RECEIPT),
                        "preimageState": "absent",
                    },
                )
                hook("first-backup-receipt-authorized")
            phases = ledger.names()
            if "first-backup-receipt-complete" not in phases:
                post = _post_restart_evidence(producer, authority, plan)
                recovery = _recover_authorized_partial_first_receipt()
                first = _first_receipt_evidence(producer, authority)
                ledger.append(
                    "first-backup-receipt-complete",
                    {
                        "firstBackupReceipt": first,
                        "partialRecovery": recovery,
                        "postFullIdentity": post["databaseIdentity"],
                    },
                )
                hook("first-backup-receipt-complete")
            phases = ledger.names()
            if "terminal" not in phases:
                first_phase = ledger.load()[PHASES.index("first-backup-receipt-complete")]
                receipt = {
                    "completedAtUtc": _utc_now(),
                    "containsSecrets": False,
                    "firstBackupReceipt": first_phase["evidence"]["firstBackupReceipt"],
                    "kind": TERMINAL_KIND,
                    "localRecoveryOnly": True,
                    "planSha256": expected_plan_sha256,
                    "productionAuthority": False,
                    "repositoryMutationIsIrreversible": True,
                    "restoreVerified": False,
                    "schemaVersion": SCHEMA_VERSION,
                    "status": "COMMISSIONED_LOCAL_FIRST_FULL_ENTRY_CLOSED",
                    "transactionPath": str(transaction),
                }
                receipt_sha = _exclusive_json(RECEIPTS_ROOT / "terminal.json", receipt)
                ledger.append("terminal", {"receiptPath": str(RECEIPTS_ROOT / "terminal.json"), "receiptSha256": receipt_sha})
                hook("terminal")
            terminal, raw = _read_root_json(RECEIPTS_ROOT / "terminal.json", "terminal first-backup commissioning receipt")
            _validate_terminal(
                terminal,
                expected_plan_sha256,
                transaction_path=transaction,
            )
            _durable_unlink(ACTIVE_PATH)
            return terminal, sha256_bytes(raw)


def rollback_pre_repository(
    *,
    expected_plan_sha256: str,
    confirmation: str,
    producer_loader: Callable[[], tuple[Any, dict[str, Any]]] = load_producer,
    release_lock_factory: Callable[[], AbstractContextManager[Any]] | None = None,
    maintenance_lock_factory: Callable[[], AbstractContextManager[Any]] = MaintenanceLock,
) -> tuple[dict[str, Any], str]:
    _require_root()
    if confirmation != ROLLBACK_CONFIRMATION:
        fail("pre-repository rollback confirmation differs")
    plan, _ = _load_plan(expected_plan_sha256)
    producer, _ = producer_loader()
    lock = release_lock_factory() if release_lock_factory else _default_release_lock(producer)
    with lock, maintenance_lock_factory():
        assert_external_markers_absent()
        producer.assert_no_markers()
        authority = producer.load_authority()
        _revalidate_static_authority(plan, authority)
        rollback_path = RECEIPTS_ROOT / "pre-repository-rollback.json"
        if os.path.lexists(rollback_path):
            existing, existing_raw = _read_root_json(
                rollback_path, "pre-repository rollback receipt"
            )
            if (
                set(existing)
                != {
                    "completedAtUtc",
                    "containsSecrets",
                    "kind",
                    "planSha256",
                    "productionAuthority",
                    "repositoryBytesDeleted",
                    "restoreVerified",
                    "schemaVersion",
                    "status",
                }
                or existing.get("kind") != ROLLBACK_KIND
                or existing.get("schemaVersion") != SCHEMA_VERSION
                or existing.get("planSha256") != expected_plan_sha256
                or existing.get("containsSecrets") is not False
                or existing.get("productionAuthority") is not False
                or existing.get("restoreVerified") is not False
                or existing.get("repositoryBytesDeleted") is not False
                or existing.get("status") != "ROLLED_BACK_BEFORE_REPOSITORY_MUTATION"
            ):
                fail("pre-repository rollback receipt schema differs")
            if os.path.lexists(ACTIVE_PATH):
                _durable_unlink(ACTIVE_PATH)
            return existing, sha256_bytes(existing_raw)
        transaction, ledger = _ensure_transaction(expected_plan_sha256)
        phases = ledger.names()
        if REPOSITORY_BOUNDARY in phases or _repository_has_bytes():
            fail("repository boundary was reached; automatic rollback/deletion is forbidden")
        postgres = pwd.getpwnam("postgres")
        for path in (ARCHIVE_OVERRIDE, CIPHER_TARGET, PGBACKREST_CONFIG):
            _remove_interrupted_temporaries(
                path,
                uid=0,
                gid=postgres.pw_gid,
                mode=0o640,
                maximum=64 * 1024,
            )
        for path, digest, uid, gid, mode in (
            (ARCHIVE_OVERRIDE, plan["archiveOverrideSha256"], 0, postgres.pw_gid, 0o640),
            (CIPHER_TARGET, plan["repo1CipherSha256"], 0, postgres.pw_gid, 0o640),
        ):
            if os.path.lexists(path):
                _raw, observed = capture_file(path, "rollback target", uid=uid, gid=gid, mode=mode, maximum=64 * 1024)
                if observed["sha256"] != digest:
                    fail(f"rollback target changed and will not be removed: {path}")
                _durable_unlink(path)
        preimage = plan["assessment"]["pgBackRestConfigPreimage"]
        current_config: tuple[bytes, dict[str, Any]] | None = None
        if os.path.lexists(PGBACKREST_CONFIG):
            current_config = capture_file(
                PGBACKREST_CONFIG,
                "rollback pgBackRest target",
                gid=postgres.pw_gid,
                mode=0o640,
                maximum=64 * 1024,
            )
        if preimage.get("state") == "absent":
            if current_config is not None:
                if current_config[1]["sha256"] != plan["pgBackRestTargetSha256"]:
                    fail("pgBackRest target changed and will not be removed")
                _durable_unlink(PGBACKREST_CONFIG)
        else:
            if current_config is not None and {
                "state": "file",
                **current_config[1],
            } == preimage:
                pass
            else:
                if (
                    current_config is not None
                    and current_config[1]["sha256"] != plan["pgBackRestTargetSha256"]
                ):
                    fail("pgBackRest target changed and will not be overwritten")
                saved, _ = capture_file(
                    transaction / "preimages" / "pgbackrest.conf",
                    "saved pgBackRest preimage",
                    mode=0o600,
                    maximum=64 * 1024,
                )
                if sha256_bytes(saved) != preimage["sha256"]:
                    fail("saved pgBackRest preimage changed")
                _atomic_write(
                    PGBACKREST_CONFIG,
                    saved,
                    uid=0,
                    gid=postgres.pw_gid,
                    mode=0o640,
                    replace=True,
                )
        for path, preimage_value, uid, gid, mode in (
            (
                PGBACKREST_INCLUDE_DIR,
                plan["assessment"]["pgBackRestIncludeDirPreimage"],
                0,
                0,
                0o755,
            ),
            (
                PGBACKREST_INCLUDE_ROOT,
                plan["assessment"]["pgBackRestIncludeRootPreimage"],
                0,
                0,
                0o755,
            ),
            (
                CIPHER_DIRECTORY,
                plan["assessment"]["cipherDirectoryPreimage"],
                0,
                postgres.pw_gid,
                0o750,
            ),
        ):
            if preimage_value.get("state") != "absent" or not os.path.lexists(path):
                continue
            _details, entries = _directory_entries(path, uid=uid, gid=gid, mode=mode)
            if entries:
                fail(f"rollback-created directory is no longer empty: {path}")
            _durable_rmdir(path)
        _systemctl("daemon-reload")
        _systemctl("restart", POSTGRES_UNIT, timeout=900)
        identity = _database_identity(producer, authority, archive_on=False)
        if identity != plan["assessment"]["databaseIdentity"]:
            fail("database identity drifted during pre-repository rollback")
        receipt = {
            "completedAtUtc": _utc_now(),
            "containsSecrets": False,
            "kind": ROLLBACK_KIND,
            "planSha256": expected_plan_sha256,
            "productionAuthority": False,
            "repositoryBytesDeleted": False,
            "restoreVerified": False,
            "schemaVersion": SCHEMA_VERSION,
            "status": "ROLLED_BACK_BEFORE_REPOSITORY_MUTATION",
        }
        digest = _exclusive_json(RECEIPTS_ROOT / "pre-repository-rollback.json", receipt)
        _durable_unlink(ACTIVE_PATH)
        return receipt, digest


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("action", choices=("assess", "record-plan", "apply", "resume", "rollback-pre-repository"))
    result.add_argument("--expected-assessment-sha256")
    result.add_argument("--expected-plan-sha256")
    result.add_argument("--confirm")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.action == "assess":
        if any((args.expected_assessment_sha256, args.expected_plan_sha256, args.confirm)):
            fail("read-only assess accepts no mutation arguments")
        value, _ = assess()
        sys.stdout.buffer.write(canonical_bytes(value))
        return 0
    if args.action == "record-plan":
        if not args.expected_assessment_sha256 or args.expected_plan_sha256:
            fail("record-plan requires only --expected-assessment-sha256")
        value, digest = record_plan(
            expected_assessment_sha256=args.expected_assessment_sha256,
            confirmation=args.confirm or "",
        )
        sys.stdout.buffer.write(canonical_bytes({"planPath": str(PLAN_PATH), "planSha256": digest, "recordedAtUtc": value["recordedAtUtc"]}))
        return 0
    if not args.expected_plan_sha256 or args.expected_assessment_sha256:
        fail("apply/resume/rollback requires only --expected-plan-sha256")
    if args.action in {"apply", "resume"}:
        value, digest = apply_plan(
            expected_plan_sha256=args.expected_plan_sha256,
            confirmation=args.confirm or "",
        )
        sys.stdout.buffer.write(canonical_bytes({"receiptPath": str(RECEIPTS_ROOT / "terminal.json"), "receiptSha256": digest, "status": value["status"]}))
        return 0
    value, digest = rollback_pre_repository(
        expected_plan_sha256=args.expected_plan_sha256,
        confirmation=args.confirm or "",
    )
    sys.stdout.buffer.write(canonical_bytes({"receiptPath": str(RECEIPTS_ROOT / "pre-repository-rollback.json"), "receiptSha256": digest, "status": value["status"]}))
    return 0


if __name__ == "__main__":  # pragma: no cover
    try:
        raise SystemExit(main())
    except CommissioningError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
