#!/usr/bin/env python3
"""Fail-closed ERP boot gate for signed release and live database authority."""

from __future__ import annotations

import fcntl
import grp
import hashlib
import importlib.util
import json
import os
import re
import secrets
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn


RELEASE_BASE = Path("/opt/uten-imp")
RELEASES_DIR = RELEASE_BASE / "releases"
CURRENT_LINK = RELEASE_BASE / "current"
ROOT_STATE_DIR = Path("/var/lib/uten-imp-release")
ACTIVE_STATE = ROOT_STATE_DIR / "active.json"
RUNTIME_AUTHORITY = ROOT_STATE_DIR / "runtime-authority.json"
INTERNAL_TEST_RUNTIME_CONTRACT = ROOT_STATE_DIR / "internal-test-runtime-contract.json"
INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR = (
    ROOT_STATE_DIR / "internal-test-onboarding-evidence"
)
APPLICATION_ENV_FILE = Path("/etc/uten-imp/server.env")
APPLICATION_UNIT_FILE = Path("/etc/systemd/system/uten-imp.service")
INTERNAL_TEST_ENV_VALIDATOR = Path(
    "/usr/local/sbin/uten-imp-validate-internal-test-server-env"
)
INTERNAL_TEST_STORAGE_VALIDATOR = Path(
    "/usr/local/sbin/uten-imp-validate-internal-test-storage"
)
INTERNAL_TEST_DB_COMMISSIONER = Path(
    "/usr/local/sbin/uten-imp-existing-test-host-db-commissioner"
)
INTERNAL_TEST_RELEASE_UPDATER = Path("/opt/uten-imp/updater/release_updater.py")
INTERNAL_TEST_UPDATER_RELEASE_GUARD = Path("/opt/uten-imp/updater/release_guard.py")
INTERNAL_TEST_NGINX_CONFIG = Path(
    "/etc/nginx/sites-available/uten-imp-internal-test.conf"
)
INTERNAL_TEST_NGINX_LINK = Path(
    "/etc/nginx/sites-enabled/uten-imp-internal-test.conf"
)
INTERNAL_TEST_TLS_ROOT = Path("/etc/uten-imp/tls")
OPERATION_LOCK = ROOT_STATE_DIR / "operation.lock"
ACTIVATION_FAILURE_MARKER = ROOT_STATE_DIR / "activation-failed.json"
ACTIVATION_IN_PROGRESS_MARKER = ROOT_STATE_DIR / "activation-in-progress.json"
BOOT_ENABLEMENT_IN_PROGRESS_MARKER = (
    ROOT_STATE_DIR / "boot-enablement-in-progress.json"
)
RECOVERY_IN_PROGRESS_MARKER = ROOT_STATE_DIR / "recovery-in-progress.json"
RECOVERY_INGRESS_PENDING = ROOT_STATE_DIR / "recovery-ingress-pending.json"
START_AUTHORIZATION_DIR = Path("/run/uten-imp-release")
START_AUTHORIZATION = START_AUTHORIZATION_DIR / "start-authorization.json"
STABLE_RELEASE_GUARD = Path(
    "/usr/local/libexec/uten-imp-release/release_guard.py"
)
STABLE_DATABASE_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/database_recovery_verifier.py"
)
STABLE_STORAGE_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/storage_boot_verifier.py"
)
STABLE_ALLOWED_SIGNERS = Path(
    "/etc/uten-imp-release-trust/release-allowed-signers"
)
STORAGE_AUTHORITY = Path("/etc/uten-imp/storage-authority.json")
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
UPDATER_GROUP = "uten-imp-updater"
RELEASE_GUARD_SHA256 = (
    "2f3553f2fe3757b923a535925212877ce9b411c6743986d0c458ee07a2506833"
)
DATABASE_VERIFIER_SHA256 = (
    "3aed5823241988ac2271c1378b6c1a8ca1223e37b8d14a8b0e50a5be746429dc"
)
STORAGE_VERIFIER_SHA256 = (
    "0880678bcff0ad03149c0e0d90fccb9f6b274788b3c4e9e6add0d487d64dd83f"
)
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_AUTHORIZATION_AGE_SECONDS = 300
SHA256_RE = re.compile(r"[0-9a-f]{64}")
VERSION_RE = re.compile(r"v\d{4}\.\d{2}\.\d{2}-[1-9]\d{0,2}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
BOOT_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
DATA_UUID_RE = re.compile(
    r"(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{16,64})"
)


class BootVerificationError(RuntimeError):
    """A trusted runtime invariant is absent or inconsistent."""


def fail(message: str) -> NoReturn:
    raise BootVerificationError(message)


def _lexists(path: Path) -> bool:
    return os.path.lexists(path)


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _require_root_directory(path: Path, *, mode: int | None = None) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise BootVerificationError(f"required directory is missing: {path}") from exc
    if (
        not stat.S_ISDIR(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        fail(f"root-controlled directory is unsafe: {path}")
    return details


def _require_root_file(
    path: Path, *, mode: int | None = None, maximum_bytes: int | None = None
) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise BootVerificationError(f"required file is missing: {path}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or details.st_nlink != 1
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
        or (maximum_bytes is not None and not 1 <= details.st_size <= maximum_bytes)
    ):
        fail(f"root-controlled file is unsafe: {path}")
    return details


def _updater_venv_inventory_sha256() -> str:
    """Re-verify the updater venv before trusting it on every internal boot."""

    verifier = Path("/opt/uten-imp/updater/wheelhouse_supply_chain.py")
    lock = Path("/opt/uten-imp/updater/requirements.lock")
    venv = Path("/opt/uten-imp/updater/venv")
    for path in (verifier, lock):
        _require_root_file(path)
    try:
        completed = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                str(verifier),
                "verify-installed",
                "--lock",
                str(lock),
                "--venv",
                str(venv),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env={
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            },
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BootVerificationError(
            "updater virtualenv verification could not complete"
        ) from exc
    if completed.returncode != 0:
        fail("updater virtualenv differs from its reviewed RECORD inventory")
    inventory: list[dict[str, Any]] = []
    for path in sorted(venv.rglob("*"), key=lambda item: item.as_posix()):
        details = path.lstat()
        relative = path.relative_to(venv).as_posix()
        if stat.S_ISLNK(details.st_mode):
            payload = os.readlink(path).encode("utf-8")
            kind = "symlink"
        elif stat.S_ISREG(details.st_mode):
            payload = path.read_bytes()
            kind = "file"
        elif stat.S_ISDIR(details.st_mode):
            payload = b""
            kind = "directory"
        else:
            fail("updater virtualenv contains an unsafe file type")
        inventory.append(
            {
                "gid": details.st_gid,
                "kind": kind,
                "mode": f"{stat.S_IMODE(details.st_mode):04o}",
                "path": relative,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "uid": details.st_uid,
            }
        )
    return hashlib.sha256(
        (json.dumps(inventory, sort_keys=True, indent=2) + "\n").encode("utf-8")
    ).hexdigest()


def _strict_json_bytes(raw: bytes, label: str) -> dict[str, Any]:
    if not 1 <= len(raw) <= MAX_JSON_BYTES or b"\0" in raw:
        fail(f"{label} size is outside the trusted range")

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
                f"{label} contains a non-finite number: {constant}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BootVerificationError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} root must be an object")
    return value


def _read_root_json(path: Path, label: str, *, mode: int = 0o600) -> dict[str, Any]:
    _require_root_file(path, mode=mode, maximum_bytes=MAX_JSON_BYTES)
    return _strict_json_bytes(path.read_bytes(), label)


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        fail(f"{label} schema is unsupported")


def _string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value or (pattern and not pattern.fullmatch(value)):
        fail(f"{label} is malformed")
    return value


def _integer(value: Any, label: str, *, minimum: int = 0, maximum: int = 2**63 - 1) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < minimum
        or value > maximum
    ):
        fail(f"{label} is malformed")
    return value


def _timestamp(value: Any, label: str) -> datetime:
    text = _string(value, label)
    if not text.endswith("Z"):
        fail(f"{label} must be UTC")
    try:
        parsed = datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as exc:
        raise BootVerificationError(f"{label} is malformed") from exc
    if parsed.tzinfo != timezone.utc:
        fail(f"{label} must be UTC")
    return parsed


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _stable_root_bytes(path: Path, *, mode: int, maximum_bytes: int) -> bytes:
    """Read one exact root:root single-link file without path races."""

    _require_root_file(path, mode=mode, maximum_bytes=maximum_bytes)
    if not hasattr(os, "O_NOFOLLOW"):
        fail("platform cannot enforce no-follow runtime contract reads")
    descriptor = os.open(
        path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        before = os.fstat(descriptor)
        live = path.lstat()
        if (
            before.st_uid != 0
            or before.st_gid != 0
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != mode
            or (before.st_dev, before.st_ino) != (live.st_dev, live.st_ino)
            or not 1 <= before.st_size <= maximum_bytes
        ):
            fail("runtime contract input metadata is unsafe")
        blocks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            block = os.read(descriptor, min(64 * 1024, remaining))
            if not block:
                break
            blocks.append(block)
            remaining -= len(block)
        payload = b"".join(blocks)
        after = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            len(payload) != before.st_size
            or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (live_after.st_dev, live_after.st_ino, live_after.st_size, live_after.st_mtime_ns, live_after.st_ctime_ns)
        ):
            fail("runtime contract input changed while read")
        return payload
    finally:
        os.close(descriptor)


def _stable_python_module(
    path: Path,
    *,
    expected_sha256: str,
    module_name: str,
    maximum_bytes: int = 4 * 1024 * 1024,
) -> Any:
    """Compile and execute only the exact root-controlled bytes just verified."""

    payload = _stable_root_bytes(path, mode=0o644, maximum_bytes=maximum_bytes)
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        fail(f"stable Python module differs from its reviewed digest: {path}")
    specification = importlib.util.spec_from_loader(
        module_name, loader=None, origin=str(path)
    )
    if specification is None:
        fail(f"stable Python module specification could not be created: {path}")
    module = importlib.util.module_from_spec(specification)
    module.__file__ = str(path)
    try:
        code = compile(payload, str(path), "exec", dont_inherit=True)
        exec(code, module.__dict__)
    except (SyntaxError, ValueError) as exc:
        raise BootVerificationError(
            f"stable Python module could not be compiled: {path}"
        ) from exc
    return module


def _validate_internal_test_tls(value: dict[str, Any]) -> None:
    domain = _string(value.get("internalDomain"), "internal-test TLS domain")
    if (
        domain.lower() != domain
        or len(domain) > 253
        or re.fullmatch(
            r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",
            domain,
        )
        is None
    ):
        fail("internal-test TLS domain is not canonical")
    certificate = Path(
        _string(value.get("tlsCertificatePath"), "internal-test TLS certificate path")
    )
    key = Path(_string(value.get("tlsKeyPath"), "internal-test TLS key path"))
    try:
        if (
            certificate.parent.resolve(strict=True)
            != INTERNAL_TEST_TLS_ROOT.resolve(strict=True)
            or key.parent.resolve(strict=True) != INTERNAL_TEST_TLS_ROOT.resolve(strict=True)
        ):
            fail("internal-test TLS paths escaped their fixed directory")
    except OSError as exc:
        raise BootVerificationError("internal-test TLS directory cannot be resolved") from exc
    certificate_bytes = _stable_root_bytes(certificate, mode=0o644, maximum_bytes=1024 * 1024)
    key_bytes = _stable_root_bytes(key, mode=0o600, maximum_bytes=1024 * 1024)
    if (
        hashlib.sha256(certificate_bytes).hexdigest()
        != _string(value.get("tlsCertificateSha256"), "TLS certificate digest", SHA256_RE)
        or hashlib.sha256(key_bytes).hexdigest()
        != _string(value.get("tlsKeySha256"), "TLS key digest", SHA256_RE)
    ):
        fail("internal-test TLS bytes changed from the runtime contract")

    def openssl(arguments: list[str], payload: bytes) -> bytes:
        try:
            completed = subprocess.run(
                ["/usr/bin/openssl", *arguments], input=payload,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"},
                timeout=15, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise BootVerificationError("TLS OpenSSL verification failed") from exc
        if completed.returncode != 0 or len(completed.stdout) > 1024 * 1024:
            fail("internal-test TLS material failed OpenSSL verification")
        return completed.stdout

    openssl(["x509", "-noout", "-checkend", "86400"], certificate_bytes)
    san_output = openssl(
        ["x509", "-noout", "-ext", "subjectAltName"], certificate_bytes
    )
    try:
        san_text = san_output.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise BootVerificationError(
            "internal-test TLS subjectAltName output is not canonical ASCII"
        ) from exc
    dns_sans = {
        item.rstrip(".").lower()
        for item in re.findall(r"(?:^|[,\s])DNS:([^,\s]+)", san_text)
    }
    if domain not in dns_sans:
        fail("internal-test TLS certificate lacks the exact DNS subjectAltName")
    _require_root_directory(Path("/etc/ssl/certs"))
    openssl(
        [
            "verify",
            "-x509_strict",
            "-purpose",
            "sslserver",
            "-verify_hostname",
            domain,
            "-CApath",
            "/etc/ssl/certs",
            "/dev/stdin",
        ],
        certificate_bytes,
    )
    if openssl(["x509", "-pubkey", "-noout"], certificate_bytes) != openssl(
        ["pkey", "-pubout"], key_bytes
    ):
        fail("internal-test TLS certificate and key differ")


def _load_release_guard() -> Any:
    return _stable_python_module(
        STABLE_RELEASE_GUARD,
        expected_sha256=RELEASE_GUARD_SHA256,
        module_name="uten_imp_runtime_release_guard",
    )


def _deployment_profile() -> str:
    try:
        details = APPLICATION_ENV_FILE.lstat()
        app_gid = grp.getgrnam("uten-imp").gr_gid
    except (FileNotFoundError, KeyError) as exc:
        raise BootVerificationError("application environment ownership cannot be verified") from exc
    allowed_metadata = (
        (details.st_gid == 0 and stat.S_IMODE(details.st_mode) == 0o600)
        or (details.st_gid == app_gid and stat.S_IMODE(details.st_mode) == 0o640)
    )
    if (
        not stat.S_ISREG(details.st_mode)
        or APPLICATION_ENV_FILE.is_symlink()
        or details.st_uid != 0
        or details.st_nlink != 1
        or not allowed_metadata
    ):
        fail("application environment metadata is unsafe")
    raw = APPLICATION_ENV_FILE.read_bytes()
    if not 1 <= len(raw) <= 256 * 1024 or b"\0" in raw:
        fail("application environment size is outside the reviewed range")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise BootVerificationError("application environment is not UTF-8") from exc
    profiles = [line.removeprefix("UTEN_PROFILE=") for line in lines if line.startswith("UTEN_PROFILE=")]
    if len(profiles) != 1 or profiles[0] not in {"prod", "internal-test"}:
        fail("application environment has no unique supported UTEN_PROFILE")
    contract_present = _lexists(INTERNAL_TEST_RUNTIME_CONTRACT)
    if profiles[0] == "internal-test" and not contract_present:
        fail("internal-test profile lacks its root runtime contract")
    if profiles[0] != "internal-test" and contract_present:
        fail("internal-test runtime contract cannot coexist with another profile")
    return profiles[0]


def _internal_test_runtime_contract() -> tuple[dict[str, Any], str] | None:
    if _deployment_profile() != "internal-test":
        return None
    value = _read_root_json(
        INTERNAL_TEST_RUNTIME_CONTRACT,
        "internal-test runtime contract",
        mode=0o600,
    )
    _exact_keys(
        value,
        {
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
        },
        "internal-test runtime contract",
    )
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("contractId") != "uten-imp-internal-test-runtime-v1"
        or value.get("deploymentProfile") != "internal-test-local-v1"
    ):
        fail("internal-test runtime contract identity is unsupported")
    _timestamp(value.get("recordedAtUtc"), "internal-test runtime contract timestamp")
    _validate_internal_test_tls(value)
    pinned_paths = {
        "activationEntrypointSha256": Path("/usr/local/sbin/uten-imp-activate"),
        "databaseCommissionerSha256": INTERNAL_TEST_DB_COMMISSIONER,
        "databaseCommissionerUnitSha256": Path(
            "/etc/systemd/system/uten-imp-internal-db-commissioner.service"
        ),
        "databaseRecoveryVerifierSha256": STABLE_DATABASE_VERIFIER,
        "environmentValidatorSha256": INTERNAL_TEST_ENV_VALIDATOR,
        "entryWatchdogScriptSha256": Path(
            "/usr/local/libexec/uten-imp/uten-imp-entry-watchdog"
        ),
        "entryWatchdogServiceUnitSha256": Path(
            "/etc/systemd/system/uten-imp-entry-watchdog.service"
        ),
        "entryWatchdogTimerUnitSha256": Path(
            "/etc/systemd/system/uten-imp-entry-watchdog.timer"
        ),
        "migrationAuthorizationHelperSha256": Path(
            "/usr/local/libexec/uten-imp-release/migration_authorization.py"
        ),
        "migrationServiceUnitSha256": Path(
            "/etc/systemd/system/uten-imp-migrate.service"
        ),
        "migratorEnvironmentValidatorSha256": Path(
            "/usr/local/sbin/uten-imp-validate-migrator-env"
        ),
        "nginxConfigSha256": INTERNAL_TEST_NGINX_CONFIG,
        "nginxReadinessGateSha256": Path(
            "/usr/local/libexec/uten-imp/uten-imp-wait-ready"
        ),
        "nginxSystemdDropinSha256": Path(
            "/etc/systemd/system/nginx.service.d/uten-imp.conf"
        ),
        "releaseGuardSha256": STABLE_RELEASE_GUARD,
        "releaseUpdaterSha256": INTERNAL_TEST_RELEASE_UPDATER,
        "runtimeBootVerifierSha256": Path(__file__).resolve(),
        "recoveryCommitBootVerifierSha256": Path(
            "/usr/local/libexec/uten-imp-release/recovery_commit_boot_verifier.py"
        ),
        "recoveryCommitBootUnitSha256": Path(
            "/etc/systemd/system/uten-imp-recovery-commit-verifier.service"
        ),
        "recoveryIngressGateSha256": Path(
            "/usr/local/libexec/uten-imp-release/recovery_ingress_gate.py"
        ),
        "serverEnvironmentSha256": APPLICATION_ENV_FILE,
        "serviceUnitSha256": APPLICATION_UNIT_FILE,
        "storageBootVerifierSha256": STABLE_STORAGE_VERIFIER,
        "storageValidatorSha256": INTERNAL_TEST_STORAGE_VALIDATOR,
        "updaterReleaseGuardSha256": INTERNAL_TEST_UPDATER_RELEASE_GUARD,
        "postgresInternalTestConfigSha256": Path(
            "/etc/postgresql/16/main/conf.d/99-uten-imp-internal-test.conf"
        ),
        "postgresHbaSha256": Path("/etc/postgresql/16/main/pg_hba.conf"),
        "postgresStorageDropinSha256": Path(
            "/etc/systemd/system/postgresql@16-main.service.d/uten-imp-storage.conf"
        ),
        "recoveryEntrypointSha256": Path("/usr/local/sbin/uten-imp-recover"),
        "stableAllowedSignersSha256": STABLE_ALLOWED_SIGNERS,
        "storageAuthoritySha256": Path("/etc/uten-imp/storage-authority.json"),
        "storageMountObserverSha256": Path(
            "/usr/local/libexec/uten-imp-release/storage_mount_observer.py"
        ),
        "storageObserverUnitSha256": Path(
            "/etc/systemd/system/uten-imp-storage-observer.service"
        ),
        "updaterAllowedSignersSha256": Path(
            "/etc/uten-imp-updater/release-allowed-signers"
        ),
        "updaterEntrypointSha256": Path(
            "/opt/uten-imp/updater/uten-imp-updater.sh"
        ),
        "updaterEnvironmentValidatorSha256": Path(
            "/opt/uten-imp/updater/validate_oss_pull_env.py"
        ),
        "updaterOssIoSha256": Path("/opt/uten-imp/updater/oss_io.py"),
        "updaterServiceUnitSha256": Path(
            "/etc/systemd/system/uten-imp-updater.service"
        ),
        "updaterTimerUnitSha256": Path(
            "/etc/systemd/system/uten-imp-updater.timer"
        ),
        "updaterRequirementsLockSha256": Path(
            "/opt/uten-imp/updater/requirements.lock"
        ),
        "watchdogScriptSha256": Path(
            "/usr/local/libexec/uten-imp/uten-imp-watchdog"
        ),
        "watchdogServiceUnitSha256": Path(
            "/etc/systemd/system/uten-imp-watchdog.service"
        ),
        "watchdogTimerUnitSha256": Path(
            "/etc/systemd/system/uten-imp-watchdog.timer"
        ),
        "wheelhouseSupplyChainSha256": Path(
            "/opt/uten-imp/updater/wheelhouse_supply_chain.py"
        ),
    }
    for key, path in pinned_paths.items():
        if path == APPLICATION_ENV_FILE:
            # Metadata was checked before profile selection.
            pass
        else:
            _require_root_file(path)
        expected = _string(value.get(key), f"runtime contract {key}", SHA256_RE)
        if _sha256(path) != expected:
            fail(f"internal-test runtime contract file changed: {path}")
    if value.get("updaterAllowedSignersSha256") != value.get(
        "stableAllowedSignersSha256"
    ):
        fail("internal-test updater and stable release trust roots differ")
    for path_key, sha_key in (
        ("attachmentLayoutReceiptPath", "attachmentLayoutReceiptSha256"),
        ("backupContainmentReceiptPath", "backupContainmentReceiptSha256"),
        ("legacyNginxHandoffReceiptPath", "legacyNginxHandoffReceiptSha256"),
        (
            "serverEnvironmentBridgeReceiptPath",
            "serverEnvironmentBridgeReceiptSha256",
        ),
        ("updaterSubstrateReceiptPath", "updaterSubstrateReceiptSha256"),
        ("evidenceLayoutReceiptPath", "evidenceLayoutReceiptSha256"),
    ):
        path = Path(_string(value.get(path_key), f"runtime contract {path_key}"))
        if path.parent.parent != Path(
            "/var/lib/uten-imp-internal-test-host-preparation"
        ):
            fail("runtime contract host preparation receipt escaped its fixed root")
        _require_root_file(path, mode=0o600)
        expected = _string(value.get(sha_key), f"runtime contract {sha_key}", SHA256_RE)
        if _sha256(path) != expected:
            fail("runtime contract host preparation receipt changed")
    updater_substrate_path = Path(
        _string(
            value.get("updaterSubstrateReceiptPath"),
            "runtime updater substrate receipt path",
        )
    )
    updater_substrate = _read_root_json(
        updater_substrate_path,
        "runtime updater substrate receipt",
        mode=0o600,
    )
    _exact_keys(
        updater_substrate,
        {
            "allowedSignersSha256",
            "installedInventorySha256",
            "kind",
            "ossEnvironmentSha256",
            "resolvedVenvPython",
            "schemaVersion",
            "status",
            "transactionId",
            "updaterVenvInventorySha256",
        },
        "runtime updater substrate receipt",
    )
    if (
        updater_substrate.get("schemaVersion") != 1
        or isinstance(updater_substrate.get("schemaVersion"), bool)
        or updater_substrate.get("kind")
        != "uten-imp-internal-test-common-updater-substrate"
        or updater_substrate.get("status")
        != "COMMITTED_ENTRY_CLOSED_STAGING_MANUAL_ONLY"
        or updater_substrate.get("transactionId")
        != updater_substrate_path.parent.name
        or updater_substrate.get("allowedSignersSha256")
        != value.get("updaterAllowedSignersSha256")
        or not re.fullmatch(
            r"/usr/bin/python3(?:\.[0-9]+)?",
            str(updater_substrate.get("resolvedVenvPython")),
        )
    ):
        fail("runtime updater substrate receipt is incomplete")
    for key in (
        "installedInventorySha256",
        "ossEnvironmentSha256",
        "updaterVenvInventorySha256",
    ):
        _string(
            updater_substrate.get(key),
            f"runtime updater substrate {key}",
            SHA256_RE,
        )
    if updater_substrate.get("updaterVenvInventorySha256") != value.get(
        "updaterVenvInventorySha256"
    ):
        fail("runtime updater virtualenv inventory differs")
    if _updater_venv_inventory_sha256() != value.get(
        "updaterVenvInventorySha256"
    ):
        fail("live runtime updater virtualenv inventory drifted")
    storage_receipts: dict[str, dict[str, Any]] = {}
    for path_key, sha_key, expected_name, label in (
        ("storageCompleteReceiptPath", "storageCompleteReceiptSha256", "complete.json", "complete"),
        (
            "storageLateFinalizationReceiptPath",
            "storageLateFinalizationReceiptSha256",
            "late-committed-finalization.json",
            "late",
        ),
    ):
        path = Path(_string(value.get(path_key), f"runtime contract {path_key}"))
        if (
            path.parent.parent != Path("/var/lib/uten-imp-nvme-commissioning")
            or path.name != expected_name
        ):
            fail("runtime storage terminal receipt escaped its fixed transaction")
        storage_receipts[label] = _read_root_json(
            path, f"runtime storage {label} receipt", mode=0o600
        )
        if _sha256(path) != _string(
            value.get(sha_key), f"runtime contract {sha_key}", SHA256_RE
        ):
            fail("runtime storage terminal receipt changed")
    complete = storage_receipts["complete"]
    late = storage_receipts["late"]
    if (
        complete.get("status") != "COMMITTED_STORAGE_ONLY"
        or late.get("status") != "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED"
        or complete.get("transactionId") != late.get("transactionId")
        or complete.get("authoritySha256") != value.get("storageAuthoritySha256")
        or late.get("authoritySha256") != value.get("storageAuthoritySha256")
        or late.get("osUpdateInfrastructureRestored") is not True
        or _lexists(Path("/var/lib/uten-imp-nvme-commissioning/active.json"))
    ):
        fail("runtime storage terminal is incomplete or still armed")
    _string(
        value.get("nginxExpandedConfigSha256"),
        "runtime contract expanded Nginx digest",
        SHA256_RE,
    )
    try:
        link = INTERNAL_TEST_NGINX_LINK.lstat()
        target = INTERNAL_TEST_NGINX_LINK.resolve(strict=True)
    except OSError as exc:
        raise BootVerificationError("internal-test Nginx enabled link is unavailable") from exc
    if (
        not stat.S_ISLNK(link.st_mode)
        or link.st_uid != 0
        or link.st_gid != 0
        or target != INTERNAL_TEST_NGINX_CONFIG
    ):
        fail("internal-test Nginx enabled link differs from the runtime contract")
    try:
        expanded = subprocess.run(
            ["/usr/sbin/nginx", "-T"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"},
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BootVerificationError("effective Nginx configuration could not be read") from exc
    if (
        expanded.returncode != 0
        or not expanded.stdout
        or hashlib.sha256(expanded.stdout).hexdigest()
        != value["nginxExpandedConfigSha256"]
    ):
        fail("effective Nginx configuration changed from the runtime contract")
    raw = INTERNAL_TEST_RUNTIME_CONTRACT.read_bytes()
    return value, hashlib.sha256(raw).hexdigest()


def _verify_data_mount() -> None:
    module = _stable_python_module(
        STABLE_STORAGE_VERIFIER,
        expected_sha256=STORAGE_VERIFIER_SHA256,
        module_name="uten_imp_storage_boot_verifier",
    )
    try:
        module.verify_storage_boot()
    except Exception as exc:
        raise BootVerificationError(f"persistent storage boot gate failed: {exc}") from exc


def _current_release() -> Path:
    _require_root_directory(RELEASE_BASE)
    releases = RELEASES_DIR.resolve(strict=True)
    _require_root_directory(releases)
    try:
        link = CURRENT_LINK.lstat()
    except FileNotFoundError as exc:
        raise BootVerificationError("current release link is missing") from exc
    if not stat.S_ISLNK(link.st_mode) or link.st_uid != 0 or link.st_gid != 0:
        fail("current release is not a root-owned symbolic link")
    try:
        target = CURRENT_LINK.resolve(strict=True)
        target.relative_to(releases)
    except (OSError, ValueError) as exc:
        raise BootVerificationError("current release escaped the fixed release directory") from exc
    if target.parent != releases or not VERSION_RE.fullmatch(target.name):
        fail("current release target is not one canonical direct child")
    _require_root_directory(target)
    return target


def _verify_release_permissions(root: Path) -> None:
    for path in (root, *root.rglob("*")):
        details = path.lstat()
        if path.is_symlink() or not (
            stat.S_ISDIR(details.st_mode) or stat.S_ISREG(details.st_mode)
        ):
            fail(f"installed release contains an unsafe path: {path}")
        if details.st_uid != 0 or details.st_gid != 0 or details.st_mode & 0o022:
            fail(f"installed release permissions are unsafe: {path}")
        if stat.S_ISREG(details.st_mode) and details.st_nlink != 1:
            fail(f"installed release file has multiple hard links: {path}")


def _verified_current_release(guard: Any) -> tuple[Path, dict[str, Any], str]:
    target = _current_release()
    evidence = target / ".release"
    _require_root_directory(evidence, mode=0o755)
    manifest_path = evidence / "manifest.json"
    signature_path = evidence / "manifest.sig"
    _require_root_file(manifest_path, mode=0o644, maximum_bytes=MAX_JSON_BYTES)
    _require_root_file(signature_path, mode=0o644, maximum_bytes=64 * 1024)
    _require_root_file(STABLE_ALLOWED_SIGNERS, mode=0o640, maximum_bytes=64 * 1024)
    manifest = guard.load_json(manifest_path, MAX_JSON_BYTES)
    key_id = guard.require_string(
        manifest.get("signingKeyId"), "manifest signingKeyId", guard.KEY_ID_RE
    )
    guard.verify_ssh_signature(
        manifest_path,
        signature_path,
        STABLE_ALLOWED_SIGNERS,
        expected_key_id=key_id,
    )
    info = guard.validate_manifest(manifest, expected_version=target.name)
    guard.verify_payload(target, info)
    _verify_release_permissions(target)
    return target, info, _sha256(manifest_path)


def _canonical_live_flyway(rows: Any, manifest: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(rows, list) or not rows:
        fail("live Flyway history is empty or malformed")
    expected_keys = {
        "checksum",
        "description",
        "installedRank",
        "script",
        "success",
        "type",
        "version",
    }
    canonical: list[dict[str, Any]] = []
    prior_rank = -1
    versions: set[str] = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != expected_keys:
            fail("live Flyway row schema differs from the fixed query")
        rank = _integer(row.get("installedRank"), "Flyway installed rank")
        checksum = _integer(
            row.get("checksum"),
            "Flyway checksum",
            minimum=-(2**31),
            maximum=2**31 - 1,
        )
        version = row.get("version")
        script = row.get("script")
        description = row.get("description")
        if rank <= prior_rank:
            fail("live Flyway ranks are not strictly increasing")
        if not isinstance(version, str) or not version.isdigit() or version in versions:
            fail("live Flyway version is malformed or duplicated")
        if (
            row.get("type") != "SQL"
            or row.get("success") is not True
            or not isinstance(script, str)
            or not script.endswith(".sql")
            or not isinstance(description, str)
        ):
            fail("live Flyway history contains a failed, non-SQL or malformed row")
        canonical.append(
            {
                "checksum": checksum,
                "description": description,
                "installedRank": rank,
                "script": script,
                "success": True,
                "type": "SQL",
                "version": version,
            }
        )
        prior_rank = rank
        versions.add(version)
    migrations = manifest.get("flywayMigrations")
    if not isinstance(migrations, list) or len(migrations) != len(canonical):
        fail("live Flyway count differs from the signed release")
    for row, migration in zip(canonical, migrations, strict=True):
        if (
            row["version"] != migration.get("version")
            or row["description"] != migration.get("description")
            or row["script"] != migration.get("file")
            or row["checksum"] != migration.get("flywayChecksum")
        ):
            fail("live Flyway version/script/checksum differs from the signed release")
    canonical_bytes = json.dumps(
        canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    projection = "".join(
        f"{row['version']}\t{row['script']}\t{row['checksum']}\n" for row in canonical
    ).encode("utf-8")
    return {
        "canonicalHistorySha256": hashlib.sha256(canonical_bytes).hexdigest(),
        "headVersion": max(int(version) for version in versions),
        "signedProjectionSha256": hashlib.sha256(projection).hexdigest(),
        "successfulMigrationCount": len(canonical),
    }


def _internal_test_role_acl_contract() -> dict[str, Any]:
    return {
        "allPublicObjectsOwnedByOwner": True,
        "allPublicTypesOwnedByOwner": True,
        "applicationBypassRls": False,
        "applicationCanCreateDatabase": False,
        "applicationCanCreateRole": False,
        "applicationCanLogin": True,
        "applicationCanReplicate": False,
        "applicationDatabaseConnect": True,
        "applicationDatabaseCreate": False,
        "applicationDatabaseTemporary": False,
        "applicationHasAllRequiredFunctionPrivileges": True,
        "applicationHasAllRequiredSequencePrivileges": True,
        "applicationHasAllRequiredTablePrivileges": True,
        "applicationHasAllRequiredTypePrivileges": True,
        "applicationHasNoElevatedTablePrivilege": True,
        "applicationMemberships": [],
        "applicationGrantedToMembers": [],
        "applicationOwnsNoPublicObject": True,
        "applicationOwnsNoPublicType": True,
        "applicationRole": "uten",
        "applicationSchemaCreate": False,
        "applicationSchemaUsage": True,
        "applicationSuperuser": False,
        "databaseOwner": "uten_owner",
        "defaultFunctionAcl": ["uten:EXECUTE:false"],
        "defaultSequenceAcl": ["uten:SELECT:false", "uten:UPDATE:false", "uten:USAGE:false"],
        "defaultTableAcl": ["uten:DELETE:false", "uten:INSERT:false", "uten:SELECT:false", "uten:UPDATE:false"],
        "defaultTypeAcl": ["uten:USAGE:false"],
        "migratorBypassRls": False,
        "migratorCanCreateDatabase": False,
        "migratorCanCreateRole": False,
        "migratorCanLogin": True,
        "migratorCanReplicate": False,
        "migratorDatabaseConnect": True,
        "migratorDatabaseCreate": True,
        "migratorDatabaseTemporary": True,
        "migratorMemberOfOwner": True,
        "migratorMemberships": ["uten_owner"],
        "migratorGrantedToMembers": [],
        "migratorRole": "uten_migrator",
        "migratorSchemaCreate": True,
        "migratorSchemaUsage": True,
        "migratorSuperuser": False,
        "ownerBypassRls": False,
        "ownerCanCreateDatabase": False,
        "ownerCanCreateRole": False,
        "ownerCanLogin": False,
        "ownerCanReplicate": False,
        "ownerMemberships": [],
        "ownerGrantedToMembers": ["uten_migrator"],
        "ownerRole": "uten_owner",
        "ownerSuperuser": False,
        "publicDatabaseConnect": False,
        "publicDatabaseCreate": False,
        "publicDatabaseTemporary": False,
        "publicSchemaCreate": False,
        "publicSchemaUsage": False,
        "noUnexpectedExplicitPublicObjectAcl": True,
        "noUnexpectedExplicitPublicTypeAcl": True,
        "noUnexpectedDatabaseAcl": True,
        "noUnexpectedSchemaAcl": True,
        "schemaOwner": "uten_owner",
        "unexpectedNonBuiltinRoles": [],
        "unexpectedPrivilegedRoles": [],
    }


def _query_live_database(
    manifest: dict[str, Any], *, require_internal_role_acl: bool
) -> dict[str, Any]:
    _require_root_file(STABLE_DATABASE_VERIFIER, mode=0o644)
    if _sha256(STABLE_DATABASE_VERIFIER) != DATABASE_VERIFIER_SHA256:
        fail("database verifier differs from the reviewed digest")
    try:
        completed = subprocess.run(
            [
                "/usr/sbin/runuser",
                "-u",
                "postgres",
                "--",
                "/usr/bin/python3",
                "-I",
                str(STABLE_DATABASE_VERIFIER),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            },
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BootVerificationError("live database verification could not complete") from exc
    if completed.returncode != 0 or not completed.stdout:
        fail("live database verification failed closed")
    value = _strict_json_bytes(completed.stdout, "live database observation")
    _exact_keys(
        value,
        {
            "archiveCommand",
            "archiveMode",
            "configFile",
            "dataDirectory",
            "databaseName",
            "flywayHistory",
            "hbaFile",
            "inRecovery",
            "listenAddresses",
            "postmasterPid",
            "roleAclContract",
            "schemaName",
            "schemaVersion",
            "serverPort",
            "serverVersionNum",
            "systemdMainPid",
            "systemIdentifier",
            "tcpListenerPid",
            "timeline",
        },
        "live database observation",
    )
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("databaseName") != "uten_imp"
        or value.get("schemaName") != "public"
        or value.get("serverPort") != 5432
        or value.get("serverVersionNum") not in range(160000, 170000)
        or value.get("dataDirectory") != "/data/postgresql/16/main"
        or value.get("configFile") != "/etc/postgresql/16/main/postgresql.conf"
        or value.get("hbaFile") != "/etc/postgresql/16/main/pg_hba.conf"
        or value.get("listenAddresses") != "127.0.0.1,::1"
        or value.get("inRecovery") is not False
    ):
        fail("live query reached an unexpected database/schema/version/config/listener or standby")
    if require_internal_role_acl and (
        value.get("archiveMode") != "off" or value.get("archiveCommand") != ""
    ):
        fail("internal-test PostgreSQL archive settings could reach an old repository")
    postmaster_pid = _integer(
        value.get("postmasterPid"), "PostgreSQL postmaster PID", minimum=2
    )
    systemd_main_pid = _integer(
        value.get("systemdMainPid"), "PostgreSQL systemd MainPID", minimum=2
    )
    if postmaster_pid != systemd_main_pid:
        fail("PostgreSQL socket instance differs from postgresql@16-main.service")
    tcp_listener_pid = _integer(
        value.get("tcpListenerPid"), "PostgreSQL TCP listener PID", minimum=2
    )
    if tcp_listener_pid != postmaster_pid:
        fail("127.0.0.1:5432 differs from the verified PostgreSQL socket instance")
    system_identifier = _string(value.get("systemIdentifier"), "system identifier")
    if not system_identifier.isdigit() or not 10 <= len(system_identifier) <= 24:
        fail("live PostgreSQL system identifier is malformed")
    timeline = _integer(value.get("timeline"), "PostgreSQL timeline", minimum=1, maximum=0xFFFFFFFF)
    flyway = _canonical_live_flyway(value.get("flywayHistory"), manifest)
    if flyway["headVersion"] != int(manifest["flywayHeadVersion"]):
        fail("live Flyway head differs from the signed release")
    expected_role_acl = _internal_test_role_acl_contract()
    if require_internal_role_acl and value.get("roleAclContract") != expected_role_acl:
        fail("live PostgreSQL role/ownership/ACL contract differs")
    role_acl_sha = hashlib.sha256(
        json.dumps(value.get("roleAclContract"), sort_keys=True, separators=(",", ":")).encode(
            "utf-8"
        )
    ).hexdigest()
    result = {
        "canonicalHistorySha256": flyway["canonicalHistorySha256"],
        "headVersion": flyway["headVersion"],
        "signedProjectionSha256": flyway["signedProjectionSha256"],
        "successfulMigrationCount": flyway["successfulMigrationCount"],
        "systemIdentifier": system_identifier,
        "timeline": timeline,
    }
    if require_internal_role_acl:
        result["roleAclContractSha256"] = role_acl_sha
    return result


def _validate_active(
    value: dict[str, Any],
    manifest: dict[str, Any],
    manifest_sha: str,
    runtime_contract: tuple[dict[str, Any], str] | None = None,
) -> None:
    expected_keys = {
        "activatedAtUtc",
        "commitSha",
        "databaseChanged",
        "flywayHeadVersion",
        "flywayMigrationSetSha256",
        "manifestSha256",
        "releaseSequence",
        "version",
    }
    if runtime_contract is not None:
        expected_keys.update(
            {
                "onboardingArchivePath",
                "onboardingReceiptSha256",
                "runtimeContractId",
                "runtimeContractSha256",
            }
        )
    _exact_keys(
        value,
        expected_keys,
        "active release state",
    )
    _timestamp(value.get("activatedAtUtc"), "active timestamp")
    if not isinstance(value.get("databaseChanged"), bool):
        fail("active databaseChanged is malformed")
    expected = {
        "commitSha": manifest["commitSha"],
        "flywayHeadVersion": manifest["flywayHeadVersion"],
        "flywayMigrationSetSha256": manifest["flywayMigrationSetSha256"],
        "manifestSha256": manifest_sha,
        "releaseSequence": manifest["releaseSequence"],
        "version": manifest["version"],
    }
    if any(value.get(key) != expected_value for key, expected_value in expected.items()):
        fail("active release state differs from the signed current release")
    if runtime_contract is not None:
        contract, contract_sha = runtime_contract
        if (
            value.get("runtimeContractId") != contract["contractId"]
            or value.get("runtimeContractSha256") != contract_sha
        ):
            fail("active release differs from the internal-test runtime contract")
        archive = Path(
            _string(value.get("onboardingArchivePath"), "onboarding archive path")
        )
        if archive.parent != INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR:
            fail("onboarding archive escaped the fixed evidence directory")
        receipt_sha = _string(
            value.get("onboardingReceiptSha256"), "onboarding receipt digest", SHA256_RE
        )
        _require_root_file(archive, mode=0o600, maximum_bytes=MAX_JSON_BYTES)
        if _sha256(archive) != receipt_sha:
            fail("onboarding archive differs from the active origin digest")


DATABASE_IDENTITY_KEYS = {
    "canonicalHistorySha256",
    "headVersion",
    "signedProjectionSha256",
    "successfulMigrationCount",
    "systemIdentifier",
    "timeline",
}


def _validate_database_identity(
    value: Any, label: str, *, internal: bool = False
) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} is malformed")
    expected_keys = set(DATABASE_IDENTITY_KEYS)
    if internal:
        expected_keys.add("roleAclContractSha256")
    _exact_keys(value, expected_keys, label)
    digest_keys = ["canonicalHistorySha256", "signedProjectionSha256"]
    if internal:
        digest_keys.append("roleAclContractSha256")
    for key in digest_keys:
        _string(value.get(key), f"{label} {key}", SHA256_RE)
    system_identifier = _string(value.get("systemIdentifier"), f"{label} system identifier")
    if not system_identifier.isdigit() or not 10 <= len(system_identifier) <= 24:
        fail(f"{label} system identifier is malformed")
    _integer(value.get("timeline"), f"{label} timeline", minimum=1, maximum=0xFFFFFFFF)
    _integer(value.get("headVersion"), f"{label} Flyway head", minimum=1)
    _integer(value.get("successfulMigrationCount"), f"{label} Flyway count", minimum=1)
    return value


def _validate_runtime_authority(
    value: dict[str, Any],
    manifest: dict[str, Any],
    manifest_sha: str,
    live: dict[str, Any],
    runtime_contract: tuple[dict[str, Any], str] | None = None,
) -> None:
    expected_keys = {
        "commitSha",
        "databaseIdentity",
        "manifestSha256",
        "releaseSequence",
        "schemaVersion",
        "verifiedAtUtc",
        "version",
    }
    if runtime_contract is not None:
        expected_keys.update({"runtimeContractId", "runtimeContractSha256"})
    _exact_keys(
        value,
        expected_keys,
        "runtime authority",
    )
    if value.get("schemaVersion") != 1 or isinstance(value.get("schemaVersion"), bool):
        fail("runtime authority schema is unsupported")
    _timestamp(value.get("verifiedAtUtc"), "runtime authority timestamp")
    expected = {
        "commitSha": manifest["commitSha"],
        "manifestSha256": manifest_sha,
        "releaseSequence": manifest["releaseSequence"],
        "version": manifest["version"],
    }
    if any(value.get(key) != expected_value for key, expected_value in expected.items()):
        fail("runtime authority differs from the signed current release")
    if runtime_contract is not None:
        contract, contract_sha = runtime_contract
        if (
            value.get("runtimeContractId") != contract["contractId"]
            or value.get("runtimeContractSha256") != contract_sha
        ):
            fail("runtime authority differs from the internal-test runtime contract")
    identity = _validate_database_identity(
        value.get("databaseIdentity"),
        "runtime database authority",
        internal=runtime_contract is not None,
    )
    if identity != live:
        fail("live database identity/history differs from runtime authority")


def _boot_id() -> str:
    try:
        value = BOOT_ID_PATH.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise BootVerificationError("kernel boot ID cannot be read") from exc
    return _string(value, "kernel boot ID", BOOT_ID_RE)


def _process_start_time_ticks(pid: int) -> int:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        _prefix, separator, suffix = raw.rpartition(") ")
        fields = suffix.split()
        if not separator or len(fields) <= 19:
            fail("cannot parse start-authorization issuer")
        value = int(fields[19])
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise BootVerificationError("cannot read start-authorization issuer") from exc
    if value <= 0:
        fail("start-authorization issuer identity is invalid")
    return value


def _validate_authorization_issuer(authorization: dict[str, Any]) -> int:
    pid = authorization.get("issuerPid")
    start = authorization.get("issuerStartTimeTicks")
    if (
        not isinstance(pid, int)
        or isinstance(pid, bool)
        or pid <= 1
        or not isinstance(start, int)
        or isinstance(start, bool)
        or start <= 0
        or _process_start_time_ticks(pid) != start
    ):
        fail("one-time start authorization issuer changed")
    try:
        executable = Path(f"/proc/{pid}/exe").resolve(strict=True)
        command_line = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError as exc:
        raise BootVerificationError("cannot inspect start-authorization issuer") from exc
    if (
        executable.parent != Path("/usr/bin")
        or not executable.name.startswith("python3")
        or authorization.get("issuerExecutablePath") != str(executable)
        or authorization.get("issuerExecutableSha256") != _sha256(executable)
        or authorization.get("issuerCommandLineSha256")
        != hashlib.sha256(command_line).hexdigest()
    ):
        fail("one-time start authorization issuer executable changed")
    return pid


def _operation_lock_is_held_by(issuer_pid: int) -> bool:
    try:
        expected_gid = grp.getgrnam(UPDATER_GROUP).gr_gid
    except KeyError as exc:
        raise BootVerificationError("updater coordination group is missing") from exc
    if not hasattr(os, "O_NOFOLLOW"):
        fail("platform lacks no-follow coordination-lock support")
    descriptor = os.open(
        OPERATION_LOCK, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != expected_gid
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
        ):
            fail("operation lock permissions are unsafe")
        device = f"{os.major(details.st_dev):02x}:{os.minor(details.st_dev):02x}"
        inode = str(details.st_ino)
        try:
            locks = Path("/proc/locks").read_text(encoding="ascii").splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            raise BootVerificationError("cannot inspect operation-lock owner") from exc
        for line in locks:
            fields = line.split()
            if len(fields) < 6 or fields[1:4] != ["FLOCK", "ADVISORY", "WRITE"]:
                continue
            try:
                owner_pid = int(fields[4])
                lock_device, lock_inode = fields[5].rsplit(":", 1)
            except (ValueError, TypeError):
                continue
            if (
                owner_pid == issuer_pid
                and lock_device.lower() == device.lower()
                and lock_inode == inode
            ):
                return True
        return False
    finally:
        os.close(descriptor)


def _consume_start_authorization() -> tuple[dict[str, Any], Path]:
    _require_root_directory(START_AUTHORIZATION_DIR, mode=0o700)
    _require_root_file(START_AUTHORIZATION, mode=0o600, maximum_bytes=MAX_JSON_BYTES)
    consumed = START_AUTHORIZATION_DIR / (
        f"start-authorization.consumed-{os.getpid()}-{secrets.token_hex(8)}.json"
    )
    if _lexists(consumed):
        fail("one-time authorization evidence path already exists")
    os.rename(START_AUTHORIZATION, consumed)
    _fsync_directory(START_AUTHORIZATION_DIR)
    return _read_root_json(consumed, "one-time start authorization"), consumed


def _validate_transaction_authorization(
    authorization: dict[str, Any],
    marker: Path,
    manifest: dict[str, Any],
    manifest_sha: str,
    live: dict[str, Any],
    runtime_contract: tuple[dict[str, Any], str] | None = None,
) -> None:
    expected_keys = {
        "authorizationId",
        "bootId",
        "commitSha",
        "createdAtUtc",
        "databaseIdentity",
        "issuerCommandLineSha256",
        "issuerExecutablePath",
        "issuerExecutableSha256",
        "issuerPid",
        "issuerStartTimeTicks",
        "manifestSha256",
        "markerPath",
        "markerSha256",
        "mode",
        "releaseSequence",
        "schemaVersion",
        "version",
    }
    if runtime_contract is not None:
        expected_keys.update({"runtimeContractId", "runtimeContractSha256"})
    _exact_keys(
        authorization,
        expected_keys,
        "one-time start authorization",
    )
    if authorization.get("schemaVersion") != 1 or isinstance(
        authorization.get("schemaVersion"), bool
    ):
        fail("one-time start authorization schema is unsupported")
    _string(
        authorization.get("authorizationId"),
        "authorization ID",
        re.compile(r"[0-9a-f]{32}"),
    )
    if authorization.get("bootId") != _boot_id():
        fail("one-time start authorization belongs to another boot")
    created = _timestamp(authorization.get("createdAtUtc"), "authorization timestamp")
    age = (datetime.now(timezone.utc) - created).total_seconds()
    if age < -5 or age > MAX_AUTHORIZATION_AGE_SECONDS:
        fail("one-time start authorization is stale or from the future")
    expected_mode = (
        {"activation", "rollback"}
        if marker == ACTIVATION_IN_PROGRESS_MARKER
        else {"recovery"}
    )
    if authorization.get("mode") not in expected_mode:
        fail("one-time start authorization mode differs from the transaction")
    if authorization.get("markerPath") != str(marker):
        fail("one-time start authorization references another marker")
    _require_root_file(marker, mode=0o600, maximum_bytes=MAX_JSON_BYTES)
    if authorization.get("markerSha256") != _sha256(marker):
        fail("transaction marker changed after start authorization")
    expected = {
        "commitSha": manifest["commitSha"],
        "manifestSha256": manifest_sha,
        "releaseSequence": manifest["releaseSequence"],
        "version": manifest["version"],
    }
    if any(
        authorization.get(key) != expected_value
        for key, expected_value in expected.items()
    ):
        fail("one-time start authorization differs from the signed current release")
    identity = _validate_database_identity(
        authorization.get("databaseIdentity"),
        "authorized database identity",
        internal=runtime_contract is not None,
    )
    if identity != live:
        fail("live database changed after one-time start authorization")
    if runtime_contract is not None:
        contract, contract_sha = runtime_contract
        if (
            authorization.get("runtimeContractId") != contract["contractId"]
            or authorization.get("runtimeContractSha256") != contract_sha
        ):
            fail("one-time start authorization differs from the runtime contract")
    issuer_pid = _validate_authorization_issuer(authorization)
    if not _operation_lock_is_held_by(issuer_pid):
        fail("controlled release operation is not holding its coordination lock")


def verify_runtime_boot() -> None:
    if os.geteuid() != 0:
        fail("runtime boot verification must run as root")
    _require_root_directory(ROOT_STATE_DIR)
    for gate in (
        ACTIVATION_FAILURE_MARKER,
        BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
        RECOVERY_INGRESS_PENDING,
    ):
        if _lexists(gate):
            _require_root_file(gate, mode=0o600, maximum_bytes=MAX_JSON_BYTES)
            fail(f"persistent fail-closed marker is present: {gate.name}")
    runtime_contract = _internal_test_runtime_contract()
    _verify_data_mount()

    guard = _load_release_guard()
    _target, manifest, manifest_sha = _verified_current_release(guard)
    live = _query_live_database(
        manifest, require_internal_role_acl=runtime_contract is not None
    )
    transaction_markers = [
        marker
        for marker in (ACTIVATION_IN_PROGRESS_MARKER, RECOVERY_IN_PROGRESS_MARKER)
        if _lexists(marker)
    ]
    if len(transaction_markers) > 1:
        fail("multiple release transaction markers are present")
    if transaction_markers:
        authorization, consumed_path = _consume_start_authorization()
        try:
            _validate_transaction_authorization(
                authorization,
                transaction_markers[0],
                manifest,
                manifest_sha,
                live,
                runtime_contract,
            )
        except Exception:
            # Preserve the renamed one-use evidence until the updater contains the
            # failed transaction. It cannot authorize a second ExecStartPre.
            raise
        else:
            consumed_path.unlink()
            _fsync_directory(START_AUTHORIZATION_DIR)
        return

    if _lexists(START_AUTHORIZATION):
        _require_root_file(START_AUTHORIZATION, mode=0o600, maximum_bytes=MAX_JSON_BYTES)
        fail("one-time start authorization exists without a release transaction")
    active = _read_root_json(ACTIVE_STATE, "active release state")
    _validate_active(active, manifest, manifest_sha, runtime_contract)
    authority = _read_root_json(RUNTIME_AUTHORITY, "runtime authority")
    _validate_runtime_authority(
        authority, manifest, manifest_sha, live, runtime_contract
    )


def main() -> int:
    try:
        verify_runtime_boot()
    except Exception as exc:
        print(f"ERP_RUNTIME_BOOT_NO_GO: {exc}", file=sys.stderr)
        return 1
    print("ERP_RUNTIME_BOOT_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
