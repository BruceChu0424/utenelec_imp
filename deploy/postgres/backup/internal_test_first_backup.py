#!/usr/bin/env python3
"""Mint the one local-recovery-only first-backup receipt for internal-test.

This program never starts a backup and never configures PostgreSQL, pgBackRest,
or credentials.  It runs only fixed verification commands while holding the
shared database-maintenance lock, re-authenticates the commissioning candidate,
and creates one fixed root-only receipt with O_EXCL durability semantics.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pwd
import re
import shlex
import stat
import subprocess
import sys
import types
from contextlib import AbstractContextManager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, NoReturn, Sequence

try:
    import fcntl
except ImportError:  # pragma: no cover - production is POSIX only.
    fcntl = None  # type: ignore[assignment]


POSTGRES_USER = "postgres"
RELEASE_STATE = Path("/var/lib/uten-imp-release")
ONBOARDING_RECEIPT = RELEASE_STATE / "internal-test-onboarding.json"
RUNTIME_CONTRACT = RELEASE_STATE / "internal-test-runtime-contract.json"
COMMISSIONING_ROOT = Path("/var/lib/uten-imp-internal-test-commissioning")
BACKUP_TRANSACTION_ROOT = Path("/var/lib/uten-imp-backup-transactions")
BACKUP_TRANSACTION_RECEIPTS = BACKUP_TRANSACTION_ROOT / "receipts"
MAINTENANCE_ROOT = Path("/var/lib/uten-imp-db-maintenance")
MAINTENANCE_LOCK = MAINTENANCE_ROOT / "operation.lock"
RECEIPT_ROOT = Path("/var/lib/uten-imp-internal-test-first-backup")
FIRST_BACKUP_RECEIPT = RECEIPT_ROOT / "first-backup.json"

UPDATER_MODULE = Path("/opt/uten-imp/updater/release_updater.py")
RELEASE_GUARD = Path("/opt/uten-imp/updater/release_guard.py")
ALLOWED_SIGNERS = Path("/etc/uten-imp-release-trust/release-allowed-signers")
INSTALLED_PRODUCER = Path(
    "/usr/local/libexec/uten-imp-backup/internal_test_first_backup.py"
)

PGBACKREST_BASE = (
    "/usr/bin/pgbackrest",
    "--config=/etc/pgbackrest.conf",
    "--config-include-path=/etc/pgbackrest/conf.d",
    "--stanza=uten-imp",
)
PGBACKREST_CHECK = PGBACKREST_BASE + ("--repo=1", "check")
PGBACKREST_INFO = PGBACKREST_BASE + ("--output=json", "--repo=1", "info")
PGBACKREST_BACKUP = PGBACKREST_BASE + (
    "--repo=1",
    "--no-expire-auto",
    "--type=full",
    "backup",
)
PGBACKREST_EXPIRE = PGBACKREST_BASE + ("--repo=1", "expire")

FIXED_ENVIRONMENT = {
    "HOME": "/var/lib/postgresql",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "LOGNAME": POSTGRES_USER,
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "USER": POSTGRES_USER,
}

SCHEMA_VERSION = 1
RECEIPT_KIND = "uten-imp-internal-test-first-local-backup"
RECEIPT_STATUS = "VERIFIED_LOCAL_FIRST_FULL"
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_FULL_AGE_SECONDS = 6 * 60 * 60
RECEIPT_LIFETIME = timedelta(hours=24)
FUTURE_SKEW_SECONDS = 5

SHA256_RE = re.compile(r"[0-9a-f]{64}")
VERSION_RE = re.compile(r"v\d{4}\.\d{2}\.\d{2}-[1-9]\d{0,2}")
TRANSACTION_RE = re.compile(
    r"internal-test-db-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}"
)
LOCKED_TRANSACTION_RE = re.compile(
    r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}"
)
BACKUP_LABEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}")
WAL_RE = re.compile(r"[0-9A-F]{24}(?:\.partial)?")
UTC_RE = re.compile(
    r"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z"
)

# Any live transaction or already-published runtime state makes this one-time
# pre-activation receipt ambiguous.  Each path is inspected through its fixed
# parent directory; unsafe parents fail closed as well.
BLOCKING_MARKERS = (
    RELEASE_STATE / "active.json",
    RELEASE_STATE / "runtime-authority.json",
    RELEASE_STATE / "activation-failed.json",
    RELEASE_STATE / "activation-in-progress.json",
    RELEASE_STATE / "boot-enablement-in-progress.json",
    RELEASE_STATE / "recovery-in-progress.json",
    RELEASE_STATE / "recovery-ingress-pending.json",
    RELEASE_STATE / "recovery-ingress-authorization.json",
    RELEASE_STATE / "recovery-ingress-finalizing.json",
    RELEASE_STATE / "internal-test-onboarding-adoption.json",
    RELEASE_STATE / "internal-test-activation-reauthorization.json",
    RELEASE_STATE / "legacy-current-retirement.json",
    RELEASE_STATE / "retention-in-progress.json",
    Path("/run/uten-imp-release/start-authorization.json"),
    Path("/run/uten-imp-migration-authorization/migration-authorization.json"),
    COMMISSIONING_ROOT / "active.json",
    COMMISSIONING_ROOT / "pre-active.json",
    COMMISSIONING_ROOT / "worker-request.json",
    Path("/var/lib/uten-imp-internal-test-host-preparation/mutation-active.json"),
    Path("/var/lib/uten-imp-nvme-commissioning/active.json"),
    Path("/var/lib/uten-imp-backup-commissioner/active-transaction.json"),
    Path("/var/lib/uten-imp-backup-install/active-transaction.json"),
    BACKUP_TRANSACTION_ROOT / "repo1.active.json",
    BACKUP_TRANSACTION_ROOT / "repo2.active.json",
)

RUNTIME_CONTRACT_KEYS = {
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
    "legacyNginxArchivePath",
    "legacyNginxArchiveSha256",
    "legacyNginxHandoffReceiptPath",
    "legacyNginxHandoffReceiptSha256",
    "migrationAuthorizationHelperSha256",
    "migrationServiceUnitSha256",
    "migratorEnvironmentValidatorSha256",
    "nginxConfigSha256",
    "nginxExpandedConfigSha256",
    "nginxReadinessGateSha256",
    "nginxSystemdDropinSha256",
    "postgresHbaSha256",
    "postgresInternalTestConfigSha256",
    "postgresStorageDropinSha256",
    "recordedAtUtc",
    "recoveryCommitBootUnitSha256",
    "recoveryCommitBootVerifierSha256",
    "recoveryEntrypointSha256",
    "recoveryIngressGateSha256",
    "releaseGuardSha256",
    "releaseUpdaterSha256",
    "runtimeBootVerifierSha256",
    "schemaVersion",
    "serverEnvironmentBridgeReceiptPath",
    "serverEnvironmentBridgeReceiptSha256",
    "serverEnvironmentSha256",
    "serviceUnitSha256",
    "stableAllowedSignersSha256",
    "storageAuthoritySha256",
    "storageBootVerifierSha256",
    "storageCompleteReceiptPath",
    "storageCompleteReceiptSha256",
    "storageLateFinalizationReceiptPath",
    "storageLateFinalizationReceiptSha256",
    "storageMountObserverSha256",
    "storageObserverUnitSha256",
    "storageValidatorSha256",
    "tlsCertificatePath",
    "tlsCertificateSha256",
    "tlsKeyPath",
    "tlsKeySha256",
    "updaterAllowedSignersSha256",
    "updaterEntrypointSha256",
    "updaterEnvironmentValidatorSha256",
    "updaterOssIoSha256",
    "updaterReleaseGuardSha256",
    "updaterRequirementsLockSha256",
    "updaterServiceUnitSha256",
    "updaterSubstrateReceiptPath",
    "updaterSubstrateReceiptSha256",
    "updaterTimerUnitSha256",
    "updaterVenvInventorySha256",
    "watchdogScriptSha256",
    "watchdogServiceUnitSha256",
    "watchdogTimerUnitSha256",
    "wheelhouseSupplyChainSha256",
}


class FirstBackupError(RuntimeError):
    """The fixed first-backup evidence contract could not be proven."""


def fail(message: str) -> NoReturn:
    raise FirstBackupError(message)


def _canonical_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def _pretty_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2)
        + "\n"
    ).encode("utf-8")


def _sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or UTC_RE.fullmatch(value) is None:
        fail(f"{label} must use canonical UTC seconds")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise FirstBackupError(f"{label} is not a real UTC timestamp") from exc


def _utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _exact_keys(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        fail(
            f"{label} schema differs: missing={sorted(expected - actual)}, "
            f"extra={sorted(actual - expected)}"
        )


def _strict_json(raw: bytes, label: str, *, require_object: bool = True) -> Any:
    if not 1 <= len(raw) <= MAX_JSON_BYTES or b"\0" in raw or raw.startswith(b"\xef\xbb\xbf"):
        fail(f"{label} size/encoding boundary differs")

    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in items:
            if key in result:
                fail(f"{label} contains a duplicate JSON key")
            result[key] = item
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda item: fail(
                f"{label} contains a non-finite JSON value: {item}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FirstBackupError(f"{label} is not strict UTF-8 JSON") from exc
    if require_object and not isinstance(value, dict):
        fail(f"{label} must contain exactly one object")
    return value


def _require_root() -> None:
    if (
        os.name != "posix"
        or fcntl is None
        or not hasattr(os, "O_NOFOLLOW")
        or os.geteuid() != 0
        or os.getegid() != 0
    ):
        fail("first-backup receipt production requires POSIX root with flock/O_NOFOLLOW")


def _safe_directory(path: Path, *, mode: int | None = None) -> os.stat_result:
    try:
        before = path.lstat()
    except OSError as exc:
        raise FirstBackupError(f"fixed root directory is unavailable: {path}") from exc
    if (
        not stat.S_ISDIR(before.st_mode)
        or path.is_symlink()
        or before.st_uid != 0
        or before.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(before.st_mode) != mode)
    ):
        fail(f"fixed directory is not root-controlled: {path}")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise FirstBackupError(f"fixed root directory cannot be safely opened: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_mode & 0o022
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or (mode is not None and stat.S_IMODE(opened.st_mode) != mode)
        ):
            fail(f"fixed root directory changed during inspection: {path}")
    finally:
        os.close(descriptor)
    return before


def _safe_chain(path: Path) -> None:
    if not path.is_absolute():
        fail("fixed evidence path must be absolute")
    current = Path("/")
    _safe_directory(current)
    for part in path.parts[1:]:
        current /= part
        _safe_directory(current)


def _read_root_bytes(
    path: Path,
    label: str,
    *,
    mode: int | None = 0o600,
    maximum: int = MAX_JSON_BYTES,
) -> tuple[bytes, os.stat_result]:
    _safe_chain(path.parent)
    try:
        before = path.lstat()
    except OSError as exc:
        raise FirstBackupError(f"{label} is unavailable at its fixed path") from exc
    if (
        not stat.S_ISREG(before.st_mode)
        or path.is_symlink()
        or before.st_uid != 0
        or before.st_gid != 0
        or before.st_nlink != 1
        or before.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(before.st_mode) != mode)
        or not 1 <= before.st_size <= maximum
    ):
        fail(f"{label} must be one bounded root:root non-writable file")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise FirstBackupError(f"{label} cannot be safely opened") from exc
    try:
        opened = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_nlink, before.st_size)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_gid != 0
            or opened.st_nlink != 1
            or opened.st_mode & 0o022
            or (mode is not None and stat.S_IMODE(opened.st_mode) != mode)
            or (opened.st_dev, opened.st_ino, opened.st_nlink, opened.st_size)
            != identity
        ):
            fail(f"{label} changed before read")
        chunks: list[bytes] = []
        remaining = opened.st_size
        while remaining:
            block = os.read(descriptor, min(remaining, 1024 * 1024))
            if not block:
                fail(f"{label} truncated during read")
            chunks.append(block)
            remaining -= len(block)
        if os.read(descriptor, 1):
            fail(f"{label} grew during read")
        after = os.fstat(descriptor)
        if (after.st_dev, after.st_ino, after.st_nlink, after.st_size) != identity:
            fail(f"{label} changed during read")
        return b"".join(chunks), after
    finally:
        os.close(descriptor)


def _read_root_json(
    path: Path,
    label: str,
    *,
    mode: int | None = 0o600,
    canonical: str | None = None,
) -> tuple[dict[str, Any], bytes]:
    raw, _details = _read_root_bytes(path, label, mode=mode)
    value = _strict_json(raw, label)
    assert isinstance(value, dict)
    expected = None
    if canonical == "compact":
        expected = _canonical_bytes(value)
    elif canonical == "pretty":
        expected = _pretty_bytes(value)
    if expected is not None and raw != expected:
        fail(f"{label} bytes are not canonical {canonical} JSON")
    return value, raw


def _file_sha(path: Path, label: str, *, mode: int | None = None) -> str:
    raw, _details = _read_root_bytes(path, label, mode=mode)
    return _sha256(raw)


def _marker_absent(path: Path) -> None:
    # A missing fixed leaf directory is a proven absence only after its parent
    # chain has been authenticated.  Existing leaves must themselves be safe.
    parent = path.parent
    if not os.path.lexists(parent):
        _safe_chain(parent.parent)
        return
    _safe_chain(parent)
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(parent, flags)
    try:
        try:
            os.stat(path.name, dir_fd=descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return
        except OSError as exc:
            raise FirstBackupError(f"blocking marker cannot be safely inspected: {path}") from exc
        fail(f"blocking release/commissioning marker is present: {path}")
    finally:
        os.close(descriptor)


def assert_no_markers() -> None:
    for marker in BLOCKING_MARKERS:
        _marker_absent(marker)


class MaintenanceLock(AbstractContextManager["MaintenanceLock"]):
    """Hold the same root:postgres lock used by migration and backup jobs."""

    def __init__(self) -> None:
        self.descriptor: int | None = None

    def __enter__(self) -> "MaintenanceLock":
        if fcntl is None:
            fail("database maintenance locking requires POSIX flock")
        _require_root()
        try:
            postgres = pwd.getpwnam(POSTGRES_USER)
        except KeyError as exc:
            raise FirstBackupError("postgres service identity is unavailable") from exc
        directory = MAINTENANCE_ROOT.lstat()
        if (
            not stat.S_ISDIR(directory.st_mode)
            or MAINTENANCE_ROOT.is_symlink()
            or directory.st_uid != 0
            or directory.st_gid != postgres.pw_gid
            or stat.S_IMODE(directory.st_mode) != 0o750
        ):
            fail("database maintenance directory must be root:postgres 0750")
        before = MAINTENANCE_LOCK.lstat()
        flags = os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        try:
            descriptor = os.open(MAINTENANCE_LOCK, flags)
        except OSError as exc:
            raise FirstBackupError("database maintenance lock cannot be opened") from exc
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
            fail("database maintenance lock must be one root:postgres 0660 file")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(descriptor)
            raise FirstBackupError("another database maintenance operation is running") from exc
        except OSError as exc:
            os.close(descriptor)
            raise FirstBackupError("database maintenance lock cannot be acquired") from exc
        self.descriptor = descriptor
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor is not None:
            assert fcntl is not None
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


UPDATER_PATH_GUARD_BOOTSTRAP = b'''_GUARD_PATH = Path(__file__).resolve().with_name("release_guard.py")
_GUARD_SPEC = importlib.util.spec_from_file_location("uten_imp_release_guard", _GUARD_PATH)
if _GUARD_SPEC is None or _GUARD_SPEC.loader is None:
    raise RuntimeError(f"cannot load trusted release guard: {_GUARD_PATH}")
release_guard = importlib.util.module_from_spec(_GUARD_SPEC)
_GUARD_SPEC.loader.exec_module(release_guard)
'''
UPDATER_PREVERIFIED_GUARD_MARKERS = (
    b'_PREVERIFIED_GUARD_GLOBAL = "_UTEN_PREVERIFIED_RELEASE_GUARD"',
    b"globals().get(_PREVERIFIED_GUARD_GLOBAL",
    b"_validate_release_guard_module(_preverified_guard, _GUARD_PATH)",
)


def _exec_captured_module(
    raw: bytes,
    path: Path,
    name: str,
    *,
    stable_release_guard: Any | None = None,
) -> Any:
    """Execute only already-captured bytes, never re-open ``path`` as code."""

    if not raw or len(raw) > 8 * 1024 * 1024 or b"\0" in raw or raw.startswith(b"\xef\xbb\xbf"):
        fail(f"captured module bytes are outside the reviewed boundary: {path}")
    source = raw
    injected: dict[str, Any] = {}
    if stable_release_guard is not None:
        if all(source.count(marker) == 1 for marker in UPDATER_PREVERIFIED_GUARD_MARKERS):
            # Current updater contract: execute its captured bytes unchanged and
            # satisfy its explicit preverified-module injection point.
            injected["_UTEN_PREVERIFIED_RELEASE_GUARD"] = stable_release_guard
        elif source.count(UPDATER_PATH_GUARD_BOOTSTRAP) == 1:
            # Narrow compatibility with the immediately preceding reviewed
            # updater.  Replace only its exact six-line path importer.
            source = source.replace(
                UPDATER_PATH_GUARD_BOOTSTRAP,
                b"release_guard = __stable_release_guard__\n",
                1,
            )
            injected["__stable_release_guard__"] = stable_release_guard
        else:
            fail("pinned updater guard bootstrap differs from the reviewed source")
    try:
        code = compile(source, str(path), "exec", dont_inherit=True)
    except (SyntaxError, UnicodeDecodeError) as exc:
        raise FirstBackupError(f"captured pinned module cannot be compiled: {path}") from exc
    module = types.ModuleType(name)
    module.__file__ = str(path)
    module.__package__ = ""
    module.__dict__.update(injected)
    # Some stdlib decorators resolve the executing module by name.  Publish the
    # in-memory object only for the duration of exec and remove it on failure.
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


def _bootstrap_runtime() -> tuple[dict[str, Any], bytes, Any, Any]:
    contract, contract_raw = _read_root_json(
        RUNTIME_CONTRACT, "internal-test runtime contract", canonical="pretty"
    )
    _exact_keys(contract, RUNTIME_CONTRACT_KEYS, "internal-test runtime contract")
    if (
        contract.get("schemaVersion") != 1
        or isinstance(contract.get("schemaVersion"), bool)
        or contract.get("contractId") != "uten-imp-internal-test-runtime-v1"
        or contract.get("deploymentProfile") != "internal-test-local-v1"
    ):
        fail("runtime contract is not the reviewed internal-test profile")
    _utc(contract.get("recordedAtUtc"), "runtime contract timestamp")
    for key in RUNTIME_CONTRACT_KEYS:
        if key.endswith("Sha256") and (
            not isinstance(contract.get(key), str)
            or SHA256_RE.fullmatch(str(contract[key])) is None
        ):
            fail(f"runtime contract digest is malformed: {key}")
    pins = (
        ("releaseUpdaterSha256", UPDATER_MODULE),
        ("updaterReleaseGuardSha256", RELEASE_GUARD),
        ("stableAllowedSignersSha256", ALLOWED_SIGNERS),
    )
    captured: dict[str, bytes] = {}
    for key, path in pins:
        raw, _details = _read_root_bytes(path, key, mode=None)
        if _sha256(raw) != contract[key]:
            fail(f"runtime contract pinned file changed: {key}")
        captured[key] = raw
    if contract["stableAllowedSignersSha256"] != contract["updaterAllowedSignersSha256"]:
        fail("stable and updater allowed-signers authorities differ")
    guard = _exec_captured_module(
        captured["updaterReleaseGuardSha256"],
        RELEASE_GUARD,
        "uten_first_backup_guard",
    )
    updater = _exec_captured_module(
        captured["releaseUpdaterSha256"],
        UPDATER_MODULE,
        "uten_first_backup_updater",
        stable_release_guard=guard,
    )
    validated_contract, validated_sha = updater.internal_test_runtime_contract()
    if validated_contract != contract or validated_sha != _sha256(contract_raw):
        fail("installed updater and bootstrap disagree on the runtime contract")
    return contract, contract_raw, updater, guard


def _payload_inventory_sha256(root: Path) -> str:
    _safe_chain(root)
    inventory: list[dict[str, str]] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        details = path.lstat()
        if path.is_symlink() or not (
            stat.S_ISDIR(details.st_mode) or stat.S_ISREG(details.st_mode)
        ):
            fail("candidate payload contains an unsafe file type")
        if details.st_uid != 0 or details.st_mode & 0o022:
            fail("candidate payload escaped root control")
        if stat.S_ISREG(details.st_mode):
            raw, _opened = _read_root_bytes(
                path,
                "candidate payload file",
                mode=None,
                maximum=8 * 1024 * 1024 * 1024,
            )
            inventory.append(
                {"path": path.relative_to(root).as_posix(), "sha256": _sha256(raw)}
            )
    return _sha256(_pretty_bytes(inventory))


def _candidate_binding(info: dict[str, Any], manifest_sha: str, updater: Any) -> dict[str, Any]:
    return {
        "commitSha": info["commitSha"],
        "flywayHeadVersion": info["flywayHeadVersion"],
        "flywayMigrationSetSha256": info["flywayMigrationSetSha256"],
        "manifestSha256": manifest_sha,
        "migratorJarSha256": info["executableSha256s"]["server/uten-imp-migrator.jar"],
        "releaseSequence": info["releaseSequence"],
        "serverJarSha256": info["executableSha256s"]["server/uten-imp-server.jar"],
        "signedFlywayProjectionSha256": _sha256(
            updater.canonical_signed_flyway_projection(info)
        ),
        "signingKeyId": info["signingKeyId"],
        "version": info["version"],
    }


def load_authority() -> dict[str, Any]:
    contract, contract_raw, updater, guard = _bootstrap_runtime()
    onboarding, onboarding_raw = _read_root_json(
        ONBOARDING_RECEIPT, "internal-test onboarding receipt", canonical="pretty"
    )
    transaction_id = onboarding.get("transactionId")
    if not isinstance(transaction_id, str) or TRANSACTION_RE.fullmatch(transaction_id) is None:
        fail("onboarding transaction identity is malformed")
    evidence = COMMISSIONING_ROOT / transaction_id
    if onboarding.get("evidencePath") != str(evidence):
        fail("onboarding evidence escaped the fixed commissioning transaction")
    _safe_directory(COMMISSIONING_ROOT)
    _safe_directory(evidence, mode=0o700)
    plan_path = evidence / "transaction-manifest.json"
    if onboarding.get("transactionManifestPath") != str(plan_path):
        fail("onboarding transaction manifest path differs")
    plan, plan_raw = _read_root_json(
        plan_path, "internal-test commissioning plan", canonical="pretty"
    )
    if onboarding.get("transactionManifestSha256") != _sha256(plan_raw):
        fail("onboarding transaction manifest digest changed")
    version = onboarding.get("manifest", {}).get("version")
    if not isinstance(version, str) or VERSION_RE.fullmatch(version) is None:
        fail("onboarding candidate version is malformed")
    metadata = Path(str(plan.get("candidateMetadataPath", "")))
    payload = Path(str(plan.get("candidatePayloadPath", "")))
    build = metadata.parent
    if (
        build.parent != evidence
        or re.fullmatch(r"candidate-build-[1-9][0-9]*", build.name) is None
        or metadata.name != "candidate-metadata"
        or payload.parent != build / "payload"
        or payload.name != version
    ):
        fail("signed candidate escaped its fixed commissioning generation")
    _safe_directory(build, mode=0o700)
    _safe_directory(metadata, mode=0o700)
    _safe_directory(payload.parent, mode=0o700)
    _safe_directory(payload, mode=0o700)
    _channel, info, _staged = updater.verify_candidate_metadata(metadata, ALLOWED_SIGNERS)
    if info.get("version") != version:
        fail("authenticated candidate version differs from onboarding")
    guard.verify_payload(payload, info)
    manifest_raw, _manifest_details = _read_root_bytes(
        metadata / "manifest.json", "signed candidate manifest", mode=0o600
    )
    binding = _candidate_binding(info, _sha256(manifest_raw), updater)
    if binding != onboarding.get("manifest") or plan.get("manifest") != binding:
        fail("onboarding/plan differ from the authenticated candidate manifest")
    payload_sha = _payload_inventory_sha256(payload)
    if plan.get("payloadInventorySha256") != payload_sha:
        fail("commissioning candidate payload inventory changed")
    updater.validate_internal_test_onboarding_receipt(
        onboarding,
        require_worker_terminal=True,
        authenticated_expected_target=info,
        allow_expired_origin=True,
    )
    if onboarding.get("status") not in {
        "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
        "EXPIRED_AWAITING_REAUTH",
    }:
        fail("internal-test onboarding is not terminal")
    fingerprint_fields = {
        "candidateBinding": binding,
        "candidatePayloadInventorySha256": payload_sha,
        "onboardingSha256": _sha256(onboarding_raw),
        "runtimeContractSha256": _sha256(contract_raw),
        "transactionManifestSha256": _sha256(plan_raw),
    }
    return {
        "binding": binding,
        "contract": contract,
        "fingerprint": _sha256(_canonical_bytes(fingerprint_fields)),
        "fingerprintFields": fingerprint_fields,
        "info": info,
        "onboarding": onboarding,
        "onboardingRaw": onboarding_raw,
        "plan": plan,
        "updater": updater,
    }


def observe_live_database(authority: Mapping[str, Any]) -> dict[str, Any]:
    updater = authority["updater"]
    observed = updater.observe_live_database()
    evidence = updater.validate_live_database_against_signed_release(
        observed,
        target_manifest=authority["info"],
        require_internal_role_acl=False,
    )
    if observed.get("archiveMode") != "on" or observed.get("inRecovery") is not False:
        fail("first backup requires the writable archive-enabled primary")
    command = observed.get("archiveCommand")
    if not isinstance(command, str):
        fail("PostgreSQL archive_command is unavailable")
    try:
        argv = shlex.split(command, posix=True)
    except ValueError as exc:
        raise FirstBackupError("PostgreSQL archive_command cannot be parsed") from exc
    if argv and argv[0] == "/usr/bin/pgbackrest":
        argv[0] = "pgbackrest"
    if argv != ["pgbackrest", "--stanza=uten-imp", "archive-push", "%p"]:
        fail("PostgreSQL archive_command is not the fixed pgBackRest command")
    expected_acl = updater.internal_test_role_acl_contract()
    if observed.get("roleAclContract") != expected_acl:
        fail("live internal-test role/ownership/ACL contract changed")
    identity = {
        "canonicalHistorySha256": evidence["flyway"]["canonicalHistorySha256"],
        "headVersion": evidence["flyway"]["headVersion"],
        "roleAclContractSha256": _sha256(_canonical_bytes(expected_acl).rstrip(b"\n")),
        "signedProjectionSha256": evidence["flyway"]["signedProjectionSha256"],
        "successfulMigrationCount": evidence["flyway"]["successfulMigrationCount"],
        "systemIdentifier": evidence["systemIdentifier"],
        "timeline": evidence["timeline"],
    }
    # release_updater hashes this map without a trailing newline.
    identity["roleAclContractSha256"] = hashlib.sha256(
        json.dumps(expected_acl, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    if identity != authority["onboarding"].get("databaseIdentity"):
        fail("live system identifier/timeline/Flyway projection differs from onboarding")
    return identity


def _run_as_postgres(command: Sequence[str], *, capture: bool, timeout: int) -> bytes:
    if tuple(command) not in {PGBACKREST_CHECK, PGBACKREST_INFO}:
        fail("unreviewed pgBackRest command was refused")
    argv = ["/usr/sbin/runuser", "-u", POSTGRES_USER, "--", *command]
    try:
        result = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=FIXED_ENVIRONMENT,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise FirstBackupError("fixed pgBackRest verification could not complete") from exc
    if result.returncode != 0:
        fail("fixed pgBackRest verification exited non-zero")
    output = result.stdout if capture else b""
    if len(output) > MAX_JSON_BYTES:
        fail("pgBackRest verification output exceeded its bound")
    return output


def run_repo1_check() -> dict[str, Any]:
    _run_as_postgres(PGBACKREST_CHECK, capture=False, timeout=300)
    completed = datetime.now(timezone.utc).replace(microsecond=0)
    return {
        "commandSha256": _sha256(_canonical_bytes(list(PGBACKREST_CHECK))),
        "completedAtUtc": _utc_text(completed),
        "passed": True,
        "repository": 1,
    }


def validate_repo1_check(
    value: Mapping[str, Any], *, onboarding_completed_at: datetime, now: datetime
) -> dict[str, Any]:
    _exact_keys(
        value,
        {"commandSha256", "completedAtUtc", "passed", "repository"},
        "pgBackRest repo1 check evidence",
    )
    expected_command_sha = _sha256(_canonical_bytes(list(PGBACKREST_CHECK)))
    completed = _utc(value.get("completedAtUtc"), "pgBackRest repo1 check completion")
    age = (now - completed).total_seconds()
    if (
        value.get("commandSha256") != expected_command_sha
        or value.get("passed") is not True
        or value.get("repository") != 1
        or completed < onboarding_completed_at
        or age < -FUTURE_SKEW_SECONDS
        or age > 10 * 60
    ):
        fail("pgBackRest repo1 check is not a fresh fixed-command PASS")
    return dict(value)


def load_repo1_info() -> bytes:
    return _run_as_postgres(PGBACKREST_INFO, capture=True, timeout=120)


def parse_latest_full(
    raw: bytes,
    *,
    identity: Mapping[str, Any],
    onboarding_completed_at: datetime,
    now: datetime,
) -> dict[str, Any]:
    value = _strict_json(raw, "pgBackRest repo1 info", require_object=False)
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        fail("pgBackRest repo1 info must contain exactly one stanza")
    stanza = value[0]
    status = stanza.get("status")
    repositories = stanza.get("repo")
    matching_repo = (
        [item for item in repositories if isinstance(item, dict) and item.get("key") == 1]
        if isinstance(repositories, list)
        else []
    )
    if (
        stanza.get("name") != "uten-imp"
        or not isinstance(status, dict)
        or status.get("code") != 0
        or len(matching_repo) != 1
        or not isinstance(matching_repo[0].get("status"), dict)
        or matching_repo[0]["status"].get("code") != 0
    ):
        fail("pgBackRest repo1 stanza/repository is unhealthy or ambiguous")
    databases = stanza.get("db")
    matching_db = (
        [
            item
            for item in databases
            if isinstance(item, dict)
            and str(item.get("system-id")) == identity.get("systemIdentifier")
        ]
        if isinstance(databases, list)
        else []
    )
    if len(matching_db) != 1:
        fail("pgBackRest repo1 does not identify the live PostgreSQL system")
    database_id = matching_db[0].get("id")
    if isinstance(database_id, bool) or not isinstance(database_id, int) or database_id < 1:
        fail("pgBackRest repo1 database identity is malformed")
    backups = stanza.get("backup")
    if not isinstance(backups, list):
        fail("pgBackRest repo1 backup inventory is missing")
    current_backups: list[dict[str, Any]] = []
    labels: set[str] = set()
    for backup in backups:
        if not isinstance(backup, dict):
            fail("pgBackRest repo1 backup entry is malformed")
        label = backup.get("label")
        if not isinstance(label, str) or BACKUP_LABEL_RE.fullmatch(label) is None or label in labels:
            fail("pgBackRest repo1 backup label is invalid or duplicated")
        labels.add(label)
        database = backup.get("database")
        if not isinstance(database, dict) or (
            database.get("repo-key") != 1 or database.get("id") != database_id
        ):
            continue
        timestamp = backup.get("timestamp")
        stop = timestamp.get("stop") if isinstance(timestamp, dict) else None
        backup_type = backup.get("type")
        if (
            backup.get("error") not in (None, False)
            or backup_type not in {"full", "diff", "incr"}
            or isinstance(stop, bool)
            or not isinstance(stop, int)
            or stop < 1
        ):
            fail("pgBackRest current-system backup is unhealthy or malformed")
        current_backups.append(
            {"label": label, "stopEpoch": stop, "type": backup_type}
        )
        if backup_type != "full":
            continue
        archive = backup.get("archive")
        wal_start = archive.get("start") if isinstance(archive, dict) else None
        wal_stop = archive.get("stop") if isinstance(archive, dict) else None
        if (
            not isinstance(wal_start, str)
            or WAL_RE.fullmatch(wal_start) is None
            or not isinstance(wal_stop, str)
            or WAL_RE.fullmatch(wal_stop) is None
            or wal_start > wal_stop
        ):
            fail("pgBackRest full lacks a valid stop time/WAL range")
        current_backups[-1].update({"walStart": wal_start, "walStop": wal_stop})
    if not current_backups:
        fail("pgBackRest repo1 has no successful backup for the live database")
    current_backups.sort(key=lambda item: (item["stopEpoch"], item["label"]))
    latest = current_backups[-1]
    if len(current_backups) > 1 and current_backups[-2]["stopEpoch"] == latest["stopEpoch"]:
        fail("pgBackRest latest successful backup is ambiguous")
    if latest["type"] != "full" or "walStart" not in latest or "walStop" not in latest:
        fail("pgBackRest latest backup for the live database is not a full with WAL")
    age = int(now.timestamp()) - latest["stopEpoch"]
    if age < -FUTURE_SKEW_SECONDS or age > MAX_FULL_AGE_SECONDS:
        fail("pgBackRest latest successful full is not fresh")
    if latest["stopEpoch"] < int(onboarding_completed_at.timestamp()):
        fail("pgBackRest latest full predates terminal internal-test onboarding")
    timeline = identity.get("timeline")
    if isinstance(timeline, bool) or not isinstance(timeline, int) or not 1 <= timeline <= 0xFFFFFFFF:
        fail("live PostgreSQL timeline is malformed")
    prefix = f"{timeline:08X}"
    if not latest["walStart"].startswith(prefix) or not latest["walStop"].startswith(prefix):
        fail("pgBackRest latest full WAL range differs from the live timeline")
    latest["ageSeconds"] = max(age, 0)
    latest["databaseId"] = database_id
    latest["infoSha256"] = _sha256(raw)
    latest["repository"] = 1
    latest["systemIdentifier"] = identity["systemIdentifier"]
    latest["timeline"] = timeline
    return latest


def _validate_inventory(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("locked_job inventory must be one object")
    _exact_keys(value, {"repository", "stanza", "backups", "inventorySha256"}, "locked_job inventory")
    if value.get("repository") != 1 or value.get("stanza") != "uten-imp":
        fail("locked_job inventory repository/stanza differs")
    backups = value.get("backups")
    if not isinstance(backups, list):
        fail("locked_job inventory backup list is malformed")
    normalized: list[dict[str, Any]] = []
    labels: set[str] = set()
    for item in backups:
        if not isinstance(item, dict):
            fail("locked_job inventory entry is malformed")
        _exact_keys(item, {"label", "type", "stopEpoch"}, "locked_job inventory entry")
        label = item.get("label")
        backup_type = item.get("type")
        stop = item.get("stopEpoch")
        if (
            not isinstance(label, str)
            or BACKUP_LABEL_RE.fullmatch(label) is None
            or label in labels
            or backup_type not in {"full", "diff", "incr"}
            or isinstance(stop, bool)
            or not isinstance(stop, int)
            or stop < 1
        ):
            fail("locked_job inventory identity is invalid")
        labels.add(label)
        normalized.append({"label": label, "type": backup_type, "stopEpoch": stop})
    normalized.sort(key=lambda item: item["label"])
    expected_sha = _sha256(_canonical_bytes(normalized))
    if value.get("inventorySha256") != expected_sha:
        fail("locked_job inventory digest is inconsistent")
    return {
        "repository": 1,
        "stanza": "uten-imp",
        "backups": normalized,
        "inventorySha256": expected_sha,
    }


def validate_locked_job_receipt(value: dict[str, Any], latest: Mapping[str, Any]) -> dict[str, Any]:
    _exact_keys(value, {"schemaVersion", "kind", "transaction", "containsSecrets"}, "locked_job receipt")
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("kind") != "uten-imp-pgbackrest-backup-transaction-receipt"
        or value.get("containsSecrets") is not False
        or not isinstance(value.get("transaction"), dict)
    ):
        fail("locked_job receipt identity differs")
    tx = value["transaction"]
    expected_keys = {
        "schemaVersion", "kind", "transactionId", "job", "repository", "phase",
        "createdAtUtc", "updatedAtUtc", "preInventory", "backupCommandSha256",
        "expireCommandSha256", "postBackupInventory", "committedBackup",
        "committedAtUtc", "expireStartedAtUtc", "finalInventory", "completedAtUtc",
    }
    _exact_keys(tx, expected_keys, "locked_job terminal transaction")
    transaction_id = tx.get("transactionId")
    if (
        tx.get("schemaVersion") != 1
        or tx.get("kind") != "uten-imp-pgbackrest-backup-transaction"
        or not isinstance(transaction_id, str)
        or LOCKED_TRANSACTION_RE.fullmatch(transaction_id) is None
        or tx.get("job") != "repo1"
        or tx.get("repository") != 1
        or tx.get("phase") != "complete"
        or tx.get("backupCommandSha256")
        != _sha256(_canonical_bytes(list(PGBACKREST_BACKUP)))
        or tx.get("expireCommandSha256")
        != _sha256(_canonical_bytes(list(PGBACKREST_EXPIRE)))
    ):
        fail("locked_job terminal transaction identity/commands differ")
    times = [
        _utc(tx.get(key), f"locked_job {key}")
        for key in (
            "createdAtUtc", "committedAtUtc", "expireStartedAtUtc", "completedAtUtc",
        )
    ]
    updated = _utc(tx.get("updatedAtUtc"), "locked_job updatedAtUtc")
    backup_stop = datetime.fromtimestamp(int(latest["stopEpoch"]), tz=timezone.utc)
    if (
        times != sorted(times)
        or not times[-2] <= updated <= times[-1]
        or not times[0] <= backup_stop <= times[1]
    ):
        fail("locked_job terminal chronology differs")
    pre = _validate_inventory(tx.get("preInventory"))
    post = _validate_inventory(tx.get("postBackupInventory"))
    final = _validate_inventory(tx.get("finalInventory"))
    before = {item["label"]: item for item in pre["backups"]}
    after = {item["label"]: item for item in post["backups"]}
    final_map = {item["label"]: item for item in final["backups"]}
    added = sorted(set(after) - set(before))
    committed = tx.get("committedBackup")
    if (
        not set(before).issubset(after)
        or len(added) != 1
        or not isinstance(committed, dict)
        or set(committed) != {"label", "type", "stopEpoch"}
        or committed != after.get(added[0])
        or committed.get("type") != "full"
        or committed.get("label") not in final_map
        or not set(final_map).issubset(after)
    ):
        fail("locked_job receipt does not prove exactly one durable new full")
    if (
        committed.get("label") != latest.get("label")
        or committed.get("stopEpoch") != latest.get("stopEpoch")
    ):
        fail("locked_job receipt differs from the latest repo1 full")
    return tx


def find_locked_job_receipt(latest: Mapping[str, Any]) -> dict[str, Any]:
    _safe_directory(BACKUP_TRANSACTION_ROOT, mode=0o700)
    _safe_directory(BACKUP_TRANSACTION_RECEIPTS, mode=0o700)
    matches: list[dict[str, Any]] = []
    for path in sorted(BACKUP_TRANSACTION_RECEIPTS.iterdir(), key=lambda item: item.name):
        if re.fullmatch(r"repo1-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}\.json", path.name) is None:
            continue
        value, raw = _read_root_json(
            path, "locked_job terminal receipt", canonical="compact"
        )
        try:
            transaction = validate_locked_job_receipt(value, latest)
        except FirstBackupError:
            continue
        if path.name != f"repo1-{transaction['transactionId']}.json":
            fail("locked_job receipt filename differs from its transaction")
        matches.append(
            {
                "completedAtUtc": transaction["completedAtUtc"],
                "path": str(path),
                "sha256": _sha256(raw),
                "transactionId": transaction["transactionId"],
            }
        )
    if len(matches) != 1:
        fail("latest repo1 full must bind exactly one canonical locked_job terminal receipt")
    return matches[0]


def _producer_identity() -> dict[str, str]:
    resolved = Path(__file__).resolve()
    if resolved != INSTALLED_PRODUCER:
        fail("first-backup producer must run from its fixed installed path")
    raw, _details = _read_root_bytes(
        INSTALLED_PRODUCER,
        "installed first-backup producer",
        mode=0o755,
        maximum=2 * 1024 * 1024,
    )
    return {"path": str(INSTALLED_PRODUCER), "sha256": _sha256(raw)}


def _ensure_receipt_root() -> int:
    _safe_chain(RECEIPT_ROOT.parent)
    parent_flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    parent_flags |= getattr(os, "O_DIRECTORY", 0)
    parent_fd = os.open(RECEIPT_ROOT.parent, parent_flags)
    try:
        if not os.path.lexists(RECEIPT_ROOT):
            try:
                os.mkdir(RECEIPT_ROOT.name, 0o700, dir_fd=parent_fd)
                os.fsync(parent_fd)
            except FileExistsError:
                pass
        _safe_directory(RECEIPT_ROOT, mode=0o700)
        flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_DIRECTORY", 0)
        descriptor = os.open(RECEIPT_ROOT.name, flags, dir_fd=parent_fd)
        opened = os.fstat(descriptor)
        stated = RECEIPT_ROOT.lstat()
        if (
            opened.st_uid != 0
            or opened.st_gid != 0
            or stat.S_IMODE(opened.st_mode) != 0o700
            or (opened.st_dev, opened.st_ino) != (stated.st_dev, stated.st_ino)
        ):
            os.close(descriptor)
            fail("first-backup receipt directory changed during open")
        return descriptor
    finally:
        os.close(parent_fd)


def write_receipt_exclusive(
    value: Mapping[str, Any],
    *,
    directory: Path = RECEIPT_ROOT,
    name: str = "first-backup.json",
    owner_uid: int = 0,
    owner_gid: int = 0,
) -> bytes:
    """Create and durably verify one receipt; injectable path is test-only."""

    raw = _canonical_bytes(dict(value))
    if directory == RECEIPT_ROOT and name == FIRST_BACKUP_RECEIPT.name:
        directory_fd = _ensure_receipt_root()
    else:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        directory_fd = os.open(directory, flags)
    descriptor = -1
    try:
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0)
        )
        try:
            descriptor = os.open(name, flags, 0o600, dir_fd=directory_fd)
        except FileExistsError as exc:
            raise FirstBackupError(
                "fixed first-backup receipt already exists; replay/replacement is forbidden"
            ) from exc
        os.fchown(descriptor, owner_uid, owner_gid)
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            if written <= 0:
                fail("first-backup receipt write made no progress")
            offset += written
        os.fsync(descriptor)
        created = os.fstat(descriptor)
        if (
            not stat.S_ISREG(created.st_mode)
            or created.st_uid != owner_uid
            or created.st_gid != owner_gid
            or stat.S_IMODE(created.st_mode) != 0o600
            or created.st_nlink != 1
            or created.st_size != len(raw)
        ):
            fail("new first-backup receipt metadata differs")
        os.close(descriptor)
        descriptor = -1
        os.fsync(directory_fd)
        read_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        verified_fd = os.open(name, read_flags, dir_fd=directory_fd)
        try:
            verified = os.fstat(verified_fd)
            if (
                (verified.st_dev, verified.st_ino) != (created.st_dev, created.st_ino)
                or verified.st_nlink != 1
                or verified.st_size != len(raw)
                or verified.st_uid != owner_uid
                or verified.st_gid != owner_gid
                or stat.S_IMODE(verified.st_mode) != 0o600
            ):
                fail("first-backup receipt path changed after creation")
            observed = b""
            while len(observed) < len(raw):
                block = os.read(verified_fd, len(raw) - len(observed))
                if not block:
                    fail("first-backup receipt truncated after creation")
                observed += block
            if os.read(verified_fd, 1) or observed != raw:
                fail("first-backup receipt bytes changed after creation")
        finally:
            os.close(verified_fd)
        os.fsync(directory_fd)
        return raw
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(directory_fd)


def build_receipt(
    *,
    authority: Mapping[str, Any],
    identity: Mapping[str, Any],
    latest: Mapping[str, Any],
    check: Mapping[str, Any],
    locked_receipt: Mapping[str, Any],
    producer: Mapping[str, Any],
    now: datetime,
) -> dict[str, Any]:
    created = now.astimezone(timezone.utc).replace(microsecond=0)
    evidence = {
        "candidate": authority["fingerprintFields"]["candidateBinding"],
        "candidatePayloadInventorySha256": authority["fingerprintFields"][
            "candidatePayloadInventorySha256"
        ],
        "lockedJobReceiptSha256": locked_receipt["sha256"],
        "onboardingReceiptSha256": authority["fingerprintFields"]["onboardingSha256"],
        "repo1InfoSha256": latest["infoSha256"],
        "runtimeContractSha256": authority["fingerprintFields"]["runtimeContractSha256"],
        "transactionManifestSha256": authority["fingerprintFields"][
            "transactionManifestSha256"
        ],
    }
    return {
        "backup": {
            "ageSeconds": latest["ageSeconds"],
            "label": latest["label"],
            "lockedJobReceiptPath": locked_receipt["path"],
            "lockedJobReceiptSha256": locked_receipt["sha256"],
            "lockedJobTransactionId": locked_receipt["transactionId"],
            "repository": 1,
            "stopEpoch": latest["stopEpoch"],
            "walStart": latest["walStart"],
            "walStop": latest["walStop"],
        },
        "check": dict(check),
        "containsSecrets": False,
        "createdAtUtc": _utc_text(created),
        "databaseIdentity": dict(identity),
        "deploymentProfile": "internal-test",
        "evidenceSetSha256": _sha256(_canonical_bytes(evidence)),
        "expiresAt": _utc_text(created + RECEIPT_LIFETIME),
        "kind": RECEIPT_KIND,
        "localRecoveryOnly": True,
        "onboarding": {
            "path": str(ONBOARDING_RECEIPT),
            "sha256": authority["fingerprintFields"]["onboardingSha256"],
            "status": authority["onboarding"]["status"],
            "transactionId": authority["onboarding"]["transactionId"],
        },
        "productionAuthority": False,
        "producer": dict(producer),
        "restoreVerified": False,
        "schemaVersion": SCHEMA_VERSION,
        "status": RECEIPT_STATUS,
        "version": authority["binding"]["version"],
    }


def produce_first_backup_receipt(
    *,
    lock_factory: Callable[[], AbstractContextManager[object]] = MaintenanceLock,
    marker_gate: Callable[[], None] = assert_no_markers,
    authority_loader: Callable[[], dict[str, Any]] = load_authority,
    live_observer: Callable[[Mapping[str, Any]], dict[str, Any]] = observe_live_database,
    check_runner: Callable[[], dict[str, Any]] = run_repo1_check,
    info_loader: Callable[[], bytes] = load_repo1_info,
    locked_loader: Callable[[Mapping[str, Any]], dict[str, Any]] = find_locked_job_receipt,
    producer_loader: Callable[[], dict[str, str]] = _producer_identity,
    writer: Callable[[Mapping[str, Any]], bytes] = write_receipt_exclusive,
    now_provider: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
    require_environment: bool = True,
) -> tuple[dict[str, Any], str]:
    if require_environment:
        _require_root()
    with lock_factory():
        marker_gate()
        authority = authority_loader()
        identity = live_observer(authority)
        check = check_runner()
        now = now_provider().astimezone(timezone.utc)
        onboarding_completed = _utc(
            authority["onboarding"]["completedAtUtc"], "onboarding completion time"
        )
        check = validate_repo1_check(
            check, onboarding_completed_at=onboarding_completed, now=now
        )
        latest = parse_latest_full(
            info_loader(),
            identity=identity,
            onboarding_completed_at=onboarding_completed,
            now=now,
        )
        locked_receipt = locked_loader(latest)
        marker_gate()

        # Re-authenticate every path-backed authority and re-sample the live DB,
        # repository inventory and locked receipt before the irreversible O_EXCL.
        repeated_authority = authority_loader()
        if repeated_authority["fingerprint"] != authority["fingerprint"]:
            fail("candidate/onboarding authority changed during verification")
        repeated_identity = live_observer(repeated_authority)
        if repeated_identity != identity:
            fail("live database identity/Flyway projection changed during verification")
        repeated_latest = parse_latest_full(
            info_loader(),
            identity=repeated_identity,
            onboarding_completed_at=onboarding_completed,
            now=now_provider().astimezone(timezone.utc),
        )
        for key in ("label", "stopEpoch", "walStart", "walStop", "systemIdentifier", "timeline"):
            if repeated_latest.get(key) != latest.get(key):
                fail("latest repo1 full changed during verification")
        repeated_locked = locked_loader(repeated_latest)
        if repeated_locked != locked_receipt:
            fail("locked_job terminal receipt changed during verification")
        marker_gate()
        producer = producer_loader()
        receipt = build_receipt(
            authority=authority,
            identity=identity,
            latest=repeated_latest,
            check=check,
            locked_receipt=locked_receipt,
            producer=producer,
            now=now,
        )
        raw = writer(receipt)
    return receipt, _sha256(raw)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Record the fixed internal-test first local backup receipt"
    )
    parser.add_argument("action", choices=("record",))
    args = parser.parse_args(argv)
    if args.action != "record":  # pragma: no cover - argparse enforces this.
        fail("unsupported action")
    receipt, digest = produce_first_backup_receipt()
    print(
        json.dumps(
            {
                "expiresAt": receipt["expiresAt"],
                "path": str(FIRST_BACKUP_RECEIPT),
                "receiptSha256": digest,
                "status": receipt["status"],
                "version": receipt["version"],
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FirstBackupError as exc:
        print(f"FIRST_BACKUP_REFUSED: {exc}", file=sys.stderr)
        raise SystemExit(1)
