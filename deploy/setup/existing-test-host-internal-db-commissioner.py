#!/usr/bin/env python3
"""Commission an empty PostgreSQL 16 database for the internal-test release lane.

This is deliberately not a production database bootstrap.  It consumes one
root snapshot of the normal CI-signed release candidate and the committed NVMe
storage-only authority, migrates an empty disposable database, and publishes a
short-lived first-activation authority while every employee entry remains off.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import grp
import hashlib
import hmac
import json
import os
import pwd
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import signal
import time
import types
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn


UPDATER_MODULE = Path("/opt/uten-imp/updater/release_updater.py")
RELEASE_GUARD = Path("/opt/uten-imp/updater/release_guard.py")
DATABASE_RECOVERY_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/database_recovery_verifier.py"
)
SERVER_ENV = Path("/etc/uten-imp/server.env")
ALLOWED_SIGNERS = Path("/etc/uten-imp-release-trust/release-allowed-signers")
UPDATER_STATE = Path("/var/lib/uten-imp-updater")
RELEASES = Path("/opt/uten-imp/releases")
ROOT_STATE = Path("/var/lib/uten-imp-release")
RUNTIME_CONTRACT = ROOT_STATE / "internal-test-runtime-contract.json"
ONBOARDING_RECEIPT = ROOT_STATE / "internal-test-onboarding.json"
ACTIVATION_REAUTHORIZATION = (
    ROOT_STATE / "internal-test-activation-reauthorization.json"
)
ACTIVATION_REAUTHORIZATION_EVIDENCE = (
    ROOT_STATE / "internal-test-activation-reauthorization-evidence"
)
EVIDENCE_BASE = Path("/var/lib/uten-imp-internal-test-commissioning")
ACTIVE_POINTER = EVIDENCE_BASE / "active.json"
PREACTIVE_POINTER = EVIDENCE_BASE / "pre-active.json"
COMMISSIONING_AUTHORITY_NAME = "commissioning-authorized.json"
PREACTIVE_ARCHIVE_NAME = "pre-active.committed.json"
WORKER_REQUEST = EVIDENCE_BASE / "worker-request.json"
COMMISSIONER_UNIT = "uten-imp-internal-db-commissioner.service"
COMMISSIONER_UNIT_FILE = Path(
    "/etc/systemd/system/uten-imp-internal-db-commissioner.service"
)
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
HOST_PREPARATION_EVIDENCE = Path(
    "/var/lib/uten-imp-internal-test-host-preparation"
)
HOST_PREPARATION_ACTIVE = HOST_PREPARATION_EVIDENCE / "active.json"
HOST_PREPARATION_MUTATION_ACTIVE = HOST_PREPARATION_EVIDENCE / "mutation-active.json"
STORAGE_AUTHORITY = Path("/etc/uten-imp/storage-authority.json")
STORAGE_EVIDENCE_BASE = Path("/var/lib/uten-imp-nvme-commissioning")
NVME_ACTIVE_POINTER = STORAGE_EVIDENCE_BASE / "active.json"
STORAGE_BOOT_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/storage_boot_verifier.py"
)
INTERNAL_STORAGE_VALIDATOR = Path(
    "/usr/local/sbin/uten-imp-validate-internal-test-storage"
)
PGDATA = Path("/data/postgresql/16/main")
PG_PARENT = PGDATA.parent
SECRETS = Path("/etc/uten-imp-postgres")
APP_PASSWORD = SECRETS / "app.password"
MIGRATOR_PASSWORD = SECRETS / "migrator.password"
POSTGRES_UNIT = "postgresql@16-main.service"
POSTGRES_META_UNIT = "postgresql.service"
POSTGRES_START_CONF = Path("/etc/postgresql/16/main/start.conf")
POSTGRES_INTERNAL_TEST_CONF = Path(
    "/etc/postgresql/16/main/conf.d/99-uten-imp-internal-test.conf"
)
ENTRY_UNITS = (
    "uten-imp.service",
    "nginx.service",
    "uten-imp-watchdog.timer",
    "uten-imp-entry-watchdog.timer",
)
LEGACY_BACKUP_UNITS = (
    "uten-pgbackup-health.timer",
    "uten-pgbackup-health.service",
    "uten-pgbackup-alert-drain.timer",
    "uten-pgbackup-alert-drain.service",
    "uten-pgbackup-repo2.timer",
    "uten-pgbackup-repo2.service",
    "uten-pgbackup.timer",
    "uten-pgbackup.service",
)
APPROVAL_RE = re.compile(r"CHG-[A-Z0-9][A-Z0-9._-]{5,95}")
VERSION_RE = re.compile(r"v\d{4}\.\d{2}\.\d{2}-[1-9]\d{0,2}")
TRANSACTION_RE = re.compile(
    r"internal-test-db-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}"
)
SHA256_RE = re.compile(r"[0-9a-f]{64}")
PASSWORD_RE = re.compile(r"[A-Za-z0-9]{20,512}")
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_TRUSTED_MODULE_BYTES = 2 * 1024 * 1024
MAX_CANDIDATE_BUILD_ATTEMPTS = 3
MAX_RETAINED_CANDIDATE_BYTES = 8 * 1024 * 1024 * 1024
BOOT_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
UTC_RE = re.compile(
    r"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z"
)
WORKER_CGROUP = "/system.slice/uten-imp-internal-db-commissioner.service"
WORKER_RUNTIME = Path("/run/uten-imp-internal-db-commissioner")


class CommissioningError(RuntimeError):
    """A sanitized fail-closed commissioning refusal."""


def fail(message: str) -> NoReturn:
    raise CommissioningError(message)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        fail(f"{label} is not an exact UTC timestamp")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise CommissioningError(f"{label} is not a valid UTC timestamp") from exc


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _module_stat_fingerprint(details: os.stat_result) -> tuple[int, ...]:
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


def _module_parent_chain(path: Path, label: str) -> tuple[tuple[str, tuple[int, ...]], ...]:
    captured: list[tuple[str, tuple[int, ...]]] = []
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise CommissioningError(f"cannot inspect {label} parent chain") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail(f"{label} parent chain is not root controlled")
        captured.append((str(current), _module_stat_fingerprint(details)))
        if current == current.parent:
            return tuple(captured)
        current = current.parent


def _safe_module_stat(details: os.stat_result, mode: int) -> bool:
    return (
        stat.S_ISREG(details.st_mode)
        and not stat.S_ISLNK(details.st_mode)
        and details.st_uid == 0
        and details.st_gid == 0
        and details.st_nlink == 1
        and stat.S_IMODE(details.st_mode) == mode
        and 1 <= details.st_size <= MAX_TRUSTED_MODULE_BYTES
    )


def stable_root_module_bytes(
    path: Path,
    expected_sha256: str,
    label: str,
    *,
    mode: int = 0o644,
) -> bytes:
    """Capture one pinned module from a stable no-follow descriptor."""

    if (
        not path.is_absolute()
        or os.path.normpath(str(path)) != str(path)
        or SHA256_RE.fullmatch(expected_sha256) is None
    ):
        fail(f"{label} path or expected digest is malformed")
    if not hasattr(os, "O_NOFOLLOW"):
        fail("platform lacks mandatory no-follow module reads")
    parent_before = _module_parent_chain(path, label)
    try:
        live_before = path.lstat()
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as exc:
        raise CommissioningError(f"cannot open {label} safely") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not _safe_module_stat(live_before, mode)
            or not _safe_module_stat(opened, mode)
            or _module_stat_fingerprint(opened)
            != _module_stat_fingerprint(live_before)
        ):
            fail(f"{label} is not one immutable root-owned module")
        digest = hashlib.sha256()
        payload = bytearray()
        while True:
            try:
                block = os.read(descriptor, 64 * 1024)
            except OSError as exc:
                raise CommissioningError(f"cannot read {label} descriptor") from exc
            if not block:
                break
            payload.extend(block)
            if len(payload) > MAX_TRUSTED_MODULE_BYTES:
                fail(f"{label} exceeded the fixed size limit")
            digest.update(block)
        after = os.fstat(descriptor)
        try:
            live_after = path.lstat()
        except OSError as exc:
            raise CommissioningError(f"{label} pathname changed while reading") from exc
        if (
            _module_stat_fingerprint(after) != _module_stat_fingerprint(opened)
            or _module_stat_fingerprint(live_after)
            != _module_stat_fingerprint(opened)
            or _module_parent_chain(path, label) != parent_before
            or len(payload) != opened.st_size
        ):
            fail(f"{label} changed while reading")
        if digest.hexdigest() != expected_sha256:
            fail(f"{label} differs from the runtime-contract SHA-256")
        return bytes(payload)
    finally:
        os.close(descriptor)


def _execute_verified_module(
    payload: bytes,
    path: Path,
    name: str,
    *,
    injected_globals: dict[str, Any] | None = None,
) -> Any:
    """Execute only bytes already authenticated by stable_root_module_bytes."""

    try:
        code = compile(payload, str(path), "exec", dont_inherit=True)
    except (SyntaxError, ValueError) as exc:
        raise CommissioningError(f"verified module cannot be compiled: {path}") from exc
    module = types.ModuleType(name)
    module.__file__ = str(path)
    module.__package__ = ""
    module.__cached__ = None
    module.__spec__ = None
    if injected_globals:
        if any(key.startswith("__") for key in injected_globals):
            fail("verified module injection attempted to replace interpreter metadata")
        module.__dict__.update(injected_globals)
    exec(code, module.__dict__, module.__dict__)
    return module


def _execute_verified_updater(payload: bytes, guard: Any) -> Any:
    updater = _execute_verified_module(
        payload,
        UPDATER_MODULE,
        "uten_imp_internal_commissioning_updater",
        injected_globals={"_UTEN_PREVERIFIED_RELEASE_GUARD": guard},
    )
    if updater.release_guard is not guard:
        fail("verified updater did not bind the preverified release guard")
    return updater


def fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def durable_unlink(path: Path) -> None:
    path.unlink()
    fsync_directory(path.parent)


def require_root_directory(path: Path, *, mode: int | None = None) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise CommissioningError(f"required directory is missing: {path}") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        fail(f"root-controlled directory is unsafe: {path}")
    return details


def require_root_file(
    path: Path, *, mode: int | None = None, group: int | None = 0
) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise CommissioningError(f"required file is missing: {path}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or (group is not None and details.st_gid != group)
        or details.st_nlink != 1
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        fail(f"root-controlled file is unsafe: {path}")
    return details


def strict_json(path: Path, label: str, *, mode: int = 0o600) -> dict[str, Any]:
    require_root_file(path, mode=mode)
    raw = path.read_bytes()
    if not 1 <= len(raw) <= MAX_JSON_BYTES or b"\0" in raw:
        fail(f"{label} size is outside the reviewed range")

    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if key in result:
                fail(f"{label} contains a duplicate key")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda constant: fail(
                f"{label} contains non-finite JSON: {constant}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CommissioningError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} root is not an object")
    return value


def atomic_bytes(path: Path, raw: bytes, *, replace: bool = False) -> None:
    require_root_directory(path.parent)
    temporary = path.parent / f".{path.name}.incoming-{os.getpid()}-{secrets.token_hex(6)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            if written <= 0:
                fail(f"evidence temporary write made no progress: {temporary}")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chown(temporary, 0, 0)
    os.chmod(temporary, 0o600)
    if not replace and os.path.lexists(path):
        temporary.unlink()
        fail(f"evidence already exists: {path}")
    os.replace(temporary, path)
    fsync_directory(path.parent)


def atomic_json(path: Path, value: Any, *, replace: bool = False) -> None:
    atomic_bytes(path, canonical_bytes(value), replace=replace)


def run(
    command: list[str],
    *,
    input_bytes: bytes | None = None,
    allowed: tuple[int, ...] = (0,),
    timeout: int = 600,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=(
                {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"}
                if environment is None
                else environment
            ),
            start_new_session=True,
        )
        stdout, stderr = process.communicate(input=input_bytes, timeout=timeout)
        completed = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    except (OSError, subprocess.TimeoutExpired) as exc:
        if process is not None and process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            with contextlib.suppress(Exception):
                process.wait(timeout=10)
        raise CommissioningError(f"fixed command could not complete: {command[0]}") from exc
    except BaseException:
        if process is not None and process.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            with contextlib.suppress(Exception):
                process.wait(timeout=10)
        raise
    if completed.returncode not in allowed:
        fail(f"fixed command failed closed: {command[0]}")
    return completed


def systemd_state(unit: str, property_name: str) -> str:
    completed = run(
        ["/usr/bin/systemctl", "show", unit, f"--property={property_name}", "--value"],
        allowed=(0, 1),
    )
    if completed.returncode != 0:
        fail(f"required systemd unit is unavailable: {unit}")
    return completed.stdout.decode("utf-8", errors="strict").strip()


def require_employee_ports_closed() -> None:
    """Prove TCP and UDP/QUIC employee entry ports have no listener."""

    protected = {80, 443, 8080, 8081}
    for protocol, command in (
        ("TCP", ["/usr/bin/ss", "-H", "-ltnp"]),
        ("UDP", ["/usr/bin/ss", "-H", "-lunp"]),
    ):
        raw = run(command).stdout
        if len(raw) > 1024 * 1024:
            fail(f"live {protocol} listener observation is unexpectedly large")
        try:
            lines = raw.decode("ascii", errors="strict").splitlines()
        except UnicodeDecodeError as exc:
            raise CommissioningError(
                f"live {protocol} listener observation is not canonical ASCII"
            ) from exc
        for line in lines:
            columns = line.split(None, 5)
            expected_state = "LISTEN" if protocol == "TCP" else "UNCONN"
            if len(columns) < 5 or columns[0] != expected_state:
                fail(f"live {protocol} listener observation is malformed")
            try:
                port_text = columns[3].rsplit(":", 1)[1]
                if not port_text.isdigit() or port_text != str(int(port_text)):
                    raise ValueError
                port = int(port_text)
            except (IndexError, ValueError) as exc:
                raise CommissioningError(
                    f"live {protocol} listener endpoint is malformed"
                ) from exc
            if port in protected:
                fail(f"employee-facing {protocol} port is still listening: {port}")


def require_entry_closed() -> None:
    for unit in ENTRY_UNITS:
        if systemd_state(unit, "ActiveState") not in {"inactive", "failed"}:
            fail(f"employee entry unit must be inactive: {unit}")
        enabled = systemd_state(unit, "UnitFileState")
        if enabled not in {"disabled", "static", "masked"}:
            fail(f"employee entry unit must not be boot-enabled: {unit}")
    for marker in (
        ROOT_STATE / "active.json",
        ROOT_STATE / "runtime-authority.json",
        ROOT_STATE / "activation-in-progress.json",
        ROOT_STATE / "boot-enablement-in-progress.json",
        ROOT_STATE / "recovery-in-progress.json",
        ROOT_STATE / "activation-failed.json",
    ):
        if os.path.lexists(marker):
            fail(f"release state already exists and forbids database commissioning: {marker.name}")
    if os.path.lexists(Path("/opt/uten-imp/current")):
        fail("current release must not be published by database commissioning")
    require_employee_ports_closed()
    for unit in LEGACY_BACKUP_UNITS:
        if systemd_state(unit, "ActiveState") not in {"inactive", "failed"}:
            fail(f"legacy backup unit must be inactive for the new cluster: {unit}")
        if systemd_state(unit, "UnitFileState") not in {
            "disabled",
            "static",
            "indirect",
            "masked",
        }:
            fail(f"legacy backup unit must be disabled for the new cluster: {unit}")


def load_modules(runtime_contract_value: dict[str, Any]) -> tuple[Any, Any]:
    updater_bytes = stable_root_module_bytes(
        UPDATER_MODULE,
        str(runtime_contract_value.get("releaseUpdaterSha256", "")),
        "installed release updater",
    )
    guard_bytes = stable_root_module_bytes(
        RELEASE_GUARD,
        str(runtime_contract_value.get("updaterReleaseGuardSha256", "")),
        "installed release guard",
    )
    # Authenticate both modules before executing either.  The updater's own
    # top-level guard import is then constrained to this exact captured module.
    guard = _execute_verified_module(
        guard_bytes,
        RELEASE_GUARD,
        "uten_imp_internal_commissioning_guard",
    )
    updater = _execute_verified_updater(updater_bytes, guard)
    return updater, guard


def validate_host_preparation_terminal(expected_contract_sha256: str) -> dict[str, Any]:
    """Consume the final, entry-closed host preparation transaction.

    The mutation authority is committed by a same-filesystem rename.  Its
    bytes intentionally keep the authorization status; only the fixed
    committed pathname, and the complete/active receipts that bind its hash,
    make it terminal.  A live pathname or two-path state is therefore refused.
    """
    if os.path.lexists(HOST_PREPARATION_MUTATION_ACTIVE):
        fail("host preparation mutation is still active")
    host_terminal = strict_json(
        HOST_PREPARATION_ACTIVE, "host preparation terminal"
    )
    if (
        set(host_terminal)
        != {
            "contractSha256",
            "entryEnabled",
            "kind",
            "mutationAuthorityPath",
            "mutationAuthoritySha256",
            "nginxEnabledLink",
            "nginxEnabledTargetSha256",
            "planSha256",
            "productionAuthority",
            "schemaVersion",
            "status",
            "transactionId",
        }
        or host_terminal.get("schemaVersion") != 1
        or host_terminal.get("kind")
        != "uten-imp-internal-test-host-preparation-receipt"
        or host_terminal.get("status") != "COMMITTED_ENTRY_CLOSED"
        or host_terminal.get("entryEnabled") is not False
        or host_terminal.get("productionAuthority") is not False
        or host_terminal.get("contractSha256") != expected_contract_sha256
        or not isinstance(host_terminal.get("transactionId"), str)
        or not re.fullmatch(
            r"prepare-internal-runtime-[0-9a-f]{16}",
            host_terminal["transactionId"],
        )
    ):
        fail("host preparation terminal does not bind the runtime contract")
    for key in (
        "contractSha256",
        "mutationAuthoritySha256",
        "nginxEnabledTargetSha256",
        "planSha256",
    ):
        if not isinstance(host_terminal.get(key), str) or not SHA256_RE.fullmatch(
            host_terminal[key]
        ):
            fail(f"host preparation terminal digest is malformed: {key}")

    host_complete = (
        HOST_PREPARATION_EVIDENCE
        / host_terminal["transactionId"]
        / "complete.json"
    )
    if host_complete.parent.parent != HOST_PREPARATION_EVIDENCE:
        fail("host preparation receipt escaped its evidence root")
    if strict_json(host_complete, "host preparation receipt") != host_terminal:
        fail("host preparation complete/active receipts differ")

    mutation_committed = host_complete.parent / "mutation-authorized.committed.json"
    if host_terminal.get("mutationAuthorityPath") != str(mutation_committed):
        fail("host preparation terminal names another mutation authority")
    require_root_file(mutation_committed, mode=0o600)
    if sha256_file(mutation_committed) != host_terminal["mutationAuthoritySha256"]:
        fail("host mutation terminal digest changed")
    mutation = strict_json(mutation_committed, "host mutation terminal")
    if (
        set(mutation)
        != {
            "authorizedAtUtc",
            "kind",
            "planPath",
            "planSha256",
            "reviewedSourceManifestSha256",
            "schemaVersion",
            "snapshotInventorySha256",
            "status",
            "transactionId",
        }
        or mutation.get("schemaVersion") != 1
        or mutation.get("kind")
        != "uten-imp-internal-test-host-mutation-authority"
        or mutation.get("status") != "MUTATION_AUTHORIZED_ENTRY_CLOSED"
        or mutation.get("transactionId") != host_terminal["transactionId"]
        or mutation.get("planSha256") != host_terminal["planSha256"]
        or mutation.get("planPath") != str(host_complete.parent / "plan.json")
    ):
        fail("host mutation terminal is missing or belongs to another plan")
    for key in (
        "planSha256",
        "reviewedSourceManifestSha256",
        "snapshotInventorySha256",
    ):
        if not isinstance(mutation.get(key), str) or not SHA256_RE.fullmatch(
            mutation[key]
        ):
            fail(f"host mutation terminal digest is malformed: {key}")

    plan_path = host_complete.parent / "plan.json"
    require_root_file(plan_path, mode=0o600)
    if sha256_file(plan_path) != mutation["planSha256"]:
        fail("host preparation plan changed after mutation authorization")
    plan = strict_json(plan_path, "host preparation plan")
    if (
        plan.get("schemaVersion") != 1
        or plan.get("kind") != "uten-imp-internal-test-host-preparation-plan"
        or plan.get("status") != "APPROVED_ENTRY_CLOSED"
        or plan.get("entryEnabled") is not False
        or plan.get("transactionId") != host_terminal["transactionId"]
        or plan.get("reviewedSourceManifestSha256")
        != mutation["reviewedSourceManifestSha256"]
        or plan.get("reviewedSourceManifestPath")
        != str(host_complete.parent / "reviewed-source-manifest.json")
        or plan.get("sourceSnapshotPath")
        != str(host_complete.parent / "source-snapshot")
        or not isinstance(plan.get("sourceSha256"), dict)
    ):
        fail("host preparation plan/source binding changed")
    reviewed_path = host_complete.parent / "reviewed-source-manifest.json"
    require_root_file(reviewed_path, mode=0o600)
    if sha256_file(reviewed_path) != mutation["reviewedSourceManifestSha256"]:
        fail("host preparation reviewed source manifest digest changed")
    reviewed = strict_json(reviewed_path, "host preparation reviewed source manifest")
    if set(reviewed) != {
        "approvalReference",
        "builderSha256",
        "createdAtUtc",
        "expiresAtUtc",
        "hostParameters",
        "kind",
        "preparerSha256",
        "schemaVersion",
        "sourceSha256",
        "targetPreimageSha256",
    } or (
        reviewed.get("schemaVersion") != 1
        or reviewed.get("kind")
        != "uten-imp-internal-test-reviewed-host-sources"
        or reviewed.get("approvalReference") != plan.get("approvalReference")
        or reviewed.get("sourceSha256") != plan.get("sourceSha256")
        or reviewed.get("builderSha256")
        != reviewed.get("sourceSha256", {}).get("manifestBuilderSha256")
    ):
        fail("host preparation reviewed source manifest differs")
    reviewed_created = parse_utc(
        reviewed.get("createdAtUtc"), "host review creation time"
    )
    reviewed_expires = parse_utc(
        reviewed.get("expiresAtUtc"), "host review expiry time"
    )
    mutation_authorized = parse_utc(
        mutation.get("authorizedAtUtc"), "host mutation authorization time"
    )
    if (
        reviewed_expires <= reviewed_created
        or reviewed_expires > reviewed_created + timedelta(days=7)
        or not reviewed_created <= mutation_authorized < reviewed_expires
    ):
        fail("host mutation was not authorized inside its reviewed window")
    snapshot_dir = host_complete.parent / "source-snapshot"
    require_root_directory(snapshot_dir, mode=0o700)
    if set(path.name for path in snapshot_dir.iterdir()) != set(plan["sourceSha256"]):
        fail("host preparation source snapshot inventory changed")
    snapshot_inventory: dict[str, str] = {}
    for key, expected in sorted(plan["sourceSha256"].items()):
        if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected):
            fail("host preparation source digest is malformed")
        snapshot = snapshot_dir / key
        require_root_file(snapshot, mode=0o600)
        actual = sha256_file(snapshot)
        if actual != expected:
            fail("host preparation source snapshot changed")
        snapshot_inventory[key] = actual
    if hashlib.sha256(canonical_bytes(snapshot_inventory)).hexdigest() != mutation[
        "snapshotInventorySha256"
    ]:
        fail("host mutation terminal names another source inventory")
    return host_terminal


def bootstrap_runtime_contract() -> tuple[dict[str, Any], str]:
    """Authenticate the code that will later perform the complete contract check.

    The installed updater cannot be allowed to import and then vouch for itself.
    This deliberately small bootstrap reads the root authority without executing
    either installed Python module and pins both imported files plus the stable
    database verifier and this commissioner.
    """
    contract = strict_json(RUNTIME_CONTRACT, "internal-test runtime contract")
    expected_keys = {
        "activationEntrypointSha256",
        "attachmentLayoutReceiptPath",
        "attachmentLayoutReceiptSha256",
        "backupContainmentReceiptPath",
        "backupContainmentReceiptSha256",
        "contractId",
        "databaseCommissionerSha256",
        "databaseCommissionerUnitSha256",
        "databaseRecoveryVerifierSha256",
        "deploymentProfile",
        "environmentValidatorSha256",
        "entryWatchdogScriptSha256",
        "entryWatchdogServiceUnitSha256",
        "entryWatchdogTimerUnitSha256",
        "evidenceLayoutReceiptPath",
        "evidenceLayoutReceiptSha256",
        "internalDomain",
        "migrationAuthorizationHelperSha256",
        "migrationServiceUnitSha256",
        "migratorEnvironmentValidatorSha256",
        "legacyNginxArchivePath",
        "legacyNginxArchiveSha256",
        "legacyNginxHandoffReceiptPath",
        "legacyNginxHandoffReceiptSha256",
        "nginxConfigSha256",
        "nginxExpandedConfigSha256",
        "nginxReadinessGateSha256",
        "nginxSystemdDropinSha256",
        "postgresInternalTestConfigSha256",
        "postgresHbaSha256",
        "postgresStorageDropinSha256",
        "recordedAtUtc",
        "recoveryEntrypointSha256",
        "releaseGuardSha256",
        "releaseUpdaterSha256",
        "runtimeBootVerifierSha256",
        "recoveryCommitBootVerifierSha256",
        "recoveryCommitBootUnitSha256",
        "recoveryIngressGateSha256",
        "schemaVersion",
        "serverEnvironmentBridgeReceiptPath",
        "serverEnvironmentBridgeReceiptSha256",
        "serverEnvironmentSha256",
        "serviceUnitSha256",
        "storageBootVerifierSha256",
        "storageMountObserverSha256",
        "storageObserverUnitSha256",
        "storageAuthoritySha256",
        "storageCompleteReceiptPath",
        "storageCompleteReceiptSha256",
        "storageLateFinalizationReceiptPath",
        "storageLateFinalizationReceiptSha256",
        "storageValidatorSha256",
        "tlsCertificatePath",
        "tlsCertificateSha256",
        "tlsKeyPath",
        "tlsKeySha256",
        "stableAllowedSignersSha256",
        "updaterAllowedSignersSha256",
        "updaterEntrypointSha256",
        "updaterEnvironmentValidatorSha256",
        "updaterOssIoSha256",
        "updaterReleaseGuardSha256",
        "updaterServiceUnitSha256",
        "updaterSubstrateReceiptPath",
        "updaterSubstrateReceiptSha256",
        "updaterTimerUnitSha256",
        "updaterRequirementsLockSha256",
        "updaterVenvInventorySha256",
        "watchdogScriptSha256",
        "watchdogServiceUnitSha256",
        "watchdogTimerUnitSha256",
        "wheelhouseSupplyChainSha256",
    }
    if (
        set(contract) != expected_keys
        or contract.get("schemaVersion") != 1
        or isinstance(contract.get("schemaVersion"), bool)
        or contract.get("contractId") != "uten-imp-internal-test-runtime-v1"
        or contract.get("deploymentProfile") != "internal-test-local-v1"
    ):
        fail("bootstrap runtime contract schema/profile is unsupported")
    pinned = {
        "databaseCommissionerSha256": Path(__file__).resolve(),
        "databaseRecoveryVerifierSha256": DATABASE_RECOVERY_VERIFIER,
        "releaseUpdaterSha256": UPDATER_MODULE,
        "serverEnvironmentSha256": SERVER_ENV,
        "updaterReleaseGuardSha256": RELEASE_GUARD,
    }
    for key, path in pinned.items():
        require_root_file(
            path,
            mode=0o755 if key == "databaseCommissionerSha256" else None,
            group=None if key == "serverEnvironmentSha256" else 0,
        )
        expected = contract.get(key)
        if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected):
            fail(f"bootstrap runtime contract digest is malformed: {key}")
        if sha256_file(path) != expected:
            fail(f"bootstrap runtime contract file changed: {path}")
    try:
        environment = SERVER_ENV.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise CommissioningError("internal-test server environment is unreadable") from exc
    profiles = [
        line.removeprefix("UTEN_PROFILE=")
        for line in environment.splitlines()
        if line.startswith("UTEN_PROFILE=")
    ]
    if profiles != ["internal-test"]:
        fail("bootstrap runtime profile is not uniquely internal-test")
    if contract.get("storageAuthoritySha256") != sha256_file(STORAGE_AUTHORITY):
        fail("bootstrap runtime contract names another storage authority")
    validate_host_preparation_terminal(sha256_file(RUNTIME_CONTRACT))
    for path_key, sha_key, expected_name in (
        ("storageCompleteReceiptPath", "storageCompleteReceiptSha256", "complete.json"),
        (
            "storageLateFinalizationReceiptPath",
            "storageLateFinalizationReceiptSha256",
            "late-committed-finalization.json",
        ),
    ):
        path = Path(str(contract.get(path_key, "")))
        if path.parent.parent != STORAGE_EVIDENCE_BASE or path.name != expected_name:
            fail("bootstrap storage terminal path escaped its fixed transaction")
        require_root_directory(path.parent, mode=0o700)
        require_root_file(path, mode=0o600)
        if (
            not isinstance(contract.get(sha_key), str)
            or not SHA256_RE.fullmatch(contract[sha_key])
            or sha256_file(path) != contract[sha_key]
        ):
            fail(f"bootstrap storage terminal digest changed: {sha_key}")
    for path_key, sha_key in (
        ("attachmentLayoutReceiptPath", "attachmentLayoutReceiptSha256"),
        ("backupContainmentReceiptPath", "backupContainmentReceiptSha256"),
    ):
        path = Path(str(contract.get(path_key, "")))
        if path.parent.parent != Path(
            "/var/lib/uten-imp-internal-test-host-preparation"
        ):
            fail("bootstrap host preparation receipt escaped its evidence root")
        require_root_file(path, mode=0o600)
        if contract.get(sha_key) != sha256_file(path):
            fail("bootstrap host preparation receipt changed")
    return contract, sha256_file(RUNTIME_CONTRACT)


def storage_receipt() -> tuple[Path, dict[str, Any], str]:
    require_root_directory(STORAGE_EVIDENCE_BASE)
    if os.path.lexists(NVME_ACTIVE_POINTER):
        fail("NVMe commissioning active pointer remains; storage is not terminal")
    require_root_file(STORAGE_AUTHORITY, mode=0o640)
    authority = strict_json(STORAGE_AUTHORITY, "storage authority", mode=0o640)
    if authority.get("schemaVersion") != 3:
        fail("internal-test database requires the v3 NVMe storage authority")
    candidates: list[tuple[Path, dict[str, Any], str]] = []
    for path in sorted(STORAGE_EVIDENCE_BASE.glob("nvme-*/complete.json")):
        try:
            require_root_directory(path.parent, mode=0o700)
            value = strict_json(path, "storage commissioning receipt")
        except CommissioningError:
            continue
        if (
            value.get("status") == "COMMITTED_STORAGE_ONLY"
            and value.get("authorityPath") == str(STORAGE_AUTHORITY)
            and value.get("authoritySha256") == sha256_file(STORAGE_AUTHORITY)
            and value.get("postgresInitialized") is False
            and value.get("postgresEnabled") is False
            and value.get("backupCommissioned") is False
            and value.get("entryEnabled") is False
            and value.get("transactionId") == path.parent.name
            and authority.get("commissioningEvidenceSha256")
            == value.get("commissioningEvidenceSha256")
            and authority.get("dataUuid") == str(value.get("filesystemUuid", "")).lower()
        ):
            candidates.append((path, value, sha256_file(path)))
    if len(candidates) != 1:
        fail("exactly one committed v3 storage-only receipt must match the live authority")
    return candidates[0]


def validate_storage_terminal_contract(
    contract: dict[str, Any],
    complete_path: Path,
    complete: dict[str, Any],
) -> None:
    late_path = complete_path.parent / "late-committed-finalization.json"
    if (
        contract.get("storageCompleteReceiptPath") != str(complete_path)
        or contract.get("storageLateFinalizationReceiptPath") != str(late_path)
        or contract.get("storageCompleteReceiptSha256") != sha256_file(complete_path)
    ):
        fail("runtime contract names another storage terminal")
    late = strict_json(late_path, "NVMe late finalization receipt")
    if (
        contract.get("storageLateFinalizationReceiptSha256") != sha256_file(late_path)
        or late.get("status") != "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED"
        or late.get("transactionId") != complete.get("transactionId")
        or late.get("authoritySha256") != complete.get("authoritySha256")
        or late.get("osUpdateInfrastructureRestored") is not True
        or os.path.lexists(NVME_ACTIVE_POINTER)
    ):
        fail("NVMe storage late finalization is missing, stale or still armed")


def _strict_json_bytes(raw: bytes, label: str) -> dict[str, Any]:
    if not 1 <= len(raw) <= MAX_JSON_BYTES or b"\0" in raw:
        fail(f"{label} size is outside the reviewed range")

    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if key in result:
                fail(f"{label} contains a duplicate key")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda constant: fail(
                f"{label} contains non-finite JSON: {constant}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CommissioningError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} root is not an object")
    return value


def verify_live_storage(
    contract: dict[str, Any],
    storage_receipt_path: Path,
    storage_receipt_sha256: str,
) -> dict[str, Any]:
    require_root_file(STORAGE_BOOT_VERIFIER, mode=0o644)
    require_root_file(INTERNAL_STORAGE_VALIDATOR, mode=0o755)
    if (
        sha256_file(STORAGE_BOOT_VERIFIER)
        != contract.get("storageBootVerifierSha256")
        or sha256_file(INTERNAL_STORAGE_VALIDATOR)
        != contract.get("storageValidatorSha256")
    ):
        fail("live storage verifiers differ from the runtime contract")
    verifier = run(
        ["/usr/bin/python3", "-I", str(STORAGE_BOOT_VERIFIER)], timeout=120
    )
    validator = run([str(INTERNAL_STORAGE_VALIDATOR)], timeout=120)
    findmnt = run(
        [
            "/usr/bin/findmnt",
            "--json",
            "--output",
            "SOURCE,FSTYPE,OPTIONS,UUID,TARGET",
            "--target",
            "/data",
        ]
    )
    try:
        mount = _strict_json_bytes(
            findmnt.stdout, "live storage mount observation"
        )["filesystems"]
    except (KeyError, TypeError) as exc:
        raise CommissioningError("live storage mount observation is malformed") from exc
    if not isinstance(mount, list) or len(mount) != 1:
        fail("live storage mount observation is ambiguous")
    value = mount[0]
    authority = strict_json(STORAGE_AUTHORITY, "storage authority", mode=0o640)
    receipt = strict_json(
        storage_receipt_path, "storage commissioning receipt"
    )
    if sha256_file(storage_receipt_path) != storage_receipt_sha256:
        fail("storage commissioning receipt changed during live verification")
    options = set(str(value.get("options", "")).split(","))
    source = Path(str(value.get("source", "")))
    authority_source = Path(str(authority.get("dataSource", "")))
    try:
        source_details = source.stat()
        authority_details = authority_source.stat()
    except OSError as exc:
        raise CommissioningError("live storage block identity is unavailable") from exc
    if (
        not stat.S_ISBLK(source_details.st_mode)
        or not stat.S_ISBLK(authority_details.st_mode)
        or source_details.st_rdev != authority_details.st_rdev
    ):
        fail("mounted /data source differs from the authority block identity")
    rdev = f"{os.major(source_details.st_rdev)}:{os.minor(source_details.st_rdev)}"
    if (
        value.get("target") != "/data"
        or value.get("fstype") != "ext4"
        or str(value.get("uuid", "")).lower() != authority.get("dataUuid")
        or not {"rw", "nodev", "nosuid", "noexec"}.issubset(options)
    ):
        fail("live /data mount differs from the v3 authority")
    boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(
        encoding="ascii"
    ).strip()
    if not BOOT_ID_RE.fullmatch(boot_id):
        fail("live boot identity is malformed")
    return {
        "authoritySha256": sha256_file(STORAGE_AUTHORITY),
        "authorityCommissioningEvidenceSha256": authority[
            "commissioningEvidenceSha256"
        ],
        "bootId": boot_id,
        "findmntOutputSha256": sha256_bytes(findmnt.stdout),
        "filesystemUuid": authority["dataUuid"],
        "mountedSourceRdev": rdev,
        "storageBootVerifierOutputSha256": sha256_bytes(verifier.stdout),
        "storageBootVerifierSha256": sha256_file(STORAGE_BOOT_VERIFIER),
        "storageCommissioningPlanSha256": receipt["planSha256"],
        "storageCommissioningReceiptSha256": storage_receipt_sha256,
        "storageValidatorOutputSha256": sha256_bytes(validator.stdout),
        "storageValidatorSha256": sha256_file(INTERNAL_STORAGE_VALIDATOR),
        "verifiedAtUtc": utc_now(),
    }


def write_storage_observation(
    evidence: Path,
    phase: str,
    observation: dict[str, Any],
) -> tuple[Path, str]:
    allowed_phases = {
        "before-plan",
        "before-initdb",
        "before-postgres",
        "before-terminal",
        "resume-terminal",
    }
    if phase not in allowed_phases:
        fail("storage observation phase is unsupported")
    require_root_directory(evidence, mode=0o700)
    boot_id = observation.get("bootId")
    if not isinstance(boot_id, str) or not BOOT_ID_RE.fullmatch(boot_id):
        fail("storage observation boot identity is malformed")
    prefix = f"storage-{phase}-{boot_id}-"
    numbered: list[int] = []
    for candidate in evidence.glob(prefix + "*.json"):
        match = re.fullmatch(re.escape(prefix) + r"([1-9][0-9]*)\.json", candidate.name)
        if match is None:
            fail("storage observation namespace contains an unexpected entry")
        strict_json(candidate, "existing storage observation")
        numbered.append(int(match.group(1)))
    sequence = max(numbered, default=0) + 1
    if sequence > 1000:
        fail("storage observation sequence exceeds the reviewed limit")
    value = {
        **observation,
        "kind": "uten-imp-internal-test-live-storage-observation",
        "phase": phase,
        "schemaVersion": 1,
        "sequence": sequence,
        "transactionId": evidence.name,
    }
    path = evidence / f"{prefix}{sequence}.json"
    atomic_json(path, value)
    return path, sha256_file(path)


def validate_storage_observation_binding(
    evidence: Path,
    binding: Any,
    *,
    phase: str | None = None,
) -> dict[str, Any]:
    if not isinstance(binding, dict) or set(binding) != {"path", "sha256"}:
        fail("storage observation binding schema is unsupported")
    path = Path(str(binding.get("path", "")))
    if path.parent != evidence or not re.fullmatch(
        r"storage-[a-z-]+-[0-9a-f-]{36}-[1-9][0-9]*\.json", path.name
    ):
        fail("storage observation escaped the fixed transaction path")
    value = strict_json(path, "bound storage observation")
    digest = binding.get("sha256")
    if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
        fail("storage observation binding digest is malformed")
    if (
        sha256_file(path) != digest
        or value.get("kind") != "uten-imp-internal-test-live-storage-observation"
        or value.get("schemaVersion") != 1
        or value.get("transactionId") != evidence.name
        or (phase is not None and value.get("phase") != phase)
    ):
        fail("storage observation binding changed")
    return value


def commissioner_sha256() -> str:
    executable = Path(__file__).resolve()
    require_root_file(executable, mode=0o755)
    return sha256_file(executable)


def runtime_contract(
    updater: Any,
    bootstrap: tuple[dict[str, Any], str],
) -> tuple[dict[str, Any], str]:
    if updater.deployment_profile() != "internal-test":
        fail("database commissioner is valid only for the internal-test profile")
    contract, digest = updater.internal_test_runtime_contract()
    if (contract, digest) != bootstrap:
        fail("complete runtime contract verification differs from bootstrap authority")
    if (
        contract.get("deploymentProfile") != "internal-test-local-v1"
        or contract.get("databaseCommissionerSha256") != commissioner_sha256()
    ):
        fail("runtime contract does not pin this database commissioner")
    return contract, digest


def secret_value(path: Path) -> str:
    postgres_gid = grp.getgrnam("postgres").gr_gid
    require_root_file(path, mode=0o640, group=postgres_gid)
    try:
        value = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise CommissioningError("PostgreSQL credential is unreadable") from exc
    if not PASSWORD_RE.fullmatch(value):
        fail("PostgreSQL credential is outside the reviewed format")
    return value


def environment_value(path: Path, key: str) -> str:
    require_root_file(path, group=None)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise CommissioningError("server environment is unreadable") from exc
    matches = [line.split("=", 1)[1] for line in lines if line.startswith(key + "=")]
    if len(matches) != 1:
        fail(f"server environment has no unique {key}")
    return matches[0]


def verify_runtime_secret_binding() -> tuple[str, str]:
    """Read and compare reviewed runtime secrets without exposing their values."""

    app_password = secret_value(APP_PASSWORD)
    configured_app_password = environment_value(SERVER_ENV, "UTEN_DB_PASSWORD")
    if not hmac.compare_digest(app_password, configured_app_password):
        fail("application database secret differs from the runtime environment")
    migrator_password = secret_value(MIGRATOR_PASSWORD)
    return app_password, migrator_password


def verify_database_credentials() -> None:
    """Prove both loopback SCRAM credentials without exposing their values."""

    app_password, migrator_password = verify_runtime_secret_binding()
    probes = (
        ("uten", app_password),
        ("uten_migrator", migrator_password),
    )
    configured_app_password = ""
    app_password = ""
    migrator_password = ""
    for role, password in probes:
        run(
            [
                "/usr/bin/psql",
                "-X",
                "-q",
                "-A",
                "-t",
                "--no-password",
                "-h",
                "127.0.0.1",
                "-p",
                "5432",
                "-U",
                role,
                "-d",
                "uten_imp",
                "-c",
                "SELECT 1",
            ],
            environment={
                "HOME": "/nonexistent",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/bin:/bin",
                "PGAPPNAME": "uten-imp-internal-test-credential-proof",
                "PGCONNECT_TIMEOUT": "10",
                "PGPASSWORD": password,
            },
            timeout=30,
        )
        password = ""


def pgdata_empty() -> bool:
    details = PGDATA.lstat()
    postgres = pwd.getpwnam("postgres")
    return (
        stat.S_ISDIR(details.st_mode)
        and not PGDATA.is_symlink()
        and details.st_uid == postgres.pw_uid
        and details.st_gid == postgres.pw_gid
        and stat.S_IMODE(details.st_mode) == 0o700
        and not any(PGDATA.iterdir())
    )


def manifest_binding(info: dict[str, Any], manifest_sha: str, updater: Any) -> dict[str, Any]:
    return {
        "commitSha": info["commitSha"],
        "flywayHeadVersion": info["flywayHeadVersion"],
        "flywayMigrationSetSha256": info["flywayMigrationSetSha256"],
        "manifestSha256": manifest_sha,
        "migratorJarSha256": info["executableSha256s"]["server/uten-imp-migrator.jar"],
        "releaseSequence": info["releaseSequence"],
        "serverJarSha256": info["executableSha256s"]["server/uten-imp-server.jar"],
        "signedFlywayProjectionSha256": sha256_bytes(
            updater.canonical_signed_flyway_projection(info)
        ),
        "signingKeyId": info["signingKeyId"],
        "version": info["version"],
    }


def validate_preactive_pointer(
    value: dict[str, Any],
    *,
    version: str,
    approval: str,
    runtime_contract_sha: str,
    storage_receipt_sha: str,
    require_fresh: bool = True,
) -> Path:
    if set(value) != {
        "approvalReference",
        "createdAtUtc",
        "evidencePath",
        "runtimeContractSha256",
        "schemaVersion",
        "status",
        "storageCommissioningReceiptSha256",
        "transactionId",
        "version",
    }:
        fail("database commissioning pre-active pointer schema differs")
    evidence = Path(str(value.get("evidencePath", "")))
    created = parse_utc(
        value.get("createdAtUtc"), "database commissioning pre-active creation time"
    )
    now = datetime.now(timezone.utc)
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("status") != "PREPARING_ENTRY_CLOSED"
        or value.get("version") != version
        or value.get("approvalReference") != approval
        or value.get("runtimeContractSha256") != runtime_contract_sha
        or value.get("storageCommissioningReceiptSha256") != storage_receipt_sha
        or evidence.parent != EVIDENCE_BASE
        or evidence.name != value.get("transactionId")
        or not TRANSACTION_RE.fullmatch(evidence.name)
        or created > now + timedelta(seconds=5)
        or (require_fresh and now >= created + timedelta(days=7))
    ):
        fail("database commissioning pre-active pointer differs")
    return evidence


def validate_active_pointer(value: dict[str, Any], evidence: Path) -> str:
    if set(value) != {"evidencePath", "planSha256", "schemaVersion", "transactionId"}:
        fail("database commissioning active pointer schema differs")
    plan_sha = value.get("planSha256")
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("evidencePath") != str(evidence)
        or value.get("transactionId") != evidence.name
        or not isinstance(plan_sha, str)
        or not SHA256_RE.fullmatch(plan_sha)
        or evidence.parent != EVIDENCE_BASE
        or not TRANSACTION_RE.fullmatch(evidence.name)
    ):
        fail("database commissioning active pointer differs")
    plan_path = evidence / "transaction-manifest.json"
    require_root_file(plan_path, mode=0o600)
    if sha256_file(plan_path) != plan_sha:
        fail("database commissioning active pointer names another plan")
    return plan_sha


def begin_or_resume_preactive(
    version: str,
    approval: str,
    runtime_contract_sha: str,
    storage_receipt_sha: str,
) -> tuple[str, Path]:
    """Publish the transaction identity before creating any child evidence.

    This fixed pointer makes every crash before ``active.json`` adoptable.  It
    is removed only after the complete plan-bound active pointer is durable.
    """

    require_root_directory(EVIDENCE_BASE, mode=0o700)
    if os.path.lexists(PREACTIVE_POINTER):
        value = strict_json(
            PREACTIVE_POINTER, "database commissioning pre-active pointer"
        )
        evidence = validate_preactive_pointer(
            value,
            version=version,
            approval=approval,
            runtime_contract_sha=runtime_contract_sha,
            storage_receipt_sha=storage_receipt_sha,
            require_fresh=False,
        )
        transaction = evidence.name
    else:
        archived = [
            path
            for path in EVIDENCE_BASE.glob(f"*/{PREACTIVE_ARCHIVE_NAME}")
            if os.path.lexists(path)
        ]
        if archived:
            fail("committed pre-active evidence exists without its active pointer")
        transaction = (
            "internal-test-db-"
            + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
            + secrets.token_hex(6)
        )
        if not TRANSACTION_RE.fullmatch(transaction):
            fail("generated transaction ID is malformed")
        evidence = EVIDENCE_BASE / transaction
        atomic_json(
            PREACTIVE_POINTER,
            {
                "approvalReference": approval,
                "createdAtUtc": utc_now(),
                "evidencePath": str(evidence),
                "runtimeContractSha256": runtime_contract_sha,
                "schemaVersion": 1,
                "status": "PREPARING_ENTRY_CLOSED",
                "storageCommissioningReceiptSha256": storage_receipt_sha,
                "transactionId": transaction,
                "version": version,
            },
        )
    if os.path.lexists(evidence):
        require_root_directory(evidence, mode=0o700)
    else:
        evidence.mkdir(mode=0o700)
        os.chown(evidence, 0, 0)
        os.chmod(evidence, 0o700)
        fsync_directory(EVIDENCE_BASE)
    authority_path = evidence / COMMISSIONING_AUTHORITY_NAME
    plan_path = evidence / "transaction-manifest.json"
    if authority_path.exists():
        if not plan_path.exists():
            fail("database commissioning authority exists without its immutable plan")
        validate_commissioning_authority(
            evidence, strict_json(plan_path, "database commissioning plan")
        )
    elif os.path.lexists(authority_path):
        fail("database commissioning authority has an unsafe type")
    elif plan_path.exists():
        require_fresh_plan(strict_json(plan_path, "database commissioning plan"))
    else:
        validate_preactive_pointer(
            strict_json(PREACTIVE_POINTER, "database commissioning pre-active pointer"),
            version=version,
            approval=approval,
            runtime_contract_sha=runtime_contract_sha,
            storage_receipt_sha=storage_receipt_sha,
            require_fresh=True,
        )
    return transaction, evidence


def create_evidence() -> tuple[str, Path]:
    """Legacy test helper; production apply uses begin_or_resume_preactive."""

    require_root_directory(EVIDENCE_BASE, mode=0o700)
    transaction = (
        "internal-test-db-"
        + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
        + secrets.token_hex(6)
    )
    if not TRANSACTION_RE.fullmatch(transaction):
        fail("generated transaction ID is malformed")
    evidence = EVIDENCE_BASE / transaction
    evidence.mkdir(mode=0o700)
    os.chown(evidence, 0, 0)
    os.chmod(evidence, 0o700)
    fsync_directory(EVIDENCE_BASE)
    return transaction, evidence


def converge_preactive_after_active(evidence: Path) -> None:
    """Adopt the active-before-preactive-unlink crash boundary."""

    archived_path = evidence / PREACTIVE_ARCHIVE_NAME
    live = os.path.lexists(PREACTIVE_POINTER)
    archived = os.path.lexists(archived_path)
    if live and archived:
        fail("live and archived database pre-active pointers both exist")
    if not live and not archived:
        fail("database pre-active authority disappeared before convergence")
    active = strict_json(ACTIVE_POINTER, "database commissioning active pointer")
    plan = strict_json(
        evidence / "transaction-manifest.json", "database commissioning plan"
    )
    manifest = plan.get("manifest")
    if not isinstance(manifest, dict):
        fail("database commissioning plan manifest binding is malformed")
    preactive_path = PREACTIVE_POINTER if live else archived_path
    preactive = strict_json(
        preactive_path, "database commissioning pre-active evidence"
    )
    bound_evidence = validate_preactive_pointer(
        preactive,
        version=str(manifest.get("version", "")),
        approval=str(plan.get("approvalReference", "")),
        runtime_contract_sha=str(plan.get("runtimeContractSha256", "")),
        storage_receipt_sha=str(plan.get("storageCommissioningReceiptSha256", "")),
        require_fresh=False,
    )
    if bound_evidence != evidence:
        fail("pre-active pointer names another evidence transaction")
    validate_active_pointer(active, evidence)
    validate_commissioning_authority(evidence, plan)
    if live:
        os.replace(PREACTIVE_POINTER, archived_path)
        fsync_directory(EVIDENCE_BASE)
        fsync_directory(evidence)
    validate_commissioning_authority(evidence, plan)


def write_active_pointer(evidence: Path, plan_sha: str) -> None:
    pointer = {
        "evidencePath": str(evidence),
        "planSha256": plan_sha,
        "schemaVersion": 1,
        "transactionId": evidence.name,
    }
    atomic_json(ACTIVE_POINTER, pointer)


def resolve_active() -> tuple[Path, dict[str, Any]]:
    pointer = strict_json(ACTIVE_POINTER, "database commissioning active pointer")
    evidence = Path(str(pointer.get("evidencePath", "")))
    require_root_directory(evidence, mode=0o700)
    validate_active_pointer(pointer, evidence)
    plan_path = evidence / "transaction-manifest.json"
    return evidence, strict_json(plan_path, "database commissioning plan")


def validate_committed_pointer(evidence: Path, plan_sha: str) -> dict[str, Any]:
    pointer_path = evidence / "active-pointer.committed.json"
    pointer = strict_json(pointer_path, "committed active pointer evidence")
    if set(pointer) != {"evidencePath", "planSha256", "schemaVersion", "transactionId"}:
        fail("committed database pointer schema differs")
    if (
        pointer.get("schemaVersion") != 1
        or pointer.get("evidencePath") != str(evidence)
        or pointer.get("transactionId") != evidence.name
        or pointer.get("planSha256") != plan_sha
        or evidence.parent != EVIDENCE_BASE
        or not TRANSACTION_RE.fullmatch(evidence.name)
    ):
        fail("committed database pointer differs from its transaction")
    plan_path = evidence / "transaction-manifest.json"
    if sha256_file(plan_path) != plan_sha:
        fail("committed database pointer names another transaction manifest")
    return pointer


def validate_complete_receipt(
    evidence: Path, onboarding_sha: str, *, expired_awaiting_reauth: bool = False
) -> dict[str, Any]:
    complete = strict_json(
        evidence / "complete.json", "database commissioning terminal receipt"
    )
    if set(complete) != {
        "completedAtUtc",
        "entryEnabled",
        "kind",
        "onboardingReceiptSha256",
        "productionAuthority",
        "schemaVersion",
        "status",
        "transactionId",
    }:
        fail("database commissioning terminal receipt schema differs")
    if (
        complete.get("schemaVersion") != 1
        or complete.get("kind")
        != "uten-imp-internal-test-database-commissioning-receipt"
        or complete.get("status")
        != (
            "EXPIRED_AWAITING_REAUTH"
            if expired_awaiting_reauth
            else "COMMITTED_AWAITING_FIRST_ACTIVATION"
        )
        or complete.get("transactionId") != evidence.name
        or complete.get("entryEnabled") is not False
        or complete.get("productionAuthority") is not False
        or complete.get("onboardingReceiptSha256") != onboarding_sha
        or not isinstance(complete.get("completedAtUtc"), str)
        or UTC_RE.fullmatch(complete["completedAtUtc"]) is None
    ):
        fail("database commissioning terminal receipt differs")
    return complete


def plan_time_window(plan: dict[str, Any]) -> tuple[datetime, datetime]:
    created = parse_utc(plan.get("createdAtUtc"), "commissioning plan creation time")
    expires = parse_utc(plan.get("expiresAtUtc"), "commissioning plan expiry time")
    if expires <= created or expires > created + timedelta(days=7):
        fail("database commissioning plan time window differs")
    return created, expires


def require_fresh_plan(
    plan: dict[str, Any], *, observed_at: datetime | None = None
) -> datetime:
    created, expires = plan_time_window(plan)
    observed = observed_at or datetime.now(timezone.utc)
    if observed.tzinfo is None:
        fail("database commissioning plan observation time is not UTC")
    observed = observed.astimezone(timezone.utc)
    if created > observed + timedelta(seconds=5) or observed >= expires:
        fail("database commissioning plan is stale, expired, or from the future")
    return observed


def validate_commissioning_authority(
    evidence: Path, plan: dict[str, Any]
) -> dict[str, Any]:
    authority_path = evidence / COMMISSIONING_AUTHORITY_NAME
    require_root_file(authority_path, mode=0o600)
    authority = strict_json(authority_path, "database commissioning authority")
    if set(authority) != {
        "approvalReference",
        "authorizedAtUtc",
        "evidencePath",
        "kind",
        "planPath",
        "planSha256",
        "preActiveSha256",
        "runtimeContractSha256",
        "schemaVersion",
        "status",
        "storageCommissioningReceiptSha256",
        "transactionId",
        "version",
    }:
        fail("database commissioning authority schema differs")
    plan_path = evidence / "transaction-manifest.json"
    plan_sha = sha256_file(plan_path)
    manifest = plan.get("manifest")
    if not isinstance(manifest, dict):
        fail("database commissioning authority plan manifest is malformed")
    authorized = parse_utc(
        authority.get("authorizedAtUtc"), "database commissioning authorization time"
    )
    created, expires = plan_time_window(plan)
    if not (created <= authorized < expires):
        fail("database commissioning authorization was outside the plan window")
    if (
        authority.get("schemaVersion") != 1
        or isinstance(authority.get("schemaVersion"), bool)
        or authority.get("kind")
        != "uten-imp-internal-test-database-commissioning-authority"
        or authority.get("status") != "AUTHORIZED_ENTRY_CLOSED"
        or authority.get("transactionId") != evidence.name
        or authority.get("evidencePath") != str(evidence)
        or authority.get("planPath") != str(plan_path)
        or authority.get("planSha256") != plan_sha
        or authority.get("approvalReference") != plan.get("approvalReference")
        or authority.get("version") != manifest.get("version")
        or authority.get("runtimeContractSha256")
        != plan.get("runtimeContractSha256")
        or authority.get("storageCommissioningReceiptSha256")
        != plan.get("storageCommissioningReceiptSha256")
        or not isinstance(authority.get("preActiveSha256"), str)
        or SHA256_RE.fullmatch(authority["preActiveSha256"]) is None
    ):
        fail("database commissioning authority differs from its immutable plan")

    live = os.path.lexists(PREACTIVE_POINTER)
    archived_path = evidence / PREACTIVE_ARCHIVE_NAME
    archived = os.path.lexists(archived_path)
    if live == archived:
        fail("database commissioning pre-active evidence is missing or duplicated")
    preactive_path = PREACTIVE_POINTER if live else archived_path
    require_root_file(preactive_path, mode=0o600)
    if sha256_file(preactive_path) != authority["preActiveSha256"]:
        fail("database commissioning pre-active evidence changed")
    bound = validate_preactive_pointer(
        strict_json(preactive_path, "database commissioning pre-active evidence"),
        version=str(manifest.get("version", "")),
        approval=str(plan.get("approvalReference", "")),
        runtime_contract_sha=str(plan.get("runtimeContractSha256", "")),
        storage_receipt_sha=str(plan.get("storageCommissioningReceiptSha256", "")),
        require_fresh=False,
    )
    if bound != evidence:
        fail("database commissioning authority names another pre-active transaction")
    return authority


def authorize_or_resume_commissioning(
    evidence: Path, plan: dict[str, Any]
) -> dict[str, Any]:
    authority_path = evidence / COMMISSIONING_AUTHORITY_NAME
    if authority_path.exists():
        return validate_commissioning_authority(evidence, plan)
    if os.path.lexists(authority_path):
        fail("database commissioning authority has an unsafe type")
    authorized_text = utc_now()
    authorized = parse_utc(
        authorized_text, "database commissioning authorization time"
    )
    require_fresh_plan(plan, observed_at=authorized)
    preactive = strict_json(
        PREACTIVE_POINTER, "database commissioning pre-active pointer"
    )
    manifest = plan.get("manifest")
    if not isinstance(manifest, dict):
        fail("database commissioning plan manifest is malformed")
    bound = validate_preactive_pointer(
        preactive,
        version=str(manifest.get("version", "")),
        approval=str(plan.get("approvalReference", "")),
        runtime_contract_sha=str(plan.get("runtimeContractSha256", "")),
        storage_receipt_sha=str(plan.get("storageCommissioningReceiptSha256", "")),
        require_fresh=True,
    )
    if bound != evidence:
        fail("database commissioning pre-active pointer names another transaction")
    value = {
        "approvalReference": plan["approvalReference"],
        "authorizedAtUtc": authorized_text,
        "evidencePath": str(evidence),
        "kind": "uten-imp-internal-test-database-commissioning-authority",
        "planPath": str(evidence / "transaction-manifest.json"),
        "planSha256": sha256_file(evidence / "transaction-manifest.json"),
        "preActiveSha256": sha256_file(PREACTIVE_POINTER),
        "runtimeContractSha256": plan["runtimeContractSha256"],
        "schemaVersion": 1,
        "status": "AUTHORIZED_ENTRY_CLOSED",
        "storageCommissioningReceiptSha256": plan[
            "storageCommissioningReceiptSha256"
        ],
        "transactionId": evidence.name,
        "version": manifest["version"],
    }
    atomic_json(authority_path, value)
    return validate_commissioning_authority(evidence, plan)


def candidate_snapshot(
    updater: Any, guard: Any, version: str, evidence: Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Build or adopt one durable, signed candidate snapshot generation."""

    attempt_re = re.compile(r"candidate-build-attempt-([1-9][0-9]*)\.json")
    attempt_numbers: list[int] = []
    for path in evidence.glob("candidate-build-attempt-*.json"):
        match = attempt_re.fullmatch(path.name)
        if match is None:
            fail("candidate build attempt evidence has an unsafe name")
        attempt_numbers.append(int(match.group(1)))

    def validate_attempt(number: int) -> tuple[Path, Path]:
        attempt_path = evidence / f"candidate-build-attempt-{number}.json"
        build = evidence / f"candidate-build-{number}"
        incomplete = evidence / f"candidate-build-incomplete-{number}"
        value = strict_json(attempt_path, "candidate build attempt")
        if value != {
            "buildPath": str(build),
            "kind": "uten-imp-internal-test-candidate-build-attempt",
            "schemaVersion": 1,
            "status": "AUTHORIZED_ENTRY_CLOSED",
            "transactionId": evidence.name,
            "version": version,
        }:
            fail("candidate build attempt differs from its transaction")
        return build, incomplete

    def validate_prepared(number: int) -> tuple[dict[str, Any], dict[str, Any]]:
        build, _incomplete = validate_attempt(number)
        prepared_path = evidence / f"candidate-build-prepared-{number}.json"
        prepared = strict_json(prepared_path, "prepared candidate snapshot")
        metadata = build / "candidate-metadata"
        extracted = build / "payload" / version
        if set(prepared) != {
            "candidateMetadataPath",
            "candidatePayloadPath",
            "kind",
            "manifestSha256",
            "payloadInventorySha256",
            "schemaVersion",
            "status",
            "transactionId",
            "version",
        } or prepared != {
            "candidateMetadataPath": str(metadata),
            "candidatePayloadPath": str(extracted),
            "kind": "uten-imp-internal-test-candidate-snapshot",
            "manifestSha256": prepared.get("manifestSha256"),
            "payloadInventorySha256": prepared.get("payloadInventorySha256"),
            "schemaVersion": 1,
            "status": "SIGNED_SNAPSHOT_DURABLE_ENTRY_CLOSED",
            "transactionId": evidence.name,
            "version": version,
        }:
            fail("prepared candidate snapshot schema differs")
        for key in ("manifestSha256", "payloadInventorySha256"):
            if not isinstance(prepared.get(key), str) or not SHA256_RE.fullmatch(
                prepared[key]
            ):
                fail("prepared candidate snapshot digest is malformed")
        require_root_directory(build, mode=0o700)
        require_root_directory(metadata, mode=0o700)
        require_root_directory(build / "payload", mode=0o700)
        _channel, verified, _staged = updater.verify_candidate_metadata(
            metadata, ALLOWED_SIGNERS
        )
        if verified.get("version") != version:
            fail("prepared signed candidate version differs")
        guard.verify_payload(extracted, verified)
        if (
            sha256_file(metadata / "manifest.json") != prepared["manifestSha256"]
            or payload_inventory_sha256(extracted)
            != prepared["payloadInventorySha256"]
        ):
            fail("prepared candidate snapshot bytes changed")
        return verified, {
            "candidateMetadataPath": metadata,
            "extracted": extracted,
            "manifestSha256": prepared["manifestSha256"],
            "payloadInventorySha256": prepared["payloadInventorySha256"],
        }

    def retained_candidate_bytes() -> tuple[int, int]:
        retained = 0
        total = 0
        for path in evidence.iterdir():
            match = re.fullmatch(r"candidate-build-incomplete-([1-9][0-9]*)", path.name)
            if match is None:
                continue
            number = int(match.group(1))
            if number > MAX_CANDIDATE_BUILD_ATTEMPTS:
                fail("retained candidate build exceeds the authorized attempt namespace")
            require_root_directory(path, mode=0o700)
            abandoned = evidence / f"candidate-build-abandoned-{number}.json"
            authority = evidence / f"candidate-build-abandon-authorized-{number}.json"
            if not abandoned.exists() or not authority.exists():
                # The current generation may be between rename and receipt;
                # its caller will converge that exact authority before retry.
                if number != max(attempt_numbers, default=0):
                    fail("retained candidate build lacks terminal abandonment evidence")
            for child in (path, *path.rglob("*")):
                details = child.lstat()
                if (
                    stat.S_ISLNK(details.st_mode)
                    or details.st_uid != 0
                    or details.st_gid != 0
                    or details.st_mode & 0o022
                ):
                    fail("retained candidate build contains unsafe metadata")
                if stat.S_ISREG(details.st_mode):
                    if details.st_nlink != 1:
                        fail("retained candidate build contains a hard-linked file")
                    total += details.st_size
                elif not stat.S_ISDIR(details.st_mode):
                    fail("retained candidate build contains an unsafe file type")
                if total > MAX_RETAINED_CANDIDATE_BYTES:
                    fail("retained candidate builds exceed the fixed byte budget")
            retained += 1
        return retained, total

    prepared_numbers: list[int] = []
    for path in evidence.glob("candidate-build-prepared-*.json"):
        match = re.fullmatch(r"candidate-build-prepared-([1-9][0-9]*)\.json", path.name)
        if match is None:
            fail("prepared candidate evidence has an unsafe name")
        prepared_numbers.append(int(match.group(1)))
    if len(prepared_numbers) > 1:
        fail("multiple prepared candidate snapshots exist")
    if prepared_numbers:
        return validate_prepared(prepared_numbers[0])

    attempt_number = max(attempt_numbers, default=0)
    if attempt_number:
        build, incomplete = validate_attempt(attempt_number)
        abandoned_path = evidence / f"candidate-build-abandoned-{attempt_number}.json"
        authority_path = evidence / f"candidate-build-abandon-authorized-{attempt_number}.json"
        expected_abandoned = {
            "attempt": attempt_number,
            "incompletePath": str(incomplete),
            "kind": "uten-imp-internal-test-candidate-build-abandoned",
            "schemaVersion": 1,
            "status": "RETAINED_ENTRY_CLOSED",
            "transactionId": evidence.name,
        }
        if abandoned_path.exists():
            abandoned = strict_json(abandoned_path, "abandoned candidate build")
            if abandoned != expected_abandoned:
                fail("abandoned candidate build receipt differs")
            require_root_directory(incomplete, mode=0o700)
            if os.path.lexists(build):
                fail("abandoned and live candidate builds coexist")
            attempt_number += 1
        elif os.path.lexists(build) or os.path.lexists(incomplete):
            authority = {
                "attempt": attempt_number,
                "buildPath": str(build),
                "incompletePath": str(incomplete),
                "kind": "uten-imp-internal-test-candidate-build-abandon-authority",
                "schemaVersion": 1,
                "status": "AUTHORIZED_ENTRY_CLOSED",
                "transactionId": evidence.name,
            }
            if authority_path.exists():
                if strict_json(authority_path, "candidate build abandonment authority") != authority:
                    fail("candidate build abandonment authority differs")
                if os.path.lexists(build) and os.path.lexists(incomplete):
                    fail("live and retained candidate builds coexist")
            else:
                if os.path.lexists(incomplete):
                    fail("retained candidate build lacks its durable authority")
                atomic_json(authority_path, authority)
            if os.path.lexists(build):
                os.replace(build, incomplete)
                fsync_directory(evidence)
            require_root_directory(incomplete, mode=0o700)
            atomic_json(abandoned_path, expected_abandoned)
            attempt_number += 1
        # A crash after the attempt receipt but before mkdir reuses this exact
        # generation and never invents an orphan transaction.

    retained_count, _retained_bytes = retained_candidate_bytes()
    if attempt_number > MAX_CANDIDATE_BUILD_ATTEMPTS or (
        retained_count >= MAX_CANDIDATE_BUILD_ATTEMPTS
        and not (evidence / f"candidate-build-attempt-{attempt_number}.json").exists()
    ):
        fail("candidate snapshot retry limit reached; preserve evidence and remain NO-GO")

    if attempt_number == 0 or (evidence / f"candidate-build-abandoned-{attempt_number - 1}.json").exists():
        attempt_number = max(attempt_number, 1)
        if attempt_number > MAX_CANDIDATE_BUILD_ATTEMPTS:
            fail("candidate snapshot retry limit reached; preserve evidence and remain NO-GO")
        attempt_path = evidence / f"candidate-build-attempt-{attempt_number}.json"
        build = evidence / f"candidate-build-{attempt_number}"
        if not attempt_path.exists():
            atomic_json(
                attempt_path,
                {
                    "buildPath": str(build),
                    "kind": "uten-imp-internal-test-candidate-build-attempt",
                    "schemaVersion": 1,
                    "status": "AUTHORIZED_ENTRY_CLOSED",
                    "transactionId": evidence.name,
                    "version": version,
                },
            )
    else:
        build, _unused = validate_attempt(attempt_number)

    if os.path.lexists(build):
        fail("candidate build generation unexpectedly pre-exists")
    build.mkdir(mode=0o700)
    os.chown(build, 0, 0)
    os.chmod(build, 0o700)
    fsync_directory(evidence)
    candidate = UPDATER_STATE / "candidates" / version
    snapshot, info = updater.snapshot_candidate(
        candidate,
        RELEASES,
        ALLOWED_SIGNERS,
        transaction_snapshot=build / "updater-candidate-snapshot",
    )
    try:
        manifest_sha = sha256_file(snapshot / "manifest.json")
        extracted_parent = build / "payload"
        extracted_parent.mkdir(mode=0o700)
        os.chown(extracted_parent, 0, 0)
        os.chmod(extracted_parent, 0o700)
        extracted = guard.safe_extract(
            snapshot / info["artifactFileName"], extracted_parent, info
        )
        guard.verify_payload(extracted, info)
        # Persist every extracted directory entry before the transaction plan
        # can name this payload.  A crash may lose neither an intermediate
        # directory nor its files while leaving an active pointer durable.
        directories = [
            path for path in extracted.rglob("*") if path.is_dir() and not path.is_symlink()
        ]
        for directory in sorted(
            directories, key=lambda item: len(item.parts), reverse=True
        ):
            fsync_directory(directory)
        fsync_directory(extracted)
        fsync_directory(extracted.parent)
        fsync_directory(extracted_parent)
        fsync_directory(build)
        fsync_directory(evidence)
        payload_inventory = [
            {
                "path": path.relative_to(extracted).as_posix(),
                "sha256": sha256_file(path),
            }
            for path in sorted(extracted.rglob("*"), key=lambda item: item.as_posix())
            if path.is_file() and not path.is_symlink()
        ]
        payload_inventory_sha = sha256_bytes(canonical_bytes(payload_inventory))
        metadata = build / "candidate-metadata"
        metadata.mkdir(mode=0o700)
        os.chown(metadata, 0, 0)
        os.chmod(metadata, 0o700)
        for name in ("channel.json", "channel.sig", "manifest.json", "manifest.sig", "STAGED.json"):
            destination = metadata / name
            shutil.copyfile(snapshot / name, destination)
            os.chown(destination, 0, 0)
            os.chmod(destination, 0o600)
            descriptor = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        fsync_directory(metadata)
        fsync_directory(build)
        fsync_directory(evidence)
        _channel, verified_info, _staged = updater.verify_candidate_metadata(
            metadata, ALLOWED_SIGNERS
        )
        if verified_info != info:
            fail("root snapshot metadata changed during candidate preparation")
        prepared = {
            "candidateMetadataPath": str(metadata),
            "candidatePayloadPath": str(extracted),
            "kind": "uten-imp-internal-test-candidate-snapshot",
            "manifestSha256": manifest_sha,
            "payloadInventorySha256": payload_inventory_sha,
            "schemaVersion": 1,
            "status": "SIGNED_SNAPSHOT_DURABLE_ENTRY_CLOSED",
            "transactionId": evidence.name,
            "version": version,
        }
        atomic_json(
            evidence / f"candidate-build-prepared-{attempt_number}.json",
            prepared,
        )
        return verified_info, {
            "candidateMetadataPath": metadata,
            "extracted": extracted,
            "manifestSha256": manifest_sha,
            "payloadInventorySha256": payload_inventory_sha,
        }
    finally:
        shutil.rmtree(snapshot, ignore_errors=True)


def payload_inventory_sha256(extracted: Path) -> str:
    if not extracted.is_dir() or extracted.is_symlink():
        fail("commissioning payload directory is missing or unsafe")
    inventory: list[dict[str, str]] = []
    for path in sorted(extracted.rglob("*"), key=lambda item: item.as_posix()):
        details = path.lstat()
        if path.is_symlink() or not (
            stat.S_ISDIR(details.st_mode) or stat.S_ISREG(details.st_mode)
        ):
            fail("commissioning payload contains an unsafe file type")
        if stat.S_ISREG(details.st_mode):
            inventory.append(
                {
                    "path": path.relative_to(extracted).as_posix(),
                    "sha256": sha256_file(path),
                }
            )
    return sha256_bytes(canonical_bytes(inventory))


def candidate_paths_from_plan(
    evidence: Path, plan: dict[str, Any], version: str
) -> tuple[Path, Path]:
    metadata = Path(str(plan.get("candidateMetadataPath", "")))
    extracted = Path(str(plan.get("candidatePayloadPath", "")))
    if (
        metadata.parent.parent != evidence
        or not re.fullmatch(r"candidate-build-[1-9][0-9]*", metadata.parent.name)
        or metadata.name != "candidate-metadata"
        or extracted.parent.parent != metadata.parent
        or extracted.parent != metadata.parent / "payload"
        or extracted.name != version
    ):
        fail("commissioning candidate paths escaped their prepared generation")
    require_root_directory(metadata, mode=0o700)
    require_root_directory(extracted.parent, mode=0o700)
    require_root_directory(extracted, mode=0o700)
    return metadata, extracted


def validate_transaction_plan(
    plan: dict[str, Any],
    *,
    evidence: Path,
    version: str,
    approval: str,
    manifest: dict[str, Any],
    runtime_contract_sha: str,
    storage_receipt_sha: str,
    storage_authority_sha: str,
) -> None:
    expected_keys = {
        "approvalReference",
        "candidateMetadataPath",
        "candidatePayloadPath",
        "commissionerSha256",
        "createdAtUtc",
        "dataClassification",
        "deploymentProfile",
        "entryEnabled",
        "expiresAtUtc",
        "kind",
        "manifest",
        "payloadInventorySha256",
        "productionAuthority",
        "runtimeContractSha256",
        "schemaVersion",
        "status",
        "storageAuthoritySha256",
        "storageCommissioningReceiptSha256",
        "storageObservation",
        "transactionId",
    }
    if set(plan) != expected_keys:
        fail("database commissioning plan schema differs")
    if (
        plan.get("schemaVersion") != 1
        or isinstance(plan.get("schemaVersion"), bool)
        or plan.get("kind")
        != "uten-imp-internal-test-database-commissioning-plan"
        or plan.get("status") != "APPROVED_ENTRY_CLOSED"
        or plan.get("deploymentProfile") != "internal-test-local-v1"
        or plan.get("dataClassification") != "discardable-test-only"
        or plan.get("entryEnabled") is not False
        or plan.get("productionAuthority") is not False
        or plan.get("transactionId") != evidence.name
        or plan.get("approvalReference") != approval
        or plan.get("runtimeContractSha256") != runtime_contract_sha
        or plan.get("storageCommissioningReceiptSha256") != storage_receipt_sha
        or plan.get("storageAuthoritySha256") != storage_authority_sha
        or plan.get("manifest") != manifest
        or manifest.get("version") != version
        or plan.get("commissionerSha256") != commissioner_sha256()
        or not isinstance(plan.get("payloadInventorySha256"), str)
        or not SHA256_RE.fullmatch(plan["payloadInventorySha256"])
    ):
        fail("database commissioning plan authority differs")
    plan_time_window(plan)
    _metadata, payload = candidate_paths_from_plan(evidence, plan, version)
    if payload_inventory_sha256(payload) != plan["payloadInventorySha256"]:
        fail("database commissioning plan payload changed")
    validate_storage_observation_binding(
        evidence, plan.get("storageObservation"), phase="before-plan"
    )


def initialized_identity(pgdata: Path) -> dict[str, Any]:
    completed = run(
        ["/usr/lib/postgresql/16/bin/pg_controldata", "-D", str(pgdata)]
    )
    values: dict[str, str] = {}
    for line in completed.stdout.decode("utf-8", errors="strict").splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            values[key.strip()] = value.strip()
    system_identifier = values.get("Database system identifier", "")
    if not system_identifier.isdigit():
        fail("initialized PostgreSQL system identifier is malformed")
    return {"systemIdentifier": system_identifier}


def _converge_incomplete_initdb_attempt(
    evidence: Path,
    storage: dict[str, Any],
    attempt_number: int,
    attempt_path: Path,
    incoming: Path,
    directory_created: Path,
) -> None:
    """Retain one failed initdb generation across every rename/fsync boundary."""

    directory_receipt = strict_json(
        directory_created, "initdb directory creation evidence"
    )
    if (
        set(directory_receipt)
        != {
            "attempt",
            "createdAtUtc",
            "incomingPath",
            "kind",
            "schemaVersion",
            "status",
            "transactionId",
        }
        or directory_receipt.get("attempt") != attempt_number
        or directory_receipt.get("incomingPath") != str(incoming)
        or directory_receipt.get("kind")
        != "uten-imp-internal-test-initdb-directory"
        or directory_receipt.get("schemaVersion") != 1
        or isinstance(directory_receipt.get("schemaVersion"), bool)
        or directory_receipt.get("status") != "EMPTY_DIRECTORY_CREATED"
        or directory_receipt.get("transactionId") != evidence.name
        or not isinstance(directory_receipt.get("createdAtUtc"), str)
    ):
        fail("initdb directory creation evidence is malformed")
    abandoned = PG_PARENT / f".main.incomplete-{evidence.name}-{attempt_number}"
    authority_path = evidence / f"initdb-abandon-authorized-{attempt_number}.json"
    receipt_path = evidence / f"initdb-abandoned-{attempt_number}.json"
    if authority_path.exists():
        authority = strict_json(authority_path, "initdb abandonment authority")
        expected_authority = {
            "abandonedPath": str(abandoned),
            "attempt": attempt_number,
            "attemptSha256": sha256_file(attempt_path),
            "authorizedAtUtc": authority.get("authorizedAtUtc"),
            "directoryReceiptSha256": sha256_file(directory_created),
            "filesystemUuid": storage["filesystemUuid"],
            "incomingPath": str(incoming),
            "kind": "uten-imp-internal-test-initdb-abandonment-authority",
            "schemaVersion": 1,
            "status": "INCOMPLETE_ATTEMPT_RETENTION_AUTHORIZED",
            "transactionId": evidence.name,
        }
        if (
            authority != expected_authority
            or not isinstance(authority.get("authorizedAtUtc"), str)
        ):
            fail("initdb abandonment authority differs from its durable attempt")
    else:
        if receipt_path.exists() or os.path.lexists(abandoned):
            fail("incomplete initdb path exists without prior durable authority")
        authority = {
            "abandonedPath": str(abandoned),
            "attempt": attempt_number,
            "attemptSha256": sha256_file(attempt_path),
            "authorizedAtUtc": utc_now(),
            "directoryReceiptSha256": sha256_file(directory_created),
            "filesystemUuid": storage["filesystemUuid"],
            "incomingPath": str(incoming),
            "kind": "uten-imp-internal-test-initdb-abandonment-authority",
            "schemaVersion": 1,
            "status": "INCOMPLETE_ATTEMPT_RETENTION_AUTHORIZED",
            "transactionId": evidence.name,
        }
        atomic_json(authority_path, authority)

    incoming_present = incoming.is_dir() and not incoming.is_symlink()
    abandoned_present = abandoned.is_dir() and not abandoned.is_symlink()
    if os.path.lexists(incoming) and not incoming_present:
        fail("incomplete initdb incoming path changed to an unsafe type")
    if os.path.lexists(abandoned) and not abandoned_present:
        fail("retained incomplete initdb path changed to an unsafe type")
    if incoming_present and abandoned_present:
        fail("incomplete initdb attempt exists at both live and retained paths")
    if incoming_present:
        os.rename(incoming, abandoned)
        fsync_directory(PG_PARENT)
        abandoned_present = True
    if not abandoned_present:
        fail("authorized incomplete initdb attempt disappeared before retention")

    receipt = {
        "abandonedPath": str(abandoned),
        "attempt": attempt_number,
        "abandonmentAuthoritySha256": sha256_file(authority_path),
        "filesystemUuid": storage["filesystemUuid"],
        "kind": "uten-imp-internal-test-incomplete-initdb",
        "retainedAtUtc": authority["authorizedAtUtc"],
        "schemaVersion": 1,
        "status": "INCOMPLETE_ATTEMPT_RETAINED",
        "transactionId": evidence.name,
    }
    if receipt_path.exists():
        if strict_json(receipt_path, "retained initdb evidence") != receipt:
            fail("retained incomplete initdb receipt differs")
    else:
        atomic_json(receipt_path, receipt)


def initialize_cluster(evidence: Path, storage: dict[str, Any]) -> None:
    prepared_path = evidence / "initdb-prepared.json"
    published_path = evidence / "initdb-published.json"
    empty_preimage = PG_PARENT / f".main.empty-preimage-{evidence.name}"
    authorized_incoming: set[Path] = set()
    for attempt_file in evidence.glob("initdb-attempt-*.json"):
        match = re.fullmatch(r"initdb-attempt-([1-9][0-9]*)\.json", attempt_file.name)
        if match is None:
            fail("initdb attempt namespace contains an unexpected entry")
        attempt_value = strict_json(attempt_file, "initdb attempt evidence")
        expected_incoming = PG_PARENT / (
            f".main.incoming-{evidence.name}-{int(match.group(1))}"
        )
        if (
            attempt_value.get("transactionId") != evidence.name
            or attempt_value.get("incomingPath") != str(expected_incoming)
        ):
            fail("initdb attempt does not bind its incoming directory")
        authorized_incoming.add(expected_incoming)
    for candidate in PG_PARENT.glob(f".main.incoming-{evidence.name}-*"):
        if candidate not in authorized_incoming:
            fail("unbound initdb incoming directory exists and remains untouched")
    if published_path.exists():
        published = strict_json(published_path, "published initdb evidence")
        if (
            published.get("transactionId") != evidence.name
            or published.get("status") != "INITIALIZED_PGDATA_PUBLISHED"
            or not (PGDATA / "PG_VERSION").is_file()
            or not empty_preimage.is_dir()
            or any(empty_preimage.iterdir())
        ):
            fail("published initdb evidence differs from the exact filesystem state")
        if initialized_identity(PGDATA).get("systemIdentifier") != published.get("systemIdentifier"):
            fail("initialized PostgreSQL identity changed")
        return

    if prepared_path.exists():
        prepared = strict_json(prepared_path, "prepared initdb evidence")
        if (
            prepared.get("transactionId") != evidence.name
            or prepared.get("status") != "INITIALIZED_NOT_PUBLISHED"
            or prepared.get("filesystemUuid") != storage["filesystemUuid"]
        ):
            fail("prepared initdb evidence differs from this transaction")
        incoming = Path(str(prepared.get("incomingPath", "")))
        if incoming.parent != PG_PARENT or not re.fullmatch(
            rf"\.main\.incoming-{re.escape(evidence.name)}-[1-9][0-9]*",
            incoming.name,
        ):
            fail("prepared initdb incoming path escaped its transaction namespace")
    else:
        need_initdb = False
        existing_attempt: dict[str, Any] | None = None
        if not pgdata_empty():
            fail("PGDATA is no longer the empty storage-commissioned directory")
        if os.path.lexists(empty_preimage):
            fail("empty PGDATA preimage exists before durable initdb preparation")
        attempt_paths: list[tuple[int, Path]] = []
        for candidate in evidence.glob("initdb-attempt-*.json"):
            match = re.fullmatch(r"initdb-attempt-([1-9][0-9]*)\.json", candidate.name)
            if match is None:
                fail("initdb attempt namespace contains an unexpected entry")
            attempt_paths.append((int(match.group(1)), candidate))
        attempt_paths.sort(key=lambda item: item[0])
        attempt_number = 1
        if attempt_paths:
            attempt_number, latest = attempt_paths[-1]
            if attempt_number > 100:
                fail("initdb retry count exceeds the reviewed limit")
            attempt = strict_json(latest, "initdb attempt evidence")
            existing_attempt = attempt
            incoming = Path(str(attempt.get("incomingPath", "")))
            directory_created = evidence / (
                f"initdb-directory-created-{attempt_number}.json"
            )
            if (
                attempt.get("transactionId") != evidence.name
                or attempt.get("status") != "INITDB_RUNNING"
                or attempt.get("filesystemUuid") != storage["filesystemUuid"]
                or latest.name != f"initdb-attempt-{attempt_number}.json"
                or incoming
                != PG_PARENT / f".main.incoming-{evidence.name}-{attempt_number}"
            ):
                fail("latest initdb attempt evidence is malformed")
            if incoming.is_dir() and not incoming.is_symlink():
                try:
                    identity = initialized_identity(incoming)
                except CommissioningError:
                    if not directory_created.exists():
                        atomic_json(
                            directory_created,
                            {
                                "attempt": attempt_number,
                                "createdAtUtc": utc_now(),
                                "incomingPath": str(incoming),
                                "kind": "uten-imp-internal-test-initdb-directory",
                                "schemaVersion": 1,
                                "status": "EMPTY_DIRECTORY_CREATED",
                                "transactionId": evidence.name,
                            },
                        )
                    _converge_incomplete_initdb_attempt(
                        evidence,
                        storage,
                        attempt_number,
                        latest,
                        incoming,
                        directory_created,
                    )
                    attempt_number += 1
                    existing_attempt = None
                else:
                    prepared = {
                        "attempt": attempt_number,
                        "completedAtUtc": utc_now(),
                        "filesystemUuid": storage["filesystemUuid"],
                        "incomingPath": str(incoming),
                        "kind": "uten-imp-internal-test-initdb",
                        "schemaVersion": 1,
                        "status": "INITIALIZED_NOT_PUBLISHED",
                        "systemIdentifier": identity["systemIdentifier"],
                        "transactionId": evidence.name,
                    }
                    atomic_json(prepared_path, prepared)
            elif os.path.lexists(incoming):
                fail("initdb attempt path changed to an unsafe file type")
            else:
                if directory_created.exists():
                    _converge_incomplete_initdb_attempt(
                        evidence,
                        storage,
                        attempt_number,
                        latest,
                        incoming,
                        directory_created,
                    )
                    attempt_number += 1
                    existing_attempt = None
                else:
                    need_initdb = True
        if prepared_path.exists():
            prepared = strict_json(prepared_path, "prepared initdb evidence")
            incoming = Path(prepared["incomingPath"])
        else:
            incoming = PG_PARENT / f".main.incoming-{evidence.name}-{attempt_number}"
            attempt_path = evidence / f"initdb-attempt-{attempt_number}.json"
            if existing_attempt is not None:
                attempt = existing_attempt
                if (
                    attempt.get("attempt") != attempt_number
                    or attempt.get("filesystemUuid") != storage["filesystemUuid"]
                    or attempt.get("incomingPath") != str(incoming)
                    or attempt.get("kind")
                    != "uten-imp-internal-test-initdb-attempt"
                    or attempt.get("pgDataEmpty") is not True
                    or attempt.get("schemaVersion") != 1
                    or attempt.get("status") != "INITDB_RUNNING"
                    or attempt.get("transactionId") != evidence.name
                    or not isinstance(attempt.get("authorizedAtUtc"), str)
                ):
                    fail("existing initdb attempt differs from the authorized values")
            else:
                attempt = {
                    "attempt": attempt_number,
                    "authorizedAtUtc": utc_now(),
                    "filesystemUuid": storage["filesystemUuid"],
                    "incomingPath": str(incoming),
                    "kind": "uten-imp-internal-test-initdb-attempt",
                    "pgDataEmpty": True,
                    "schemaVersion": 1,
                    "status": "INITDB_RUNNING",
                    "transactionId": evidence.name,
                }
                atomic_json(attempt_path, attempt)
            if os.path.lexists(incoming):
                fail("authorized initdb target already exists")
            need_initdb = True
        if need_initdb:
            postgres = pwd.getpwnam("postgres")
            incoming.mkdir(mode=0o700)
            os.chown(incoming, postgres.pw_uid, postgres.pw_gid)
            os.chmod(incoming, 0o700)
            fsync_directory(PG_PARENT)
            directory_created = evidence / (
                f"initdb-directory-created-{attempt_number}.json"
            )
            if not directory_created.exists():
                atomic_json(
                    directory_created,
                    {
                        "attempt": attempt_number,
                        "createdAtUtc": utc_now(),
                        "incomingPath": str(incoming),
                        "kind": "uten-imp-internal-test-initdb-directory",
                        "schemaVersion": 1,
                        "status": "EMPTY_DIRECTORY_CREATED",
                        "transactionId": evidence.name,
                    },
                )
            run(
                [
                    "/usr/sbin/runuser",
                    "-u",
                    "postgres",
                    "--",
                    "/usr/lib/postgresql/16/bin/initdb",
                    "-D",
                    str(incoming),
                    "--encoding=UTF8",
                    "--locale=C.UTF-8",
                    "--auth-local=peer",
                    "--auth-host=scram-sha-256",
                    "--no-instructions",
                ],
                timeout=900,
            )
            identity = initialized_identity(incoming)
            prepared = {
                "attempt": attempt_number,
                "completedAtUtc": utc_now(),
                "filesystemUuid": storage["filesystemUuid"],
                "incomingPath": str(incoming),
                "kind": "uten-imp-internal-test-initdb",
                "schemaVersion": 1,
                "status": "INITIALIZED_NOT_PUBLISHED",
                "systemIdentifier": identity["systemIdentifier"],
                "transactionId": evidence.name,
            }
            atomic_json(prepared_path, prepared)

    expected_identity = {"systemIdentifier": prepared["systemIdentifier"]}
    # Reconcile each exact fsync boundary. Unknown or ambiguous combinations are
    # never deleted, renamed, or reinitialized.
    incoming_initialized = (
        incoming.is_dir()
        and not incoming.is_symlink()
        and (incoming / "PG_VERSION").is_file()
        and initialized_identity(incoming) == expected_identity
    )
    pgdata_initialized = (
        PGDATA.is_dir()
        and not PGDATA.is_symlink()
        and (PGDATA / "PG_VERSION").is_file()
        and initialized_identity(PGDATA) == expected_identity
    )
    pgdata_is_empty = PGDATA.is_dir() and not PGDATA.is_symlink() and not any(PGDATA.iterdir())
    preimage_is_empty = (
        empty_preimage.is_dir()
        and not empty_preimage.is_symlink()
        and not any(empty_preimage.iterdir())
    )
    if incoming_initialized and pgdata_is_empty and not os.path.lexists(empty_preimage):
        os.rename(PGDATA, empty_preimage)
        fsync_directory(PG_PARENT)
        preimage_is_empty = True
        pgdata_is_empty = False
    if incoming_initialized and preimage_is_empty and not os.path.lexists(PGDATA):
        os.rename(incoming, PGDATA)
        fsync_directory(PG_PARENT)
        incoming_initialized = False
        pgdata_initialized = True
    if not (pgdata_initialized and preimage_is_empty and not os.path.lexists(incoming)):
        fail("initdb publication filesystem state is ambiguous and remains untouched")
    published = {
        **prepared,
        "publishedAtUtc": utc_now(),
        "status": "INITIALIZED_PGDATA_PUBLISHED",
    }
    atomic_json(published_path, published)


def start_postgres() -> None:
    if systemd_state(POSTGRES_UNIT, "UnitFileState") not in {
        "disabled",
        "enabled",
        "static",
        "indirect",
    }:
        fail("PostgreSQL unit enablement is outside the reviewed transition")
    run(["/usr/bin/systemctl", "start", POSTGRES_UNIT], timeout=180)
    if systemd_state(POSTGRES_UNIT, "ActiveState") != "active":
        fail("PostgreSQL did not remain active")


def validate_postgres_boot_preparing(evidence: Path) -> dict[str, Any]:
    value = strict_json(
        evidence / "postgres-boot-preparing.json",
        "PostgreSQL boot preparation",
    )
    if set(value) != {
        "entryEnabled", "kind", "recordedAtUtc", "schemaVersion", "status",
        "transactionId",
    } or (
        value.get("entryEnabled") is not False
        or value.get("kind") != "uten-imp-internal-test-postgres-boot-transition"
        or value.get("schemaVersion") != 1
        or value.get("status") != "POSTGRES_BOOT_PREPARING"
        or value.get("transactionId") != evidence.name
        or not isinstance(value.get("recordedAtUtc"), str)
        or UTC_RE.fullmatch(value["recordedAtUtc"]) is None
    ):
        fail("PostgreSQL boot preparation differs")
    return value


def validate_postgres_boot_commit(evidence: Path) -> dict[str, Any]:
    value = strict_json(
        evidence / "postgres-boot-committed.json",
        "PostgreSQL boot commitment",
    )
    if set(value) != {
        "committedAtUtc", "entryEnabled", "kind", "schemaVersion", "status",
        "transactionId", "units",
    } or (
        value.get("entryEnabled") is not False
        or value.get("kind") != "uten-imp-internal-test-postgres-boot-transition"
        or value.get("schemaVersion") != 1
        or value.get("status") != "POSTGRES_BOOT_COMMITTED_ENTRY_CLOSED"
        or value.get("transactionId") != evidence.name
        or value.get("units") != [POSTGRES_META_UNIT, POSTGRES_UNIT]
        or not isinstance(value.get("committedAtUtc"), str)
        or UTC_RE.fullmatch(value["committedAtUtc"]) is None
    ):
        fail("PostgreSQL boot commitment differs")
    return value


def commit_postgres_boot_contract(evidence: Path) -> None:
    complete = evidence / "postgres-boot-committed.json"
    if complete.exists():
        validate_postgres_boot_commit(evidence)
    else:
        preparing = evidence / "postgres-boot-preparing.json"
        if not preparing.exists():
            atomic_json(
                preparing,
                {
                    "entryEnabled": False,
                    "kind": "uten-imp-internal-test-postgres-boot-transition",
                    "recordedAtUtc": utc_now(),
                    "schemaVersion": 1,
                    "status": "POSTGRES_BOOT_PREPARING",
                    "transactionId": evidence.name,
                },
            )
        validate_postgres_boot_preparing(evidence)
        atomic_bytes(POSTGRES_START_CONF, b"auto\n", replace=True)
        os.chmod(POSTGRES_START_CONF, 0o644)
        run(["/usr/bin/systemctl", "daemon-reload"])
        run(
            [
                "/usr/bin/systemctl",
                "enable",
                POSTGRES_META_UNIT,
                POSTGRES_UNIT,
            ]
        )
        run(["/usr/bin/systemctl", "start", POSTGRES_META_UNIT], timeout=180)
    require_root_file(POSTGRES_START_CONF, mode=0o644)
    if POSTGRES_START_CONF.read_bytes() != b"auto\n":
        fail("PostgreSQL start.conf differs from the reviewed auto contract")
    for unit in (POSTGRES_META_UNIT, POSTGRES_UNIT):
        if (
            systemd_state(unit, "UnitFileState") != "enabled"
            or systemd_state(unit, "ActiveState") != "active"
        ):
            fail(f"PostgreSQL boot contract did not converge: {unit}")
    wants = set(systemd_state(POSTGRES_META_UNIT, "Wants").split())
    if POSTGRES_UNIT not in wants:
        fail("PostgreSQL meta unit does not want the fixed 16/main instance")
    if not complete.exists():
        atomic_json(
            complete,
            {
                "committedAtUtc": utc_now(),
                "entryEnabled": False,
                "kind": "uten-imp-internal-test-postgres-boot-transition",
                "schemaVersion": 1,
                "status": "POSTGRES_BOOT_COMMITTED_ENTRY_CLOSED",
                "transactionId": evidence.name,
                "units": [POSTGRES_META_UNIT, POSTGRES_UNIT],
            },
        )
    validate_postgres_boot_commit(evidence)


def configure_roles(evidence: Path) -> None:
    marker = evidence / "roles-created.json"
    app_password = secret_value(APP_PASSWORD)
    migrator_password = secret_value(MIGRATOR_PASSWORD)
    sql = b"""\\getenv app_password UTEN_COMMISSION_APP_PASSWORD
\\getenv migrator_password UTEN_COMMISSION_MIGRATOR_PASSWORD
SET log_statement = 'none';
SET log_duration = off;
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
SET log_parameter_max_length_on_error = 0;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='uten_owner') THEN CREATE ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='uten_migrator') THEN CREATE ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; END IF; END $$;
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='uten') THEN CREATE ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; END IF; END $$;
ALTER ROLE uten_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE uten_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE uten LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
DO $$ DECLARE membership record; BEGIN
  FOR membership IN
    SELECT parent.rolname AS parent_name, member.rolname AS member_name
    FROM pg_auth_members link
    JOIN pg_roles parent ON parent.oid = link.roleid
    JOIN pg_roles member ON member.oid = link.member
    WHERE (
      member.rolname IN ('uten', 'uten_owner', 'uten_migrator')
      OR parent.rolname IN ('uten', 'uten_owner', 'uten_migrator')
    )
      AND NOT (member.rolname = 'uten_migrator' AND parent.rolname = 'uten_owner')
  LOOP
    EXECUTE format('REVOKE %I FROM %I', membership.parent_name, membership.member_name);
  END LOOP;
END $$;
ALTER ROLE uten_migrator PASSWORD :'migrator_password';
ALTER ROLE uten PASSWORD :'app_password';
GRANT uten_owner TO uten_migrator;
SELECT 'CREATE DATABASE uten_imp OWNER uten_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='uten_imp')\\gexec
REVOKE ALL ON DATABASE uten_imp FROM PUBLIC;
DO $$ DECLARE grantee_name text; BEGIN
  FOR grantee_name IN
    SELECT DISTINCT grantee.rolname
    FROM pg_database database
    CROSS JOIN LATERAL aclexplode(COALESCE(database.datacl, acldefault('d', database.datdba))) acl
    JOIN pg_roles grantee ON grantee.oid = acl.grantee
    WHERE database.datname = 'uten_imp'
      AND acl.grantee <> database.datdba
      AND grantee.rolname NOT IN ('uten', 'uten_migrator')
  LOOP
    EXECUTE format('REVOKE ALL ON DATABASE uten_imp FROM %I', grantee_name);
  END LOOP;
END $$;
GRANT CONNECT ON DATABASE uten_imp TO uten, uten_migrator;
ALTER ROLE uten_migrator IN DATABASE uten_imp SET role TO 'uten_owner';
\\connect uten_imp
ALTER SCHEMA public OWNER TO uten_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
DO $$ DECLARE grantee_name text; BEGIN
  FOR grantee_name IN
    SELECT DISTINCT grantee.rolname
    FROM pg_namespace namespace
    CROSS JOIN LATERAL aclexplode(COALESCE(namespace.nspacl, acldefault('n', namespace.nspowner))) acl
    JOIN pg_roles grantee ON grantee.oid = acl.grantee
    WHERE namespace.nspname = 'public'
      AND acl.grantee <> namespace.nspowner
      AND grantee.rolname <> 'uten'
  LOOP
    EXECUTE format('REVOKE ALL ON SCHEMA public FROM %I', grantee_name);
  END LOOP;
END $$;
GRANT USAGE ON SCHEMA public TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO uten;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public REVOKE USAGE ON TYPES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE uten_owner IN SCHEMA public GRANT USAGE ON TYPES TO uten;
"""
    run(
        ["/usr/sbin/runuser", "-u", "postgres", "--", "/usr/bin/psql", "-X", "-q", "-v", "ON_ERROR_STOP=1"],
        input_bytes=sql,
        environment={
            "HOME": "/var/lib/postgresql",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            "UTEN_COMMISSION_APP_PASSWORD": app_password,
            "UTEN_COMMISSION_MIGRATOR_PASSWORD": migrator_password,
        },
    )
    app_password = ""
    migrator_password = ""
    query = run(
        [
            "/usr/sbin/runuser", "-u", "postgres", "--", "/usr/bin/psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-d", "uten_imp", "-c",
            "SELECT datdba::regrole::text,(SELECT nspowner::regrole::text FROM pg_namespace WHERE nspname='public'),has_database_privilege('uten','uten_imp','CREATE'),has_schema_privilege('uten','public','CREATE'),pg_has_role('uten_migrator','uten_owner','MEMBER'); FROM pg_database WHERE datname='uten_imp'",
        ]
    ).stdout.decode("utf-8", errors="strict").strip()
    if query != "uten_owner|uten_owner|f|f|t":
        fail("database role/ownership contract differs")
    if not marker.exists():
        atomic_json(
            marker,
            {
                "completedAtUtc": utc_now(),
                "kind": "uten-imp-internal-test-role-contract",
                "queryResultSha256": sha256_bytes((query + "\n").encode("utf-8")),
                "schemaVersion": 1,
                "status": "ROLE_CONTRACT_VERIFIED",
                "transactionId": evidence.name,
            },
        )


def run_migrator(evidence: Path, extracted: Path, manifest: dict[str, Any]) -> None:
    jar = extracted / "server/uten-imp-migrator.jar"
    require_root_file(jar, group=None)
    if sha256_file(jar) != manifest["migratorJarSha256"]:
        fail("migration-only JAR differs from the signed manifest")
    process_receipt_path = evidence / "migrator-process.json"
    if process_receipt_path.exists():
        prior = strict_json(process_receipt_path, "migration process receipt")
        if (
            set(prior)
            != {
                "completedAtUtc",
                "jarSha256",
                "kind",
                "outputSha256",
                "schemaVersion",
                "status",
                "transactionId",
            }
            or prior.get("schemaVersion") != 1
            or prior.get("kind") != "uten-imp-internal-test-migrator-process"
            or prior.get("status") != "MIGRATION_PROCESS_SUCCEEDED"
            or prior.get("transactionId") != evidence.name
            or prior.get("jarSha256") != manifest["migratorJarSha256"]
            or not SHA256_RE.fullmatch(str(prior.get("outputSha256", "")))
        ):
            fail("existing migration process receipt differs from this transaction")
        return
    migrator = pwd.getpwnam("uten-imp-migrate")
    require_root_directory(WORKER_RUNTIME, mode=0o700)
    execution = Path(
        tempfile.mkdtemp(prefix="migrator-", dir=str(WORKER_RUNTIME))
    )
    os.chown(execution, 0, migrator.pw_gid)
    os.chmod(execution, 0o750)
    executable = execution / "uten-imp-migrator.jar"
    shutil.copyfile(jar, executable)
    os.chown(executable, 0, migrator.pw_gid)
    os.chmod(executable, 0o440)
    try:
        password = secret_value(MIGRATOR_PASSWORD)
        completed = run(
            [
                "/usr/sbin/runuser", "-u", "uten-imp-migrate", "--",
                "/usr/bin/java", "-Xms64m", "-Xmx512m", "-XX:+ExitOnOutOfMemoryError", "-jar", str(executable),
            ],
            timeout=1800,
            environment={
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/bin:/bin",
                "UTEN_MIGRATOR_DB_PASSWORD": password,
            },
        )
        password = ""
        lines = completed.stdout.decode("utf-8", errors="strict").splitlines()
        if len(lines) != 2 or lines[0] != "UTEN_MIGRATION_VALIDATE_OK" or not re.fullmatch(r"UTEN_MIGRATION_OK migrations_executed=\d+", lines[1]):
            fail("migration-only JAR returned unexpected terminal evidence")
        atomic_json(
            process_receipt_path,
            {
                "completedAtUtc": utc_now(),
                "jarSha256": manifest["migratorJarSha256"],
                "kind": "uten-imp-internal-test-migrator-process",
                "outputSha256": sha256_bytes(completed.stdout),
                "schemaVersion": 1,
                "status": "MIGRATION_PROCESS_SUCCEEDED",
                "transactionId": evidence.name,
            },
        )
    finally:
        shutil.rmtree(execution, ignore_errors=True)


def database_identity(updater: Any, info: dict[str, Any]) -> dict[str, Any]:
    verify_database_credentials()
    observed = updater.verify_live_internal_test_signed_database(target_manifest=info)
    return updater.runtime_database_identity(observed)


def reauthorize_activation(version: str, approval: str) -> dict[str, Any]:
    """Mint a short activation-only authority without mutating PostgreSQL/runtime."""

    if os.geteuid() != 0:
        fail("activation reauthorization must run as root")
    if not VERSION_RE.fullmatch(version) or not APPROVAL_RE.fullmatch(approval):
        fail("activation reauthorization version or approval is malformed")
    bootstrap = bootstrap_runtime_contract()
    updater, _guard = load_modules(bootstrap[0])
    with updater.StateLock(updater.DEFAULT_LOCK_FILE), updater.DatabaseMaintenanceLock():
        require_entry_closed()
        if any(
            os.path.lexists(path)
            for path in (
                ROOT_STATE / "active.json",
                ROOT_STATE / "runtime-authority.json",
                ROOT_STATE / "internal-test-onboarding-adoption.json",
                ACTIVE_POINTER,
                PREACTIVE_POINTER,
                WORKER_REQUEST,
            )
        ):
            fail("activation reauthorization requires a terminal, unadopted first install")
        contract, contract_sha = runtime_contract(updater, bootstrap)
        updater.assert_pre_database_runtime_contract()
        verify_runtime_secret_binding()
        storage_path, storage, storage_sha = storage_receipt()
        validate_storage_terminal_contract(contract, storage_path, storage)
        live_storage = verify_live_storage(contract, storage_path, storage_sha)
        require_root_file(ONBOARDING_RECEIPT, mode=0o600)
        onboarding = strict_json(
            ONBOARDING_RECEIPT, "expired internal-test onboarding receipt"
        )
        if (
            onboarding.get("status") != "EXPIRED_AWAITING_REAUTH"
            or onboarding.get("manifest", {}).get("version") != version
            or onboarding.get("runtimeContractSha256") != contract_sha
            or onboarding.get("storageCommissioningReceiptSha256") != storage_sha
        ):
            fail("expired onboarding differs from the requested reauthorization")
        evidence = Path(str(onboarding.get("evidencePath", "")))
        if (
            evidence.parent != EVIDENCE_BASE
            or evidence.name != onboarding.get("transactionId")
            or not TRANSACTION_RE.fullmatch(evidence.name)
        ):
            fail("expired onboarding evidence escaped its fixed transaction")
        require_root_directory(evidence, mode=0o700)
        plan_path = evidence / "transaction-manifest.json"
        plan = strict_json(plan_path, "expired commissioning plan")
        metadata, _payload = candidate_paths_from_plan(evidence, plan, version)
        _channel, info, _staged = updater.verify_candidate_metadata(
            metadata, ALLOWED_SIGNERS
        )
        updater.validate_internal_test_onboarding_receipt(
            onboarding,
            require_worker_terminal=True,
            authenticated_expected_target=info,
            allow_expired_origin=True,
        )
        if manifest_binding(info, sha256_file(metadata / "manifest.json"), updater) != onboarding[
            "manifest"
        ]:
            fail("expired onboarding candidate binding changed")
        identity = database_identity(updater, info)
        if identity != onboarding.get("databaseIdentity"):
            fail("live database identity drifted before activation reauthorization")
        complete_path = evidence / "complete.json"
        validate_complete_receipt(
            evidence,
            sha256_file(ONBOARDING_RECEIPT),
            expired_awaiting_reauth=True,
        )
        validate_committed_pointer(evidence, sha256_file(plan_path))
        commissioning_authority = evidence / COMMISSIONING_AUTHORITY_NAME
        validate_commissioning_authority(evidence, plan)
        host_active = HOST_PREPARATION_ACTIVE
        host_terminal = validate_host_preparation_terminal(contract_sha)
        authorized_at = datetime.now(timezone.utc).replace(microsecond=0)
        expires_at = authorized_at + timedelta(hours=1)
        boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(
            encoding="ascii"
        ).strip()
        if not BOOT_ID_RE.fullmatch(boot_id):
            fail("kernel boot identity is malformed")
        clock = getattr(time, "CLOCK_BOOTTIME", None)
        if clock is None:
            fail("CLOCK_BOOTTIME is unavailable for activation reauthorization")
        boottime_ns = time.clock_gettime_ns(clock)
        if not isinstance(boottime_ns, int) or isinstance(boottime_ns, bool) or boottime_ns < 0:
            fail("CLOCK_BOOTTIME returned an invalid value")
        nonce = secrets.token_hex(16)
        receipt = {
            "approvalReference": approval,
            "authorizedAtUtc": authorized_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "authorizedBoottimeNs": boottime_ns,
            "bootId": boot_id,
            "candidateManifestSha256": onboarding["manifest"]["manifestSha256"],
            "commissioningAuthorityPath": str(commissioning_authority),
            "commissioningAuthoritySha256": sha256_file(commissioning_authority),
            "completePath": str(complete_path),
            "completeSha256": sha256_file(complete_path),
            "databaseIdentity": identity,
            "databaseIdentitySha256": sha256_bytes(canonical_bytes(identity)),
            "entryEnabled": False,
            "expiresAtUtc": expires_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "expiresBoottimeNs": boottime_ns + 3600 * 1_000_000_000,
            "hostPreparationActivePath": str(host_active),
            "hostPreparationActiveSha256": sha256_file(host_active),
            "kind": "uten-imp-internal-test-activation-reauthorization",
            "nonce": nonce,
            "onboardingPath": str(ONBOARDING_RECEIPT),
            "onboardingSha256": sha256_file(ONBOARDING_RECEIPT),
            "productionAuthority": False,
            "runtimeContractSha256": contract_sha,
            "schemaVersion": 1,
            "status": "AUTHORIZED_ACTIVATION_ONLY_ENTRY_CLOSED",
            "storageAuthoritySha256": sha256_file(STORAGE_AUTHORITY),
            "storageObservationSha256": sha256_bytes(canonical_bytes(live_storage)),
            "transactionId": evidence.name,
            "version": version,
        }
        if os.path.lexists(ACTIVATION_REAUTHORIZATION):
            existing = strict_json(
                ACTIVATION_REAUTHORIZATION,
                "existing activation reauthorization",
            )
            if (
                existing.get("transactionId") != evidence.name
                or existing.get("version") != version
                or existing.get("approvalReference") != approval
            ):
                fail("another activation reauthorization is already active")
            return existing
        atomic_json(ACTIVATION_REAUTHORIZATION, receipt)
        return receipt


def current_boot_id() -> str:
    try:
        value = BOOT_ID_PATH.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise CommissioningError("kernel boot identity is unavailable") from exc
    if BOOT_ID_RE.fullmatch(value) is None:
        fail("kernel boot identity is malformed")
    return value


def worker_request_value(
    version: str,
    approval: str,
    *,
    boot_id: str,
    unit_sha256: str,
    runtime_contract_sha256: str,
) -> dict[str, Any]:
    if (
        VERSION_RE.fullmatch(version) is None
        or APPROVAL_RE.fullmatch(approval) is None
        or BOOT_ID_RE.fullmatch(boot_id) is None
        or SHA256_RE.fullmatch(unit_sha256) is None
        or SHA256_RE.fullmatch(runtime_contract_sha256) is None
    ):
        fail("database commissioner worker request identity is malformed")
    core = {
        "approvalReference": approval,
        "bootId": boot_id,
        "controlGroup": WORKER_CGROUP,
        "kind": "uten-imp-internal-test-db-worker-request",
        "runtimeContractSha256": runtime_contract_sha256,
        "schemaVersion": 2,
        "status": "AUTHORIZED_FIXED_CGROUP",
        "systemdUnit": COMMISSIONER_UNIT,
        "unitSha256": unit_sha256,
        "version": version,
    }
    return {**core, "requestId": sha256_bytes(canonical_bytes(core))[:32]}


def validate_worker_request(value: dict[str, Any]) -> None:
    if set(value) != {
        "approvalReference",
        "bootId",
        "controlGroup",
        "kind",
        "requestId",
        "runtimeContractSha256",
        "schemaVersion",
        "status",
        "systemdUnit",
        "unitSha256",
        "version",
    } or value.get("kind") != "uten-imp-internal-test-db-worker-request" or value.get(
        "schemaVersion"
    ) != 2 or value.get("status") != "AUTHORIZED_FIXED_CGROUP":
        fail("database commissioner worker request schema differs")
    version = value.get("version")
    approval = value.get("approvalReference")
    boot_id = value.get("bootId")
    unit_sha256 = value.get("unitSha256")
    runtime_contract_sha256 = value.get("runtimeContractSha256")
    if (
        not isinstance(version, str)
        or VERSION_RE.fullmatch(version) is None
        or not isinstance(approval, str)
        or APPROVAL_RE.fullmatch(approval) is None
        or not isinstance(boot_id, str)
        or BOOT_ID_RE.fullmatch(boot_id) is None
        or not isinstance(unit_sha256, str)
        or SHA256_RE.fullmatch(unit_sha256) is None
        or not isinstance(runtime_contract_sha256, str)
        or SHA256_RE.fullmatch(runtime_contract_sha256) is None
        or value.get("systemdUnit") != COMMISSIONER_UNIT
        or value.get("controlGroup") != WORKER_CGROUP
        or value.get("requestId")
        != worker_request_value(
            version,
            approval,
            boot_id=boot_id,
            unit_sha256=unit_sha256,
            runtime_contract_sha256=runtime_contract_sha256,
        )["requestId"]
    ):
        fail("database commissioner worker request identity differs")


def validate_worker_request_live(
    value: dict[str, Any],
    *,
    contract: dict[str, Any],
    runtime_contract_sha256: str,
) -> None:
    """Bind a structurally valid request to the live boot and reviewed worker."""

    validate_worker_request(value)
    if current_boot_id() != value["bootId"]:
        fail("database commissioner worker request belongs to another boot")
    require_root_file(COMMISSIONER_UNIT_FILE, mode=0o644, group=0)
    live_unit_sha256 = sha256_file(COMMISSIONER_UNIT_FILE)
    if (
        live_unit_sha256 != value["unitSha256"]
        or contract.get("databaseCommissionerUnitSha256") != live_unit_sha256
    ):
        fail("database commissioner worker unit differs from its runtime authority")
    if (
        not isinstance(runtime_contract_sha256, str)
        or SHA256_RE.fullmatch(runtime_contract_sha256) is None
        or value["runtimeContractSha256"] != runtime_contract_sha256
    ):
        fail("database commissioner worker runtime contract changed")


def assert_fixed_worker_supervision() -> None:
    if os.geteuid() != 0:
        fail("database commissioner worker must run as root")
    require_root_file(COMMISSIONER_UNIT_FILE, group=None)
    expected = {
        "ActiveState": "activating",
        "ControlGroup": WORKER_CGROUP,
        "DropInPaths": "",
        "FragmentPath": str(COMMISSIONER_UNIT_FILE),
        "KillMode": "control-group",
        "MainPID": str(os.getpid()),
        "UnitFileState": "static",
    }
    for property_name, expected_value in expected.items():
        if systemd_state(COMMISSIONER_UNIT, property_name) != expected_value:
            fail(f"database commissioner worker supervision differs: {property_name}")
    try:
        cgroups = Path("/proc/self/cgroup").read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise CommissioningError("cannot inspect database commissioner cgroup") from exc
    if not any(line.endswith("::" + WORKER_CGROUP) for line in cgroups):
        fail("database commissioner is outside its fixed systemd cgroup")
    require_root_directory(WORKER_RUNTIME, mode=0o700)


def assert_fixed_worker_unit_pre_dispatch(
    updater: Any, bootstrap: dict[str, Any]
) -> None:
    """Authenticate the root worker before publishing its Condition request."""

    require_root_file(COMMISSIONER_UNIT_FILE, mode=0o644, group=0)
    if sha256_file(COMMISSIONER_UNIT_FILE) != bootstrap.get(
        "databaseCommissionerUnitSha256"
    ):
        fail("database commissioner unit differs from the reviewed runtime contract")
    expected = {
        "ActiveState": {"inactive", "failed"},
        "AmbientCapabilities": {""},
        "DropInPaths": {""},
        "FragmentPath": {str(COMMISSIONER_UNIT_FILE)},
        "Group": {"root"},
        "KillMode": {"control-group"},
        "LoadState": {"loaded"},
        "OOMPolicy": {"stop"},
        "Restart": {"no"},
        "SendSIGKILL": {"yes"},
        "Type": {"oneshot"},
        "UnitFileState": {"static"},
        "User": {"root"},
    }
    for property_name, allowed in expected.items():
        if systemd_state(COMMISSIONER_UNIT, property_name) not in allowed:
            fail(f"database commissioner pre-dispatch unit differs: {property_name}")
    commands = updater.systemd_exec_commands(
        systemd_state(COMMISSIONER_UNIT, "ExecStart"),
        "database commissioner pre-dispatch ExecStart",
    )
    if commands != [
        (
            "/usr/bin/python3",
            "/usr/bin/python3 -I /usr/local/sbin/uten-imp-existing-test-host-db-commissioner worker",
        )
    ]:
        fail("database commissioner pre-dispatch ExecStart differs")
    if systemd_state(COMMISSIONER_UNIT, "RuntimeDirectory") != (
        "uten-imp-internal-db-commissioner"
    ):
        fail("database commissioner pre-dispatch runtime directory differs")
    if systemd_state(COMMISSIONER_UNIT, "RuntimeDirectoryMode") != "0700":
        fail("database commissioner pre-dispatch runtime mode differs")


def archive_worker_request(request_raw: bytes, onboarding: dict[str, Any]) -> Path:
    evidence = Path(str(onboarding.get("evidencePath", "")))
    if (
        evidence.parent != EVIDENCE_BASE
        or evidence.name != onboarding.get("transactionId")
        or TRANSACTION_RE.fullmatch(evidence.name) is None
    ):
        fail("database commissioner worker result escaped its transaction")
    require_root_directory(evidence, mode=0o700)
    require_root_file(WORKER_REQUEST, group=None)
    if WORKER_REQUEST.read_bytes() != request_raw:
        fail("database commissioner worker request changed during execution")
    archived = evidence / "worker-request.committed.json"
    if os.path.lexists(archived):
        require_root_file(archived, group=None)
        if archived.read_bytes() != request_raw:
            fail("archived database commissioner worker request differs")
        durable_unlink(WORKER_REQUEST)
    else:
        os.replace(WORKER_REQUEST, archived)
        fsync_directory(evidence)
        fsync_directory(EVIDENCE_BASE)
    complete_path = evidence / "worker-complete.json"
    complete = {
        "kind": "uten-imp-internal-test-db-worker-receipt",
        "onboardingReceiptSha256": sha256_file(ONBOARDING_RECEIPT),
        "requestSha256": sha256_bytes(request_raw),
        "schemaVersion": 1,
        "status": "FIXED_CGROUP_COMPLETED",
        "transactionId": evidence.name,
    }
    if os.path.lexists(complete_path):
        if strict_json(complete_path, "database worker completion receipt") != complete:
            fail("database worker completion receipt differs")
    else:
        atomic_json(complete_path, complete)
    return complete_path


def worker() -> dict[str, Any]:
    assert_fixed_worker_supervision()
    bootstrap = bootstrap_runtime_contract()
    updater, _guard = load_modules(bootstrap[0])
    contract, contract_sha = runtime_contract(updater, bootstrap)
    request_raw = updater.read_root_evidence_bytes(
        WORKER_REQUEST, maximum_bytes=64 * 1024
    )
    request = _strict_json_bytes(
        request_raw, "database commissioner worker request"
    )
    validate_worker_request_live(
        request,
        contract=contract,
        runtime_contract_sha256=contract_sha,
    )
    onboarding = apply(
        request["version"],
        request["approvalReference"],
        worker_request_sha256=sha256_bytes(request_raw),
        worker_request=request,
    )
    complete = archive_worker_request(request_raw, onboarding)
    return {
        "status": "FIXED_CGROUP_COMPLETED",
        "transactionId": onboarding["transactionId"],
        "workerReceiptPath": str(complete),
    }


def dispatch_worker(version: str, approval: str) -> dict[str, Any]:
    if os.geteuid() != 0:
        fail("database commissioning apply/resume must run as root")
    if not VERSION_RE.fullmatch(version) or not APPROVAL_RE.fullmatch(approval):
        fail("version or approval reference is malformed")
    require_root_directory(EVIDENCE_BASE, mode=0o700)
    # All checks below are read-only and precede the ConditionPathExists grant.
    # The dispatcher must not hold the updater/database locks while synchronously
    # starting the worker, because the fixed worker acquires those same locks.
    bootstrap, _bootstrap_sha = bootstrap_runtime_contract()
    updater, _guard = load_modules(bootstrap)
    require_entry_closed()
    contract, contract_sha = runtime_contract(
        updater, (bootstrap, _bootstrap_sha)
    )
    updater.assert_pre_database_runtime_contract()
    verify_runtime_secret_binding()
    assert_fixed_worker_unit_pre_dispatch(updater, bootstrap)
    request = worker_request_value(
        version,
        approval,
        boot_id=current_boot_id(),
        unit_sha256=str(contract.get("databaseCommissionerUnitSha256", "")),
        runtime_contract_sha256=contract_sha,
    )
    permit_request_sha256: str | None = None
    if os.path.lexists(WORKER_REQUEST):
        request_raw = updater.read_root_evidence_bytes(
            WORKER_REQUEST, maximum_bytes=64 * 1024
        )
        existing = _strict_json_bytes(
            request_raw, "database commissioner worker request"
        )
        validate_worker_request(existing)
        if existing != request:
            fail("another database commissioner worker request is pending")
        permit_request_sha256 = sha256_bytes(request_raw)
    # Publish the fixed request and enqueue the PID-1 worker while holding the
    # release lock.  The worker start is deliberately non-blocking: it queues
    # behind this lock and later consumes the exact request SHA.  From request
    # publication until consumption, StateLock rejects every other release
    # mutation, closing the former publish-to-start race.
    with updater.StateLock(
        updater.DEFAULT_LOCK_FILE,
        internal_test_worker_request_sha256=permit_request_sha256,
    ):
        if os.path.lexists(WORKER_REQUEST):
            request_raw = updater.read_root_evidence_bytes(
                WORKER_REQUEST, maximum_bytes=64 * 1024
            )
            existing = _strict_json_bytes(
                request_raw, "database commissioner worker request"
            )
            validate_worker_request(existing)
            if existing != request:
                fail("another database commissioner worker request is pending")
        else:
            atomic_json(WORKER_REQUEST, request)
        run(["/usr/bin/systemctl", "reset-failed", COMMISSIONER_UNIT], allowed=(0, 1))
        run(
            ["/usr/bin/systemctl", "start", "--no-block", COMMISSIONER_UNIT],
            timeout=30,
        )
    deadline = time.monotonic() + 8 * 3600
    while os.path.lexists(WORKER_REQUEST):
        if time.monotonic() >= deadline:
            fail("database commissioner worker did not reach a durable terminal state")
        active = systemd_state(COMMISSIONER_UNIT, "ActiveState")
        if active == "failed":
            fail("database commissioner worker failed; evidence requires review")
        time.sleep(1)
    if os.path.lexists(WORKER_REQUEST):
        fail("database commissioner worker returned without consuming its request")
    onboarding = strict_json(ONBOARDING_RECEIPT, "internal-test onboarding receipt")
    if (
        onboarding.get("manifest", {}).get("version") != version
        or onboarding.get("approvalReference") != approval
    ):
        fail("database commissioner worker returned another transaction")
    return onboarding


def assess(version: str) -> dict[str, Any]:
    if os.geteuid() != 0:
        fail("database commissioning assessment must run as root")
    if not VERSION_RE.fullmatch(version):
        fail("candidate version is malformed")
    bootstrap = bootstrap_runtime_contract()
    updater, _guard = load_modules(bootstrap[0])
    require_root_directory(ROOT_STATE)
    require_root_directory(RELEASES)
    require_root_directory(UPDATER_STATE)
    # snapshot_candidate creates and removes a root workspace.  Treat assess as
    # a release mutation for locking purposes even though it publishes no ERP
    # state; FINALIZING and every concurrent release transaction must reject it
    # before that workspace can exist.
    with updater.StateLock(updater.DEFAULT_LOCK_FILE):
        require_entry_closed()
        contract, contract_sha = runtime_contract(updater, bootstrap)
        storage_path, storage, storage_sha = storage_receipt()
        live_storage = verify_live_storage(contract, storage_path, storage_sha)
        verify_runtime_secret_binding()
        if os.path.lexists(ACTIVE_POINTER):
            fail("a database commissioning transaction already requires resume")
        if not pgdata_empty():
            fail("storage-commissioned PGDATA is not empty")
        if systemd_state(POSTGRES_UNIT, "ActiveState") not in {"inactive", "failed"}:
            fail("PostgreSQL must be inactive before empty-source assessment")
        snapshot, info = updater.snapshot_candidate(
            UPDATER_STATE / "candidates" / version, RELEASES, ALLOWED_SIGNERS
        )
        try:
            if info["version"] != version:
                fail("signed candidate version differs from the requested version")
            return {
            "candidate": manifest_binding(info, sha256_file(snapshot / "manifest.json"), updater),
            "dataClassification": "discardable-test-only",
            "deploymentProfile": contract["deploymentProfile"],
            "entryEnabled": False,
            "kind": "uten-imp-internal-test-db-assessment",
            "productionAuthority": False,
            "runtimeContractSha256": contract_sha,
            "schemaVersion": 1,
            "status": "READY_FOR_EXPLICIT_APPLY",
            "storageCommissioningReceiptPath": str(storage_path),
            "storageCommissioningReceiptSha256": storage_sha,
            "storageObservationSha256": sha256_bytes(canonical_bytes(live_storage)),
            }
        finally:
            shutil.rmtree(snapshot, ignore_errors=True)


def apply(
    version: str,
    approval: str,
    *,
    worker_request_sha256: str | None = None,
    worker_request: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if os.geteuid() != 0:
        fail("database commissioning apply must run as root")
    if not VERSION_RE.fullmatch(version) or not APPROVAL_RE.fullmatch(approval):
        fail("version or approval reference is malformed")
    bootstrap = bootstrap_runtime_contract()
    updater, guard = load_modules(bootstrap[0])
    with updater.StateLock(
        updater.DEFAULT_LOCK_FILE,
        internal_test_worker_request_sha256=worker_request_sha256,
    ), updater.DatabaseMaintenanceLock():
        require_entry_closed()
        contract, contract_sha = runtime_contract(updater, bootstrap)
        if worker_request is None:
            fail("database commissioning apply requires its fixed worker request")
        validate_worker_request_live(
            worker_request,
            contract=contract,
            runtime_contract_sha256=contract_sha,
        )
        updater.assert_pre_database_runtime_contract()
        # This comparison must happen before the first possible PGDATA write.
        # It catches a Phase4 secret/runtime mismatch while the empty storage
        # proof is still intact; the authenticated probes run after PostgreSQL
        # starts and again for every terminal/resume identity observation.
        verify_runtime_secret_binding()
        storage_path, storage, storage_sha = storage_receipt()
        validate_storage_terminal_contract(contract, storage_path, storage)
        initial_storage_observation = verify_live_storage(
            contract, storage_path, storage_sha
        )
        existing_onboarding: dict[str, Any] | None = None
        if os.path.lexists(ONBOARDING_RECEIPT):
            existing_onboarding = strict_json(
                ONBOARDING_RECEIPT, "internal-test onboarding receipt"
            )
            updater.validate_internal_test_onboarding_receipt(
                existing_onboarding, require_worker_terminal=False
            )
            if (
                existing_onboarding.get("manifest", {}).get("version") != version
                or existing_onboarding.get("approvalReference") != approval
                or existing_onboarding.get("runtimeContractSha256") != contract_sha
                or existing_onboarding.get("storageCommissioningReceiptSha256")
                != storage_sha
            ):
                fail("existing onboarding receipt differs from the requested transaction")
            existing_evidence = Path(existing_onboarding["evidencePath"])
            if not os.path.lexists(ACTIVE_POINTER):
                if (
                    existing_evidence.parent != EVIDENCE_BASE
                    or existing_evidence.name != existing_onboarding.get("transactionId")
                    or not TRANSACTION_RE.fullmatch(existing_evidence.name)
                ):
                    fail("existing onboarding evidence escaped its fixed transaction")
                require_root_directory(existing_evidence, mode=0o700)
                expected_plan_path = existing_evidence / "transaction-manifest.json"
                expected_plan_sha = existing_onboarding.get(
                    "transactionManifestSha256"
                )
                if (
                    existing_onboarding.get("transactionManifestPath")
                    != str(expected_plan_path)
                    or not isinstance(expected_plan_sha, str)
                    or not SHA256_RE.fullmatch(expected_plan_sha)
                    or sha256_file(expected_plan_path) != expected_plan_sha
                ):
                    fail("existing onboarding transaction manifest differs")
                onboarding_sha = sha256_file(ONBOARDING_RECEIPT)
                validate_complete_receipt(
                    existing_evidence,
                    onboarding_sha,
                    expired_awaiting_reauth=(
                        existing_onboarding.get("status")
                        == "EXPIRED_AWAITING_REAUTH"
                    ),
                )
                validate_committed_pointer(existing_evidence, expected_plan_sha)
                existing_plan = strict_json(
                    expected_plan_path, "existing commissioning plan"
                )
                validate_commissioning_authority(existing_evidence, existing_plan)
                metadata, _payload = candidate_paths_from_plan(
                    existing_evidence, existing_plan, version
                )
                _channel, verified_info, _staged = updater.verify_candidate_metadata(
                    metadata, ALLOWED_SIGNERS
                )
                live_identity = database_identity(updater, verified_info)
                if live_identity != existing_onboarding.get("databaseIdentity"):
                    fail("live database drifted after commissioning commitment")
                commit_postgres_boot_contract(existing_evidence)
                resumed_storage = verify_live_storage(
                    contract, storage_path, storage_sha
                )
                write_storage_observation(
                    existing_evidence, "resume-terminal", resumed_storage
                )
                require_entry_closed()
                return existing_onboarding

        if os.path.lexists(ACTIVE_POINTER):
            evidence, plan = resolve_active()
            converge_preactive_after_active(evidence)
            if plan.get("manifest", {}).get("version") != version or plan.get("approvalReference") != approval:
                fail("resume arguments differ from the active database transaction")
            metadata, extracted = candidate_paths_from_plan(evidence, plan, version)
            _channel, info, _staged = updater.verify_candidate_metadata(
                metadata, ALLOWED_SIGNERS
            )
            if info["version"] != version:
                fail("resumed signed candidate differs from the requested version")
            guard.verify_payload(extracted, info)
            manifest = manifest_binding(
                info, sha256_file(metadata / "manifest.json"), updater
            )
            validate_transaction_plan(
                plan,
                evidence=evidence,
                version=version,
                approval=approval,
                manifest=manifest,
                runtime_contract_sha=contract_sha,
                storage_receipt_sha=storage_sha,
                storage_authority_sha=sha256_file(STORAGE_AUTHORITY),
            )
            validate_commissioning_authority(evidence, plan)
        else:
            if not pgdata_empty():
                fail("PGDATA is not the storage-commissioned empty directory")
            transaction, evidence = begin_or_resume_preactive(
                version, approval, contract_sha, storage_sha
            )
            plan_path = evidence / "transaction-manifest.json"
            if plan_path.exists():
                pending_plan = strict_json(plan_path, "database commissioning plan")
                authority_path = evidence / COMMISSIONING_AUTHORITY_NAME
                if authority_path.exists():
                    validate_commissioning_authority(evidence, pending_plan)
                elif os.path.lexists(authority_path):
                    fail("database commissioning authority has an unsafe type")
                else:
                    # A pre-active crash may leave the immutable plan behind.
                    # Refuse an expired plan before touching its candidate tree
                    # or publishing the active transaction pointer.
                    require_fresh_plan(pending_plan)
            info, snapshot = candidate_snapshot(updater, guard, version, evidence)
            extracted = snapshot["extracted"]
            manifest = manifest_binding(info, snapshot["manifestSha256"], updater)
            if plan_path.exists():
                plan = strict_json(plan_path, "database commissioning plan")
            else:
                initial_storage_path, initial_storage_sha = write_storage_observation(
                    evidence, "before-plan", initial_storage_observation
                )
                expiry = (datetime.now(timezone.utc) + timedelta(days=7)).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                )
                plan = {
                    "approvalReference": approval,
                    "commissionerSha256": commissioner_sha256(),
                    "createdAtUtc": utc_now(),
                    "dataClassification": "discardable-test-only",
                    "deploymentProfile": "internal-test-local-v1",
                    "entryEnabled": False,
                    "expiresAtUtc": expiry,
                    "kind": "uten-imp-internal-test-database-commissioning-plan",
                    "manifest": manifest,
                    "candidateMetadataPath": str(snapshot["candidateMetadataPath"]),
                    "candidatePayloadPath": str(extracted),
                    "productionAuthority": False,
                    "payloadInventorySha256": snapshot["payloadInventorySha256"],
                    "runtimeContractSha256": contract_sha,
                    "schemaVersion": 1,
                    "status": "APPROVED_ENTRY_CLOSED",
                    "storageAuthoritySha256": sha256_file(STORAGE_AUTHORITY),
                    "storageCommissioningReceiptSha256": storage_sha,
                    "storageObservation": {
                        "path": str(initial_storage_path),
                        "sha256": initial_storage_sha,
                    },
                    "transactionId": transaction,
                }
                atomic_json(plan_path, plan)
            validate_transaction_plan(
                plan,
                evidence=evidence,
                version=version,
                approval=approval,
                manifest=manifest,
                runtime_contract_sha=contract_sha,
                storage_receipt_sha=storage_sha,
                storage_authority_sha=sha256_file(STORAGE_AUTHORITY),
            )
            authorize_or_resume_commissioning(evidence, plan)
            write_active_pointer(evidence, sha256_file(plan_path))
            converge_preactive_after_active(evidence)
            atomic_json(
                evidence / "empty-source-proof.json",
                {
                    "checkedAtUtc": utc_now(),
                    "directoryEntryCount": 0,
                    "filesystemUuid": storage["filesystemUuid"],
                    "kind": "uten-imp-internal-test-empty-pgdata-proof",
                    "pgData": str(PGDATA),
                    "postgresClusterInitializedBefore": False,
                    "schemaVersion": 1,
                    "status": "EMPTY_PGDATA_CONFIRMED",
                    "transactionId": transaction,
                },
            )

        validate_commissioning_authority(evidence, plan)
        fresh_storage = verify_live_storage(contract, storage_path, storage_sha)
        original_storage = validate_storage_observation_binding(
            evidence, plan.get("storageObservation"), phase="before-plan"
        )
        if fresh_storage["authoritySha256"] != original_storage["authoritySha256"]:
            fail("live storage authority changed before initdb")
        write_storage_observation(
            evidence, "before-initdb", fresh_storage
        )
        initialize_cluster(evidence, storage)
        validate_commissioning_authority(evidence, plan)
        before_postgres = verify_live_storage(contract, storage_path, storage_sha)
        write_storage_observation(evidence, "before-postgres", before_postgres)
        start_postgres()
        configure_roles(evidence)
        run_migrator(evidence, extracted, manifest)
        identity = database_identity(updater, info)
        role_contract = {
            "applicationCreateRevoked": True,
            "applicationRole": "uten",
            "database": "uten_imp",
            "databaseOwner": "uten_owner",
            "migratorCanSetOwner": True,
            "migratorRole": "uten_migrator",
            "ownerRole": "uten_owner",
            "publicCreateRevoked": True,
            "schemaOwner": "uten_owner",
        }
        validate_commissioning_authority(evidence, plan)
        commit_postgres_boot_contract(evidence)
        require_entry_closed()
        validate_commissioning_authority(evidence, plan)
        terminal_storage = verify_live_storage(contract, storage_path, storage_sha)
        terminal_storage_path, terminal_storage_sha = write_storage_observation(
            evidence, "before-terminal", terminal_storage
        )
        # Re-read the signed Flyway history, role/ACL contract and the live
        # archive settings after every remaining privileged mutation.  The
        # internal profile rejects archive_mode=on or any non-empty
        # archive_command, so an old pgBackRest stanza can never be inherited
        # by the newly initialized disposable test cluster.
        terminal_identity = database_identity(updater, info)
        if terminal_identity != identity:
            fail("live database identity drifted before terminal commitment")
        identity = terminal_identity
        terminal = {
            "completedAtUtc": utc_now(),
            "databaseIdentity": identity,
            "entryEnabled": False,
            "kind": "uten-imp-internal-test-migration-terminal",
            "manifest": manifest,
            "roleContract": role_contract,
            "schemaVersion": 1,
            "status": "SIGNED_TARGET_VERIFIED_ENTRY_CLOSED",
            "storageObservationPath": str(terminal_storage_path),
            "storageObservationSha256": terminal_storage_sha,
            "transactionId": evidence.name,
        }
        terminal_path = evidence / "migration-terminal.json"
        if terminal_path.exists():
            existing_terminal = strict_json(terminal_path, "migration terminal")
            comparable_keys = set(terminal) - {
                "completedAtUtc",
                "storageObservationPath",
                "storageObservationSha256",
            }
            if any(
                existing_terminal.get(key) != terminal.get(key)
                for key in comparable_keys
            ):
                fail("existing migration terminal differs from live signed database")
            validate_storage_observation_binding(
                evidence,
                {
                    "path": existing_terminal.get("storageObservationPath"),
                    "sha256": existing_terminal.get("storageObservationSha256"),
                },
                phase="before-terminal",
            )
        else:
            atomic_json(terminal_path, terminal)
        validate_commissioning_authority(evidence, plan)

        commissioning_authority = validate_commissioning_authority(evidence, plan)
        onboarding_completed_at = utc_now()
        # Completion does not mint a fresh authority window.  The onboarding
        # expiry is the original reviewed commissioning-plan expiry; a long
        # safe resume therefore reaches an explicit activation-only reauth
        # state instead of silently renewing its own authority.
        onboarding_expires_at = plan["expiresAtUtc"]
        onboarding_expired = parse_utc(
            onboarding_completed_at, "onboarding completion time"
        ) >= parse_utc(onboarding_expires_at, "onboarding expiry time")
        onboarding = existing_onboarding or {
            "approvalReference": approval,
            "backupEnabled": False,
            "commissionerSha256": commissioner_sha256(),
            "commissioningAuthorityPath": str(
                evidence / COMMISSIONING_AUTHORITY_NAME
            ),
            "commissioningAuthoritySha256": sha256_file(
                evidence / COMMISSIONING_AUTHORITY_NAME
            ),
            "commissioningAuthorizedAtUtc": commissioning_authority[
                "authorizedAtUtc"
            ],
            "commissioningPlanExpiresAtUtc": plan["expiresAtUtc"],
            "commissioningPreActivePath": str(
                evidence / PREACTIVE_ARCHIVE_NAME
            ),
            "commissioningPreActiveSha256": commissioning_authority[
                "preActiveSha256"
            ],
            "completedAtUtc": onboarding_completed_at,
            "currentPublished": False,
            "dataClassification": "discardable-test-only",
            "databaseIdentity": identity,
            "deploymentProfile": "internal-test",
            "emptySourceProofPath": str(evidence / "empty-source-proof.json"),
            "emptySourceProofSha256": sha256_file(evidence / "empty-source-proof.json"),
            "entryEnabled": False,
            "evidencePath": str(evidence),
            "expiresAtUtc": onboarding_expires_at,
            "kind": "uten-imp-internal-test-onboarding",
            "manifest": manifest,
            "migrationTerminalReceiptPath": str(terminal_path),
            "migrationTerminalReceiptSha256": sha256_file(terminal_path),
            "productionAuthority": False,
            "remainingNoGo": ["authoritative-data", "backup-restore", "business-uat"],
            "runtimeContractSha256": contract_sha,
            "schemaVersion": 1,
            "status": (
                "EXPIRED_AWAITING_REAUTH"
                if onboarding_expired
                else "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED"
            ),
            "storageAuthoritySha256": sha256_file(STORAGE_AUTHORITY),
            "storageCommissioningEvidencePath": str(storage_path.parent),
            "storageCommissioningReceiptPath": str(storage_path),
            "storageCommissioningReceiptSha256": storage_sha,
            "storageObservationPath": str(terminal_storage_path),
            "storageObservationSha256": terminal_storage_sha,
            "transactionId": evidence.name,
            "transactionManifestPath": str(evidence / "transaction-manifest.json"),
            "transactionManifestSha256": sha256_file(evidence / "transaction-manifest.json"),
        }
        if existing_onboarding is None:
            atomic_json(ONBOARDING_RECEIPT, onboarding)
        elif (
            onboarding.get("databaseIdentity") != identity
            or onboarding.get("manifest") != manifest
            or onboarding.get("transactionId") != evidence.name
        ):
            fail("existing onboarding receipt differs from the resumed terminal state")
        committed = evidence / "complete.json"
        complete_value = {
            "completedAtUtc": utc_now(),
            "entryEnabled": False,
            "kind": "uten-imp-internal-test-database-commissioning-receipt",
            "onboardingReceiptSha256": sha256_file(ONBOARDING_RECEIPT),
            "productionAuthority": False,
            "schemaVersion": 1,
            "status": (
                "EXPIRED_AWAITING_REAUTH"
                if onboarding_expired
                else "COMMITTED_AWAITING_FIRST_ACTIVATION"
            ),
            "transactionId": evidence.name,
        }
        if committed.exists():
            validate_complete_receipt(
                evidence,
                complete_value["onboardingReceiptSha256"],
                expired_awaiting_reauth=onboarding_expired,
            )
        else:
            atomic_json(committed, complete_value)
            validate_complete_receipt(
                evidence,
                complete_value["onboardingReceiptSha256"],
                expired_awaiting_reauth=onboarding_expired,
            )
        active_archive = evidence / "active-pointer.committed.json"
        if os.path.lexists(ACTIVE_POINTER):
            if os.path.lexists(active_archive):
                fail("live and committed database pointers both exist")
            os.replace(ACTIVE_POINTER, active_archive)
            fsync_directory(EVIDENCE_BASE)
            fsync_directory(evidence)
        elif not active_archive.exists():
            fail("database commissioning active pointer disappeared before commitment")
        validate_committed_pointer(
            evidence, sha256_file(evidence / "transaction-manifest.json")
        )
        return onboarding


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    assess_command = commands.add_parser("assess")
    assess_command.add_argument("--version", required=True)
    apply_command = commands.add_parser("apply")
    apply_command.add_argument("--version", required=True)
    apply_command.add_argument("--approval-reference", required=True)
    resume = commands.add_parser("resume")
    resume.add_argument("--version", required=True)
    resume.add_argument("--approval-reference", required=True)
    reauthorize = commands.add_parser("reauthorize-activation")
    reauthorize.add_argument("--version", required=True)
    reauthorize.add_argument("--approval-reference", required=True)
    commands.add_parser("worker", help=argparse.SUPPRESS)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "assess":
            result = assess(args.version)
        elif args.command == "worker":
            result = worker()
        elif args.command == "reauthorize-activation":
            result = reauthorize_activation(args.version, args.approval_reference)
        else:
            result = dispatch_worker(args.version, args.approval_reference)
    except Exception as exc:
        print(f"INTERNAL_TEST_DB_COMMISSIONING_NO_GO: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
