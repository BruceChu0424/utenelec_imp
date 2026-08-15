#!/usr/bin/python3
"""Fail-closed NVMe storage commissioning for the audited internal test host.

The tool is intentionally host-specific.  ``assess`` and ``plan`` make no
business or storage changes and write their JSON only to stdout.  Some
inventory commands may still emit normal system logs.  ``apply`` requires both the
deterministic plan SHA-256 and a typed confirmation phrase.  It commissions one
350 GiB linear LV, switches /data by filesystem UUID, and stops at an empty
PostgreSQL-16 PGDATA preparation boundary.  It never initializes a cluster,
creates a database role, drops a database, wipes/stops the old md array, or
removes an LV during recovery.

The active transaction and its preimages are persisted before the old /data is
unmounted.  Permanent systemd gates keep every protected unit closed while the
active pointer exists.  A static early-boot unit restores storage and
enablement; a second unit, ordered after local filesystems, opens a volatile
systemd-owned gate only while it starts and verifies the pre-operation active
units.  The newly-created LV is deliberately retained for forensic review and
evidence-bound re-adoption.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

try:  # The commissioned host is Linux; this fallback keeps pure policy tests portable.
    import fcntl  # type: ignore
except ImportError:  # pragma: no cover - exercised only by Windows-hosted tests
    fcntl = None  # type: ignore

try:
    import pwd
except ImportError:  # pragma: no cover - exercised only by Windows-hosted tests
    pwd = None  # type: ignore


SCHEMA_VERSION = 1
KIND = "uten-imp-existing-test-host-nvme-commissioning"
HOSTNAME_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?")
TARGET_VG = "ubuntu-vg"
TARGET_LV = "uten-data"
TARGET_LV_PATH = "/dev/ubuntu-vg/uten-data"
TARGET_LV_BYTES = 350 * 1024**3
MINIMUM_VG_REMAINING_BYTES = 20 * 1024**3
TARGET_MOUNT = "/data"
OLD_MD_DEVICE = "/dev/md0"
TARGET_PV = "/dev/nvme0n1p3"
TARGET_NVME = "/dev/nvme0n1"
CONFIRM_PHRASE = "COMMISSION-NVME-UTEN-DATA-350G-RETAIN-OLD-MD"
APPROVAL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}")
LVM_UUID_RE = re.compile(r"[A-Za-z0-9]{6}(?:-[A-Za-z0-9]{4}){5}-[A-Za-z0-9]{6}")

EVIDENCE_ROOT = Path("/var/lib/uten-imp-nvme-commissioning")
ACTIVE_POINTER = EVIDENCE_ROOT / "active.json"
LOCK_PATH = Path("/run/uten-imp-nvme-commissioning.lock")
MAINTENANCE_LOCK = Path("/var/lib/uten-imp-db-maintenance/operation.lock")
FSTAB = Path("/etc/fstab")
PG_GUARD = Path("/etc/systemd/system/postgresql@16-main.service.d/uten-imp-data.conf")
PG_START_CONF = Path("/etc/postgresql/16/main/start.conf")
STORAGE_AUTHORITY = Path("/etc/uten-imp/storage-authority.json")
RESUME_UNIT = Path("/etc/systemd/system/uten-imp-nvme-commissioning-resume.service")
RESUME_LINK = Path("/etc/systemd/system/local-fs.target.wants/uten-imp-nvme-commissioning-resume.service")
LATE_RESUME_UNIT = Path("/etc/systemd/system/uten-imp-nvme-commissioning-late-resume.service")
LATE_RESUME_TIMER = Path("/etc/systemd/system/uten-imp-nvme-commissioning-late-resume.timer")
LATE_RESUME_LINK = Path(
    "/etc/systemd/system/timers.target.wants/uten-imp-nvme-commissioning-late-resume.timer"
)
GATE_AUTHORIZER_UNIT = Path("/etc/systemd/system/uten-imp-nvme-gate-authorizer.service")
GATE_DROPIN_NAME = "90-uten-imp-nvme-active-transaction-gate.conf"
LATE_RUNTIME_DIRECTORY = Path("/run/uten-imp-nvme-late-unlock")
LATE_GRANT = LATE_RUNTIME_DIRECTORY / "grant.json"
GATE_RUNTIME_DIRECTORY = Path("/run/uten-imp-nvme-gate-authorizer")
GATE_OPEN_DIRECTORY = GATE_RUNTIME_DIRECTORY / "open"
EARLY_RECOVERY_READY_NAME = "early-recovery-ready.json"
LATE_RECOVERY_STATE_NAME = "late-recovery-state.json"
HELPER_ROOT = Path("/usr/local/libexec")
OLD_PHASE1_RESUME = "uten-imp-phase1-resume.service"

SYSTEMCTL = "/usr/bin/systemctl"
FINDMNT = "/usr/bin/findmnt"
LSBLK = "/usr/bin/lsblk"
BLKID = "/usr/sbin/blkid"
PVS = "/usr/sbin/pvs"
VGS = "/usr/sbin/vgs"
LVS = "/usr/sbin/lvs"
VGCFGBACKUP = "/usr/sbin/vgcfgbackup"
LVCREATE = "/usr/sbin/lvcreate"
MKFS_EXT4 = "/usr/sbin/mkfs.ext4"
MOUNT = "/usr/bin/mount"
UMOUNT = "/usr/bin/umount"
FUSER = "/usr/bin/fuser"
MDADM = "/usr/sbin/mdadm"
SMARTCTL = "/usr/sbin/smartctl"
RUNUSER = "/usr/sbin/runuser"
PSQL = "/usr/bin/psql"
PGBACKREST = "/usr/bin/pgbackrest"
PG_CONTROLDATA = "/usr/lib/postgresql/16/bin/pg_controldata"
UDEVADM = "/usr/bin/udevadm"
INSTALL = "/usr/bin/install"
SYNC = "/usr/bin/sync"
DPKG = "/usr/bin/dpkg"
LSLOCKS = "/usr/bin/lslocks"
SYSTEMD_ANALYZE = "/usr/bin/systemd-analyze"
CURL = "/usr/bin/curl"

COMMAND_TIMEOUT_SECONDS = 120
DESTRUCTIVE_COMMAND_TIMEOUT_SECONDS = 300
PACKAGE_LOCK_PATHS = {
    "/var/lib/dpkg/lock",
    "/var/lib/dpkg/lock-frontend",
    "/var/lib/apt/lists/lock",
    "/var/cache/apt/archives/lock",
}
PASSIVE_UNATTENDED_ARGV = [
    "/usr/bin/python3",
    "/usr/share/unattended-upgrades/unattended-upgrade-shutdown",
    "--wait-for-signal",
]

BASE_ENV = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "HOME": "/root",
    "PAGER": "cat",
    "SYSTEMD_PAGER": "cat",
    "SYSTEMD_COLORS": "0",
}

SERVICE_UNITS = (
    "nginx.service",
    "uten-imp.service",
    "uten-imp-updater.service",
    "uten-imp-updater.timer",
    "uten-imp-watchdog.service",
    "uten-imp-watchdog.timer",
    "uten-imp-entry-watchdog.service",
    "uten-imp-entry-watchdog.timer",
    "uten-pgbackup-health.timer",
    "uten-pgbackup-health.service",
    "uten-pgbackup-alert-drain.timer",
    "uten-pgbackup-alert-drain.service",
    "uten-pgbackup-repo2.timer",
    "uten-pgbackup-repo2.service",
    "uten-pgbackup.timer",
    "uten-pgbackup.service",
    "postgresql.service",
    "postgresql@16-main.service",
    OLD_PHASE1_RESUME,
    "unattended-upgrades.service",
    "apt-daily.service",
    "apt-daily-upgrade.service",
    "apt-daily.timer",
    "apt-daily-upgrade.timer",
)

STOP_ORDER = (
    "nginx.service",
    "uten-imp.service",
    "uten-imp-entry-watchdog.timer",
    "uten-imp-entry-watchdog.service",
    "uten-imp-watchdog.timer",
    "uten-imp-watchdog.service",
    "uten-imp-updater.timer",
    "uten-imp-updater.service",
    "uten-pgbackup-health.timer",
    "uten-pgbackup-health.service",
    "uten-pgbackup-alert-drain.timer",
    "uten-pgbackup-alert-drain.service",
    "uten-pgbackup-repo2.timer",
    "uten-pgbackup-repo2.service",
    "uten-pgbackup.timer",
    "uten-pgbackup.service",
    OLD_PHASE1_RESUME,
    "postgresql.service",
    "postgresql@16-main.service",
)

BACKUP_TIMERS = (
    "uten-pgbackup-health.timer",
    "uten-pgbackup-alert-drain.timer",
    "uten-pgbackup-repo2.timer",
    "uten-pgbackup.timer",
)

BACKUP_JOB_SERVICES = (
    "uten-pgbackup-health.service",
    "uten-pgbackup-repo2.service",
    "uten-pgbackup.service",
)

APT_TIMERS = ("apt-daily.timer", "apt-daily-upgrade.timer")
APT_JOB_SERVICES = ("apt-daily.service", "apt-daily-upgrade.service")
GATED_UNITS = tuple(dict.fromkeys(SERVICE_UNITS))
LATE_RECOVERY_ATTEMPTS = 3

# These units must remain disabled after a successful storage-only cutover.  A
# later, separately reviewed database/runtime phase enables them after initdb,
# roles, migrations, backup authority and application readiness are verified.
SUCCESS_DISABLE_UNITS = tuple(dict.fromkeys(STOP_ORDER + (OLD_PHASE1_RESUME,)))


class CommissioningError(RuntimeError):
    """A sanitized fail-closed refusal or transaction error."""


@dataclass(frozen=True)
class Completed:
    args: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str


class Runner:
    """No-shell command runner with an optional root-only evidence log."""

    def __init__(self, command_log: Path | None = None) -> None:
        self.command_log = command_log

    def run(
        self,
        args: Sequence[str],
        *,
        allowed: Iterable[int] = (0,),
        stdin: bytes | None = None,
        log_name: str | None = None,
        timeout: int = COMMAND_TIMEOUT_SECONDS,
    ) -> Completed:
        if not args or not all(isinstance(value, str) and value for value in args):
            raise CommissioningError("invalid command vector")
        if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout <= 0:
            raise CommissioningError("invalid command timeout")
        try:
            proc = subprocess.run(
                list(args),
                input=stdin,
                stdin=subprocess.DEVNULL if stdin is None else None,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=BASE_ENV,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            if self.command_log is not None and log_name is not None:
                atomic_json(
                    self.command_log / f"{safe_name(log_name)}.json",
                    {
                        "argv": list(args),
                        "timeoutSeconds": timeout,
                        "timedOut": True,
                    },
                    replace=False,
                )
            raise CommissioningError(
                f"command timed out after {timeout}s with ambiguous state: {Path(args[0]).name}"
            ) from exc
        result = Completed(
            tuple(args),
            proc.returncode,
            proc.stdout.decode("utf-8", errors="replace"),
            proc.stderr.decode("utf-8", errors="replace"),
        )
        if self.command_log is not None and log_name is not None:
            payload = {
                "argv": list(args),
                "returnCode": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
            atomic_json(self.command_log / f"{safe_name(log_name)}.json", payload, replace=False)
        if result.returncode not in set(allowed):
            raise CommissioningError(f"command failed rc={result.returncode}: {Path(args[0]).name}")
        return result

    def recovery_attempt(self, evidence: Path) -> None:
        attempts = evidence / "recovery-attempts"
        ensure_secure_directory(attempts)
        attempt = attempts / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ-") + uuid.uuid4().hex)
        ensure_secure_directory(attempt)
        commands = attempt / "commands"
        ensure_secure_directory(commands)
        self.command_log = commands


class MaintenanceLock:
    """Hold the already-installed database maintenance inode without replacing it."""

    def __init__(self) -> None:
        self.descriptor: int | None = None

    def __enter__(self) -> "MaintenanceLock":
        if fcntl is None or pwd is None:
            raise CommissioningError("database maintenance locking requires Linux/POSIX")
        postgres_gid = pwd.getpwnam("postgres").pw_gid
        observation = maintenance_lock_observation()
        if not valid_maintenance_lock(observation, postgres_gid):
            raise CommissioningError("database maintenance lock metadata differs")
        flags = os.O_RDWR | os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        descriptor = os.open(MAINTENANCE_LOCK, flags)
        info = os.fstat(descriptor)
        current = MAINTENANCE_LOCK.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or info.st_gid != postgres_gid
            or stat.S_IMODE(info.st_mode) != 0o660
            or info.st_nlink != 1
            or info.st_size != 0
            or info.st_dev != current.st_dev
            or info.st_ino != current.st_ino
        ):
            os.close(descriptor)
            raise CommissioningError("database maintenance lock inode differs")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(descriptor)
            raise CommissioningError("backup or another database maintenance operation is active") from exc
        self.descriptor = descriptor
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.descriptor is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-.")
    if not cleaned:
        raise CommissioningError("empty evidence name")
    return cleaned[:120]


def root_directory_metadata_is_exact(info: os.stat_result, mode: int) -> bool:
    """Production evidence directories are accepted only with exact root metadata."""

    return (
        stat.S_ISDIR(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and info.st_uid == 0
        and info.st_gid == 0
        and stat.S_IMODE(info.st_mode) == mode
    )


def root_file_metadata_is_exact(info: os.stat_result, mode: int) -> bool:
    """Production evidence files are accepted only with exact root metadata."""

    return (
        stat.S_ISREG(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and info.st_uid == 0
        and info.st_gid == 0
        and stat.S_IMODE(info.st_mode) == mode
        and info.st_nlink == 1
    )


def fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def ensure_secure_directory(path: Path, mode: int = 0o700) -> None:
    if path.exists() or path.is_symlink():
        st = path.lstat()
        if not stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode):
            raise CommissioningError(f"unsafe directory type: {path}")
        if st.st_uid != 0 or st.st_gid != 0 or stat.S_IMODE(st.st_mode) != mode:
            raise CommissioningError(f"unsafe directory metadata: {path}")
        return
    path.mkdir(mode=mode)
    os.chown(path, 0, 0)
    os.chmod(path, mode)
    fsync_directory(path.parent)


def ensure_trusted_durable_directory(path: Path) -> None:
    missing: list[Path] = []
    current = path
    while not current.exists():
        if current.is_symlink():
            raise CommissioningError(f"trusted directory component is a symlink: {current}")
        missing.append(current)
        if current.parent == current:
            raise CommissioningError("trusted directory has no existing ancestor")
        current = current.parent
    for directory in reversed(missing):
        directory.mkdir(mode=0o755)
        os.chown(directory, 0, 0)
        os.chmod(directory, 0o755)
        fsync_directory(directory)
        fsync_directory(directory.parent)
    current = path
    while True:
        st = current.lstat()
        if (
            not stat.S_ISDIR(st.st_mode)
            or stat.S_ISLNK(st.st_mode)
            or st.st_uid != 0
            or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) & 0o022
        ):
            raise CommissioningError(f"trusted directory metadata differs: {current}")
        if current == Path("/"):
            break
        current = current.parent


def atomic_write(path: Path, payload: bytes, *, mode: int = 0o600, replace: bool = True) -> None:
    ensure_secure_directory(path.parent)
    temporary = path.parent / f".{path.name}.tmp-{os.getpid()}-{time.monotonic_ns()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        os.fchown(fd, 0, 0)
        os.fchmod(fd, mode)
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view) :]
        os.fsync(fd)
    finally:
        os.close(fd)
    if not replace and (path.exists() or path.is_symlink()):
        if path.is_file() and not path.is_symlink() and path.read_bytes() == payload:
            temporary.unlink()
            fsync_directory(path.parent)
            return
        temporary.unlink(missing_ok=True)
        raise CommissioningError(f"immutable evidence differs: {path.name}")
    os.replace(temporary, path)
    fsync_directory(path.parent)


def atomic_json(path: Path, value: Any, *, replace: bool = True, mode: int = 0o600) -> None:
    atomic_write(path, canonical_bytes(value), mode=mode, replace=replace)


def atomic_json_with_lineage(
    path: Path,
    value: Mapping[str, Any],
    *,
    lineage_field: str,
) -> dict[str, Any]:
    """Replace a mutable status pointer without destroying its prior bytes."""

    document = dict(value)
    previous_sha: str | None = None
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not root_file_metadata_is_exact(path.lstat(), 0o600):
            raise CommissioningError(f"mutable evidence metadata differs: {path.name}")
        previous_document = load_json_regular(path)
        validate_lineage_reference(path, previous_document, lineage_field)
        previous = path.read_bytes()
        previous_sha = sha256_bytes(previous)
        history = path.parent / "history" / safe_name(path.stem)
        ensure_secure_directory(path.parent / "history")
        ensure_secure_directory(history)
        archive = history / (
            dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ-")
            + uuid.uuid4().hex
            + "-"
            + previous_sha
            + ".json"
        )
        atomic_write(archive, previous, replace=False)
    document[lineage_field] = previous_sha
    atomic_json(path, document, replace=True)
    return document


def validate_lineage_reference(path: Path, document: Mapping[str, Any], lineage_field: str) -> None:
    """Validate the append-only archive referenced by a mutable evidence pointer."""

    if lineage_field not in document:
        raise CommissioningError(f"mutable evidence lineage is absent: {path.name}")
    previous_sha = document.get(lineage_field)
    if previous_sha is None:
        return
    if not isinstance(previous_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", previous_sha):
        raise CommissioningError(f"mutable evidence lineage is malformed: {path.name}")
    history_root = path.parent / "history"
    history = history_root / safe_name(path.stem)
    if (
        history_root.is_symlink()
        or history.is_symlink()
        or not history_root.is_dir()
        or not history.is_dir()
        or not root_directory_metadata_is_exact(history_root.lstat(), 0o700)
        or not root_directory_metadata_is_exact(history.lstat(), 0o700)
    ):
        raise CommissioningError(f"mutable evidence lineage directory is unsafe: {path.name}")
    matches = 0
    archive_name = re.compile(
        r"\d{8}T\d{6}\.\d{6}Z-[0-9a-f]{32}-([0-9a-f]{64})\.json"
    )
    for archive in history.iterdir():
        match = archive_name.fullmatch(archive.name)
        if (
            match is None
            or archive.is_symlink()
            or not archive.is_file()
            or not root_file_metadata_is_exact(archive.lstat(), 0o600)
        ):
            raise CommissioningError(f"mutable evidence lineage archive is unsafe: {path.name}")
        actual_sha = sha256_file(archive)
        if actual_sha != match.group(1):
            raise CommissioningError(f"mutable evidence lineage archive digest differs: {path.name}")
        if actual_sha == previous_sha:
            matches += 1
    if matches < 1:
        raise CommissioningError(f"mutable evidence lineage archive is absent: {path.name}")


def require_root() -> None:
    if os.geteuid() != 0:
        raise CommissioningError("run this host-specific command as root")


def json_command(runner: Runner, args: Sequence[str], *, allowed: Iterable[int] = (0,)) -> Any:
    result = runner.run(args, allowed=allowed)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise CommissioningError(f"invalid JSON from {Path(args[0]).name}") from exc


def parse_lvm_rows(document: Mapping[str, Any], table: str) -> list[dict[str, str]]:
    reports = document.get("report")
    if not isinstance(reports, list) or len(reports) != 1:
        raise CommissioningError(f"ambiguous LVM {table} report")
    rows = reports[0].get(table)
    if not isinstance(rows, list):
        raise CommissioningError(f"missing LVM {table} rows")
    result: list[dict[str, str]] = []
    for row in rows:
        if not isinstance(row, dict):
            raise CommissioningError(f"invalid LVM {table} row")
        result.append({str(key): str(value).strip() for key, value in row.items()})
    return result


def integer_field(value: Any, name: str) -> int:
    if isinstance(value, bool):
        raise CommissioningError(f"invalid integer field: {name}")
    match = re.fullmatch(r"[<>]?(\d+)(?:\.0+)?", str(value).strip())
    if not match:
        raise CommissioningError(f"invalid integer field: {name}")
    parsed = int(match.group(1))
    if parsed < 0:
        raise CommissioningError(f"negative integer field: {name}")
    return parsed


def single_filesystem(document: Mapping[str, Any]) -> dict[str, Any]:
    filesystems = document.get("filesystems")
    if not isinstance(filesystems, list) or len(filesystems) != 1 or not isinstance(filesystems[0], dict):
        raise CommissioningError("/data mount inventory is ambiguous")
    return dict(filesystems[0])


def normalized_mount_source(value: Any) -> str:
    return str(value).split("[", 1)[0]


def same_block_device(left: str | Path, right: str | Path) -> bool:
    try:
        left_info = os.stat(left)
        right_info = os.stat(right)
    except OSError:
        return False
    return stat.S_ISBLK(left_info.st_mode) and stat.S_ISBLK(right_info.st_mode) and left_info.st_rdev == right_info.st_rdev


def mounted_target_lv_is_exact(observed: Mapping[str, Any], filesystem_uuid: str) -> bool:
    options = {item for item in str(observed.get("options", "")).split(",") if item}
    return (
        observed.get("fstype") == "ext4"
        and str(observed.get("uuid", "")).lower() == filesystem_uuid.lower()
        and same_block_device(normalized_mount_source(observed.get("source")), TARGET_LV_PATH)
        and {"rw", "nodev", "nosuid", "noexec"}.issubset(options)
    )


def runtime_authority_document(
    topology: Mapping[str, Any], approval_reference: str, commissioning_evidence_sha256: str
) -> dict[str, Any]:
    if not APPROVAL_RE.fullmatch(approval_reference):
        raise CommissioningError("storage approval reference is malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", commissioning_evidence_sha256):
        raise CommissioningError("commissioning evidence SHA-256 is malformed")
    if set(topology) != {"dataUuid", "lvm", "nvme"}:
        raise CommissioningError("runtime storage topology keys differ")
    return {
        "approvalReference": approval_reference,
        "commissioningEvidenceSha256": commissioning_evidence_sha256,
        "dataFilesystem": "ext4",
        "dataSource": "/dev/mapper/ubuntu--vg-uten--data",
        "dataUuid": topology["dataUuid"],
        "lvm": topology["lvm"],
        "minimumFreeBytes": 2 * 1024**3,
        "minimumFreeInodes": 100_000,
        "mountPoint": "/data",
        "nvme": topology["nvme"],
        "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],
        "schemaVersion": 3,
        "topology": "lvm-linear-nvme",
    }


def parse_fstab_data_entries(payload: bytes) -> list[dict[str, Any]]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CommissioningError("fstab is not UTF-8/ASCII") from exc
    entries: list[dict[str, Any]] = []
    for index, raw in enumerate(text.splitlines(keepends=True)):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            fields = shlex.split(stripped, comments=True, posix=True)
        except ValueError as exc:
            raise CommissioningError(f"invalid fstab syntax at line {index + 1}") from exc
        if len(fields) < 4:
            raise CommissioningError(f"short fstab entry at line {index + 1}")
        if fields[1] == TARGET_MOUNT:
            entries.append({"line": index, "fields": fields, "raw": raw})
    return entries


def postgres_start_mode(text: Any) -> str | None:
    if not isinstance(text, str):
        return None
    values = [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if len(values) != 1 or values[0] not in {"auto", "manual"}:
        return None
    return values[0]


def render_postgres_start_manual(payload: bytes) -> bytes:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CommissioningError("PostgreSQL start.conf is not UTF-8/ASCII") from exc
    if postgres_start_mode(text) is None:
        raise CommissioningError("PostgreSQL start.conf has an unsafe mode")
    lines = text.splitlines(keepends=True)
    active = [index for index, line in enumerate(lines) if line.strip() and not line.lstrip().startswith("#")]
    index = active[0]
    newline = "\r\n" if lines[index].endswith("\r\n") else "\n" if lines[index].endswith("\n") else ""
    lines[index] = "manual" + newline
    return "".join(lines).encode("utf-8")


def render_switched_fstab(payload: bytes, filesystem_uuid: str, old_filesystem_uuid: str | None = None) -> bytes:
    if not re.fullmatch(r"[0-9A-Fa-f-]{8,64}", filesystem_uuid):
        raise CommissioningError("unsafe target filesystem UUID")
    entries = parse_fstab_data_entries(payload)
    if len(entries) != 1:
        raise CommissioningError("fstab must contain exactly one active /data entry")
    fields = entries[0]["fields"]
    allowed_old_sources = {OLD_MD_DEVICE}
    if old_filesystem_uuid is not None:
        allowed_old_sources.add("UUID=" + old_filesystem_uuid)
    if fields[0] not in allowed_old_sources:
        raise CommissioningError("unexpected /data source in fstab")
    lines = payload.decode("utf-8").splitlines(keepends=True)
    newline = "\r\n" if entries[0]["raw"].endswith("\r\n") else "\n"
    lines[entries[0]["line"]] = (
        f"UUID={filesystem_uuid} /data ext4 rw,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=30s 0 2{newline}"
    )
    return "".join(lines).encode("utf-8")


def postgres_guard(filesystem_uuid: str) -> bytes:
    if not re.fullmatch(r"[0-9A-Fa-f-]{8,64}", filesystem_uuid):
        raise CommissioningError("unsafe target filesystem UUID")
    return (
        "# Generated by existing-test-host-nvme-commissioner.py\n"
        "[Unit]\n"
        "RequiresMountsFor=/data\n"
        "After=data.mount\n"
        "ConditionPathIsMountPoint=/data\n"
        "\n"
        "[Service]\n"
        f"ExecStartPre=/usr/bin/findmnt --noheadings --mountpoint /data --source UUID={filesystem_uuid} --types ext4\n"
    ).encode("utf-8")


def resume_unit(helper_path: Path) -> bytes:
    normalized = helper_path.as_posix().replace("\\", "/")
    if not normalized.startswith("/usr/local/libexec/") or "/../" in normalized:
        raise CommissioningError("unsafe installed helper path")
    return (
        "# Generated by existing-test-host-nvme-commissioner.py\n"
        "[Unit]\n"
        "Description=Recover interrupted Uten IMP NVMe commissioning\n"
        "DefaultDependencies=no\n"
        "After=local-fs-pre.target systemd-remount-fs.service systemd-udev-settle.service mdmonitor.service lvm2-monitor.service\n"
        "Before=data.mount local-fs.target postgresql.service postgresql@16-main.service nginx.service\n"
        "ConditionPathExists=/var/lib/uten-imp-nvme-commissioning/active.json\n"
        "StartLimitIntervalSec=900s\n"
        "StartLimitBurst=3\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        f"ExecStart=/usr/bin/python3 -I {helper_path} recover --from-systemd-early\n"
        "TimeoutStartSec=300s\n"
        "Restart=on-failure\n"
        "RestartSec=30s\n"
        "UMask=0077\n"
        "NoNewPrivileges=yes\n"
        # Do not add mount-namespace sandboxing (ProtectSystem, PrivateTmp,
        # ReadWritePaths, etc.).  Recovery must mount /data in the host mount
        # namespace so the restored mount survives this oneshot service.
    ).encode("utf-8")


def late_resume_unit(helper_path: Path) -> bytes:
    normalized = helper_path.as_posix().replace("\\", "/")
    if not normalized.startswith("/usr/local/libexec/") or "/../" in normalized:
        raise CommissioningError("unsafe installed late-recovery helper path")
    return (
        "# Generated by existing-test-host-nvme-commissioner.py\n"
        "[Unit]\n"
        "Description=Finalize interrupted Uten IMP NVMe recovery after local filesystems\n"
        "After=multi-user.target network-online.target\n"
        "Wants=network-online.target\n"
        "ConditionPathExists=/var/lib/uten-imp-nvme-commissioning/active.json\n"
        "StartLimitIntervalSec=900s\n"
        "StartLimitBurst=3\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        f"ExecStart=/usr/bin/python3 -I {helper_path} recover --from-systemd-late\n"
        f"ExecStopPost=/usr/bin/python3 -I {helper_path} contain-late-failure\n"
        "RuntimeDirectory=uten-imp-nvme-late-unlock\n"
        "RuntimeDirectoryMode=0700\n"
        "TimeoutStartSec=600s\n"
        "TimeoutStopSec=300s\n"
        "Restart=on-failure\n"
        "RestartSec=30s\n"
        "UMask=0077\n"
        "NoNewPrivileges=yes\n"
    ).encode("utf-8")


def late_resume_timer() -> bytes:
    return (
        "# Generated by existing-test-host-nvme-commissioner.py\n"
        "[Unit]\n"
        "Description=Schedule late Uten IMP NVMe recovery after normal boot jobs settle\n"
        "ConditionPathExists=/var/lib/uten-imp-nvme-commissioning/active.json\n"
        "\n"
        "[Timer]\n"
        "OnActiveSec=30s\n"
        "AccuracySec=1s\n"
        "Unit=uten-imp-nvme-commissioning-late-resume.service\n"
    ).encode("utf-8")


def gate_marker_path(unit: str) -> Path:
    if unit not in GATED_UNITS:
        raise CommissioningError("unknown gated unit")
    return GATE_OPEN_DIRECTORY / safe_name(unit)


def gate_authorizer_unit(helper_path: Path) -> bytes:
    normalized = helper_path.as_posix().replace("\\", "/")
    if not normalized.startswith("/usr/local/libexec/") or "/../" in normalized:
        raise CommissioningError("unsafe installed gate-authorizer helper path")
    return (
        "# Generated by existing-test-host-nvme-commissioner.py\n"
        "[Unit]\n"
        "Description=Authorize Uten IMP unit starts around NVMe transactions\n"
        "DefaultDependencies=no\n"
        "After=systemd-remount-fs.service\n"
        "Before=local-fs.target\n"
        "\n"
        "[Service]\n"
        "Type=oneshot\n"
        "RemainAfterExit=yes\n"
        "RuntimeDirectory=uten-imp-nvme-gate-authorizer\n"
        "RuntimeDirectoryMode=0700\n"
        f"ExecStart=/usr/bin/python3 -I {helper_path} authorize-gate\n"
        f"ExecReload=/usr/bin/python3 -I {helper_path} authorize-gate\n"
        "TimeoutStartSec=60s\n"
        "TimeoutStopSec=60s\n"
        "UMask=0077\n"
        "NoNewPrivileges=yes\n"
    ).encode("utf-8")


def active_transaction_gate_dropin(unit: str) -> bytes:
    marker = gate_marker_path(unit)
    return (
        "# Generated by existing-test-host-nvme-commissioner.py\n"
        "# Keep this permanent. The root authorizer creates this unit-specific marker.\n"
        "# A regular (non-trigger) condition cannot be weakened by another drop-in's OR group.\n"
        "[Unit]\n"
        f"Requires={GATE_AUTHORIZER_UNIT.name}\n"
        f"After={GATE_AUTHORIZER_UNIT.name}\n"
        f"ConditionPathExists={marker}\n"
    ).encode("utf-8")


def gate_dropin_path(unit: str) -> Path:
    if unit not in GATED_UNITS:
        raise CommissioningError("unknown gated unit")
    return Path("/etc/systemd/system") / f"{unit}.d" / GATE_DROPIN_NAME


def unit_state(runner: Runner, unit: str, *, timeout: int = COMMAND_TIMEOUT_SECONDS) -> dict[str, str]:
    result = runner.run(
        [
            SYSTEMCTL,
            "show",
            unit,
            "--property=Id,LoadState,ActiveState,SubState,UnitFileState,FragmentPath,Result,ExecMainStatus",
            "--no-pager",
        ],
        allowed=(0, 1),
        timeout=timeout,
    )
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            values[key] = value
    return values


def evidence_listing(path: Path) -> list[dict[str, Any]]:
    if not path.exists() and not path.is_symlink():
        return []
    if path.is_symlink() or not path.is_dir():
        raise CommissioningError(f"unsafe evidence root: {path}")
    values: list[dict[str, Any]] = []
    for child in sorted(path.iterdir(), key=lambda item: item.name):
        st = child.lstat()
        item: dict[str, Any] = {
            "name": child.name,
            "type": "directory" if stat.S_ISDIR(st.st_mode) else "file" if stat.S_ISREG(st.st_mode) else "other",
            "mode": format(stat.S_IMODE(st.st_mode), "04o"),
            "uid": st.st_uid,
            "gid": st.st_gid,
        }
        if stat.S_ISREG(st.st_mode) and st.st_size <= 1024 * 1024:
            item["sha256"] = sha256_file(child)
        values.append(item)
    return values


def regular_file_observation(path: Path, *, include_text: bool = False) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        return {"path": str(path), "exists": False}
    st = path.lstat()
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        return {"path": str(path), "exists": True, "unsafeType": True}
    payload = path.read_bytes()
    value: dict[str, Any] = {
        "path": str(path),
        "exists": True,
        "unsafeType": False,
        "sha256": sha256_bytes(payload),
        "mode": format(stat.S_IMODE(st.st_mode), "04o"),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "links": st.st_nlink,
    }
    if include_text:
        try:
            value["text"] = payload.decode("utf-8")
        except UnicodeDecodeError:
            value["text"] = None
    return value


def resume_installation_observation() -> dict[str, Any]:
    unit_contracts = (
        (
            "early",
            RESUME_UNIT,
            re.compile(
                r"^ExecStart=/usr/bin/python3 -I "
                r"(/usr/local/libexec/uten-imp-nvme-commissioner-([0-9a-f]{64})\.py) "
                r"recover --from-systemd-early$",
                re.MULTILINE,
            ),
            resume_unit,
        ),
        (
            "late",
            LATE_RESUME_UNIT,
            re.compile(
                r"^ExecStart=/usr/bin/python3 -I "
                r"(/usr/local/libexec/uten-imp-nvme-commissioner-([0-9a-f]{64})\.py) "
                r"recover --from-systemd-late$",
                re.MULTILINE,
            ),
            late_resume_unit,
        ),
        (
            "gateAuthorizer",
            GATE_AUTHORIZER_UNIT,
            re.compile(
                r"^ExecStart=/usr/bin/python3 -I "
                r"(/usr/local/libexec/uten-imp-nvme-commissioner-([0-9a-f]{64})\.py) "
                r"authorize-gate$",
                re.MULTILINE,
            ),
            gate_authorizer_unit,
        ),
    )
    link_contracts = (
        ("early", RESUME_LINK, RESUME_UNIT),
        ("lateTimer", LATE_RESUME_LINK, LATE_RESUME_TIMER),
    )
    gate_paths = [gate_dropin_path(unit) for unit in GATED_UNITS]
    all_paths = (
        [unit_path for _, unit_path, _, _ in unit_contracts]
        + [LATE_RESUME_TIMER]
        + [link_path for _, link_path, _ in link_contracts]
        + gate_paths
    )
    if not any(path.exists() or path.is_symlink() for path in all_paths):
        return {"state": "absent", "gatedUnits": list(GATED_UNITS)}

    value: dict[str, Any] = {
        "state": "invalid",
        "gatedUnits": list(GATED_UNITS),
        "units": {},
        "gates": {},
        "missing": [],
        "failures": [],
    }
    helpers: set[str] = set()
    for name, unit_path, expression, renderer in unit_contracts:
        unit_present = unit_path.exists() or unit_path.is_symlink()
        value["units"][name] = {"unitPresent": unit_present}
        if not unit_present:
            value["missing"].append(str(unit_path))
            continue
        info = unit_path.lstat()
        if not root_file_metadata_is_exact(info, 0o644):
            value["failures"].append(f"{name} resume unit metadata differs")
            continue
        try:
            text = unit_path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            value["failures"].append(f"{name} resume unit is not UTF-8")
            continue
        match = expression.search(text)
        if match is None:
            value["failures"].append(f"{name} resume ExecStart differs")
            continue
        helper = Path(match.group(1))
        helpers.add(str(helper))
        if not helper.exists() or helper.is_symlink():
            value["failures"].append(f"{name} resume helper is absent or unsafe")
            continue
        helper_info = helper.lstat()
        if (
            not root_file_metadata_is_exact(helper_info, 0o755)
            or sha256_file(helper) != match.group(2)
            or unit_path.read_bytes() != renderer(helper)
        ):
            value["failures"].append(f"{name} resume helper or unit binding differs")

    timer_present = LATE_RESUME_TIMER.exists() or LATE_RESUME_TIMER.is_symlink()
    value["units"]["lateTimer"] = {"unitPresent": timer_present}
    if not timer_present:
        value["missing"].append(str(LATE_RESUME_TIMER))
    elif (
        LATE_RESUME_TIMER.is_symlink()
        or not root_file_metadata_is_exact(LATE_RESUME_TIMER.lstat(), 0o644)
        or LATE_RESUME_TIMER.read_bytes() != late_resume_timer()
    ):
        value["failures"].append("late resume timer differs")

    for name, link_path, target in link_contracts:
        link_present = link_path.exists() or link_path.is_symlink()
        value["units"].setdefault(name, {})["linkPresent"] = link_present
        if not link_present:
            value["missing"].append(str(link_path))
        elif not link_path.is_symlink() or os.readlink(link_path) != str(target):
            value["failures"].append(f"{name} resume wants-link differs")
        elif not target.exists() and not target.is_symlink():
            value["failures"].append(f"{name} resume link exists without its unit")

    for unit, path in zip(GATED_UNITS, gate_paths, strict=True):
        expected_gate = active_transaction_gate_dropin(unit)
        if not path.exists() and not path.is_symlink():
            value["gates"][unit] = "missing"
            value["missing"].append(str(path))
            continue
        if path.is_symlink() or not root_file_metadata_is_exact(path.lstat(), 0o644) or path.read_bytes() != expected_gate:
            value["gates"][unit] = "invalid"
            value["failures"].append(f"active-transaction gate differs: {unit}")
        else:
            value["gates"][unit] = "valid"

    if len(helpers) > 1:
        value["failures"].append("early and late resume helpers differ")
    if value["failures"]:
        return value
    if value["missing"]:
        value["state"] = "partial-valid-permanent-gate"
    else:
        value["state"] = "complete-valid-permanent-gate"
        value["helper"] = next(iter(helpers))
    return value


def maintenance_lock_observation(path: Path = MAINTENANCE_LOCK) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        return {"path": str(path), "state": "absent"}
    st = path.lstat()
    return {
        "path": str(path),
        "state": "file" if stat.S_ISREG(st.st_mode) and not stat.S_ISLNK(st.st_mode) else "unsafe",
        "uid": st.st_uid,
        "gid": st.st_gid,
        "mode": format(stat.S_IMODE(st.st_mode), "04o"),
        "links": st.st_nlink,
        "bytes": st.st_size,
    }


def valid_maintenance_lock(observation: Mapping[str, Any], postgres_gid: int) -> bool:
    return observation == {
        "path": str(MAINTENANCE_LOCK),
        "state": "file",
        "uid": 0,
        "gid": postgres_gid,
        "mode": "0660",
        "links": 1,
        "bytes": 0,
    }


def retained_lv_candidates(path: Path = EVIDENCE_ROOT) -> list[dict[str, Any]]:
    """Find immutable rollback evidence that can authorize retained-LV adoption.

    Merely finding an LV with the expected name is never sufficient.  A
    candidate requires a successful exact lvcreate command logged by this tool,
    its eligible fixed plan, a completed rollback receipt, and no commit receipt.
    """

    if not path.exists() and not path.is_symlink():
        return []
    if (
        path.is_symlink()
        or not path.is_dir()
        or not root_directory_metadata_is_exact(path.lstat(), 0o700)
    ):
        raise CommissioningError("unsafe NVMe commissioning evidence root")
    exact_lvcreate = [
        LVCREATE,
        "--yes",
        "--type",
        "linear",
        "--size",
        "350g",
        "--name",
        TARGET_LV,
        TARGET_VG,
        TARGET_PV,
    ]
    candidates: list[dict[str, Any]] = []
    for child in sorted(path.iterdir(), key=lambda item: item.name):
        try:
            child_info = child.lstat()
        except OSError:
            continue
        if (
            not re.fullmatch(r"nvme-\d{8}T\d{6}Z-[0-9a-f]{12}", child.name)
            or child.is_symlink()
            or not child.is_dir()
            or not root_directory_metadata_is_exact(child_info, 0o700)
        ):
            continue
        commands = child / "commands"
        if (
            commands.is_symlink()
            or not commands.is_dir()
            or not root_directory_metadata_is_exact(commands.lstat(), 0o700)
        ):
            continue
        required = (
            child / "plan.json",
            child / "rollback.json",
            commands / "lvcreate.json",
            child / "lv-identity.json",
        )
        if not all(item.is_file() and not item.is_symlink() for item in required):
            continue
        if any(not root_file_metadata_is_exact(item.lstat(), 0o600) for item in required):
            continue
        if (child / "complete.json").exists() or (child / "complete.json").is_symlink():
            continue
        try:
            plan = load_json_regular(required[0])
            receipt = load_json_regular(required[1])
            validate_lineage_reference(required[1], receipt, "previousReceiptSha256")
            command = load_json_regular(required[2])
            identity = load_json_regular(required[3])
        except CommissioningError:
            continue
        target = plan.get("target")
        plan_core = {key: value for key, value in plan.items() if key != "planSha256"}
        recomputed_plan_sha = sha256_bytes(canonical_bytes(plan_core))
        if (
            plan.get("kind") != KIND + "-plan"
            or plan.get("eligible") is not True
            or not isinstance(target, dict)
            or target.get("vg") != TARGET_VG
            or target.get("lv") != TARGET_LV
            or target.get("sizeBytes") != TARGET_LV_BYTES
            or plan.get("planSha256") != recomputed_plan_sha
            or receipt.get("kind") != KIND + "-rollback"
            or receipt.get("status") != "ROLLED_BACK"
            or receipt.get("transactionId") != child.name
            or receipt.get("planSha256") != plan.get("planSha256")
            or receipt.get("lvRemovalAttempted") is not False
            or receipt.get("lvIdentitySha256") != sha256_file(required[3])
            or receipt.get("lvcreateLogSha256") != sha256_file(required[2])
            or command.get("argv") != exact_lvcreate
            or command.get("returnCode") != 0
            or identity.get("kind") != KIND + "-lv-identity"
            or identity.get("transactionId") != child.name
            or identity.get("planSha256") != plan.get("planSha256")
            or identity.get("lvPath") != TARGET_LV_PATH
            or identity.get("pvPath") != TARGET_PV
            or identity.get("sizeBytes") != TARGET_LV_BYTES
            or identity.get("segmentType") != "linear"
            or not re.fullmatch(rf"{re.escape(TARGET_PV)}\(\d+\)", str(identity.get("devices", "")))
            or not all(LVM_UUID_RE.fullmatch(str(identity.get(key, ""))) for key in ("lvUuid", "vgUuid", "pvUuid"))
        ):
            continue
        mkfs_log = commands / "mkfs-ext4.json"
        mkfs_completed = False
        if mkfs_log.exists() or mkfs_log.is_symlink():
            if (
                mkfs_log.is_symlink()
                or not mkfs_log.is_file()
                or not root_file_metadata_is_exact(mkfs_log.lstat(), 0o600)
            ):
                continue
            try:
                mkfs = load_json_regular(mkfs_log)
                mkfs_completed = mkfs.get("argv") == [MKFS_EXT4, "-L", TARGET_LV, TARGET_LV_PATH] and mkfs.get(
                    "returnCode"
                ) == 0
            except CommissioningError:
                mkfs_completed = False
        candidates.append(
            {
                "transactionId": child.name,
                "evidence": str(child),
                "planSha256": plan.get("planSha256"),
                "rollbackSha256": sha256_file(required[1]),
                "lvcreateLogSha256": sha256_file(required[2]),
                "lvIdentitySha256": sha256_file(required[3]),
                "lvIdentity": identity,
                "mkfsCompleted": mkfs_completed,
            }
        )
    return candidates


def parse_blkid_export(payload: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in payload.splitlines():
        key, separator, value = line.partition("=")
        if separator and re.fullmatch(r"[A-Z0-9_]+", key):
            values[key] = value
    return values


def parse_udev_properties(payload: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in payload.splitlines():
        key, separator, value = line.partition("=")
        if separator and re.fullmatch(r"[A-Z0-9_]+", key):
            values[key] = value
    return values


def canonical_nvme_by_id(device: Path, properties: Mapping[str, str], partition_number: int | None) -> str:
    links = properties.get("DEVLINKS", "").split()
    pattern = (
        re.compile(r"/dev/disk/by-id/nvme-[A-Za-z0-9_.:+-]+")
        if partition_number is None
        else re.compile(rf"/dev/disk/by-id/nvme-[A-Za-z0-9_.:+-]+-part{partition_number}")
    )
    candidates = sorted(
        link
        for link in links
        if pattern.fullmatch(link)
        and not Path(link).name.startswith("nvme-eui.")
        and not Path(link).name.startswith("nvme-uuid.")
    )
    serial = properties.get("ID_SERIAL")
    if isinstance(serial, str) and serial:
        exact_basename = "nvme-" + serial + ("" if partition_number is None else f"-part{partition_number}")
        exact = [link for link in candidates if Path(link).name == exact_basename]
        if len(exact) == 1:
            candidates = exact
    if len(candidates) != 1:
        # Some devices expose only the EUI/WWN stable link; accept exactly one
        # matching nvme by-id in that case, never an ambiguous alias set.
        candidates = sorted(link for link in links if pattern.fullmatch(link))
    if len(candidates) != 1 or os.path.realpath(candidates[0]) != str(device):
        raise CommissioningError(f"stable NVMe by-id is ambiguous for {device}")
    return candidates[0]


def md0_stanza(mdstat: str) -> str | None:
    lines = mdstat.splitlines()
    for index, line in enumerate(lines):
        if re.match(r"^md0\s*:", line):
            collected = [line]
            for following in lines[index + 1 :]:
                if following and not following[0].isspace():
                    break
                collected.append(following)
            return "\n".join(collected)
    return None


def md_stanza_is_clean(stanza: str | None) -> bool:
    if stanza is None or "[2/2]" not in stanza or "[UU]" not in stanza or "inactive" in stanza.lower():
        return False
    lowered = stanza.lower()
    return not any(token in lowered for token in ("recovery", "resync", "reshape", "check", "repair"))


def package_process_observation(proc_root: Path = Path("/proc")) -> list[dict[str, Any]]:
    """Inventory only apt/dpkg processes, including the known passive helper."""

    observed: list[dict[str, Any]] = []
    try:
        children = list(proc_root.iterdir())
    except OSError as exc:
        raise CommissioningError("package process inventory is unavailable") from exc
    for item in children:
        if not item.name.isdigit():
            continue
        try:
            comm = (item / "comm").read_text(encoding="utf-8").strip()
            if comm not in {"apt", "apt-get", "dpkg", "unattended-upgr"}:
                continue
            argv = [
                value.decode("utf-8", errors="replace")
                for value in (item / "cmdline").read_bytes().split(b"\0")
                if value
            ]
            status = {
                key: value.strip()
                for line in (item / "status").read_text(encoding="utf-8").splitlines()
                for key, separator, value in [line.partition(":")]
                if separator
            }
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        observed.append(
            {
                "pid": integer_field(item.name, "package pid"),
                "comm": comm,
                "argv": argv,
                "ppid": integer_field(status.get("PPid", "-1"), "package ppid"),
                "uids": [integer_field(value, "package uid") for value in status.get("Uid", "").split()],
            }
        )
    return sorted(observed, key=lambda row: row["pid"])


def package_lock_observation(runner: Runner) -> list[dict[str, Any]]:
    document = json_command(
        runner,
        [LSLOCKS, "--json", "--notruncate", "--output", "PID,COMMAND,PATH,TYPE,MODE"],
    )
    rows = document.get("locks") if isinstance(document, dict) else None
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise CommissioningError("package lock inventory is malformed")
    return [dict(row) for row in rows if row.get("path") in PACKAGE_LOCK_PATHS]


def passive_unattended_is_exact(processes: Any) -> bool:
    return (
        isinstance(processes, list)
        and len(processes) == 1
        and isinstance(processes[0], dict)
        and processes[0].get("comm") == "unattended-upgr"
        and processes[0].get("argv") == PASSIVE_UNATTENDED_ARGV
        and processes[0].get("ppid") == 1
        and processes[0].get("uids") == [0, 0, 0, 0]
    )


def validate_retained_filesystem(root: Path, filesystem_uuid: str, allowed_transactions: set[str]) -> None:
    if root.is_symlink() or not root.is_dir():
        raise CommissioningError("retained filesystem mountpoint is unsafe")
    allowed_root = {
        "lost+found",
        "postgresql",
        "backups",
        ".uten-imp-storage-authority.json",
    }
    children = {child.name: child for child in root.iterdir()}
    unexpected = sorted(name for name in children if name not in allowed_root)
    if unexpected:
        raise CommissioningError("retained filesystem contains unexpected root entries")
    for directory in ("postgresql", "backups", "lost+found"):
        candidate = root / directory
        if candidate.exists() or candidate.is_symlink():
            if candidate.is_symlink() or not candidate.is_dir():
                raise CommissioningError("retained filesystem contains an unsafe data path")
    exact_children = {
        root / "lost+found": set(),
        root / "postgresql": {"16"},
        root / "postgresql" / "16": {"main"},
        root / "postgresql" / "16" / "main": set(),
        root / "backups": {"pgbackrest"},
        root / "backups" / "pgbackrest": set(),
    }
    root_device = root.stat().st_dev
    for directory, expected in exact_children.items():
        if not directory.exists() and not directory.is_symlink():
            continue
        info = directory.lstat()
        if directory.is_symlink() or not stat.S_ISDIR(info.st_mode) or info.st_dev != root_device:
            raise CommissioningError("retained filesystem contains an unsafe nested directory")
        names = {child.name for child in directory.iterdir()}
        if not names.issubset(expected):
            raise CommissioningError("retained filesystem nested contents differ")
    main = root / "postgresql" / "16" / "main"
    if main.exists() or main.is_symlink():
        if main.is_symlink() or not main.is_dir() or any(main.iterdir()):
            raise CommissioningError("retained PGDATA is not an empty prepared directory")
    marker = root / ".uten-imp-storage-authority.json"
    if marker.exists() or marker.is_symlink():
        document = load_json_regular(marker)
        if (
            document.get("kind") != KIND + "-storage-authority"
            or document.get("status") != "PGDATA_PREPARED_NOT_INITIALIZED"
            or document.get("filesystemUuid", "").lower() != filesystem_uuid.lower()
            or document.get("transactionId") not in allowed_transactions
            or document.get("postgresInitialized") is not False
            or document.get("backupCommissioned") is not False
        ):
            raise CommissioningError("retained storage authority marker is invalid")


def assess(runner: Runner | None = None) -> dict[str, Any]:
    """Perform a root read-only assessment; no path is created or changed."""

    require_root()
    runner = runner or Runner()
    if pwd is None:
        raise CommissioningError("POSIX account inventory is unavailable")
    postgres_gid = pwd.getpwnam("postgres").pw_gid
    started = utc_now()
    hostname = runner.run(["/bin/hostname", "--fqdn"], allowed=(0, 1)).stdout.strip()
    if not hostname:
        hostname = runner.run(["/bin/hostname"]).stdout.strip()

    findmnt_document = json_command(
        runner, [FINDMNT, "--json", "--bytes", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", TARGET_MOUNT]
    )
    data_mount = single_filesystem(findmnt_document)
    old_uuid = str(data_mount.get("uuid", ""))
    old_uuid_mount_result = runner.run(
        [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", "--source", "UUID=" + old_uuid],
        allowed=(0, 1),
    )
    old_uuid_mounts: list[dict[str, Any]] = []
    if old_uuid_mount_result.returncode == 0:
        old_uuid_mount_document = json.loads(old_uuid_mount_result.stdout)
        raw_old_mounts = old_uuid_mount_document.get("filesystems")
        if not isinstance(raw_old_mounts, list) or not all(isinstance(item, dict) for item in raw_old_mounts):
            raise CommissioningError("old data UUID mount inventory is malformed")
        old_uuid_mounts = [dict(item) for item in raw_old_mounts]
    lsblk_document = json_command(
        runner,
        [LSBLK, "--json", "--bytes", "--output", "NAME,KNAME,PATH,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINTS,PKNAME"],
    )
    pvs_rows = parse_lvm_rows(
        json_command(
            runner,
            [PVS, "--reportformat", "json", "--units", "b", "--nosuffix", "--options", "pv_name,pv_size,pv_free,vg_name,pv_uuid"],
        ),
        "pv",
    )
    vgs_rows = parse_lvm_rows(
        json_command(
            runner,
            [VGS, "--reportformat", "json", "--units", "b", "--nosuffix", "--options", "vg_name,vg_size,vg_free,pv_count,lv_count,vg_attr,vg_uuid"],
        ),
        "vg",
    )
    lvs_rows = parse_lvm_rows(
        json_command(
            runner,
            [LVS, "--reportformat", "json", "--units", "b", "--nosuffix", "--options", "vg_name,lv_name,lv_size,lv_attr,devices,lv_uuid,segtype"],
        ),
        "lv",
    )
    target_lvs = [row for row in lvs_rows if row.get("vg_name") == TARGET_VG and row.get("lv_name") == TARGET_LV]
    target_lv_blkid: dict[str, str] | None = None
    target_lv_mounts: list[dict[str, Any]] = []
    if target_lvs:
        blkid_result = runner.run([BLKID, "--probe", "--output", "export", TARGET_LV_PATH], allowed=(0, 2))
        if blkid_result.returncode == 0:
            target_lv_blkid = parse_blkid_export(blkid_result.stdout)
        mount_result = runner.run(
            [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", "--source", TARGET_LV_PATH],
            allowed=(0, 1),
        )
        if mount_result.returncode == 0:
            mount_document = json.loads(mount_result.stdout)
            mounts = mount_document.get("filesystems")
            if not isinstance(mounts, list) or not all(isinstance(item, dict) for item in mounts):
                raise CommissioningError("target LV mount inventory is malformed")
            target_lv_mounts = [dict(item) for item in mounts]

    nvme_result = runner.run([SMARTCTL, "--json", "--all", TARGET_NVME], allowed=range(0, 256))
    try:
        nvme = json.loads(nvme_result.stdout)
    except json.JSONDecodeError as exc:
        raise CommissioningError("invalid NVMe SMART JSON") from exc
    md_export = runner.run([MDADM, "--detail", "--export", OLD_MD_DEVICE]).stdout
    md_values: dict[str, str] = {}
    for line in md_export.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            md_values[key] = value

    fstab_payload = FSTAB.read_bytes()
    fstab_stat = FSTAB.lstat()
    if not stat.S_ISREG(fstab_stat.st_mode) or stat.S_ISLNK(fstab_stat.st_mode):
        raise CommissioningError("fstab is not a regular file")

    units = {unit: unit_state(runner, unit) for unit in SERVICE_UNITS}
    db_query = (
        "SELECT datname || '|' || pg_database_size(datname)::text "
        "FROM pg_database WHERE datallowconn ORDER BY datname;"
    )
    databases_result = runner.run(
        [RUNUSER, "-u", "postgres", "--", PSQL, "--no-psqlrc", "--set", "ON_ERROR_STOP=1", "--dbname", "postgres", "--tuples-only", "--no-align", "--command", db_query]
    )
    data_directory = runner.run(
        [RUNUSER, "-u", "postgres", "--", PSQL, "--no-psqlrc", "--set", "ON_ERROR_STOP=1", "--dbname", "postgres", "--tuples-only", "--no-align", "--command", "SHOW data_directory;"]
    ).stdout.strip()
    control = runner.run([RUNUSER, "-u", "postgres", "--", PG_CONTROLDATA, data_directory]).stdout
    control_values: dict[str, str] = {}
    for line in control.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() in {"Database system identifier", "Database cluster state", "Latest checkpoint's TimeLineID"}:
            control_values[key.strip()] = value.strip()

    backrest = runner.run(
        [RUNUSER, "-u", "postgres", "--", PGBACKREST, "--config=/etc/pgbackrest.conf", "--stanza=uten-imp", "--repo=1", "--output=json", "info"],
        allowed=(0,),
    ).stdout
    try:
        backrest_document = json.loads(backrest)
    except json.JSONDecodeError as exc:
        raise CommissioningError("invalid pgBackRest inventory JSON") from exc

    smart_sdb = runner.run([SMARTCTL, "--json", "--capabilities", "/dev/sdb"], allowed=range(0, 256))
    try:
        smart_sdb_document = json.loads(smart_sdb.stdout)
    except json.JSONDecodeError:
        smart_sdb_document = {"unavailable": True, "returnCode": smart_sdb.returncode}

    assessment = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-assessment",
        "observedAtUtc": started,
        "completedAtUtc": utc_now(),
        "bootId": Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip(),
        "hostname": hostname,
        "dataMount": data_mount,
        "oldDataUuidMounts": old_uuid_mounts,
        "lsblk": lsblk_document,
        "pvs": pvs_rows,
        "vgs": vgs_rows,
        "lvs": lvs_rows,
        "targetLvBlkid": target_lv_blkid,
        "targetLvMounts": target_lv_mounts,
        "nvme": {"processReturnCode": nvme_result.returncode, "document": nvme},
        "md": {
            "export": md_values,
            "procMdstat": Path("/proc/mdstat").read_text(encoding="utf-8"),
            "syncAction": Path("/sys/block/md0/md/sync_action").read_text(encoding="ascii").strip(),
        },
        "fstab": {
            "sha256": sha256_bytes(fstab_payload),
            "mode": format(stat.S_IMODE(fstab_stat.st_mode), "04o"),
            "uid": fstab_stat.st_uid,
            "gid": fstab_stat.st_gid,
            "dataEntries": parse_fstab_data_entries(fstab_payload),
        },
        "units": units,
        "postgres": {
            "dataDirectory": data_directory,
            "databases": [line for line in databases_result.stdout.splitlines() if line],
            "control": control_values,
            "startConf": regular_file_observation(PG_START_CONF, include_text=True),
            "gid": postgres_gid,
        },
        "pgBackRest": backrest_document,
        "packageManager": {
            "dpkgAudit": runner.run([DPKG, "--audit"], allowed=(0,)).stdout,
            "processes": package_process_observation(),
            "locks": package_lock_observation(runner),
        },
        "phaseEvidence": {
            "phase1": evidence_listing(Path("/var/lib/uten-imp-phase1-evidence")),
            "packageWindow": evidence_listing(Path("/var/lib/uten-imp-phase1-package-window")),
            "oldResumeUnitSha256": sha256_file(Path("/etc/systemd/system") / OLD_PHASE1_RESUME)
            if (Path("/etc/systemd/system") / OLD_PHASE1_RESUME).is_file()
            else None,
            "nvmeCommissioning": evidence_listing(EVIDENCE_ROOT),
            "retainedLvCandidates": retained_lv_candidates(),
            "activeNvmeTransaction": {
                "exists": ACTIVE_POINTER.is_file() and not ACTIVE_POINTER.is_symlink(),
                "sha256": sha256_file(ACTIVE_POINTER)
                if ACTIVE_POINTER.is_file() and not ACTIVE_POINTER.is_symlink()
                else None,
            },
            "nvmeResumeInstallation": resume_installation_observation(),
            "postgresMountGuard": regular_file_observation(PG_GUARD),
            "nvmeResumeUnit": regular_file_observation(RESUME_UNIT),
        },
        "sdbLongTestObservation": smart_sdb_document,
        "maintenanceLock": maintenance_lock_observation(),
    }
    return assessment


def assessment_fingerprint(assessment: Mapping[str, Any]) -> str:
    nvme = assessment.get("nvme")
    stable_nvme: Any = nvme
    if isinstance(nvme, dict) and isinstance(nvme.get("document"), dict):
        document = nvme["document"]
        health = document.get("nvme_smart_health_information_log")
        stable_health = None
        if isinstance(health, dict):
            stable_health = {
                key: health.get(key)
                for key in (
                    "critical_warning",
                    "available_spare",
                    "available_spare_threshold",
                    "percentage_used",
                    "media_errors",
                )
            }
        stable_nvme = {
            "processReturnCode": nvme.get("processReturnCode"),
            "modelName": document.get("model_name"),
            "serialNumber": document.get("serial_number"),
            "firmwareVersion": document.get("firmware_version"),
            "smartStatus": document.get("smart_status"),
            "health": stable_health,
        }
    stable = {
        "schemaVersion": assessment.get("schemaVersion"),
        "hostname": assessment.get("hostname"),
        "bootId": assessment.get("bootId"),
        "dataMount": assessment.get("dataMount"),
        "oldDataUuidMounts": assessment.get("oldDataUuidMounts"),
        "lsblk": assessment.get("lsblk"),
        "pvs": assessment.get("pvs"),
        "vgs": assessment.get("vgs"),
        "lvs": assessment.get("lvs"),
        "targetLvBlkid": assessment.get("targetLvBlkid"),
        "targetLvMounts": assessment.get("targetLvMounts"),
        "nvme": stable_nvme,
        "md": assessment.get("md"),
        "fstab": assessment.get("fstab"),
        "units": assessment.get("units"),
        "postgres": assessment.get("postgres"),
        "pgBackRest": assessment.get("pgBackRest"),
        "packageManager": assessment.get("packageManager"),
        "phaseEvidence": assessment.get("phaseEvidence"),
        "maintenanceLock": assessment.get("maintenanceLock"),
    }
    return sha256_bytes(canonical_bytes(stable))


def nvme_health_blockers(nvme: Mapping[str, Any]) -> list[str]:
    blockers: list[str] = []
    process_rc = nvme.get("processReturnCode")
    document = nvme.get("document")
    if process_rc != 0 or not isinstance(document, dict):
        blockers.append("NVME_SMART_COMMAND_NOT_CLEAN")
        return blockers
    smart_status = document.get("smart_status")
    if not isinstance(smart_status, dict) or smart_status.get("passed") is not True:
        blockers.append("NVME_SMART_NOT_PASSED")
    health = document.get("nvme_smart_health_information_log")
    if not isinstance(health, dict):
        blockers.append("NVME_HEALTH_LOG_MISSING")
        return blockers
    if integer_field(health.get("critical_warning", -1), "critical_warning") != 0:
        blockers.append("NVME_CRITICAL_WARNING")
    if integer_field(health.get("media_errors", -1), "media_errors") != 0:
        blockers.append("NVME_MEDIA_ERRORS")
    return blockers


def build_plan(assessment: Mapping[str, Any], expected_hostname: str) -> dict[str, Any]:
    if not HOSTNAME_RE.fullmatch(expected_hostname) or ".." in expected_hostname:
        raise CommissioningError("--expected-hostname is malformed")
    blockers: list[str] = []
    warnings: list[str] = []
    if assessment.get("schemaVersion") != SCHEMA_VERSION:
        blockers.append("ASSESSMENT_SCHEMA_MISMATCH")
    if assessment.get("hostname") != expected_hostname:
        blockers.append("HOSTNAME_MISMATCH")

    data_mount = assessment.get("dataMount")
    if not isinstance(data_mount, dict):
        blockers.append("DATA_MOUNT_MISSING")
    else:
        source = str(data_mount.get("source", ""))
        if source != OLD_MD_DEVICE and not source.startswith(OLD_MD_DEVICE + "["):
            blockers.append("DATA_NOT_ON_EXPECTED_MD")
        if data_mount.get("target") != TARGET_MOUNT or data_mount.get("fstype") != "ext4":
            blockers.append("DATA_MOUNT_CONTRACT_MISMATCH")
        if not re.fullmatch(r"[0-9A-Fa-f-]{8,64}", str(data_mount.get("uuid", ""))):
            blockers.append("OLD_DATA_UUID_INVALID")
    old_uuid_mounts = assessment.get("oldDataUuidMounts")
    if (
        not isinstance(old_uuid_mounts, list)
        or len(old_uuid_mounts) != 1
        or not isinstance(old_uuid_mounts[0], dict)
        or old_uuid_mounts[0].get("target") != TARGET_MOUNT
        or normalized_mount_source(old_uuid_mounts[0].get("source")) != OLD_MD_DEVICE
    ):
        blockers.append("OLD_DATA_UUID_MOUNT_TOPOLOGY_AMBIGUOUS")

    pvs = assessment.get("pvs")
    vgs = assessment.get("vgs")
    lvs = assessment.get("lvs")
    target_pvs = [
        row
        for row in pvs or []
        if isinstance(row, dict) and row.get("pv_name") == TARGET_PV and row.get("vg_name") == TARGET_VG
    ]
    all_vg_pvs = [row for row in pvs or [] if isinstance(row, dict) and row.get("vg_name") == TARGET_VG]
    if len(target_pvs) != 1:
        blockers.append("TARGET_NVME_PV_NOT_IN_EXPECTED_VG")
    elif len(all_vg_pvs) != 1:
        blockers.append("TARGET_VG_MUST_HAVE_EXACTLY_ONE_PV")
    vg_rows = [row for row in vgs or [] if isinstance(row, dict) and row.get("vg_name") == TARGET_VG]
    if len(vg_rows) != 1:
        blockers.append("TARGET_VG_AMBIGUOUS")
        vg_free = 0
    else:
        vg_free = integer_field(vg_rows[0].get("vg_free"), "vg_free")
        if integer_field(vg_rows[0].get("pv_count"), "pv_count") != 1:
            blockers.append("TARGET_VG_PV_COUNT_MISMATCH")
    target_lvs = [
        row for row in lvs or [] if isinstance(row, dict) and row.get("vg_name") == TARGET_VG and row.get("lv_name") == TARGET_LV
    ]
    target_mode = "create-new"
    adoption_candidate: dict[str, Any] | None = None
    if target_lvs:
        phase = assessment.get("phaseEvidence")
        candidates = phase.get("retainedLvCandidates") if isinstance(phase, dict) else None
        target_blkid = assessment.get("targetLvBlkid")
        target_mounts = assessment.get("targetLvMounts")
        if len(target_lvs) != 1:
            blockers.append("TARGET_LV_AMBIGUOUS")
        elif integer_field(target_lvs[0].get("lv_size"), "retained lv_size") != TARGET_LV_BYTES:
            blockers.append("RETAINED_LV_SIZE_MISMATCH")
        elif not re.fullmatch(rf"{re.escape(TARGET_PV)}\(\d+\)", str(target_lvs[0].get("devices", ""))):
            blockers.append("RETAINED_LV_DEVICE_MISMATCH")
        elif target_lvs[0].get("segtype") != "linear":
            blockers.append("RETAINED_LV_SEGMENT_TYPE_MISMATCH")
        elif not isinstance(target_mounts, list) or target_mounts:
            blockers.append("RETAINED_LV_IS_MOUNTED")
        elif not isinstance(candidates, list) or len(candidates) != 1 or not isinstance(candidates[0], dict):
            blockers.append("RETAINED_LV_PROVENANCE_AMBIGUOUS")
        elif len(vg_rows) != 1 or len(target_pvs) != 1:
            blockers.append("RETAINED_LV_LVM_PARENT_IDENTITY_MISSING")
        elif not isinstance(candidates[0].get("lvIdentity"), dict) or any(
            (
                target_lvs[0].get("lv_uuid") != candidates[0]["lvIdentity"].get("lvUuid"),
                vg_rows[0].get("vg_uuid") != candidates[0]["lvIdentity"].get("vgUuid"),
                target_pvs[0].get("pv_uuid") != candidates[0]["lvIdentity"].get("pvUuid"),
            )
        ):
            blockers.append("RETAINED_LV_IDENTITY_MISMATCH")
        elif target_blkid is not None and (
            not isinstance(target_blkid, dict)
            or target_blkid.get("TYPE") != "ext4"
            or target_blkid.get("LABEL") != TARGET_LV
            or not re.fullmatch(r"[0-9A-Fa-f-]{8,64}", str(target_blkid.get("UUID", "")))
        ):
            blockers.append("RETAINED_LV_FILESYSTEM_UNSAFE")
        else:
            target_mode = "adopt-retained"
            adoption_candidate = dict(candidates[0])
            warnings.append("RETAINED_LV_WILL_BE_ADOPTED_ONLY_AFTER_ON_DISK_CONTENT_VALIDATION")
    if target_mode == "create-new" and vg_free < TARGET_LV_BYTES + MINIMUM_VG_REMAINING_BYTES:
        blockers.append("INSUFFICIENT_VG_FREE_SPACE")
    if target_mode == "create-new" and (
        len(target_pvs) != 1
        or integer_field(target_pvs[0].get("pv_free"), "target pv_free")
        < TARGET_LV_BYTES + MINIMUM_VG_REMAINING_BYTES
    ):
        blockers.append("INSUFFICIENT_TARGET_NVME_PV_FREE_SPACE")
    if target_mode == "adopt-retained" and vg_free < MINIMUM_VG_REMAINING_BYTES:
        blockers.append("INSUFFICIENT_VG_RESERVE_AFTER_RETAINED_LV")

    phase = assessment.get("phaseEvidence")
    if isinstance(phase, dict):
        active = phase.get("activeNvmeTransaction")
        if isinstance(active, dict) and active.get("exists") is True:
            blockers.append("ACTIVE_NVME_TRANSACTION_REQUIRES_RECOVER")
        resume_installation = phase.get("nvmeResumeInstallation")
        if not isinstance(resume_installation, dict) or resume_installation.get("state") not in {
            "absent",
            "partial-valid-permanent-gate",
            "complete-valid-permanent-gate",
        }:
            blockers.append("NVME_RESUME_INSTALLATION_UNSAFE")

    try:
        blockers.extend(nvme_health_blockers(assessment.get("nvme", {})))
    except CommissioningError:
        blockers.append("NVME_HEALTH_DOCUMENT_INVALID")

    md = assessment.get("md")
    if not isinstance(md, dict):
        blockers.append("MD_INVENTORY_MISSING")
    else:
        export = md.get("export")
        mdstat = str(md.get("procMdstat", ""))
        stanza = md0_stanza(mdstat)
        if (
            not isinstance(export, dict)
            or export.get("MD_LEVEL") != "raid1"
            or export.get("MD_DEVICES") != "2"
            or not isinstance(export.get("MD_UUID"), str)
            or not export.get("MD_UUID")
            or export.get("MD_STATE") not in {"clean", "active", "active,clean"}
        ):
            blockers.append("OLD_MD_NOT_RAID1")
        if not md_stanza_is_clean(stanza) or md.get("syncAction") != "idle":
            blockers.append("OLD_MD_NOT_CLEAN_TWO_MEMBER")

    fstab = assessment.get("fstab")
    if not isinstance(fstab, dict) or len(fstab.get("dataEntries", [])) != 1:
        blockers.append("FSTAB_DATA_ENTRY_AMBIGUOUS")
    else:
        fields = fstab["dataEntries"][0].get("fields", [])
        old_uuid = data_mount.get("uuid") if isinstance(data_mount, dict) else None
        if not fields or fields[0] not in {OLD_MD_DEVICE, "UUID=" + str(old_uuid)}:
            blockers.append("FSTAB_DATA_SOURCE_UNEXPECTED")

    postgres = assessment.get("postgres")
    if not isinstance(postgres, dict) or postgres.get("dataDirectory") != "/data/postgresql/16/main":
        blockers.append("POSTGRES_DATA_DIRECTORY_UNEXPECTED")
    elif (
        not isinstance(postgres.get("startConf"), dict)
        or postgres["startConf"].get("exists") is not True
        or postgres["startConf"].get("unsafeType") is not False
        or postgres_start_mode(postgres["startConf"].get("text")) is None
    ):
        blockers.append("POSTGRES_START_CONF_UNSAFE")
    postgres_gid = postgres.get("gid") if isinstance(postgres, dict) else None
    if (
        isinstance(postgres_gid, bool)
        or not isinstance(postgres_gid, int)
        or not isinstance(assessment.get("maintenanceLock"), dict)
        or not valid_maintenance_lock(assessment["maintenanceLock"], postgres_gid)
    ):
        blockers.append("DATABASE_MAINTENANCE_LOCK_UNSAFE_OR_ABSENT")
    backrest = assessment.get("pgBackRest")
    if (
        not isinstance(backrest, list)
        or len(backrest) != 1
        or not isinstance(backrest[0], dict)
        or backrest[0].get("name") != "uten-imp"
        or not isinstance(backrest[0].get("status"), dict)
        or backrest[0]["status"].get("code") != 0
        or not isinstance(backrest[0].get("backup"), list)
        or not backrest[0]["backup"]
    ):
        blockers.append("PGBACKREST_INVENTORY_AMBIGUOUS")

    units = assessment.get("units")
    if not isinstance(units, dict):
        blockers.append("UNIT_INVENTORY_MISSING")
    else:
        for unit in ("uten-pgbackup.service", "uten-pgbackup-repo2.service"):
            if units.get(unit, {}).get("ActiveState") in {"active", "activating", "deactivating"}:
                blockers.append("ACTIVE_BACKUP_JOB_MUST_FINISH")
        if units.get(OLD_PHASE1_RESUME, {}).get("ActiveState") in {"active", "activating", "deactivating"}:
            blockers.append("OLD_PHASE1_RESUME_MUST_BE_INACTIVE")
        for unit in APT_JOB_SERVICES:
            if units.get(unit, {}).get("ActiveState") not in {"inactive", "failed"}:
                blockers.append("PACKAGE_MANAGER_MUST_FINISH")
        for unit in SERVICE_UNITS:
            if units.get(unit, {}).get("ActiveState") in {"activating", "deactivating"}:
                blockers.append("TRANSITIONING_UNIT_" + safe_name(unit).upper().replace(".", "_"))
            if units.get(unit, {}).get("UnitFileState") not in {
                "enabled",
                "enabled-runtime",
                "disabled",
                "static",
                "indirect",
                "not-found",
                None,
                "",
            }:
                blockers.append("UNSUPPORTED_UNIT_ENABLEMENT_" + safe_name(unit).upper().replace(".", "_"))

    package = assessment.get("packageManager")
    if not isinstance(package, dict):
        blockers.append("PACKAGE_MANAGER_INVENTORY_MISSING")
    else:
        if package.get("dpkgAudit") != "":
            blockers.append("DPKG_AUDIT_NOT_CLEAN")
        if package.get("locks") != []:
            blockers.append("PACKAGE_MANAGER_LOCK_ACTIVE")
        processes = package.get("processes")
        unattended_active = (
            isinstance(units, dict)
            and units.get("unattended-upgrades.service", {}).get("ActiveState") == "active"
        )
        if unattended_active:
            if not passive_unattended_is_exact(processes):
                blockers.append("UNATTENDED_UPGRADES_PROCESS_IDENTITY_DIFFERS")
        elif processes != []:
            blockers.append("PACKAGE_MANAGER_PROCESS_ACTIVE")

    if assessment.get("sdbLongTestObservation"):
        warnings.append("SDB_LONG_TEST_MAY_FINISH_NATURALLY;_NO_SDA_TEST_OR_RAID_SCRUB_IS_REQUIRED")
    warnings.extend(
        [
            "SUCCESS_STOPS_AT_EMPTY_PGDATA_PREPARATION;_POSTGRESQL_REMAINS_DISABLED",
            "OLD_MD_IS_RETAINED_ASSEMBLED_AND_UNMOUNTED;IT_IS_NOT_A_BACKUP_AUTHORITY",
            "NOFAIL_ONLY_COVERS_DATA_LV_OR_FILESYSTEM_FAILURE_WHILE_THE_OS_NVME_REMAINS_AVAILABLE;THE_POSTGRES_MOUNT_GUARD_PREVENTS_ROOT_FILESYSTEM_FALLBACK",
            "SINGLE_NVME_IS_ACCEPTABLE_FOR_INTERNAL_TEST_ONLY;PRODUCTION_REQUIRES_ANOTHER_FAILURE_DOMAIN",
        ]
    )

    core = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-plan",
        "assessmentFingerprint": assessment_fingerprint(assessment),
        "expectedHostname": expected_hostname,
        "eligible": not blockers,
        "blockers": sorted(set(blockers)),
        "warnings": warnings,
        "target": {
            "vg": TARGET_VG,
            "lv": TARGET_LV,
            "lvPath": TARGET_LV_PATH,
            "sizeBytes": TARGET_LV_BYTES,
            "minimumVgRemainingBytes": MINIMUM_VG_REMAINING_BYTES,
            "expectedVgRemainingBytes": max(0, vg_free if target_mode == "adopt-retained" else vg_free - TARGET_LV_BYTES),
            "filesystem": "ext4",
            "mount": TARGET_MOUNT,
            "fstabOptions": "rw,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=30s",
            "mode": target_mode,
            "adoptionCandidate": adoption_candidate,
        },
        "oldStorage": {
            "device": OLD_MD_DEVICE,
            "action": "unmount-only-retain-assembled-no-wipe-no-stop",
        },
        "servicePolicy": {
            "stopOrder": list(STOP_ORDER),
            "disableOnSuccess": list(SUCCESS_DISABLE_UNITS),
            "restoreActiveAndEnablementMapOnFailure": True,
        },
        "databaseBoundary": {
            "path": "/data/postgresql/16/main",
            "action": "create-empty-owned-directory-only",
            "initdb": False,
            "roles": False,
            "migrations": False,
            "oldDatabaseDeletion": False,
            "debianClusterStartConf": "manual",
        },
        "backupBoundary": {
            "oldRepoRetainedOnOldMd": True,
            "newRepoCommissioned": False,
            "timersRemainDisabled": True,
        },
        "phase1Resume": {
            "unitFilePreserved": True,
            "receiptsPreserved": True,
            "enablementAfterSuccess": "disabled",
        },
        "recovery": {
            "automaticEarlyBootResume": True,
            "earlyPhase": "restore-old-storage-and-enablement-only",
            "latePhase": "post-multi-user-start-and-health-verify-prior-active-units",
            "permanentActivePointerGate": True,
            "gatedUnits": list(GATED_UNITS),
            "volatileLateGrant": str(LATE_GRANT),
            "unitSpecificGateDirectory": str(GATE_OPEN_DIRECTORY),
            "boundedLateAttemptsPerBoot": LATE_RECOVERY_ATTEMPTS,
            "restoreFstab": True,
            "restoreUnitFiles": True,
            "restoreServiceMap": True,
            "removeLv": False,
        },
        "confirmationPhrase": CONFIRM_PHRASE,
    }
    plan_sha = sha256_bytes(canonical_bytes(core))
    return {**core, "planSha256": plan_sha}


def verify_plan_authorization(plan: Mapping[str, Any], plan_sha256: str, confirmation: str) -> None:
    if plan.get("eligible") is not True or plan.get("blockers"):
        raise CommissioningError("current read-only plan is not eligible")
    if not re.fullmatch(r"[0-9a-f]{64}", plan_sha256 or ""):
        raise CommissioningError("--plan-sha256 must be a lowercase SHA-256")
    if plan.get("planSha256") != plan_sha256:
        raise CommissioningError("plan SHA-256 is stale or does not match current state")
    if confirmation != CONFIRM_PHRASE:
        raise CommissioningError("typed confirmation phrase does not match")


def file_preimage(path: Path, evidence: Path, name: str) -> dict[str, Any]:
    if path.is_symlink():
        raise CommissioningError(f"refusing symlink preimage: {path}")
    if not path.exists():
        return {"path": str(path), "exists": False}
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise CommissioningError(f"preimage is not a regular file: {path}")
    payload = path.read_bytes()
    copy = evidence / "preimages" / safe_name(name)
    atomic_write(copy, payload, mode=0o600, replace=False)
    return {
        "path": str(path),
        "exists": True,
        "copy": str(copy),
        "sha256": sha256_bytes(payload),
        "mode": stat.S_IMODE(st.st_mode),
        "uid": st.st_uid,
        "gid": st.st_gid,
    }


def restore_file_preimage(record: Mapping[str, Any]) -> None:
    path = Path(str(record["path"]))
    if record.get("exists") is not True:
        if path.exists() or path.is_symlink():
            if path.is_symlink() or path.is_file():
                path.unlink()
                fsync_directory(path.parent)
            else:
                raise CommissioningError(f"cannot remove unexpected non-file: {path}")
        return
    copy = Path(str(record["copy"]))
    payload = copy.read_bytes()
    if sha256_bytes(payload) != record.get("sha256"):
        raise CommissioningError(f"preimage checksum mismatch: {path}")
    if not path.parent.exists():
        path.parent.mkdir(parents=True, mode=0o755)
        os.chown(path.parent, 0, 0)
    parent_stat = path.parent.lstat()
    if (
        not stat.S_ISDIR(parent_stat.st_mode)
        or stat.S_ISLNK(parent_stat.st_mode)
        or parent_stat.st_uid != 0
        or parent_stat.st_gid != 0
        or stat.S_IMODE(parent_stat.st_mode) & 0o022
    ):
        raise CommissioningError(f"untrusted preimage parent: {path.parent}")
    temporary = path.parent / f".{path.name}.restore-{os.getpid()}-{time.monotonic_ns()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, int(record["mode"]))
    try:
        os.fchown(fd, int(record["uid"]), int(record["gid"]))
        os.fchmod(fd, int(record["mode"]))
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view) :]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    fsync_directory(path.parent)


def write_system_file(path: Path, payload: bytes, mode: int = 0o644) -> None:
    parent = path.parent
    if parent.is_symlink():
        raise CommissioningError(f"system file parent is a symlink: {parent}")
    if not parent.exists():
        parent.mkdir(parents=True, mode=0o755)
        os.chown(parent, 0, 0)
    parent_stat = parent.lstat()
    if (
        not stat.S_ISDIR(parent_stat.st_mode)
        or stat.S_ISLNK(parent_stat.st_mode)
        or parent_stat.st_uid != 0
        or parent_stat.st_gid != 0
        or stat.S_IMODE(parent_stat.st_mode) & 0o022
    ):
        raise CommissioningError(f"untrusted system file parent: {parent}")
    temporary = parent / f".{path.name}.incoming-{os.getpid()}-{time.monotonic_ns()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        os.fchown(fd, 0, 0)
        os.fchmod(fd, mode)
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view) :]
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    fsync_directory(parent)


def install_exact_permanent_file(path: Path, payload: bytes, mode: int) -> None:
    """Install an immutable operational helper/unit/drop-in without overwriting drift."""

    ensure_trusted_durable_directory(path.parent)
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not root_file_metadata_is_exact(path.lstat(), mode) or path.read_bytes() != payload:
            raise CommissioningError(f"existing permanent recovery file differs: {path}")
        return
    write_system_file(path, payload, mode)


def install_exact_permanent_symlink(path: Path, target: Path) -> None:
    ensure_trusted_durable_directory(path.parent)
    if path.exists() or path.is_symlink():
        if not path.is_symlink() or os.readlink(path) != str(target):
            raise CommissioningError(f"existing permanent recovery link differs: {path}")
        return
    os.symlink(str(target), path)
    fsync_directory(path.parent)


class Transaction:
    def __init__(
        self,
        runner: Runner,
        plan: Mapping[str, Any],
        assessment: Mapping[str, Any],
        approval_reference: str,
    ) -> None:
        if not APPROVAL_RE.fullmatch(approval_reference):
            raise CommissioningError("storage approval reference is malformed")
        self.runner = runner
        self.plan = dict(plan)
        self.assessment = dict(assessment)
        self.transaction_id = "nvme-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12]
        self.evidence = EVIDENCE_ROOT / self.transaction_id
        self.preimages: dict[str, Any] = {}
        self.helper_path: Path | None = None
        self.lv_created = False
        self.approval_reference = approval_reference

    def state(self, name: str, **extra: Any) -> None:
        atomic_json(
            self.evidence / "state.json",
            {"schemaVersion": SCHEMA_VERSION, "transactionId": self.transaction_id, "state": name, "recordedAtUtc": utc_now(), **extra},
        )

    def prepare(self) -> None:
        ensure_secure_directory(EVIDENCE_ROOT)
        ensure_secure_directory(self.evidence)
        ensure_secure_directory(self.evidence / "preimages")
        ensure_secure_directory(self.evidence / "commands")
        self.runner.command_log = self.evidence / "commands"
        atomic_json(self.evidence / "assessment.json", self.assessment, replace=False)
        atomic_json(self.evidence / "plan.json", self.plan, replace=False)
        self.preimages = {
            "fstab": file_preimage(FSTAB, self.evidence, "fstab"),
            "pgGuard": file_preimage(PG_GUARD, self.evidence, "postgresql-uten-imp-data.conf"),
            "pgStartConf": file_preimage(PG_START_CONF, self.evidence, "postgresql-start.conf"),
            "resumeUnit": file_preimage(RESUME_UNIT, self.evidence, "nvme-resume.service"),
            "storageAuthority": file_preimage(STORAGE_AUTHORITY, self.evidence, "storage-authority.json"),
            "serviceMap": self.assessment["units"],
            "oldDataMount": self.assessment["dataMount"],
            "oldMd": self.assessment["md"]["export"],
            "temporaryMountpoint": str(Path("/run") / f"uten-imp-nvme-verify-{self.transaction_id}"),
            "targetLvPath": TARGET_LV_PATH,
        }
        atomic_json(self.evidence / "preimages.json", self.preimages, replace=False)
        self.state("PREPARED")

    def install_resume(self) -> None:
        source = Path(__file__).resolve()
        source_stat = source.lstat()
        if (
            source.is_symlink()
            or not stat.S_ISREG(source_stat.st_mode)
            or source_stat.st_uid != 0
            or source_stat.st_gid != 0
            or source_stat.st_nlink != 1
            or stat.S_IMODE(source_stat.st_mode) & 0o022
        ):
            raise CommissioningError("apply requires a trusted root-owned commissioner source")
        flags = os.O_RDONLY | os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        descriptor = os.open(source, flags)
        try:
            opened = os.fstat(descriptor)
            if opened.st_dev != source_stat.st_dev or opened.st_ino != source_stat.st_ino:
                raise CommissioningError("commissioner source changed during trust verification")
            chunks: list[bytes] = []
            digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
                digest.update(chunk)
            source_payload = b"".join(chunks)
            helper_sha = digest.hexdigest()
        finally:
            os.close(descriptor)
        self.helper_path = HELPER_ROOT / f"uten-imp-nvme-commissioner-{helper_sha}.py"
        ensure_trusted_durable_directory(HELPER_ROOT)
        install_exact_permanent_file(self.helper_path, source_payload, 0o755)
        install_exact_permanent_file(RESUME_UNIT, resume_unit(self.helper_path), 0o644)
        install_exact_permanent_file(LATE_RESUME_UNIT, late_resume_unit(self.helper_path), 0o644)
        install_exact_permanent_file(LATE_RESUME_TIMER, late_resume_timer(), 0o644)
        install_exact_permanent_file(GATE_AUTHORIZER_UNIT, gate_authorizer_unit(self.helper_path), 0o644)
        install_exact_permanent_symlink(RESUME_LINK, RESUME_UNIT)
        install_exact_permanent_symlink(LATE_RESUME_LINK, LATE_RESUME_TIMER)
        for unit in GATED_UNITS:
            install_exact_permanent_file(gate_dropin_path(unit), active_transaction_gate_dropin(unit), 0o644)
        self.runner.run([SYSTEMCTL, "daemon-reload"], log_name="resume-daemon-reload")
        self.runner.run(
            [
                SYSTEMD_ANALYZE,
                "verify",
                str(RESUME_UNIT),
                str(LATE_RESUME_UNIT),
                str(LATE_RESUME_TIMER),
                str(GATE_AUTHORIZER_UNIT),
            ],
            log_name="resume-systemd-analyze-verify",
        )
        if ACTIVE_POINTER.exists() or ACTIVE_POINTER.is_symlink():
            raise CommissioningError("an active transaction pointer appeared while installing recovery")
        installation = resume_installation_observation()
        if installation.get("state") != "complete-valid-permanent-gate" or installation.get("helper") != str(
            self.helper_path
        ):
            raise CommissioningError("permanent two-stage recovery installation did not verify")
        # The fixed unit/link are permanent and ConditionPathExists makes them
        # a no-op outside a transaction.  Therefore the only transactional
        # arm/disarm directory entry is this durable pointer. Publish it before
        # closing the volatile markers: a protected start racing this boundary
        # can still run only before any destructive/storage mutation begins.
        # Once the pointer exists, every authorizer restart observes it and
        # returns success with an empty marker set.
        atomic_json(
            ACTIVE_POINTER,
            {
                "schemaVersion": SCHEMA_VERSION,
                "transactionId": self.transaction_id,
                "evidence": str(self.evidence),
                "planSha256": self.plan["planSha256"],
                "preimagesSha256": sha256_file(self.evidence / "preimages.json"),
                "helperSha256": helper_sha,
            },
            replace=False,
        )
        ensure_gate_authorizer_closed(self.runner)
        self.state("RESUME_ARMED")

    def disable_old_resume(self) -> None:
        ensure_gate_authorizer_closed(self.runner)
        self.runner.run([SYSTEMCTL, "disable", OLD_PHASE1_RESUME], allowed=(0,), log_name="disable-old-phase1-resume")
        if unit_state(self.runner, OLD_PHASE1_RESUME).get("UnitFileState") not in {"disabled", "static", "indirect"}:
            raise CommissioningError("old Phase 1 resume did not become disabled")
        self.state("OLD_PHASE1_RESUME_DISABLED")

    def stop_units(self) -> None:
        # Stop timers first while the shared maintenance lock is held.  Never
        # stop/kill a running backup job: an active job here means the lock
        # contract was bypassed or state changed, so the transaction rolls back.
        ensure_gate_authorizer_closed(self.runner)
        for unit in BACKUP_TIMERS:
            self.runner.run([SYSTEMCTL, "stop", unit], allowed=(0, 5), log_name="stop-" + unit)
        for unit in BACKUP_JOB_SERVICES:
            current = unit_state(self.runner, unit)
            if current.get("ActiveState") not in {"inactive", "failed"}:
                raise CommissioningError("backup job became active; it will not be stopped")
        for unit in APT_TIMERS:
            self.runner.run([SYSTEMCTL, "stop", unit], allowed=(0,), log_name="stop-" + unit)
        for unit in APT_JOB_SERVICES:
            if unit_state(self.runner, unit).get("ActiveState") not in {"inactive", "failed"}:
                raise CommissioningError("package manager became active; it will not be stopped")
        processes_before_stop = package_process_observation()
        unattended_was_active = self.assessment["units"].get("unattended-upgrades.service", {}).get("ActiveState") == "active"
        if (unattended_was_active and not passive_unattended_is_exact(processes_before_stop)) or (
            not unattended_was_active and processes_before_stop != []
        ):
            raise CommissioningError("package process identity changed; active package work will not be stopped")
        if package_lock_observation(self.runner) or self.runner.run([DPKG, "--audit"]).stdout:
            raise CommissioningError("package state changed before passive helper stop")
        self.runner.run(
            [SYSTEMCTL, "stop", "unattended-upgrades.service"],
            allowed=(0,),
            log_name="stop-passive-unattended-upgrades",
        )
        if unit_state(self.runner, "unattended-upgrades.service").get("ActiveState") not in {"inactive", "failed"}:
            raise CommissioningError("passive unattended-upgrades helper did not stop")
        if package_process_observation() or package_lock_observation(self.runner) or self.runner.run([DPKG, "--audit"]).stdout:
            raise CommissioningError("package manager is not quiescent after update window setup")
        for unit in STOP_ORDER:
            if unit in BACKUP_TIMERS or unit in BACKUP_JOB_SERVICES:
                continue
            self.runner.run([SYSTEMCTL, "stop", unit], allowed=(0, 5), log_name="stop-" + unit)
        for unit in SUCCESS_DISABLE_UNITS:
            before = self.assessment["units"].get(unit, {})
            if before.get("LoadState") == "not-found":
                continue
            self.runner.run([SYSTEMCTL, "disable", unit], allowed=(0,), log_name="disable-" + unit)
        # Re-run the pointer-aware authorizer immediately before the first
        # configuration/storage mutation, then prove no job accepted in the
        # arming window remains active.
        ensure_gate_authorizer_closed(self.runner)
        for unit in STOP_ORDER:
            if unit_state(self.runner, unit).get("ActiveState") not in {"inactive", "failed"}:
                raise CommissioningError(f"unit restarted during transaction arming: {unit}")
        start_conf_payload = PG_START_CONF.read_bytes()
        start_conf_stat = PG_START_CONF.lstat()
        write_system_file(
            PG_START_CONF,
            render_postgres_start_manual(start_conf_payload),
            stat.S_IMODE(start_conf_stat.st_mode),
        )
        os.chown(PG_START_CONF, start_conf_stat.st_uid, start_conf_stat.st_gid)
        self.runner.run([SYSTEMCTL, "daemon-reload"], log_name="postgres-manual-daemon-reload")
        for unit in STOP_ORDER:
            current = unit_state(self.runner, unit)
            if current.get("ActiveState") not in {"inactive", "failed"}:
                raise CommissioningError(f"unit did not stop: {unit}")
        for unit in SUCCESS_DISABLE_UNITS:
            before = self.assessment["units"].get(unit, {})
            if before.get("LoadState") == "not-found":
                continue
            if unit_state(self.runner, unit).get("UnitFileState") not in {
                "disabled",
                "static",
                "indirect",
                "generated",
                "transient",
            }:
                raise CommissioningError(f"unit did not become disabled: {unit}")
        users = self.runner.run([FUSER, "--mount", TARGET_MOUNT], allowed=(0, 1), log_name="data-mount-users")
        if users.returncode == 0:
            raise CommissioningError("/data still has users after services stopped")
        self.state("SERVICES_STOPPED")

    def backup_vg_metadata(self) -> None:
        ensure_gate_authorizer_closed(self.runner)
        for unit in STOP_ORDER:
            if unit_state(self.runner, unit).get("ActiveState") not in {"inactive", "failed"}:
                raise CommissioningError(f"unit is active at storage mutation boundary: {unit}")
        target = self.evidence / "ubuntu-vg.vgcfg"
        self.runner.run([VGCFGBACKUP, "--file", str(target), TARGET_VG], log_name="vgcfgbackup")
        if not target.is_file() or target.is_symlink() or target.stat().st_size == 0:
            raise CommissioningError("vgcfgbackup did not create a regular evidence file")
        atomic_json(
            self.evidence / "vgcfgbackup.json",
            {"path": str(target), "sha256": sha256_file(target), "bytes": target.stat().st_size},
            replace=False,
        )
        self.state("VG_METADATA_BACKED_UP")

    def create_filesystem(self) -> str:
        mode = self.plan.get("target", {}).get("mode")
        if mode == "create-new":
            self.runner.run(
                [
                    LVCREATE,
                    "--yes",
                    "--type",
                    "linear",
                    "--size",
                    "350g",
                    "--name",
                    TARGET_LV,
                    TARGET_VG,
                    TARGET_PV,
                ],
                log_name="lvcreate",
                timeout=DESTRUCTIVE_COMMAND_TIMEOUT_SECONDS,
            )
            self.lv_created = True
            self.state("LV_CREATED", lvPath=TARGET_LV_PATH)
        elif mode == "adopt-retained":
            expected = self.plan.get("target", {}).get("adoptionCandidate")
            current = retained_lv_candidates()
            if not isinstance(expected, dict) or len(current) != 1 or current[0] != expected:
                raise CommissioningError("retained LV provenance changed after authorization")
            self.state("RETAINED_LV_PROVENANCE_VERIFIED", sourceTransaction=expected.get("transactionId"))
        else:
            raise CommissioningError("unknown LV provisioning mode")
        lvs_after = parse_lvm_rows(
            json_command(
                self.runner,
                [LVS, "--reportformat", "json", "--units", "b", "--nosuffix", "--options", "vg_name,lv_name,lv_size,lv_attr,devices,lv_uuid,segtype"],
            ),
            "lv",
        )
        target = [row for row in lvs_after if row.get("vg_name") == TARGET_VG and row.get("lv_name") == TARGET_LV]
        if (
            len(target) != 1
            or integer_field(target[0].get("lv_size"), "new lv_size") != TARGET_LV_BYTES
            or target[0].get("segtype") != "linear"
            or not re.fullmatch(rf"{re.escape(TARGET_PV)}\(\d+\)", str(target[0].get("devices", "")))
        ):
            raise CommissioningError("created LV identity or size differs")
        vgs_after = parse_lvm_rows(
            json_command(
                self.runner,
                [VGS, "--reportformat", "json", "--units", "b", "--nosuffix", "--options", "vg_name,vg_size,vg_free,pv_count,lv_count,vg_attr,vg_uuid"],
            ),
            "vg",
        )
        vg = [row for row in vgs_after if row.get("vg_name") == TARGET_VG]
        if len(vg) != 1 or integer_field(vg[0].get("vg_free"), "remaining vg_free") < MINIMUM_VG_REMAINING_BYTES:
            raise CommissioningError("created LV leaves less than the required VG reserve")
        pvs_after = parse_lvm_rows(
            json_command(
                self.runner,
                [PVS, "--reportformat", "json", "--units", "b", "--nosuffix", "--options", "pv_name,pv_size,pv_free,vg_name,pv_uuid"],
            ),
            "pv",
        )
        pv = [row for row in pvs_after if row.get("vg_name") == TARGET_VG and row.get("pv_name") == TARGET_PV]
        if len(pv) != 1 or any(
            not LVM_UUID_RE.fullmatch(str(value))
            for value in (target[0].get("lv_uuid"), vg[0].get("vg_uuid"), pv[0].get("pv_uuid"))
        ):
            raise CommissioningError("created LV parent identity differs")
        identity = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": KIND + "-lv-identity",
            "transactionId": self.transaction_id,
            "planSha256": self.plan["planSha256"],
            "lvPath": TARGET_LV_PATH,
            "pvPath": TARGET_PV,
            "sizeBytes": TARGET_LV_BYTES,
            "segmentType": "linear",
            "devices": target[0]["devices"],
            "lvUuid": target[0]["lv_uuid"],
            "vgUuid": vg[0]["vg_uuid"],
            "pvUuid": pv[0]["pv_uuid"],
        }
        if mode == "create-new":
            atomic_json(self.evidence / "lv-identity.json", identity, replace=False)
        else:
            candidate_identity = self.plan.get("target", {}).get("adoptionCandidate", {}).get("lvIdentity")
            if not isinstance(candidate_identity, dict):
                raise CommissioningError("retained LV immutable identity is absent")
            if identity | {"transactionId": str(candidate_identity.get("transactionId", "")), "planSha256": str(candidate_identity.get("planSha256", ""))} != candidate_identity:
                raise CommissioningError("retained LV immutable identity changed")
        probe = self.runner.run(
            [BLKID, "--probe", "--output", "export", TARGET_LV_PATH], allowed=(0, 2), log_name="blkid-before-mkfs"
        )
        existing = parse_blkid_export(probe.stdout) if probe.returncode == 0 else {}
        if mode == "create-new":
            if existing:
                raise CommissioningError("new LV unexpectedly contains a filesystem signature")
            self.runner.run(
                [MKFS_EXT4, "-L", TARGET_LV, TARGET_LV_PATH],
                log_name="mkfs-ext4",
                timeout=DESTRUCTIVE_COMMAND_TIMEOUT_SECONDS,
            )
            self.state("FILESYSTEM_CREATED")
        elif existing:
            if existing.get("TYPE") != "ext4" or existing.get("LABEL") != TARGET_LV:
                raise CommissioningError("retained LV filesystem identity is unsafe")
            self.state("RETAINED_FILESYSTEM_ADOPTED", filesystemUuid=existing.get("UUID"))
        else:
            # Formatting an unformatted retained LV is allowed only because the
            # immutable prior rollback proves this tool created that exact LV.
            self.runner.run(
                [MKFS_EXT4, "-L", TARGET_LV, TARGET_LV_PATH],
                log_name="mkfs-ext4",
                timeout=DESTRUCTIVE_COMMAND_TIMEOUT_SECONDS,
            )
            self.state("RETAINED_LV_FORMATTED")
        blkid = self.runner.run(
            [BLKID, "--probe", "--output", "export", TARGET_LV_PATH], log_name="blkid-new-lv"
        )
        filesystem = parse_blkid_export(blkid.stdout)
        if filesystem.get("TYPE") != "ext4" or filesystem.get("LABEL") != TARGET_LV:
            raise CommissioningError("new filesystem type or label is invalid")
        filesystem_uuid = filesystem.get("UUID", "")
        if not re.fullmatch(r"[0-9A-Fa-f-]{8,64}", filesystem_uuid):
            raise CommissioningError("new filesystem UUID is invalid")
        if filesystem_uuid.lower() == str(self.assessment["dataMount"].get("uuid", "")).lower():
            raise CommissioningError("new filesystem UUID duplicates old /data")
        uuid_matches = [
            line.strip()
            for line in self.runner.run(
                [BLKID, "--cache-file", "/dev/null", "--match-token", "UUID=" + filesystem_uuid, "--output", "device"],
                log_name="blkid-unique-new-uuid",
            ).stdout.splitlines()
            if line.strip()
        ]
        if len(uuid_matches) != 1 or not same_block_device(uuid_matches[0], TARGET_LV_PATH):
            raise CommissioningError("new filesystem UUID does not resolve uniquely to the target LV")
        return filesystem_uuid

    def storage_topology(self, filesystem_uuid: str) -> dict[str, Any]:
        lvs = parse_lvm_rows(
            json_command(
                self.runner,
                [
                    LVS,
                    "--reportformat",
                    "json",
                    "--units",
                    "b",
                    "--nosuffix",
                    "--options",
                    "vg_name,lv_name,lv_size,lv_attr,devices,lv_uuid,segtype",
                ],
            ),
            "lv",
        )
        vgs = parse_lvm_rows(
            json_command(
                self.runner,
                [
                    VGS,
                    "--reportformat",
                    "json",
                    "--units",
                    "b",
                    "--nosuffix",
                    "--options",
                    "vg_name,vg_size,vg_free,pv_count,lv_count,vg_attr,vg_uuid",
                ],
            ),
            "vg",
        )
        pvs = parse_lvm_rows(
            json_command(
                self.runner,
                [
                    PVS,
                    "--reportformat",
                    "json",
                    "--units",
                    "b",
                    "--nosuffix",
                    "--options",
                    "pv_name,pv_size,pv_free,vg_name,pv_uuid",
                ],
            ),
            "pv",
        )
        lv = [row for row in lvs if row.get("vg_name") == TARGET_VG and row.get("lv_name") == TARGET_LV]
        vg = [row for row in vgs if row.get("vg_name") == TARGET_VG]
        pv = [row for row in pvs if row.get("vg_name") == TARGET_VG and row.get("pv_name") == TARGET_PV]
        if len(lv) != 1 or len(vg) != 1 or len(pv) != 1:
            raise CommissioningError("storage topology is ambiguous")
        for value, label in (
            (lv[0].get("lv_uuid"), "LV UUID"),
            (vg[0].get("vg_uuid"), "VG UUID"),
            (pv[0].get("pv_uuid"), "PV UUID"),
        ):
            if not isinstance(value, str) or not LVM_UUID_RE.fullmatch(value):
                raise CommissioningError(f"{label} is malformed")
        if (
            integer_field(lv[0].get("lv_size"), "authority lv_size") != TARGET_LV_BYTES
            or lv[0].get("segtype") != "linear"
            or integer_field(vg[0].get("pv_count"), "authority pv_count") != 1
            or not re.fullmatch(rf"{re.escape(TARGET_PV)}\(\d+\)", str(lv[0].get("devices", "")))
        ):
            raise CommissioningError("LVM topology differs before authority publication")

        dm_real = os.path.realpath(TARGET_LV_PATH)
        dm_name = Path(dm_real).name
        if not re.fullmatch(r"dm-\d+", dm_name):
            raise CommissioningError("logical volume did not resolve to a dm device")
        dm_uuid = (Path("/sys/block") / dm_name / "dm/uuid").read_text(encoding="ascii").strip()
        if not re.fullmatch(r"LVM-[A-Za-z0-9]{64}", dm_uuid):
            raise CommissioningError("device-mapper UUID is malformed")

        namespace = Path(TARGET_NVME)
        partition = Path(TARGET_PV)
        namespace_props = parse_udev_properties(self.runner.run([UDEVADM, "info", "--query=property", "--name", str(namespace)]).stdout)
        partition_props = parse_udev_properties(self.runner.run([UDEVADM, "info", "--query=property", "--name", str(partition)]).stdout)
        namespace_by_id = canonical_nvme_by_id(namespace, namespace_props, partition_number=None)
        partition_number = integer_field(partition_props.get("ID_PART_ENTRY_NUMBER"), "NVMe partition number")
        partition_by_id = canonical_nvme_by_id(partition, partition_props, partition_number=partition_number)
        if not partition_by_id.startswith(namespace_by_id + "-part"):
            raise CommissioningError("NVMe namespace and partition by-id differ")
        serial = namespace_props.get("ID_SERIAL_SHORT") or namespace_props.get("ID_SERIAL")
        if not isinstance(serial, str) or not serial.strip():
            raise CommissioningError("NVMe serial identity is unavailable")
        rotational = (Path("/sys/block") / namespace.name / "queue/rotational").read_text(encoding="ascii").strip()
        if rotational != "0":
            raise CommissioningError("target NVMe unexpectedly reports rotational media")
        return {
            "dataUuid": filesystem_uuid.lower(),
            "lvm": {
                "dmUuid": dm_uuid,
                "lvSizeBytes": TARGET_LV_BYTES,
                "lvUuid": lv[0]["lv_uuid"],
                "pvCount": 1,
                "pvUuid": pv[0]["pv_uuid"],
                "segmentType": "linear",
                "vgUuid": vg[0]["vg_uuid"],
            },
            "nvme": {
                "namespaceById": namespace_by_id,
                "partitionById": partition_by_id,
                "partitionNumber": partition_number,
                "rotational": False,
                "serialSha256": sha256_bytes(serial.strip().encode("utf-8")),
                "transport": "nvme",
            },
        }

    def verify_temporary_mount(self, filesystem_uuid: str) -> None:
        mountpoint = Path(str(self.preimages["temporaryMountpoint"]))
        mountpoint.mkdir(mode=0o700)
        try:
            self.runner.run(
                [MOUNT, "--types", "ext4", "--options", "rw,nodev,nosuid,noexec", TARGET_LV_PATH, str(mountpoint)],
                log_name="temporary-mount",
            )
            observed = single_filesystem(
                json_command(self.runner, [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", str(mountpoint)])
            )
            if observed.get("target") != str(mountpoint) or not mounted_target_lv_is_exact(observed, filesystem_uuid):
                raise CommissioningError("temporary mount identity mismatch")
            candidate = self.plan.get("target", {}).get("adoptionCandidate")
            allowed_transactions = {self.transaction_id}
            if isinstance(candidate, dict):
                allowed_transactions.add(str(candidate.get("transactionId")))
            validate_retained_filesystem(mountpoint, filesystem_uuid, allowed_transactions)
            probe = mountpoint / ".uten-imp-fsync-probe"
            fd = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, b"uten-imp-nvme-commissioning\n")
                os.fsync(fd)
            finally:
                os.close(fd)
            probe.unlink()
            fsync_directory(mountpoint)
            self.runner.run([SYNC, "--file-system", str(mountpoint)], log_name="temporary-mount-sync")
        finally:
            current = self.runner.run(
                [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", "--mountpoint", str(mountpoint)],
                allowed=(0, 1),
            )
            if current.returncode == 0:
                self.runner.run([UMOUNT, str(mountpoint)], allowed=(0,), log_name="temporary-umount")
                absent = self.runner.run([FINDMNT, "--mountpoint", str(mountpoint)], allowed=(1,))
                if absent.returncode != 1:
                    raise CommissioningError("temporary mount remained after unmount")
            try:
                mountpoint.rmdir()
            except OSError:
                pass
        self.state("TEMPORARY_MOUNT_VERIFIED")

    def switch_fstab_and_mount(self, filesystem_uuid: str) -> None:
        original = FSTAB.read_bytes()
        if sha256_bytes(original) != self.assessment["fstab"]["sha256"]:
            raise CommissioningError("fstab changed after authorization")
        replacement = render_switched_fstab(original, filesystem_uuid, str(self.assessment["dataMount"]["uuid"]))
        candidate = self.evidence / "fstab.candidate"
        atomic_write(candidate, replacement, mode=0o600, replace=False)
        self.runner.run([FINDMNT, "--verify", "--verbose", "--tab-file", str(candidate)], log_name="findmnt-verify-candidate")
        self.runner.run([UMOUNT, TARGET_MOUNT], log_name="unmount-old-data")
        self.state("OLD_DATA_UNMOUNTED")
        st = FSTAB.lstat()
        write_system_file(FSTAB, replacement, stat.S_IMODE(st.st_mode))
        os.chown(FSTAB, st.st_uid, st.st_gid)
        self.state("FSTAB_SWITCHED", filesystemUuid=filesystem_uuid)
        self.runner.run([SYSTEMCTL, "daemon-reload"], log_name="fstab-daemon-reload")
        self.runner.run([MOUNT, TARGET_MOUNT], log_name="mount-new-data")
        observed = single_filesystem(
            json_command(self.runner, [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", TARGET_MOUNT])
        )
        if (
            observed.get("target") != TARGET_MOUNT
            or not mounted_target_lv_is_exact(observed, filesystem_uuid)
        ):
            raise CommissioningError("new /data mount identity mismatch")
        self.state("NEW_DATA_MOUNTED")

    def prepare_pgdata(self, filesystem_uuid: str) -> None:
        write_system_file(PG_GUARD, postgres_guard(filesystem_uuid), 0o644)
        self.runner.run([SYSTEMCTL, "daemon-reload"], log_name="postgres-guard-daemon-reload")
        postgres_identity = self.runner.run(["/usr/bin/getent", "passwd", "postgres"], log_name="postgres-identity")
        fields = postgres_identity.stdout.strip().split(":")
        if len(fields) < 4:
            raise CommissioningError("postgres account inventory is malformed")
        uid = integer_field(fields[2], "postgres uid")
        gid = integer_field(fields[3], "postgres gid")
        directories = (
            (Path("/data/postgresql"), 0o750, uid, gid),
            (Path("/data/postgresql/16"), 0o750, uid, gid),
            (Path("/data/postgresql/16/main"), 0o700, uid, gid),
            (Path("/data/backups"), 0o700, 0, 0),
            (Path("/data/backups/pgbackrest"), 0o750, uid, gid),
        )
        for path, mode, owner, group in directories:
            if path.exists() or path.is_symlink():
                st = path.lstat()
                if (
                    path.is_symlink()
                    or not stat.S_ISDIR(st.st_mode)
                    or st.st_uid != owner
                    or st.st_gid != group
                    or stat.S_IMODE(st.st_mode) != mode
                ):
                    raise CommissioningError(f"prepared data path metadata differs: {path}")
                if path == Path("/data/postgresql/16/main") and any(path.iterdir()):
                    raise CommissioningError("prepared PGDATA is not empty")
            else:
                path.mkdir(mode=mode)
                os.chown(path, owner, group)
                os.chmod(path, mode)
                fsync_directory(path.parent)
        marker = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": KIND + "-storage-authority",
            "transactionId": self.transaction_id,
            "filesystemUuid": filesystem_uuid,
            "lvPath": TARGET_LV_PATH,
            "mount": TARGET_MOUNT,
            "status": "PGDATA_PREPARED_NOT_INITIALIZED",
            "oldMdRetained": True,
            "postgresInitialized": False,
            "backupCommissioned": False,
            "recordedAtUtc": utc_now(),
        }
        marker_path = Path("/data/.uten-imp-storage-authority.json")
        if marker_path.exists() or marker_path.is_symlink():
            existing_marker = load_json_regular(marker_path)
            candidate = self.plan.get("target", {}).get("adoptionCandidate")
            expected_transaction = candidate.get("transactionId") if isinstance(candidate, dict) else self.transaction_id
            if (
                existing_marker.get("kind") != KIND + "-storage-authority"
                or existing_marker.get("transactionId") != expected_transaction
                or existing_marker.get("filesystemUuid", "").lower() != filesystem_uuid.lower()
                or existing_marker.get("status") != "PGDATA_PREPARED_NOT_INITIALIZED"
                or existing_marker.get("postgresInitialized") is not False
                or existing_marker.get("backupCommissioned") is not False
            ):
                raise CommissioningError("existing storage authority marker differs")
        else:
            write_system_file(marker_path, canonical_bytes(marker), 0o600)
        self.runner.run([SYNC, "--file-system", TARGET_MOUNT], log_name="new-data-sync")
        self.state("PGDATA_PREPARED", filesystemUuid=filesystem_uuid)

    def publish_runtime_authority(self, filesystem_uuid: str) -> tuple[str, str]:
        topology = self.storage_topology(filesystem_uuid)
        plan_path = self.evidence / "plan.json"
        plan_sha256 = sha256_file(plan_path)
        if plan_sha256 != sha256_bytes(canonical_bytes(self.plan)):
            raise CommissioningError("immutable plan evidence differs before authority publication")
        authority = runtime_authority_document(topology, self.approval_reference, plan_sha256)
        payload = canonical_bytes(authority)
        if STORAGE_AUTHORITY.exists() or STORAGE_AUTHORITY.is_symlink():
            if STORAGE_AUTHORITY.is_symlink() or not STORAGE_AUTHORITY.is_file() or STORAGE_AUTHORITY.read_bytes() != payload:
                raise CommissioningError("existing runtime storage authority differs")
        else:
            write_system_file(STORAGE_AUTHORITY, payload, 0o640)
        st = STORAGE_AUTHORITY.lstat()
        if (
            stat.S_ISLNK(st.st_mode)
            or not stat.S_ISREG(st.st_mode)
            or st.st_uid != 0
            or st.st_gid != 0
            or stat.S_IMODE(st.st_mode) != 0o640
            or st.st_nlink != 1
            or STORAGE_AUTHORITY.read_bytes() != payload
        ):
            raise CommissioningError("runtime storage authority metadata differs")
        authority_sha256 = sha256_bytes(payload)
        self.state("RUNTIME_AUTHORITY_PUBLISHED", authoritySha256=authority_sha256)
        return str(STORAGE_AUTHORITY), authority_sha256

    def commit(self, filesystem_uuid: str, authority_path: str, authority_sha256: str) -> None:
        receipt = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": KIND + "-receipt",
            "status": "COMMITTED_STORAGE_ONLY",
            "transactionId": self.transaction_id,
            "planSha256": self.plan["planSha256"],
            "filesystemUuid": filesystem_uuid,
            "lvPath": TARGET_LV_PATH,
            "oldMdRetainedAssembled": True,
            "oldMdMounted": False,
            "postgresInitialized": False,
            "postgresEnabled": False,
            "backupCommissioned": False,
            "entryEnabled": False,
            "protectedUnitsDisabledInactive": list(SUCCESS_DISABLE_UNITS),
            "osUpdateInfrastructureRestored": False,
            "oldBackupAutomationRestored": False,
            "oldPhase1ResumeRetired": True,
            "newBackupDirectoryEmpty": True,
            "newPostgresSystemIdentifier": None,
            "newPostgresSystemIdentifierMustDifferBeforeInitialization": True,
            "authorityPath": authority_path,
            "authoritySha256": authority_sha256,
            "evidenceRole": "plan",
            "commissioningEvidenceSha256": sha256_file(self.evidence / "plan.json"),
            "completedAtUtc": utc_now(),
        }
        atomic_json(self.evidence / "complete.json", receipt, replace=False)
        self.state("COMMITTED", filesystemUuid=filesystem_uuid)

    def finalize_committed(self) -> dict[str, Any]:
        complete = validate_committed_transaction(self.evidence, load_json_regular(ACTIVE_POINTER))
        self.runner.run(
            [SYSTEMCTL, "restart", "--no-block", LATE_RESUME_TIMER.name],
            allowed=(0,),
            log_name="queue-committed-late-finalization",
        )
        return {
            **complete,
            "lateFinalizationQueued": True,
            "activePointerRetained": True,
        }

    def disarm_resume(self, *, remove_unit: bool) -> None:
        if ACTIVE_POINTER.exists() or ACTIVE_POINTER.is_symlink():
            if ACTIVE_POINTER.is_symlink():
                raise CommissioningError("active pointer became a symlink")
            ACTIVE_POINTER.unlink()
            fsync_directory(ACTIVE_POINTER.parent)
        # Unit and wants-link remain as a permanent, conditioned no-op.

    def apply(self) -> dict[str, Any]:
        self.prepare()
        try:
            self.install_resume()
            self.disable_old_resume()
            self.stop_units()
            self.backup_vg_metadata()
            filesystem_uuid = self.create_filesystem()
            self.verify_temporary_mount(filesystem_uuid)
            self.switch_fstab_and_mount(filesystem_uuid)
            self.prepare_pgdata(filesystem_uuid)
            authority_path, authority_sha256 = self.publish_runtime_authority(filesystem_uuid)
            self.commit(filesystem_uuid, authority_path, authority_sha256)
            return self.finalize_committed()
        except BaseException as exc:
            complete_path = self.evidence / "complete.json"
            if complete_path.exists() or complete_path.is_symlink():
                # complete.json is the durable point of no return.  Never
                # restore old md after it exists; leave the resume link/pointer
                # armed so manual or early-boot recover can retry finalization.
                raise CommissioningError(
                    f"storage committed but finalization remains pending; evidence={self.evidence}"
                ) from exc
            try:
                rollback(self.evidence, self.runner, reason=type(exc).__name__ + ": " + str(exc))
            except BaseException as rollback_exc:
                atomic_json(
                    self.evidence / "rollback-failed.json",
                    {
                        "status": "ROLLBACK_FAILED_ENTRY_MUST_REMAIN_CLOSED",
                        "originalFailure": type(exc).__name__ + ": " + str(exc),
                        "rollbackFailure": type(rollback_exc).__name__ + ": " + str(rollback_exc),
                        "recordedAtUtc": utc_now(),
                    },
                    replace=False,
                )
                raise CommissioningError(
                    f"commissioning failed and rollback failed; evidence={self.evidence}"
                ) from rollback_exc
            if isinstance(exc, KeyboardInterrupt):
                raise
            raise CommissioningError(
                f"commissioning failed closed; old storage restored and late verified recovery queued; evidence={self.evidence}"
            ) from exc


def load_json_regular(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise CommissioningError(f"unsafe or absent JSON file: {path}")

    def object_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate JSON object key")
            value[key] = item
        return value

    def reject_nonfinite(value: str) -> Any:
        raise ValueError(f"non-finite JSON number: {value}")

    try:
        payload = path.read_bytes()
        if len(payload) > 16 * 1024 * 1024:
            raise ValueError("JSON file exceeds fixed size limit")
        value = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=object_without_duplicates,
            parse_constant=reject_nonfinite,
        )
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
        raise CommissioningError(f"invalid JSON file: {path}") from exc
    if not isinstance(value, dict):
        raise CommissioningError(f"JSON object required: {path}")
    return value


def validate_rollback_evidence(evidence: Path, pointer: Mapping[str, Any] | None = None) -> dict[str, Any]:
    if evidence.parent != EVIDENCE_ROOT or not re.fullmatch(r"nvme-\d{8}T\d{6}Z-[0-9a-f]{12}", evidence.name):
        raise CommissioningError("rollback evidence is not a direct fixed-root transaction")
    info = evidence.lstat()
    if not root_directory_metadata_is_exact(info, 0o700):
        raise CommissioningError("rollback evidence directory metadata differs")
    plan_path = evidence / "plan.json"
    preimages_path = evidence / "preimages.json"
    for required in (plan_path, preimages_path):
        required_info = required.lstat()
        if not root_file_metadata_is_exact(required_info, 0o600):
            raise CommissioningError("rollback manifest metadata differs")
    plan = load_json_regular(plan_path)
    if plan.get("planSha256") != sha256_bytes(canonical_bytes({k: v for k, v in plan.items() if k != "planSha256"})):
        raise CommissioningError("rollback plan checksum differs")
    preimages = load_json_regular(preimages_path)
    expected_paths = {
        "fstab": FSTAB,
        "pgGuard": PG_GUARD,
        "pgStartConf": PG_START_CONF,
        "resumeUnit": RESUME_UNIT,
        "storageAuthority": STORAGE_AUTHORITY,
    }
    expected_copy_names = {
        "fstab": "fstab",
        "pgGuard": "postgresql-uten-imp-data.conf",
        "pgStartConf": "postgresql-start.conf",
        "resumeUnit": "nvme-resume.service",
        "storageAuthority": "storage-authority.json",
    }
    for key, expected_path in expected_paths.items():
        record = preimages.get(key)
        if not isinstance(record, dict) or record.get("path") != str(expected_path) or record.get("exists") not in {True, False}:
            raise CommissioningError(f"rollback preimage path differs: {key}")
        if record.get("exists") is True:
            copy = Path(str(record.get("copy", "")))
            expected_copy = evidence / "preimages" / expected_copy_names[key]
            if copy != expected_copy:
                raise CommissioningError(f"rollback preimage copy escapes transaction: {key}")
            copy_info = copy.lstat()
            if not root_file_metadata_is_exact(copy_info, 0o600) or sha256_file(copy) != record.get("sha256"):
                raise CommissioningError(f"rollback preimage copy metadata differs: {key}")
    if preimages.get("targetLvPath") != TARGET_LV_PATH or not isinstance(preimages.get("serviceMap"), dict):
        raise CommissioningError("rollback fixed preimage fields differ")
    if pointer is not None:
        if (
            set(pointer) != {
                "schemaVersion",
                "transactionId",
                "evidence",
                "planSha256",
                "preimagesSha256",
                "helperSha256",
            }
            or pointer.get("schemaVersion") != SCHEMA_VERSION
            or pointer.get("transactionId") != evidence.name
            or pointer.get("evidence") != str(evidence)
            or pointer.get("planSha256") != plan.get("planSha256")
            or pointer.get("preimagesSha256") != sha256_file(preimages_path)
            or not re.fullmatch(r"[0-9a-f]{64}", str(pointer.get("helperSha256", "")))
        ):
            raise CommissioningError("active rollback pointer binding differs")
    return preimages


def validate_committed_transaction(evidence: Path, pointer: Mapping[str, Any]) -> dict[str, Any]:
    if evidence.parent != EVIDENCE_ROOT or not re.fullmatch(r"nvme-[0-9TZ-]+-[0-9a-f]{12}", evidence.name):
        raise CommissioningError("committed evidence is not a direct fixed-root transaction")
    info = evidence.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or info.st_uid != 0
        or info.st_gid != 0
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise CommissioningError("committed evidence directory metadata differs")
    validate_rollback_evidence(evidence, pointer)
    plan_path = evidence / "plan.json"
    complete_path = evidence / "complete.json"
    if not root_file_metadata_is_exact(complete_path.lstat(), 0o600):
        raise CommissioningError("committed receipt metadata differs")
    plan = load_json_regular(plan_path)
    complete = load_json_regular(complete_path)
    expected_pointer_keys = {
        "schemaVersion",
        "transactionId",
        "evidence",
        "planSha256",
        "preimagesSha256",
        "helperSha256",
    }
    expected_complete_keys = {
        "schemaVersion",
        "kind",
        "status",
        "transactionId",
        "planSha256",
        "filesystemUuid",
        "lvPath",
        "oldMdRetainedAssembled",
        "oldMdMounted",
        "postgresInitialized",
        "postgresEnabled",
        "backupCommissioned",
        "entryEnabled",
        "protectedUnitsDisabledInactive",
        "osUpdateInfrastructureRestored",
        "oldBackupAutomationRestored",
        "oldPhase1ResumeRetired",
        "newBackupDirectoryEmpty",
        "newPostgresSystemIdentifier",
        "newPostgresSystemIdentifierMustDifferBeforeInitialization",
        "authorityPath",
        "authoritySha256",
        "evidenceRole",
        "commissioningEvidenceSha256",
        "completedAtUtc",
    }
    if (
        set(pointer) != expected_pointer_keys
        or set(complete) != expected_complete_keys
        or complete.get("schemaVersion") != SCHEMA_VERSION
        or pointer.get("schemaVersion") != SCHEMA_VERSION
        or pointer.get("transactionId") != evidence.name
        or pointer.get("evidence") != str(evidence)
        or pointer.get("planSha256") != plan.get("planSha256")
        or pointer.get("preimagesSha256") != sha256_file(evidence / "preimages.json")
        or not re.fullmatch(r"[0-9a-f]{64}", str(pointer.get("helperSha256", "")))
        or complete.get("kind") != KIND + "-receipt"
        or complete.get("status") != "COMMITTED_STORAGE_ONLY"
        or complete.get("transactionId") != evidence.name
        or complete.get("planSha256") != plan.get("planSha256")
        or complete.get("authorityPath") != str(STORAGE_AUTHORITY)
        or complete.get("evidenceRole") != "plan"
        or complete.get("commissioningEvidenceSha256") != sha256_file(evidence / "plan.json")
        or complete.get("lvPath") != TARGET_LV_PATH
        or complete.get("oldMdRetainedAssembled") is not True
        or complete.get("oldMdMounted") is not False
        or complete.get("postgresInitialized") is not False
        or complete.get("postgresEnabled") is not False
        or complete.get("backupCommissioned") is not False
        or complete.get("entryEnabled") is not False
        or complete.get("protectedUnitsDisabledInactive") != list(SUCCESS_DISABLE_UNITS)
        or complete.get("osUpdateInfrastructureRestored") is not False
        or complete.get("oldBackupAutomationRestored") is not False
        or complete.get("oldPhase1ResumeRetired") is not True
        or complete.get("newBackupDirectoryEmpty") is not True
        or complete.get("newPostgresSystemIdentifier") is not None
        or complete.get("newPostgresSystemIdentifierMustDifferBeforeInitialization") is not True
    ):
        raise CommissioningError("committed receipt binding differs")
    authority = load_json_regular(STORAGE_AUTHORITY)
    authority_payload = STORAGE_AUTHORITY.read_bytes()
    authority_info = STORAGE_AUTHORITY.lstat()
    filesystem_uuid = str(complete.get("filesystemUuid", "")).lower()
    expected_authority = runtime_authority_document(
        {
            "dataUuid": filesystem_uuid,
            "lvm": authority.get("lvm"),
            "nvme": authority.get("nvme"),
        },
        str(authority.get("approvalReference", "")),
        str(complete.get("commissioningEvidenceSha256", "")),
    )
    if (
        authority != expected_authority
        or not isinstance(authority.get("lvm"), dict)
        or set(authority["lvm"]) != {
            "dmUuid",
            "lvSizeBytes",
            "lvUuid",
            "pvCount",
            "pvUuid",
            "segmentType",
            "vgUuid",
        }
        or not isinstance(authority.get("nvme"), dict)
        or set(authority["nvme"]) != {
            "namespaceById",
            "partitionById",
            "partitionNumber",
            "rotational",
            "serialSha256",
            "transport",
        }
        or sha256_bytes(authority_payload) != complete.get("authoritySha256")
        or authority.get("dataUuid") != filesystem_uuid
        or authority.get("commissioningEvidenceSha256") != complete.get("commissioningEvidenceSha256")
        or not stat.S_ISREG(authority_info.st_mode)
        or stat.S_ISLNK(authority_info.st_mode)
        or authority_info.st_uid != 0
        or authority_info.st_gid != 0
        or stat.S_IMODE(authority_info.st_mode) != 0o640
        or authority_info.st_nlink != 1
    ):
        raise CommissioningError("runtime storage authority binding differs")
    fstab_entries = parse_fstab_data_entries(FSTAB.read_bytes())
    if len(fstab_entries) != 1 or fstab_entries[0]["fields"][:4] != [
        "UUID=" + filesystem_uuid,
        TARGET_MOUNT,
        "ext4",
        "rw,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=30s",
    ]:
        raise CommissioningError("committed fstab binding differs")
    resume = resume_installation_observation()
    if (
        resume.get("state") != "complete-valid-permanent-gate"
        or Path(str(resume.get("helper", ""))).name
        != f"uten-imp-nvme-commissioner-{pointer.get('helperSha256')}.py"
    ):
        raise CommissioningError("committed resume helper binding differs")
    return complete


def verify_committed_live_storage(
    evidence: Path,
    pointer: Mapping[str, Any],
    complete: Mapping[str, Any],
    runner: Runner,
) -> dict[str, Any]:
    """Prove the committed storage-only boundary after local-fs is live."""

    filesystem_uuid = str(complete.get("filesystemUuid", "")).lower()
    authority = load_json_regular(STORAGE_AUTHORITY)
    observed = single_filesystem(
        json_command(
            runner,
            [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", TARGET_MOUNT],
        )
    )
    if observed.get("target") != TARGET_MOUNT or not mounted_target_lv_is_exact(observed, filesystem_uuid):
        raise CommissioningError("committed live /data mount identity differs")
    options = {item for item in str(observed.get("options", "")).split(",") if item}
    if not {"rw", "nodev", "nosuid", "noexec"}.issubset(options):
        raise CommissioningError("committed live /data mount options differ")

    topology = Transaction.__new__(Transaction)
    topology.runner = runner
    actual = Transaction.storage_topology(topology, filesystem_uuid)
    if actual.get("lvm") != authority.get("lvm") or actual.get("nvme") != authority.get("nvme"):
        raise CommissioningError("committed live LVM/NVMe topology differs from authority")

    plan = load_json_regular(evidence / "plan.json")
    candidate = plan.get("target", {}).get("adoptionCandidate") if isinstance(plan.get("target"), dict) else None
    allowed_transactions = {evidence.name}
    if isinstance(candidate, dict) and isinstance(candidate.get("transactionId"), str):
        allowed_transactions.add(candidate["transactionId"])
    validate_retained_filesystem(Path(TARGET_MOUNT), filesystem_uuid, allowed_transactions)
    marker_path = Path(TARGET_MOUNT) / ".uten-imp-storage-authority.json"
    if marker_path.is_symlink() or not marker_path.is_file():
        raise CommissioningError("committed storage-only marker is absent")
    marker = load_json_regular(marker_path)
    if (
        marker.get("postgresInitialized") is not False
        or marker.get("backupCommissioned") is not False
        or marker.get("status") != "PGDATA_PREPARED_NOT_INITIALIZED"
    ):
        raise CommissioningError("committed storage-only marker differs")
    pgdata = Path(TARGET_MOUNT) / "postgresql/16/main"
    backup_repo = Path(TARGET_MOUNT) / "backups/pgbackrest"
    if not pgdata.is_dir() or any(pgdata.iterdir()) or not backup_repo.is_dir() or any(backup_repo.iterdir()):
        raise CommissioningError("committed PGDATA or backup preparation boundary is not empty")
    if postgres_start_mode(PG_START_CONF.read_text(encoding="utf-8")) != "manual":
        raise CommissioningError("PostgreSQL start mode is not manual after storage-only commit")
    if PG_GUARD.read_bytes() != postgres_guard(filesystem_uuid):
        raise CommissioningError("temporary PostgreSQL storage guard differs after commit")

    protected: dict[str, dict[str, str]] = {}
    for unit in SUCCESS_DISABLE_UNITS:
        current = unit_state(runner, unit)
        protected[unit] = current
        if current.get("ActiveState") not in {"inactive", "failed"}:
            raise CommissioningError(f"storage-only protected unit is active: {unit}")
        if current.get("LoadState") != "not-found" and current.get("UnitFileState") not in {
            "disabled",
            "static",
            "indirect",
            "generated",
            "transient",
        }:
            raise CommissioningError(f"storage-only protected unit is enabled: {unit}")
    return {
        "mount": observed,
        "topology": actual,
        "storageMarkerSha256": sha256_file(marker_path),
        "pgdataEmpty": True,
        "backupDirectoryEmpty": True,
        "protectedUnits": protected,
    }


def validate_committed_late_receipt(
    evidence: Path,
    complete: Mapping[str, Any],
    service_map: Mapping[str, Any],
) -> dict[str, Any] | None:
    """Validate an immutable live-finalization receipt left before disarm."""

    path = evidence / "late-committed-finalization.json"
    if not path.exists() and not path.is_symlink():
        return None
    if path.is_symlink() or not root_file_metadata_is_exact(path.lstat(), 0o600):
        raise CommissioningError("committed late-finalization receipt metadata differs")
    receipt = load_json_regular(path)
    expected_keys = set(complete) | {
        "lateFinalizationAttempt",
        "liveVerification",
        "updateInfrastructure",
        "lateFinalizedAtUtc",
    }
    immutable_keys = set(complete) - {"status", "osUpdateInfrastructureRestored"}
    if (
        set(receipt) != expected_keys
        or any(receipt.get(key) != complete.get(key) for key in immutable_keys)
        or receipt.get("status") != "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED"
        or receipt.get("osUpdateInfrastructureRestored") is not True
        or isinstance(receipt.get("lateFinalizationAttempt"), bool)
        or not isinstance(receipt.get("lateFinalizationAttempt"), int)
        or not 1 <= int(receipt["lateFinalizationAttempt"]) <= LATE_RECOVERY_ATTEMPTS
        or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", str(receipt.get("lateFinalizedAtUtc", "")))
    ):
        raise CommissioningError("committed late-finalization receipt binding differs")
    live = receipt.get("liveVerification")
    if (
        not isinstance(live, dict)
        or set(live)
        != {
            "mount",
            "topology",
            "storageMarkerSha256",
            "pgdataEmpty",
            "backupDirectoryEmpty",
            "protectedUnits",
        }
        or live.get("pgdataEmpty") is not True
        or live.get("backupDirectoryEmpty") is not True
        or not re.fullmatch(r"[0-9a-f]{64}", str(live.get("storageMarkerSha256", "")))
        or not isinstance(live.get("mount"), dict)
        or not isinstance(live.get("topology"), dict)
        or not isinstance(live.get("protectedUnits"), dict)
        or set(live["protectedUnits"]) != set(SUCCESS_DISABLE_UNITS)
    ):
        raise CommissioningError("committed late-finalization live evidence differs")
    expected_update_units = {
        unit
        for unit in ("unattended-upgrades.service",) + APT_TIMERS
        if isinstance(service_map.get(unit), dict)
        and service_map[unit].get("ActiveState") in {"active", "activating"}
    }
    update = receipt.get("updateInfrastructure")
    if (
        not isinstance(update, dict)
        or set(update) != expected_update_units
        or not all(isinstance(value, dict) for value in update.values())
    ):
        raise CommissioningError("committed late-finalization update evidence differs")
    return receipt


def committed_late_finalize(
    evidence: Path,
    pointer: Mapping[str, Any],
    runner: Runner,
) -> dict[str, Any]:
    complete = validate_committed_transaction(evidence, pointer)
    preimages = validate_rollback_evidence(evidence, pointer)
    service_map = preimages.get("serviceMap", {})
    receipt = validate_committed_late_receipt(evidence, complete, service_map)
    runner.recovery_attempt(evidence)
    if receipt is not None:
        # A power loss/SIGKILL after the immutable live receipt but before the
        # durable pointer unlink must not consume the bounded retry budget or
        # repeat systemctl start. StopPost preserves the already-proven OS
        # update baseline when (and only when) this exact receipt is valid.
        ensure_gate_authorizer_closed(runner)
        verify_committed_live_storage(evidence, pointer, complete, runner)
        verify_update_infrastructure_map(runner, service_map)
        finalize_gate_with_retry(runner, evidence, pointer, outcome="COMMITTED")
        return receipt

    attempt, attempt_state = begin_late_recovery_attempt(evidence, pointer)
    verified_receipt_published = False
    try:
        ensure_gate_authorizer_closed(runner)
        live = verify_committed_live_storage(evidence, pointer, complete, runner)
        update_failures = restore_update_infrastructure_map(
            runner,
            service_map,
            evidence=evidence,
            pointer=pointer,
        )
        if update_failures:
            raise CommissioningError("restore update infrastructure: " + "; ".join(update_failures))
        update_health = verify_update_infrastructure_map(runner, service_map)
        candidate = {
            **dict(complete),
            "status": "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED",
            "lateFinalizationAttempt": attempt,
            "liveVerification": live,
            "osUpdateInfrastructureRestored": True,
            "updateInfrastructure": update_health,
            "lateFinalizedAtUtc": utc_now(),
        }
        atomic_json(evidence / "late-committed-finalization.json", candidate, replace=False)
        verified_receipt_published = True
        receipt = candidate
        finish_late_recovery_attempt(evidence, attempt_state, status="SUCCEEDED", failure=None)
    except BaseException as exc:
        containment = contain_late_recovery_failure(
            runner,
            preserve_verified_update_infrastructure=verified_receipt_published,
        )
        failure = type(exc).__name__ + ": " + str(exc)
        if containment:
            failure += "; containment: " + "; ".join(containment)
        try:
            finish_late_recovery_attempt(evidence, attempt_state, status="FAILED", failure=failure)
        except BaseException as state_exc:
            failure += "; record attempt: " + str(state_exc)
        raise CommissioningError(
            f"committed late finalization attempt {attempt}/{LATE_RECOVERY_ATTEMPTS} failed closed: {failure}"
        ) from exc

    finalize_gate_with_retry(runner, evidence, pointer, outcome="COMMITTED")
    return receipt


def restore_enablement_map(runner: Runner, service_map: Mapping[str, Any]) -> list[str]:
    failures: list[str] = []
    for unit in SUCCESS_DISABLE_UNITS:
        state = service_map.get(unit, {})
        desired = state.get("UnitFileState") if isinstance(state, dict) else None
        try:
            if desired == "enabled":
                runner.run([SYSTEMCTL, "enable", unit], allowed=(0,), log_name="rollback-enable-" + unit)
            elif desired == "enabled-runtime":
                runner.run([SYSTEMCTL, "enable", "--runtime", unit], allowed=(0,), log_name="rollback-enable-" + unit)
            elif desired in {"disabled", "static", "indirect", "not-found", None, ""}:
                if desired not in {"not-found", None, ""}:
                    runner.run([SYSTEMCTL, "disable", unit], allowed=(0,), log_name="rollback-disable-" + unit)
            else:
                failures.append(f"unknown enablement {unit}={desired}")
        except CommissioningError as exc:
            failures.append(str(exc))
            continue
        current_state = unit_state(runner, unit)
        if desired == "not-found":
            if current_state.get("LoadState") != "not-found":
                failures.append(f"unit absence was not restored: {unit}")
        elif desired in {"enabled", "enabled-runtime", "disabled", "static", "indirect"}:
            if current_state.get("UnitFileState") != desired:
                failures.append(
                    f"unit enablement was not restored exactly: {unit} "
                    f"expected={desired} actual={current_state.get('UnitFileState')}"
                )
    return failures


def contain_runtime_closed(runner: Runner) -> list[str]:
    failures: list[str] = []
    # ExecStopPost has a finite stop timeout. Queue all stops in one bounded
    # command so one slow service cannot prevent the rest from receiving their
    # stop job; exact per-unit state is verified below.
    try:
        runner.run(
            [SYSTEMCTL, "stop", "--no-block", *STOP_ORDER],
            allowed=(0, 1, 5),
            log_name="contain-stop-protected-units",
            timeout=30,
        )
    except CommissioningError as exc:
        failures.append(str(exc))
    deadline = time.monotonic() + 60
    while True:
        still_active: list[str] = []
        for unit in STOP_ORDER:
            try:
                if unit_state(runner, unit, timeout=10).get("ActiveState") not in {"inactive", "failed"}:
                    still_active.append(unit)
            except CommissioningError as exc:
                failures.append(str(exc))
        if not still_active or time.monotonic() >= deadline:
            break
        time.sleep(2)
    try:
        runner.run(
            [SYSTEMCTL, "disable", *SUCCESS_DISABLE_UNITS],
            allowed=(0, 1, 5),
            log_name="contain-disable-protected-units",
            timeout=30,
        )
    except CommissioningError as exc:
        failures.append(str(exc))
    for unit in STOP_ORDER:
        try:
            current = unit_state(runner, unit, timeout=10)
            if current.get("ActiveState") not in {"inactive", "failed"}:
                failures.append(f"containment unit remains active: {unit}")
            if current.get("LoadState") != "not-found" and current.get("UnitFileState") not in {
                "disabled",
                "static",
                "indirect",
                "generated",
                "transient",
            }:
                failures.append(f"containment unit remains enabled: {unit}")
        except CommissioningError as exc:
            failures.append(str(exc))
    return failures


def restore_update_infrastructure_map(
    runner: Runner,
    service_map: Mapping[str, Any],
    *,
    evidence: Path,
    pointer: Mapping[str, Any],
) -> list[str]:
    failures: list[str] = []
    for unit in ("unattended-upgrades.service",) + APT_TIMERS:
        before = service_map.get(unit, {})
        if not isinstance(before, dict):
            failures.append(f"update infrastructure pre-state missing: {unit}")
            continue
        if before.get("ActiveState") in {"active", "activating"}:
            try:
                start_unit_with_one_time_gate(
                    runner,
                    evidence,
                    pointer,
                    unit,
                    log_name="restore-update-" + unit,
                )
            except CommissioningError as exc:
                failures.append(str(exc))
                continue
        current = unit_state(runner, unit)
        if before.get("ActiveState") in {"active", "activating"} and current.get("ActiveState") not in {
            "active",
            "activating",
        }:
            failures.append(f"update infrastructure activity was not restored: {unit}")
        if current.get("UnitFileState") != before.get("UnitFileState"):
            failures.append(f"update infrastructure enablement changed: {unit}")
    return failures


def verify_update_infrastructure_map(
    runner: Runner,
    service_map: Mapping[str, Any],
) -> dict[str, dict[str, str]]:
    """Re-prove the exact OS-update baseline without starting anything."""

    health: dict[str, dict[str, str]] = {}
    for unit in ("unattended-upgrades.service",) + APT_TIMERS:
        before = service_map.get(unit)
        if not isinstance(before, dict):
            raise CommissioningError(f"update infrastructure pre-state missing: {unit}")
        current = unit_state(runner, unit)
        if current.get("UnitFileState") != before.get("UnitFileState"):
            raise CommissioningError(f"update infrastructure enablement changed: {unit}")
        if before.get("ActiveState") in {"active", "activating"}:
            if current.get("ActiveState") not in {"active", "activating"}:
                raise CommissioningError(f"update infrastructure is no longer active: {unit}")
            health[unit] = wait_for_unit_health(runner, unit, timeout_seconds=30)
        elif current.get("ActiveState") != before.get("ActiveState"):
            raise CommissioningError(f"update infrastructure activity changed: {unit}")
    for unit in APT_JOB_SERVICES:
        if unit_state(runner, unit).get("ActiveState") not in {"inactive", "failed"}:
            raise CommissioningError(f"package job became active during committed finalization: {unit}")
    processes = package_process_observation()
    unattended_before = service_map.get("unattended-upgrades.service", {})
    if unattended_before.get("ActiveState") in {"active", "activating"}:
        if not passive_unattended_is_exact(processes):
            raise CommissioningError("passive unattended-upgrade helper identity differs")
    elif processes:
        raise CommissioningError("unexpected apt/dpkg process exists during committed finalization")
    if package_lock_observation(runner):
        raise CommissioningError("package-manager lock is held during committed finalization")
    if runner.run([DPKG, "--audit"], allowed=(0,), log_name="late-existing-receipt-dpkg-audit").stdout.strip():
        raise CommissioningError("dpkg audit is not clean during committed finalization")
    return health


def stop_update_infrastructure(runner: Runner) -> list[str]:
    failures: list[str] = []
    units = ("unattended-upgrades.service",) + APT_TIMERS
    try:
        runner.run(
            [SYSTEMCTL, "stop", "--no-block", *units],
            allowed=(0, 1, 5),
            log_name="contain-stop-update-infrastructure",
            timeout=30,
        )
    except CommissioningError as exc:
        failures.append(str(exc))
    deadline = time.monotonic() + 30
    while True:
        active: list[str] = []
        for unit in units:
            try:
                if unit_state(runner, unit, timeout=10).get("ActiveState") not in {"inactive", "failed"}:
                    active.append(unit)
            except CommissioningError as exc:
                failures.append(str(exc))
        if not active or time.monotonic() >= deadline:
            break
        time.sleep(2)
    if active:
        failures.append("update infrastructure remains active: " + ",".join(active))
    return failures


def cleanup_transaction_mounts(runner: Runner, preimages: Mapping[str, Any]) -> list[str]:
    failures: list[str] = []
    temporary = str(preimages.get("temporaryMountpoint", ""))
    if not re.fullmatch(r"/run/uten-imp-nvme-verify-nvme-[A-Za-z0-9-]+", temporary):
        return ["temporary mountpoint preimage is malformed"]
    try:
        current = runner.run(
            [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", "--mountpoint", temporary],
            allowed=(0, 1),
        )
        if current.returncode == 0:
            observed = single_filesystem(json.loads(current.stdout))
            if observed.get("target") != temporary or not same_block_device(
                normalized_mount_source(observed.get("source")), TARGET_LV_PATH
            ):
                failures.append("temporary mount source differs; it was not unmounted")
            else:
                runner.run([UMOUNT, temporary], allowed=(0,), log_name="rollback-unmount-temporary")
        if runner.run([FINDMNT, "--mountpoint", temporary], allowed=(1,)).returncode != 1:
            failures.append("temporary verification mount remains")
    except BaseException as exc:
        failures.append("cleanup temporary mount: " + str(exc))
    return failures


def verify_target_lv_unmounted(runner: Runner) -> list[str]:
    try:
        target_mounts = runner.run(
            [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", "--source", TARGET_LV_PATH],
            allowed=(0, 1),
        )
        if target_mounts.returncode == 1:
            return []
        document = json.loads(target_mounts.stdout)
        rows = document.get("filesystems") if isinstance(document, dict) else None
        if not isinstance(rows, list) or rows:
            return ["target LV remains mounted after rollback cleanup"]
    except BaseException as exc:
        return ["verify target LV unmounted: " + str(exc)]
    return []


def wait_for_old_md(runner: Runner, preimages: Mapping[str, Any], *, timeout_seconds: int = 60) -> None:
    old_mount = preimages.get("oldDataMount")
    old_md = preimages.get("oldMd")
    if not isinstance(old_mount, dict) or not isinstance(old_md, dict):
        raise CommissioningError("old storage identity preimage is missing")
    expected_uuid = str(old_mount.get("uuid", "")).lower()
    expected_md_uuid = str(old_md.get("MD_UUID", ""))
    if not re.fullmatch(r"[0-9a-f-]{8,64}", expected_uuid) or not expected_md_uuid:
        raise CommissioningError("old storage identity preimage is invalid")
    deadline = time.monotonic() + timeout_seconds
    attempt = 0
    while True:
        attempt += 1
        block = runner.run(
            [BLKID, "--probe", "--output", "export", OLD_MD_DEVICE],
            allowed=(0, 2),
            log_name=f"old-md-blkid-{attempt}",
        )
        detail = runner.run(
            [MDADM, "--detail", "--export", OLD_MD_DEVICE],
            allowed=(0, 1, 2),
            log_name=f"old-md-detail-{attempt}",
        )
        block_values = parse_blkid_export(block.stdout) if block.returncode == 0 else {}
        md_values = parse_blkid_export(detail.stdout) if detail.returncode == 0 else {}
        mdstat = Path("/proc/mdstat").read_text(encoding="utf-8")
        try:
            sync_action = Path("/sys/block/md0/md/sync_action").read_text(encoding="ascii").strip()
        except OSError:
            sync_action = "unavailable"
        if (
            block_values.get("TYPE") == "ext4"
            and str(block_values.get("UUID", "")).lower() == expected_uuid
            and md_values.get("MD_UUID") == expected_md_uuid
            and md_values.get("MD_LEVEL") == "raid1"
            and md_values.get("MD_DEVICES") == "2"
            and md_values.get("MD_STATE") in {"clean", "active,clean"}
            and md_stanza_is_clean(md0_stanza(mdstat))
            and sync_action == "idle"
            and same_block_device(OLD_MD_DEVICE, normalized_mount_source(old_mount.get("source")))
        ):
            return
        if time.monotonic() >= deadline:
            raise CommissioningError("old md identity did not become ready before recovery timeout")
        time.sleep(2)


def file_matches_preimage(record: Mapping[str, Any]) -> bool:
    path = Path(str(record.get("path", "")))
    if record.get("exists") is False:
        return not path.exists() and not path.is_symlink()
    if record.get("exists") is not True or not path.exists() or path.is_symlink():
        return False
    info = path.lstat()
    return (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == record.get("uid")
        and info.st_gid == record.get("gid")
        and stat.S_IMODE(info.st_mode) == record.get("mode")
        and info.st_nlink == 1
        and sha256_file(path) == record.get("sha256")
    )


def verify_restored_old_storage(
    runner: Runner, preimages: Mapping[str, Any], *, wait_for_array: bool = True
) -> dict[str, Any]:
    if wait_for_array:
        wait_for_old_md(runner, preimages)
    for key in ("fstab", "pgGuard", "pgStartConf", "storageAuthority"):
        record = preimages.get(key)
        if not isinstance(record, dict) or not file_matches_preimage(record):
            raise CommissioningError(f"restored system file differs before late recovery: {key}")
    observed = single_filesystem(
        json_command(runner, [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", TARGET_MOUNT])
    )
    expected = preimages.get("oldDataMount")
    if not isinstance(expected, dict):
        raise CommissioningError("old /data preimage is missing before late recovery")
    options = {value for value in str(observed.get("options", "")).split(",") if value}
    if not (
        observed.get("target") == TARGET_MOUNT
        and normalized_mount_source(observed.get("source")) == OLD_MD_DEVICE
        and same_block_device(normalized_mount_source(observed.get("source")), OLD_MD_DEVICE)
        and observed.get("fstype") == "ext4"
        and str(observed.get("uuid", "")).lower() == str(expected.get("uuid", "")).lower()
        and "rw" in options
    ):
        raise CommissioningError("restored old /data identity differs before late recovery")
    target_failures = verify_target_lv_unmounted(runner)
    if target_failures:
        raise CommissioningError("; ".join(target_failures))
    return observed


def wait_for_unit_health(runner: Runner, unit: str, *, timeout_seconds: int = 60) -> dict[str, str]:
    deadline = time.monotonic() + timeout_seconds
    last: dict[str, str] = {}
    while True:
        last = unit_state(runner, unit)
        result = last.get("Result", "success")
        main_status = last.get("ExecMainStatus", "0")
        if (
            last.get("ActiveState") == "active"
            and result in {"", "success"}
            and main_status in {"", "0"}
        ):
            return last
        if last.get("ActiveState") == "failed" or result not in {"", "success"} or main_status not in {"", "0"}:
            raise CommissioningError(f"restored unit health failed: {unit}")
        if time.monotonic() >= deadline:
            raise CommissioningError(f"restored unit did not become active before timeout: {unit}")
        time.sleep(2)


def wait_for_postgres_health(runner: Runner, *, timeout_seconds: int = 60) -> None:
    deadline = time.monotonic() + timeout_seconds
    attempt = 0
    while True:
        attempt += 1
        result = runner.run(
            [
                RUNUSER,
                "-u",
                "postgres",
                "--",
                PSQL,
                "--no-psqlrc",
                "--set",
                "ON_ERROR_STOP=1",
                "--dbname",
                "postgres",
                "--tuples-only",
                "--no-align",
                "--command",
                "SELECT 1;",
            ],
            allowed=range(0, 256),
            log_name=f"late-postgres-health-{attempt}",
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip() == "1":
            return
        if time.monotonic() >= deadline:
            raise CommissioningError("restored PostgreSQL did not pass bounded SQL health verification")
        time.sleep(2)


def wait_for_application_readiness(runner: Runner, *, timeout_seconds: int = 90) -> None:
    deadline = time.monotonic() + timeout_seconds
    attempt = 0
    while True:
        attempt += 1
        result = runner.run(
            [
                CURL,
                "--fail",
                "--silent",
                "--show-error",
                "--max-time",
                "3",
                "http://127.0.0.1:8080/actuator/health/readiness",
            ],
            allowed=range(0, 256),
            log_name=f"late-application-readiness-{attempt}",
            timeout=10,
        )
        if result.returncode == 0:
            try:
                document = json.loads(result.stdout)
            except json.JSONDecodeError:
                document = None
            if isinstance(document, dict) and document.get("status") == "UP":
                return
        if time.monotonic() >= deadline:
            raise CommissioningError("restored application did not pass bounded readiness verification")
        time.sleep(2)


def start_and_verify_prior_active_units(
    runner: Runner,
    service_map: Mapping[str, Any],
    *,
    evidence: Path,
    pointer: Mapping[str, Any],
) -> dict[str, dict[str, str]]:
    health: dict[str, dict[str, str]] = {}
    restore_order = ("postgresql.service", "postgresql@16-main.service") + tuple(reversed(STOP_ORDER[:-2]))
    for unit in restore_order:
        state = service_map.get(unit, {})
        if not isinstance(state, dict) or state.get("ActiveState") not in {"active", "activating"}:
            continue
        start_unit_with_one_time_gate(
            runner,
            evidence,
            pointer,
            unit,
            log_name="late-start-" + unit,
        )
        health[unit] = wait_for_unit_health(runner, unit)
        if unit == "uten-imp.service":
            wait_for_application_readiness(runner)
    for unit in ("postgresql.service", "postgresql@16-main.service"):
        state = service_map.get(unit, {})
        if isinstance(state, dict) and state.get("ActiveState") in {"active", "activating"}:
            wait_for_postgres_health(runner)
            break
    return health


def start_unit_with_one_time_gate(
    runner: Runner,
    evidence: Path,
    pointer: Mapping[str, Any],
    unit: str,
    *,
    log_name: str,
) -> None:
    """Grant one start job, then close its marker before any health wait."""

    try:
        publish_gate_grant(runner, evidence, pointer, [unit])
        runner.run([SYSTEMCTL, "start", unit], allowed=(0,), log_name=log_name)
    finally:
        # Even a failed/timeout start may have queued or partially started the
        # unit. Re-running the pointer-aware authorizer consumes the grant and
        # removes the marker before control reaches health checks or callers.
        ensure_gate_authorizer_closed(runner)


def process_start_time_ticks(pid: int) -> int:
    try:
        fields = (Path("/proc") / str(pid) / "stat").read_text(encoding="ascii").split()
    except OSError as exc:
        raise CommissioningError("late verifier process identity is unavailable") from exc
    if len(fields) < 22:
        raise CommissioningError("late verifier process stat is malformed")
    return integer_field(fields[21], "late verifier start time")


def process_holds_exclusive_flock(pid: int, path: Path) -> bool:
    try:
        info = path.stat()
        lines = Path("/proc/locks").read_text(encoding="ascii").splitlines()
    except OSError:
        return False
    identity = f"{os.major(info.st_dev):02x}:{os.minor(info.st_dev):02x}:{info.st_ino}"
    for line in lines:
        fields = line.split()
        if (
            len(fields) >= 8
            and fields[1] == "FLOCK"
            and fields[3] == "WRITE"
            and fields[4] == str(pid)
            and fields[5].lower() == identity.lower()
        ):
            return True
    return False


def late_verifier_identity() -> dict[str, Any]:
    invocation_id = os.environ.get("INVOCATION_ID", "")
    if not re.fullmatch(r"[0-9a-f]{32}", invocation_id):
        raise CommissioningError("late verifier systemd invocation identity is absent")
    pid = os.getpid()
    if not process_holds_exclusive_flock(pid, LOCK_PATH) or not process_holds_exclusive_flock(pid, MAINTENANCE_LOCK):
        raise CommissioningError("late verifier does not hold both commissioning locks")
    return {
        "latePid": pid,
        "lateStartTimeTicks": process_start_time_ticks(pid),
        "lateInvocationId": invocation_id,
    }


def validate_late_verifier_identity(grant: Mapping[str, Any]) -> None:
    pid = grant.get("latePid")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 1:
        raise CommissioningError("late gate grant PID is malformed")
    invocation_id = str(grant.get("lateInvocationId", ""))
    if not re.fullmatch(r"[0-9a-f]{32}", invocation_id):
        raise CommissioningError("late gate grant invocation identity is malformed")
    if process_start_time_ticks(pid) != grant.get("lateStartTimeTicks"):
        raise CommissioningError("late gate grant process start identity differs")
    proc = Path("/proc") / str(pid)
    try:
        environment = {
            item.partition(b"=")[0].decode("ascii", errors="ignore"): item.partition(b"=")[2].decode(
                "ascii", errors="ignore"
            )
            for item in (proc / "environ").read_bytes().split(b"\0")
            if b"=" in item
        }
        cgroup = (proc / "cgroup").read_text(encoding="utf-8")
    except OSError as exc:
        raise CommissioningError("late verifier process disappeared during gate authorization") from exc
    if environment.get("INVOCATION_ID") != invocation_id:
        raise CommissioningError("late verifier invocation environment differs")
    if "/" + LATE_RESUME_UNIT.name not in cgroup:
        raise CommissioningError("late verifier is not in the fixed systemd service cgroup")
    if not process_holds_exclusive_flock(pid, LOCK_PATH) or not process_holds_exclusive_flock(pid, MAINTENANCE_LOCK):
        raise CommissioningError("late verifier lock ownership differs")


def reset_gate_open_directory() -> None:
    runtime_info = GATE_RUNTIME_DIRECTORY.lstat()
    if not root_directory_metadata_is_exact(runtime_info, 0o700):
        raise CommissioningError("gate authorizer RuntimeDirectory metadata differs")
    if GATE_OPEN_DIRECTORY.exists() or GATE_OPEN_DIRECTORY.is_symlink():
        if GATE_OPEN_DIRECTORY.is_symlink() or not root_directory_metadata_is_exact(
            GATE_OPEN_DIRECTORY.lstat(), 0o700
        ):
            raise CommissioningError("gate open directory metadata differs")
        children = list(GATE_OPEN_DIRECTORY.iterdir())
        expected_names = {gate_marker_path(unit).name for unit in GATED_UNITS}
        unexpected = [child for child in children if child.name not in expected_names]
        for child in children:
            if child.name in expected_names:
                if child.is_symlink() or not child.is_file() or not root_file_metadata_is_exact(child.lstat(), 0o600):
                    raise CommissioningError("gate marker metadata differs")
                child.unlink()
        fsync_directory(GATE_OPEN_DIRECTORY)
        if unexpected:
            raise CommissioningError("gate authorizer RuntimeDirectory contains unexpected entries")
    else:
        GATE_OPEN_DIRECTORY.mkdir(mode=0o700)
        os.chown(GATE_OPEN_DIRECTORY, 0, 0)
        os.chmod(GATE_OPEN_DIRECTORY, 0o700)
        fsync_directory(GATE_RUNTIME_DIRECTORY)


def write_gate_markers(units: Sequence[str], authorization: Mapping[str, Any]) -> None:
    if len(set(units)) != len(units) or any(unit not in GATED_UNITS for unit in units):
        raise CommissioningError("gate authorization contains an unknown or duplicate unit")
    for unit in units:
        marker = {
            "schemaVersion": SCHEMA_VERSION,
            "kind": KIND + "-unit-start-authorization",
            "unit": unit,
            "authorization": dict(authorization),
        }
        write_system_file(gate_marker_path(unit), canonical_bytes(marker), 0o600)


def observed_gate_markers() -> set[str]:
    if not GATE_OPEN_DIRECTORY.exists() and not GATE_OPEN_DIRECTORY.is_symlink():
        return set()
    if GATE_OPEN_DIRECTORY.is_symlink() or not root_directory_metadata_is_exact(GATE_OPEN_DIRECTORY.lstat(), 0o700):
        raise CommissioningError("gate open directory is unsafe")
    by_name = {gate_marker_path(unit).name: unit for unit in GATED_UNITS}
    result: set[str] = set()
    for child in GATE_OPEN_DIRECTORY.iterdir():
        unit = by_name.get(child.name)
        if unit is None or child.is_symlink() or not root_file_metadata_is_exact(child.lstat(), 0o600):
            raise CommissioningError("gate open directory contains an unsafe marker")
        result.add(unit)
    return result


def authorize_gate() -> dict[str, Any]:
    """Root helper used only by the fixed authorizer service."""

    require_root()
    reset_gate_open_directory()
    if not ACTIVE_POINTER.exists() and not ACTIVE_POINTER.is_symlink():
        units = list(GATED_UNITS)
        write_gate_markers(units, {"mode": "NORMAL_NO_ACTIVE_TRANSACTION", "bootId": current_boot_id()})
        return {"status": "NORMAL_GATE_OPEN", "authorizedUnits": units}
    if ACTIVE_POINTER.is_symlink() or not root_file_metadata_is_exact(ACTIVE_POINTER.lstat(), 0o600):
        raise CommissioningError("active pointer is unsafe during gate authorization")
    pointer = load_json_regular(ACTIVE_POINTER)
    evidence = Path(str(pointer.get("evidence", "")))
    validate_rollback_evidence(evidence, pointer)
    if not LATE_GRANT.exists() and not LATE_GRANT.is_symlink():
        return {"status": "ACTIVE_TRANSACTION_GATE_CLOSED", "authorizedUnits": []}
    if (
        LATE_GRANT.is_symlink()
        or not root_file_metadata_is_exact(LATE_GRANT.lstat(), 0o600)
        or not root_directory_metadata_is_exact(LATE_RUNTIME_DIRECTORY.lstat(), 0o700)
    ):
        raise CommissioningError("late gate grant metadata differs")
    grant = load_json_regular(LATE_GRANT)
    expected_keys = {
        "schemaVersion",
        "kind",
        "transactionId",
        "planSha256",
        "pointerSha256",
        "bootId",
        "latePid",
        "lateStartTimeTicks",
        "lateInvocationId",
        "permittedUnits",
    }
    permitted = grant.get("permittedUnits")
    if (
        set(grant) != expected_keys
        or grant.get("schemaVersion") != SCHEMA_VERSION
        or grant.get("kind") != KIND + "-late-gate-grant"
        or grant.get("transactionId") != evidence.name
        or grant.get("planSha256") != pointer.get("planSha256")
        or grant.get("pointerSha256") != sha256_file(ACTIVE_POINTER)
        or grant.get("bootId") != current_boot_id()
        or not isinstance(permitted, list)
        or not permitted
        or not all(isinstance(unit, str) for unit in permitted)
    ):
        raise CommissioningError("late gate grant binding differs")
    validate_late_verifier_identity(grant)
    write_gate_markers(permitted, {"mode": "BOUND_LATE_VERIFIER", "grantSha256": sha256_file(LATE_GRANT)})
    return {"status": "BOUND_LATE_GATE_OPEN", "authorizedUnits": permitted}


def remove_late_grant() -> None:
    if LATE_GRANT.exists() or LATE_GRANT.is_symlink():
        if LATE_GRANT.is_symlink() or not root_file_metadata_is_exact(LATE_GRANT.lstat(), 0o600):
            raise CommissioningError("late gate grant became unsafe")
        LATE_GRANT.unlink()
        fsync_directory(LATE_RUNTIME_DIRECTORY)


def ensure_gate_authorizer_closed(runner: Runner) -> None:
    remove_late_grant()
    runner.run([SYSTEMCTL, "restart", GATE_AUTHORIZER_UNIT.name], allowed=(0,), log_name="late-close-gate")
    if observed_gate_markers():
        raise CommissioningError("active transaction gate unexpectedly opened without a grant")


def publish_gate_grant(
    runner: Runner,
    evidence: Path,
    pointer: Mapping[str, Any],
    units: Sequence[str],
) -> None:
    runtime_info = LATE_RUNTIME_DIRECTORY.lstat()
    if not root_directory_metadata_is_exact(runtime_info, 0o700):
        raise CommissioningError("late recovery RuntimeDirectory metadata differs")
    identity = late_verifier_identity()
    grant = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-late-gate-grant",
        "transactionId": evidence.name,
        "planSha256": pointer.get("planSha256"),
        "pointerSha256": sha256_file(ACTIVE_POINTER),
        "bootId": current_boot_id(),
        **identity,
        "permittedUnits": list(units),
    }
    atomic_json(LATE_GRANT, grant, replace=True)
    runner.run([SYSTEMCTL, "restart", GATE_AUTHORIZER_UNIT.name], allowed=(0,), log_name="late-authorize-gate")
    if observed_gate_markers() != set(units):
        raise CommissioningError("gate authorizer did not publish the exact unit grant")


def close_gate_authorizer(runner: Runner) -> list[str]:
    failures: list[str] = []
    try:
        remove_late_grant()
    except BaseException as exc:
        failures.append("remove late gate grant: " + str(exc))
    try:
        runner.run([SYSTEMCTL, "stop", GATE_AUTHORIZER_UNIT.name], allowed=(0,), log_name="contain-close-gate")
        if GATE_RUNTIME_DIRECTORY.exists() or GATE_RUNTIME_DIRECTORY.is_symlink():
            raise CommissioningError("gate RuntimeDirectory remained after authorizer stop")
    except BaseException as exc:
        failures.append("stop gate authorizer: " + str(exc))
    return failures


def finalize_gate_normal(
    runner: Runner, evidence: Path, pointer: Mapping[str, Any]
) -> dict[str, Any]:
    # Never publish a full-unit grant while the durable pointer still exists.
    # Keep the gate closed, delete the sole durable arm, then reopen normal
    # markers. A crash after deletion is handled by the late service's fixed
    # ExecStopPost; after a reboot /run is empty and the next protected start
    # Requires the normal no-pointer authorizer.
    ensure_gate_authorizer_closed(runner)
    current = active_pointer_for_evidence(evidence, required=True)
    if current != dict(pointer):
        raise CommissioningError("active pointer changed before gate finalization")
    ACTIVE_POINTER.unlink()
    pointer_sync_failure: str | None = None
    try:
        fsync_directory(ACTIVE_POINTER.parent)
    except BaseException as exc:
        # The in-memory namespace is already disarmed.  Never throw back into
        # rollback/containment after this point.  If the directory sync did not
        # persist, a reboot can only resurrect the pointer, which safely closes
        # the gate and retries committed late finalization.
        pointer_sync_failure = type(exc).__name__ + ": " + str(exc)
    gate_failures: list[str] = []
    try:
        runner.run(
            [SYSTEMCTL, "restart", GATE_AUTHORIZER_UNIT.name],
            allowed=(0,),
            log_name="reopen-normal-gate-after-disarm",
        )
        if observed_gate_markers() != set(GATED_UNITS):
            gate_failures.append("normal authorizer did not restore the exact marker set")
    except BaseException as exc:
        # Pointer deletion is the durable point of no return. Do not claim that
        # it can be rolled back; ExecStopPost and the next protected Requires=
        # start both retry the no-pointer authorizer.
        gate_failures.append(type(exc).__name__ + ": " + str(exc))
    return {
        "activePointerRemoved": True,
        "pointerDirectorySynced": pointer_sync_failure is None,
        "pointerDirectorySyncFailure": pointer_sync_failure,
        "normalGateOpen": not gate_failures,
        "normalGateFailures": gate_failures,
    }


def record_gate_finalization_failure(
    evidence: Path,
    pointer: Mapping[str, Any],
    gate_result: Mapping[str, Any],
    runner: Runner,
    failure: BaseException,
    *,
    outcome: str,
) -> dict[str, Any]:
    """Write the sole append-only terminal receipt after an irreversible disarm."""

    path = evidence / "gate-finalization-failed.json"
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not root_file_metadata_is_exact(path.lstat(), 0o600):
            raise CommissioningError("gate-finalization failure receipt metadata differs")
        existing = load_json_regular(path)
        expected_status = outcome + "_DISARMED_NORMAL_GATE_NOT_OPEN"
        if (
            existing.get("kind") != KIND + "-gate-finalization-failure"
            or existing.get("status") != expected_status
            or existing.get("transactionId") != evidence.name
            or existing.get("planSha256") != pointer.get("planSha256")
            or existing.get("activePointerPresent") is not False
        ):
            raise CommissioningError("gate-finalization failure receipt binding differs")
        return existing
    marker_units: list[str] = []
    marker_failure: str | None = None
    try:
        marker_units = sorted(observed_gate_markers())
    except BaseException as exc:
        marker_failure = type(exc).__name__ + ": " + str(exc)
    authorizer_state: dict[str, str] = {}
    authorizer_failure: str | None = None
    try:
        authorizer_state = unit_state(runner, GATE_AUTHORIZER_UNIT.name)
    except BaseException as exc:
        authorizer_failure = type(exc).__name__ + ": " + str(exc)
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-gate-finalization-failure",
        "status": outcome + "_DISARMED_NORMAL_GATE_NOT_OPEN",
        "transactionId": evidence.name,
        "planSha256": pointer.get("planSha256"),
        "activePointerPresent": ACTIVE_POINTER.exists() or ACTIVE_POINTER.is_symlink(),
        "gateResult": dict(gate_result),
        "markerUnits": marker_units,
        "markerObservationFailure": marker_failure,
        "authorizerState": authorizer_state,
        "authorizerObservationFailure": authorizer_failure,
        "failure": type(failure).__name__ + ": " + str(failure),
        "recordedAtUtc": utc_now(),
    }
    if receipt["activePointerPresent"] is not False:
        raise CommissioningError("active pointer unexpectedly reappeared after final disarm")
    atomic_json(path, receipt, replace=False)
    return receipt


def finalize_gate_with_retry(
    runner: Runner,
    evidence: Path,
    pointer: Mapping[str, Any],
    *,
    outcome: str,
) -> dict[str, Any]:
    finish = finalize_gate_normal(runner, evidence, pointer)
    if finish.get("normalGateOpen"):
        return finish
    try:
        contain_active_late_failure(runner)
        return {**finish, "normalGateOpen": True, "normalGateRecoveredOnRetry": True}
    except BaseException as exc:
        record_gate_finalization_failure(
            evidence,
            pointer,
            finish,
            runner,
            exc,
            outcome=outcome,
        )
        raise CommissioningError(
            "transaction is disarmed, but the normal unit gate did not reopen"
        ) from exc


def validate_resume_pointer_binding(pointer: Mapping[str, Any]) -> dict[str, Any]:
    installation = resume_installation_observation()
    expected_helper = f"uten-imp-nvme-commissioner-{pointer.get('helperSha256')}.py"
    if (
        installation.get("state") != "complete-valid-permanent-gate"
        or Path(str(installation.get("helper", ""))).name != expected_helper
    ):
        raise CommissioningError("active pointer permanent recovery binding differs")
    return installation


def active_pointer_for_evidence(evidence: Path, *, required: bool) -> dict[str, Any] | None:
    if not ACTIVE_POINTER.exists() and not ACTIVE_POINTER.is_symlink():
        if required:
            raise CommissioningError("active transaction pointer is absent")
        return None
    if ACTIVE_POINTER.is_symlink() or not ACTIVE_POINTER.is_file():
        raise CommissioningError("active transaction pointer is unsafe")
    if not root_file_metadata_is_exact(ACTIVE_POINTER.lstat(), 0o600):
        raise CommissioningError("active transaction pointer metadata differs")
    pointer = load_json_regular(ACTIVE_POINTER)
    if pointer.get("evidence") != str(evidence):
        raise CommissioningError("a different active transaction pointer exists")
    return pointer


def rollback_identity_fields(evidence: Path) -> dict[str, Any]:
    identity_path = evidence / "lv-identity.json"
    command_path = evidence / "commands" / "lvcreate.json"
    return {
        "lvIdentitySha256": sha256_file(identity_path)
        if identity_path.is_file() and not identity_path.is_symlink()
        else None,
        "lvcreateLogSha256": sha256_file(command_path)
        if command_path.is_file() and not command_path.is_symlink()
        else None,
    }


def existing_rollback_receipt(evidence: Path, plan_sha256: str) -> dict[str, Any] | None:
    path = evidence / "rollback.json"
    if not path.exists() and not path.is_symlink():
        return None
    if path.is_symlink() or not root_file_metadata_is_exact(path.lstat(), 0o600):
        raise CommissioningError("existing rollback receipt metadata differs")
    receipt = load_json_regular(path)
    validate_lineage_reference(path, receipt, "previousReceiptSha256")
    if (
        receipt.get("kind") != KIND + "-rollback"
        or receipt.get("transactionId") != evidence.name
        or receipt.get("planSha256") != plan_sha256
        or receipt.get("status")
        not in {
            "ABORTED_BEFORE_ARMING",
            "EARLY_STORAGE_RESTORED_AWAITING_LATE",
            "ROLLBACK_INCOMPLETE_ENTRY_MUST_REMAIN_CLOSED",
            "ROLLED_BACK",
        }
        or receipt.get("lvRemovalAttempted") is not False
        or receipt.get("oldMdWipeAttempted") is not False
        or receipt.get("oldMdStopAttempted") is not False
    ):
        raise CommissioningError("existing rollback receipt is invalid")
    return receipt


def validate_final_rollback_receipt(
    evidence: Path,
    pointer: Mapping[str, Any],
    service_map: Mapping[str, Any],
) -> dict[str, Any] | None:
    receipt = existing_rollback_receipt(evidence, str(pointer.get("planSha256", "")))
    if receipt is None or receipt.get("status") != "ROLLED_BACK":
        return None
    expected_keys = {
        "schemaVersion",
        "kind",
        "transactionId",
        "planSha256",
        "status",
        "reason",
        "failures",
        "lvRemovalAttempted",
        "oldMdWipeAttempted",
        "oldMdStopAttempted",
        "lvIdentitySha256",
        "lvcreateLogSha256",
        "recordedAtUtc",
        "lastRecoveryAttemptAtUtc",
        "lateRecoveryRequired",
        "lateRecoveryAttempt",
        "health",
        "completedAtUtc",
        "previousReceiptSha256",
    }
    health = receipt.get("health")
    expected_protected = {
        unit
        for unit in STOP_ORDER
        if isinstance(service_map.get(unit), dict)
        and service_map[unit].get("ActiveState") in {"active", "activating"}
    }
    expected_updates = {
        unit
        for unit in ("unattended-upgrades.service",) + APT_TIMERS
        if isinstance(service_map.get(unit), dict)
        and service_map[unit].get("ActiveState") in {"active", "activating"}
    }
    expected_identity = rollback_identity_fields(evidence)
    if (
        set(receipt) != expected_keys
        or receipt.get("schemaVersion") != SCHEMA_VERSION
        or receipt.get("failures") != []
        or not isinstance(receipt.get("reason"), str)
        or not receipt.get("reason")
        or receipt.get("lateRecoveryRequired") is not False
        or isinstance(receipt.get("lateRecoveryAttempt"), bool)
        or not isinstance(receipt.get("lateRecoveryAttempt"), int)
        or not 1 <= int(receipt["lateRecoveryAttempt"]) <= LATE_RECOVERY_ATTEMPTS
        or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", str(receipt.get("recordedAtUtc", "")))
        or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",
            str(receipt.get("lastRecoveryAttemptAtUtc", "")),
        )
        or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", str(receipt.get("completedAtUtc", "")))
        or any(
            value is not None and not re.fullmatch(r"[0-9a-f]{64}", str(value))
            for value in (receipt.get("lvIdentitySha256"), receipt.get("lvcreateLogSha256"))
        )
        or receipt.get("lvIdentitySha256") != expected_identity["lvIdentitySha256"]
        or receipt.get("lvcreateLogSha256") != expected_identity["lvcreateLogSha256"]
        or not isinstance(health, dict)
        or set(health) != {"protectedUnits", "updateInfrastructure"}
        or not isinstance(health.get("protectedUnits"), dict)
        or set(health["protectedUnits"]) != expected_protected
        or not all(isinstance(value, dict) for value in health["protectedUnits"].values())
        or not isinstance(health.get("updateInfrastructure"), dict)
        or set(health["updateInfrastructure"]) != expected_updates
        or not all(isinstance(value, dict) for value in health["updateInfrastructure"].values())
    ):
        raise CommissioningError("final rollback receipt binding differs")
    return receipt


def write_rollback_receipt(
    evidence: Path,
    *,
    plan_sha256: str,
    status: str,
    reason: str,
    failures: Sequence[str],
    existing: Mapping[str, Any] | None,
    extra: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    attempted_at = utc_now()
    receipt: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-rollback",
        "transactionId": evidence.name,
        "planSha256": plan_sha256,
        "status": status,
        "reason": existing.get("reason", reason) if existing else reason,
        "failures": list(failures),
        "lvRemovalAttempted": False,
        "oldMdWipeAttempted": False,
        "oldMdStopAttempted": False,
        **rollback_identity_fields(evidence),
        "recordedAtUtc": existing.get("recordedAtUtc", attempted_at) if existing else attempted_at,
        "lastRecoveryAttemptAtUtc": attempted_at,
    }
    if extra:
        receipt.update(extra)
    return atomic_json_with_lineage(
        evidence / "rollback.json",
        receipt,
        lineage_field="previousReceiptSha256",
    )


def early_recovery_ready_document(
    evidence: Path, pointer: Mapping[str, Any], preimages: Mapping[str, Any], *, recorded_at: str
) -> dict[str, Any]:
    service_map = preimages.get("serviceMap")
    old_mount = preimages.get("oldDataMount")
    old_md = preimages.get("oldMd")
    if not isinstance(service_map, dict) or not isinstance(old_mount, dict) or not isinstance(old_md, dict):
        raise CommissioningError("early recovery handoff preimages are incomplete")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-early-recovery-ready",
        "status": "STORAGE_AND_ENABLEMENT_RESTORED_LATE_REQUIRED",
        "transactionId": evidence.name,
        "planSha256": pointer.get("planSha256"),
        "preimagesSha256": pointer.get("preimagesSha256"),
        "helperSha256": pointer.get("helperSha256"),
        "serviceMapSha256": sha256_bytes(canonical_bytes(service_map)),
        "oldDataUuid": str(old_mount.get("uuid", "")).lower(),
        "oldMdUuid": old_md.get("MD_UUID"),
        "recordedAtUtc": recorded_at,
        "lastVerifiedAtUtc": utc_now(),
    }


def validate_early_recovery_ready(
    evidence: Path, pointer: Mapping[str, Any], preimages: Mapping[str, Any]
) -> dict[str, Any]:
    path = evidence / EARLY_RECOVERY_READY_NAME
    if path.is_symlink() or not path.is_file() or not root_file_metadata_is_exact(path.lstat(), 0o600):
        raise CommissioningError("early recovery handoff is absent or unsafe")
    value = load_json_regular(path)
    expected = early_recovery_ready_document(
        evidence,
        pointer,
        preimages,
        recorded_at=str(value.get("recordedAtUtc", "")),
    )
    expected["lastVerifiedAtUtc"] = value.get("lastVerifiedAtUtc")
    if set(value) != set(expected) or value != expected:
        raise CommissioningError("early recovery handoff binding differs")
    receipt = existing_rollback_receipt(evidence, str(pointer.get("planSha256", "")))
    if receipt is None or receipt.get("status") not in {
        "EARLY_STORAGE_RESTORED_AWAITING_LATE",
        "ROLLED_BACK",
    }:
        raise CommissioningError("early recovery receipt is not ready for late recovery")
    return value


def write_early_recovery_ready(
    evidence: Path, pointer: Mapping[str, Any], preimages: Mapping[str, Any]
) -> dict[str, Any]:
    path = evidence / EARLY_RECOVERY_READY_NAME
    recorded_at = utc_now()
    if path.exists() or path.is_symlink():
        current = validate_early_recovery_ready(evidence, pointer, preimages)
        recorded_at = str(current["recordedAtUtc"])
    document = early_recovery_ready_document(evidence, pointer, preimages, recorded_at=recorded_at)
    atomic_json(path, document, replace=True)
    return document


def current_boot_id() -> str:
    try:
        value = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    except OSError as exc:
        raise CommissioningError("boot identity is unavailable") from exc
    if not re.fullmatch(r"[0-9a-f-]{36}", value):
        raise CommissioningError("boot identity is malformed")
    return value


def validate_late_recovery_state(
    path: Path,
    document: Mapping[str, Any],
    evidence: Path,
    pointer: Mapping[str, Any],
) -> None:
    expected_keys = {
        "schemaVersion",
        "kind",
        "transactionId",
        "planSha256",
        "bootId",
        "attemptCount",
        "status",
        "lastAttemptAtUtc",
        "lastFailure",
        "previousStateSha256",
    }
    if (
        set(document) != expected_keys
        or document.get("schemaVersion") != SCHEMA_VERSION
        or document.get("kind") != KIND + "-late-recovery-state"
        or document.get("transactionId") != evidence.name
        or document.get("planSha256") != pointer.get("planSha256")
        or not re.fullmatch(r"[0-9a-f-]{36}", str(document.get("bootId", "")))
        or isinstance(document.get("attemptCount"), bool)
        or not isinstance(document.get("attemptCount"), int)
        or not 1 <= int(document["attemptCount"]) <= LATE_RECOVERY_ATTEMPTS
        or document.get("status") not in {"RUNNING", "SUCCEEDED", "FAILED"}
        or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z",
            str(document.get("lastAttemptAtUtc", "")),
        )
        or (
            document.get("lastFailure") is not None
            and not isinstance(document.get("lastFailure"), str)
        )
    ):
        raise CommissioningError("late recovery state binding differs")
    validate_lineage_reference(path, document, "previousStateSha256")


def begin_late_recovery_attempt(
    evidence: Path, pointer: Mapping[str, Any]
) -> tuple[int, dict[str, Any]]:
    path = evidence / LATE_RECOVERY_STATE_NAME
    boot_id = current_boot_id()
    previous: dict[str, Any] | None = None
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not root_file_metadata_is_exact(path.lstat(), 0o600):
            raise CommissioningError("late recovery state metadata differs")
        previous = load_json_regular(path)
        validate_late_recovery_state(path, previous, evidence, pointer)
    attempt = 1
    if previous is not None and previous.get("bootId") == boot_id:
        attempt = int(previous["attemptCount"]) + 1
    if attempt > LATE_RECOVERY_ATTEMPTS:
        raise CommissioningError("bounded late recovery attempts are exhausted for this boot")
    state = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-late-recovery-state",
        "transactionId": evidence.name,
        "planSha256": pointer.get("planSha256"),
        "bootId": boot_id,
        "attemptCount": attempt,
        "status": "RUNNING",
        "lastAttemptAtUtc": utc_now(),
        "lastFailure": None,
    }
    state = atomic_json_with_lineage(path, state, lineage_field="previousStateSha256")
    return attempt, state


def finish_late_recovery_attempt(evidence: Path, state: Mapping[str, Any], *, status: str, failure: str | None) -> None:
    document = dict(state)
    document["status"] = status
    document["lastFailure"] = failure
    document["lastAttemptAtUtc"] = utc_now()
    atomic_json_with_lineage(
        evidence / LATE_RECOVERY_STATE_NAME,
        document,
        lineage_field="previousStateSha256",
    )


def rollback(
    evidence: Path,
    runner: Runner,
    *,
    reason: str,
) -> dict[str, Any]:
    active_pointer = active_pointer_for_evidence(evidence, required=False)
    preimages = validate_rollback_evidence(evidence, active_pointer)
    plan_sha256 = str(load_json_regular(evidence / "plan.json").get("planSha256", ""))
    existing_receipt = existing_rollback_receipt(evidence, plan_sha256)

    # No destructive method is reachable before install_resume durably creates
    # the active pointer.  If installing the permanent recovery chain itself
    # failed, prove the transaction never advanced beyond PREPARED and stop;
    # there is no storage or runtime state to roll back or late-start.
    if active_pointer is None:
        state_path = evidence / "state.json"
        if state_path.is_symlink() or not state_path.is_file() or not root_file_metadata_is_exact(state_path.lstat(), 0o600):
            raise CommissioningError("unarmed transaction state is absent or unsafe")
        state = load_json_regular(state_path)
        if state.get("transactionId") != evidence.name or state.get("state") != "PREPARED":
            raise CommissioningError("unarmed transaction advanced beyond the safe prepare boundary")
        return write_rollback_receipt(
            evidence,
            plan_sha256=plan_sha256,
            status="ABORTED_BEFORE_ARMING",
            reason=reason,
            failures=[],
            existing=existing_receipt,
        )

    validate_resume_pointer_binding(active_pointer)
    runner.recovery_attempt(evidence)
    failures: list[str] = []
    failures.extend(close_gate_authorizer(runner))
    failures.extend(cleanup_transaction_mounts(runner, preimages))
    old_uuid = str(preimages.get("oldDataMount", {}).get("uuid", "")).lower()
    try:
        current_mount = runner.run(
            [FINDMNT, "--json", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS,UUID", TARGET_MOUNT], allowed=(0, 1)
        )
        if current_mount.returncode == 0:
            parsed = json.loads(current_mount.stdout)
            observed_current = single_filesystem(parsed)
            source = normalized_mount_source(observed_current.get("source"))
            already_old = (
                source == OLD_MD_DEVICE
                and observed_current.get("fstype") == "ext4"
                and str(observed_current.get("uuid", "")).lower() == old_uuid
            )
            if not already_old:
                if not same_block_device(source, TARGET_LV_PATH):
                    raise CommissioningError("unexpected /data source was not unmounted")
                runner.run([UMOUNT, TARGET_MOUNT], allowed=(0,), log_name="rollback-unmount-new-data")
                if runner.run([FINDMNT, "--mountpoint", TARGET_MOUNT], allowed=(1,)).returncode != 1:
                    raise CommissioningError("new /data mount remained after unmount")
    except BaseException as exc:
        failures.append("unmount new data: " + str(exc))
    failures.extend(verify_target_lv_unmounted(runner))

    restored_files: set[str] = set()
    for key in ("fstab", "pgGuard", "pgStartConf", "storageAuthority"):
        try:
            restore_file_preimage(preimages[key])
            restored_files.add(key)
        except BaseException as exc:
            failures.append(f"restore {key}: {exc}")
    try:
        runner.run([SYSTEMCTL, "daemon-reload"], allowed=(0,), log_name="rollback-daemon-reload")
    except BaseException as exc:
        failures.append("daemon-reload: " + str(exc))
    old_mount_verified = False
    if not failures and restored_files == {"fstab", "pgGuard", "pgStartConf", "storageAuthority"}:
        try:
            wait_for_old_md(runner, preimages)
            mounted = runner.run([FINDMNT, "--mountpoint", TARGET_MOUNT], allowed=(0, 1))
            if mounted.returncode != 0:
                runner.run([MOUNT, TARGET_MOUNT], log_name="rollback-mount-old-data")
            verify_restored_old_storage(runner, preimages, wait_for_array=False)
            old_mount_verified = True
        except BaseException as exc:
            failures.append("restore old mount: " + str(exc))

    if not failures and old_mount_verified:
        failures.extend(
            restore_enablement_map(
                runner,
                preimages.get("serviceMap", {}),
            )
        )
    if failures:
        failures.extend(contain_runtime_closed(runner))
    receipt = write_rollback_receipt(
        evidence,
        plan_sha256=plan_sha256,
        status=(
            "EARLY_STORAGE_RESTORED_AWAITING_LATE"
            if not failures
            else "ROLLBACK_INCOMPLETE_ENTRY_MUST_REMAIN_CLOSED"
        ),
        reason=reason,
        failures=failures,
        existing=existing_receipt,
        extra={"lateRecoveryRequired": not failures},
    )
    if failures:
        raise CommissioningError("rollback incomplete: " + "; ".join(failures))

    try:
        handoff = write_early_recovery_ready(evidence, active_pointer, preimages)
        runner.run(
            [SYSTEMCTL, "restart", "--no-block", LATE_RESUME_TIMER.name],
            allowed=(0,),
            log_name="queue-late-recovery",
        )
    except BaseException as exc:
        cleanup_failures: list[str] = ["queue late recovery: " + str(exc)]
        handoff_path = evidence / EARLY_RECOVERY_READY_NAME
        if handoff_path.exists() or handoff_path.is_symlink():
            try:
                if handoff_path.is_symlink() or not handoff_path.is_file():
                    raise CommissioningError("early handoff became unsafe")
                handoff_path.unlink()
                fsync_directory(evidence)
            except BaseException as cleanup_exc:
                cleanup_failures.append("remove unusable early handoff: " + str(cleanup_exc))
        cleanup_failures.extend(contain_runtime_closed(runner))
        write_rollback_receipt(
            evidence,
            plan_sha256=plan_sha256,
            status="ROLLBACK_INCOMPLETE_ENTRY_MUST_REMAIN_CLOSED",
            reason=reason,
            failures=cleanup_failures,
            existing=receipt,
            extra={"lateRecoveryRequired": True},
        )
        raise CommissioningError("late recovery could not be queued: " + "; ".join(cleanup_failures)) from exc
    receipt["earlyRecoveryHandoffSha256"] = sha256_bytes(canonical_bytes(handoff))
    return atomic_json_with_lineage(
        evidence / "rollback.json",
        receipt,
        lineage_field="previousReceiptSha256",
    )


def contain_late_recovery_failure(
    runner: Runner,
    *,
    preserve_verified_update_infrastructure: bool = False,
) -> list[str]:
    failures: list[str] = close_gate_authorizer(runner)
    failures.extend(contain_runtime_closed(runner))
    if not preserve_verified_update_infrastructure:
        failures.extend(stop_update_infrastructure(runner))
    return failures


def validate_existing_late_stop_post(
    path: Path,
    document: Mapping[str, Any],
    evidence: Path,
    pointer: Mapping[str, Any],
) -> None:
    expected_keys = {
        "schemaVersion",
        "kind",
        "status",
        "transactionId",
        "planSha256",
        "validationFailure",
        "verifiedUpdateInfrastructurePreserved",
        "failures",
        "recordedAtUtc",
        "previousReceiptSha256",
    }
    if (
        set(document) != expected_keys
        or document.get("schemaVersion") != SCHEMA_VERSION
        or document.get("kind") != KIND + "-late-stop-post"
        or document.get("status")
        not in {
            "CONTAINED_ACTIVE_POINTER_RETAINED",
            "CONTAINMENT_INCOMPLETE_ACTIVE_POINTER_RETAINED",
        }
        or document.get("transactionId") != evidence.name
        or document.get("planSha256") != pointer.get("planSha256")
        or (
            document.get("validationFailure") is not None
            and not isinstance(document.get("validationFailure"), str)
        )
        or not isinstance(document.get("verifiedUpdateInfrastructurePreserved"), bool)
        or not isinstance(document.get("failures"), list)
        or not all(isinstance(value, str) for value in document["failures"])
        or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", str(document.get("recordedAtUtc", "")))
    ):
        raise CommissioningError("existing late stop-post receipt binding differs")
    validate_lineage_reference(path, document, "previousReceiptSha256")


def contain_active_late_failure(runner: Runner | None = None) -> dict[str, Any]:
    """ExecStopPost fail-safe for SIGKILL/timeout of the late verifier.

    A systemd Condition prevents new starts after the volatile ready marker is
    removed, but Conditions do not stop units that were already started.  This
    fixed stop-post path therefore re-closes and disables the protected runtime
    whenever the durable active pointer still exists.  It intentionally does
    not take the database-maintenance lock: containment must not be delayed by
    the process whose abnormal exit triggered it.
    """

    require_root()
    if not ACTIVE_POINTER.exists() and not ACTIVE_POINTER.is_symlink():
        # This also covers SIGKILL in the narrow post-disarm window: the
        # transaction is already durably complete, so reopen the normal gate
        # instead of attempting rollback/containment.
        runner = runner or Runner()
        runner.run(
            [SYSTEMCTL, "restart", GATE_AUTHORIZER_UNIT.name],
            allowed=(0,),
            log_name="stop-post-reopen-normal-gate",
        )
        if observed_gate_markers() != set(GATED_UNITS):
            raise CommissioningError("normal gate did not reopen after committed late finalization")
        return {"status": "NO_ACTIVE_POINTER_NORMAL_GATE_OPEN", "contained": False}
    runner = runner or Runner()
    evidence: Path | None = None
    pointer: dict[str, Any] | None = None
    preimages: dict[str, Any] | None = None
    preserve_verified_updates = False
    validation_failure: str | None = None
    try:
        if ACTIVE_POINTER.is_symlink() or not ACTIVE_POINTER.is_file():
            raise CommissioningError("active transaction pointer is unsafe")
        if not root_file_metadata_is_exact(ACTIVE_POINTER.lstat(), 0o600):
            raise CommissioningError("active transaction pointer metadata differs")
        pointer = load_json_regular(ACTIVE_POINTER)
        evidence = Path(str(pointer.get("evidence", "")))
        evidence.relative_to(EVIDENCE_ROOT)
        preimages = validate_rollback_evidence(evidence, pointer)
        complete_path = evidence / "complete.json"
        if complete_path.exists() or complete_path.is_symlink():
            complete = validate_committed_transaction(evidence, pointer)
            service_map = preimages.get("serviceMap", {})
            preserve_verified_updates = (
                validate_committed_late_receipt(evidence, complete, service_map) is not None
            )
        runner.recovery_attempt(evidence)
    except BaseException as exc:
        validation_failure = type(exc).__name__ + ": " + str(exc)

    failures = contain_late_recovery_failure(
        runner,
        preserve_verified_update_infrastructure=preserve_verified_updates,
    )
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND + "-late-stop-post",
        "status": "CONTAINED_ACTIVE_POINTER_RETAINED"
        if not failures and validation_failure is None
        else "CONTAINMENT_INCOMPLETE_ACTIVE_POINTER_RETAINED",
        "transactionId": pointer.get("transactionId") if pointer else None,
        "planSha256": pointer.get("planSha256") if pointer else None,
        "validationFailure": validation_failure,
        "verifiedUpdateInfrastructurePreserved": preserve_verified_updates,
        "failures": failures,
        "recordedAtUtc": utc_now(),
    }
    if (
        evidence is not None
        and evidence.parent == EVIDENCE_ROOT
        and evidence.is_dir()
        and not evidence.is_symlink()
        and root_directory_metadata_is_exact(evidence.lstat(), 0o700)
    ):
        try:
            stop_post_path = evidence / "late-stop-post.json"
            if stop_post_path.exists() or stop_post_path.is_symlink():
                if stop_post_path.is_symlink() or not root_file_metadata_is_exact(
                    stop_post_path.lstat(), 0o600
                ):
                    raise CommissioningError("existing late stop-post receipt metadata differs")
                validate_existing_late_stop_post(
                    stop_post_path,
                    load_json_regular(stop_post_path),
                    evidence,
                    pointer or {},
                )
            receipt = atomic_json_with_lineage(
                stop_post_path,
                receipt,
                lineage_field="previousReceiptSha256",
            )
        except BaseException as exc:
            failures.append("record late stop-post: " + str(exc))
    if validation_failure is not None or failures:
        details = ([validation_failure] if validation_failure else []) + failures
        raise CommissioningError("late stop-post containment incomplete: " + "; ".join(details))
    return receipt


def resume_final_rollback(
    evidence: Path,
    pointer: Mapping[str, Any],
    preimages: Mapping[str, Any],
    receipt: Mapping[str, Any],
    runner: Runner,
) -> dict[str, Any]:
    """Resume only the post-receipt disarm without consuming retry budget."""

    runner.recovery_attempt(evidence)
    service_map = preimages.get("serviceMap", {})
    try:
        ensure_gate_authorizer_closed(runner)
        verify_restored_old_storage(runner, preimages)
        enablement_failures = restore_enablement_map(runner, service_map)
        if enablement_failures:
            raise CommissioningError("restore enablement: " + "; ".join(enablement_failures))
        start_and_verify_prior_active_units(
            runner,
            service_map,
            evidence=evidence,
            pointer=pointer,
        )
        update_failures = restore_update_infrastructure_map(
            runner,
            service_map,
            evidence=evidence,
            pointer=pointer,
        )
        if update_failures:
            raise CommissioningError("restore update infrastructure: " + "; ".join(update_failures))
        verify_update_infrastructure_map(runner, service_map)
    except BaseException as exc:
        containment = contain_late_recovery_failure(runner)
        failure = type(exc).__name__ + ": " + str(exc)
        if containment:
            failure += "; containment: " + "; ".join(containment)
        raise CommissioningError("final rollback receipt resume failed closed: " + failure) from exc
    finalize_gate_with_retry(runner, evidence, pointer, outcome="ROLLED_BACK")
    return dict(receipt)


def late_recover(
    evidence: Path,
    pointer: Mapping[str, Any],
    runner: Runner,
) -> dict[str, Any]:
    preimages = validate_rollback_evidence(evidence, pointer)
    validate_resume_pointer_binding(pointer)
    validate_early_recovery_ready(evidence, pointer, preimages)
    final_receipt = validate_final_rollback_receipt(
        evidence,
        pointer,
        preimages.get("serviceMap", {}),
    )
    if final_receipt is not None:
        return resume_final_rollback(evidence, pointer, preimages, final_receipt, runner)
    attempt, attempt_state = begin_late_recovery_attempt(evidence, pointer)
    runner.recovery_attempt(evidence)
    health: dict[str, Any] = {}
    try:
        ensure_gate_authorizer_closed(runner)
        verify_restored_old_storage(runner, preimages)
        enablement_failures = restore_enablement_map(
            runner,
            preimages.get("serviceMap", {}),
        )
        if enablement_failures:
            raise CommissioningError("restore enablement: " + "; ".join(enablement_failures))

        health["protectedUnits"] = start_and_verify_prior_active_units(
            runner,
            preimages.get("serviceMap", {}),
            evidence=evidence,
            pointer=pointer,
        )
        update_failures = restore_update_infrastructure_map(
            runner,
            preimages.get("serviceMap", {}),
            evidence=evidence,
            pointer=pointer,
        )
        if update_failures:
            raise CommissioningError("restore update infrastructure: " + "; ".join(update_failures))
        health["updateInfrastructure"] = verify_update_infrastructure_map(
            runner,
            preimages.get("serviceMap", {}),
        )

        plan_sha256 = str(pointer.get("planSha256", ""))
        existing = existing_rollback_receipt(evidence, plan_sha256)
        receipt = write_rollback_receipt(
            evidence,
            plan_sha256=plan_sha256,
            status="ROLLED_BACK",
            reason="LATE_RECOVERY_VERIFIED",
            failures=[],
            existing=existing,
            extra={
                "lateRecoveryRequired": False,
                "lateRecoveryAttempt": attempt,
                "health": health,
                "completedAtUtc": utc_now(),
            },
        )
        finish_late_recovery_attempt(evidence, attempt_state, status="SUCCEEDED", failure=None)
    except BaseException as exc:
        containment = contain_late_recovery_failure(runner)
        failure = type(exc).__name__ + ": " + str(exc)
        if containment:
            failure += "; containment: " + "; ".join(containment)
        try:
            finish_late_recovery_attempt(evidence, attempt_state, status="FAILED", failure=failure)
        except BaseException as state_exc:
            failure += "; record attempt: " + str(state_exc)
        raise CommissioningError(
            f"late recovery attempt {attempt}/{LATE_RECOVERY_ATTEMPTS} failed closed: {failure}"
        ) from exc
    # The active-pointer unlink is irreversible in the running namespace; do
    # not feed a later normal-gate failure back into old-storage containment.
    finalize_gate_with_retry(runner, evidence, pointer, outcome="ROLLED_BACK")
    return receipt


def recover_active(runner: Runner | None = None, *, phase: str = "manual") -> dict[str, Any]:
    require_root()
    if phase not in {"manual", "early", "late"}:
        raise CommissioningError("invalid recovery phase")
    runner = runner or Runner()
    if ACTIVE_POINTER.is_symlink() or not ACTIVE_POINTER.is_file():
        raise CommissioningError("active transaction pointer is absent or unsafe")
    if not root_file_metadata_is_exact(ACTIVE_POINTER.lstat(), 0o600):
        raise CommissioningError("active transaction pointer metadata differs")
    pointer = load_json_regular(ACTIVE_POINTER)
    evidence = Path(str(pointer.get("evidence", "")))
    try:
        evidence.relative_to(EVIDENCE_ROOT)
    except ValueError as exc:
        raise CommissioningError("active evidence path escapes fixed root") from exc
    if evidence.is_symlink() or not evidence.is_dir():
        raise CommissioningError("active evidence directory is unsafe")
    validate_rollback_evidence(evidence, pointer)
    validate_resume_pointer_binding(pointer)
    complete_path = evidence / "complete.json"
    if complete_path.exists() or complete_path.is_symlink():
        validate_committed_transaction(evidence, pointer)
        if phase == "late":
            return committed_late_finalize(evidence, pointer, runner)
        runner.run(
            [SYSTEMCTL, "restart", "--no-block", LATE_RESUME_TIMER.name],
            allowed=(0,),
            log_name="queue-committed-late-finalization",
        )
        return {
            "status": "COMMITTED_AWAITING_LIVE_LATE_FINALIZATION",
            "evidence": str(evidence),
            "activePointerRetained": True,
        }
    if phase == "late":
        return late_recover(evidence, pointer, runner)
    return rollback(evidence, runner, reason="EARLY_BOOT_OR_MANUAL_RECOVERY")


def locked_operation(callback: Any) -> Any:
    if fcntl is None:
        raise CommissioningError("the commissioning lock requires Linux")
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(fd)
        raise CommissioningError("another NVMe commissioning operation is active") from exc
    try:
        return callback()
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def print_json(value: Any) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("assess", help="root read-only host assessment; writes JSON only to stdout")
    plan_parser = subparsers.add_parser("plan", help="root inventory-only deterministic plan; writes JSON only to stdout")
    plan_parser.add_argument("--expected-hostname", required=True)
    apply_parser = subparsers.add_parser("apply", help="apply the currently eligible plan")
    apply_parser.add_argument("--expected-hostname", required=True)
    apply_parser.add_argument("--plan-sha256", required=True)
    apply_parser.add_argument("--confirm", required=True)
    apply_parser.add_argument("--storage-approval-reference", required=True)
    recover_parser = subparsers.add_parser("recover", help="recover the fixed active transaction")
    recovery_origin = recover_parser.add_mutually_exclusive_group()
    recovery_origin.add_argument("--from-systemd-early", action="store_true", help=argparse.SUPPRESS)
    recovery_origin.add_argument("--from-systemd-late", action="store_true", help=argparse.SUPPRESS)
    subparsers.add_parser("contain-late-failure", help=argparse.SUPPRESS)
    subparsers.add_parser("authorize-gate", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if args.command == "assess":
            print_json(assess())
            return 0
        if args.command == "plan":
            plan = build_plan(assess(), args.expected_hostname)
            print_json(plan)
            return 0 if plan["eligible"] else 2
        if args.command == "apply":
            require_root()

            def do_apply() -> dict[str, Any]:
                if ACTIVE_POINTER.exists() or ACTIVE_POINTER.is_symlink():
                    raise CommissioningError("an active transaction requires recover before apply")
                current_assessment = assess()
                current_plan = build_plan(current_assessment, args.expected_hostname)
                verify_plan_authorization(current_plan, args.plan_sha256, args.confirm)
                with MaintenanceLock():
                    locked_assessment = assess()
                    locked_plan = build_plan(locked_assessment, args.expected_hostname)
                    verify_plan_authorization(locked_plan, args.plan_sha256, args.confirm)
                    return Transaction(
                        Runner(),
                        locked_plan,
                        locked_assessment,
                        args.storage_approval_reference,
                    ).apply()

            print_json(locked_operation(do_apply))
            return 0
        if args.command == "recover":
            def do_recover() -> dict[str, Any]:
                with MaintenanceLock():
                    phase = "late" if args.from_systemd_late else "early" if args.from_systemd_early else "manual"
                    return recover_active(phase=phase)

            print_json(locked_operation(do_recover))
            return 0
        if args.command == "contain-late-failure":
            print_json(contain_active_late_failure())
            return 0
        if args.command == "authorize-gate":
            print_json(authorize_gate())
            return 0
    except CommissioningError as exc:
        sys.stderr.write(f"NVME_COMMISSIONING_REFUSED: {exc}\n")
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
