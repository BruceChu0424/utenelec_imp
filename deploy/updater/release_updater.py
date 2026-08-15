#!/usr/bin/env python3
"""Two-stage Uten IMP updater: unprivileged staging and explicit root activation."""

from __future__ import annotations

import argparse
import atexit
import contextlib
import fcntl
import hashlib
import http.client
import importlib
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
import time
import types
import urllib.error
import urllib.request
from collections.abc import Iterable, Iterator
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn

_GUARD_PATH = Path(__file__).resolve().with_name("release_guard.py")
_GUARD_MODULE_NAME = "uten_imp_release_guard"
_PREVERIFIED_GUARD_GLOBAL = "_UTEN_PREVERIFIED_RELEASE_GUARD"
_GUARD_MAXIMUM_BYTES = 4 * 1024 * 1024
_GUARD_SHA256 = "2f3553f2fe3757b923a535925212877ce9b411c6743986d0c458ee07a2506833"
OSS_IO_SHA256 = "a3d8a8d4044617e500293ae2dad036b9fd0f1f890d07b2bf87fc6a4e3535f77b"
WHEELHOUSE_SUPPLY_CHAIN_SHA256 = (
    "b46bee01c173d4cd56d21a80bb40983dba535199d011f5ecc18625e2405c3bea"
)
OSS_IO_HELPER = Path("/opt/uten-imp/updater/oss_io.py")
WHEELHOUSE_SUPPLY_CHAIN = Path(
    "/opt/uten-imp/updater/wheelhouse_supply_chain.py"
)


def _validate_release_guard_module(module: Any, expected_path: Path) -> Any:
    """Accept only the fixed release-guard module and its complete API contract."""

    if not isinstance(module, types.ModuleType):
        raise RuntimeError("preverified release guard is not a Python module")
    module_file = getattr(module, "__file__", None)
    if not isinstance(module_file, str) or Path(module_file) != expected_path:
        raise RuntimeError("preverified release guard escaped its fixed source path")
    required_callables = {
        "allowed_signing_key_ids",
        "exact_keys",
        "load_json",
        "require_string",
        "safe_extract",
        "sha256_file",
        "validate_channel",
        "validate_manifest",
        "validate_static_entry_response",
        "validate_web_version_value",
        "verify_payload",
        "verify_ssh_signature",
        "version_sequence",
    }
    if any(not callable(getattr(module, name, None)) for name in required_callables):
        raise RuntimeError("preverified release guard API contract is incomplete")
    for name in ("COMMIT_RE", "KEY_ID_RE", "SHA256_RE"):
        if not isinstance(getattr(module, name, None), re.Pattern):
            raise RuntimeError("preverified release guard regex contract is incomplete")
    for name in (
        "MAX_ARCHIVE_BYTES",
        "MAX_CHANNEL_BYTES",
        "MAX_MANIFEST_BYTES",
        "MAX_SIGNATURE_BYTES",
    ):
        value = getattr(module, name, None)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise RuntimeError("preverified release guard size contract is incomplete")
    error_type = getattr(module, "ReleaseGuardError", None)
    if not isinstance(error_type, type) or not issubclass(error_type, Exception):
        raise RuntimeError("preverified release guard exception contract is incomplete")
    return module


def _stable_pinned_python_module(
    path: Path,
    *,
    expected_sha256: str,
    module_name: str,
    require_root_control: bool,
    exact_mode: int | None = None,
) -> types.ModuleType:
    """Compile one pinned immutable byte snapshot without reopening its path."""

    if (
        not path.is_absolute()
        or not hasattr(os, "O_NOFOLLOW")
        or re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is None
        or not module_name
    ):
        raise RuntimeError("trusted Python helper loader contract is invalid")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise RuntimeError(f"cannot open trusted Python helper: {path}") from exc
    try:
        before = os.fstat(descriptor)
        live_before = os.lstat(path)
        before_identity = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_nlink,
            before.st_uid,
            before.st_gid,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        live_before_identity = (
            live_before.st_dev,
            live_before.st_ino,
            live_before.st_mode,
            live_before.st_nlink,
            live_before.st_uid,
            live_before.st_gid,
            live_before.st_size,
            live_before.st_mtime_ns,
            live_before.st_ctime_ns,
        )
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before_identity != live_before_identity
            or before.st_size < 2
            or before.st_size > _GUARD_MAXIMUM_BYTES
        ):
            raise RuntimeError("trusted Python helper is not one stable regular file")
        if require_root_control and (
            before.st_uid != 0
            or before.st_gid != 0
            or before.st_mode & 0o022
            or (exact_mode is not None and stat.S_IMODE(before.st_mode) != exact_mode)
        ):
            raise RuntimeError("trusted Python helper is not root-controlled")
        chunks: list[bytes] = []
        remaining = _GUARD_MAXIMUM_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        source = b"".join(chunks)
        after = os.fstat(descriptor)
        live_after = os.lstat(path)
        after_identity = (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_nlink,
            after.st_uid,
            after.st_gid,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        live_after_identity = (
            live_after.st_dev,
            live_after.st_ino,
            live_after.st_mode,
            live_after.st_nlink,
            live_after.st_uid,
            live_after.st_gid,
            live_after.st_size,
            live_after.st_mtime_ns,
            live_after.st_ctime_ns,
        )
        if (
            len(source) != before.st_size
            or len(source) > _GUARD_MAXIMUM_BYTES
            or before_identity != after_identity
            or after_identity != live_after_identity
        ):
            raise RuntimeError("trusted Python helper changed while it was captured")
    except OSError as exc:
        raise RuntimeError("cannot capture a stable trusted Python helper") from exc
    finally:
        os.close(descriptor)

    if not secrets.compare_digest(hashlib.sha256(source).hexdigest(), expected_sha256):
        raise RuntimeError("trusted Python helper digest does not match its leaf pin")
    module = types.ModuleType(module_name)
    module.__file__ = str(path)
    module.__package__ = ""
    module.__loader__ = None
    module.__spec__ = None
    try:
        code = compile(source, str(path), "exec", dont_inherit=True, optimize=0)
    except (SyntaxError, ValueError) as exc:
        raise RuntimeError("trusted Python helper source cannot be compiled") from exc
    previous = sys.modules.get(module_name)
    sys.modules[module_name] = module
    try:
        exec(code, module.__dict__)
        return module
    except BaseException:
        if previous is None:
            sys.modules.pop(module_name, None)
        else:
            sys.modules[module_name] = previous
        raise


def _stable_release_guard_module(path: Path) -> Any:
    """Load the pinned guard from one immutable byte snapshot."""

    module = _stable_pinned_python_module(
        path,
        expected_sha256=_GUARD_SHA256,
        module_name=_GUARD_MODULE_NAME,
        # The installed updater is a root trust anchor. Keep source-checkout tests
        # possible without weakening the fixed production path contract.
        require_root_control=path.parts[:3] == ("/", "opt", "uten-imp"),
    )
    return _validate_release_guard_module(module, path)


_guard_missing = object()
_preverified_guard = globals().get(_PREVERIFIED_GUARD_GLOBAL, _guard_missing)
if _preverified_guard is _guard_missing:
    release_guard = _stable_release_guard_module(_GUARD_PATH)
else:
    release_guard = _validate_release_guard_module(_preverified_guard, _GUARD_PATH)


LOG_TAG = "uten-imp-updater"
DEFAULT_STATE_DIR = Path("/var/lib/uten-imp-updater")
DEFAULT_ROOT_STATE_DIR = Path("/var/lib/uten-imp-release")
DEFAULT_LOCK_FILE = DEFAULT_ROOT_STATE_DIR / "operation.lock"
DATABASE_MAINTENANCE_DIR = Path("/var/lib/uten-imp-db-maintenance")
DATABASE_MAINTENANCE_LOCK = DATABASE_MAINTENANCE_DIR / "operation.lock"
ACTIVATION_FAILURE_MARKER = DEFAULT_ROOT_STATE_DIR / "activation-failed.json"
ACTIVATION_IN_PROGRESS_MARKER = DEFAULT_ROOT_STATE_DIR / "activation-in-progress.json"
BOOT_ENABLEMENT_IN_PROGRESS_MARKER = (
    DEFAULT_ROOT_STATE_DIR / "boot-enablement-in-progress.json"
)
RECOVERY_IN_PROGRESS_MARKER = DEFAULT_ROOT_STATE_DIR / "recovery-in-progress.json"
RECOVERY_INGRESS_PENDING = DEFAULT_ROOT_STATE_DIR / "recovery-ingress-pending.json"
RECOVERY_INGRESS_AUTHORIZATION = (
    DEFAULT_ROOT_STATE_DIR / "recovery-ingress-authorization.json"
)
RECOVERY_INGRESS_FINALIZING = (
    DEFAULT_ROOT_STATE_DIR / "recovery-ingress-finalizing.json"
)
RUNTIME_AUTHORITY = DEFAULT_ROOT_STATE_DIR / "runtime-authority.json"
INTERNAL_TEST_ONBOARDING_RECEIPT = (
    DEFAULT_ROOT_STATE_DIR / "internal-test-onboarding.json"
)
INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR = (
    DEFAULT_ROOT_STATE_DIR / "internal-test-onboarding-evidence"
)
INTERNAL_TEST_ONBOARDING_ADOPTION = (
    DEFAULT_ROOT_STATE_DIR / "internal-test-onboarding-adoption.json"
)
INTERNAL_TEST_FIRST_BACKUP_RECEIPT = Path(
    "/var/lib/uten-imp-internal-test-first-backup/first-backup.json"
)
INTERNAL_TEST_FIRST_BACKUP_PRODUCER = Path(
    "/usr/local/libexec/uten-imp-backup/internal_test_first_backup.py"
)
INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER = Path(
    "/usr/local/libexec/uten-imp-backup/internal_test_first_backup_commissioner.py"
)
INTERNAL_TEST_FIRST_BACKUP_TERMINAL = Path(
    "/var/lib/uten-imp-internal-test-backup-commissioner/receipts/terminal.json"
)
INTERNAL_TEST_FIRST_BACKUP_PRODUCER_SHA256 = (
    "9b84a2d9c8750133ecc63ab6d00753eb3917bdde08845f24979a357a241545e5"
)
INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_SHA256 = (
    "18bd34008b9d27e347d1c87f06cd74cb79ef50f105a6f31eaf1302cf170d4682"
)
INTERNAL_TEST_FIRST_BACKUP_ARCHIVE_SUFFIX = ".first-backup.json"
INTERNAL_TEST_FIRST_BACKUP_TERMINAL_ARCHIVE_SUFFIX = ".first-backup-terminal.json"
INTERNAL_TEST_FIRST_BACKUP_REVIEWED_PRODUCER_SHA256 = frozenset(
    {INTERNAL_TEST_FIRST_BACKUP_PRODUCER_SHA256}
)
INTERNAL_TEST_FIRST_BACKUP_REVIEWED_COMMISSIONER_SHA256 = frozenset(
    {INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_SHA256}
)
INTERNAL_TEST_LOCAL_ARCHIVE_COMMAND = (
    "pgbackrest --stanza=uten-imp archive-push %p"
)
INTERNAL_TEST_ACTIVATION_REAUTHORIZATION = (
    DEFAULT_ROOT_STATE_DIR / "internal-test-activation-reauthorization.json"
)
INTERNAL_TEST_ACTIVATION_REAUTHORIZATION_EVIDENCE_DIR = (
    DEFAULT_ROOT_STATE_DIR / "internal-test-activation-reauthorization-evidence"
)
RECOVERY_EVIDENCE_DIR = DEFAULT_ROOT_STATE_DIR / "recovery-evidence"
INTERRUPTED_CONTAINMENT_PLAN = "interrupted-containment-plan.json"
INTERRUPTED_CONTAINMENT_RECEIPT = "interrupted-containment-receipt.json"
RECOVERY_DATABASE_RECEIPTS_DIR = DEFAULT_ROOT_STATE_DIR / "database-receipts"
RECOVERY_DATABASE_DETAIL_DIR = Path(
    "/var/lib/uten-imp-backup/acceptance-receipts"
)
DATABASE_RECOVERY_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/database_recovery_verifier.py"
)
RUNTIME_BOOT_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/runtime_boot_verifier.py"
)
STORAGE_BOOT_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/storage_boot_verifier.py"
)
STORAGE_MOUNT_OBSERVER = Path(
    "/usr/local/libexec/uten-imp-release/storage_mount_observer.py"
)
MIGRATION_AUTHORIZATION_HELPER = Path(
    "/usr/local/libexec/uten-imp-release/migration_authorization.py"
)
MIGRATION_AUTHORIZATION_DIR = Path("/run/uten-imp-migration-authorization")
MIGRATION_AUTHORIZATION = (
    MIGRATION_AUTHORIZATION_DIR / "migration-authorization.json"
)
MIGRATION_AUTHORIZATION_EVIDENCE_DIR = (
    DEFAULT_ROOT_STATE_DIR / "migration-evidence"
)
STORAGE_AUTHORITY = Path("/etc/uten-imp/storage-authority.json")
STORAGE_OBSERVER_UNIT = "uten-imp-storage-observer.service"
STORAGE_OBSERVER_UNIT_FILE = Path(
    "/etc/systemd/system/uten-imp-storage-observer.service"
)
ENTRY_WATCHDOG_UNIT = "uten-imp-entry-watchdog.service"
ENTRY_WATCHDOG_UNIT_FILE = Path(
    "/etc/systemd/system/uten-imp-entry-watchdog.service"
)
ENTRY_WATCHDOG_SCRIPT_FILE = Path(
    "/usr/local/libexec/uten-imp/uten-imp-entry-watchdog"
)
START_AUTHORIZATION_DIR = Path("/run/uten-imp-release")
START_AUTHORIZATION = START_AUTHORIZATION_DIR / "start-authorization.json"
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
# Updated only with a reviewed byte-for-byte verifier change. Phase 4 and the
# runtime both enforce this digest before any recovery database observation.
DATABASE_RECOVERY_VERIFIER_SHA256 = (
    "3aed5823241988ac2271c1378b6c1a8ca1223e37b8d14a8b0e50a5be746429dc"
)
# Updated after the runtime boot verifier and its focused fault tests are
# reviewed byte-for-byte. Phase 4 refuses to install any other source.
RUNTIME_BOOT_VERIFIER_SHA256 = (
    "17406074c47e4c721abcb95b803f09794a76f6d94c29154ce5b0d73e0b788488"
)
STORAGE_BOOT_VERIFIER_SHA256 = (
    "0880678bcff0ad03149c0e0d90fccb9f6b274788b3c4e9e6add0d487d64dd83f"
)
STORAGE_MOUNT_OBSERVER_SHA256 = (
    "b96476e50edad6178e3ab55516659b9b3b656653a6c0e376d173566d2cd88ddb"
)
MIGRATION_AUTHORIZATION_HELPER_SHA256 = (
    "7eafd7e5111d1fceef5ade7ae2bdc63e3b96b44423f4ecf14924571308b02bfe"
)
ENTRY_WATCHDOG_UNIT_SHA256 = (
    "e018a0f67a268e81066350f9d0ae2c923825a3cc907c49c4e4854ce1c807f16a"
)
ENTRY_WATCHDOG_SCRIPT_SHA256 = (
    "cf54f4304452d2a1c271cdbf4605ce73da664e1b3bf3f25628df0e3e74fdab78"
)
LEGACY_RETIREMENT_MARKER = DEFAULT_ROOT_STATE_DIR / "legacy-current-retirement.json"
LEGACY_RETIREMENT_CONFIRMATION = "RETIRE_UNSIGNED_LEGACY_CURRENT_NO_ROLLBACK"
DEFAULT_RELEASE_BASE = Path("/opt/uten-imp")
DEFAULT_ALLOWED_SIGNERS = Path("/etc/uten-imp-updater/release-allowed-signers")
UPDATER_USER = "uten-imp-updater"
CHANNEL = "candidate"
HEALTH_BASE_URL = "http://127.0.0.1:8080"
MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024
MIN_FREE_PERCENT = 15
CAPACITY_WARNING_PERCENT = 30
CAPACITY_CRITICAL_PERCENT = 20
WATCHDOG_SERVICES = (
    "uten-imp-watchdog.service",
    ENTRY_WATCHDOG_UNIT,
)
WATCHDOG_REQUIRED_GATE_COMMANDS = (
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/activation-in-progress.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json",
    ),
    (
        "/usr/bin/python3",
        "/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/recovery_ingress_gate.py",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-in-progress.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-onboarding-adoption.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-activation-reauthorization.json",
    ),
)
APPLICATION_UNIT = "uten-imp.service"
APPLICATION_UNIT_FILE = Path("/etc/systemd/system/uten-imp.service")
APPLICATION_ENV_FILE = Path("/etc/uten-imp/server.env")
APPLICATION_ENV_VALIDATOR = Path("/usr/local/sbin/uten-imp-validate-server-env")
APPLICATION_BOOT_VERIFIER = RUNTIME_BOOT_VERIFIER
APPLICATION_EXECSTART_ARGV = (
    "/usr/bin/java -Xms512m -Xmx4g -Dserver.address=127.0.0.1 "
    "-Dserver.port=8080 -Dspring.flyway.enabled=false -XX:+ExitOnOutOfMemoryError "
    "-jar /opt/uten-imp/current/server/uten-imp-server.jar"
)
APPLICATION_EXECSTART_PRE_COMMANDS = (
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-pending.json",
    ),
    (
        str(APPLICATION_ENV_VALIDATOR),
        f"{APPLICATION_ENV_VALIDATOR} {APPLICATION_ENV_FILE}",
    ),
    ("/usr/bin/mountpoint", "/usr/bin/mountpoint --quiet /data"),
    (
        "/usr/bin/pg_isready",
        "/usr/bin/pg_isready -q -h 127.0.0.1 -p 5432 -d uten_imp -t 10",
    ),
    ("/usr/bin/test", "/usr/bin/test -L /opt/uten-imp/current"),
    (
        "/usr/bin/test",
        "/usr/bin/test -r /opt/uten-imp/current/server/uten-imp-server.jar",
    ),
    (
        "/usr/bin/python3",
        f"/usr/bin/python3 -I {APPLICATION_BOOT_VERIFIER}",
    ),
)
APPLICATION_EXECSTART_PRE_FRAGMENT_LINES = (
    "ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    "ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json",
    "ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-pending.json",
    "ExecStartPre=+/usr/local/sbin/uten-imp-validate-server-env /etc/uten-imp/server.env",
    "ExecStartPre=/usr/bin/mountpoint --quiet /data",
    "ExecStartPre=/usr/bin/pg_isready -q -h 127.0.0.1 -p 5432 -d uten_imp -t 10",
    "ExecStartPre=/usr/bin/test -L /opt/uten-imp/current",
    "ExecStartPre=/usr/bin/test -r /opt/uten-imp/current/server/uten-imp-server.jar",
    "ExecStartPre=+/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/runtime_boot_verifier.py",
)
APPLICATION_EXECSTART_FRAGMENT_LINE = f"ExecStart={APPLICATION_EXECSTART_ARGV}"
APPLICATION_ENV_VALIDATION_OUTPUT = (
    "SERVER_ENV_CONFIGURATION_OK",
    "BOOTSTRAP_ADMIN_CONTROL: if the one-time credential is active, complete the HTTPS first-login password change; verify the old credential is rejected and users.must_change_password=false with last_password_changed_at set; then, in an approved maintenance window, empty BOOTSTRAP_ADMIN_PASSWORD, set UTEN_BOOTSTRAP_ADMIN_RETIRED=true, revalidate, and restart through the controlled activation path.",
    "NOTE: this validates local configuration only; OSS connectivity, least-privilege RAM policy, HTTPS certificate, and bucket versioning still require live acceptance.",
)
INTERNAL_TEST_APPLICATION_ENV_VALIDATOR = Path(
    "/usr/local/sbin/uten-imp-validate-internal-test-server-env"
)
INTERNAL_TEST_STORAGE_VALIDATOR = Path(
    "/usr/local/sbin/uten-imp-validate-internal-test-storage"
)
INTERNAL_TEST_DB_COMMISSIONER = Path(
    "/usr/local/sbin/uten-imp-existing-test-host-db-commissioner"
)
INTERNAL_TEST_DB_COMMISSIONER_UNIT = (
    "uten-imp-internal-db-commissioner.service"
)
INTERNAL_TEST_DB_COMMISSIONER_UNIT_FILE = Path(
    "/etc/systemd/system/uten-imp-internal-db-commissioner.service"
)
INTERNAL_TEST_DB_COMMISSIONER_CONTROL_GROUP = (
    "/system.slice/uten-imp-internal-db-commissioner.service"
)
INTERNAL_TEST_NGINX_CONFIG = Path(
    "/etc/nginx/sites-available/uten-imp-internal-test.conf"
)
INTERNAL_TEST_NGINX_LINK = Path(
    "/etc/nginx/sites-enabled/uten-imp-internal-test.conf"
)
INTERNAL_TEST_TLS_ROOT = Path("/etc/uten-imp/tls")
SYSTEM_CA_PATH = Path("/etc/ssl/certs")
INTERNAL_TEST_RUNTIME_CONTRACT = (
    DEFAULT_ROOT_STATE_DIR / "internal-test-runtime-contract.json"
)
INTERNAL_TEST_DB_WORKER_REQUEST = Path(
    "/var/lib/uten-imp-internal-test-commissioning/worker-request.json"
)
STABLE_RELEASE_GUARD = Path(
    "/usr/local/libexec/uten-imp-release/release_guard.py"
)
INTERNAL_TEST_APPLICATION_EXECSTART_ARGV = (
    "/usr/bin/java -Xms512m -Xmx4g -Dspring.profiles.active=internal-test "
    "-Dspring.main.lazy-initialization=false -Dserver.address=127.0.0.1 "
    "-Dserver.port=8080 -Dspring.flyway.enabled=false "
    "-Duten.storage.provider=local "
    "-Duten.storage.local-dir=/data/uten-imp/attachments "
    "-Duten.storage.uploads-enabled=false -XX:+ExitOnOutOfMemoryError "
    "-jar /opt/uten-imp/current/server/uten-imp-server.jar"
)
INTERNAL_TEST_APPLICATION_EXECSTART_PRE_COMMANDS = (
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-pending.json",
    ),
    (
        "/bin/bash",
        "/bin/bash --noprofile --norc -p "
        "/usr/local/sbin/uten-imp-validate-internal-test-server-env "
        "/etc/uten-imp/server.env",
    ),
    (
        str(INTERNAL_TEST_STORAGE_VALIDATOR),
        str(INTERNAL_TEST_STORAGE_VALIDATOR),
    ),
    (
        "/usr/bin/pg_isready",
        "/usr/bin/pg_isready -q -h 127.0.0.1 -p 5432 -d uten_imp -t 10",
    ),
    ("/usr/bin/test", "/usr/bin/test -L /opt/uten-imp/current"),
    (
        "/usr/bin/test",
        "/usr/bin/test -r /opt/uten-imp/current/server/uten-imp-server.jar",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test -w /data/uten-imp/attachments/staging",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test -w /data/uten-imp/attachments/final",
    ),
    (
        "/usr/bin/python3",
        "/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/runtime_boot_verifier.py",
    ),
)
INTERNAL_TEST_APPLICATION_EXECSTART_PRE_FRAGMENT_LINES = (
    "ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    "ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json",
    "ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-pending.json",
    "ExecStartPre=+/bin/bash --noprofile --norc -p /usr/local/sbin/uten-imp-validate-internal-test-server-env /etc/uten-imp/server.env",
    "ExecStartPre=+/usr/local/sbin/uten-imp-validate-internal-test-storage",
    "ExecStartPre=/usr/bin/pg_isready -q -h 127.0.0.1 -p 5432 -d uten_imp -t 10",
    "ExecStartPre=/usr/bin/test -L /opt/uten-imp/current",
    "ExecStartPre=/usr/bin/test -r /opt/uten-imp/current/server/uten-imp-server.jar",
    "ExecStartPre=/usr/bin/test -w /data/uten-imp/attachments/staging",
    "ExecStartPre=/usr/bin/test -w /data/uten-imp/attachments/final",
    "ExecStartPre=+/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/runtime_boot_verifier.py",
)
INTERNAL_TEST_APPLICATION_EXECSTART_FRAGMENT_LINE = (
    f"ExecStart={INTERNAL_TEST_APPLICATION_EXECSTART_ARGV}"
)
INTERNAL_TEST_APPLICATION_ENV_VALIDATION_OUTPUT = (
    "INTERNAL_TEST_SERVER_ENV_OK",
    "Runtime is loopback-only behind HTTPS Nginx; Flyway, Swagger, website integration, external APIs and attachment intake remain disabled.",
    "Local attachments are pinned to /data/uten-imp/attachments and require the independent storage preflight.",
)
INTERNAL_TEST_APPROVAL_RE = re.compile(r"CHG-[A-Z0-9][A-Z0-9._-]{5,95}")
INTERNAL_TEST_VERSION_RE = re.compile(r"v\d{4}\.\d{2}\.\d{2}-[1-9]\d{0,2}")
INTERNAL_TEST_TRANSACTION_RE = re.compile(
    r"internal-test-db-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}"
)
UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-"
    r"[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}"
)
POSTGRES_META_UNIT = "postgresql.service"
POSTGRES_UNIT = "postgresql@16-main.service"
DATABASE_BOOT_UNITS = (POSTGRES_META_UNIT, POSTGRES_UNIT)
POSTGRES_START_CONF = Path("/etc/postgresql/16/main/start.conf")
POSTGRES_GENERATOR_WANTS_DIR = Path(
    "/run/systemd/generator/postgresql.service.wants"
)
POSTGRES_GENERATOR_LINK = POSTGRES_GENERATOR_WANTS_DIR / POSTGRES_UNIT
POSTGRES_STORAGE_DROPIN_FILE = Path(
    "/etc/systemd/system/postgresql@16-main.service.d/uten-imp-storage.conf"
)
POSTGRES_STORAGE_DROPIN_LINES = (
    "# Install as /etc/systemd/system/postgresql@16-main.service.d/uten-imp-storage.conf.",
    "# PostgreSQL must never touch a merely present /data path or an uncommissioned",
    "# replacement filesystem. The fixed root helper verifies UUID, md source,",
    "# filesystem, rw/nodev/nosuid/noexec and capacity before the postmaster starts.",
    "[Unit]",
    "After=data.mount",
    "BindsTo=data.mount",
    "RequiresMountsFor=/data",
    "",
    "[Service]",
    "ExecStartPre=+/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/storage_boot_verifier.py",
)
MIGRATION_UNIT = "uten-imp-migrate.service"
MIGRATION_UNIT_FILE = Path("/etc/systemd/system/uten-imp-migrate.service")
MIGRATION_ENV_FILE = Path("/etc/uten-imp-migrator/migrator.env")
MIGRATION_ENV_VALIDATOR = Path("/usr/local/sbin/uten-imp-validate-migrator-env")
MIGRATION_EXECSTART_ARGV = (
    "/usr/bin/java -Xms64m -Xmx512m -XX:+ExitOnOutOfMemoryError -jar "
    "/opt/uten-imp/current/server/uten-imp-migrator.jar"
)
MIGRATION_EXECSTART_PRE_COMMANDS = (
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    ),
    (
        str(MIGRATION_ENV_VALIDATOR),
        f"{MIGRATION_ENV_VALIDATOR} {MIGRATION_ENV_FILE}",
    ),
    ("/usr/bin/mountpoint", "/usr/bin/mountpoint --quiet /data"),
    (
        "/usr/bin/pg_isready",
        "/usr/bin/pg_isready -q -h 127.0.0.1 -p 5432 -d uten_imp -U uten_migrator -t 10",
    ),
    ("/usr/bin/test", "/usr/bin/test -L /opt/uten-imp/current"),
    (
        "/usr/bin/test",
        "/usr/bin/test -r /opt/uten-imp/current/server/uten-imp-migrator.jar",
    ),
    (
        "/usr/bin/python3",
        "/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/"
        "migration_authorization.py consume",
    ),
)
MIGRATION_EXECSTART_PRE_FRAGMENT_LINES = (
    "ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    "ExecStartPre=+/usr/local/sbin/uten-imp-validate-migrator-env /etc/uten-imp-migrator/migrator.env",
    "ExecStartPre=/usr/bin/mountpoint --quiet /data",
    "ExecStartPre=/usr/bin/pg_isready -q -h 127.0.0.1 -p 5432 -d uten_imp -U uten_migrator -t 10",
    "ExecStartPre=/usr/bin/test -L /opt/uten-imp/current",
    "ExecStartPre=/usr/bin/test -r /opt/uten-imp/current/server/uten-imp-migrator.jar",
    "ExecStartPre=+/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/"
    "migration_authorization.py consume",
)
MIGRATION_EXECSTART_FRAGMENT_LINE = f"ExecStart={MIGRATION_EXECSTART_ARGV}"
MIGRATION_ENV_VALIDATION_OUTPUT = (
    "MIGRATOR_ENV_CONFIGURATION_OK",
    "The file is isolated from the application account and contains no database URL or role override.",
)
NGINX_UNIT = "nginx.service"
NGINX_FRAGMENT_FILE = Path("/usr/lib/systemd/system/nginx.service")
NGINX_DROPIN_FILE = Path("/etc/systemd/system/nginx.service.d/uten-imp.conf")
NGINX_EXECSTART_ARGV = "/usr/sbin/nginx -g daemon on; master_process on;"
NGINX_EXECRELOAD_ARGV = (
    "/usr/sbin/nginx -g daemon on; master_process on; -s reload"
)
NGINX_EXECSTOP_ARGV = (
    "/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /run/nginx.pid"
)
NGINX_READINESS_GATE = Path("/usr/local/libexec/uten-imp/uten-imp-wait-ready")
NGINX_EXECSTART_PRE_COMMANDS = (
    (
        "/usr/sbin/nginx",
        "/usr/sbin/nginx -t -q -g daemon on; master_process on;",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/activation-in-progress.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-in-progress.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-onboarding-adoption.json",
    ),
    (
        "/usr/bin/test",
        "/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-activation-reauthorization.json",
    ),
    (
        "/usr/bin/python3",
        "/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/recovery_ingress_gate.py",
    ),
    (str(NGINX_READINESS_GATE), str(NGINX_READINESS_GATE)),
)
NGINX_EXECSTART_POST_COMMANDS = (
    (
        "/usr/bin/python3",
        "/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/recovery_commit_boot_verifier.py --finalize-ingress",
    ),
)
NGINX_DROPIN_LINES = (
    "# Install as /etc/systemd/system/nginx.service.d/uten-imp.conf.",
    "# PID 1 must never restart a failed start job: the fatal ExecStartPost proof",
    "# runs after listeners open, and RestartPreventExitStatus does not apply to an",
    "# ExecStartPost signal/failure.  Once all durable gates are clear, the entry",
    "# watchdog owns bounded recovery of a later Nginx master-process failure.",
    "[Unit]",
    "After=uten-imp.service uten-imp-recovery-commit-verifier.service",
    "Requires=uten-imp-recovery-commit-verifier.service",
    "BindsTo=uten-imp.service",
    "PartOf=uten-imp.service",
    "StartLimitIntervalSec=10min",
    "StartLimitBurst=8",
    "StartLimitAction=none",
    "",
    "[Service]",
    "ExecStartPre=/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json",
    "ExecStartPre=/usr/bin/test ! -e /var/lib/uten-imp-release/activation-in-progress.json",
    "ExecStartPre=/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json",
    "ExecStartPre=/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-in-progress.json",
    "ExecStartPre=/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-onboarding-adoption.json",
    "ExecStartPre=/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-activation-reauthorization.json",
    "ExecStartPre=/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/recovery_ingress_gate.py",
    "ExecStartPre=/usr/local/libexec/uten-imp/uten-imp-wait-ready",
    "ExecStartPost=/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/recovery_commit_boot_verifier.py --finalize-ingress",
    "Restart=no",
    "RestartSec=3s",
    "RestartSteps=5",
    "RestartMaxDelaySec=30s",
    "TimeoutStartSec=90s",
)
SYSTEMD_EXEC_RECORD_RE = re.compile(
    r"\{ path=(?P<path>[^ ;{}]+) ; argv\[\]=(?P<argv>[^{}\r\n]*?) ; "
    r"ignore_errors=(?P<ignore>yes|no) ; [^{}]*\}"
)
WATCHDOG_TIMERS = (
    "uten-imp-watchdog.timer",
    "uten-imp-entry-watchdog.timer",
)
BOOT_UNITS = (
    "uten-imp.service",
    "nginx.service",
    *WATCHDOG_TIMERS,
)
SYSTEMD_ENABLEMENT_DIRECTORIES = (
    Path("/etc/systemd/system/multi-user.target.wants"),
    Path("/etc/systemd/system/timers.target.wants"),
)
RECOVERY_APPROVAL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}")
RECOVERY_RECEIPT_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}\.json")
RECOVERY_DETAIL_REFERENCE_RE = re.compile(
    r"path=(/var/lib/uten-imp-backup/acceptance-receipts/"
    r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}\.json);sha256=([0-9a-f]{64})"
)
RECOVERY_EVIDENCE_REFERENCE_RE = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9._:/@+=-]{2,511}"
)
POSTGRES_SYSTEM_IDENTIFIER_RE = re.compile(r"[0-9]{16,24}")
POSTGRES_WAL_RE = re.compile(r"[0-9A-F]{24}")
BOOT_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
START_AUTHORIZATION_ID_RE = re.compile(r"[0-9a-f]{32}")
START_AUTHORIZATION_CONSUMED_RE = re.compile(
    r"start-authorization\.consumed-[1-9][0-9]*-[0-9a-f]{16}\.json"
)
MIGRATION_AUTHORIZATION_ARCHIVE_RE = re.compile(
    r"migration-authorization\.(?:consumed|cancelled)-[0-9a-f]{32}-"
    r"[0-9a-f]{64}\.json"
)
MIGRATION_AUTHORIZATION_NONCE_RE = re.compile(r"[0-9a-f]{32}")
MIGRATION_AUTHORIZATION_TRANSACTION_RE = re.compile(
    r"activation-[0-9a-f]{64}-[0-9a-f]{32}"
)
MIGRATION_AUTHORIZATION_TTL_SECONDS = 120
UTC_TIMESTAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
MAX_ROOT_EVIDENCE_BYTES = 256 * 1024
MAX_DATABASE_OBSERVATION_BYTES = 4 * 1024 * 1024
REQUIRED_DATABASE_BUSINESS_CHECKS = {
    "attachments",
    "audit",
    "finance",
    "inventory",
    "procurement",
    "production",
    "sales",
}


class UpdaterError(RuntimeError):
    """Raised for a fail-closed staging or activation error."""


class MigrationUnitError(UpdaterError):
    """Raised when the isolated, non-root Flyway process did not prove success."""


def fail(message: str) -> NoReturn:
    raise UpdaterError(message)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def log(message: str, priority: str = "notice") -> None:
    rendered = f"[{LOG_TAG}] {message}"
    print(rendered, flush=True)
    try:
        subprocess.run(
            ["logger", "-p", f"daemon.{priority}", "-t", LOG_TAG, "--", message],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def atomic_json(path: Path, value: dict[str, Any], mode: int = 0o640) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_bytes(path: Path, value: bytes, mode: int = 0o600) -> None:
    """Atomically restore exact root evidence bytes without following a path link."""
    if not isinstance(value, bytes) or not value:
        fail("root evidence bytes must be non-empty")
    require_real_directory(path.parent, owner_uid=0)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def read_root_evidence_bytes(
    path: Path, *, maximum_bytes: int = MAX_ROOT_EVIDENCE_BYTES
) -> bytes:
    """Read one single-link root-only evidence file through an O_NOFOLLOW descriptor."""
    if not path.is_absolute():
        fail("root evidence path must be absolute")
    require_root_controlled_file(path, secret=True)
    if not hasattr(os, "O_NOFOLLOW"):
        fail("this platform cannot enforce no-follow root evidence reads")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        details = os.fstat(descriptor)
        path_details = path.lstat()
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_mode & 0o077
            or details.st_nlink != 1
            or (details.st_dev, details.st_ino)
            != (path_details.st_dev, path_details.st_ino)
        ):
            fail("root evidence must be a stable single-link root-only regular file")
        if details.st_size < 2 or details.st_size > maximum_bytes:
            fail("root evidence size is outside the allowed range")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b"".join(chunks)
        if len(value) != details.st_size or len(value) > maximum_bytes:
            fail("root evidence changed while it was being read")
        return value
    finally:
        os.close(descriptor)


def read_root_controlled_bytes(
    path: Path, *, exact_mode: int, maximum_bytes: int = MAX_ROOT_EVIDENCE_BYTES
) -> bytes:
    """Read a non-secret root:root contract through one stable no-follow fd."""
    if not path.is_absolute() or exact_mode not in {0o600, 0o640, 0o644, 0o755}:
        fail("root contract read requested an unsupported path or mode")
    require_root_controlled_file(path)
    if not hasattr(os, "O_NOFOLLOW"):
        fail("this platform cannot enforce no-follow root contract reads")
    descriptor = os.open(
        path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    )
    try:
        details = os.fstat(descriptor)
        path_details = path.lstat()
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != exact_mode
            or details.st_nlink != 1
            or (details.st_dev, details.st_ino)
            != (path_details.st_dev, path_details.st_ino)
        ):
            fail("root contract must be a stable exact-mode single-link regular file")
        if details.st_size < 2 or details.st_size > maximum_bytes:
            fail("root contract size is outside the allowed range")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b"".join(chunks)
        after = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            len(value) != details.st_size
            or len(value) > maximum_bytes
            or (details.st_dev, details.st_ino, details.st_size, details.st_mtime_ns, details.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (live_after.st_dev, live_after.st_ino, live_after.st_size, live_after.st_mtime_ns, live_after.st_ctime_ns)
        ):
            fail("root contract changed while it was read")
        return value
    finally:
        os.close(descriptor)


@contextlib.contextmanager
def sealed_memory_snapshot(payload: bytes, label: str) -> Iterator[int]:
    """Expose immutable captured bytes to one child without reopening a path."""

    if (
        not payload
        or not label
        or not hasattr(os, "memfd_create")
        or any(
            not hasattr(fcntl, name)
            for name in (
                "F_ADD_SEALS",
                "F_GET_SEALS",
                "F_SEAL_GROW",
                "F_SEAL_SEAL",
                "F_SEAL_SHRINK",
                "F_SEAL_WRITE",
            )
        )
    ):
        fail("sealed TLS snapshot support is unavailable")
    flags = getattr(os, "MFD_CLOEXEC", 0) | getattr(os, "MFD_ALLOW_SEALING", 0)
    try:
        descriptor = os.memfd_create(f"uten-{label}", flags)
    except OSError as exc:
        raise UpdaterError("cannot create sealed TLS snapshot") from exc
    try:
        offset = 0
        while offset < len(payload):
            try:
                written = os.write(descriptor, payload[offset:])
            except OSError as exc:
                raise UpdaterError("cannot populate sealed TLS snapshot") from exc
            if written <= 0:
                fail("sealed TLS snapshot write made no progress")
            offset += written
        seals = (
            fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_SEAL
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_WRITE
        )
        try:
            fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, seals)
            observed = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
        except OSError as exc:
            raise UpdaterError("cannot seal TLS snapshot") from exc
        if observed & seals != seals or os.fstat(descriptor).st_size != len(payload):
            fail("TLS snapshot seal or size differs")
        yield descriptor
    finally:
        os.close(descriptor)


def validate_internal_test_tls_contract(value: dict[str, Any]) -> None:
    """Revalidate exact reviewed TLS bytes, SAN, expiry and key matching."""

    domain = release_guard.require_string(
        value.get("internalDomain"), "internal-test TLS domain"
    )
    if (
        len(domain) > 253
        or domain.lower() != domain
        or re.fullmatch(
            r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?",
            domain,
        )
        is None
    ):
        fail("internal-test TLS domain is not canonical")
    certificate = Path(
        release_guard.require_string(
            value.get("tlsCertificatePath"), "internal-test TLS certificate path"
        )
    )
    key = Path(
        release_guard.require_string(
            value.get("tlsKeyPath"), "internal-test TLS key path"
        )
    )
    try:
        if (
            certificate.parent.resolve(strict=True)
            != INTERNAL_TEST_TLS_ROOT.resolve(strict=True)
            or key.parent.resolve(strict=True)
            != INTERNAL_TEST_TLS_ROOT.resolve(strict=True)
        ):
            fail("internal-test TLS material escaped its fixed private directory")
    except OSError as exc:
        raise UpdaterError("internal-test TLS directory cannot be resolved") from exc
    certificate_bytes = read_root_controlled_bytes(
        certificate, exact_mode=0o644, maximum_bytes=1024 * 1024
    )
    key_bytes = read_root_controlled_bytes(
        key, exact_mode=0o600, maximum_bytes=1024 * 1024
    )
    if (
        hashlib.sha256(certificate_bytes).hexdigest()
        != require_recovery_sha256(
            value.get("tlsCertificateSha256"), "internal-test TLS certificate"
        )
        or hashlib.sha256(key_bytes).hexdigest()
        != require_recovery_sha256(value.get("tlsKeySha256"), "internal-test TLS key")
    ):
        fail("internal-test TLS bytes changed from the runtime contract")

    def openssl(
        arguments: list[str],
        payload: bytes | None = None,
        *,
        pass_fds: tuple[int, ...] = (),
    ) -> bytes:
        try:
            completed = subprocess.run(
                ["/usr/bin/openssl", *arguments],
                input=b"" if payload is None else payload,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"},
                timeout=15,
                check=False,
                pass_fds=pass_fds,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise UpdaterError("internal-test TLS OpenSSL validation failed") from exc
        if (
            completed.returncode != 0
            or len(completed.stdout) > 1024 * 1024
            or len(completed.stderr) > 1024 * 1024
        ):
            fail("internal-test TLS material failed OpenSSL validation")
        return completed.stdout

    openssl(["x509", "-noout", "-checkend", "86400"], certificate_bytes)
    san_output = openssl(
        ["x509", "-noout", "-ext", "subjectAltName"], certificate_bytes
    )
    try:
        san_text = san_output.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise UpdaterError(
            "internal-test TLS subjectAltName output is not canonical ASCII"
        ) from exc
    dns_sans = {
        item.rstrip(".").lower()
        for item in re.findall(r"(?:^|[,\s])DNS:([^,\s]+)", san_text)
    }
    if domain not in dns_sans:
        fail("internal-test TLS certificate lacks the exact DNS subjectAltName")
    require_real_directory(SYSTEM_CA_PATH, owner_uid=0)
    with sealed_memory_snapshot(
        certificate_bytes, "internal-test-tls-fullchain"
    ) as descriptor:
        openssl(
            [
                "verify",
                "-x509_strict",
                "-purpose",
                "sslserver",
                "-verify_hostname",
                domain,
                "-CApath",
                str(SYSTEM_CA_PATH),
                "-untrusted",
                f"/proc/self/fd/{descriptor}",
                f"/proc/self/fd/{descriptor}",
            ],
            pass_fds=(descriptor,),
        )
    certificate_key = openssl(["x509", "-pubkey", "-noout"], certificate_bytes)
    private_key = openssl(["pkey", "-pubout"], key_bytes)
    if not certificate_key or certificate_key != private_key:
        fail("internal-test TLS certificate and private key do not match")


def strict_json_object(value: bytes, label: str) -> dict[str, Any]:
    """Decode canonical evidence JSON while rejecting duplicates and non-finite values."""
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                fail(f"{label} contains a duplicate JSON key: {key}")
            result[key] = item
        return result

    def invalid_constant(constant: str) -> NoReturn:
        fail(f"{label} contains a non-finite JSON value: {constant}")

    try:
        decoded = value.decode("utf-8")
        parsed = json.loads(
            decoded,
            object_pairs_hook=object_pairs,
            parse_constant=invalid_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UpdaterError(f"{label} is not valid strict UTF-8 JSON") from exc
    if not isinstance(parsed, dict):
        fail(f"{label} JSON root must be an object")
    return parsed


def canonical_json_sha256(value: dict[str, Any]) -> str:
    encoded = json.dumps(
        value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def run_pinned_python_source(
    path: Path,
    *,
    expected_sha256: str,
    arguments: list[str],
    executable: str,
    environment: dict[str, str],
    capture: bool,
    check: bool,
    timeout: int,
    label: str,
) -> subprocess.CompletedProcess[bytes]:
    """Run only stable captured root-owned bytes; never give Python the path."""

    source = read_root_controlled_bytes(
        path,
        exact_mode=0o644,
        maximum_bytes=4 * 1024 * 1024,
    )
    if not secrets.compare_digest(
        hashlib.sha256(source).hexdigest(), expected_sha256
    ):
        fail(f"{label} differs from its reviewed leaf digest")
    try:
        return subprocess.run(
            [executable, "-I", "-", *arguments],
            input=source,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            env=environment,
            timeout=timeout,
            check=check,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise UpdaterError(f"{label} could not complete") from exc


def updater_venv_inventory_sha256(
    expected_verifier_sha256: str = WHEELHOUSE_SUPPLY_CHAIN_SHA256,
) -> str:
    """Re-verify the credential-bearing updater venv from root-pinned tools."""

    verifier = WHEELHOUSE_SUPPLY_CHAIN
    lock = Path("/opt/uten-imp/updater/requirements.lock")
    venv = Path("/opt/uten-imp/updater/venv")
    if expected_verifier_sha256 != WHEELHOUSE_SUPPLY_CHAIN_SHA256:
        fail("runtime contract authorizes an unpinned wheelhouse verifier")
    require_root_controlled_file(lock)
    completed = run_pinned_python_source(
        verifier,
        expected_sha256=WHEELHOUSE_SUPPLY_CHAIN_SHA256,
        arguments=["verify-installed", "--lock", str(lock), "--venv", str(venv)],
        executable="/usr/bin/python3",
        environment={
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
        },
        capture=False,
        check=False,
        timeout=60,
        label="updater virtualenv verifier",
    )
    if completed.returncode != 0:
        fail("updater virtualenv differs from its reviewed RECORD inventory")
    # verify-installed has just proven the entire venv tree root:root,
    # group/world-nonwritable, regular/safe-symlink-only, and every regular file
    # single-linked. A non-root process cannot mutate this inventory between that
    # proof and the deterministic receipt hash below; concurrent root mutation is
    # outside this updater's privilege-boundary threat model and is caught by the
    # reviewed inventory mismatch before activation can continue.
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


def fsync_directory(path: Path) -> None:
    details = path.lstat()
    if not stat.S_ISDIR(details.st_mode) or path.is_symlink():
        fail(f"cannot fsync an unsafe directory: {path}")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def arm_recovery_ingress_pending(
    *, transaction: Path, commit_receipt: dict[str, Any], commit_path: Path
) -> None:
    atomic_json(
        RECOVERY_INGRESS_PENDING,
        {
            "action": commit_receipt["action"],
            "commitSha256": release_guard.sha256_file(commit_path),
            "markerSha256": commit_receipt["markerSha256"],
            "planSha256": commit_receipt["planSha256"],
            "schemaVersion": 1,
            "status": "RECOVERY_COMMITTED_PENDING_INGRESS",
            "targetVersion": commit_receipt["targetVersion"],
            "transactionDirectory": str(transaction),
        },
        mode=0o600,
    )
    require_root_controlled_file(RECOVERY_INGRESS_PENDING, secret=True)


def process_start_time_ticks(pid: int) -> int:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        _prefix, separator, suffix = raw.rpartition(") ")
        fields = suffix.split()
        if not separator or len(fields) <= 19:
            fail("cannot parse recovery process identity")
        value = int(fields[19])
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise UpdaterError("cannot read recovery process identity") from exc
    if value <= 0:
        fail("recovery process identity is invalid")
    return value


def recovery_issuer_identity(pid: int) -> dict[str, Any]:
    try:
        executable = Path(f"/proc/{pid}/exe").resolve(strict=True)
        command_line = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError as exc:
        raise UpdaterError("cannot read recovery issuer identity") from exc
    if (
        not command_line
        or executable.parent != Path("/usr/bin")
        or not executable.name.startswith("python3")
    ):
        fail("recovery issuer is not the fixed system Python")
    return {
        "issuerCommandLineSha256": hashlib.sha256(command_line).hexdigest(),
        "issuerExecutablePath": str(executable),
        "issuerExecutableSha256": release_guard.sha256_file(executable),
        "issuerPid": pid,
        "issuerStartTimeTicks": process_start_time_ticks(pid),
    }


def authorize_recovery_ingress_probes(*, transaction: Path) -> None:
    """Authorize only entry probes executed while this process holds operation.lock."""
    require_root_controlled_file(RECOVERY_INGRESS_PENDING, secret=True)
    pending_raw = read_root_evidence_bytes(RECOVERY_INGRESS_PENDING)
    if os.path.lexists(RECOVERY_INGRESS_AUTHORIZATION):
        fail("another recovery ingress probe authorization already exists")
    issuer = recovery_issuer_identity(os.getpid())
    atomic_json(
        RECOVERY_INGRESS_AUTHORIZATION,
        {
            "bootId": current_boot_id(),
            **issuer,
            "issuedAtUtc": utc_now(),
            "pendingSha256": hashlib.sha256(pending_raw).hexdigest(),
            "schemaVersion": 1,
            "status": "RECOVERY_INGRESS_PROBE_AUTHORIZED",
            "transactionDirectory": str(transaction),
        },
        mode=0o600,
    )
    require_root_controlled_file(RECOVERY_INGRESS_AUTHORIZATION, secret=True)


def complete_recovery_ingress(*, transaction: Path, receipt: dict[str, Any]) -> None:
    """Publish success after probes, then remove authorization before the gate."""
    require_root_controlled_file(RECOVERY_INGRESS_PENDING, secret=True)
    pending_raw = read_root_evidence_bytes(RECOVERY_INGRESS_PENDING)
    pending = strict_json_object(pending_raw, "recovery ingress pending gate")
    if (
        set(pending)
        != {
            "action", "commitSha256", "markerSha256", "planSha256",
            "schemaVersion", "status", "targetVersion", "transactionDirectory",
        }
        or pending.get("schemaVersion") != 1
        or pending.get("status") != "RECOVERY_COMMITTED_PENDING_INGRESS"
        or pending.get("transactionDirectory") != str(transaction)
    ):
        fail("recovery ingress pending gate differs before terminal commit")
    receipt_path = transaction / "recovery-receipt.json"
    expected_receipt = (
        json.dumps(receipt, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")
    receipt_existed = os.path.lexists(receipt_path)
    if receipt_existed:
        require_root_controlled_file(receipt_path, secret=True)
        if read_root_evidence_bytes(receipt_path) != expected_receipt:
            fail("existing recovery receipt differs from the completed probes")
    else:
        atomic_json(receipt_path, receipt, mode=0o600)
    require_root_controlled_file(receipt_path, secret=True)
    if os.path.lexists(RECOVERY_INGRESS_AUTHORIZATION):
        require_root_controlled_file(RECOVERY_INGRESS_AUTHORIZATION, secret=True)
        authorization = strict_json_object(
            read_root_evidence_bytes(RECOVERY_INGRESS_AUTHORIZATION),
            "recovery ingress probe authorization",
        )
        if (
            set(authorization)
            != {
                "bootId", "issuedAtUtc", "issuerCommandLineSha256",
                "issuerExecutablePath", "issuerExecutableSha256", "issuerPid",
                "issuerStartTimeTicks", "pendingSha256", "schemaVersion", "status",
                "transactionDirectory",
            }
            or authorization.get("schemaVersion") != 1
            or authorization.get("status") != "RECOVERY_INGRESS_PROBE_AUTHORIZED"
            or authorization.get("transactionDirectory") != str(transaction)
            or authorization.get("pendingSha256")
            != hashlib.sha256(pending_raw).hexdigest()
        ):
            fail("recovery ingress authorization differs before terminal commit")
        durable_unlink(RECOVERY_INGRESS_AUTHORIZATION)
    elif not receipt_existed:
        fail("recovery probe authorization disappeared before terminal commit")
    durable_unlink(RECOVERY_INGRESS_PENDING)


def commit_recovery_ingress_for_systemd_finalizer(
    *, transaction: Path, commit_path: Path
) -> None:
    """Durably authorize ingress before systemd starts Nginx.

    The Nginx ExecStartPost finalizer is owned by PID 1, not by this updater
    process.  If the updater is SIGKILLed after Nginx starts, systemd therefore
    still completes the fixed health/static probes and publishes the terminal
    recovery receipt; a failing finalizer makes the Nginx start fail.
    """

    require_root_controlled_file(RECOVERY_INGRESS_PENDING, secret=True)
    pending_raw = read_root_evidence_bytes(RECOVERY_INGRESS_PENDING)
    pending = strict_json_object(pending_raw, "recovery ingress pending gate")
    require_root_controlled_file(commit_path, secret=True)
    commit_sha = release_guard.sha256_file(commit_path)
    if (
        set(pending)
        != {
            "action", "commitSha256", "markerSha256", "planSha256",
            "schemaVersion", "status", "targetVersion", "transactionDirectory",
        }
        or pending.get("schemaVersion") != 1
        or pending.get("status") != "RECOVERY_COMMITTED_PENDING_INGRESS"
        or pending.get("transactionDirectory") != str(transaction)
        or pending.get("commitSha256") != commit_sha
    ):
        fail("recovery ingress pending gate differs before durable authorization")
    archived_pending = transaction / "recovery-ingress-pending.committed.json"
    finalizing = {
        "action": pending["action"],
        "commitSha256": commit_sha,
        "markerSha256": pending["markerSha256"],
        "pendingSha256": hashlib.sha256(pending_raw).hexdigest(),
        "planSha256": pending["planSha256"],
        "schemaVersion": 1,
        "status": "RECOVERY_INGRESS_DURABLY_AUTHORIZED_PENDING_PROBES",
        "targetVersion": pending["targetVersion"],
        "transactionDirectory": str(transaction),
    }
    if os.path.lexists(RECOVERY_INGRESS_FINALIZING):
        require_root_controlled_file(RECOVERY_INGRESS_FINALIZING, secret=True)
        if strict_json_object(
            read_root_evidence_bytes(RECOVERY_INGRESS_FINALIZING),
            "recovery ingress finalization pointer",
        ) != finalizing:
            fail("another recovery ingress finalization is active")
    else:
        atomic_json(RECOVERY_INGRESS_FINALIZING, finalizing, mode=0o600)
    if os.path.lexists(archived_pending):
        require_root_controlled_file(archived_pending, secret=True)
        if read_root_evidence_bytes(archived_pending) != pending_raw:
            fail("archived recovery ingress pending evidence differs")
        durable_unlink(RECOVERY_INGRESS_PENDING)
    else:
        os.replace(RECOVERY_INGRESS_PENDING, archived_pending)
        fsync_directory(transaction)
        fsync_directory(DEFAULT_ROOT_STATE_DIR)
    if os.path.lexists(RECOVERY_INGRESS_AUTHORIZATION):
        # No volatile probe lease is valid once the durable systemd finalizer
        # authority exists.  This also closes adoption from older interrupted
        # source snapshots.
        durable_unlink(RECOVERY_INGRESS_AUTHORIZATION)


def read_systemd_finalized_recovery_receipt(
    *, transaction: Path, commit_receipt: dict[str, Any]
) -> dict[str, Any]:
    if os.path.lexists(RECOVERY_INGRESS_FINALIZING):
        fail("systemd did not terminalize the recovery ingress probes")
    if os.path.lexists(RECOVERY_INGRESS_PENDING) or os.path.lexists(
        RECOVERY_INGRESS_AUTHORIZATION
    ):
        fail("recovery ingress gate remains armed after systemd finalization")
    receipt_path = transaction / "recovery-receipt.json"
    require_root_controlled_file(receipt_path, secret=True)
    receipt = strict_json_object(
        read_root_evidence_bytes(receipt_path), "systemd recovery ingress receipt"
    )
    expected = dict(commit_receipt)
    expected.pop("committedAtUtc")
    expected["completedAtUtc"] = receipt.get("completedAtUtc")
    expected["status"] = "completed"
    if receipt != expected:
        fail("systemd recovery ingress receipt differs from its runtime commit")
    require_recovery_timestamp(
        receipt.get("completedAtUtc"), "systemd recovery ingress completion time"
    )
    return receipt


def fsync_tree(root: Path) -> None:
    """Persist a verified release tree before publishing its directory entry."""
    for current_text, directories, files in os.walk(root, topdown=False, followlinks=False):
        current = Path(current_text)
        for name in files:
            path = current / name
            details = path.lstat()
            if not stat.S_ISREG(details.st_mode) or path.is_symlink():
                fail(f"cannot persist unsafe staging entry: {path}")
            flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            descriptor = os.open(path, flags)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        for name in directories:
            child = current / name
            if child.is_symlink():
                fail(f"cannot persist a staging symlink: {child}")
        fsync_directory(current)


def durable_unlink(path: Path) -> None:
    path.unlink()
    fsync_directory(path.parent)


def require_real_directory(path: Path, *, owner_uid: int | None = None) -> None:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise UpdaterError(f"required directory is missing: {path}") from exc
    if not stat.S_ISDIR(details.st_mode) or path.is_symlink():
        fail(f"required path is not a real directory: {path}")
    if owner_uid is not None and details.st_uid != owner_uid:
        fail(f"directory has the wrong owner: {path}")
    if details.st_mode & 0o022:
        fail(f"directory must not be group/world-writable: {path}")


def system_group_id(name: str) -> int:
    """Resolve a POSIX group only on paths that actually need host identity."""
    try:
        group_module = importlib.import_module("grp")
    except ImportError as exc:
        raise UpdaterError("POSIX group resolution is unavailable on this platform") from exc
    try:
        return int(group_module.getgrnam(name).gr_gid)
    except KeyError as exc:
        raise UpdaterError(f"dedicated group does not exist: {name}") from exc


def require_capacity(path: Path, additional_bytes: int, purpose: str) -> None:
    """Leave both an absolute and proportional filesystem reserve after an operation."""
    if (
        not isinstance(additional_bytes, int)
        or isinstance(additional_bytes, bool)
        or additional_bytes < 0
    ):
        fail("capacity request is invalid")
    usage = shutil.disk_usage(path)
    proportional_reserve = (usage.total * MIN_FREE_PERCENT + 99) // 100
    required_reserve = max(MIN_FREE_BYTES, proportional_reserve)
    if usage.free - additional_bytes < required_reserve:
        fail(
            f"insufficient filesystem capacity for {purpose}; the operation must leave "
            f"at least {MIN_FREE_PERCENT}% or {MIN_FREE_BYTES} bytes free, whichever is larger"
        )


def report_capacity(path: Path, purpose: str) -> dict[str, int]:
    """Emit a read-only, journal-visible capacity signal without deleting releases."""
    try:
        usage = shutil.disk_usage(path)
    except OSError as exc:
        log(f"cannot read {purpose} filesystem capacity: {exc}", "err")
        return {"freeBytes": -1, "freePercent": -1, "totalBytes": -1}
    free_percent = (usage.free * 100) // usage.total if usage.total else 0
    priority = "notice"
    if usage.free < MIN_FREE_BYTES or free_percent <= CAPACITY_CRITICAL_PERCENT:
        priority = "err"
    elif free_percent <= CAPACITY_WARNING_PERCENT:
        priority = "warning"
    log(
        f"capacity {purpose}: freeBytes={usage.free} totalBytes={usage.total} "
        f"freePercent={free_percent}",
        priority,
    )
    return {
        "freeBytes": usage.free,
        "freePercent": free_percent,
        "totalBytes": usage.total,
    }


def require_root_controlled_file(path: Path, *, secret: bool = False) -> None:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise UpdaterError(f"required verifier file is missing: {path}") from exc
    if not stat.S_ISREG(details.st_mode) or path.is_symlink():
        fail(f"verifier path is not a regular file: {path}")
    if details.st_uid != 0 or details.st_mode & 0o022:
        fail(f"verifier file must be root-owned and not group/world-writable: {path}")
    if secret and details.st_mode & 0o077:
        fail(f"secret file must be mode 0600 or stricter: {path}")
    current = path.parent
    while True:
        try:
            parent_details = current.lstat()
        except FileNotFoundError as exc:
            raise UpdaterError(f"root-controlled parent is missing: {current}") from exc
        if (
            not stat.S_ISDIR(parent_details.st_mode)
            or current.is_symlink()
            or parent_details.st_uid != 0
            or parent_details.st_mode & 0o022
        ):
            fail(f"root-controlled parent directory is unsafe: {current}")
        parent = current.parent
        if parent == current:
            break
        current = parent


def persistent_state_lock_markers() -> tuple[tuple[Path, str], ...]:
    """Return every durable marker that owns or constrains the release state."""

    # Keep this dynamic rather than capturing the module constants in a global
    # tuple. Focused fault tests replace the fixed roots, and callers must always
    # observe one internally consistent marker namespace after taking the lock.
    return (
        (ACTIVATION_FAILURE_MARKER, "activation failure"),
        (ACTIVATION_IN_PROGRESS_MARKER, "activation in progress"),
        (BOOT_ENABLEMENT_IN_PROGRESS_MARKER, "boot enablement in progress"),
        (RECOVERY_IN_PROGRESS_MARKER, "recovery in progress"),
        (RECOVERY_INGRESS_PENDING, "recovery ingress pending"),
        (RECOVERY_INGRESS_AUTHORIZATION, "recovery ingress authorization"),
        (RECOVERY_INGRESS_FINALIZING, "recovery ingress finalization"),
        (INTERNAL_TEST_ONBOARDING_ADOPTION, "internal-test onboarding adoption"),
        (
            INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
            "internal-test activation reauthorization",
        ),
    )


def recovery_state_lock_compatible_markers() -> frozenset[Path]:
    """Markers that are evidence inputs to controlled activation recovery."""

    return frozenset(
        {
            ACTIVATION_FAILURE_MARKER,
            ACTIVATION_IN_PROGRESS_MARKER,
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
            RECOVERY_IN_PROGRESS_MARKER,
            INTERNAL_TEST_ONBOARDING_ADOPTION,
            INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
        }
    )


class StateLock:
    """Cross-privilege lock whose inode cannot be replaced by the updater user."""

    def __init__(
        self,
        path: Path,
        *,
        internal_test_worker_request_sha256: str | None = None,
    ) -> None:
        self.path = path
        self.descriptor: int | None = None
        self.internal_test_worker_request_sha256 = (
            internal_test_worker_request_sha256
        )
        self.compatible_persistent_markers: frozenset[Path] = frozenset()

    def allow_persistent_markers(self, markers: Iterable[Path]) -> "StateLock":
        """Permit only an explicit recovery/reauthorization evidence lineage.

        Ingress markers are never caller-permitted: once ingress is pending,
        leased, or owned by the PID-1 finalizer, a second release command must
        remain zero-write.  All other permitted markers are still validated as
        root-only regular files after the operation lock has been acquired.
        """

        if self.descriptor is not None:
            fail("persistent marker compatibility must be fixed before lock entry")
        requested = frozenset(Path(path) for path in markers)
        known = {path for path, _label in persistent_state_lock_markers()}
        unknown = requested - known
        if unknown:
            fail(
                "persistent marker compatibility escaped the fixed release state: "
                + ", ".join(str(path) for path in sorted(unknown, key=str))
            )
        ingress = {
            RECOVERY_INGRESS_PENDING,
            RECOVERY_INGRESS_AUTHORIZATION,
            RECOVERY_INGRESS_FINALIZING,
        }
        if requested & ingress:
            fail("recovery ingress markers can never be shared with a release command")
        self.compatible_persistent_markers = requested
        return self

    def __enter__(self) -> "StateLock":
        if not self.path.is_absolute():
            fail("coordination lock path must be absolute")
        parent = self.path.parent
        require_real_directory(parent, owner_uid=0)
        if parent.lstat().st_mode & 0o022:
            fail("coordination lock parent must not be group/world-writable")
        updater_group_id = system_group_id(UPDATER_USER)
        if not hasattr(os, "O_NOFOLLOW"):
            fail("this platform cannot enforce no-follow coordination-lock opens")
        flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
        try:
            descriptor = os.open(self.path, flags)
        except OSError as exc:
            raise UpdaterError(f"cannot safely open coordination lock: {self.path}") from exc
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != updater_group_id
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
        ):
            os.close(descriptor)
            fail(
                "coordination lock must be a single-link regular file owned "
                f"root:{UPDATER_USER} with mode 0660"
            )
        self.descriptor = descriptor
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(descriptor)
            self.descriptor = None
            raise UpdaterError("another staging or activation operation is running") from exc
        try:
            for marker, label in persistent_state_lock_markers():
                if not os.path.lexists(marker):
                    continue
                require_root_controlled_file(marker, secret=True)
                if marker in self.compatible_persistent_markers:
                    continue
                if marker == RECOVERY_INGRESS_FINALIZING:
                    fail(
                        "recovery ingress finalization is still owned by the fixed "
                        "systemd finalizer; no second release mutation may begin"
                    )
                fail(
                    f"persistent {label} marker owns the global release gate: {marker}"
                )
            if os.path.lexists(INTERNAL_TEST_DB_WORKER_REQUEST):
                request_bytes = read_root_evidence_bytes(
                    INTERNAL_TEST_DB_WORKER_REQUEST, maximum_bytes=64 * 1024
                )
                request_sha256 = hashlib.sha256(request_bytes).hexdigest()
                if (
                    self.internal_test_worker_request_sha256 is None
                    or not re.fullmatch(
                        r"[0-9a-f]{64}",
                        self.internal_test_worker_request_sha256,
                    )
                    or request_sha256
                    != self.internal_test_worker_request_sha256
                ):
                    fail(
                        "an internal-test database worker request owns the "
                        "global release gate"
                    )
        except BaseException:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            self.descriptor = None
            raise
        return self

    def __exit__(self, *_: Any) -> None:
        if self.descriptor is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


class DatabaseMaintenanceLock:
    """Serialize every release database boundary with fixed backup jobs.

    The release operation lock is always acquired first by callers.  This
    second, non-blocking lock is the same inode used by the root backup-job
    supervisor, so an already running backup prevents activation before any
    durable release marker, current-link, or database mutation.
    """

    def __init__(self) -> None:
        self.descriptor: int | None = None

    def __enter__(self) -> "DatabaseMaintenanceLock":
        if os.geteuid() != 0:
            fail("database maintenance lock may only be held by root")
        if not hasattr(os, "O_NOFOLLOW"):
            fail("this platform cannot enforce no-follow database-maintenance locks")
        postgres_group_id = system_group_id("postgres")

        require_real_directory(DATABASE_MAINTENANCE_DIR.parent, owner_uid=0)
        try:
            directory = DATABASE_MAINTENANCE_DIR.lstat()
        except FileNotFoundError as exc:
            raise UpdaterError(
                "database maintenance directory is missing; install the reviewed "
                "backup runtime before activation"
            ) from exc
        if (
            not stat.S_ISDIR(directory.st_mode)
            or DATABASE_MAINTENANCE_DIR.is_symlink()
            or directory.st_uid != 0
            or directory.st_gid != postgres_group_id
            or stat.S_IMODE(directory.st_mode) != 0o750
        ):
            fail("database maintenance directory must be root:postgres mode 0750")

        flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
        try:
            before = DATABASE_MAINTENANCE_LOCK.lstat()
            descriptor = os.open(DATABASE_MAINTENANCE_LOCK, flags)
        except OSError as exc:
            raise UpdaterError(
                "cannot safely open the fixed database maintenance lock"
            ) from exc
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != postgres_group_id
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
            or details.st_size != 0
            or (details.st_dev, details.st_ino) != (before.st_dev, before.st_ino)
        ):
            os.close(descriptor)
            fail(
                "database maintenance lock must be one empty root:postgres 0660 "
                "regular file"
            )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            os.close(descriptor)
            raise UpdaterError(
                "another database backup or maintenance operation is already running"
            ) from exc
        except OSError as exc:
            os.close(descriptor)
            raise UpdaterError("database maintenance lock could not be acquired") from exc
        self.descriptor = descriptor
        return self

    def __exit__(self, *_: Any) -> None:
        if self.descriptor is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


def run(command: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def run_oss_helper(
    arguments: list[str], *, capture: bool, environment: dict[str, str]
) -> subprocess.CompletedProcess[bytes]:
    return run_pinned_python_source(
        OSS_IO_HELPER,
        expected_sha256=OSS_IO_SHA256,
        arguments=arguments,
        # Reuse the already-running reviewed updater interpreter image instead
        # of reopening its venv symlink by path for every credential-bearing call.
        executable="/proc/self/exe",
        environment=environment,
        capture=capture,
        check=True,
        timeout=60,
        label="credential-bearing OSS helper",
    )


def oss_stat(object_key: str) -> dict[str, Any]:
    completed = run_oss_helper(
        ["stat", object_key], capture=True, environment=os.environ.copy()
    )
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise UpdaterError(f"OSS stat returned invalid JSON for {object_key}") from exc
    if not isinstance(value, dict) or not isinstance(value.get("contentLength"), int):
        fail(f"OSS stat response is incomplete for {object_key}")
    return value


def oss_download(object_key: str, destination: Path, maximum_bytes: int) -> None:
    details = oss_stat(object_key)
    length = details["contentLength"]
    if length < 1 or length > maximum_bytes:
        fail(f"OSS object size is outside the allowed range: {object_key}")
    environment = os.environ.copy()
    environment["OSS_MAX_DOWNLOAD_BYTES"] = str(maximum_bytes)
    run_oss_helper(
        ["get", object_key, str(destination)],
        capture=False,
        environment=environment,
    )
    if destination.stat().st_size != length:
        fail(f"downloaded object size changed during transfer: {object_key}")


def authorized_key_ids(allowed_signers: Path) -> set[str]:
    require_root_controlled_file(allowed_signers)
    return release_guard.allowed_signing_key_ids(allowed_signers)


def verify_signed_json(
    content: Path, signature: Path, allowed_signers: Path
) -> dict[str, Any]:
    maximum = (
        release_guard.MAX_CHANNEL_BYTES
        if content.name == "channel.json"
        else release_guard.MAX_MANIFEST_BYTES
    )
    value = release_guard.load_json(content, maximum)
    claimed_key_id = release_guard.require_string(
        value.get("signingKeyId"), "signed JSON signingKeyId", release_guard.KEY_ID_RE
    )
    release_guard.verify_ssh_signature(
        content,
        signature,
        allowed_signers,
        expected_key_id=claimed_key_id,
    )
    return value


def cross_check_release(channel_info: dict[str, Any], manifest_info: dict[str, Any]) -> None:
    for key in ("commitSha", "releaseSequence", "signingKeyId", "version"):
        if channel_info[key] != manifest_info[key]:
            fail(f"signed channel and manifest disagree on {key}")


def load_high_water(path: Path) -> int:
    if not path.exists():
        return 0
    value = release_guard.load_json(path, 64 * 1024)
    sequence = value.get("releaseSequence")
    if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 1:
        fail("staging high-water state is malformed")
    return sequence


def commit_staged_candidate(
    *,
    work: Path,
    candidate: Path,
    state_dir: Path,
    candidates: Path,
    high_water_path: Path,
    high_water_value: dict[str, Any],
) -> None:
    """Make candidate durability precede anti-rollback high-water durability."""
    fsync_tree(work)
    os.replace(work, candidate)
    fsync_directory(candidates)
    fsync_directory(state_dir)
    atomic_json(high_water_path, high_water_value)


def stage_release(args: argparse.Namespace) -> None:
    if os.geteuid() == 0:
        fail("automatic staging must run as the dedicated unprivileged updater user")
    state_dir = Path(args.state_dir).resolve()
    require_real_directory(state_dir, owner_uid=os.geteuid())
    report_capacity(state_dir, "staging")
    releases = DEFAULT_RELEASE_BASE / "releases"
    if releases.exists():
        report_capacity(releases, "installed releases")
    else:
        log("installed-release directory is missing; activation is not ready", "err")
    allowed_signers = Path(args.allowed_signers)
    key_ids = authorized_key_ids(allowed_signers)
    candidates = state_dir / "candidates"
    high_water_path = state_dir / "high-water.json"

    with StateLock(Path(args.lock_file)):
        # FINALIZING is checked by StateLock.  Do not even create the ordinary
        # candidate namespace until that global, root-owned recovery gate has
        # been acquired successfully: a fixed PID 1 ingress finalizer owns the
        # release transaction and every competing command must be zero-write.
        if os.path.lexists(candidates):
            require_real_directory(candidates, owner_uid=os.geteuid())
        else:
            os.mkdir(candidates, 0o750)
            fsync_directory(state_dir)
        work = state_dir / ".incoming-candidate"
        if os.path.lexists(work):
            require_real_directory(work, owner_uid=os.geteuid())
            details = work.lstat()
            if stat.S_IMODE(details.st_mode) != 0o700:
                fail("resumable staging workspace has unsafe permissions")
            # Nothing beneath this workspace is authoritative until the final
            # same-filesystem rename into candidates/<signed-version>. A kill
            # therefore resumes by deleting exactly one bounded updater-owned
            # namespace, never by creating another random full-payload orphan.
            shutil.rmtree(work)
            fsync_directory(state_dir)
        os.mkdir(work, 0o700)
        fsync_directory(state_dir)
        try:
            pointer = work / "LATEST.txt"
            oss_download(f"channels/{CHANNEL}/LATEST.txt", pointer, 256)
            try:
                version = pointer.read_text(encoding="ascii").strip()
            except UnicodeDecodeError as exc:
                raise UpdaterError("release channel pointer is not ASCII") from exc
            sequence = release_guard.version_sequence(version)
            channel_key = f"channels/{CHANNEL}/{version}.json"
            channel_signature_key = f"channels/{CHANNEL}/{version}.sig"
            channel_path = work / "channel.json"
            channel_signature_path = work / "channel.sig"
            oss_download(channel_key, channel_path, release_guard.MAX_CHANNEL_BYTES)
            oss_download(
                channel_signature_key,
                channel_signature_path,
                release_guard.MAX_SIGNATURE_BYTES,
            )
            channel = verify_signed_json(channel_path, channel_signature_path, allowed_signers)
            channel_info = release_guard.validate_channel(
                channel, expected_channel=CHANNEL
            )
            if channel_info["version"] != version or channel_info["releaseSequence"] != sequence:
                fail("channel pointer and signed channel disagree")
            if channel_info["signingKeyId"] not in key_ids:
                fail("signed channel names a key that is not in allowed_signers")

            candidate = candidates / version
            high_water = load_high_water(high_water_path)
            if candidate.exists():
                marker = release_guard.load_json(candidate / "STAGED.json", 64 * 1024)
                if (
                    marker.get("version") == version
                    and marker.get("releaseSequence") == sequence
                    and marker.get("channelSha256") == release_guard.sha256_file(channel_path)
                    and isinstance(marker.get("commitSha"), str)
                    and release_guard.COMMIT_RE.fullmatch(marker["commitSha"]) is not None
                    and isinstance(marker.get("stagedAtUtc"), str)
                    and bool(marker["stagedAtUtc"])
                ):
                    if high_water > sequence:
                        fail("existing staged candidate is below the staging high-water mark")
                    if high_water < sequence:
                        atomic_json(
                            high_water_path,
                            {
                                "commitSha": marker["commitSha"],
                                "releaseSequence": sequence,
                                "stagedAtUtc": marker["stagedAtUtc"],
                                "version": version,
                            },
                        )
                        log(f"recovered staging high-water evidence for {version}", "warning")
                    log(f"release {version} is already staged")
                    return
                fail(f"candidate directory already exists with different evidence: {candidate}")
            if sequence <= high_water:
                fail(
                    f"release sequence {sequence} is not above staging high-water mark {high_water}"
                )

            manifest_path = work / "manifest.json"
            manifest_signature_path = work / "manifest.sig"
            oss_download(
                channel_info["manifestObjectKey"],
                manifest_path,
                release_guard.MAX_MANIFEST_BYTES,
            )
            oss_download(
                channel_info["manifestSignatureObjectKey"],
                manifest_signature_path,
                release_guard.MAX_SIGNATURE_BYTES,
            )
            if release_guard.sha256_file(manifest_path) != channel_info["manifestSha256"]:
                fail("manifest digest differs from the signed channel")
            manifest = verify_signed_json(
                manifest_path, manifest_signature_path, allowed_signers
            )
            manifest_info = release_guard.validate_manifest(
                manifest,
                expected_version=version,
                expected_signing_key_id=channel_info["signingKeyId"],
            )
            cross_check_release(channel_info, manifest_info)

            artifact_path = work / manifest_info["artifactFileName"]
            require_capacity(
                state_dir,
                manifest_info["artifactSizeBytes"]
                + manifest_info["uncompressedBytes"],
                "signed release staging",
            )
            details = oss_stat(manifest_info["artifactObjectKey"])
            if details["contentLength"] != manifest_info["artifactSizeBytes"]:
                fail("OSS archive size differs from the signed manifest")
            oss_download(
                manifest_info["artifactObjectKey"],
                artifact_path,
                manifest_info["artifactSizeBytes"],
            )
            if release_guard.sha256_file(artifact_path) != manifest_info["artifactSha256"]:
                fail("downloaded archive digest differs from the signed manifest")
            payload_parent = work / "payload"
            release_guard.safe_extract(artifact_path, payload_parent, manifest_info)
            marker = {
                "artifactSha256": manifest_info["artifactSha256"],
                "channelSha256": release_guard.sha256_file(channel_path),
                "commitSha": manifest_info["commitSha"],
                "manifestSha256": release_guard.sha256_file(manifest_path),
                "payloadVerified": True,
                "releaseSequence": sequence,
                "schemaVersion": 1,
                "stagedAtUtc": utc_now(),
                "version": version,
            }
            atomic_json(work / "STAGED.json", marker)
            commit_staged_candidate(
                work=work,
                candidate=candidate,
                state_dir=state_dir,
                candidates=candidates,
                high_water_path=high_water_path,
                high_water_value={
                    "commitSha": manifest_info["commitSha"],
                    "releaseSequence": sequence,
                    "stagedAtUtc": marker["stagedAtUtc"],
                    "version": version,
                },
            )
            log(
                f"staged signed release {version} commit {manifest_info['commitSha']}; "
                "activation was not attempted"
            )
        finally:
            if os.path.lexists(work):
                require_real_directory(work, owner_uid=os.geteuid())
                shutil.rmtree(work)
                fsync_directory(state_dir)


def inspect_release(args: argparse.Namespace) -> None:
    """Verify a staged candidate and print only the values an approver must confirm."""
    if os.geteuid() == 0:
        fail("candidate inspection must run as the unprivileged updater account")
    state_dir = Path(args.state_dir).resolve()
    require_real_directory(state_dir, owner_uid=os.geteuid())
    allowed_signers = Path(args.allowed_signers)
    authorized_key_ids(allowed_signers)
    with StateLock(Path(args.lock_file)):
        _, manifest_info, _ = verify_candidate(
            state_dir / "candidates" / args.version, allowed_signers
        )
    print(
        json.dumps(
            {
                "commitSha": manifest_info["commitSha"],
                "databaseChangePolicy": "explicit-approval-and-fail-closed",
                "flywayHeadVersion": manifest_info["flywayHeadVersion"],
                "flywayMigrationSetSha256": manifest_info[
                    "flywayMigrationSetSha256"
                ],
                "releaseSequence": manifest_info["releaseSequence"],
                "signingKeyId": manifest_info["signingKeyId"],
                "version": manifest_info["version"],
            },
            indent=2,
            sort_keys=True,
        )
    )


def systemd_property(unit: str, property_name: str) -> str | None:
    completed = run(
        ["systemctl", "show", unit, f"--property={property_name}", "--value"],
        check=False,
        capture=True,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def unit_exists(unit: str) -> bool:
    return systemd_property(unit, "LoadState") not in (None, "not-found")


def unit_active(unit: str) -> bool:
    completed = run(["systemctl", "is-active", "--quiet", unit], check=False)
    return completed.returncode == 0


def unit_enabled(unit: str) -> bool:
    completed = run(["systemctl", "is-enabled", "--quiet", unit], check=False)
    return completed.returncode == 0


def stop_unit(unit: str) -> None:
    if not unit_exists(unit):
        return
    run(["systemctl", "stop", unit])
    if unit_active(unit):
        fail(f"systemd unit remained active after stop: {unit}")


def start_unit(unit: str) -> None:
    if not unit_exists(unit):
        fail(f"required systemd unit is not installed: {unit}")
    run(["systemctl", "start", unit])
    if not unit_active(unit):
        fail(f"systemd unit did not become active: {unit}")


def enable_unit(unit: str) -> None:
    if not unit_exists(unit):
        fail(f"required systemd unit is not installed: {unit}")
    run(["systemctl", "enable", unit])
    if not unit_enabled(unit):
        fail(f"systemd unit did not become enabled: {unit}")


def run_oneshot_probe(unit: str) -> None:
    if not unit_exists(unit):
        fail(f"required watchdog probe unit is not installed: {unit}")
    run(["systemctl", "start", unit])
    result = systemd_property(unit, "Result")
    exit_status = systemd_property(unit, "ExecMainStatus")
    if result != "success" or exit_status != "0":
        fail(f"watchdog probe did not complete successfully: {unit}")


def require_migration_authorization_helper() -> None:
    require_root_controlled_file(MIGRATION_AUTHORIZATION_HELPER)
    details = MIGRATION_AUTHORIZATION_HELPER.lstat()
    if (
        details.st_gid != 0
        or details.st_nlink != 1
        or stat.S_IMODE(details.st_mode) != 0o644
    ):
        fail("migration authorization helper must be root:root mode 0644 with one hard link")
    if (
        release_guard.sha256_file(MIGRATION_AUTHORIZATION_HELPER)
        != MIGRATION_AUTHORIZATION_HELPER_SHA256
    ):
        fail("migration authorization helper differs from the reviewed digest")


def current_process_start_time() -> str:
    """Read this exact Linux process birth tick for PID-reuse-resistant grants."""
    try:
        raw = Path("/proc/self/stat").read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as exc:
        raise UpdaterError("cannot read release updater process start time") from exc
    closing = raw.rfind(")")
    fields = raw[closing + 1 :].strip().split() if closing >= 2 else []
    if len(fields) < 20 or not fields[19].isdigit() or int(fields[19]) < 1:
        fail("release updater process start time is malformed")
    return fields[19]


def current_boottime_ns() -> int:
    clock = getattr(time, "CLOCK_BOOTTIME", None)
    if clock is None or not hasattr(time, "clock_gettime_ns"):
        fail("kernel CLOCK_BOOTTIME is unavailable for migration authorization")
    try:
        value = time.clock_gettime_ns(clock)
    except OSError as exc:
        raise UpdaterError("cannot read kernel CLOCK_BOOTTIME") from exc
    if not isinstance(value, int) or value < 1:
        fail("kernel CLOCK_BOOTTIME is malformed")
    return value


def validate_migration_authorization(value: dict[str, Any]) -> str:
    """Validate one volatile Flyway grant without trusting its mutable live facts."""
    release_guard.exact_keys(
        value,
        {
            "bootId",
            "commitSha",
            "expiresAtBoottimeNs",
            "expiresAtUnix",
            "flywayHeadVersion",
            "flywayMigrationSetSha256",
            "issuedAtUnix",
            "issuedAtBoottimeNs",
            "issuedAtUtc",
            "issuerPid",
            "issuerProcStartTime",
            "manifestSha256",
            "markerPath",
            "markerSha256",
            "nonce",
            "releaseSequence",
            "schemaVersion",
            "targetPath",
            "transactionEvidencePath",
            "version",
        },
        "migration authorization",
    )
    require_recovery_schema_version(value, "migration authorization")
    release_guard.require_string(
        value.get("nonce"),
        "migration authorization nonce",
        MIGRATION_AUTHORIZATION_NONCE_RE,
    )
    release_guard.require_string(
        value.get("bootId"), "migration authorization boot ID", BOOT_ID_RE
    )
    release_guard.require_string(
        value.get("commitSha"),
        "migration authorization commit",
        release_guard.COMMIT_RE,
    )
    for key in ("flywayMigrationSetSha256", "manifestSha256", "markerSha256"):
        release_guard.require_string(
            value.get(key), f"migration authorization {key}", release_guard.SHA256_RE
        )
    version = release_guard.require_string(
        value.get("version"), "migration authorization version"
    )
    if release_guard.version_sequence(version) != value.get("releaseSequence"):
        fail("migration authorization version/sequence is inconsistent")
    if value.get("targetPath") != str(DEFAULT_RELEASE_BASE / "releases" / version):
        fail("migration authorization target path is not canonical")
    if value.get("markerPath") != str(ACTIVATION_IN_PROGRESS_MARKER):
        fail("migration authorization marker path is not fixed")
    head = release_guard.require_string(
        value.get("flywayHeadVersion"), "migration authorization Flyway head"
    )
    if not head.isdigit() or int(head) < 1:
        fail("migration authorization Flyway head is malformed")
    issued = require_recovery_integer(
        value.get("issuedAtUnix"), "migration authorization issue time", minimum=1
    )
    expires = require_recovery_integer(
        value.get("expiresAtUnix"), "migration authorization expiry time", minimum=1
    )
    issued_boot = require_recovery_integer(
        value.get("issuedAtBoottimeNs"),
        "migration authorization boot-time issue tick",
        minimum=1,
    )
    expires_boot = require_recovery_integer(
        value.get("expiresAtBoottimeNs"),
        "migration authorization boot-time expiry tick",
        minimum=1,
    )
    if (
        expires - issued != MIGRATION_AUTHORIZATION_TTL_SECONDS
        or expires_boot - issued_boot
        != MIGRATION_AUTHORIZATION_TTL_SECONDS * 1_000_000_000
    ):
        fail("migration authorization TTL differs from the fixed policy")
    require_recovery_timestamp(
        value.get("issuedAtUtc"), "migration authorization issue timestamp"
    )
    require_recovery_integer(
        value.get("issuerPid"), "migration authorization issuer PID", minimum=2
    )
    issuer_start = release_guard.require_string(
        value.get("issuerProcStartTime"),
        "migration authorization issuer process start time",
    )
    if not issuer_start.isdigit() or int(issuer_start) < 1:
        fail("migration authorization issuer process start time is malformed")
    transaction = Path(
        release_guard.require_string(
            value.get("transactionEvidencePath"),
            "migration authorization transaction evidence path",
        )
    )
    expected_transaction = MIGRATION_AUTHORIZATION_EVIDENCE_DIR / (
        f"activation-{value['markerSha256']}-{value['nonce']}"
    )
    if (
        transaction != expected_transaction
        or transaction.parent != MIGRATION_AUTHORIZATION_EVIDENCE_DIR
        or not MIGRATION_AUTHORIZATION_TRANSACTION_RE.fullmatch(transaction.name)
    ):
        fail("migration authorization transaction evidence path is not canonical")
    return "migration-authorization-v1"


def _migration_authorization_entries() -> list[Path]:
    if not os.path.lexists(MIGRATION_AUTHORIZATION_DIR):
        return []
    require_real_directory(MIGRATION_AUTHORIZATION_DIR, owner_uid=0)
    details = MIGRATION_AUTHORIZATION_DIR.lstat()
    if details.st_gid != 0 or stat.S_IMODE(details.st_mode) != 0o700:
        fail("migration authorization directory must be root:root mode 0700")
    try:
        entries = sorted(MIGRATION_AUTHORIZATION_DIR.iterdir(), key=lambda path: path.name)
    except OSError as exc:
        raise UpdaterError("cannot enumerate migration authorization evidence") from exc
    if len(entries) > 64:
        fail("migration authorization archive count exceeds the fixed per-boot limit")
    for entry in entries:
        if entry != MIGRATION_AUTHORIZATION and not MIGRATION_AUTHORIZATION_ARCHIVE_RE.fullmatch(
            entry.name
        ):
            fail(f"unexpected migration authorization directory entry: {entry.name}")
        require_root_controlled_file(entry, secret=True)
        entry_details = entry.lstat()
        if entry_details.st_gid != 0 or stat.S_IMODE(entry_details.st_mode) != 0o600:
            fail("migration authorization evidence must be root:root mode 0600")
    return entries


def _ensure_migration_authorization_directory() -> None:
    if os.path.lexists(MIGRATION_AUTHORIZATION_DIR):
        _migration_authorization_entries()
        return
    parent = MIGRATION_AUTHORIZATION_DIR.parent
    require_real_directory(parent, owner_uid=0)
    if parent.lstat().st_mode & 0o022:
        fail("migration authorization parent directory is writable")
    MIGRATION_AUTHORIZATION_DIR.mkdir(mode=0o700)
    os.chown(MIGRATION_AUTHORIZATION_DIR, 0, 0)
    os.chmod(MIGRATION_AUTHORIZATION_DIR, 0o700)
    fsync_directory(parent)
    _migration_authorization_entries()


def prepare_migration_authorization(
    *, target: Path, manifest: dict[str, Any]
) -> str:
    """Issue the sole short-lived grant after current was atomically switched."""
    require_migration_authorization_helper()
    require_root_controlled_file(ACTIVATION_IN_PROGRESS_MARKER, secret=True)
    releases = DEFAULT_RELEASE_BASE / "releases"
    live_current = current_release(DEFAULT_RELEASE_BASE, releases)
    if live_current is None or live_current != target:
        fail("migration authorization target is not the signed current release")
    if target != releases / manifest["version"]:
        fail("migration authorization target differs from the signed version")
    _ensure_migration_authorization_directory()
    entries = _migration_authorization_entries()
    if entries:
        fail(
            "volatile migration authorization evidence remains; contain the "
            "interrupted transaction before issuing another grant"
        )
    nonce = os.urandom(16).hex()
    if not MIGRATION_AUTHORIZATION_NONCE_RE.fullmatch(nonce):
        fail("generated migration authorization nonce is malformed")
    issued = int(time.time())
    issued_boot = current_boottime_ns()
    marker_raw = read_root_evidence_bytes(ACTIVATION_IN_PROGRESS_MARKER)
    marker_sha256 = hashlib.sha256(marker_raw).hexdigest()
    transaction = MIGRATION_AUTHORIZATION_EVIDENCE_DIR / (
        f"activation-{marker_sha256}-{nonce}"
    )
    value = {
        "bootId": current_boot_id(),
        "commitSha": manifest["commitSha"],
        "expiresAtBoottimeNs": issued_boot
        + MIGRATION_AUTHORIZATION_TTL_SECONDS * 1_000_000_000,
        "expiresAtUnix": issued + MIGRATION_AUTHORIZATION_TTL_SECONDS,
        "flywayHeadVersion": manifest["flywayHeadVersion"],
        "flywayMigrationSetSha256": manifest["flywayMigrationSetSha256"],
        "issuedAtUnix": issued,
        "issuedAtBoottimeNs": issued_boot,
        "issuedAtUtc": utc_now(),
        "issuerPid": os.getpid(),
        "issuerProcStartTime": current_process_start_time(),
        "manifestSha256": installed_manifest_sha256(target),
        "markerPath": str(ACTIVATION_IN_PROGRESS_MARKER),
        "markerSha256": marker_sha256,
        "nonce": nonce,
        "releaseSequence": manifest["releaseSequence"],
        "schemaVersion": 1,
        "targetPath": str(target),
        "transactionEvidencePath": str(transaction),
        "version": manifest["version"],
    }
    validate_migration_authorization(value)
    raw = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
    require_real_directory(MIGRATION_AUTHORIZATION_EVIDENCE_DIR, owner_uid=0)
    evidence_details = MIGRATION_AUTHORIZATION_EVIDENCE_DIR.lstat()
    if evidence_details.st_gid != 0 or stat.S_IMODE(evidence_details.st_mode) != 0o700:
        fail("migration authorization evidence directory must be root:root mode 0700")
    if os.path.lexists(transaction):
        fail("migration authorization transaction evidence already exists")
    transaction.mkdir(mode=0o700)
    os.chown(transaction, 0, 0)
    os.chmod(transaction, 0o700)
    fsync_directory(MIGRATION_AUTHORIZATION_EVIDENCE_DIR)
    atomic_bytes(transaction / "authorization.issued.json", raw, mode=0o600)
    if read_root_evidence_bytes(transaction / "authorization.issued.json") != raw:
        fail("persistent migration authorization evidence changed after write")
    atomic_bytes(MIGRATION_AUTHORIZATION, raw, mode=0o600)
    require_root_controlled_file(MIGRATION_AUTHORIZATION, secret=True)
    persisted = strict_json_object(
        read_root_evidence_bytes(MIGRATION_AUTHORIZATION),
        "persisted migration authorization",
    )
    if persisted != value or validate_migration_authorization(persisted) != "migration-authorization-v1":
        fail("persisted migration authorization differs from the issued grant")
    return nonce


def _migration_authorization_runtime_path(
    kind: str, nonce: str, digest: str
) -> Path:
    if kind not in {"consumed", "cancelled"}:
        fail("migration authorization runtime archive kind is unsupported")
    release_guard.require_string(
        nonce, "migration authorization nonce", MIGRATION_AUTHORIZATION_NONCE_RE
    )
    release_guard.require_string(
        digest, "migration authorization digest", release_guard.SHA256_RE
    )
    return MIGRATION_AUTHORIZATION_DIR / (
        f"migration-authorization.{kind}-{nonce}-{digest}.json"
    )


def _migration_authorization_transaction(
    value: dict[str, Any], raw: bytes
) -> tuple[Path, Path]:
    validate_migration_authorization(value)
    transaction = Path(value["transactionEvidencePath"])
    require_real_directory(MIGRATION_AUTHORIZATION_EVIDENCE_DIR, owner_uid=0)
    base_details = MIGRATION_AUTHORIZATION_EVIDENCE_DIR.lstat()
    if base_details.st_gid != 0 or stat.S_IMODE(base_details.st_mode) != 0o700:
        fail("migration authorization evidence directory must be root:root mode 0700")
    require_real_directory(transaction, owner_uid=0)
    transaction_details = transaction.lstat()
    if (
        transaction.parent != MIGRATION_AUTHORIZATION_EVIDENCE_DIR
        or not MIGRATION_AUTHORIZATION_TRANSACTION_RE.fullmatch(transaction.name)
        or transaction_details.st_gid != 0
        or stat.S_IMODE(transaction_details.st_mode) != 0o700
    ):
        fail("migration authorization transaction evidence directory is unsafe")
    issued = transaction / "authorization.issued.json"
    consumed = transaction / "authorization.consumed.json"
    cancelled = transaction / "authorization.cancelled.json"
    present = [path for path in (issued, consumed, cancelled) if os.path.lexists(path)]
    if len(present) != 1:
        fail("migration authorization persistent raw evidence is missing or ambiguous")
    if read_root_evidence_bytes(present[0]) != raw:
        fail("migration authorization persistent raw evidence differs from /run")
    return transaction, present[0]


def _persist_migration_authorization_terminal(
    *,
    kind: str,
    runtime_archive: Path,
    raw: bytes,
    value: dict[str, Any],
    terminal_state: dict[str, str | None] | None,
    status: str,
) -> None:
    if kind not in {"consumed", "cancelled"} or status not in {
        "migration-succeeded",
        "migration-failed",
        "cancelled-before-consume",
    }:
        fail("migration authorization terminal evidence kind/status is unsupported")
    nonce = value["nonce"]
    digest = hashlib.sha256(raw).hexdigest()
    expected_runtime = _migration_authorization_runtime_path(kind, nonce, digest)
    if runtime_archive != expected_runtime:
        fail("migration authorization runtime archive path is not deterministic")
    if read_root_evidence_bytes(runtime_archive) != raw:
        fail("migration authorization runtime archive bytes changed")
    transaction, persistent_raw = _migration_authorization_transaction(value, raw)
    destination = transaction / f"authorization.{kind}.json"
    if persistent_raw != destination:
        if persistent_raw.name != "authorization.issued.json" or os.path.lexists(destination):
            fail("migration authorization persistent terminal archive is ambiguous")
        os.replace(persistent_raw, destination)
        fsync_directory(transaction)
    if read_root_evidence_bytes(destination) != raw:
        fail("migration authorization persistent terminal bytes changed")
    if terminal_state is not None and set(terminal_state) != {
        "ActiveState",
        "ExecMainStatus",
        "Result",
        "SubState",
    }:
        fail("migration unit terminal evidence is incomplete")
    receipt = {
        "authorizationSha256": digest,
        "completedAtUtc": utc_now(),
        "kind": kind,
        "markerSha256": value["markerSha256"],
        "nonce": nonce,
        "schemaVersion": 1,
        "status": status,
        "systemdTerminalState": terminal_state,
        "transactionEvidencePath": str(transaction),
    }
    receipt_path = transaction / "terminal.json"
    if os.path.lexists(receipt_path):
        existing = strict_json_object(
            read_root_evidence_bytes(receipt_path),
            "migration authorization terminal receipt",
        )
        comparable = dict(receipt)
        comparable["completedAtUtc"] = existing.get("completedAtUtc")
        if existing != comparable:
            fail("migration authorization terminal receipt differs")
    else:
        atomic_json(receipt_path, receipt, mode=0o600)
    require_root_controlled_file(receipt_path, secret=True)
    durable_unlink(runtime_archive)


def discard_unconsumed_migration_authorization(nonce: str) -> None:
    """Persist then remove a grant that systemd never gave to ExecStartPre."""
    if not os.path.lexists(MIGRATION_AUTHORIZATION):
        return
    require_root_controlled_file(MIGRATION_AUTHORIZATION, secret=True)
    raw = read_root_evidence_bytes(MIGRATION_AUTHORIZATION)
    value = strict_json_object(raw, "unconsumed migration authorization")
    validate_migration_authorization(value)
    if value.get("nonce") != nonce:
        fail("migration authorization changed before fail-closed archive")
    digest = hashlib.sha256(raw).hexdigest()
    archive = _migration_authorization_runtime_path("cancelled", nonce, digest)
    if os.path.lexists(archive):
        fail("migration authorization cancellation archive already exists")
    os.rename(MIGRATION_AUTHORIZATION, archive)
    fsync_directory(MIGRATION_AUTHORIZATION_DIR)
    if read_root_evidence_bytes(archive) != raw:
        fail("cancelled migration authorization archive bytes changed")
    _persist_migration_authorization_terminal(
        kind="cancelled",
        runtime_archive=archive,
        raw=raw,
        value=value,
        terminal_state=None,
        status="cancelled-before-consume",
    )


def require_consumed_migration_authorization(
    nonce: str, raw: bytes
) -> tuple[Path, dict[str, Any]]:
    if os.path.lexists(MIGRATION_AUTHORIZATION):
        fail("migration authorization helper did not consume its one-use grant")
    digest = hashlib.sha256(raw).hexdigest()
    consumed = _migration_authorization_runtime_path("consumed", nonce, digest)
    entries = _migration_authorization_entries()
    if entries != [consumed]:
        fail("migration authorization consumption archive is missing or ambiguous")
    value = strict_json_object(
        read_root_evidence_bytes(consumed), "consumed migration authorization"
    )
    validate_migration_authorization(value)
    if value.get("nonce") != nonce:
        fail("migration authorization consumption archive binds another grant")
    if read_root_evidence_bytes(consumed) != raw:
        fail("migration authorization consumption archive changed from issued bytes")
    return consumed, value


def run_migration_unit(authorization_nonce: str) -> None:
    """Run the authorized migration service and require its exact terminal state."""
    if not MIGRATION_AUTHORIZATION_NONCE_RE.fullmatch(authorization_nonce):
        raise MigrationUnitError("migration authorization nonce is malformed")
    if not unit_exists(MIGRATION_UNIT):
        raise MigrationUnitError("required migration unit is not installed")
    require_root_controlled_file(MIGRATION_AUTHORIZATION, secret=True)
    authorization_raw = read_root_evidence_bytes(MIGRATION_AUTHORIZATION)
    authorization = strict_json_object(
        authorization_raw, "migration authorization before systemd start"
    )
    validate_migration_authorization(authorization)
    if authorization.get("nonce") != authorization_nonce:
        raise MigrationUnitError("migration authorization binds another activation")
    start_error: subprocess.CalledProcessError | None = None
    try:
        run(["systemctl", "start", MIGRATION_UNIT])
    except subprocess.CalledProcessError as exc:
        start_error = exc
    properties: dict[str, str | None] = {}
    property_error: Exception | None = None
    for name in ("Result", "ExecMainStatus", "ActiveState", "SubState"):
        try:
            properties[name] = systemd_property(MIGRATION_UNIT, name)
        except Exception as exc:
            # Preserve an exact, complete terminal receipt even if systemctl
            # observation itself fails after ExecStartPre consumed the grant.
            properties[name] = None
            if property_error is None:
                property_error = exc
    expected_success = {
        "Result": "success",
        "ExecMainStatus": "0",
        "ActiveState": "inactive",
        "SubState": "dead",
    }
    if not os.path.lexists(MIGRATION_AUTHORIZATION):
        try:
            consumed, consumed_value = require_consumed_migration_authorization(
                authorization_nonce, authorization_raw
            )
            _persist_migration_authorization_terminal(
                kind="consumed",
                runtime_archive=consumed,
                raw=authorization_raw,
                value=consumed_value,
                terminal_state=properties,
                status=(
                    "migration-succeeded"
                    if start_error is None and properties == expected_success
                    else "migration-failed"
                ),
            )
        except UpdaterError as exc:
            raise MigrationUnitError(
                "isolated migration process lacks exact persistent one-use authorization evidence"
            ) from exc
    elif start_error is None:
        raise MigrationUnitError(
            "isolated migration process returned without consuming its one-use authorization"
        )
    if start_error is not None:
        raise MigrationUnitError("isolated migration process failed") from start_error
    if property_error is not None:
        raise MigrationUnitError(
            "isolated migration process terminal state could not be observed"
        ) from property_error
    if properties != expected_success:
        raise MigrationUnitError("isolated migration process did not reach exact success state")


def systemd_exec_commands(
    value: str,
    property_name: str,
    *,
    expected_ignore_errors: str = "no",
) -> list[tuple[str, str]]:
    matches = list(SYSTEMD_EXEC_RECORD_RE.finditer(value))
    remainder = SYSTEMD_EXEC_RECORD_RE.sub("", value)
    if not matches or remainder.replace(";", "").strip():
        fail(f"{property_name} has an unrecognized systemd representation")
    commands: list[tuple[str, str]] = []
    for match in matches:
        if match.group("ignore") != expected_ignore_errors:
            fail(f"{property_name} has an unsafe command failure policy")
        commands.append((match.group("path"), match.group("argv").strip()))
    return commands


def assert_fragment_commands(
    fragment_path: Path,
    *,
    label: str,
    expected_exec_start: str,
    expected_exec_start_pre: tuple[str, ...],
) -> None:
    require_root_controlled_file(fragment_path)
    try:
        fragment_text = fragment_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise UpdaterError(f"cannot read the {label} unit fragment safely") from exc
    fragment_lines = fragment_text.splitlines()
    actual_exec_start = [
        line for line in fragment_lines if line.lstrip().startswith("ExecStart=")
    ]
    actual_exec_start_pre = [
        line for line in fragment_lines if line.lstrip().startswith("ExecStartPre")
    ]
    if actual_exec_start != [expected_exec_start]:
        fail(f"{label} unit fragment has an unsafe ExecStart privilege prefix or command")
    if actual_exec_start_pre != list(expected_exec_start_pre):
        fail(f"{label} unit fragment has unsafe ExecStartPre privilege prefixes or commands")


def run_root_environment_validator(
    validator: Path,
    environment_file: Path,
    *,
    label: str,
    expected_output: tuple[str, ...],
) -> None:
    require_root_controlled_file(validator)
    try:
        validation = run([str(validator), str(environment_file)], capture=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise UpdaterError(f"{label} environment validation failed") from exc
    if tuple(validation.stdout.splitlines()) != expected_output:
        fail(f"{label} environment validator returned unexpected evidence")


def deployment_profile() -> str:
    """Read only the canonical profile selector; the profile validator does the rest."""
    require_root_controlled_file(APPLICATION_ENV_FILE, secret=True)
    try:
        raw = APPLICATION_ENV_FILE.read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise UpdaterError("application environment is not readable UTF-8") from exc
    if b"\0" in raw or len(raw) > 256 * 1024:
        fail("application environment size is outside the reviewed range")
    values = [
        line[len("UTEN_PROFILE=") :]
        for line in text.splitlines()
        if line.startswith("UTEN_PROFILE=")
    ]
    if len(values) != 1 or values[0] not in {"prod", "internal-test"}:
        fail("application environment has no unique supported UTEN_PROFILE")
    profile = values[0]
    contract_present = os.path.lexists(INTERNAL_TEST_RUNTIME_CONTRACT)
    if profile == "internal-test" and not contract_present:
        fail("internal-test profile requires the pinned root runtime contract")
    if profile != "internal-test" and contract_present:
        fail("internal-test runtime contract cannot coexist with another profile")
    return profile


def internal_test_runtime_contract() -> tuple[dict[str, Any], str]:
    """Verify the root-published host-policy authority and every pinned byte."""
    require_root_controlled_file(INTERNAL_TEST_RUNTIME_CONTRACT, secret=True)
    contract_details = INTERNAL_TEST_RUNTIME_CONTRACT.lstat()
    if (
        contract_details.st_gid != 0
        or contract_details.st_nlink != 1
        or stat.S_IMODE(contract_details.st_mode) != 0o600
    ):
        fail("internal-test runtime contract must be root:root mode 0600 with one hard link")
    raw = read_root_evidence_bytes(INTERNAL_TEST_RUNTIME_CONTRACT)
    value = strict_json_object(raw, "internal-test runtime contract")
    release_guard.exact_keys(
        value,
        {
            "activationEntrypointSha256",
            "attachmentLayoutReceiptPath",
            "attachmentLayoutReceiptSha256",
            "backupContainmentReceiptPath",
            "backupContainmentReceiptSha256",
            "contractId",
            "deploymentProfile",
            "databaseCommissionerSha256",
            "databaseCommissionerUnitSha256",
            "databaseRecoveryVerifierSha256",
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
    require_recovery_timestamp(
        value.get("recordedAtUtc"), "internal-test runtime contract time"
    )
    validate_internal_test_tls_contract(value)
    release_guard.require_string(
        value.get("nginxExpandedConfigSha256"),
        "internal-test expanded Nginx configuration digest",
        release_guard.SHA256_RE,
    )
    paths = {
        "activationEntrypointSha256": Path("/usr/local/sbin/uten-imp-activate"),
        "databaseCommissionerSha256": INTERNAL_TEST_DB_COMMISSIONER,
        "databaseCommissionerUnitSha256": INTERNAL_TEST_DB_COMMISSIONER_UNIT_FILE,
        "databaseRecoveryVerifierSha256": DATABASE_RECOVERY_VERIFIER,
        "environmentValidatorSha256": INTERNAL_TEST_APPLICATION_ENV_VALIDATOR,
        "entryWatchdogScriptSha256": ENTRY_WATCHDOG_SCRIPT_FILE,
        "entryWatchdogServiceUnitSha256": ENTRY_WATCHDOG_UNIT_FILE,
        "entryWatchdogTimerUnitSha256": Path(
            "/etc/systemd/system/uten-imp-entry-watchdog.timer"
        ),
        "migrationAuthorizationHelperSha256": MIGRATION_AUTHORIZATION_HELPER,
        "migrationServiceUnitSha256": MIGRATION_UNIT_FILE,
        "migratorEnvironmentValidatorSha256": MIGRATION_ENV_VALIDATOR,
        "nginxConfigSha256": INTERNAL_TEST_NGINX_CONFIG,
        "nginxReadinessGateSha256": NGINX_READINESS_GATE,
        "nginxSystemdDropinSha256": NGINX_DROPIN_FILE,
        "releaseGuardSha256": STABLE_RELEASE_GUARD,
        "releaseUpdaterSha256": Path("/opt/uten-imp/updater/release_updater.py"),
        "runtimeBootVerifierSha256": RUNTIME_BOOT_VERIFIER,
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
        "storageBootVerifierSha256": STORAGE_BOOT_VERIFIER,
        "storageValidatorSha256": INTERNAL_TEST_STORAGE_VALIDATOR,
        "updaterReleaseGuardSha256": Path("/opt/uten-imp/updater/release_guard.py"),
        "postgresInternalTestConfigSha256": Path(
            "/etc/postgresql/16/main/conf.d/99-uten-imp-internal-test.conf"
        ),
        "postgresHbaSha256": Path("/etc/postgresql/16/main/pg_hba.conf"),
        "postgresStorageDropinSha256": POSTGRES_STORAGE_DROPIN_FILE,
        "recoveryEntrypointSha256": Path("/usr/local/sbin/uten-imp-recover"),
        "stableAllowedSignersSha256": Path(
            "/etc/uten-imp-release-trust/release-allowed-signers"
        ),
        "storageAuthoritySha256": STORAGE_AUTHORITY,
        "storageMountObserverSha256": STORAGE_MOUNT_OBSERVER,
        "storageObserverUnitSha256": STORAGE_OBSERVER_UNIT_FILE,
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
    for key, path in paths.items():
        require_root_controlled_file(path, secret=path == APPLICATION_ENV_FILE)
        expected = release_guard.require_string(
            value.get(key), f"internal-test runtime contract {key}", release_guard.SHA256_RE
        )
        if release_guard.sha256_file(path) != expected:
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
        path = Path(
            release_guard.require_string(
                value.get(path_key), f"internal-test runtime contract {path_key}"
            )
        )
        if path.parent.parent != Path(
            "/var/lib/uten-imp-internal-test-host-preparation"
        ):
            fail("internal-test host preparation receipt escaped its evidence root")
        require_root_controlled_file(path, secret=True)
        if release_guard.sha256_file(path) != release_guard.require_string(
            value.get(sha_key),
            f"internal-test runtime contract {sha_key}",
            release_guard.SHA256_RE,
        ):
            fail("internal-test host preparation receipt changed")
    environment_bridge_path = Path(
        release_guard.require_string(
            value.get("serverEnvironmentBridgeReceiptPath"),
            "internal-test server environment bridge receipt path",
        )
    )
    environment_bridge = strict_json_object(
        read_root_evidence_bytes(environment_bridge_path),
        "internal-test server environment bridge receipt",
    )
    release_guard.exact_keys(
        environment_bridge,
        {
            "approvalReference",
            "kind",
            "newSha256",
            "oldSha256",
            "schemaVersion",
            "status",
            "transactionId",
        },
        "internal-test server environment bridge receipt",
    )
    if (
        environment_bridge.get("schemaVersion") != 1
        or environment_bridge.get("kind")
        != "uten-imp-internal-test-server-environment-bridge"
        or environment_bridge.get("status")
        != "COMMITTED_INTERNAL_TEST_ENV_ENTRY_CLOSED"
        or environment_bridge.get("transactionId")
        != environment_bridge_path.parent.name
        or environment_bridge.get("newSha256")
        != value.get("serverEnvironmentSha256")
    ):
        fail("internal-test server environment bridge receipt is incomplete")
    require_recovery_sha256(
        environment_bridge.get("oldSha256"),
        "internal-test server environment preimage digest",
    )
    legacy_handoff_path = Path(
        release_guard.require_string(
            value.get("legacyNginxHandoffReceiptPath"),
            "internal-test legacy Nginx handoff receipt path",
        )
    )
    legacy_handoff = strict_json_object(
        read_root_evidence_bytes(legacy_handoff_path),
        "internal-test legacy Nginx handoff receipt",
    )
    release_guard.exact_keys(
        legacy_handoff,
        {
            "archivePath",
            "archiveSha256",
            "kind",
            "legacyPath",
            "preimageSha256",
            "schemaVersion",
            "status",
            "transactionId",
        },
        "internal-test legacy Nginx handoff receipt",
    )
    if (
        legacy_handoff.get("schemaVersion") != 1
        or legacy_handoff.get("kind")
        != "uten-imp-internal-test-legacy-nginx-handoff"
        or legacy_handoff.get("status")
        != "COMMITTED_LEGACY_INCLUDE_DISABLED_ENTRY_CLOSED"
        or legacy_handoff.get("transactionId") != legacy_handoff_path.parent.name
        or legacy_handoff.get("legacyPath") != "/etc/nginx/conf.d/uten-imp.conf"
        or os.path.lexists(Path("/etc/nginx/conf.d/uten-imp.conf"))
        or legacy_handoff.get("archivePath") != value.get("legacyNginxArchivePath")
        or legacy_handoff.get("archiveSha256") != value.get("legacyNginxArchiveSha256")
    ):
        fail("internal-test legacy Nginx handoff receipt is incomplete")
    archive_path_value = value.get("legacyNginxArchivePath")
    archive_sha_value = value.get("legacyNginxArchiveSha256")
    if archive_path_value is None or archive_sha_value is None:
        if archive_path_value is not None or archive_sha_value is not None:
            fail("internal-test legacy Nginx archive binding is incomplete")
    else:
        archive_path = Path(
            release_guard.require_string(
                archive_path_value, "internal-test legacy Nginx archive path"
            )
        )
        if (
            archive_path.parent != Path("/etc/nginx/uten-imp-disabled")
            or archive_path.name != f"{legacy_handoff_path.parent.name}.conf"
        ):
            fail("internal-test legacy Nginx archive escaped its fixed path")
        require_root_controlled_file(archive_path)
        if release_guard.sha256_file(archive_path) != release_guard.require_string(
            archive_sha_value,
            "internal-test legacy Nginx archive digest",
            release_guard.SHA256_RE,
        ):
            fail("internal-test legacy Nginx archive changed")
    updater_substrate_path = Path(
        release_guard.require_string(
            value.get("updaterSubstrateReceiptPath"),
            "internal-test updater substrate receipt path",
        )
    )
    updater_substrate = strict_json_object(
        read_root_evidence_bytes(updater_substrate_path),
        "internal-test updater substrate receipt",
    )
    release_guard.exact_keys(
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
        "internal-test updater substrate receipt",
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
        fail("internal-test updater substrate receipt is incomplete")
    for key in (
        "installedInventorySha256",
        "ossEnvironmentSha256",
        "updaterVenvInventorySha256",
    ):
        release_guard.require_string(
            updater_substrate.get(key),
            f"internal-test updater substrate {key}",
            release_guard.SHA256_RE,
        )
    if updater_substrate.get("updaterVenvInventorySha256") != value.get(
        "updaterVenvInventorySha256"
    ):
        fail("internal-test updater virtualenv inventory differs")
    if updater_venv_inventory_sha256(
        release_guard.require_string(
            value.get("wheelhouseSupplyChainSha256"),
            "internal-test runtime contract wheelhouseSupplyChainSha256",
            release_guard.SHA256_RE,
        )
    ) != value.get("updaterVenvInventorySha256"):
        fail("live internal-test updater virtualenv inventory drifted")
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
        path = Path(
            release_guard.require_string(
                value.get(path_key), f"internal-test runtime contract {path_key}"
            )
        )
        if (
            path.parent.parent != Path("/var/lib/uten-imp-nvme-commissioning")
            or path.name != expected_name
        ):
            fail("internal-test storage terminal receipt escaped its fixed transaction")
        require_root_controlled_file(path, secret=True)
        expected_sha = release_guard.require_string(
            value.get(sha_key), f"internal-test runtime contract {sha_key}", release_guard.SHA256_RE
        )
        if release_guard.sha256_file(path) != expected_sha:
            fail("internal-test storage terminal receipt changed")
        storage_receipts[label] = strict_json_object(
            read_root_evidence_bytes(path), f"internal-test storage {label} receipt"
        )
    complete = storage_receipts["complete"]
    late = storage_receipts["late"]
    if (
        complete.get("status") != "COMMITTED_STORAGE_ONLY"
        or late.get("status") != "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED"
        or complete.get("transactionId") != late.get("transactionId")
        or complete.get("authoritySha256") != value.get("storageAuthoritySha256")
        or late.get("authoritySha256") != value.get("storageAuthoritySha256")
        or late.get("osUpdateInfrastructureRestored") is not True
        or os.path.lexists(Path("/var/lib/uten-imp-nvme-commissioning/active.json"))
    ):
        fail("internal-test storage terminal is incomplete or still armed")
    try:
        link = INTERNAL_TEST_NGINX_LINK.lstat()
        resolved_link = INTERNAL_TEST_NGINX_LINK.resolve(strict=True)
    except OSError as exc:
        raise UpdaterError("internal-test Nginx enabled link is unavailable") from exc
    if (
        not stat.S_ISLNK(link.st_mode)
        or link.st_uid != 0
        or link.st_gid != 0
        or resolved_link != INTERNAL_TEST_NGINX_CONFIG
    ):
        fail("internal-test Nginx site is not enabled through its canonical link")
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
        raise UpdaterError("expanded internal-test Nginx configuration could not be read") from exc
    if expanded.returncode != 0 or not expanded.stdout:
        fail("expanded internal-test Nginx configuration failed validation")
    if hashlib.sha256(expanded.stdout).hexdigest() != value["nginxExpandedConfigSha256"]:
        fail("effective Nginx configuration changed from the runtime contract")
    return value, hashlib.sha256(raw).hexdigest()


def assert_application_unit_contract() -> None:
    profile = deployment_profile()
    internal = profile == "internal-test"
    if internal:
        internal_test_runtime_contract()
    expected = {
        "LoadState": "loaded",
        "Type": "simple",
        "Restart": "always",
        "RestartSteps": "5",
        "RestartMaxDelayUSec": "1min",
        "TimeoutStartUSec": "2min",
        "StartLimitIntervalUSec": "10min",
        "StartLimitBurst": "8",
        "StartLimitAction": "none",
        "User": "uten-imp",
        "Group": "uten-imp",
        "FragmentPath": str(APPLICATION_UNIT_FILE),
        "EnvironmentFiles": f"{APPLICATION_ENV_FILE} (ignore_errors=no)",
        "ReadWritePaths": (
            "/data/uten-imp/attachments -/run/uten-imp-release"
            if internal
            else "/run/uten-imp-release"
        ),
    }
    for property_name, expected_value in expected.items():
        if systemd_property(APPLICATION_UNIT, property_name) != expected_value:
            fail(f"application unit has an unsafe {property_name} setting")
    if systemd_property(APPLICATION_UNIT, "DropInPaths") != "":
        fail("application unit drop-ins are not permitted")
    for property_name, required_units in (
        (
            "After",
            {
                "data.mount",
                "postgresql@16-main.service",
                "uten-imp-recovery-commit-verifier.service",
            },
        ),
        ("BindsTo", {"data.mount", "postgresql@16-main.service"}),
        ("PartOf", {"postgresql@16-main.service"}),
        (
            "Requires",
            {
                "postgresql@16-main.service",
                "uten-imp-recovery-commit-verifier.service",
            },
        ),
    ):
        actual_units = set((systemd_property(APPLICATION_UNIT, property_name) or "").split())
        if not required_units.issubset(actual_units):
            fail(f"application unit is missing a required {property_name} dependency")
    for property_name in (
        "ExecCondition",
        "ExecStartPost",
        "ExecReload",
        "ExecStop",
        "ExecStopPost",
    ):
        if systemd_property(APPLICATION_UNIT, property_name) != "":
            fail(f"application unit has an unexpected {property_name} command")
    expected_start = (
        INTERNAL_TEST_APPLICATION_EXECSTART_ARGV
        if internal
        else APPLICATION_EXECSTART_ARGV
    )
    expected_pre = (
        INTERNAL_TEST_APPLICATION_EXECSTART_PRE_COMMANDS
        if internal
        else APPLICATION_EXECSTART_PRE_COMMANDS
    )
    expected_fragment_start = (
        INTERNAL_TEST_APPLICATION_EXECSTART_FRAGMENT_LINE
        if internal
        else APPLICATION_EXECSTART_FRAGMENT_LINE
    )
    expected_fragment_pre = (
        INTERNAL_TEST_APPLICATION_EXECSTART_PRE_FRAGMENT_LINES
        if internal
        else APPLICATION_EXECSTART_PRE_FRAGMENT_LINES
    )
    validator = (
        INTERNAL_TEST_APPLICATION_ENV_VALIDATOR if internal else APPLICATION_ENV_VALIDATOR
    )
    validator_output = (
        INTERNAL_TEST_APPLICATION_ENV_VALIDATION_OUTPUT
        if internal
        else APPLICATION_ENV_VALIDATION_OUTPUT
    )
    if systemd_exec_commands(
        systemd_property(APPLICATION_UNIT, "ExecStart") or "",
        "application ExecStart",
    ) != [("/usr/bin/java", expected_start)]:
        fail("application unit ExecStart differs from the reviewed command")
    if systemd_exec_commands(
        systemd_property(APPLICATION_UNIT, "ExecStartPre") or "",
        "application ExecStartPre",
    ) != list(expected_pre):
        fail("application unit ExecStartPre differs from the reviewed command sequence")
    assert_fragment_commands(
        APPLICATION_UNIT_FILE,
        label="application",
        expected_exec_start=expected_fragment_start,
        expected_exec_start_pre=expected_fragment_pre,
    )
    run_root_environment_validator(
        validator,
        APPLICATION_ENV_FILE,
        label="application",
        expected_output=validator_output,
    )


def assert_migration_unit_contract() -> None:
    expected = {
        "LoadState": "loaded",
        "Type": "oneshot",
        "RemainAfterExit": "no",
        "Restart": "no",
        "User": "uten-imp-migrate",
        "Group": "uten-imp-migrate",
        "FragmentPath": str(MIGRATION_UNIT_FILE),
        "EnvironmentFiles": f"{MIGRATION_ENV_FILE} (ignore_errors=no)",
        "ReadWritePaths": str(MIGRATION_AUTHORIZATION_DIR),
    }
    for property_name, expected_value in expected.items():
        if systemd_property(MIGRATION_UNIT, property_name) != expected_value:
            fail(f"migration unit has an unsafe {property_name} setting")
    if systemd_property(MIGRATION_UNIT, "DropInPaths") != "":
        fail("migration unit drop-ins are not permitted")
    after = set((systemd_property(MIGRATION_UNIT, "After") or "").split())
    required_ordering = {"network-online.target", "data.mount", POSTGRES_UNIT}
    if not required_ordering.issubset(after):
        fail("migration unit lacks the reviewed ordering-only dependencies")
    wants = set((systemd_property(MIGRATION_UNIT, "Wants") or "").split())
    if wants != {"network-online.target"}:
        fail("migration unit Wants must contain only network-online.target")
    forbidden_pull_units = {"data.mount", POSTGRES_UNIT}
    for property_name in ("Requires", "Requisite", "BindsTo", "PartOf", "Upholds"):
        dependencies = set(
            (systemd_property(MIGRATION_UNIT, property_name) or "").split()
        )
        if dependencies & forbidden_pull_units:
            fail(
                f"migration unit {property_name} may not pull PostgreSQL or /data online"
            )
    if (systemd_property(MIGRATION_UNIT, "RequiresMountsFor") or "").split():
        fail("migration unit RequiresMountsFor may not pull /data online")
    for property_name in (
        "ExecCondition",
        "ExecStartPost",
        "ExecReload",
        "ExecStop",
        "ExecStopPost",
    ):
        if systemd_property(MIGRATION_UNIT, property_name) != "":
            fail(f"migration unit has an unexpected {property_name} command")
    exec_start = systemd_property(MIGRATION_UNIT, "ExecStart") or ""
    if systemd_exec_commands(exec_start, "ExecStart") != [
        ("/usr/bin/java", MIGRATION_EXECSTART_ARGV)
    ]:
        fail("migration unit ExecStart differs from the reviewed command")
    exec_start_pre = systemd_property(MIGRATION_UNIT, "ExecStartPre") or ""
    if systemd_exec_commands(exec_start_pre, "ExecStartPre") != list(
        MIGRATION_EXECSTART_PRE_COMMANDS
    ):
        fail("migration unit ExecStartPre differs from the reviewed command sequence")

    assert_fragment_commands(
        MIGRATION_UNIT_FILE,
        label="migration",
        expected_exec_start=MIGRATION_EXECSTART_FRAGMENT_LINE,
        expected_exec_start_pre=MIGRATION_EXECSTART_PRE_FRAGMENT_LINES,
    )
    require_root_controlled_file(MIGRATION_ENV_VALIDATOR)
    require_migration_authorization_helper()


def validate_migration_environment() -> None:
    run_root_environment_validator(
        MIGRATION_ENV_VALIDATOR,
        MIGRATION_ENV_FILE,
        label="dedicated migrator",
        expected_output=MIGRATION_ENV_VALIDATION_OUTPUT,
    )


def assert_nginx_unit_contract() -> None:
    expected = {
        "LoadState": "loaded",
        "Type": "forking",
        "Restart": "no",
        "RestartSteps": "5",
        "RestartMaxDelayUSec": "30s",
        "StartLimitIntervalUSec": "10min",
        "StartLimitBurst": "8",
        "StartLimitAction": "none",
        "FragmentPath": str(NGINX_FRAGMENT_FILE),
        "DropInPaths": str(NGINX_DROPIN_FILE),
    }
    for property_name, expected_value in expected.items():
        if systemd_property(NGINX_UNIT, property_name) != expected_value:
            fail(f"nginx unit has an unsafe {property_name} setting")
    for property_name in ("After", "BindsTo", "PartOf"):
        if "uten-imp.service" not in (
            systemd_property(NGINX_UNIT, property_name) or ""
        ).split():
            fail(f"nginx unit is missing its application {property_name} dependency")
    for property_name in ("After", "Requires"):
        if "uten-imp-recovery-commit-verifier.service" not in (
            systemd_property(NGINX_UNIT, property_name) or ""
        ).split():
            fail(f"nginx unit is missing its recovery {property_name} dependency")
    for property_name in ("ExecCondition", "ExecStopPost"):
        if systemd_property(NGINX_UNIT, property_name) != "":
            fail(f"nginx unit has an unexpected {property_name} command")
    if systemd_exec_commands(
        systemd_property(NGINX_UNIT, "ExecStart") or "", "nginx ExecStart"
    ) != [("/usr/sbin/nginx", NGINX_EXECSTART_ARGV)]:
        fail("nginx unit ExecStart differs from the reviewed command")
    if systemd_exec_commands(
        systemd_property(NGINX_UNIT, "ExecStartPre") or "", "nginx ExecStartPre"
    ) != list(NGINX_EXECSTART_PRE_COMMANDS):
        fail("nginx unit ExecStartPre differs from the reviewed command sequence")
    if systemd_exec_commands(
        systemd_property(NGINX_UNIT, "ExecStartPost") or "", "nginx ExecStartPost"
    ) != list(NGINX_EXECSTART_POST_COMMANDS):
        fail("nginx unit ExecStartPost differs from the recovery finalization command")
    if systemd_exec_commands(
        systemd_property(NGINX_UNIT, "ExecReload") or "", "nginx ExecReload"
    ) != [("/usr/sbin/nginx", NGINX_EXECRELOAD_ARGV)]:
        fail("nginx unit ExecReload differs from the reviewed command")
    if systemd_exec_commands(
        systemd_property(NGINX_UNIT, "ExecStop") or "",
        "nginx ExecStop",
        expected_ignore_errors="yes",
    ) != [("/sbin/start-stop-daemon", NGINX_EXECSTOP_ARGV)]:
        fail("nginx unit ExecStop differs from the reviewed command")
    require_root_controlled_file(NGINX_FRAGMENT_FILE)
    require_root_controlled_file(NGINX_DROPIN_FILE)
    require_root_controlled_file(NGINX_READINESS_GATE)
    try:
        dropin_lines = tuple(NGINX_DROPIN_FILE.read_text(encoding="utf-8").splitlines())
    except (OSError, UnicodeDecodeError) as exc:
        raise UpdaterError("cannot read the nginx systemd drop-in safely") from exc
    if dropin_lines != NGINX_DROPIN_LINES:
        fail("nginx systemd drop-in differs from the reviewed restart/marker contract")


def fsync_boot_enablement() -> None:
    systemd_root = Path("/etc/systemd/system")
    require_real_directory(systemd_root, owner_uid=0)
    for directory in SYSTEMD_ENABLEMENT_DIRECTORIES:
        if directory.exists() or directory.is_symlink():
            require_real_directory(directory, owner_uid=0)
            fsync_directory(directory)
    fsync_directory(systemd_root)


def disable_boot_units_durable() -> None:
    for unit in BOOT_UNITS:
        run(["systemctl", "disable", unit])
    for unit in BOOT_UNITS:
        if unit_enabled(unit):
            fail(f"boot unit remained enabled during activation transaction: {unit}")
    fsync_boot_enablement()


def restore_boot_enablement(boot_enabled: dict[str, bool]) -> None:
    if set(boot_enabled) != set(BOOT_UNITS) or not all(
        isinstance(value, bool) for value in boot_enabled.values()
    ):
        fail("boot enablement restoration evidence is incomplete")
    for unit in BOOT_UNITS:
        if boot_enabled[unit]:
            enable_unit(unit)
        else:
            run(["systemctl", "disable", unit])
            if unit_enabled(unit):
                fail(f"boot unit remained enabled unexpectedly: {unit}")
    fsync_boot_enablement()


def commit_boot_enablement(
    boot_enabled: dict[str, bool], release_info: dict[str, Any]
) -> None:
    if set(boot_enabled) != set(BOOT_UNITS) or not all(
        isinstance(value, bool) for value in boot_enabled.values()
    ):
        fail("boot enablement commit evidence is incomplete")
    version = release_guard.require_string(
        release_info.get("version"), "boot enablement version"
    )
    commit_sha = release_guard.require_string(
        release_info.get("commitSha"),
        "boot enablement commit",
        release_guard.COMMIT_RE,
    )
    sequence = release_info.get("releaseSequence")
    if (
        not isinstance(sequence, int)
        or isinstance(sequence, bool)
        or release_guard.version_sequence(version) != sequence
    ):
        fail("boot enablement release sequence is inconsistent")
    atomic_json(
        BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
        {
            "commitSha": commit_sha,
            "desiredBootEnablement": {
                unit: boot_enabled[unit] for unit in BOOT_UNITS
            },
            "releaseSequence": sequence,
            "schemaVersion": 1,
            "startedAtUtc": utc_now(),
            "version": version,
        },
        mode=0o600,
    )
    require_root_controlled_file(
        BOOT_ENABLEMENT_IN_PROGRESS_MARKER, secret=True
    )
    require_root_controlled_file(ACTIVATION_IN_PROGRESS_MARKER, secret=True)
    durable_unlink(ACTIVATION_IN_PROGRESS_MARKER)
    restore_boot_enablement(boot_enabled)
    require_root_controlled_file(
        BOOT_ENABLEMENT_IN_PROGRESS_MARKER, secret=True
    )
    durable_unlink(BOOT_ENABLEMENT_IN_PROGRESS_MARKER)


def begin_activation_transaction(
    *,
    old_info: dict[str, Any] | None,
    new_info: dict[str, Any],
    boot_enabled_before: dict[str, bool],
) -> None:
    preparation_gate = {
        "failedAtUtc": utc_now(),
        "failedCommitSha": new_info["commitSha"],
        "failedVersion": new_info["version"],
        "originalBootEnablement": {
            unit: boot_enabled_before[unit] for unit in BOOT_UNITS
        },
        "previousVersion": old_info["version"] if old_info is not None else None,
        "reason": "activation-preparing",
        "recoveryRequired": True,
        "schemaVersion": 1,
    }
    atomic_json(ACTIVATION_FAILURE_MARKER, preparation_gate, mode=0o600)
    require_root_controlled_file(ACTIVATION_FAILURE_MARKER, secret=True)
    disable_boot_units_durable()
    atomic_json(
        ACTIVATION_IN_PROGRESS_MARKER,
        {
            "commitSha": new_info["commitSha"],
            "originalBootEnablement": {
                unit: boot_enabled_before[unit] for unit in BOOT_UNITS
            },
            "previousVersion": old_info["version"] if old_info is not None else None,
            "releaseSequence": new_info["releaseSequence"],
            "startedAtUtc": utc_now(),
            "version": new_info["version"],
            "schemaVersion": 1,
        },
        mode=0o600,
    )
    require_root_controlled_file(ACTIVATION_IN_PROGRESS_MARKER, secret=True)
    durable_unlink(ACTIVATION_FAILURE_MARKER)


def persist_fail_closed_activation(
    *,
    old_info: dict[str, Any] | None,
    new_info: dict[str, Any],
    boot_enabled_before: dict[str, bool],
    reason: str,
    current_link_restored: bool,
    legacy_current_evidence: dict[str, str] | None = None,
) -> None:
    """Persist a reboot gate, then stop/disable and verify every boot-capable unit."""
    if reason not in {
        "first-release-failed",
        "activation-preparation-failed",
        "activation-commit-failed",
        "legacy-retirement-preparation-failed",
        "current-restore-failed",
        "database-incompatible",
        "migration-process-failed",
        "previous-release-recovery-failed",
    }:
        fail("activation failure reason is not canonical")
    if set(boot_enabled_before) != set(BOOT_UNITS) or not all(
        isinstance(value, bool) for value in boot_enabled_before.values()
    ):
        fail("original boot enablement evidence is incomplete")
    marker = {
        "currentLinkRestored": current_link_restored,
        "failedAtUtc": utc_now(),
        "failedCommitSha": new_info["commitSha"],
        "failedFlywayHeadVersion": new_info["flywayHeadVersion"],
        "failedFlywayMigrationSetSha256": new_info[
            "flywayMigrationSetSha256"
        ],
        "failedVersion": new_info["version"],
        "originalBootEnablement": {
            unit: boot_enabled_before[unit] for unit in BOOT_UNITS
        },
        "previousFlywayHeadVersion": (
            old_info["flywayHeadVersion"] if old_info is not None else None
        ),
        "previousFlywayMigrationSetSha256": (
            old_info["flywayMigrationSetSha256"] if old_info is not None else None
        ),
        "previousVersion": old_info["version"] if old_info is not None else None,
        "reason": reason,
        "recoveryRequired": True,
        "schemaVersion": 1,
    }
    if legacy_current_evidence is not None:
        if set(legacy_current_evidence) != {
            "legacyCurrentLinkTarget",
            "legacyResolvedPath",
        } or not all(
            isinstance(value, str) and value
            for value in legacy_current_evidence.values()
        ):
            fail("legacy current failure evidence is incomplete")
        marker["legacyCurrent"] = dict(legacy_current_evidence)
    problems: list[str] = []
    try:
        atomic_json(ACTIVATION_FAILURE_MARKER, marker, mode=0o600)
        require_root_controlled_file(ACTIVATION_FAILURE_MARKER, secret=True)
        if os.path.lexists(ACTIVATION_IN_PROGRESS_MARKER):
            require_root_controlled_file(ACTIVATION_IN_PROGRESS_MARKER, secret=True)
            durable_unlink(ACTIVATION_IN_PROGRESS_MARKER)
    except Exception as exc:
        problems.append(f"failure marker: {exc}")

    controlled_runtime_units = (
        *WATCHDOG_TIMERS,
        *WATCHDOG_SERVICES,
        MIGRATION_UNIT,
        "nginx.service",
        "uten-imp.service",
    )
    for unit in controlled_runtime_units:
        try:
            stop_unit(unit)
        except Exception as exc:
            problems.append(f"stop {unit}: {exc}")
    for unit in BOOT_UNITS:
        try:
            if unit_exists(unit):
                run(["systemctl", "disable", unit])
            if unit_enabled(unit):
                problems.append(f"disable {unit}: unit remains enabled")
        except Exception as exc:
            problems.append(f"disable {unit}: {exc}")
    for unit in controlled_runtime_units:
        try:
            if unit_active(unit):
                problems.append(f"inactive check {unit}: unit remains active")
        except Exception as exc:
            problems.append(f"inactive check {unit}: {exc}")
    if problems:
        for problem in problems:
            log(f"persistent activation containment problem: {problem}", "err")
        fail("persistent fail-closed activation containment could not be fully verified")
    log(
        "persistent activation failure gate written; backend, nginx, and watchdog "
        "boot units are inactive and disabled",
        "err",
    )


def assert_watchdog_service_gate_contract(unit: str) -> None:
    if unit not in WATCHDOG_SERVICES:
        fail(f"unexpected watchdog unit contract request: {unit}")
    if not unit_exists(unit):
        fail(f"required watchdog unit is not installed: {unit}")
    user = systemd_property(unit, "User") or "root"
    command = systemd_property(unit, "ExecStart") or ""
    if user == "root" and "/opt/uten-imp/current/" in command:
        fail(
            f"{unit} still executes a script from the application artifact as root; "
            "install a root-controlled watchdog path before activation"
        )
    pre_commands = systemd_exec_commands(
        systemd_property(unit, "ExecStartPre") or "",
        f"{unit} ExecStartPre",
    )
    for required_gate in WATCHDOG_REQUIRED_GATE_COMMANDS:
        if required_gate not in pre_commands:
            fail(f"{unit} is missing a required reboot-safety gate")
    if unit != ENTRY_WATCHDOG_UNIT:
        return

    unit_raw = read_root_controlled_bytes(
        ENTRY_WATCHDOG_UNIT_FILE,
        exact_mode=0o644,
        maximum_bytes=64 * 1024,
    )
    if hashlib.sha256(unit_raw).hexdigest() != ENTRY_WATCHDOG_UNIT_SHA256:
        fail("entry watchdog unit differs from the reviewed fixed dependency contract")
    script_raw = read_root_controlled_bytes(
        ENTRY_WATCHDOG_SCRIPT_FILE,
        exact_mode=0o755,
        maximum_bytes=256 * 1024,
    )
    if hashlib.sha256(script_raw).hexdigest() != ENTRY_WATCHDOG_SCRIPT_SHA256:
        fail("entry watchdog script differs from the reviewed fail-closed contract")
    if systemd_property(unit, "LoadState") != "loaded":
        fail("entry watchdog unit is not loaded")
    if systemd_property(unit, "FragmentPath") != str(ENTRY_WATCHDOG_UNIT_FILE):
        fail("entry watchdog unit is not loaded from the fixed system path")
    if (systemd_property(unit, "DropInPaths") or "").split():
        fail("entry watchdog unit has unreviewed systemd drop-ins")
    after = set((systemd_property(unit, "After") or "").split())
    if not {"network-online.target", "nginx.service"}.issubset(after):
        fail("entry watchdog loaded ordering lacks network-online or Nginx")
    wants = set((systemd_property(unit, "Wants") or "").split())
    if wants != {"network-online.target"}:
        fail("entry watchdog loaded Wants must contain only network-online.target")
    for property_name in ("Requires", "BindsTo", "Upholds"):
        dependencies = set((systemd_property(unit, property_name) or "").split())
        if "nginx.service" in dependencies:
            fail(
                "entry watchdog must not pull Nginx active through "
                f"{property_name}="
            )


def read_postgres_start_conf() -> bytes:
    """Read start.conf through one stable fd without trusting its postgres parent."""
    if not hasattr(os, "O_NOFOLLOW"):
        fail("this platform cannot enforce no-follow PostgreSQL boot-policy reads")
    for directory in (
        POSTGRES_START_CONF.parent,
        POSTGRES_START_CONF.parent.parent,
        POSTGRES_START_CONF.parent.parent.parent,
    ):
        details = directory.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or directory.is_symlink()
            or details.st_mode & 0o022
        ):
            fail("PostgreSQL configuration parent is symlinked or writable")
    before = POSTGRES_START_CONF.lstat()
    descriptor = os.open(
        POSTGRES_START_CONF,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
    )
    try:
        opened = os.fstat(descriptor)
        after = POSTGRES_START_CONF.lstat()
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != 0
            or opened.st_gid != 0
            or stat.S_IMODE(opened.st_mode) != 0o644
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino)
            or opened.st_size > 16
        ):
            fail(
                "PostgreSQL start.conf must be one stable root:root 0644 regular file"
            )
        value = os.read(descriptor, 17)
        if len(value) != opened.st_size:
            fail("PostgreSQL start.conf changed while it was read")
        return value
    finally:
        os.close(descriptor)


def assert_database_boot_contract() -> None:
    """Prove the database layer remains independently bootable and online."""
    if read_postgres_start_conf() != b"auto\n":
        fail("PostgreSQL start.conf must contain exactly auto")
    for unit in DATABASE_BOOT_UNITS:
        if systemd_property(unit, "LoadState") != "loaded":
            fail(f"database boot unit is not loaded: {unit}")
        if systemd_property(unit, "UnitFileState") != "enabled":
            fail(f"database boot unit is not persistently enabled: {unit}")
        if systemd_property(unit, "ActiveState") != "active":
            fail(f"database boot unit is not active: {unit}")

    wants = set((systemd_property(POSTGRES_META_UNIT, "Wants") or "").split())
    if POSTGRES_UNIT not in wants:
        fail("postgresql.service does not want the 16/main instance from the generator")

    for directory in (
        POSTGRES_GENERATOR_WANTS_DIR.parent,
        POSTGRES_GENERATOR_WANTS_DIR,
    ):
        require_real_directory(directory, owner_uid=0)
    try:
        link_details = POSTGRES_GENERATOR_LINK.lstat()
    except FileNotFoundError as exc:
        raise UpdaterError(
            "postgresql-generator did not publish the 16/main meta-service dependency"
        ) from exc
    if not stat.S_ISLNK(link_details.st_mode) or link_details.st_uid != 0:
        fail("PostgreSQL generator dependency is not one root-owned symlink")
    fragment_value = systemd_property(POSTGRES_UNIT, "FragmentPath")
    if not fragment_value:
        fail("PostgreSQL instance has no loaded fragment path")
    fragment = Path(fragment_value)
    require_root_controlled_file(fragment)
    try:
        if POSTGRES_GENERATOR_LINK.resolve(strict=True) != fragment.resolve(strict=True):
            fail("PostgreSQL generator dependency targets an unexpected unit fragment")
    except RuntimeError as exc:
        raise UpdaterError("PostgreSQL generator dependency contains a symlink loop") from exc


def assert_postgres_storage_unit_contract() -> None:
    if systemd_property(POSTGRES_UNIT, "LoadState") != "loaded":
        fail("PostgreSQL 16 main unit is not loaded")
    if systemd_property(POSTGRES_UNIT, "User") != "postgres":
        fail("PostgreSQL 16 main unit does not use the postgres service account")
    dropins = (systemd_property(POSTGRES_UNIT, "DropInPaths") or "").split()
    if dropins != [str(POSTGRES_STORAGE_DROPIN_FILE)]:
        fail("PostgreSQL has an unreviewed or missing storage drop-in")
    for property_name in ("After", "BindsTo"):
        units = set((systemd_property(POSTGRES_UNIT, property_name) or "").split())
        if "data.mount" not in units:
            fail(f"PostgreSQL storage drop-in is missing {property_name}=data.mount")
    pre_commands = systemd_exec_commands(
        systemd_property(POSTGRES_UNIT, "ExecStartPre") or "",
        "PostgreSQL ExecStartPre",
    )
    required = (
        "/usr/bin/python3",
        "/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/storage_boot_verifier.py",
    )
    if required not in pre_commands:
        fail("PostgreSQL loaded unit lacks the fixed storage boot verifier")
    require_root_controlled_file(POSTGRES_STORAGE_DROPIN_FILE)
    if POSTGRES_STORAGE_DROPIN_FILE.read_text(encoding="utf-8").splitlines() != list(
        POSTGRES_STORAGE_DROPIN_LINES
    ):
        fail("PostgreSQL storage drop-in differs from the reviewed fixed contract")
    require_root_controlled_file(STORAGE_BOOT_VERIFIER)
    verifier = STORAGE_BOOT_VERIFIER.lstat()
    if (
        verifier.st_gid != 0
        or verifier.st_nlink != 1
        or stat.S_IMODE(verifier.st_mode) != 0o644
        or release_guard.sha256_file(STORAGE_BOOT_VERIFIER)
        != STORAGE_BOOT_VERIFIER_SHA256
    ):
        fail("PostgreSQL storage boot verifier differs from the reviewed root-owned bytes")


def assert_storage_observer_contract() -> None:
    if not unit_exists(STORAGE_OBSERVER_UNIT):
        fail("required storage observer unit is not installed")
    require_root_controlled_file(STORAGE_MOUNT_OBSERVER)
    helper = STORAGE_MOUNT_OBSERVER.lstat()
    if (
        helper.st_gid != 0
        or helper.st_nlink != 1
        or stat.S_IMODE(helper.st_mode) != 0o644
        or release_guard.sha256_file(STORAGE_MOUNT_OBSERVER)
        != STORAGE_MOUNT_OBSERVER_SHA256
    ):
        fail("storage mount observer differs from the reviewed root-owned bytes")

    require_root_controlled_file(STORAGE_AUTHORITY)
    authority_details = STORAGE_AUTHORITY.lstat()
    if (
        authority_details.st_gid != 0
        or authority_details.st_nlink != 1
        or stat.S_IMODE(authority_details.st_mode) != 0o640
    ):
        fail("storage authority metadata differs from the observer contract")
    try:
        module = _stable_pinned_python_module(
            STORAGE_MOUNT_OBSERVER,
            expected_sha256=STORAGE_MOUNT_OBSERVER_SHA256,
            module_name="uten_imp_storage_mount_observer_contract",
            # Keep source-checkout contract tests usable while enforcing ownership
            # at the only fixed production installation directory.
            require_root_control=(
                STORAGE_MOUNT_OBSERVER.parent
                == Path("/usr/local/libexec/uten-imp-release")
            ),
            exact_mode=0o644,
        )
    except RuntimeError as exc:
        raise UpdaterError(
            "cannot load the pinned reviewed storage observer contract"
        ) from exc
    if not callable(getattr(module, "_authority", None)) or not callable(
        getattr(module, "render_observer_unit", None)
    ):
        fail("reviewed storage observer API contract is incomplete")
    authority_raw = read_root_controlled_bytes(STORAGE_AUTHORITY, exact_mode=0o640)
    authority = module._authority(authority_raw)
    source = authority["dataSource"]
    if authority["schemaVersion"] == 2:
        resolved_source = os.path.realpath(source)
        if not re.fullmatch(r"/dev/md\d+", resolved_source):
            fail("legacy storage observer authority does not resolve to /dev/mdN")
        try:
            source_details = os.stat(resolved_source)
        except OSError as exc:
            raise UpdaterError("storage observer DeviceAllow node is unavailable") from exc
        if not stat.S_ISBLK(source_details.st_mode):
            fail("storage observer DeviceAllow target is not a block device")
        expected_unit = module.render_observer_unit(resolved_source)
        expected_device_lines = 1
    else:
        expected_unit = module.render_observer_unit(None)
        expected_device_lines = 0

    require_root_controlled_file(STORAGE_OBSERVER_UNIT_FILE)
    unit_details = STORAGE_OBSERVER_UNIT_FILE.lstat()
    if (
        unit_details.st_gid != 0
        or unit_details.st_nlink != 1
        or stat.S_IMODE(unit_details.st_mode) != 0o644
        or STORAGE_OBSERVER_UNIT_FILE.read_text(encoding="utf-8") != expected_unit
        or expected_unit.count("DeviceAllow=") != expected_device_lines
    ):
        fail("storage observer unit differs from its authority-generation contract")
    properties = {
        name: systemd_property(STORAGE_OBSERVER_UNIT, name) or ""
        for name in (
            "LoadState",
            "FragmentPath",
            "DropInPaths",
            "User",
            "DevicePolicy",
            "PrivateDevices",
            "PrivateNetwork",
            "ExecStart",
        )
    }
    if (
        properties["LoadState"] != "loaded"
        or properties["FragmentPath"] != str(STORAGE_OBSERVER_UNIT_FILE)
        or properties["DropInPaths"]
        or properties["User"] not in {"", "root"}
        or properties["DevicePolicy"] != "closed"
        or properties["PrivateDevices"] != "no"
        or properties["PrivateNetwork"] != "yes"
        or str(STORAGE_MOUNT_OBSERVER) not in properties["ExecStart"]
        or " observe" not in properties["ExecStart"]
        or unit_enabled(STORAGE_OBSERVER_UNIT)
    ):
        fail("loaded storage observer escaped its fixed on-demand sandbox contract")


def assert_common_updater_unit_contract() -> None:
    service = "uten-imp-updater.service"
    timer = "uten-imp-updater.timer"
    service_file = Path("/etc/systemd/system/uten-imp-updater.service")
    timer_file = Path("/etc/systemd/system/uten-imp-updater.timer")
    expected = {
        (service, "LoadState"): "loaded",
        (service, "FragmentPath"): str(service_file),
        (service, "DropInPaths"): "",
        (service, "Type"): "oneshot",
        (service, "User"): UPDATER_USER,
        (service, "Group"): UPDATER_USER,
        (service, "SupplementaryGroups"): "",
        (service, "EnvironmentFiles"): "/etc/uten-imp-updater/oss-pull.env (ignore_errors=no)",
        (service, "NoNewPrivileges"): "yes",
        (service, "ProtectSystem"): "strict",
        (service, "PrivateDevices"): "yes",
        (service, "PrivateNetwork"): "no",
        (service, "ReadWritePaths"): "/var/lib/uten-imp-updater /run/uten-imp-updater /var/lib/uten-imp-release/operation.lock",
        (service, "UnitFileState"): "static",
        (timer, "LoadState"): "loaded",
        (timer, "FragmentPath"): str(timer_file),
        (timer, "DropInPaths"): "",
        (timer, "UnitFileState"): "disabled",
        (timer, "ActiveState"): "inactive",
    }
    for (unit, property_name), expected_value in expected.items():
        if (systemd_property(unit, property_name) or "") != expected_value:
            fail(f"common updater unit has an unsafe {property_name}: {unit}")
    unset_environment = set(
        (systemd_property(service, "UnsetEnvironment") or "").split()
    )
    required_unset = {
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "LD_AUDIT",
        "LD_DEBUG",
        "GCONV_PATH",
        "BASH_ENV",
        "ENV",
        "SHELLOPTS",
        "BASHOPTS",
        "PS4",
        "BASH_XTRACEFD",
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONSTARTUP",
        "PYTHONINSPECT",
        "JAVA_TOOL_OPTIONS",
        "JDK_JAVA_OPTIONS",
        "_JAVA_OPTIONS",
    }
    if unset_environment != required_unset:
        fail("common updater unit does not clear the exact control environment")
    if systemd_exec_commands(
        systemd_property(service, "ExecStart") or "", "updater ExecStart"
    ) != [
        (
            "/opt/uten-imp/updater/uten-imp-updater.sh",
            "/opt/uten-imp/updater/uten-imp-updater.sh",
        )
    ]:
        fail("common updater ExecStart differs")
    expected_pre = [
        (
            "/usr/bin/python3",
            "/usr/bin/python3 -I /opt/uten-imp/updater/validate_oss_pull_env.py /etc/uten-imp-updater/oss-pull.env",
        ),
        (
            "/usr/bin/python3",
            "/usr/bin/python3 -I /opt/uten-imp/updater/wheelhouse_supply_chain.py verify-installed --lock /opt/uten-imp/updater/requirements.lock --venv /opt/uten-imp/updater/venv",
        ),
    ]
    if systemd_exec_commands(
        systemd_property(service, "ExecStartPre") or "", "updater ExecStartPre"
    ) != expected_pre:
        fail("common updater ExecStartPre differs")
    for path in (service_file, timer_file):
        require_root_controlled_file(path)


def assert_pre_database_runtime_contract() -> None:
    """Prove every effective internal runtime dependency before initdb writes.

    This deliberately omits only the database *active/enabled* assertions: the
    commissioner has not initialized that cluster yet.  Loaded fragments,
    drop-ins, commands, dependency edges and root-pinned helper bytes are all
    checked here so a stale systemd view cannot be discovered only after an
    irreversible database migration.
    """

    if deployment_profile() != "internal-test":
        fail("pre-database runtime contract is internal-test only")
    internal_test_runtime_contract()
    assert_common_updater_unit_contract()
    recovery_boot_unit = "uten-imp-recovery-commit-verifier.service"
    if (
        systemd_property(recovery_boot_unit, "LoadState") != "loaded"
        or systemd_property(recovery_boot_unit, "FragmentPath")
        != "/etc/systemd/system/uten-imp-recovery-commit-verifier.service"
        or (systemd_property(recovery_boot_unit, "DropInPaths") or "").split()
        or systemd_property(recovery_boot_unit, "UnitFileState") != "enabled"
    ):
        fail("recovery commit boot verifier effective unit differs")
    commissioner_unit = "uten-imp-internal-db-commissioner.service"
    commissioner_file = Path(
        "/etc/systemd/system/uten-imp-internal-db-commissioner.service"
    )
    commissioner_expected = {
        "LoadState": "loaded",
        "FragmentPath": str(commissioner_file),
        "DropInPaths": "",
        "Type": "oneshot",
        "User": "root",
        "Group": "root",
        "KillMode": "control-group",
        "UnitFileState": "static",
    }
    for property_name, expected_value in commissioner_expected.items():
        if (systemd_property(commissioner_unit, property_name) or "") != expected_value:
            fail(f"database commissioner unit has an unsafe {property_name}")
    if systemd_exec_commands(
        systemd_property(commissioner_unit, "ExecStart") or "",
        "database commissioner ExecStart",
    ) != [
        (
            "/usr/bin/python3",
            "/usr/bin/python3 -I /usr/local/sbin/uten-imp-existing-test-host-db-commissioner worker",
        )
    ]:
        fail("database commissioner ExecStart differs")
    require_root_controlled_file(commissioner_file)
    assert_application_unit_contract()
    assert_migration_unit_contract()
    validate_migration_environment()
    assert_nginx_unit_contract()
    assert_postgres_storage_unit_contract()
    assert_storage_observer_contract()
    for unit in WATCHDOG_SERVICES:
        assert_watchdog_service_gate_contract(unit)

    expected_fragments = {
        "uten-imp-watchdog.service": Path(
            "/etc/systemd/system/uten-imp-watchdog.service"
        ),
        ENTRY_WATCHDOG_UNIT: ENTRY_WATCHDOG_UNIT_FILE,
        "uten-imp-watchdog.timer": Path(
            "/etc/systemd/system/uten-imp-watchdog.timer"
        ),
        "uten-imp-entry-watchdog.timer": Path(
            "/etc/systemd/system/uten-imp-entry-watchdog.timer"
        ),
    }
    for unit, fragment in expected_fragments.items():
        if (
            systemd_property(unit, "LoadState") != "loaded"
            or systemd_property(unit, "FragmentPath") != str(fragment)
            or (systemd_property(unit, "DropInPaths") or "").split()
        ):
            fail(f"pre-database runtime unit has an unreviewed effective view: {unit}")
        require_root_controlled_file(fragment)
    for timer in WATCHDOG_TIMERS:
        if systemd_property(timer, "UnitFileState") != "disabled":
            fail(f"pre-database watchdog timer is not disabled: {timer}")


def assert_privilege_separation(state_dir: Path) -> None:
    assert_common_updater_unit_contract()
    updater_user = systemd_property("uten-imp-updater.service", "User")
    if updater_user != UPDATER_USER:
        fail(
            "uten-imp-updater.service must run as the dedicated uten-imp-updater user "
            "before activation is permitted"
        )
    updater_group = systemd_property("uten-imp-updater.service", "Group")
    if updater_group != UPDATER_USER:
        fail("uten-imp-updater.service must use its dedicated same-name group")
    supplementary_groups = (
        systemd_property("uten-imp-updater.service", "SupplementaryGroups") or ""
    ).split()
    if "uten-imp" in supplementary_groups:
        fail("uten-imp-updater.service must not receive the uten-imp supplementary group")
    try:
        account = pwd.getpwnam(UPDATER_USER)
    except KeyError as exc:
        raise UpdaterError(f"dedicated account does not exist: {UPDATER_USER}") from exc
    if account.pw_shell not in ("/usr/sbin/nologin", "/sbin/nologin", "/bin/false"):
        fail(f"{UPDATER_USER} must have a nologin shell")
    if state_dir.lstat().st_uid != account.pw_uid:
        fail("updater state directory must be owned by the dedicated updater account")
    try:
        application_group = importlib.import_module("grp").getgrnam("uten-imp")
    except (ImportError, KeyError):
        application_group = None
    if application_group is not None and (
        account.pw_gid == application_group.gr_gid
        or UPDATER_USER in application_group.gr_mem
    ):
        fail(f"{UPDATER_USER} must not belong to the uten-imp application group")
    server_environment = Path("/etc/uten-imp/server.env")
    if server_environment.exists() or server_environment.is_symlink():
        details = server_environment.lstat()
        mode = stat.S_IMODE(details.st_mode)
        ownership_mode_ok = (details.st_gid == 0 and mode == 0o600) or (
            application_group is not None
            and details.st_gid == application_group.gr_gid
            and mode == 0o640
        )
        if (
            not stat.S_ISREG(details.st_mode)
            or server_environment.is_symlink()
            or details.st_uid != 0
            or not ownership_mode_ok
        ):
            fail("server.env must remain root-controlled and unreadable by the updater account")
    for unit in WATCHDOG_SERVICES:
        assert_watchdog_service_gate_contract(unit)
    assert_storage_observer_contract()
    assert_postgres_storage_unit_contract()
    assert_database_boot_contract()
    assert_application_unit_contract()
    assert_migration_unit_contract()
    assert_nginx_unit_contract()


def atomic_current(base: Path, target: Path) -> None:
    current = base / "current"
    temporary = base / f".current-activate-{os.getpid()}"
    temporary.unlink(missing_ok=True)
    relative = os.path.relpath(target, base)
    os.symlink(relative, temporary)
    os.replace(temporary, current)
    fsync_directory(base)


def remove_current(base: Path) -> None:
    current = base / "current"
    if current.is_symlink():
        current.unlink()
        fsync_directory(base)
    elif os.path.lexists(current):
        fail("refusing to remove a non-symlink current path")


def current_release(base: Path, releases: Path) -> Path | None:
    current = base / "current"
    if not current.exists() and not current.is_symlink():
        return None
    if not current.is_symlink():
        fail("/opt/uten-imp/current must be a symbolic link")
    resolved = current.resolve(strict=True)
    try:
        resolved.relative_to(releases.resolve())
    except ValueError as exc:
        raise UpdaterError("current points outside the controlled releases directory") from exc
    return resolved


def require_legacy_retirement_quiescence() -> None:
    controlled_units = tuple(
        dict.fromkeys((*BOOT_UNITS, *WATCHDOG_SERVICES, MIGRATION_UNIT))
    )
    for unit in controlled_units:
        if not unit_exists(unit):
            fail(f"legacy retirement requires the reviewed installed unit: {unit}")
        if unit_active(unit):
            fail(f"legacy retirement requires an inactive unit: {unit}")
        if unit_enabled(unit):
            fail(f"legacy retirement requires a disabled unit: {unit}")


def capture_legacy_current_evidence(
    *, base: Path, legacy_target: Path
) -> dict[str, str]:
    current = base / "current"
    if not current.is_symlink():
        fail("legacy current disappeared or is no longer a symlink")
    link_target = os.readlink(current)
    resolved = current.resolve(strict=True)
    if resolved != legacy_target:
        fail("legacy current changed after retirement approval")
    return {
        "legacyCurrentLinkTarget": link_target,
        "legacyResolvedPath": str(resolved),
    }


def record_and_remove_legacy_current(
    *,
    base: Path,
    legacy_target: Path,
    new_info: dict[str, Any],
    expected_evidence: dict[str, str],
) -> None:
    current = base / "current"
    if os.path.lexists(LEGACY_RETIREMENT_MARKER):
        require_root_controlled_file(LEGACY_RETIREMENT_MARKER, secret=True)
        fail("legacy current retirement is one-time and has already been recorded")
    evidence = capture_legacy_current_evidence(
        base=base, legacy_target=legacy_target
    )
    if evidence != expected_evidence:
        fail("legacy current evidence changed before retirement commit")
    atomic_json(
        LEGACY_RETIREMENT_MARKER,
        {
            **evidence,
            "replacementCommitSha": new_info["commitSha"],
            "replacementVersion": new_info["version"],
            "retirementRecordedAtUtc": utc_now(),
            "rollbackAllowed": False,
            "schemaVersion": 1,
        },
        mode=0o600,
    )
    require_root_controlled_file(LEGACY_RETIREMENT_MARKER, secret=True)
    remove_current(base)
    if os.path.lexists(current):
        fail("legacy current link remained after retirement")


def verify_candidate_metadata(
    candidate: Path, allowed_signers: Path
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    if not candidate.is_dir() or candidate.is_symlink():
        fail(f"staged candidate is missing or unsafe: {candidate}")
    marker = release_guard.load_json(candidate / "STAGED.json", 64 * 1024)
    if marker.get("payloadVerified") is not True or marker.get("schemaVersion") != 1:
        fail("staged marker is incomplete")
    channel_path = candidate / "channel.json"
    channel_signature = candidate / "channel.sig"
    manifest_path = candidate / "manifest.json"
    manifest_signature = candidate / "manifest.sig"
    channel = verify_signed_json(channel_path, channel_signature, allowed_signers)
    channel_info = release_guard.validate_channel(channel, expected_channel=CHANNEL)
    key_ids = authorized_key_ids(allowed_signers)
    if channel_info["signingKeyId"] not in key_ids:
        fail("candidate signing key is no longer authorized")
    if release_guard.sha256_file(manifest_path) != channel_info["manifestSha256"]:
        fail("candidate manifest digest differs from the signed channel")
    manifest = verify_signed_json(manifest_path, manifest_signature, allowed_signers)
    manifest_info = release_guard.validate_manifest(
        manifest,
        expected_version=channel_info["version"],
        expected_signing_key_id=channel_info["signingKeyId"],
    )
    cross_check_release(channel_info, manifest_info)
    for field, expected in (
        ("version", manifest_info["version"]),
        ("releaseSequence", manifest_info["releaseSequence"]),
        ("commitSha", manifest_info["commitSha"]),
        ("manifestSha256", release_guard.sha256_file(manifest_path)),
        ("channelSha256", release_guard.sha256_file(channel_path)),
        ("artifactSha256", manifest_info["artifactSha256"]),
    ):
        if marker.get(field) != expected:
            fail(f"staged marker disagrees on {field}")
    return channel_info, manifest_info, marker


def verify_candidate(
    candidate: Path,
    allowed_signers: Path,
    *,
    verify_staged_payload: bool = True,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    channel_info, manifest_info, marker = verify_candidate_metadata(
        candidate, allowed_signers
    )
    artifact = candidate / manifest_info["artifactFileName"]
    if not artifact.is_file() or artifact.is_symlink():
        fail("staged archive is missing or unsafe")
    if artifact.stat().st_size != manifest_info["artifactSizeBytes"]:
        fail("staged archive size differs from the signed manifest")
    if release_guard.sha256_file(artifact) != manifest_info["artifactSha256"]:
        fail("staged archive digest differs from the signed manifest")
    if verify_staged_payload:
        payload = candidate / "payload" / manifest_info["version"]
        release_guard.verify_payload(payload, manifest_info)
    return channel_info, manifest_info, marker


def copy_untrusted_regular_file(
    source_directory_fd: int,
    source_name: str,
    destination: Path,
    *,
    updater_uid: int,
    maximum_bytes: int,
    expected_bytes: int | None = None,
) -> None:
    """Copy one updater-owned file through a stable no-follow fd into root-only storage."""
    if not source_name or "/" in source_name or "\\" in source_name:
        fail("snapshot source name is not a direct child")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    try:
        source_fd = os.open(source_name, flags, dir_fd=source_directory_fd)
    except OSError as exc:
        raise UpdaterError(f"cannot safely open staged file: {source_name}") from exc
    try:
        before = os.fstat(source_fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != updater_uid
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > maximum_bytes
            or (expected_bytes is not None and before.st_size != expected_bytes)
        ):
            fail(f"staged file violates snapshot constraints: {source_name}")
        destination_flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | os.O_NOFOLLOW
        )
        destination_fd = os.open(destination, destination_flags, 0o600)
        copied = 0
        try:
            while True:
                chunk = os.read(source_fd, min(1024 * 1024, maximum_bytes - copied + 1))
                if not chunk:
                    break
                copied += len(chunk)
                if copied > maximum_bytes:
                    fail(f"staged file grew beyond its snapshot limit: {source_name}")
                view = memoryview(chunk)
                while view:
                    written = os.write(destination_fd, view)
                    if written < 1:
                        fail(f"could not make progress while snapshotting: {source_name}")
                    view = view[written:]
            os.fsync(destination_fd)
        finally:
            os.close(destination_fd)
        after = os.fstat(source_fd)
        stable_fields_before = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        stable_fields_after = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if copied != before.st_size or stable_fields_before != stable_fields_after:
            destination.unlink(missing_ok=True)
            fail(f"staged file changed while it was snapshotted: {source_name}")
    finally:
        os.close(source_fd)


def adopt_or_copy_untrusted_regular_file(
    source_directory_fd: int,
    source_name: str,
    destination: Path,
    *,
    updater_uid: int,
    maximum_bytes: int,
    expected_bytes: int | None = None,
) -> None:
    """Resume one fixed snapshot file without trusting a partial prior write."""

    if not os.path.lexists(destination):
        copy_untrusted_regular_file(
            source_directory_fd,
            source_name,
            destination,
            updater_uid=updater_uid,
            maximum_bytes=maximum_bytes,
            expected_bytes=expected_bytes,
        )
        return
    details = destination.lstat()
    if (
        not stat.S_ISREG(details.st_mode)
        or destination.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o600
        or details.st_nlink != 1
        or not 1 <= details.st_size <= maximum_bytes
        or (expected_bytes is not None and details.st_size != expected_bytes)
    ):
        fail(f"partial root snapshot file is unsafe: {destination}")
    source_fd = os.open(
        source_name,
        os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
        dir_fd=source_directory_fd,
    )
    try:
        before = os.fstat(source_fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != updater_uid
            or before.st_nlink != 1
            or before.st_size != details.st_size
            or before.st_size > maximum_bytes
        ):
            fail(f"staged file differs from resumable snapshot: {source_name}")
        digest = hashlib.sha256()
        while True:
            block = os.read(source_fd, 1024 * 1024)
            if not block:
                break
            digest.update(block)
        after = os.fstat(source_fd)
        if (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            fail(f"staged file changed during snapshot adoption: {source_name}")
        if digest.hexdigest() != release_guard.sha256_file(destination):
            fail(f"partial root snapshot differs from staged file: {source_name}")
    finally:
        os.close(source_fd)


def snapshot_candidate(
    candidate: Path,
    releases: Path,
    allowed_signers: Path,
    *,
    transaction_snapshot: Path | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Create and verify a root-owned, same-filesystem snapshot of updater-owned evidence."""
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        fail("this platform cannot safely snapshot an untrusted candidate directory")
    try:
        account = pwd.getpwnam(UPDATER_USER)
    except KeyError as exc:
        raise UpdaterError(f"dedicated account does not exist: {UPDATER_USER}") from exc
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        candidate_fd = os.open(candidate, directory_flags)
    except OSError as exc:
        raise UpdaterError(f"cannot safely open staged candidate: {candidate}") from exc
    resumable_default = transaction_snapshot is None
    if resumable_default:
        release_guard.version_sequence(candidate.name)
        snapshot = releases / f".candidate-snapshot-{candidate.name}"
        if os.path.lexists(snapshot):
            require_real_directory(snapshot, owner_uid=0)
            if stat.S_IMODE(snapshot.lstat().st_mode) != 0o700:
                fail("resumable candidate snapshot has unsafe permissions")
        else:
            os.mkdir(snapshot, 0o700)
            os.chown(snapshot, 0, 0)
            os.chmod(snapshot, 0o700)
            fsync_directory(releases)
    else:
        if not transaction_snapshot.is_absolute():
            fail("transaction candidate snapshot path is not absolute")
        require_real_directory(transaction_snapshot.parent, owner_uid=0)
        if transaction_snapshot.parent.lstat().st_dev != releases.lstat().st_dev:
            fail("transaction candidate snapshot is on another filesystem")
        if os.path.lexists(transaction_snapshot):
            fail("transaction candidate snapshot unexpectedly already exists")
        os.mkdir(transaction_snapshot, 0o700)
        snapshot = transaction_snapshot
        os.chown(snapshot, 0, 0)
        os.chmod(snapshot, 0o700)
        fsync_directory(transaction_snapshot.parent)
    try:
        candidate_details = os.fstat(candidate_fd)
        if (
            not stat.S_ISDIR(candidate_details.st_mode)
            or candidate_details.st_uid != account.pw_uid
            or candidate_details.st_mode & 0o022
        ):
            fail("staged candidate directory has unsafe ownership or permissions")
        limits = {
            "channel.json": release_guard.MAX_CHANNEL_BYTES,
            "channel.sig": release_guard.MAX_SIGNATURE_BYTES,
            "manifest.json": release_guard.MAX_MANIFEST_BYTES,
            "manifest.sig": release_guard.MAX_SIGNATURE_BYTES,
            "STAGED.json": 64 * 1024,
        }
        for name, maximum in limits.items():
            adopt_or_copy_untrusted_regular_file(
                candidate_fd,
                name,
                snapshot / name,
                updater_uid=account.pw_uid,
                maximum_bytes=maximum,
            )
        _, manifest_info, _ = verify_candidate_metadata(snapshot, allowed_signers)
        require_capacity(
            releases,
            manifest_info["artifactSizeBytes"]
            + manifest_info["uncompressedBytes"],
            "root release snapshot and installation",
        )
        adopt_or_copy_untrusted_regular_file(
            candidate_fd,
            manifest_info["artifactFileName"],
            snapshot / manifest_info["artifactFileName"],
            updater_uid=account.pw_uid,
            maximum_bytes=release_guard.MAX_ARCHIVE_BYTES,
            expected_bytes=manifest_info["artifactSizeBytes"],
        )
        directory_fd = os.open(snapshot, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        _, verified_info, _ = verify_candidate(
            snapshot, allowed_signers, verify_staged_payload=False
        )
        return snapshot, verified_info
    except Exception:
        # Ordinary exceptions can clean the exact bounded namespace. SIGKILL
        # cannot run this block; the next invocation adopts the same fixed
        # directory and never creates an unbounded random orphan.
        shutil.rmtree(snapshot, ignore_errors=True)
        fsync_directory(snapshot.parent)
        raise
    finally:
        os.close(candidate_fd)


def verify_installed_release_target(
    candidate: Path,
    target: Path,
    manifest_info: dict[str, Any],
) -> None:
    """Revalidate the published root-owned tree before it can become current."""
    if target.is_symlink() or not target.is_dir():
        fail(f"release target exists with an unsafe type: {target}")
    release_guard.verify_payload(target, manifest_info)
    installed_manifest = target / ".release/manifest.json"
    if release_guard.sha256_file(installed_manifest) != release_guard.sha256_file(
        candidate / "manifest.json"
    ):
        fail("existing release target has different signed metadata")
    require_root_owned_tree(target)


def install_root_owned_release(
    candidate: Path,
    releases: Path,
    manifest_info: dict[str, Any],
) -> Path:
    require_real_directory(candidate, owner_uid=0)
    if candidate.lstat().st_mode & 0o022:
        fail("root candidate snapshot must not be group/world-writable")
    require_root_owned_tree(candidate)
    target = releases / manifest_info["version"]
    temporary_parent = releases / f".install-{manifest_info['version']}"

    def discard_bounded_workspace() -> None:
        if not os.path.lexists(temporary_parent):
            return
        require_real_directory(temporary_parent, owner_uid=0)
        if stat.S_IMODE(temporary_parent.lstat().st_mode) != 0o700:
            fail("resumable install workspace has unsafe permissions")
        require_root_owned_tree(temporary_parent)
        shutil.rmtree(temporary_parent)
        fsync_directory(releases)

    if target.exists():
        verify_installed_release_target(candidate, target, manifest_info)
        # A kill after publish but before workspace cleanup is safely adopted:
        # the immutable target is verified first, then only the fixed root-owned
        # build namespace for this signed version is removed.
        discard_bounded_workspace()
        return target
    # A kill during extraction may leave a partial tree. It was never published
    # as the version target and lives in one deterministic, root-owned namespace.
    # Validate that namespace before removing it; repeated crashes therefore
    # cannot create unbounded random .install-* directories.
    discard_bounded_workspace()
    os.mkdir(temporary_parent, 0o700)
    os.chown(temporary_parent, 0, 0)
    os.chmod(temporary_parent, 0o700)
    fsync_directory(releases)
    try:
        extracted = release_guard.safe_extract(
            candidate / manifest_info["artifactFileName"], temporary_parent, manifest_info
        )
        evidence = extracted / ".release"
        evidence.mkdir(mode=0o755)
        for name in ("channel.json", "channel.sig", "manifest.json", "manifest.sig", "STAGED.json"):
            source = candidate / name
            if not source.is_file() or source.is_symlink():
                fail(f"candidate evidence file is missing or unsafe: {source}")
            shutil.copyfile(source, evidence / name)
            os.chmod(evidence / name, 0o644)
        release_guard.verify_payload(extracted, manifest_info)
        for root, directories, files in os.walk(extracted):
            os.chown(root, 0, 0)
            os.chmod(root, 0o755)
            for directory in directories:
                path = Path(root) / directory
                os.chown(path, 0, 0)
                os.chmod(path, 0o755)
            for filename in files:
                path = Path(root) / filename
                os.chown(path, 0, 0)
                os.chmod(path, 0o644)
        fsync_tree(extracted)
        os.replace(extracted, target)
        fsync_directory(releases)
        fsync_directory(temporary_parent)
        verify_installed_release_target(candidate, target, manifest_info)
        return target
    finally:
        if os.path.lexists(temporary_parent):
            discard_bounded_workspace()


def require_root_owned_tree(root: Path) -> None:
    """Reject any installed path that the unprivileged downloader could mutate."""
    for path in (root, *root.rglob("*")):
        details = path.lstat()
        if stat.S_ISLNK(details.st_mode):
            fail(f"installed release contains a symbolic link: {path}")
        if details.st_uid != 0 or details.st_gid != 0:
            fail(f"installed release path is not root:root owned: {path}")
        if details.st_mode & 0o022:
            fail(f"installed release path is group/world-writable: {path}")


def validate_health(base_url: str, attempts: int = 100, delay_seconds: float = 3.0) -> None:
    if base_url != HEALTH_BASE_URL:
        fail("health verification is restricted to the loopback backend endpoint")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    endpoints = (
        "/actuator/health",
        "/actuator/health/liveness",
        "/actuator/health/readiness",
    )
    last_error = "no probe attempted"
    for _ in range(attempts):
        try:
            for endpoint in endpoints:
                request = urllib.request.Request(
                    base_url + endpoint,
                    headers={"Accept": "application/json"},
                    method="GET",
                )
                with opener.open(request, timeout=5) as response:
                    content_type = response.headers.get_content_type()
                    body = response.read(64 * 1024)
                    if response.status != 200 or content_type != "application/json":
                        fail(f"health endpoint returned unexpected HTTP metadata: {endpoint}")
                    value = json.loads(body.decode("utf-8"))
                    if not isinstance(value, dict) or value.get("status") != "UP":
                        fail(f"health endpoint is not exactly UP: {endpoint}")
            info_request = urllib.request.Request(base_url + "/actuator/info", method="GET")
            try:
                with opener.open(info_request, timeout=5) as response:
                    info_status = response.status
            except urllib.error.HTTPError as exc:
                info_status = exc.code
            if info_status != 404:
                fail(f"/actuator/info must return 404, got {info_status}")
            return
        except (
            OSError,
            UnicodeDecodeError,
            json.JSONDecodeError,
            release_guard.ReleaseGuardError,
            UpdaterError,
        ) as exc:
            last_error = str(exc)
            time.sleep(delay_seconds)
    fail(f"strict health verification did not pass: {last_error}")


def validate_static_entry(manifest_info: dict[str, Any]) -> None:
    connection = http.client.HTTPConnection("127.0.0.1", 8081, timeout=5)
    try:
        connection.request(
            "GET",
            "/index.html",
            headers={"Accept": "text/html", "Host": "localhost"},
        )
        response = connection.getresponse()
        body = response.read(2 * 1024 * 1024 + 1)
        release_guard.validate_static_entry_response(
            response.status,
            response.getheader("Content-Type", ""),
            body,
            manifest_info["version"],
        )
    except (OSError, http.client.HTTPException) as exc:
        raise UpdaterError(f"static entry probe failed: {exc}") from exc
    finally:
        connection.close()
    version_connection = http.client.HTTPConnection("127.0.0.1", 8081, timeout=5)
    try:
        version_connection.request(
            "GET",
            "/version.json",
            headers={"Accept": "application/json", "Host": "localhost"},
        )
        response = version_connection.getresponse()
        body = response.read(64 * 1024 + 1)
        if (
            response.status != 200
            or response.getheader("Content-Type", "").split(";", 1)[0].strip().lower()
            != "application/json"
            or len(body) > 64 * 1024
        ):
            fail("live web/version.json returned unexpected HTTP metadata")
        try:
            value = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise UpdaterError("live web/version.json is not valid UTF-8 JSON") from exc
        if not isinstance(value, dict):
            fail("live web/version.json root is not an object")
        release_guard.validate_web_version_value(value, manifest_info)
    except (OSError, http.client.HTTPException) as exc:
        raise UpdaterError(f"live web version probe failed: {exc}") from exc
    finally:
        version_connection.close()


def load_installed_manifest(
    release: Path, allowed_signers: Path
) -> dict[str, Any] | None:
    evidence = release / ".release"
    if not evidence.is_dir() or evidence.is_symlink():
        return None
    manifest_path = evidence / "manifest.json"
    signature_path = evidence / "manifest.sig"
    manifest = verify_signed_json(manifest_path, signature_path, allowed_signers)
    info = release_guard.validate_manifest(manifest)
    if info["signingKeyId"] not in authorized_key_ids(allowed_signers):
        fail("installed release was signed by a key that is no longer authorized")
    release_guard.verify_payload(release, info)
    return info


def require_recovery_boot_map(value: Any, label: str) -> dict[str, bool]:
    if not isinstance(value, dict) or set(value) != set(BOOT_UNITS):
        fail(f"{label} must contain the exact controlled boot-unit set")
    if any(not isinstance(enabled, bool) for enabled in value.values()):
        fail(f"{label} values must all be boolean")
    return {unit: value[unit] for unit in BOOT_UNITS}


def require_recovery_timestamp(value: Any, label: str) -> str:
    return release_guard.require_string(value, label, UTC_TIMESTAMP_RE)


def require_recovery_schema_version(value: dict[str, Any], label: str) -> None:
    schema_version = value.get("schemaVersion")
    if (
        not isinstance(schema_version, int)
        or isinstance(schema_version, bool)
        or schema_version != 1
    ):
        fail(f"{label} schema is unsupported")


def interrupted_state_kind(marker_names: Any) -> str:
    """Return the only reviewed interrupted-transaction marker combinations."""
    if not isinstance(marker_names, (set, frozenset, list, tuple)):
        fail("interrupted marker set is malformed")
    names = frozenset(marker_names)
    kinds = {
        frozenset({"activation"}): "activation",
        frozenset({"recovery"}): "recovery",
        frozenset({"boot"}): "boot",
        frozenset({"activation", "boot"}): "activation+boot",
        frozenset({"recovery", "boot"}): "recovery+boot",
    }
    kind = kinds.get(names)
    if kind is None:
        fail(
            "interrupted marker combination is empty or conflicting; activation and "
            "recovery markers must never be contained together"
        )
    return kind


def validate_activation_failure_marker(value: dict[str, Any]) -> str:
    """Validate every supported activation-failed schema and return its exact kind."""
    preparation_keys = {
        "failedAtUtc",
        "failedCommitSha",
        "failedVersion",
        "originalBootEnablement",
        "previousVersion",
        "reason",
        "recoveryRequired",
        "schemaVersion",
    }
    failure_keys = {
        "currentLinkRestored",
        "failedAtUtc",
        "failedCommitSha",
        "failedFlywayHeadVersion",
        "failedFlywayMigrationSetSha256",
        "failedVersion",
        "originalBootEnablement",
        "previousFlywayHeadVersion",
        "previousFlywayMigrationSetSha256",
        "previousVersion",
        "reason",
        "recoveryRequired",
        "schemaVersion",
    }
    containment_keys = {
        "containmentStartedAtUtc",
        "interruptedMarkerSha256",
        "planSha256",
        "reason",
        "recoveryRequired",
        "schemaVersion",
        "startAuthorization",
        "stateKind",
        "transactionDirectory",
    }
    keys = set(value)
    if keys == containment_keys:
        kind = "interrupted-containment-v1"
        require_recovery_schema_version(value, "activation-failed marker")
        if (
            value.get("reason") != "interrupted-transaction-containment"
            or value.get("recoveryRequired") is not True
        ):
            fail("interrupted containment marker control fields are malformed")
        require_recovery_timestamp(
            value.get("containmentStartedAtUtc"), "interrupted containment start time"
        )
        plan_sha = release_guard.require_string(
            value.get("planSha256"),
            "interrupted containment plan digest",
            release_guard.SHA256_RE,
        )
        marker_digests = value.get("interruptedMarkerSha256")
        if not isinstance(marker_digests, dict):
            fail("interrupted containment marker digest map is malformed")
        state_kind = interrupted_state_kind(set(marker_digests))
        if value.get("stateKind") != state_kind:
            fail("interrupted containment state kind differs from its marker set")
        for name, digest in marker_digests.items():
            release_guard.require_string(
                digest, f"interrupted {name} marker digest", release_guard.SHA256_RE
            )
        start_authorization = value.get("startAuthorization")
        if start_authorization is not None:
            if not isinstance(start_authorization, dict) or set(start_authorization) != {
                "path",
                "sha256",
            }:
                fail("interrupted containment start authorization is malformed")
            authorization_path = Path(
                release_guard.require_string(
                    start_authorization.get("path"),
                    "interrupted start authorization path",
                )
            )
            application_path = (
                authorization_path.parent == START_AUTHORIZATION_DIR
                and (
                    authorization_path == START_AUTHORIZATION
                    or START_AUTHORIZATION_CONSUMED_RE.fullmatch(
                        authorization_path.name
                    )
                )
            )
            migration_path = (
                authorization_path.parent == MIGRATION_AUTHORIZATION_DIR
                and (
                    authorization_path == MIGRATION_AUTHORIZATION
                    or MIGRATION_AUTHORIZATION_ARCHIVE_RE.fullmatch(
                        authorization_path.name
                    )
                )
            )
            if not application_path and not migration_path:
                fail("interrupted start authorization path is not fixed")
            release_guard.require_string(
                start_authorization.get("sha256"),
                "interrupted start authorization digest",
                release_guard.SHA256_RE,
            )
        transaction = Path(
            release_guard.require_string(
                value.get("transactionDirectory"),
                "interrupted containment transaction directory",
            )
        )
        if transaction.parent != RECOVERY_EVIDENCE_DIR:
            fail(
                "interrupted containment transaction must be a direct fixed "
                "evidence-directory child"
            )
        if transaction.name != f"interrupted-{plan_sha}":
            fail("interrupted containment transaction is not bound to its plan digest")
        return kind
    if keys == preparation_keys:
        kind = "activation-preparing-v1"
        if value.get("reason") != "activation-preparing":
            fail("activation preparation marker reason is not canonical")
    elif keys in (failure_keys, failure_keys | {"legacyCurrent"}):
        kind = "activation-failure-v1"
        if value.get("reason") not in {
            "first-release-failed",
            "activation-preparation-failed",
            "activation-commit-failed",
            "legacy-retirement-preparation-failed",
            "current-restore-failed",
            "database-incompatible",
            "migration-process-failed",
            "previous-release-recovery-failed",
        }:
            fail("activation failure marker reason is not canonical")
        if not isinstance(value.get("currentLinkRestored"), bool):
            fail("activation failure current-link evidence is malformed")
        failed_head = release_guard.require_string(
            value.get("failedFlywayHeadVersion"), "failed Flyway head"
        )
        if not failed_head.isdigit():
            fail("activation failure Flyway head is malformed")
        release_guard.require_string(
            value.get("failedFlywayMigrationSetSha256"),
            "failed Flyway migration-set digest",
            release_guard.SHA256_RE,
        )
        previous_head = value.get("previousFlywayHeadVersion")
        previous_digest = value.get("previousFlywayMigrationSetSha256")
        if value.get("previousVersion") is None:
            if previous_head is not None or previous_digest is not None:
                fail("first-release failure contains inconsistent previous Flyway evidence")
        else:
            previous_head = release_guard.require_string(
                previous_head, "previous Flyway head"
            )
            if not previous_head.isdigit():
                fail("previous Flyway head is malformed")
            release_guard.require_string(
                previous_digest,
                "previous Flyway migration-set digest",
                release_guard.SHA256_RE,
            )
        if "legacyCurrent" in value:
            legacy = value["legacyCurrent"]
            if not isinstance(legacy, dict) or set(legacy) != {
                "legacyCurrentLinkTarget",
                "legacyResolvedPath",
            }:
                fail("legacy current recovery evidence is malformed")
            for key, item in legacy.items():
                release_guard.require_string(item, f"legacy current {key}")
    else:
        fail("activation-failed marker has an unknown schema")

    require_recovery_schema_version(value, "activation-failed marker")
    if value.get("recoveryRequired") is not True:
        fail("activation-failed marker control fields are malformed")
    require_recovery_timestamp(value.get("failedAtUtc"), "activation failure time")
    release_guard.require_string(
        value.get("failedCommitSha"), "failed commit", release_guard.COMMIT_RE
    )
    failed_version = release_guard.require_string(
        value.get("failedVersion"), "failed version"
    )
    release_guard.version_sequence(failed_version)
    require_recovery_boot_map(
        value.get("originalBootEnablement"), "original boot enablement"
    )
    previous_version = value.get("previousVersion")
    if previous_version is not None:
        previous_version = release_guard.require_string(
            previous_version, "previous version"
        )
        release_guard.version_sequence(previous_version)
    return kind


def validate_activation_in_progress_marker(value: dict[str, Any]) -> str:
    release_guard.exact_keys(
        value,
        {
            "commitSha",
            "originalBootEnablement",
            "previousVersion",
            "releaseSequence",
            "schemaVersion",
            "startedAtUtc",
            "version",
        },
        "activation-in-progress marker",
    )
    require_recovery_schema_version(value, "activation-in-progress marker")
    version = release_guard.require_string(value.get("version"), "activation version")
    if release_guard.version_sequence(version) != value.get("releaseSequence"):
        fail("activation-in-progress version/sequence is inconsistent")
    release_guard.require_string(
        value.get("commitSha"), "activation commit", release_guard.COMMIT_RE
    )
    require_recovery_timestamp(value.get("startedAtUtc"), "activation start time")
    require_recovery_boot_map(
        value.get("originalBootEnablement"), "activation original boot enablement"
    )
    previous = value.get("previousVersion")
    if previous is not None:
        release_guard.version_sequence(
            release_guard.require_string(previous, "activation previous version")
        )
    return "activation-in-progress-v1"


def validate_boot_enablement_marker(value: dict[str, Any]) -> str:
    release_guard.exact_keys(
        value,
        {
            "commitSha",
            "desiredBootEnablement",
            "releaseSequence",
            "schemaVersion",
            "startedAtUtc",
            "version",
        },
        "boot-enablement-in-progress marker",
    )
    require_recovery_schema_version(value, "boot-enablement marker")
    version = release_guard.require_string(value.get("version"), "boot version")
    if release_guard.version_sequence(version) != value.get("releaseSequence"):
        fail("boot-enablement version/sequence is inconsistent")
    release_guard.require_string(
        value.get("commitSha"), "boot commit", release_guard.COMMIT_RE
    )
    require_recovery_timestamp(value.get("startedAtUtc"), "boot enablement start time")
    require_recovery_boot_map(
        value.get("desiredBootEnablement"), "desired boot enablement"
    )
    return "boot-enablement-in-progress-v1"


def validate_recovery_in_progress_marker(value: dict[str, Any]) -> str:
    release_guard.exact_keys(
        value,
        {
            "action",
            "approvalReference",
            "databaseReceiptPath",
            "databaseReceiptSha256",
            "desiredBootEnablement",
            "markerSha256",
            "planSha256",
            "schemaVersion",
            "startedAtUtc",
            "targetVersion",
            "transactionDirectory",
        },
        "recovery-in-progress marker",
    )
    require_recovery_schema_version(value, "recovery-in-progress marker")
    if value.get("action") not in {
        "retry-activation",
        "finish-activation",
        "restore-previous",
        "abandon-candidate",
    }:
        fail("recovery-in-progress marker schema is unsupported")
    for key in ("databaseReceiptSha256", "markerSha256", "planSha256"):
        release_guard.require_string(value.get(key), key, release_guard.SHA256_RE)
    approval = release_guard.require_string(
        value.get("approvalReference"), "recovery approval reference"
    )
    if not RECOVERY_APPROVAL_RE.fullmatch(approval):
        fail("recovery approval reference is not canonical")
    receipt_path = Path(
        release_guard.require_string(
            value.get("databaseReceiptPath"), "recovery database receipt path"
        )
    )
    if (
        receipt_path.parent != RECOVERY_DATABASE_RECEIPTS_DIR
        or not RECOVERY_RECEIPT_NAME_RE.fullmatch(receipt_path.name)
    ):
        fail("recovery database receipt path is not fixed")
    require_recovery_boot_map(
        value.get("desiredBootEnablement"), "recovery desired boot enablement"
    )
    version = release_guard.require_string(value.get("targetVersion"), "recovery target")
    release_guard.version_sequence(version)
    require_recovery_timestamp(value.get("startedAtUtc"), "recovery start time")
    transaction = Path(
        release_guard.require_string(
            value.get("transactionDirectory"), "recovery transaction directory"
        )
    )
    try:
        transaction.relative_to(RECOVERY_EVIDENCE_DIR)
    except ValueError as exc:
        raise UpdaterError("recovery transaction escaped the fixed evidence directory") from exc
    if transaction.parent != RECOVERY_EVIDENCE_DIR:
        fail("recovery transaction must be a direct evidence-directory child")
    return "recovery-in-progress-v1"


def validate_active_release_state(value: dict[str, Any]) -> str:
    internal = deployment_profile() == "internal-test"
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
    if internal:
        expected_keys.update(
            {
                "onboardingArchivePath",
                "onboardingReceiptSha256",
                "runtimeContractId",
                "runtimeContractSha256",
            }
        )
        if "firstBackup" in value:
            expected_keys.add("firstBackup")
    release_guard.exact_keys(
        value,
        expected_keys,
        "root-owned active release state",
    )
    version = release_guard.require_string(value.get("version"), "active version")
    if release_guard.version_sequence(version) != value.get("releaseSequence"):
        fail("active version/sequence is inconsistent")
    require_recovery_timestamp(value.get("activatedAtUtc"), "active release time")
    release_guard.require_string(
        value.get("commitSha"), "active commit", release_guard.COMMIT_RE
    )
    head = release_guard.require_string(value.get("flywayHeadVersion"), "active Flyway head")
    if not head.isdigit():
        fail("active Flyway head is malformed")
    for key in ("flywayMigrationSetSha256", "manifestSha256"):
        release_guard.require_string(value.get(key), f"active {key}", release_guard.SHA256_RE)
    if not isinstance(value.get("databaseChanged"), bool):
        fail("active databaseChanged state is malformed")
    if internal:
        contract, contract_sha = internal_test_runtime_contract()
        if (
            value.get("runtimeContractId") != contract["contractId"]
            or value.get("runtimeContractSha256") != contract_sha
        ):
            fail("active release is not bound to the live internal-test runtime contract")
        archive_path = Path(
            release_guard.require_string(
                value.get("onboardingArchivePath"), "active onboarding archive path"
            )
        )
        if archive_path.parent != INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR:
            fail("active onboarding archive escaped the fixed evidence directory")
        receipt_sha = release_guard.require_string(
            value.get("onboardingReceiptSha256"),
            "active onboarding receipt digest",
            release_guard.SHA256_RE,
        )
        require_root_controlled_file(archive_path, secret=True)
        if release_guard.sha256_file(archive_path) != receipt_sha:
            fail("active onboarding archive differs from the committed digest")
        if "firstBackup" in value:
            validate_internal_test_first_backup_binding(
                value["firstBackup"],
                require_archive=(
                    None
                    if os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION)
                    else True
                ),
            )
            if (
                value["firstBackup"].get("onboardingReceiptSha256") != receipt_sha
                or archive_path
                != INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR
                / (value["firstBackup"]["onboardingTransactionId"] + ".json")
                or value["firstBackup"].get("archivePath")
                != str(
                    _first_backup_archive_path(
                        value["firstBackup"]["onboardingTransactionId"]
                    )
                )
            ):
                fail("active first-backup origin differs from onboarding authority")
    return "active-release-v1"


def root_json_observation(
    path: Path, label: str, validator: Any
) -> tuple[dict[str, Any], bytes]:
    raw = read_root_evidence_bytes(path)
    fields = strict_json_object(raw, label)
    schema_kind = validator(fields)
    return (
        {
            "fields": fields,
            "path": str(path),
            "schemaKind": schema_kind,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "sizeBytes": len(raw),
        },
        raw,
    )


def optional_root_json_observation(
    path: Path, label: str, validator: Any
) -> dict[str, Any] | None:
    if not os.path.lexists(path):
        return None
    observation, _ = root_json_observation(path, label, validator)
    return observation


def observe_installed_release(
    release: Path, allowed_signers: Path
) -> dict[str, Any]:
    observation: dict[str, Any] = {"path": str(release), "verified": False}
    try:
        require_real_directory(release, owner_uid=0)
        require_root_owned_tree(release)
        info = load_installed_manifest(release, allowed_signers)
        if info is None:
            fail("installed release has no signed manifest evidence")
        if info["version"] != release.name:
            fail("installed release directory name differs from its signed version")
        observation.update(
            {
                "commitSha": info["commitSha"],
                "flywayHeadVersion": info["flywayHeadVersion"],
                "flywayMigrationCount": len(info["flywayMigrations"]),
                "flywayMigrationSetSha256": info["flywayMigrationSetSha256"],
                "manifestSha256": release_guard.sha256_file(
                    release / ".release/manifest.json"
                ),
                "releaseSequence": info["releaseSequence"],
                "signingKeyId": info["signingKeyId"],
                "verified": True,
                "version": info["version"],
            }
        )
    except Exception as exc:
        observation["error"] = str(exc)
    return observation


def observe_root_only_directory(path: Path) -> dict[str, Any]:
    observation: dict[str, Any] = {"path": str(path), "safe": False}
    try:
        require_real_directory(path, owner_uid=0)
        mode = stat.S_IMODE(path.lstat().st_mode)
        if mode & 0o077:
            fail("root-only recovery directory is accessible to group or world")
        observation.update({"mode": f"{mode:04o}", "safe": True})
    except Exception as exc:
        observation["error"] = str(exc)
    return observation


def observe_recovery_unit(unit: str) -> dict[str, Any]:
    """Read unit state without treating a failed systemctl query as a safe state."""
    load_state = systemd_property(unit, "LoadState")
    observation: dict[str, Any] = {
        "active": None,
        "activeState": None,
        "enabled": None,
        "exists": False,
        "loadState": load_state,
        "unitFileState": None,
    }
    if load_state is None:
        observation["error"] = "systemd LoadState could not be determined"
        return observation
    if load_state == "not-found":
        observation.update({"active": False, "enabled": False})
        return observation

    observation["exists"] = True
    active_state = systemd_property(unit, "ActiveState")
    unit_file_state = systemd_property(unit, "UnitFileState")
    observation["activeState"] = active_state
    observation["unitFileState"] = unit_file_state
    if not active_state or not unit_file_state:
        observation["error"] = "systemd active/enabled state could not be determined"
        return observation

    # Transitional and unfamiliar states are conservatively treated as active.
    observation["active"] = active_state not in {"inactive", "failed"}
    # Only reviewed non-boot states are accepted as disabled. Any unfamiliar or
    # linked/alias state remains conservatively enabled and therefore NO-GO.
    observation["enabled"] = unit_file_state not in {
        "disabled",
        "generated",
        "indirect",
        "masked",
        "masked-runtime",
        "static",
        "transient",
    }
    return observation


def recovery_confirmation(action: str, target_version: str, plan_sha256: str) -> str:
    if action not in {
        "retry-activation",
        "finish-activation",
        "restore-previous",
        "abandon-candidate",
        "remain-contained",
    }:
        fail("recovery action is unsupported")
    return f"{action.upper()}:{target_version}:{plan_sha256}"


def _interrupted_original_failure(
    recovery_marker: dict[str, Any],
) -> dict[str, Any] | None:
    """Load the exact failure gate archived by an interrupted recovery, if present."""
    fields = recovery_marker["fields"]
    transaction = Path(fields["transactionDirectory"])
    require_real_directory(transaction, owner_uid=0)
    if transaction.parent != RECOVERY_EVIDENCE_DIR or transaction.lstat().st_mode & 0o077:
        fail("interrupted recovery transaction directory is unsafe")
    original = transaction / "activation-failed.original.json"
    if not os.path.lexists(original):
        return None
    observation, _ = root_json_observation(
        original,
        "interrupted recovery original activation-failed marker",
        validate_activation_failure_marker,
    )
    if observation["sha256"] != fields["markerSha256"]:
        fail("interrupted recovery original failure marker digest changed")
    # Keep the containment plan stable before and after the live failure gate is
    # atomically replaced by the interrupted-containment gate.  The bytes live in
    # the prior recovery transaction, but semantically they are still the exact
    # original /var/lib failure marker.
    observation["path"] = str(ACTIVATION_FAILURE_MARKER)
    return observation


def ensure_interrupted_recovery_original_failure(
    recovery_marker: dict[str, Any], original_failure: dict[str, Any]
) -> dict[str, Any]:
    """Persist the still-live failure gate before normalizing a double-marker crash."""
    fields = recovery_marker["fields"]
    if original_failure.get("sha256") != fields["markerSha256"]:
        fail("interrupted recovery marker does not bind the live activation failure")
    transaction = Path(fields["transactionDirectory"])
    require_real_directory(transaction, owner_uid=0)
    if transaction.parent != RECOVERY_EVIDENCE_DIR or transaction.lstat().st_mode & 0o077:
        fail("interrupted recovery transaction directory is unsafe")
    destination = transaction / "activation-failed.original.json"
    if not os.path.lexists(destination):
        raw = read_root_evidence_bytes(ACTIVATION_FAILURE_MARKER)
        if hashlib.sha256(raw).hexdigest() != original_failure["sha256"]:
            fail("live activation failure changed before interrupted recovery snapshot")
        atomic_bytes(destination, raw, mode=0o600)
    persisted = _interrupted_original_failure(recovery_marker)
    if persisted is None or any(
        persisted[key] != original_failure[key]
        for key in ("fields", "schemaKind", "sha256", "sizeBytes")
    ):
        fail("persisted interrupted recovery original failure differs from the live gate")
    return persisted


def derive_recovery_context(
    activation_failure: dict[str, Any],
    interrupted: dict[str, Any] | None,
) -> dict[str, Any]:
    """Normalize ordinary and persistently-contained failures for one plan."""
    fields = activation_failure["fields"]
    schema_kind = activation_failure["schemaKind"]
    if schema_kind in {"activation-failure-v1", "activation-preparing-v1"}:
        return {
            "candidateCommitSha": fields["failedCommitSha"],
            "failedFlywayHeadVersion": fields.get("failedFlywayHeadVersion"),
            "failedFlywayMigrationSetSha256": fields.get(
                "failedFlywayMigrationSetSha256"
            ),
            "failedVersion": fields["failedVersion"],
            "failureReason": fields["reason"],
            "finishTargetVersion": fields["failedVersion"],
            "interruptedContainmentReceiptSha256": None,
            "interruptedStateKind": None,
            "originalBootEnablement": fields["originalBootEnablement"],
            "originMarkerSha256": activation_failure["sha256"],
            "previousFlywayHeadVersion": fields.get("previousFlywayHeadVersion"),
            "previousFlywayMigrationSetSha256": fields.get(
                "previousFlywayMigrationSetSha256"
            ),
            "previousVersion": fields.get("previousVersion"),
            "sourceKind": schema_kind,
        }
    if schema_kind != "interrupted-containment-v1" or interrupted is None:
        fail("activation recovery context is unsupported")

    state = interrupted["state"]
    receipt = state["receipt"]
    receipt_sha = receipt["sha256"] if receipt is not None else None
    markers = state["markers"]
    state_kind = state["stateKind"]
    activation = markers.get("activation")
    recovery = markers.get("recovery")
    boot = markers.get("boot")
    original_failure = (
        _interrupted_original_failure(recovery) if recovery is not None else None
    )

    if activation is not None:
        source = activation["fields"]
        failed_version = source["version"]
        previous_version = source.get("previousVersion")
        original_boot = source["originalBootEnablement"]
        candidate_commit = source["commitSha"]
        reason = "interrupted-activation"
        failed_head = None
        failed_digest = None
        previous_head = None
        previous_digest = None
        origin_sha = activation["sha256"]
    elif original_failure is not None and original_failure["schemaKind"] in {
        "activation-failure-v1",
        "activation-preparing-v1",
    }:
        source = original_failure["fields"]
        failed_version = source["failedVersion"]
        previous_version = source.get("previousVersion")
        original_boot = source["originalBootEnablement"]
        candidate_commit = source["failedCommitSha"]
        reason = f"interrupted-recovery:{recovery['fields']['action']}"
        failed_head = source.get("failedFlywayHeadVersion")
        failed_digest = source.get("failedFlywayMigrationSetSha256")
        previous_head = source.get("previousFlywayHeadVersion")
        previous_digest = source.get("previousFlywayMigrationSetSha256")
        origin_sha = original_failure["sha256"]
    elif recovery is not None:
        source = recovery["fields"]
        failed_version = source["targetVersion"]
        previous_version = (
            source["targetVersion"]
            if source["action"] in {"restore-previous", "abandon-candidate"}
            else None
        )
        original_boot = source["desiredBootEnablement"]
        candidate_commit = None
        reason = f"interrupted-recovery:{source['action']}"
        failed_head = None
        failed_digest = None
        previous_head = None
        previous_digest = None
        origin_sha = recovery["sha256"]
    elif boot is not None:
        source = boot["fields"]
        failed_version = source["version"]
        previous_version = None
        original_boot = source["desiredBootEnablement"]
        candidate_commit = source["commitSha"]
        reason = "interrupted-boot-commit"
        failed_head = None
        failed_digest = None
        previous_head = None
        previous_digest = None
        origin_sha = boot["sha256"]
    else:
        fail("interrupted containment lacks a recoverable release marker")

    finish_target = (
        recovery["fields"]["targetVersion"]
        if recovery is not None
        else boot["fields"]["version"]
        if boot is not None
        else failed_version
    )
    desired_boot = (
        boot["fields"]["desiredBootEnablement"]
        if boot is not None
        else recovery["fields"]["desiredBootEnablement"]
        if recovery is not None
        else original_boot
    )
    return {
        "candidateCommitSha": candidate_commit,
        "failedFlywayHeadVersion": failed_head,
        "failedFlywayMigrationSetSha256": failed_digest,
        "failedVersion": failed_version,
        "failureReason": reason,
        "finishTargetVersion": finish_target,
        "interruptedContainmentReceiptSha256": receipt_sha,
        "interruptedStateKind": state_kind,
        "originalBootEnablement": original_boot,
        "originMarkerSha256": origin_sha,
        "previousFlywayHeadVersion": previous_head,
        "previousFlywayMigrationSetSha256": previous_digest,
        "previousVersion": previous_version,
        "resumeDesiredBootEnablement": desired_boot,
        "sourceKind": schema_kind,
    }


def recovery_eligibility(state: dict[str, Any]) -> dict[str, dict[str, Any]]:
    marker = state["activationFailure"]
    fields = marker["fields"]
    context = state["recoveryContext"]

    safety_reasons: list[str] = []
    if state["recoveryInProgress"] is not None:
        safety_reasons.append("a prior recovery transaction is still in progress")
    if state["activationInProgress"] is not None:
        safety_reasons.append("an activation-in-progress marker remains")
    for label, storage in state["recoveryStorage"].items():
        if not storage["safe"]:
            safety_reasons.append(f"root-only recovery storage is unsafe: {label}")
    for unit, details in state["units"].items():
        if details.get("error"):
            safety_reasons.append(f"required unit state is indeterminate: {unit}")
        if not details["exists"]:
            safety_reasons.append(f"required unit is missing: {unit}")
        if details["active"] is not False:
            safety_reasons.append(f"fail-closed unit is still active: {unit}")
        if details["enabled"] is not False:
            safety_reasons.append(
                f"fail-closed controlled unit is still enabled: {unit}"
            )

    def verified_manifest(version: str | None) -> dict[str, Any] | None:
        if version is None:
            return None
        observed = state["manifests"].get(version)
        return observed if observed and observed.get("verified") else None

    def active_matches(observed: dict[str, Any] | None) -> bool:
        active = state["active"]
        if observed is None or not active.get("valid"):
            return False
        active_fields = active["fields"]
        comparisons = {
            "version": "version",
            "commitSha": "commitSha",
            "releaseSequence": "releaseSequence",
            "flywayHeadVersion": "flywayHeadVersion",
            "flywayMigrationSetSha256": "flywayMigrationSetSha256",
            "manifestSha256": "manifestSha256",
        }
        return all(
            active_fields[key] == observed[target_key]
            for key, target_key in comparisons.items()
        )

    if (
        context["sourceKind"] == "interrupted-containment-v1"
        and context["interruptedContainmentReceiptSha256"] is None
    ):
        safety_reasons.append(
            "interrupted transaction containment has no completed archive receipt"
        )

    target_version = context["finishTargetVersion"]
    reasons = list(safety_reasons)
    finish_supported = (
        marker["schemaKind"] == "activation-failure-v1"
        and fields.get("reason") == "activation-commit-failed"
        and fields.get("currentLinkRestored") is False
    ) or (
        context["sourceKind"] == "interrupted-containment-v1"
        and (
            "boot" in (context["interruptedStateKind"] or "")
            or context["failureReason"].startswith("interrupted-recovery:")
        )
    )
    if not finish_supported:
        reasons.append(
            "finish requires a committed-target failure or a contained recovery/boot commit"
        )

    target = verified_manifest(target_version)
    if target is None:
        reasons.append("the target installed manifest/payload is not verified")
    current = state["current"]
    expected_target_path = str(DEFAULT_RELEASE_BASE / "releases" / target_version)
    if current.get("error"):
        reasons.append("current link state is unsafe or unreadable")
    elif current.get("targetPath") != expected_target_path:
        reasons.append("current does not resolve to the failed target version")

    if not active_matches(target):
        reasons.append("active release state differs from the verified target manifest")

    if target is not None:
        candidate_commit = context.get("candidateCommitSha")
        if candidate_commit is not None and target_version == context["failedVersion"] and (
            candidate_commit != target.get("commitSha")
        ):
            reasons.append("failure marker commit differs from the target manifest")
        failed_head = context.get("failedFlywayHeadVersion")
        if failed_head is not None and target_version == context["failedVersion"] and (
            failed_head != target.get("flywayHeadVersion")
        ):
            reasons.append("failure marker Flyway head differs from the target manifest")
        failed_digest = context.get("failedFlywayMigrationSetSha256")
        if failed_digest is not None and target_version == context["failedVersion"] and (
            failed_digest != target.get("flywayMigrationSetSha256")
        ):
            reasons.append("failure marker Flyway digest differs from the target manifest")

    desired_boot = context.get("resumeDesiredBootEnablement") or (
        {unit: True for unit in BOOT_UNITS}
        if context.get("previousVersion") is None
        else context["originalBootEnablement"]
    )
    boot_marker = state["bootEnablementInProgress"]
    if boot_marker is not None:
        boot_fields = boot_marker["fields"]
        if (
            boot_fields["version"] != target_version
            or target is None
            or boot_fields["commitSha"] != target["commitSha"]
            or boot_fields["desiredBootEnablement"] != desired_boot
        ):
            reasons.append("boot-enablement marker differs from the exact target boot map")

    previous_version = context.get("previousVersion")
    previous = verified_manifest(previous_version)
    previous_reasons = list(safety_reasons)
    if previous_version is None:
        previous_reasons.append("the failure has no signed previous release")
    elif previous is None:
        previous_reasons.append("the signed previous release is missing or unverified")
    if previous is not None:
        if context.get("previousFlywayHeadVersion") not in {
            None,
            previous["flywayHeadVersion"],
        }:
            previous_reasons.append(
                "failure marker previous Flyway head differs from the signed release"
            )
        if context.get("previousFlywayMigrationSetSha256") not in {
            None,
            previous["flywayMigrationSetSha256"],
        }:
            previous_reasons.append(
                "failure marker previous Flyway digest differs from the signed release"
            )
    candidate = verified_manifest(context.get("failedVersion"))
    if candidate is None:
        previous_reasons.append("the failed candidate manifest/payload is not verified")
    elif context.get("candidateCommitSha") not in {None, candidate["commitSha"]}:
        previous_reasons.append("failure marker commit differs from the failed candidate")

    restore_reasons = list(previous_reasons)
    supported_restore_reasons = {
        "activation-preparation-failed",
        "activation-commit-failed",
        "current-restore-failed",
        "database-incompatible",
        "migration-process-failed",
        "previous-release-recovery-failed",
    }
    if context["sourceKind"] == "activation-preparing-v1":
        restore_reasons.append(
            "preparation-only cancellation must use abandon-candidate"
        )
    elif context["sourceKind"] == "activation-failure-v1" and context[
        "failureReason"
    ] not in supported_restore_reasons:
        restore_reasons.append("this failure reason cannot restore a previous release")
    elif context["sourceKind"] == "interrupted-containment-v1" and not (
        {"activation", "recovery"}
        & set((context["interruptedStateKind"] or "").split("+"))
    ):
        restore_reasons.append(
            "the interrupted evidence does not identify a previous release transaction"
        )

    abandon_reasons = list(previous_reasons)
    if context["sourceKind"] != "activation-preparing-v1":
        abandon_reasons.append(
            "abandon-candidate requires the preparation-only pre-mutation marker"
        )
    expected_previous_path = (
        str(DEFAULT_RELEASE_BASE / "releases" / previous_version)
        if previous_version is not None
        else None
    )
    if current.get("error") or current.get("targetPath") != expected_previous_path:
        abandon_reasons.append("current is not the exact signed previous release")
    if not active_matches(previous):
        abandon_reasons.append("active state is not the exact signed previous release")

    remain_reasons = [
        reason
        for reason in safety_reasons
        if reason.startswith("root-only recovery storage is unsafe")
    ]

    return {
        "finish-activation": {
            "allowed": not reasons,
            "reasons": reasons,
        },
        "restore-previous": {
            "allowed": not restore_reasons,
            "reasons": restore_reasons,
        },
        "abandon-candidate": {
            "allowed": not abandon_reasons,
            "reasons": abandon_reasons,
        },
        "remain-contained": {
            "allowed": not remain_reasons,
            "reasons": remain_reasons,
        },
        "retry-activation": {
            "allowed": False,
            "reasons": [
                "retry is intentionally unsupported: the current activation function cannot "
                "be safely re-entered under the held operation lock, and this helper does not "
                "perform PITR, Flyway repair, or infer database restoration"
            ],
        },
    }


def finalize_recovery_assessment(state: dict[str, Any]) -> dict[str, Any]:
    """Bind one normalized observed state to a deterministic recovery plan digest."""
    if "recoveryContext" not in state:
        state = dict(state)
        state["recoveryContext"] = derive_recovery_context(
            state["activationFailure"], state.get("interruptedContainment")
        )
    eligibility = recovery_eligibility(state)
    basis = {"eligibility": eligibility, "schemaVersion": 1, "state": state}
    plan_sha = canonical_json_sha256(basis)
    context = state["recoveryContext"]
    action_targets = {
        "finish-activation": context["finishTargetVersion"],
        "restore-previous": context.get("previousVersion") or context["failedVersion"],
        "abandon-candidate": context.get("previousVersion") or context["failedVersion"],
        "remain-contained": context["failedVersion"],
        "retry-activation": context["failedVersion"],
    }
    actions = {
        action: {
            **eligibility[action],
            "requiredConfirmation": recovery_confirmation(
                action, action_targets[action], plan_sha
            ),
            "targetVersion": action_targets[action],
        }
        for action in (
            "finish-activation",
            "restore-previous",
            "abandon-candidate",
            "remain-contained",
            "retry-activation",
        )
    }
    return {
        "actions": actions,
        "kind": "uten-imp-activation-recovery-assessment",
        "planSha256": plan_sha,
        "readOnly": True,
        "schemaVersion": 1,
        "state": state,
    }


def build_recovery_assessment() -> dict[str, Any]:
    """Build a deterministic, read-only assessment from fixed privileged paths."""
    root_state = DEFAULT_ROOT_STATE_DIR
    base = DEFAULT_RELEASE_BASE
    releases = base / "releases"
    allowed_signers = DEFAULT_ALLOWED_SIGNERS
    require_real_directory(root_state, owner_uid=0)
    require_real_directory(base, owner_uid=0)
    require_real_directory(releases, owner_uid=0)
    key_ids = authorized_key_ids(allowed_signers)
    if not os.path.lexists(ACTIVATION_FAILURE_MARKER):
        fail("no activation-failed marker is present for controlled recovery")
    activation_failure, _ = root_json_observation(
        ACTIVATION_FAILURE_MARKER,
        "activation-failed marker",
        validate_activation_failure_marker,
    )
    interrupted: dict[str, Any] | None = None
    if activation_failure["schemaKind"] == "interrupted-containment-v1":
        interrupted_full = build_interrupted_containment_assessment()
        interrupted = {
            "planSha256": interrupted_full["planSha256"],
            "state": {
                "markers": interrupted_full["state"]["markers"],
                "receipt": interrupted_full["state"]["receipt"],
                "stateKind": interrupted_full["state"]["stateKind"],
                "transactionDirectory": interrupted_full["state"][
                    "transactionDirectory"
                ],
            },
        }
    recovery_context = derive_recovery_context(activation_failure, interrupted)
    activation_in_progress = optional_root_json_observation(
        ACTIVATION_IN_PROGRESS_MARKER,
        "activation-in-progress marker",
        validate_activation_in_progress_marker,
    )
    boot_in_progress = optional_root_json_observation(
        BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
        "boot-enablement-in-progress marker",
        validate_boot_enablement_marker,
    )
    recovery_in_progress = optional_root_json_observation(
        RECOVERY_IN_PROGRESS_MARKER,
        "recovery-in-progress marker",
        validate_recovery_in_progress_marker,
    )

    current: dict[str, Any] = {"linkPath": str(base / "current"), "targetPath": None}
    current_target: Path | None = None
    try:
        current_target = current_release(base, releases)
        current["targetPath"] = str(current_target) if current_target is not None else None
    except Exception as exc:
        current["error"] = str(exc)

    active_path = root_state / "active.json"
    active: dict[str, Any] = {"path": str(active_path), "present": False, "valid": False}
    if os.path.lexists(active_path):
        active["present"] = True
        try:
            active_observation, _ = root_json_observation(
                active_path, "active release state", validate_active_release_state
            )
            active.update(active_observation)
            active["valid"] = True
        except Exception as exc:
            active["error"] = str(exc)

    versions = {
        recovery_context["failedVersion"],
        recovery_context["finishTargetVersion"],
    }
    previous_version = recovery_context.get("previousVersion")
    if previous_version is not None:
        versions.add(previous_version)
    if current_target is not None:
        versions.add(current_target.name)
    manifests = {
        version: observe_installed_release(releases / version, allowed_signers)
        for version in sorted(versions)
    }

    controlled_units = tuple(
        dict.fromkeys((*BOOT_UNITS, *WATCHDOG_SERVICES, MIGRATION_UNIT))
    )
    units = {unit: observe_recovery_unit(unit) for unit in controlled_units}

    state = {
        "activationFailure": activation_failure,
        "activationInProgress": activation_in_progress,
        "active": active,
        "bootEnablementInProgress": boot_in_progress,
        "current": current,
        "manifests": manifests,
        "paths": {
            "allowedSigners": str(allowed_signers),
            "databaseReceipts": str(RECOVERY_DATABASE_RECEIPTS_DIR),
            "operationLock": str(DEFAULT_LOCK_FILE),
            "releaseBase": str(base),
            "recoveryEvidence": str(RECOVERY_EVIDENCE_DIR),
            "rootState": str(root_state),
        },
        "interruptedContainment": interrupted,
        "recoveryContext": recovery_context,
        "recoveryInProgress": recovery_in_progress,
        "recoveryStorage": {
            "databaseReceipts": observe_root_only_directory(
                RECOVERY_DATABASE_RECEIPTS_DIR
            ),
            "evidence": observe_root_only_directory(RECOVERY_EVIDENCE_DIR),
        },
        "trust": {
            "allowedSignerKeyIds": sorted(key_ids),
            "allowedSignersSha256": release_guard.sha256_file(allowed_signers),
        },
        "units": units,
    }
    return finalize_recovery_assessment(state)


def require_append_only_flyway_transition(
    current_info: dict[str, Any] | None,
    target_info: dict[str, Any],
) -> None:
    """Allow ordinary activation to retain history or append new migrations only."""
    if current_info is None:
        # A genuine first installation has no signed current release to compare. It is
        # governed by the exact-target onboarding gate below and must never use this
        # absence of history as authority to execute the target migration inventory.
        return

    def verified_inventory(
        info: dict[str, Any], label: str
    ) -> tuple[list[dict[str, Any]], int]:
        if not isinstance(info, dict):
            fail(f"{label} signed release metadata is malformed")
        migrations = info.get("flywayMigrations")
        head = info.get("flywayHeadVersion")
        if (
            not isinstance(migrations, list)
            or not migrations
            or any(not isinstance(migration, dict) for migration in migrations)
            or not isinstance(head, str)
            or not head.isdigit()
            or migrations[-1].get("version") != head
        ):
            fail(f"{label} signed Flyway inventory is missing or malformed")
        return migrations, int(head)

    current_migrations, current_head = verified_inventory(current_info, "current")
    target_migrations, target_head = verified_inventory(target_info, "target")
    if target_head < current_head:
        fail("target Flyway head must not decrease during ordinary activation")
    if len(target_migrations) < len(current_migrations):
        fail("target Flyway inventory must not remove signed current migrations")
    for index, current_migration in enumerate(current_migrations):
        if target_migrations[index] != current_migration:
            version = current_migration.get("version", "unknown")
            fail(
                "target Flyway inventory must be an exact append-only extension of "
                f"signed current history; mismatch at V{version}"
            )


def require_initial_database_onboarding_acceptance(
    *,
    target_info: dict[str, Any],
    target_manifest_sha256: str,
    live_evidence: dict[str, Any],
    legacy_retirement: bool,
    approve_database_change: bool,
    expected_activation_reauthorization_sha256: str | None = None,
    allow_expired_for_reauthorization_issue: bool = False,
) -> dict[str, Any]:
    """Accept only the fixed internal-test empty-database commissioner receipt.

    Production and unsigned-legacy onboarding deliberately retain the original hard
    NO-GO.  The receipt is not an operator-authored boolean: it is emitted only after
    the dedicated commissioner validates the same CI-signed target, initializes an
    empty v3-NVMe database, runs the signed migration-only JAR, and records the exact
    live identity while every employee entry remains closed.
    """
    flyway = live_evidence.get("flyway")
    expected_projection = hashlib.sha256(
        canonical_signed_flyway_projection(target_info)
    ).hexdigest()
    if (
        not isinstance(flyway, dict)
        or flyway.get("headVersion") != int(target_info["flywayHeadVersion"])
        or flyway.get("successfulMigrationCount")
        != target_info["flywayMigrationCount"]
        or flyway.get("signedProjectionSha256") != expected_projection
    ):
        fail("first/legacy onboarding live database evidence is not the signed target")
    mode = "unsigned legacy retirement" if legacy_retirement else "first release"
    approval_note = (
        " --approve-database-change records intent only and cannot authorize onboarding."
        if approve_database_change
        else " --approve-database-change would not authorize onboarding."
    )
    if legacy_retirement or deployment_profile() != "internal-test":
        fail(
            f"{mode} database onboarding remains hard NO-GO even though the live database "
            "matches the signed target: the internal-test empty-database receipt is not "
            "valid for production/cloud or unsigned legacy takeover."
            f"{approval_note} Do not handcraft a receipt or run Flyway on this host."
        )
    if approve_database_change:
        fail(
            "--approve-database-change is invalid for exact-target internal-test onboarding"
        )
    runtime_contract, runtime_contract_sha = internal_test_runtime_contract()
    live_database_identity = runtime_database_identity(live_evidence)
    receipt_path = INTERNAL_TEST_ONBOARDING_RECEIPT
    adoption_prepared_at: str | None = None
    adoption_prepared_boot_id: str | None = None
    adoption_prepared_boottime_ns: int | None = None
    adoption: dict[str, Any] | None = None
    if os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION):
        require_root_controlled_file(INTERNAL_TEST_ONBOARDING_ADOPTION, secret=True)
        adoption = strict_json_object(
            read_root_evidence_bytes(INTERNAL_TEST_ONBOARDING_ADOPTION),
            "internal-test onboarding adoption",
        )
        validate_internal_test_onboarding_adoption(
            adoption,
            authenticated_expected_target=target_info,
            live_database_identity=live_database_identity,
        )
        adoption_prepared_at = adoption["preparedAtUtc"]
        adoption_prepared_boot_id = adoption.get("preparedBootId")
        adoption_prepared_boottime_ns = adoption.get("preparedBoottimeNs")
        adopted_reauthorization_sha = adoption.get("reauthorizationSha256")
        if adopted_reauthorization_sha is not None:
            if (
                expected_activation_reauthorization_sha256 is not None
                and expected_activation_reauthorization_sha256
                != adopted_reauthorization_sha
            ):
                fail("activation reauthorization digest differs from prepared adoption")
            expected_activation_reauthorization_sha256 = adopted_reauthorization_sha
        receipt_candidates = [
            path
            for path in (
                INTERNAL_TEST_ONBOARDING_RECEIPT,
                Path(adoption["archivePath"]),
            )
            if os.path.lexists(path)
        ]
        if len(receipt_candidates) != 1:
            fail(
                "prepared adoption requires exactly one live or archived "
                "onboarding receipt"
            )
        receipt_path = receipt_candidates[0]
    require_root_controlled_file(receipt_path, secret=True)
    raw = read_root_evidence_bytes(receipt_path)
    value = strict_json_object(raw, "internal-test onboarding receipt")
    validate_internal_test_onboarding_receipt(
        value,
        adoption_prepared_at_utc=adoption_prepared_at,
        authenticated_expected_target=target_info,
        allow_expired_origin=(
            allow_expired_for_reauthorization_issue
            or expected_activation_reauthorization_sha256 is not None
        ),
    )
    terminal_storage = strict_json_object(
        read_root_evidence_bytes(Path(value["storageObservationPath"])),
        "internal-test terminal storage observation",
    )
    if (
        terminal_storage.get("storageBootVerifierSha256")
        != runtime_contract["storageBootVerifierSha256"]
        or terminal_storage.get("storageValidatorSha256")
        != runtime_contract["storageValidatorSha256"]
        or terminal_storage.get("authoritySha256")
        != runtime_contract["storageAuthoritySha256"]
        or value.get("storageCommissioningReceiptSha256")
        != runtime_contract["storageCompleteReceiptSha256"]
    ):
        fail("internal-test onboarding storage proof differs from the runtime contract")
    manifest = value["manifest"]
    expected_manifest = {
        "commitSha": target_info["commitSha"],
        "flywayHeadVersion": target_info["flywayHeadVersion"],
        "flywayMigrationSetSha256": target_info["flywayMigrationSetSha256"],
        "signedFlywayProjectionSha256": expected_projection,
        "manifestSha256": target_manifest_sha256,
        "migratorJarSha256": target_info["executableSha256s"][
            "server/uten-imp-migrator.jar"
        ],
        "releaseSequence": target_info["releaseSequence"],
        "serverJarSha256": target_info["executableSha256s"][
            "server/uten-imp-server.jar"
        ],
        "signingKeyId": target_info["signingKeyId"],
        "version": target_info["version"],
    }
    # The manifest digest is checked against signed candidate bytes by the caller
    # before this function.  Keep it in the exact comparison while avoiding a
    # second path parameter in this narrow policy function.
    if any(manifest.get(key) != expected for key, expected in expected_manifest.items()):
        fail("internal-test onboarding receipt differs from the signed target")
    if value.get("databaseIdentity") != live_database_identity:
        fail("internal-test onboarding receipt differs from the live database identity")
    if value.get("runtimeContractSha256") != runtime_contract_sha:
        fail("internal-test onboarding receipt names another runtime contract")
    if value.get("commissionerSha256") != runtime_contract["databaseCommissionerSha256"]:
        fail("internal-test onboarding receipt was not emitted by the pinned commissioner")
    if value.get("storageAuthoritySha256") != release_guard.sha256_file(
        STORAGE_AUTHORITY
    ):
        fail("internal-test onboarding receipt names another storage authority")
    if runtime_contract.get("deploymentProfile") != "internal-test-local-v1":
        fail("internal-test runtime contract profile changed")
    if adoption_prepared_at is None:
        authorization_reference_time = datetime.now(timezone.utc)
    else:
        authorization_reference_time = datetime.strptime(
            adoption_prepared_at, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
    requires_reauthorization = (
        value.get("status") == "EXPIRED_AWAITING_REAUTH"
        or authorization_reference_time > internal_test_onboarding_expiry(value)
    )
    reauthorization: dict[str, Any] | None = None
    if allow_expired_for_reauthorization_issue:
        if expected_activation_reauthorization_sha256 is not None:
            fail("reauthorization issuance must not accept an existing authority digest")
        if not requires_reauthorization:
            fail("onboarding remains valid and must not be reauthorized")
    elif requires_reauthorization:
        if expected_activation_reauthorization_sha256 is None:
            fail(
                "expired internal-test onboarding requires an exact activation "
                "reauthorization digest"
            )
        if adoption is None:
            reauthorization_path = INTERNAL_TEST_ACTIVATION_REAUTHORIZATION
        else:
            reauthorization_candidates = [
                path
                for path in (
                    INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
                    Path(adoption["reauthorizationArchivePath"]),
                )
                if os.path.lexists(path)
            ]
            if len(reauthorization_candidates) != 1:
                fail(
                    "prepared adoption requires exactly one live or archived "
                    "activation reauthorization"
                )
            reauthorization_path = reauthorization_candidates[0]
        reauthorization = load_internal_test_activation_reauthorization(
            path=reauthorization_path,
            expected_sha256=expected_activation_reauthorization_sha256,
            onboarding=value,
            onboarding_receipt_path=receipt_path,
            authenticated_expected_target=target_info,
            live_database_identity=live_database_identity,
            runtime_contract_sha256=runtime_contract_sha,
            prepared_at_utc=adoption_prepared_at,
            prepared_boot_id=adoption_prepared_boot_id,
            prepared_boottime_ns=adoption_prepared_boottime_ns,
        )
    elif (
        expected_activation_reauthorization_sha256 is not None
        or os.path.lexists(INTERNAL_TEST_ACTIVATION_REAUTHORIZATION)
    ):
        fail("activation reauthorization is invalid while onboarding remains current")
    return {
        "fields": value,
        "path": str(receipt_path),
        "reauthorization": reauthorization,
        "reauthorizationRequired": requires_reauthorization,
        "runtimeContract": runtime_contract,
        "runtimeContractSha256": runtime_contract_sha,
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def validate_internal_test_storage_observation(
    *,
    path_value: Any,
    sha_value: Any,
    evidence_root: Path,
    transaction_id: str,
    phase: str,
) -> dict[str, Any]:
    path = Path(
        release_guard.require_string(path_value, "internal-test storage observation path")
    )
    expected_name = re.compile(
        rf"storage-{re.escape(phase)}-{BOOT_ID_RE.pattern}-[1-9][0-9]*\.json"
    )
    if path.parent != evidence_root or not expected_name.fullmatch(path.name):
        fail("internal-test storage observation escaped its fixed transaction")
    digest = require_recovery_sha256(
        sha_value, "internal-test storage observation digest"
    )
    require_root_controlled_file(path, secret=True)
    details = path.lstat()
    if details.st_gid != 0 or details.st_nlink != 1 or stat.S_IMODE(details.st_mode) != 0o600:
        fail("internal-test storage observation must be root:root mode 0600")
    raw = read_root_evidence_bytes(path)
    if hashlib.sha256(raw).hexdigest() != digest:
        fail("internal-test storage observation digest changed")
    observation = strict_json_object(raw, "internal-test storage observation")
    release_guard.exact_keys(
        observation,
        {
            "authorityCommissioningEvidenceSha256",
            "authoritySha256",
            "bootId",
            "filesystemUuid",
            "findmntOutputSha256",
            "kind",
            "mountedSourceRdev",
            "phase",
            "schemaVersion",
            "sequence",
            "storageBootVerifierOutputSha256",
            "storageBootVerifierSha256",
            "storageCommissioningPlanSha256",
            "storageCommissioningReceiptSha256",
            "storageValidatorOutputSha256",
            "storageValidatorSha256",
            "transactionId",
            "verifiedAtUtc",
        },
        "internal-test storage observation",
    )
    if (
        observation.get("schemaVersion") != 1
        or isinstance(observation.get("schemaVersion"), bool)
        or observation.get("kind")
        != "uten-imp-internal-test-live-storage-observation"
        or observation.get("transactionId") != transaction_id
        or observation.get("phase") != phase
    ):
        fail("internal-test storage observation identity differs")
    release_guard.require_string(observation.get("bootId"), "storage boot ID", BOOT_ID_RE)
    release_guard.require_string(
        observation.get("filesystemUuid"), "storage filesystem UUID", UUID_RE
    )
    release_guard.require_string(
        observation.get("mountedSourceRdev"),
        "storage mounted device identity",
        re.compile(r"[0-9]+:[0-9]+"),
    )
    require_recovery_integer(
        observation.get("sequence"), "storage observation sequence", minimum=1
    )
    require_recovery_timestamp(
        observation.get("verifiedAtUtc"), "storage observation verification time"
    )
    for key in (
        "authorityCommissioningEvidenceSha256",
        "authoritySha256",
        "findmntOutputSha256",
        "storageBootVerifierOutputSha256",
        "storageBootVerifierSha256",
        "storageCommissioningPlanSha256",
        "storageCommissioningReceiptSha256",
        "storageValidatorOutputSha256",
        "storageValidatorSha256",
    ):
        require_recovery_sha256(observation.get(key), f"storage observation {key}")
    return observation


def validate_internal_test_commissioning_candidate_paths(
    evidence_root: Path,
    transaction_manifest: dict[str, Any],
    version: str,
) -> tuple[Path, Path]:
    """Resolve the commissioner's one reviewed candidate generation."""

    candidate_metadata = Path(
        release_guard.require_string(
            transaction_manifest.get("candidateMetadataPath"),
            "internal-test commissioning candidate metadata path",
        )
    )
    candidate_payload = Path(
        release_guard.require_string(
            transaction_manifest.get("candidatePayloadPath"),
            "internal-test commissioning candidate payload path",
        )
    )
    build = candidate_metadata.parent
    if (
        build.parent != evidence_root
        or not re.fullmatch(r"candidate-build-[1-9][0-9]*", build.name)
        or candidate_metadata.name != "candidate-metadata"
        or candidate_payload.parent != build / "payload"
        or candidate_payload.name != version
    ):
        fail("internal-test commissioning candidate escaped its fixed build generation")
    return candidate_metadata, candidate_payload


def internal_test_candidate_manifest_binding(
    candidate_info: dict[str, Any], manifest_sha256: str
) -> dict[str, Any]:
    """Project authenticated candidate metadata into the onboarding authority."""

    require_recovery_sha256(
        manifest_sha256, "internal-test commissioning candidate manifest"
    )
    return {
        "commitSha": candidate_info["commitSha"],
        "flywayHeadVersion": candidate_info["flywayHeadVersion"],
        "flywayMigrationSetSha256": candidate_info["flywayMigrationSetSha256"],
        "manifestSha256": manifest_sha256,
        "migratorJarSha256": candidate_info["executableSha256s"][
            "server/uten-imp-migrator.jar"
        ],
        "releaseSequence": candidate_info["releaseSequence"],
        "serverJarSha256": candidate_info["executableSha256s"][
            "server/uten-imp-server.jar"
        ],
        "signingKeyId": candidate_info["signingKeyId"],
        "signedFlywayProjectionSha256": hashlib.sha256(
            canonical_signed_flyway_projection(candidate_info)
        ).hexdigest(),
        "version": candidate_info["version"],
    }


def internal_test_onboarding_expiry(value: dict[str, Any]) -> datetime:
    expires_at = require_recovery_timestamp(
        value.get("expiresAtUtc"), "internal-test onboarding expiry time"
    )
    try:
        return datetime.strptime(expires_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise UpdaterError("internal-test onboarding expiry is malformed") from exc


def internal_test_reauthorization_archive_path(transaction_id: str) -> Path:
    if not INTERNAL_TEST_TRANSACTION_RE.fullmatch(transaction_id):
        fail("activation reauthorization transaction ID is malformed")
    return INTERNAL_TEST_ACTIVATION_REAUTHORIZATION_EVIDENCE_DIR / (
        transaction_id + ".json"
    )


def require_internal_test_reauthorization_evidence_directory(
    *, create: bool
) -> None:
    path = INTERNAL_TEST_ACTIVATION_REAUTHORIZATION_EVIDENCE_DIR
    if not os.path.lexists(path):
        if not create:
            fail("activation reauthorization evidence directory is missing")
        os.mkdir(path, 0o700)
        os.chown(path, 0, 0)
        fsync_directory(path.parent)
    require_real_directory(path, owner_uid=0)
    details = path.lstat()
    if details.st_gid != 0 or stat.S_IMODE(details.st_mode) != 0o700:
        fail("activation reauthorization evidence directory must be root:root mode 0700")


def validate_internal_test_activation_reauthorization(
    value: dict[str, Any],
    *,
    onboarding: dict[str, Any],
    authenticated_expected_target: dict[str, Any],
    live_database_identity: dict[str, Any],
    runtime_contract_sha256: str,
    onboarding_receipt_path: Path = INTERNAL_TEST_ONBOARDING_RECEIPT,
    prepared_at_utc: str | None = None,
    prepared_boot_id: str | None = None,
    prepared_boottime_ns: int | None = None,
) -> str:
    """Validate the one-hour, activation-only renewal of an expired origin."""

    release_guard.exact_keys(
        value,
        {
            "approvalReference", "authorizedAtUtc", "authorizedBoottimeNs",
            "bootId", "candidateManifestSha256", "commissioningAuthorityPath",
            "commissioningAuthoritySha256", "completePath", "completeSha256",
            "databaseIdentity", "databaseIdentitySha256", "entryEnabled",
            "expiresAtUtc", "expiresBoottimeNs", "hostPreparationActivePath",
            "hostPreparationActiveSha256", "kind", "nonce", "onboardingPath",
            "onboardingSha256", "productionAuthority", "runtimeContractSha256",
            "schemaVersion", "status", "storageAuthoritySha256",
            "storageObservationSha256", "transactionId", "version",
        },
        "internal-test activation reauthorization",
    )
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("kind")
        != "uten-imp-internal-test-activation-reauthorization"
        or value.get("status") != "AUTHORIZED_ACTIVATION_ONLY_ENTRY_CLOSED"
        or value.get("entryEnabled") is not False
        or value.get("productionAuthority") is not False
        or onboarding.get("status") not in {
            "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
            "EXPIRED_AWAITING_REAUTH",
        }
        or value.get("transactionId") != onboarding.get("transactionId")
        or value.get("version") != onboarding.get("manifest", {}).get("version")
        or value.get("candidateManifestSha256")
        != onboarding.get("manifest", {}).get("manifestSha256")
        or value.get("databaseIdentity") != onboarding.get("databaseIdentity")
        or value.get("databaseIdentity") != live_database_identity
        or value.get("runtimeContractSha256") != runtime_contract_sha256
        or value.get("runtimeContractSha256")
        != onboarding.get("runtimeContractSha256")
        or value.get("storageAuthoritySha256")
        != onboarding.get("storageAuthoritySha256")
        or value.get("storageObservationSha256")
        != onboarding.get("storageObservationSha256")
    ):
        fail("activation reauthorization differs from the expired onboarding origin")
    approval = release_guard.require_string(
        value.get("approvalReference"), "activation reauthorization approval"
    )
    if not INTERNAL_TEST_APPROVAL_RE.fullmatch(approval):
        fail("activation reauthorization approval is malformed")
    nonce = release_guard.require_string(
        value.get("nonce"), "activation reauthorization nonce"
    )
    if re.fullmatch(r"[0-9a-f]{32}", nonce) is None:
        fail("activation reauthorization nonce is malformed")
    for key in (
        "candidateManifestSha256", "commissioningAuthoritySha256",
        "completeSha256", "databaseIdentitySha256",
        "hostPreparationActiveSha256", "onboardingSha256",
        "runtimeContractSha256", "storageAuthoritySha256",
        "storageObservationSha256",
    ):
        require_recovery_sha256(value.get(key), f"activation reauthorization {key}")
    if hashlib.sha256(
        (json.dumps(live_database_identity, sort_keys=True, indent=2) + "\n").encode()
    ).hexdigest() != value["databaseIdentitySha256"]:
        fail("activation reauthorization database identity digest differs")
    if value.get("onboardingPath") != str(INTERNAL_TEST_ONBOARDING_RECEIPT):
        fail("activation reauthorization onboardingPath escaped its fixed path")
    expected_files = {
        "commissioningAuthorityPath": (
            Path(onboarding["commissioningAuthorityPath"]),
            "commissioningAuthoritySha256",
        ),
        "completePath": (
            Path(onboarding["evidencePath"]) / "complete.json",
            "completeSha256",
        ),
        "hostPreparationActivePath": (
            Path("/var/lib/uten-imp-internal-test-host-preparation/active.json"),
            "hostPreparationActiveSha256",
        ),
    }
    for path_key, (expected_path, sha_key) in expected_files.items():
        actual = Path(
            release_guard.require_string(value.get(path_key), path_key)
        )
        if actual != expected_path:
            fail(f"activation reauthorization {path_key} escaped its fixed path")
        require_root_controlled_file(actual, secret=True)
        if release_guard.sha256_file(actual) != value[sha_key]:
            fail(f"activation reauthorization evidence changed: {actual}")
    if onboarding_receipt_path not in {
        INTERNAL_TEST_ONBOARDING_RECEIPT,
        INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR
        / (str(onboarding.get("transactionId", "")) + ".json"),
    }:
        fail("activation reauthorization onboarding evidence escaped its fixed lineage")
    require_root_controlled_file(onboarding_receipt_path, secret=True)
    origin_raw = read_root_evidence_bytes(onboarding_receipt_path)
    if hashlib.sha256(origin_raw).hexdigest() != value["onboardingSha256"]:
        fail("activation reauthorization onboarding bytes changed")
    expected_binding = internal_test_candidate_manifest_binding(
        authenticated_expected_target,
        value["candidateManifestSha256"],
    )
    if expected_binding != onboarding.get("manifest"):
        fail("activation reauthorization names another signed candidate")
    try:
        authorized = datetime.strptime(
            require_recovery_timestamp(
                value.get("authorizedAtUtc"), "reauthorization time"
            ),
            "%Y-%m-%dT%H:%M:%SZ",
        ).replace(tzinfo=timezone.utc)
        expires = datetime.strptime(
            require_recovery_timestamp(
                value.get("expiresAtUtc"), "reauthorization expiry"
            ),
            "%Y-%m-%dT%H:%M:%SZ",
        ).replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise UpdaterError(
            "activation reauthorization validity timestamp is malformed"
        ) from exc
    authorized_boot = require_recovery_integer(
        value.get("authorizedBoottimeNs"), "reauthorization boottime", minimum=0
    )
    expires_boot = require_recovery_integer(
        value.get("expiresBoottimeNs"), "reauthorization expiry boottime", minimum=1
    )
    boot_id = release_guard.require_string(value.get("bootId"), "reauthorization boot")
    onboarding_expiry = internal_test_onboarding_expiry(onboarding)
    try:
        completed = datetime.strptime(
            require_recovery_timestamp(
                onboarding.get("completedAtUtc"),
                "internal-test onboarding completion time",
            ),
            "%Y-%m-%dT%H:%M:%SZ",
        ).replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise UpdaterError(
            "internal-test onboarding completion is malformed"
        ) from exc
    if (
        not BOOT_ID_RE.fullmatch(boot_id)
        or authorized < onboarding_expiry
        or authorized < completed
        or expires <= authorized
        or expires > authorized + timedelta(hours=1)
        or expires_boot <= authorized_boot
        or expires_boot > authorized_boot + 3600 * 1_000_000_000
    ):
        fail("activation reauthorization validity window is malformed")
    if prepared_at_utc is None:
        now = datetime.now(timezone.utc)
        if (
            current_boot_id() != boot_id
            or not authorized <= now <= expires
            or not authorized_boot <= current_boottime_ns() <= expires_boot
        ):
            fail("activation reauthorization is expired or from another boot")
    else:
        try:
            prepared = datetime.strptime(
                require_recovery_timestamp(
                    prepared_at_utc, "reauthorization adoption time"
                ),
                "%Y-%m-%dT%H:%M:%SZ",
            ).replace(tzinfo=timezone.utc)
        except ValueError as exc:
            raise UpdaterError(
                "activation reauthorization adoption timestamp is malformed"
            ) from exc
        if (
            prepared_boot_id != boot_id
            or prepared_boottime_ns is None
            or not authorized <= prepared <= expires
            or not authorized_boot <= prepared_boottime_ns <= expires_boot
        ):
            fail("activation reauthorization was not adopted inside its validity window")
    return "internal-test-activation-reauthorization-v1"


def load_internal_test_activation_reauthorization(
    *,
    path: Path,
    expected_sha256: str,
    onboarding: dict[str, Any],
    onboarding_receipt_path: Path,
    authenticated_expected_target: dict[str, Any],
    live_database_identity: dict[str, Any],
    runtime_contract_sha256: str,
    prepared_at_utc: str | None = None,
    prepared_boot_id: str | None = None,
    prepared_boottime_ns: int | None = None,
) -> dict[str, Any]:
    expected_sha256 = require_recovery_sha256(
        expected_sha256, "activation reauthorization digest"
    )
    archive = internal_test_reauthorization_archive_path(onboarding["transactionId"])
    if path not in {INTERNAL_TEST_ACTIVATION_REAUTHORIZATION, archive}:
        fail("activation reauthorization escaped its fixed live/archive path")
    require_root_controlled_file(path, secret=True)
    raw = read_root_evidence_bytes(path)
    actual_sha256 = hashlib.sha256(raw).hexdigest()
    if actual_sha256 != expected_sha256:
        fail("activation reauthorization digest changed")
    fields = strict_json_object(raw, "internal-test activation reauthorization")
    validate_internal_test_activation_reauthorization(
        fields,
        onboarding=onboarding,
        onboarding_receipt_path=onboarding_receipt_path,
        authenticated_expected_target=authenticated_expected_target,
        live_database_identity=live_database_identity,
        runtime_contract_sha256=runtime_contract_sha256,
        prepared_at_utc=prepared_at_utc,
        prepared_boot_id=prepared_boot_id,
        prepared_boottime_ns=prepared_boottime_ns,
    )
    return {
        "fields": fields,
        "path": str(path),
        "sha256": actual_sha256,
    }


def issue_internal_test_activation_reauthorization(
    *,
    onboarding_receipt: dict[str, Any],
    authenticated_expected_target: dict[str, Any],
    live_database_identity: dict[str, Any],
    runtime_contract_sha256: str,
    approval_reference: str,
) -> dict[str, Any]:
    """Publish one activation-only grant for an expired, unadopted onboarding."""

    if deployment_profile() != "internal-test":
        fail("activation reauthorization is valid only for the internal-test profile")
    if not INTERNAL_TEST_APPROVAL_RE.fullmatch(approval_reference):
        fail("activation reauthorization approval is malformed")
    onboarding = onboarding_receipt.get("fields")
    if (
        not isinstance(onboarding, dict)
        or onboarding_receipt.get("path") != str(INTERNAL_TEST_ONBOARDING_RECEIPT)
        or onboarding.get("manifest", {}).get("version")
        != authenticated_expected_target.get("version")
    ):
        fail("activation reauthorization requires the live matching onboarding origin")
    if datetime.now(timezone.utc) <= internal_test_onboarding_expiry(onboarding):
        fail("activation reauthorization is invalid while onboarding remains current")
    for forbidden in (
        DEFAULT_ROOT_STATE_DIR / "active.json",
        RUNTIME_AUTHORITY,
        INTERNAL_TEST_ONBOARDING_ADOPTION,
        DEFAULT_RELEASE_BASE / "current",
    ):
        if os.path.lexists(forbidden):
            fail("activation reauthorization requires an unadopted first activation")

    archive = internal_test_reauthorization_archive_path(onboarding["transactionId"])
    if os.path.lexists(archive):
        require_root_controlled_file(archive, secret=True)
        fail("activation reauthorization was already consumed for this onboarding")

    if os.path.lexists(INTERNAL_TEST_ACTIVATION_REAUTHORIZATION):
        existing_raw = read_root_evidence_bytes(
            INTERNAL_TEST_ACTIVATION_REAUTHORIZATION
        )
        existing_sha = hashlib.sha256(existing_raw).hexdigest()
        existing = load_internal_test_activation_reauthorization(
            path=INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
            expected_sha256=existing_sha,
            onboarding=onboarding,
            onboarding_receipt_path=INTERNAL_TEST_ONBOARDING_RECEIPT,
            authenticated_expected_target=authenticated_expected_target,
            live_database_identity=live_database_identity,
            runtime_contract_sha256=runtime_contract_sha256,
        )
        if existing["fields"].get("approvalReference") != approval_reference:
            fail("another activation reauthorization is already active")
        require_internal_test_reauthorization_evidence_directory(create=True)
        return existing

    authorized_at = datetime.now(timezone.utc).replace(microsecond=0)
    expires_at = authorized_at + timedelta(hours=1)
    authorized_boottime_ns = current_boottime_ns()
    boot_id = current_boot_id()
    commissioning_authority = Path(onboarding["commissioningAuthorityPath"])
    complete = Path(onboarding["evidencePath"]) / "complete.json"
    host_preparation_active = Path(
        "/var/lib/uten-imp-internal-test-host-preparation/active.json"
    )
    value = {
        "approvalReference": approval_reference,
        "authorizedAtUtc": authorized_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "authorizedBoottimeNs": authorized_boottime_ns,
        "bootId": boot_id,
        "candidateManifestSha256": onboarding["manifest"]["manifestSha256"],
        "commissioningAuthorityPath": str(commissioning_authority),
        "commissioningAuthoritySha256": release_guard.sha256_file(
            commissioning_authority
        ),
        "completePath": str(complete),
        "completeSha256": release_guard.sha256_file(complete),
        "databaseIdentity": live_database_identity,
        "databaseIdentitySha256": hashlib.sha256(
            (json.dumps(live_database_identity, sort_keys=True, indent=2) + "\n").encode()
        ).hexdigest(),
        "entryEnabled": False,
        "expiresAtUtc": expires_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresBoottimeNs": authorized_boottime_ns + 3600 * 1_000_000_000,
        "hostPreparationActivePath": str(host_preparation_active),
        "hostPreparationActiveSha256": release_guard.sha256_file(
            host_preparation_active
        ),
        "kind": "uten-imp-internal-test-activation-reauthorization",
        "nonce": secrets.token_hex(16),
        "onboardingPath": str(INTERNAL_TEST_ONBOARDING_RECEIPT),
        "onboardingSha256": onboarding_receipt["sha256"],
        "productionAuthority": False,
        "runtimeContractSha256": runtime_contract_sha256,
        "schemaVersion": 1,
        "status": "AUTHORIZED_ACTIVATION_ONLY_ENTRY_CLOSED",
        "storageAuthoritySha256": onboarding["storageAuthoritySha256"],
        "storageObservationSha256": onboarding["storageObservationSha256"],
        "transactionId": onboarding["transactionId"],
        "version": authenticated_expected_target["version"],
    }
    validate_internal_test_activation_reauthorization(
        value,
        onboarding=onboarding,
        onboarding_receipt_path=INTERNAL_TEST_ONBOARDING_RECEIPT,
        authenticated_expected_target=authenticated_expected_target,
        live_database_identity=live_database_identity,
        runtime_contract_sha256=runtime_contract_sha256,
    )
    require_internal_test_reauthorization_evidence_directory(create=True)
    atomic_json(INTERNAL_TEST_ACTIVATION_REAUTHORIZATION, value, mode=0o600)
    raw = read_root_evidence_bytes(INTERNAL_TEST_ACTIVATION_REAUTHORIZATION)
    return load_internal_test_activation_reauthorization(
        path=INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
        expected_sha256=hashlib.sha256(raw).hexdigest(),
        onboarding=onboarding,
        onboarding_receipt_path=INTERNAL_TEST_ONBOARDING_RECEIPT,
        authenticated_expected_target=authenticated_expected_target,
        live_database_identity=live_database_identity,
        runtime_contract_sha256=runtime_contract_sha256,
    )


def validate_internal_test_database_worker_terminal(
    onboarding: dict[str, Any],
    *,
    evidence_root: Path,
    database_commissioning_root: Path,
) -> str:
    """Validate the v2 fixed-cgroup request and its terminal receipt.

    The commissioner validates ``bootId`` against the live boot before any
    database write.  Activation may legitimately happen after a reboot, so the
    terminal consumer preserves and format-checks that issuer boot rather than
    comparing it with the activation boot.  The archived request is still bound
    byte-for-byte to the worker completion receipt, onboarding receipt and
    transaction, while the reviewed runtime contract and unit bytes are checked
    again at adoption time.
    """

    request_path = evidence_root / "worker-request.committed.json"
    worker_complete_path = evidence_root / "worker-complete.json"
    if os.path.lexists(database_commissioning_root / "worker-request.json"):
        fail("internal-test database commissioner worker is not terminal")
    for terminal_path in (request_path, worker_complete_path):
        require_root_controlled_file(terminal_path, secret=True)
        terminal_details = terminal_path.lstat()
        if (
            terminal_details.st_gid != 0
            or terminal_details.st_nlink != 1
            or stat.S_IMODE(terminal_details.st_mode) != 0o600
        ):
            fail("internal-test database worker evidence metadata differs")

    request_raw = read_root_evidence_bytes(request_path)
    worker_request = strict_json_object(
        request_raw,
        "internal-test database worker request",
    )
    release_guard.exact_keys(
        worker_request,
        {
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
        },
        "internal-test database worker request",
    )
    if (
        type(worker_request.get("schemaVersion")) is not int
        or worker_request.get("schemaVersion") != 2
    ):
        fail("internal-test database worker request schema differs")
    approval = release_guard.require_string(
        onboarding.get("approvalReference"),
        "internal-test onboarding approval",
        INTERNAL_TEST_APPROVAL_RE,
    )
    manifest = onboarding.get("manifest")
    if not isinstance(manifest, dict):
        fail("internal-test onboarding manifest binding is malformed")
    version = release_guard.require_string(
        manifest.get("version"),
        "internal-test onboarding version",
        INTERNAL_TEST_VERSION_RE,
    )
    boot_id = release_guard.require_string(
        worker_request.get("bootId"),
        "internal-test database worker issuer boot ID",
        BOOT_ID_RE,
    )
    runtime_contract, runtime_contract_sha256 = internal_test_runtime_contract()
    require_recovery_sha256(
        runtime_contract_sha256,
        "live internal-test runtime contract digest",
    )
    if onboarding.get("runtimeContractSha256") != runtime_contract_sha256:
        fail("internal-test database worker names another runtime contract")
    unit_pin = release_guard.require_string(
        runtime_contract.get("databaseCommissionerUnitSha256"),
        "internal-test database commissioner unit pin",
        release_guard.SHA256_RE,
    )
    live_unit = read_root_controlled_bytes(
        INTERNAL_TEST_DB_COMMISSIONER_UNIT_FILE,
        exact_mode=0o644,
        maximum_bytes=256 * 1024,
    )
    live_unit_sha256 = hashlib.sha256(live_unit).hexdigest()
    if not secrets.compare_digest(live_unit_sha256, unit_pin):
        fail("internal-test database commissioner unit changed after review")

    request_core = {
        "approvalReference": approval,
        "bootId": boot_id,
        "controlGroup": INTERNAL_TEST_DB_COMMISSIONER_CONTROL_GROUP,
        "kind": "uten-imp-internal-test-db-worker-request",
        "runtimeContractSha256": runtime_contract_sha256,
        "schemaVersion": 2,
        "status": "AUTHORIZED_FIXED_CGROUP",
        "systemdUnit": INTERNAL_TEST_DB_COMMISSIONER_UNIT,
        "unitSha256": unit_pin,
        "version": version,
    }
    expected_request_id = hashlib.sha256(
        (json.dumps(request_core, sort_keys=True, indent=2) + "\n").encode(
            "utf-8"
        )
    ).hexdigest()[:32]
    if worker_request != {**request_core, "requestId": expected_request_id}:
        fail(
            "internal-test database worker request differs from onboarding, "
            "runtime authority, or fixed execution boundary"
        )

    worker_complete = strict_json_object(
        read_root_evidence_bytes(worker_complete_path),
        "internal-test database worker completion receipt",
    )
    release_guard.exact_keys(
        worker_complete,
        {
            "kind",
            "onboardingReceiptSha256",
            "requestSha256",
            "schemaVersion",
            "status",
            "transactionId",
        },
        "internal-test database worker completion receipt",
    )
    onboarding_sha256 = hashlib.sha256(
        (
            json.dumps(onboarding, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n"
        ).encode("utf-8")
    ).hexdigest()
    request_sha256 = hashlib.sha256(request_raw).hexdigest()
    if (
        type(worker_complete.get("schemaVersion")) is not int
        or worker_complete.get("schemaVersion") != 1
        or worker_complete.get("kind")
        != "uten-imp-internal-test-db-worker-receipt"
        or worker_complete.get("status") != "FIXED_CGROUP_COMPLETED"
        or worker_complete.get("transactionId") != onboarding.get("transactionId")
        or worker_complete.get("onboardingReceiptSha256") != onboarding_sha256
        or worker_complete.get("requestSha256") != request_sha256
    ):
        fail("internal-test database worker completion receipt differs")
    return request_sha256


def validate_internal_test_onboarding_receipt(
    value: dict[str, Any], *, require_worker_terminal: bool = True,
    adoption_prepared_at_utc: str | None = None,
    authenticated_expected_target: dict[str, Any] | None = None,
    allow_expired_origin: bool = False,
) -> str:
    release_guard.exact_keys(
        value,
        {
            "approvalReference",
            "backupEnabled",
            "commissionerSha256",
            "commissioningAuthorityPath",
            "commissioningAuthoritySha256",
            "commissioningAuthorizedAtUtc",
            "commissioningPlanExpiresAtUtc",
            "commissioningPreActivePath",
            "commissioningPreActiveSha256",
            "completedAtUtc",
            "currentPublished",
            "dataClassification",
            "databaseIdentity",
            "deploymentProfile",
            "entryEnabled",
            "evidencePath",
            "emptySourceProofPath",
            "emptySourceProofSha256",
            "expiresAtUtc",
            "kind",
            "manifest",
            "migrationTerminalReceiptPath",
            "migrationTerminalReceiptSha256",
            "runtimeContractSha256",
            "productionAuthority",
            "remainingNoGo",
            "schemaVersion",
            "status",
            "storageAuthoritySha256",
            "storageCommissioningEvidencePath",
            "storageCommissioningReceiptPath",
            "storageCommissioningReceiptSha256",
            "storageObservationPath",
            "storageObservationSha256",
            "transactionManifestPath",
            "transactionManifestSha256",
            "transactionId",
        },
        "internal-test onboarding receipt",
    )
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("kind") != "uten-imp-internal-test-onboarding"
        or value.get("status") not in {
            "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
            "EXPIRED_AWAITING_REAUTH",
        }
        or value.get("deploymentProfile") != "internal-test"
        or value.get("entryEnabled") is not False
        or value.get("backupEnabled") is not False
        or value.get("currentPublished") is not False
        or value.get("dataClassification") != "discardable-test-only"
        or value.get("productionAuthority") is not False
        or value.get("remainingNoGo")
        != ["authoritative-data", "backup-restore", "business-uat"]
    ):
        fail("internal-test onboarding receipt status/profile boundary differs")
    transaction_id = release_guard.require_string(
        value.get("transactionId"), "internal-test onboarding transaction"
    )
    if not INTERNAL_TEST_TRANSACTION_RE.fullmatch(transaction_id):
        fail("internal-test onboarding transaction ID is malformed")
    approval = release_guard.require_string(
        value.get("approvalReference"), "internal-test onboarding approval"
    )
    if not INTERNAL_TEST_APPROVAL_RE.fullmatch(approval):
        fail("internal-test onboarding approval reference is malformed")
    completed_at = require_recovery_timestamp(
        value.get("completedAtUtc"), "internal-test onboarding completion time"
    )
    expires_at = require_recovery_timestamp(
        value.get("expiresAtUtc"), "internal-test onboarding expiry time"
    )
    try:
        expiry = datetime.strptime(expires_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise UpdaterError("internal-test onboarding expiry is malformed") from exc
    try:
        completed = datetime.strptime(completed_at, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise UpdaterError("internal-test onboarding completion is malformed") from exc
    expired_at_completion = completed >= expiry
    if (
        (value.get("status") == "EXPIRED_AWAITING_REAUTH")
        != expired_at_completion
    ):
        fail("internal-test onboarding status differs from its expiry chronology")
    if adoption_prepared_at_utc is None:
        if datetime.now(timezone.utc) > expiry and not allow_expired_origin:
            fail("internal-test onboarding receipt expired before first activation")
    else:
        prepared_at = require_recovery_timestamp(
            adoption_prepared_at_utc, "internal-test onboarding adoption time"
        )
        try:
            prepared = datetime.strptime(
                prepared_at, "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)
        except ValueError as exc:
            raise UpdaterError("internal-test onboarding adoption is malformed") from exc
        if allow_expired_origin:
            if prepared < completed:
                fail("internal-test onboarding adoption predates database completion")
        elif not completed <= prepared <= expiry:
            fail("internal-test onboarding was not adopted inside its validity window")
    for key in (
        "commissionerSha256",
        "commissioningAuthoritySha256",
        "commissioningPreActiveSha256",
        "emptySourceProofSha256",
        "migrationTerminalReceiptSha256",
        "runtimeContractSha256",
        "storageAuthoritySha256",
        "storageCommissioningReceiptSha256",
        "storageObservationSha256",
        "transactionManifestSha256",
    ):
        require_recovery_sha256(value.get(key), f"internal-test onboarding {key}")
    evidence_path = release_guard.require_string(
        value.get("evidencePath"), "internal-test onboarding evidence path"
    )
    if evidence_path != (
        "/var/lib/uten-imp-internal-test-commissioning/" + transaction_id
    ):
        fail("internal-test onboarding evidence escaped its fixed transaction path")
    storage_evidence = release_guard.require_string(
        value.get("storageCommissioningEvidencePath"),
        "storage commissioning evidence path",
    )
    if not re.fullmatch(
        r"/var/lib/uten-imp-nvme-commissioning/nvme-[0-9TZ-]+-[0-9a-f]{12}",
        storage_evidence,
    ):
        fail("storage commissioning evidence path is not canonical")
    evidence_root = Path(evidence_path)
    database_commissioning_root = evidence_root.parent
    if (
        os.path.lexists(database_commissioning_root / "active.json")
        or os.path.lexists(database_commissioning_root / "pre-active.json")
    ):
        fail("internal-test database commissioning is not terminal")
    terminal_storage_observation = validate_internal_test_storage_observation(
        path_value=value.get("storageObservationPath"),
        sha_value=value.get("storageObservationSha256"),
        evidence_root=evidence_root,
        transaction_id=transaction_id,
        phase="before-terminal",
    )
    fixed_evidence_files = {
        "commissioningAuthorityPath": (
            evidence_root / "commissioning-authorized.json",
            "commissioningAuthoritySha256",
        ),
        "commissioningPreActivePath": (
            evidence_root / "pre-active.committed.json",
            "commissioningPreActiveSha256",
        ),
        "emptySourceProofPath": (
            evidence_root / "empty-source-proof.json",
            "emptySourceProofSha256",
        ),
        "migrationTerminalReceiptPath": (
            evidence_root / "migration-terminal.json",
            "migrationTerminalReceiptSha256",
        ),
        "transactionManifestPath": (
            evidence_root / "transaction-manifest.json",
            "transactionManifestSha256",
        ),
        "storageCommissioningReceiptPath": (
            Path(storage_evidence) / "complete.json",
            "storageCommissioningReceiptSha256",
        ),
    }
    for path_key, (expected_path, sha_key) in fixed_evidence_files.items():
        actual_path = Path(
            release_guard.require_string(
                value.get(path_key), f"internal-test onboarding {path_key}"
            )
        )
        if actual_path != expected_path:
            fail(f"internal-test onboarding {path_key} escaped its fixed path")
        require_root_controlled_file(actual_path, secret=True)
        details = actual_path.lstat()
        if details.st_gid != 0 or details.st_nlink != 1 or stat.S_IMODE(details.st_mode) != 0o600:
            fail(f"internal-test onboarding evidence must be root:root mode 0600: {actual_path}")
        if release_guard.sha256_file(actual_path) != value[sha_key]:
            fail(f"internal-test onboarding evidence digest changed: {actual_path}")
    onboarding_sha = hashlib.sha256(
        (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
            "utf-8"
        )
    ).hexdigest()
    complete_path = evidence_root / "complete.json"
    require_root_controlled_file(complete_path, secret=True)
    complete_details = complete_path.lstat()
    if (
        complete_details.st_gid != 0
        or complete_details.st_nlink != 1
        or stat.S_IMODE(complete_details.st_mode) != 0o600
    ):
        fail("internal-test database terminal receipt metadata differs")
    complete = strict_json_object(
        read_root_evidence_bytes(complete_path),
        "internal-test database terminal receipt",
    )
    release_guard.exact_keys(
        complete,
        {
            "completedAtUtc", "entryEnabled", "kind", "onboardingReceiptSha256",
            "productionAuthority", "schemaVersion", "status", "transactionId",
        },
        "internal-test database terminal receipt",
    )
    if (
        complete.get("schemaVersion") != 1
        or complete.get("kind")
        != "uten-imp-internal-test-database-commissioning-receipt"
        or complete.get("status")
        != (
            "EXPIRED_AWAITING_REAUTH"
            if value.get("status") == "EXPIRED_AWAITING_REAUTH"
            else "COMMITTED_AWAITING_FIRST_ACTIVATION"
        )
        or complete.get("transactionId") != transaction_id
        or complete.get("entryEnabled") is not False
        or complete.get("productionAuthority") is not False
        or complete.get("onboardingReceiptSha256") != onboarding_sha
    ):
        fail("internal-test database terminal receipt differs")
    require_recovery_timestamp(
        complete.get("completedAtUtc"), "internal-test database terminal time"
    )
    committed_pointer_path = evidence_root / "active-pointer.committed.json"
    require_root_controlled_file(committed_pointer_path, secret=True)
    pointer_details = committed_pointer_path.lstat()
    if (
        pointer_details.st_gid != 0
        or pointer_details.st_nlink != 1
        or stat.S_IMODE(pointer_details.st_mode) != 0o600
    ):
        fail("internal-test database committed pointer metadata differs")
    committed_pointer = strict_json_object(
        read_root_evidence_bytes(committed_pointer_path),
        "internal-test database committed pointer",
    )
    release_guard.exact_keys(
        committed_pointer,
        {"evidencePath", "planSha256", "schemaVersion", "transactionId"},
        "internal-test database committed pointer",
    )
    if (
        committed_pointer.get("schemaVersion") != 1
        or committed_pointer.get("evidencePath") != str(evidence_root)
        or committed_pointer.get("transactionId") != transaction_id
        or committed_pointer.get("planSha256") != value["transactionManifestSha256"]
    ):
        fail("internal-test database committed pointer differs")
    if require_worker_terminal:
        validate_internal_test_database_worker_terminal(
            value,
            evidence_root=evidence_root,
            database_commissioning_root=database_commissioning_root,
        )
    manifest = value.get("manifest")
    if not isinstance(manifest, dict):
        fail("internal-test onboarding manifest binding is malformed")
    release_guard.exact_keys(
        manifest,
        {
            "commitSha",
            "flywayHeadVersion",
            "flywayMigrationSetSha256",
            "manifestSha256",
            "migratorJarSha256",
            "releaseSequence",
            "serverJarSha256",
            "signingKeyId",
            "signedFlywayProjectionSha256",
            "version",
        },
        "internal-test onboarding manifest binding",
    )
    version = release_guard.require_string(manifest.get("version"), "onboarding version")
    if release_guard.version_sequence(version) != manifest.get("releaseSequence"):
        fail("internal-test onboarding version/sequence differs")
    release_guard.require_string(
        manifest.get("commitSha"), "onboarding commit", release_guard.COMMIT_RE
    )
    release_guard.require_string(
        manifest.get("signingKeyId"), "onboarding signing key", release_guard.KEY_ID_RE
    )
    head = release_guard.require_string(
        manifest.get("flywayHeadVersion"), "onboarding Flyway head"
    )
    if not head.isdigit():
        fail("internal-test onboarding Flyway head is malformed")
    for key in (
        "flywayMigrationSetSha256",
        "manifestSha256",
        "migratorJarSha256",
        "serverJarSha256",
        "signedFlywayProjectionSha256",
    ):
        require_recovery_sha256(manifest.get(key), f"onboarding manifest {key}")
    identity = value.get("databaseIdentity")
    if not isinstance(identity, dict):
        fail("internal-test onboarding database identity is malformed")
    release_guard.exact_keys(
        identity,
        {
            "canonicalHistorySha256",
            "headVersion",
            "roleAclContractSha256",
            "signedProjectionSha256",
            "successfulMigrationCount",
            "systemIdentifier",
            "timeline",
        },
        "internal-test onboarding database identity",
    )
    for key in (
        "canonicalHistorySha256",
        "roleAclContractSha256",
        "signedProjectionSha256",
    ):
        require_recovery_sha256(identity.get(key), f"onboarding database {key}")
    release_guard.require_string(
        identity.get("systemIdentifier"), "onboarding database system identifier",
        POSTGRES_SYSTEM_IDENTIFIER_RE,
    )
    require_recovery_integer(identity.get("headVersion"), "onboarding database head", minimum=1)
    require_recovery_integer(
        identity.get("successfulMigrationCount"), "onboarding database migration count", minimum=1
    )
    require_recovery_integer(identity.get("timeline"), "onboarding database timeline", minimum=1)

    transaction_manifest = release_guard.load_json(
        Path(value["transactionManifestPath"]), 256 * 1024
    )
    release_guard.exact_keys(
        transaction_manifest,
        {
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
            "productionAuthority",
            "payloadInventorySha256",
            "runtimeContractSha256",
            "schemaVersion",
            "status",
            "storageAuthoritySha256",
            "storageCommissioningReceiptSha256",
            "storageObservation",
            "transactionId",
        },
        "internal-test commissioning transaction manifest",
    )
    if (
        transaction_manifest.get("schemaVersion") != 1
        or transaction_manifest.get("kind")
        != "uten-imp-internal-test-database-commissioning-plan"
        or transaction_manifest.get("status") != "APPROVED_ENTRY_CLOSED"
        or transaction_manifest.get("deploymentProfile") != "internal-test-local-v1"
        or transaction_manifest.get("dataClassification") != "discardable-test-only"
        or transaction_manifest.get("productionAuthority") is not False
        or transaction_manifest.get("entryEnabled") is not False
    ):
        fail("internal-test commissioning plan boundary differs")
    authority_path = Path(value["commissioningAuthorityPath"])
    authority = release_guard.load_json(authority_path, 64 * 1024)
    release_guard.exact_keys(
        authority,
        {
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
        },
        "internal-test database commissioning authority",
    )
    authorized_at = require_recovery_timestamp(
        value.get("commissioningAuthorizedAtUtc"),
        "internal-test database commissioning authorization time",
    )
    plan_expires_at = require_recovery_timestamp(
        value.get("commissioningPlanExpiresAtUtc"),
        "internal-test database commissioning plan expiry",
    )
    plan_created_at = require_recovery_timestamp(
        transaction_manifest.get("createdAtUtc"),
        "internal-test database commissioning plan creation",
    )
    try:
        authorized_time = datetime.strptime(
            authorized_at, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
        plan_created_time = datetime.strptime(
            plan_created_at, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
        plan_expires_time = datetime.strptime(
            plan_expires_at, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise UpdaterError(
            "internal-test database commissioning authority time is malformed"
        ) from exc
    if (
        not plan_created_time <= authorized_time < plan_expires_time
        or plan_expires_time > plan_created_time + timedelta(days=7)
    ):
        fail("internal-test database commissioning was not authorized in its plan window")
    if (
        authority.get("schemaVersion") != 1
        or authority.get("kind")
        != "uten-imp-internal-test-database-commissioning-authority"
        or authority.get("status") != "AUTHORIZED_ENTRY_CLOSED"
        or authority.get("transactionId") != transaction_id
        or authority.get("evidencePath") != str(evidence_root)
        or authority.get("planPath") != value["transactionManifestPath"]
        or authority.get("planSha256") != value["transactionManifestSha256"]
        or authority.get("approvalReference") != approval
        or authority.get("version") != version
        or authority.get("authorizedAtUtc") != authorized_at
        or authority.get("runtimeContractSha256")
        != value["runtimeContractSha256"]
        or authority.get("storageCommissioningReceiptSha256")
        != value["storageCommissioningReceiptSha256"]
        or not isinstance(authority.get("preActiveSha256"), str)
        or SHA256_RE.fullmatch(authority["preActiveSha256"]) is None
        or transaction_manifest.get("expiresAtUtc") != plan_expires_at
        or authority.get("preActiveSha256")
        != value["commissioningPreActiveSha256"]
    ):
        fail("internal-test database commissioning authority differs")
    preactive = release_guard.load_json(
        Path(value["commissioningPreActivePath"]), 64 * 1024
    )
    release_guard.exact_keys(
        preactive,
        {
            "approvalReference",
            "createdAtUtc",
            "evidencePath",
            "runtimeContractSha256",
            "schemaVersion",
            "status",
            "storageCommissioningReceiptSha256",
            "transactionId",
            "version",
        },
        "internal-test database commissioning pre-active evidence",
    )
    if (
        preactive.get("schemaVersion") != 1
        or preactive.get("status") != "PREPARING_ENTRY_CLOSED"
        or preactive.get("transactionId") != transaction_id
        or preactive.get("evidencePath") != str(evidence_root)
        or preactive.get("approvalReference") != approval
        or preactive.get("version") != version
        or preactive.get("runtimeContractSha256")
        != value["runtimeContractSha256"]
        or preactive.get("storageCommissioningReceiptSha256")
        != value["storageCommissioningReceiptSha256"]
    ):
        fail("internal-test database commissioning pre-active evidence differs")
    preactive_created_at = require_recovery_timestamp(
        preactive.get("createdAtUtc"),
        "internal-test database commissioning pre-active creation time",
    )
    try:
        preactive_created_time = datetime.strptime(
            preactive_created_at, "%Y-%m-%dT%H:%M:%SZ"
        ).replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise UpdaterError(
            "internal-test database commissioning pre-active time is malformed"
        ) from exc
    if (
        preactive_created_time > plan_created_time
        or preactive_created_time > authorized_time
        or authorized_time >= preactive_created_time + timedelta(days=7)
    ):
        fail("internal-test database commissioning pre-active chronology differs")
    candidate_metadata, candidate_payload = (
        validate_internal_test_commissioning_candidate_paths(
            evidence_root, transaction_manifest, version
        )
    )
    require_real_directory(candidate_metadata, owner_uid=0)
    require_real_directory(candidate_payload, owner_uid=0)
    payload_inventory: list[dict[str, str]] = []
    for path in sorted(candidate_payload.rglob("*"), key=lambda item: item.as_posix()):
        details = path.lstat()
        if path.is_symlink() or not (
            stat.S_ISDIR(details.st_mode) or stat.S_ISREG(details.st_mode)
        ):
            fail("internal-test commissioning payload contains an unsafe file type")
        if stat.S_ISREG(details.st_mode):
            payload_inventory.append(
                {
                    "path": path.relative_to(candidate_payload).as_posix(),
                    "sha256": release_guard.sha256_file(path),
                }
            )
    expected_payload_inventory = require_recovery_sha256(
        transaction_manifest.get("payloadInventorySha256"),
        "internal-test commissioning payload inventory",
    )
    if hashlib.sha256(
        (json.dumps(payload_inventory, sort_keys=True, indent=2) + "\n").encode(
            "utf-8"
        )
    ).hexdigest() != expected_payload_inventory:
        fail("internal-test commissioning payload inventory changed")
    _channel, candidate_info, _staged = verify_candidate_metadata(
        candidate_metadata, DEFAULT_ALLOWED_SIGNERS
    )
    candidate_manifest_binding = internal_test_candidate_manifest_binding(
        candidate_info,
        release_guard.sha256_file(candidate_metadata / "manifest.json"),
    )
    if candidate_manifest_binding != manifest:
        fail(
            "internal-test onboarding manifest differs from its authenticated "
            "commissioning candidate"
        )
    if (
        authenticated_expected_target is not None
        and candidate_info != authenticated_expected_target
    ):
        fail("internal-test commissioning candidate metadata differs from activation target")
    for key in (
        "approvalReference",
        "commissionerSha256",
        "manifest",
        "runtimeContractSha256",
        "storageAuthoritySha256",
        "storageCommissioningReceiptSha256",
        "transactionId",
    ):
        if transaction_manifest.get(key) != value.get(key):
            fail(f"internal-test commissioning plan differs at {key}")
    if transaction_manifest.get("expiresAtUtc") != value.get(
        "commissioningPlanExpiresAtUtc"
    ):
        fail("internal-test commissioning plan expiry differs from its authority")
    plan_storage_binding = transaction_manifest.get("storageObservation")
    if not isinstance(plan_storage_binding, dict) or set(plan_storage_binding) != {
        "path",
        "sha256",
    }:
        fail("internal-test commissioning plan storage observation is malformed")
    plan_storage_observation = validate_internal_test_storage_observation(
        path_value=plan_storage_binding.get("path"),
        sha_value=plan_storage_binding.get("sha256"),
        evidence_root=evidence_root,
        transaction_id=transaction_id,
        phase="before-plan",
    )
    require_recovery_timestamp(
        transaction_manifest.get("createdAtUtc"), "internal-test commissioning plan time"
    )

    empty_proof = release_guard.load_json(Path(value["emptySourceProofPath"]), 64 * 1024)
    release_guard.exact_keys(
        empty_proof,
        {
            "checkedAtUtc",
            "directoryEntryCount",
            "filesystemUuid",
            "kind",
            "pgData",
            "postgresClusterInitializedBefore",
            "schemaVersion",
            "status",
            "transactionId",
        },
        "internal-test empty PGDATA proof",
    )
    if (
        empty_proof.get("schemaVersion") != 1
        or empty_proof.get("kind") != "uten-imp-internal-test-empty-pgdata-proof"
        or empty_proof.get("status") != "EMPTY_PGDATA_CONFIRMED"
        or empty_proof.get("transactionId") != transaction_id
        or empty_proof.get("pgData") != "/data/postgresql/16/main"
        or empty_proof.get("directoryEntryCount") != 0
        or empty_proof.get("postgresClusterInitializedBefore") is not False
    ):
        fail("internal-test empty PGDATA proof differs")
    require_recovery_timestamp(empty_proof.get("checkedAtUtc"), "empty PGDATA proof time")
    release_guard.require_string(
        empty_proof.get("filesystemUuid"), "empty PGDATA filesystem UUID", UUID_RE
    )

    migration_terminal = release_guard.load_json(
        Path(value["migrationTerminalReceiptPath"]), 256 * 1024
    )
    release_guard.exact_keys(
        migration_terminal,
        {
            "completedAtUtc",
            "databaseIdentity",
            "entryEnabled",
            "kind",
            "manifest",
            "roleContract",
            "schemaVersion",
            "status",
            "storageObservationPath",
            "storageObservationSha256",
            "transactionId",
        },
        "internal-test migration terminal receipt",
    )
    if (
        migration_terminal.get("schemaVersion") != 1
        or migration_terminal.get("kind") != "uten-imp-internal-test-migration-terminal"
        or migration_terminal.get("status") != "SIGNED_TARGET_VERIFIED_ENTRY_CLOSED"
        or migration_terminal.get("transactionId") != transaction_id
        or migration_terminal.get("entryEnabled") is not False
        or migration_terminal.get("manifest") != manifest
        or migration_terminal.get("databaseIdentity") != identity
        or migration_terminal.get("storageObservationPath")
        != value.get("storageObservationPath")
        or migration_terminal.get("storageObservationSha256")
        != value.get("storageObservationSha256")
    ):
        fail("internal-test migration terminal receipt binding differs")
    require_recovery_timestamp(
        migration_terminal.get("completedAtUtc"), "migration terminal time"
    )
    expected_roles = {
        "applicationRole": "uten",
        "database": "uten_imp",
        "databaseOwner": "uten_owner",
        "migratorCanSetOwner": True,
        "migratorRole": "uten_migrator",
        "ownerRole": "uten_owner",
        "publicCreateRevoked": True,
        "applicationCreateRevoked": True,
        "schemaOwner": "uten_owner",
    }
    if migration_terminal.get("roleContract") != expected_roles:
        fail("internal-test database role/ownership contract differs")

    storage_receipt = release_guard.load_json(
        Path(value["storageCommissioningReceiptPath"]), 64 * 1024
    )
    release_guard.exact_keys(
        storage_receipt,
        {
            "authorityPath",
            "authoritySha256",
            "backupCommissioned",
            "commissioningEvidenceSha256",
            "completedAtUtc",
            "entryEnabled",
            "evidenceRole",
            "filesystemUuid",
            "kind",
            "lvPath",
            "oldMdMounted",
            "oldMdRetainedAssembled",
            "planSha256",
            "postgresEnabled",
            "postgresInitialized",
            "schemaVersion",
            "status",
            "transactionId",
        },
        "NVMe storage commissioning receipt",
    )
    if (
        storage_receipt.get("schemaVersion") != 1
        or storage_receipt.get("kind") != "uten-imp-existing-test-host-nvme-receipt"
        or storage_receipt.get("status") != "COMMITTED_STORAGE_ONLY"
        or storage_receipt.get("authorityPath") != str(STORAGE_AUTHORITY)
        or storage_receipt.get("authoritySha256") != value.get("storageAuthoritySha256")
        or storage_receipt.get("evidenceRole") != "plan"
        or storage_receipt.get("postgresInitialized") is not False
        or storage_receipt.get("postgresEnabled") is not False
        or storage_receipt.get("backupCommissioned") is not False
        or storage_receipt.get("entryEnabled") is not False
    ):
        fail("NVMe storage commissioning receipt is not the v3 storage-only terminal")
    storage_plan = Path(value["storageCommissioningEvidencePath"]) / "plan.json"
    require_root_controlled_file(storage_plan, secret=True)
    storage_plan_raw = read_root_evidence_bytes(storage_plan)
    storage_plan_value = strict_json_object(storage_plan_raw, "NVMe storage commissioning plan")
    embedded_plan_sha = release_guard.require_string(
        storage_plan_value.pop("planSha256", None),
        "NVMe embedded plan digest",
        release_guard.SHA256_RE,
    )
    plan_core_sha = hashlib.sha256(
        (json.dumps(storage_plan_value, sort_keys=True, indent=2) + "\n").encode("utf-8")
    ).hexdigest()
    if (
        release_guard.sha256_file(storage_plan)
        != storage_receipt["commissioningEvidenceSha256"]
        or embedded_plan_sha != storage_receipt["planSha256"]
        or plan_core_sha != storage_receipt["planSha256"]
    ):
        fail("NVMe storage commissioning plan binding changed")
    storage_authority = release_guard.load_json(STORAGE_AUTHORITY, 256 * 1024)
    if (
        storage_authority.get("schemaVersion") != 3
        or storage_authority.get("commissioningEvidenceSha256")
        != storage_receipt["commissioningEvidenceSha256"]
        or storage_authority.get("dataUuid")
        != str(storage_receipt["filesystemUuid"]).lower()
        or release_guard.sha256_file(STORAGE_AUTHORITY)
        != storage_receipt["authoritySha256"]
        or storage_receipt.get("transactionId") != Path(storage_evidence).name
    ):
        fail("NVMe storage authority/receipt/transaction binding differs")
    if empty_proof["filesystemUuid"].lower() != str(storage_receipt["filesystemUuid"]).lower():
        fail("empty PGDATA proof belongs to another storage filesystem")
    for observation in (plan_storage_observation, terminal_storage_observation):
        if (
            observation.get("authoritySha256") != value.get("storageAuthoritySha256")
            or observation.get("authorityCommissioningEvidenceSha256")
            != storage_receipt.get("commissioningEvidenceSha256")
            or observation.get("filesystemUuid").lower()
            != str(storage_receipt["filesystemUuid"]).lower()
            or observation.get("storageCommissioningPlanSha256")
            != storage_receipt.get("planSha256")
            or observation.get("storageCommissioningReceiptSha256")
            != value.get("storageCommissioningReceiptSha256")
        ):
            fail("live storage observation differs from commissioning authority")
    return version


def _compact_canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def _read_canonical_root_receipt(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    raw = read_root_controlled_bytes(
        path, exact_mode=0o600, maximum_bytes=MAX_ROOT_EVIDENCE_BYTES
    )
    value = strict_json_object(raw, label)
    if raw != _compact_canonical_json_bytes(value):
        fail(f"{label} is not canonical compact JSON")
    return value, raw


def _first_backup_archive_path(transaction_id: str) -> Path:
    if not INTERNAL_TEST_TRANSACTION_RE.fullmatch(transaction_id):
        fail("first-backup onboarding transaction ID is malformed")
    return INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
        transaction_id + INTERNAL_TEST_FIRST_BACKUP_ARCHIVE_SUFFIX
    )


def _first_backup_terminal_archive_path(transaction_id: str) -> Path:
    if not INTERNAL_TEST_TRANSACTION_RE.fullmatch(transaction_id):
        fail("first-backup onboarding transaction ID is malformed")
    return INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
        transaction_id + INTERNAL_TEST_FIRST_BACKUP_TERMINAL_ARCHIVE_SUFFIX
    )


def _parse_first_backup_time(value: Any, label: str) -> datetime:
    text = require_recovery_timestamp(value, label)
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise UpdaterError(f"{label} is malformed") from exc


def _first_backup_source_pins() -> dict[str, str]:
    producer = read_root_controlled_bytes(
        INTERNAL_TEST_FIRST_BACKUP_PRODUCER,
        exact_mode=0o755,
        maximum_bytes=2 * 1024 * 1024,
    )
    commissioner = read_root_controlled_bytes(
        INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER,
        exact_mode=0o755,
        maximum_bytes=4 * 1024 * 1024,
    )
    producer_sha = hashlib.sha256(producer).hexdigest()
    commissioner_sha = hashlib.sha256(commissioner).hexdigest()
    if not secrets.compare_digest(
        producer_sha, INTERNAL_TEST_FIRST_BACKUP_PRODUCER_SHA256
    ) or not secrets.compare_digest(
        commissioner_sha, INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_SHA256
    ):
        fail("installed first-backup producer/commissioner differs from reviewed bytes")
    return {
        "commissionerPath": str(INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER),
        "commissionerSha256": commissioner_sha,
        "producerPath": str(INTERNAL_TEST_FIRST_BACKUP_PRODUCER),
        "producerSha256": producer_sha,
    }


def _validate_first_backup_inventory(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be one object")
    release_guard.exact_keys(
        value, {"backups", "inventorySha256", "repository", "stanza"}, label
    )
    if value.get("repository") != 1 or value.get("stanza") != "uten-imp":
        fail(f"{label} repository/stanza differs")
    backups = value.get("backups")
    if not isinstance(backups, list):
        fail(f"{label} backups are malformed")
    normalized: list[dict[str, Any]] = []
    labels: set[str] = set()
    for item in backups:
        if not isinstance(item, dict):
            fail(f"{label} entry is malformed")
        release_guard.exact_keys(item, {"label", "stopEpoch", "type"}, label)
        backup_label = item.get("label")
        stop = item.get("stopEpoch")
        backup_type = item.get("type")
        if (
            not isinstance(backup_label, str)
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}", backup_label)
            is None
            or backup_label in labels
            or backup_type not in {"full", "diff", "incr"}
            or isinstance(stop, bool)
            or not isinstance(stop, int)
            or stop < 1
        ):
            fail(f"{label} entry identity is malformed")
        labels.add(backup_label)
        normalized.append(
            {"label": backup_label, "stopEpoch": stop, "type": backup_type}
        )
    normalized.sort(key=lambda item: item["label"])
    expected = hashlib.sha256(_compact_canonical_json_bytes(normalized)).hexdigest()
    if value.get("inventorySha256") != expected:
        fail(f"{label} digest differs")
    return {"backups": normalized, "inventorySha256": expected}


def _validate_first_backup_locked_job(
    backup: dict[str, Any], *, receipt_created_at: datetime
) -> dict[str, Any]:
    transaction_id = release_guard.require_string(
        backup.get("lockedJobTransactionId"), "first-backup locked_job transaction"
    )
    if re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}", transaction_id) is None:
        fail("first-backup locked_job transaction ID is malformed")
    path = Path(
        release_guard.require_string(
            backup.get("lockedJobReceiptPath"), "first-backup locked_job receipt path"
        )
    )
    expected_path = Path("/var/lib/uten-imp-backup-transactions/receipts") / (
        f"repo1-{transaction_id}.json"
    )
    if path != expected_path:
        fail("first-backup locked_job receipt escaped its fixed path")
    value, raw = _read_canonical_root_receipt(path, "first-backup locked_job receipt")
    digest = hashlib.sha256(raw).hexdigest()
    if digest != require_recovery_sha256(
        backup.get("lockedJobReceiptSha256"), "first-backup locked_job receipt digest"
    ):
        fail("first-backup locked_job receipt bytes changed")
    release_guard.exact_keys(
        value,
        {"containsSecrets", "kind", "schemaVersion", "transaction"},
        "first-backup locked_job receipt",
    )
    transaction = value.get("transaction")
    expected_keys = {
        "backupCommandSha256", "committedAtUtc", "committedBackup",
        "completedAtUtc", "createdAtUtc", "expireCommandSha256",
        "expireStartedAtUtc", "finalInventory", "job", "kind", "phase",
        "postBackupInventory", "preInventory", "repository", "schemaVersion",
        "transactionId", "updatedAtUtc",
    }
    if (
        value.get("schemaVersion") != 1
        or value.get("kind")
        != "uten-imp-pgbackrest-backup-transaction-receipt"
        or value.get("containsSecrets") is not False
        or not isinstance(transaction, dict)
    ):
        fail("first-backup locked_job receipt identity differs")
    release_guard.exact_keys(
        transaction, expected_keys, "first-backup locked_job transaction"
    )
    pgbackrest_base = [
        "/usr/bin/pgbackrest",
        "--config=/etc/pgbackrest.conf",
        "--config-include-path=/etc/pgbackrest/conf.d",
        "--stanza=uten-imp",
    ]
    backup_command = pgbackrest_base + [
        "--repo=1", "--no-expire-auto", "--type=full", "backup"
    ]
    expire_command = pgbackrest_base + ["--repo=1", "expire"]
    if (
        transaction.get("schemaVersion") != 1
        or transaction.get("kind") != "uten-imp-pgbackrest-backup-transaction"
        or transaction.get("transactionId") != transaction_id
        or transaction.get("job") != "repo1"
        or transaction.get("repository") != 1
        or transaction.get("phase") != "complete"
        or transaction.get("backupCommandSha256")
        != hashlib.sha256(_compact_canonical_json_bytes(backup_command)).hexdigest()
        or transaction.get("expireCommandSha256")
        != hashlib.sha256(_compact_canonical_json_bytes(expire_command)).hexdigest()
    ):
        fail("first-backup locked_job transaction/commands differ")
    created = _parse_first_backup_time(transaction.get("createdAtUtc"), "locked_job creation")
    committed_at = _parse_first_backup_time(
        transaction.get("committedAtUtc"), "locked_job commit"
    )
    expire_started = _parse_first_backup_time(
        transaction.get("expireStartedAtUtc"), "locked_job expiry start"
    )
    completed = _parse_first_backup_time(
        transaction.get("completedAtUtc"), "locked_job completion"
    )
    updated = _parse_first_backup_time(
        transaction.get("updatedAtUtc"), "locked_job update"
    )
    stop = backup.get("stopEpoch")
    if isinstance(stop, bool) or not isinstance(stop, int) or stop < 1:
        fail("first-backup stop epoch is malformed")
    stop_time = datetime.fromtimestamp(stop, tz=timezone.utc)
    if not (
        created <= stop_time <= committed_at <= expire_started <= updated <= completed
        <= receipt_created_at
    ):
        fail("first-backup locked_job chronology differs")
    pre = _validate_first_backup_inventory(
        transaction.get("preInventory"), "first-backup pre-inventory"
    )["backups"]
    post = _validate_first_backup_inventory(
        transaction.get("postBackupInventory"), "first-backup post-inventory"
    )["backups"]
    final = _validate_first_backup_inventory(
        transaction.get("finalInventory"), "first-backup final inventory"
    )["backups"]
    before = {item["label"]: item for item in pre}
    after = {item["label"]: item for item in post}
    final_map = {item["label"]: item for item in final}
    added = sorted(set(after) - set(before))
    committed = transaction.get("committedBackup")
    if (
        not set(before).issubset(after)
        or len(added) != 1
        or not isinstance(committed, dict)
        or set(committed) != {"label", "stopEpoch", "type"}
        or committed != after.get(added[0])
        or committed.get("type") != "full"
        or committed.get("label") != backup.get("label")
        or committed.get("stopEpoch") != stop
        or committed.get("label") not in final_map
        or not set(final_map).issubset(after)
    ):
        fail("first-backup locked_job receipt does not prove one durable new full")
    return {"path": str(path), "sha256": digest, "transactionId": transaction_id}


def validate_internal_test_first_backup_receipt(
    value: dict[str, Any],
    *,
    raw_sha256: str,
    onboarding: dict[str, Any],
    onboarding_sha256: str,
    live_database_identity: dict[str, Any],
    expected_candidate: dict[str, Any] | None,
    expected_manifest_sha256: str | None,
    require_fresh: bool,
    now: datetime | None = None,
) -> dict[str, Any]:
    release_guard.exact_keys(
        value,
        {
            "backup", "check", "containsSecrets", "createdAtUtc",
            "databaseIdentity", "deploymentProfile", "evidenceSetSha256",
            "expiresAt", "kind", "localRecoveryOnly", "onboarding",
            "producer", "productionAuthority", "restoreVerified",
            "schemaVersion", "status", "version",
        },
        "internal-test first-backup receipt",
    )
    if (
        value.get("schemaVersion") != 1
        or value.get("kind") != "uten-imp-internal-test-first-local-backup"
        or value.get("status") != "VERIFIED_LOCAL_FIRST_FULL"
        or value.get("containsSecrets") is not False
        or value.get("deploymentProfile") != "internal-test"
        or value.get("localRecoveryOnly") is not True
        or value.get("restoreVerified") is not False
        or value.get("productionAuthority") is not False
    ):
        fail("internal-test first-backup authority boundary differs")
    created = _parse_first_backup_time(value.get("createdAtUtc"), "first-backup creation")
    expires = _parse_first_backup_time(value.get("expiresAt"), "first-backup expiry")
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if expires - created != timedelta(hours=24) or created > current + timedelta(seconds=5):
        fail("first-backup receipt chronology differs")
    if require_fresh and not created <= current < expires:
        fail("first-backup receipt expired before activation")
    onboarding_completed = _parse_first_backup_time(
        onboarding.get("completedAtUtc"), "first-backup onboarding completion"
    )
    if created < onboarding_completed:
        fail("first-backup receipt predates onboarding completion")
    identity = value.get("databaseIdentity")
    if identity != onboarding.get("databaseIdentity") or identity != live_database_identity:
        fail("first-backup database identity differs from onboarding/live runtime")
    receipt_onboarding = value.get("onboarding")
    if not isinstance(receipt_onboarding, dict):
        fail("first-backup onboarding binding is malformed")
    release_guard.exact_keys(
        receipt_onboarding,
        {"path", "sha256", "status", "transactionId"},
        "first-backup onboarding binding",
    )
    if (
        receipt_onboarding.get("path") != str(INTERNAL_TEST_ONBOARDING_RECEIPT)
        or receipt_onboarding.get("sha256") != onboarding_sha256
        or receipt_onboarding.get("status") != onboarding.get("status")
        or receipt_onboarding.get("transactionId") != onboarding.get("transactionId")
    ):
        fail("first-backup onboarding receipt binding differs")
    pins = _first_backup_source_pins()
    producer = value.get("producer")
    if not isinstance(producer, dict) or producer != {
        "path": pins["producerPath"], "sha256": pins["producerSha256"]
    }:
        fail("first-backup producer binding differs")
    candidate = value.get("candidate")
    # The candidate lives inside evidenceSetSha256, not as a top-level field.
    if candidate is not None:
        fail("first-backup receipt contains an unexpected candidate field")
    candidate_binding = onboarding.get("manifest")
    if not isinstance(candidate_binding, dict):
        fail("first-backup onboarding candidate binding is malformed")
    if expected_candidate is not None:
        if expected_manifest_sha256 is None or candidate_binding != internal_test_candidate_manifest_binding(
            expected_candidate, expected_manifest_sha256
        ):
            fail("first-backup candidate differs from the authenticated activation target")
    if value.get("version") != candidate_binding.get("version"):
        fail("first-backup version differs from onboarding")
    backup = value.get("backup")
    check = value.get("check")
    if not isinstance(backup, dict) or not isinstance(check, dict):
        fail("first-backup backup/check evidence is malformed")
    release_guard.exact_keys(
        backup,
        {
            "ageSeconds", "label", "lockedJobReceiptPath",
            "lockedJobReceiptSha256", "lockedJobTransactionId", "repository",
            "stopEpoch", "walStart", "walStop",
        },
        "first-backup backup evidence",
    )
    age = backup.get("ageSeconds")
    stop = backup.get("stopEpoch")
    label = backup.get("label")
    wal_start = backup.get("walStart")
    wal_stop = backup.get("walStop")
    timeline = identity.get("timeline") if isinstance(identity, dict) else None
    if (
        backup.get("repository") != 1
        or isinstance(age, bool)
        or not isinstance(age, int)
        or not 0 <= age <= 6 * 60 * 60
        or isinstance(stop, bool)
        or not isinstance(stop, int)
        or stop < int(onboarding_completed.timestamp())
        or not isinstance(label, str)
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}", label) is None
        or not isinstance(wal_start, str)
        or re.fullmatch(r"[0-9A-F]{24}(?:\.partial)?", wal_start) is None
        or not isinstance(wal_stop, str)
        or re.fullmatch(r"[0-9A-F]{24}(?:\.partial)?", wal_stop) is None
        or wal_start > wal_stop
        or isinstance(timeline, bool)
        or not isinstance(timeline, int)
        or not wal_start.startswith(f"{timeline:08X}")
        or not wal_stop.startswith(f"{timeline:08X}")
        or max(int(created.timestamp()) - stop, 0) != age
        or current - datetime.fromtimestamp(stop, tz=timezone.utc)
        > timedelta(hours=24)
    ):
        fail("first-backup repo1 full/WAL identity differs")
    release_guard.exact_keys(
        check,
        {"commandSha256", "completedAtUtc", "passed", "repository"},
        "first-backup repo1 check",
    )
    pgbackrest_check = [
        "/usr/bin/pgbackrest", "--config=/etc/pgbackrest.conf",
        "--config-include-path=/etc/pgbackrest/conf.d", "--stanza=uten-imp",
        "--repo=1", "check",
    ]
    check_completed = _parse_first_backup_time(
        check.get("completedAtUtc"), "first-backup repo1 check completion"
    )
    if (
        check.get("commandSha256")
        != hashlib.sha256(_compact_canonical_json_bytes(pgbackrest_check)).hexdigest()
        or check.get("passed") is not True
        or check.get("repository") != 1
        or not onboarding_completed <= check_completed <= created
        or created - check_completed > timedelta(minutes=10)
    ):
        fail("first-backup fixed repo1 check is not a fresh PASS")
    locked = _validate_first_backup_locked_job(backup, receipt_created_at=created)
    # repo1InfoSha256 is intentionally not in the onboarding plan; it is bound
    # only by evidenceSetSha256 and cannot be recovered independently. Preserve
    # the producer's one-way aggregate while validating every available input.
    if not isinstance(value.get("evidenceSetSha256"), str) or re.fullmatch(
        r"[0-9a-f]{64}", value["evidenceSetSha256"]
    ) is None:
        fail("first-backup evidence-set digest is malformed")
    return {
        "createdAtUtc": value["createdAtUtc"],
        "databaseIdentity": identity,
        "expiresAtUtc": value["expiresAt"],
        "lockedJobReceipt": locked,
        "onboardingReceiptSha256": onboarding_sha256,
        "receiptSha256": raw_sha256,
        "version": value["version"],
    }


def _validate_internal_test_first_backup_terminal(
    *,
    path: Path,
    receipt_sha256: str,
    created_at_utc: str,
    expires_at_utc: str,
    require_current: bool = False,
) -> dict[str, str]:
    terminal, terminal_raw = _read_canonical_root_receipt(
        path,
        "internal-test first-backup commissioner terminal receipt",
    )
    release_guard.exact_keys(
        terminal,
        {
            "completedAtUtc", "containsSecrets", "firstBackupReceipt", "kind",
            "localRecoveryOnly", "planSha256", "productionAuthority",
            "repositoryMutationIsIrreversible", "restoreVerified", "schemaVersion",
            "status", "transactionPath",
        },
        "internal-test first-backup commissioner terminal receipt",
    )
    terminal_reference = terminal.get("firstBackupReceipt")
    plan_sha = terminal.get("planSha256")
    completed = _parse_first_backup_time(
        terminal.get("completedAtUtc"), "first-backup commissioner completion"
    )
    created = _parse_first_backup_time(created_at_utc, "first-backup creation")
    expires = _parse_first_backup_time(expires_at_utc, "first-backup expiry")
    if (
        terminal.get("schemaVersion") != 1
        or terminal.get("kind")
        != "uten-imp-internal-test-first-backup-commissioning-receipt"
        or terminal.get("status")
        != "COMMISSIONED_LOCAL_FIRST_FULL_ENTRY_CLOSED"
        or terminal.get("containsSecrets") is not False
        or terminal.get("localRecoveryOnly") is not True
        or terminal.get("restoreVerified") is not False
        or terminal.get("productionAuthority") is not False
        or terminal.get("repositoryMutationIsIrreversible") is not True
        or not isinstance(plan_sha, str)
        or re.fullmatch(r"[0-9a-f]{64}", plan_sha) is None
        or terminal.get("transactionPath")
        != f"/var/lib/uten-imp-internal-test-backup-commissioner/transactions/{plan_sha}"
        or terminal_reference
        != {"path": str(INTERNAL_TEST_FIRST_BACKUP_RECEIPT), "sha256": receipt_sha256}
        or not created <= completed <= expires
        or expires - created != timedelta(hours=24)
        or (
            require_current
            and completed > datetime.now(timezone.utc) + timedelta(seconds=5)
        )
    ):
        fail("first-backup commissioner terminal binding differs")
    return {
        "path": str(path),
        "sha256": hashlib.sha256(terminal_raw).hexdigest(),
    }


def require_initial_internal_test_first_backup(
    *,
    target_info: dict[str, Any],
    target_manifest_sha256: str,
    onboarding_receipt: dict[str, Any],
    live_evidence: dict[str, Any],
) -> dict[str, Any]:
    if deployment_profile() != "internal-test":
        fail("first local backup receipt is valid only for internal-test")
    onboarding = onboarding_receipt.get("fields")
    onboarding_sha = onboarding_receipt.get("sha256")
    if not isinstance(onboarding, dict) or not isinstance(onboarding_sha, str):
        fail("first-backup onboarding authority is malformed")
    archive = _first_backup_archive_path(onboarding["transactionId"])
    terminal_archive = _first_backup_terminal_archive_path(
        onboarding["transactionId"]
    )
    if os.path.lexists(archive) or os.path.lexists(terminal_archive):
        fail("first-backup receipt was already consumed")
    if not os.path.lexists(INTERNAL_TEST_FIRST_BACKUP_RECEIPT):
        fail("live first-backup receipt is missing")
    receipt, raw = _read_canonical_root_receipt(
        INTERNAL_TEST_FIRST_BACKUP_RECEIPT, "internal-test first-backup receipt"
    )
    receipt_sha = hashlib.sha256(raw).hexdigest()
    validated = validate_internal_test_first_backup_receipt(
        receipt,
        raw_sha256=receipt_sha,
        onboarding=onboarding,
        onboarding_sha256=onboarding_sha,
        live_database_identity=runtime_database_identity(live_evidence),
        expected_candidate=target_info,
        expected_manifest_sha256=target_manifest_sha256,
        require_fresh=True,
    )
    terminal = _validate_internal_test_first_backup_terminal(
        path=INTERNAL_TEST_FIRST_BACKUP_TERMINAL,
        receipt_sha256=receipt_sha,
        created_at_utc=validated["createdAtUtc"],
        expires_at_utc=validated["expiresAtUtc"],
        require_current=True,
    )
    pins = _first_backup_source_pins()
    return {
        "archivePath": str(archive),
        **pins,
        "databaseIdentity": validated["databaseIdentity"],
        "onboardingReceiptSha256": onboarding_sha,
        "onboardingTransactionId": onboarding["transactionId"],
        "receiptSha256": receipt_sha,
        "sourcePath": str(INTERNAL_TEST_FIRST_BACKUP_RECEIPT),
        "terminalReceiptPath": terminal["path"],
        "terminalReceiptArchivePath": str(
            _first_backup_terminal_archive_path(onboarding["transactionId"])
        ),
        "terminalReceiptSha256": terminal["sha256"],
        "version": validated["version"],
    }


def validate_internal_test_first_backup_binding(
    value: Any,
    *,
    expected_version: str | None = None,
    live_database_identity: dict[str, Any] | None = None,
    require_archive: bool | None = None,
) -> str:
    if not isinstance(value, dict):
        fail("internal-test first-backup binding must be one object")
    release_guard.exact_keys(
        value,
        {
            "archivePath", "commissionerPath", "commissionerSha256",
            "databaseIdentity", "onboardingReceiptSha256",
            "onboardingTransactionId", "producerPath", "producerSha256",
            "receiptSha256", "sourcePath", "terminalReceiptPath",
            "terminalReceiptArchivePath", "terminalReceiptSha256", "version",
        },
        "internal-test first-backup binding",
    )
    transaction_id = release_guard.require_string(
        value.get("onboardingTransactionId"),
        "first-backup onboarding transaction",
    )
    expected_archive = _first_backup_archive_path(transaction_id)
    expected_terminal_archive = _first_backup_terminal_archive_path(transaction_id)
    producer_sha = require_recovery_sha256(
        value.get("producerSha256"), "first-backup producer digest"
    )
    commissioner_sha = require_recovery_sha256(
        value.get("commissionerSha256"), "first-backup commissioner digest"
    )
    if (
        value.get("sourcePath") != str(INTERNAL_TEST_FIRST_BACKUP_RECEIPT)
        or value.get("archivePath") != str(expected_archive)
        or value.get("terminalReceiptPath") != str(INTERNAL_TEST_FIRST_BACKUP_TERMINAL)
        or value.get("terminalReceiptArchivePath")
        != str(expected_terminal_archive)
        or value.get("producerPath") != str(INTERNAL_TEST_FIRST_BACKUP_PRODUCER)
        or producer_sha not in INTERNAL_TEST_FIRST_BACKUP_REVIEWED_PRODUCER_SHA256
        or value.get("commissionerPath")
        != str(INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER)
        or commissioner_sha
        not in INTERNAL_TEST_FIRST_BACKUP_REVIEWED_COMMISSIONER_SHA256
    ):
        fail("internal-test first-backup source/archive binding differs")
    for key in (
        "onboardingReceiptSha256",
        "receiptSha256",
        "terminalReceiptSha256",
    ):
        require_recovery_sha256(value.get(key), f"first-backup binding {key}")
    version = release_guard.require_string(value.get("version"), "first-backup version")
    release_guard.version_sequence(version)
    if expected_version is not None and version != expected_version:
        fail("first-backup binding names another release version")
    identity = value.get("databaseIdentity")
    if not isinstance(identity, dict):
        fail("first-backup binding database identity is malformed")
    if live_database_identity is not None and identity != live_database_identity:
        fail("first-backup binding database identity differs from the live runtime")

    source = INTERNAL_TEST_FIRST_BACKUP_RECEIPT
    source_present = os.path.lexists(source)
    archive_present = os.path.lexists(expected_archive)
    if source_present == archive_present:
        fail("first-backup binding requires exactly one live or archived receipt")
    if require_archive is True and not archive_present:
        fail("first-backup receipt has not been durably consumed")
    if require_archive is False and not source_present:
        fail("initial activation requires the unconsumed live first-backup receipt")
    terminal_source_present = os.path.lexists(INTERNAL_TEST_FIRST_BACKUP_TERMINAL)
    terminal_archive_present = os.path.lexists(expected_terminal_archive)
    if terminal_source_present == terminal_archive_present:
        fail("first-backup binding requires exactly one live or archived terminal receipt")
    if require_archive is True and not terminal_archive_present:
        fail("first-backup terminal receipt has not been durably consumed")
    if require_archive is False and not terminal_source_present:
        fail("initial activation requires the live commissioner terminal receipt")
    origin = expected_archive if archive_present else source
    receipt, raw = _read_canonical_root_receipt(origin, "bound first-backup receipt")
    if hashlib.sha256(raw).hexdigest() != value["receiptSha256"]:
        fail("bound first-backup receipt bytes differ")
    release_guard.exact_keys(
        receipt,
        {
            "backup", "check", "containsSecrets", "createdAtUtc",
            "databaseIdentity", "deploymentProfile", "evidenceSetSha256",
            "expiresAt", "kind", "localRecoveryOnly", "onboarding", "producer",
            "productionAuthority", "restoreVerified", "schemaVersion", "status",
            "version",
        },
        "bound first-backup receipt",
    )
    onboarding = receipt.get("onboarding")
    producer = receipt.get("producer")
    created = _parse_first_backup_time(receipt.get("createdAtUtc"), "first-backup creation")
    expires = _parse_first_backup_time(receipt.get("expiresAt"), "first-backup expiry")
    if (
        receipt.get("schemaVersion") != 1
        or receipt.get("kind") != "uten-imp-internal-test-first-local-backup"
        or receipt.get("status") != "VERIFIED_LOCAL_FIRST_FULL"
        or receipt.get("containsSecrets") is not False
        or receipt.get("deploymentProfile") != "internal-test"
        or receipt.get("localRecoveryOnly") is not True
        or receipt.get("restoreVerified") is not False
        or receipt.get("productionAuthority") is not False
        or receipt.get("version") != version
        or receipt.get("databaseIdentity") != identity
        or expires - created != timedelta(hours=24)
        or not isinstance(onboarding, dict)
        or onboarding.get("path") != str(INTERNAL_TEST_ONBOARDING_RECEIPT)
        or onboarding.get("sha256") != value["onboardingReceiptSha256"]
        or onboarding.get("transactionId") != transaction_id
        or producer
        != {"path": value["producerPath"], "sha256": producer_sha}
    ):
        fail("bound first-backup receipt authority differs")
    terminal = _validate_internal_test_first_backup_terminal(
        path=(
            expected_terminal_archive
            if terminal_archive_present
            else INTERNAL_TEST_FIRST_BACKUP_TERMINAL
        ),
        receipt_sha256=value["receiptSha256"],
        created_at_utc=receipt["createdAtUtc"],
        expires_at_utc=receipt["expiresAt"],
    )
    if (
        terminal["sha256"] != value["terminalReceiptSha256"]
    ):
        fail("bound first-backup commissioner terminal receipt changed")
    return "internal-test-first-backup-binding-v1"


def archive_internal_test_first_backup(
    binding: dict[str, Any],
    *,
    expected_version: str,
    live_database_identity: dict[str, Any],
) -> Path:
    validate_internal_test_first_backup_binding(
        binding,
        expected_version=expected_version,
        live_database_identity=live_database_identity,
        require_archive=None,
    )
    source = INTERNAL_TEST_FIRST_BACKUP_RECEIPT
    destination = Path(binding["archivePath"])
    terminal_source = INTERNAL_TEST_FIRST_BACKUP_TERMINAL
    terminal_destination = Path(binding["terminalReceiptArchivePath"])
    require_real_directory(destination.parent, owner_uid=0)
    if destination.parent.lstat().st_mode & 0o077:
        fail("first-backup archive directory must be root-only")
    if os.path.lexists(source):
        archive_root_evidence(source, destination, binding["receiptSha256"])
    if os.path.lexists(terminal_source):
        archive_root_evidence(
            terminal_source,
            terminal_destination,
            binding["terminalReceiptSha256"],
        )
    validate_internal_test_first_backup_binding(
        binding,
        expected_version=expected_version,
        live_database_identity=live_database_identity,
        require_archive=True,
    )
    return destination


def archive_internal_test_onboarding(
    receipt: dict[str, Any],
    *,
    authenticated_expected_target: dict[str, Any] | None = None,
    live_database_identity: dict[str, Any] | None = None,
) -> Path:
    fields = receipt.get("fields")
    if not isinstance(fields, dict):
        fail("internal-test onboarding archive input is malformed")
    adoption_prepared_at: str | None = None
    adoption: dict[str, Any] | None = None
    if os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION):
        require_root_controlled_file(INTERNAL_TEST_ONBOARDING_ADOPTION, secret=True)
        adoption = strict_json_object(
            read_root_evidence_bytes(INTERNAL_TEST_ONBOARDING_ADOPTION),
            "internal-test onboarding adoption",
        )
        if adoption.get("transactionId") != fields.get("transactionId"):
            fail("internal-test onboarding adoption names another transaction")
        validate_internal_test_onboarding_adoption(
            adoption,
            authenticated_expected_target=authenticated_expected_target,
            live_database_identity=live_database_identity,
        )
        adoption_prepared_at = adoption.get("preparedAtUtc")
    validate_internal_test_onboarding_receipt(
        fields,
        adoption_prepared_at_utc=adoption_prepared_at,
        allow_expired_origin=(
            adoption is not None
            and adoption.get("reauthorizationSha256") is not None
        ),
    )
    expected_sha = release_guard.require_string(
        receipt.get("sha256"), "internal-test onboarding receipt digest", release_guard.SHA256_RE
    )
    require_real_directory(INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR, owner_uid=0)
    if INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR.lstat().st_mode & 0o077:
        fail("internal-test onboarding archive directory must be root-only")
    destination = INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
        fields["transactionId"] + ".json"
    )
    source_present = os.path.lexists(INTERNAL_TEST_ONBOARDING_RECEIPT)
    destination_present = os.path.lexists(destination)
    if source_present and destination_present:
        fail("live and archived internal-test onboarding receipts both exist")
    if source_present:
        archived = archive_root_evidence(
            INTERNAL_TEST_ONBOARDING_RECEIPT, destination, expected_sha
        )
    elif destination_present:
        require_root_controlled_file(destination, secret=True)
        archived = read_root_evidence_bytes(destination)
    else:
        fail("internal-test onboarding receipt disappeared before durable adoption")
    if hashlib.sha256(archived).hexdigest() != expected_sha:
        fail("internal-test onboarding archive digest changed")
    if adoption is not None and adoption.get("reauthorizationSha256") is not None:
        reauthorization_sha = adoption["reauthorizationSha256"]
        reauthorization_archive = Path(adoption["reauthorizationArchivePath"])
        require_internal_test_reauthorization_evidence_directory(create=False)
        source_present = os.path.lexists(
            INTERNAL_TEST_ACTIVATION_REAUTHORIZATION
        )
        destination_present = os.path.lexists(reauthorization_archive)
        if source_present and destination_present:
            fail("live and archived activation reauthorizations both exist")
        if source_present:
            load_internal_test_activation_reauthorization(
                path=INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
                expected_sha256=reauthorization_sha,
                onboarding=fields,
                onboarding_receipt_path=destination,
                authenticated_expected_target=authenticated_expected_target,
                live_database_identity=live_database_identity,
                runtime_contract_sha256=adoption["runtimeContractSha256"],
                prepared_at_utc=adoption["preparedAtUtc"],
                prepared_boot_id=adoption["preparedBootId"],
                prepared_boottime_ns=adoption["preparedBoottimeNs"],
            )
            archive_root_evidence(
                INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
                reauthorization_archive,
                reauthorization_sha,
            )
        elif destination_present:
            load_internal_test_activation_reauthorization(
                path=reauthorization_archive,
                expected_sha256=reauthorization_sha,
                onboarding=fields,
                onboarding_receipt_path=destination,
                authenticated_expected_target=authenticated_expected_target,
                live_database_identity=live_database_identity,
                runtime_contract_sha256=adoption["runtimeContractSha256"],
                prepared_at_utc=adoption["preparedAtUtc"],
                prepared_boot_id=adoption["preparedBootId"],
                prepared_boottime_ns=adoption["preparedBoottimeNs"],
            )
        else:
            fail("activation reauthorization disappeared before durable adoption")
        validate_internal_test_onboarding_adoption(
            adoption,
            authenticated_expected_target=authenticated_expected_target,
            live_database_identity=live_database_identity,
        )
    return destination


def prepare_internal_test_onboarding_adoption(
    receipt: dict[str, Any],
    *,
    runtime_contract_id: str,
    runtime_contract_sha256: str,
    first_backup: dict[str, Any] | None = None,
    authenticated_expected_target: dict[str, Any] | None = None,
    live_database_identity: dict[str, Any] | None = None,
) -> dict[str, Any]:
    fields = receipt.get("fields")
    if not isinstance(fields, dict):
        fail("internal-test onboarding adoption input is malformed")
    receipt_sha = release_guard.require_string(
        receipt.get("sha256"),
        "internal-test onboarding adoption digest",
        release_guard.SHA256_RE,
    )
    archive = INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
        fields["transactionId"] + ".json"
    )
    reauthorization = receipt.get("reauthorization")
    if reauthorization is not None and not isinstance(reauthorization, dict):
        fail("internal-test onboarding reauthorization input is malformed")
    prepared_at = utc_now()
    prepared_boot_id = current_boot_id() if reauthorization is not None else None
    prepared_boottime_ns = (
        current_boottime_ns() if reauthorization is not None else None
    )
    reauthorization_archive = (
        internal_test_reauthorization_archive_path(fields["transactionId"])
        if reauthorization is not None
        else None
    )
    value = {
        "archivePath": str(archive),
        "preparedAtUtc": prepared_at,
        "receiptSha256": receipt_sha,
        "runtimeContractId": runtime_contract_id,
        "runtimeContractSha256": runtime_contract_sha256,
        "schemaVersion": 1,
        "sourcePath": str(INTERNAL_TEST_ONBOARDING_RECEIPT),
        "status": "ADOPTION_PREPARED",
        "transactionId": fields["transactionId"],
    }
    if first_backup is not None:
        value["firstBackup"] = dict(first_backup)
    if reauthorization is not None:
        value.update(
            {
                "preparedBootId": prepared_boot_id,
                "preparedBoottimeNs": prepared_boottime_ns,
                "reauthorizationArchivePath": str(reauthorization_archive),
                "reauthorizationSha256": reauthorization.get("sha256"),
                "reauthorizationSourcePath": str(
                    INTERNAL_TEST_ACTIVATION_REAUTHORIZATION
                ),
            }
        )
    if os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION):
        require_root_controlled_file(INTERNAL_TEST_ONBOARDING_ADOPTION, secret=True)
        existing = strict_json_object(
            read_root_evidence_bytes(INTERNAL_TEST_ONBOARDING_ADOPTION),
            "internal-test onboarding adoption",
        )
        prepared_keys = {"preparedAtUtc", "preparedBootId", "preparedBoottimeNs"}
        existing_without_time = {
            key: item for key, item in existing.items() if key not in prepared_keys
        }
        value_without_time = {
            key: item for key, item in value.items() if key not in prepared_keys
        }
        if existing_without_time != value_without_time:
            fail("internal-test onboarding adoption intent differs")
        validate_internal_test_onboarding_adoption(
            existing,
            authenticated_expected_target=authenticated_expected_target,
            live_database_identity=live_database_identity,
        )
        return existing
    validate_internal_test_onboarding_adoption(
        value,
        authenticated_expected_target=authenticated_expected_target,
        live_database_identity=live_database_identity,
    )
    atomic_json(INTERNAL_TEST_ONBOARDING_ADOPTION, value, mode=0o600)
    return value


def validate_internal_test_onboarding_adoption(
    value: dict[str, Any],
    *,
    authenticated_expected_target: dict[str, Any] | None = None,
    live_database_identity: dict[str, Any] | None = None,
) -> str:
    reauthorization_keys = {
        "preparedBootId",
        "preparedBoottimeNs",
        "reauthorizationArchivePath",
        "reauthorizationSha256",
        "reauthorizationSourcePath",
    }
    expected_keys = {
        "archivePath",
        "preparedAtUtc",
        "receiptSha256",
        "runtimeContractId",
        "runtimeContractSha256",
        "schemaVersion",
        "sourcePath",
        "status",
        "transactionId",
    }
    has_first_backup = "firstBackup" in value
    if has_first_backup:
        expected_keys.add("firstBackup")
    has_reauthorization_schema = any(key in value for key in reauthorization_keys)
    if has_reauthorization_schema:
        expected_keys.update(reauthorization_keys)
    release_guard.exact_keys(
        value,
        expected_keys,
        "internal-test onboarding adoption",
    )
    if (
        value.get("schemaVersion") != 1
        or value.get("status") != "ADOPTION_PREPARED"
        or value.get("sourcePath") != str(INTERNAL_TEST_ONBOARDING_RECEIPT)
        or value.get("runtimeContractId") != "uten-imp-internal-test-runtime-v1"
        or not INTERNAL_TEST_TRANSACTION_RE.fullmatch(str(value.get("transactionId", "")))
        or value.get("archivePath")
        != str(INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (value["transactionId"] + ".json"))
    ):
        fail("internal-test onboarding adoption boundary differs")
    require_recovery_timestamp(value.get("preparedAtUtc"), "onboarding adoption time")
    for key in ("receiptSha256", "runtimeContractSha256"):
        require_recovery_sha256(value.get(key), f"onboarding adoption {key}")
    source = INTERNAL_TEST_ONBOARDING_RECEIPT
    archive = Path(value["archivePath"])
    present = [path for path in (source, archive) if os.path.lexists(path)]
    if len(present) != 1:
        fail("onboarding adoption requires exactly one live or archived receipt")
    require_root_controlled_file(present[0], secret=True)
    raw = read_root_evidence_bytes(present[0])
    if hashlib.sha256(raw).hexdigest() != value["receiptSha256"]:
        fail("onboarding adoption receipt bytes differ")
    receipt = strict_json_object(raw, "adopted internal-test onboarding receipt")
    if receipt.get("transactionId") != value.get("transactionId"):
        fail("onboarding adoption receipt belongs to another transaction")
    reauthorization_sha = value.get("reauthorizationSha256")
    has_reauthorization = reauthorization_sha is not None
    if has_reauthorization_schema and not has_reauthorization:
        fail("onboarding adoption reauthorization schema is incomplete")
    if has_reauthorization:
        release_guard.require_string(
            value.get("preparedBootId"),
            "onboarding adoption boot ID",
            BOOT_ID_RE,
        )
        require_recovery_integer(
            value.get("preparedBoottimeNs"),
            "onboarding adoption boottime",
            minimum=1,
        )
        require_recovery_sha256(
            reauthorization_sha, "onboarding adoption reauthorization digest"
        )
        expected_reauthorization_archive = internal_test_reauthorization_archive_path(
            value["transactionId"]
        )
        if (
            value.get("reauthorizationSourcePath")
            != str(INTERNAL_TEST_ACTIVATION_REAUTHORIZATION)
            or value.get("reauthorizationArchivePath")
            != str(expected_reauthorization_archive)
            or authenticated_expected_target is None
            or live_database_identity is None
        ):
            fail("onboarding adoption reauthorization binding is incomplete")
    elif (
        value.get("reauthorizationSourcePath") is not None
        or value.get("reauthorizationArchivePath") is not None
    ):
        fail("onboarding adoption has a partial reauthorization binding")
    validate_internal_test_onboarding_receipt(
        receipt,
        adoption_prepared_at_utc=value["preparedAtUtc"],
        allow_expired_origin=has_reauthorization,
    )
    if has_first_backup:
        validate_internal_test_first_backup_binding(
            value["firstBackup"],
            expected_version=(
                authenticated_expected_target.get("version")
                if authenticated_expected_target is not None
                else None
            ),
            live_database_identity=live_database_identity,
            require_archive=None,
        )
        if (
            value["firstBackup"].get("onboardingTransactionId")
            != value.get("transactionId")
            or value["firstBackup"].get("onboardingReceiptSha256")
            != value.get("receiptSha256")
        ):
            fail("onboarding adoption first-backup origin differs")
    if has_reauthorization:
        reauthorization_archive = Path(value["reauthorizationArchivePath"])
        reauthorization_present = [
            path
            for path in (
                INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
                reauthorization_archive,
            )
            if os.path.lexists(path)
        ]
        if len(reauthorization_present) != 1:
            fail(
                "onboarding adoption requires exactly one live or archived "
                "activation reauthorization"
            )
        load_internal_test_activation_reauthorization(
            path=reauthorization_present[0],
            expected_sha256=reauthorization_sha,
            onboarding=receipt,
            onboarding_receipt_path=present[0],
            authenticated_expected_target=authenticated_expected_target,
            live_database_identity=live_database_identity,
            runtime_contract_sha256=value["runtimeContractSha256"],
            prepared_at_utc=value["preparedAtUtc"],
            prepared_boot_id=value["preparedBootId"],
            prepared_boottime_ns=value["preparedBoottimeNs"],
        )
    return "internal-test-onboarding-adoption-v1"


def finalize_internal_test_onboarding_adoption_if_committed(
    *,
    target: Path,
    manifest: dict[str, Any],
    live_evidence: dict[str, Any],
) -> None:
    """Remove a prepared adoption grant only after the durable commit is exact.

    A power loss may occur after the onboarding receipt has been archived and
    active/runtime authority have been committed, but before the prepared
    adoption marker is removed.  The marker is not a second grant: it may only
    be terminalized after independently re-reading every committed authority.
    """
    if not os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION):
        return
    if deployment_profile() != "internal-test":
        fail("internal-test onboarding adoption exists under another runtime profile")

    require_root_controlled_file(INTERNAL_TEST_ONBOARDING_ADOPTION, secret=True)
    adoption = strict_json_object(
        read_root_evidence_bytes(INTERNAL_TEST_ONBOARDING_ADOPTION),
        "internal-test onboarding adoption",
    )
    adoption_requires_live_identity = (
        "firstBackup" in adoption or adoption.get("reauthorizationSha256") is not None
    )
    committed_live_identity = (
        runtime_database_identity(live_evidence)
        if adoption_requires_live_identity
        else None
    )
    validate_internal_test_onboarding_adoption(
        adoption,
        authenticated_expected_target=manifest,
        live_database_identity=committed_live_identity,
    )

    active_path = DEFAULT_ROOT_STATE_DIR / "active.json"
    require_root_controlled_file(active_path, secret=True)
    active = strict_json_object(
        read_root_evidence_bytes(active_path),
        "committed internal-test active state",
    )
    validate_active_release_state(active)
    if (
        active.get("version") != manifest.get("version")
        or active.get("releaseSequence") != manifest.get("releaseSequence")
        or active.get("commitSha") != manifest.get("commitSha")
        or active.get("flywayHeadVersion") != manifest.get("flywayHeadVersion")
        or active.get("flywayMigrationSetSha256")
        != manifest.get("flywayMigrationSetSha256")
        or active.get("manifestSha256") != installed_manifest_sha256(target)
    ):
        fail("committed internal-test active state differs from the signed release")
    if (
        active.get("onboardingArchivePath") != adoption.get("archivePath")
        or active.get("onboardingReceiptSha256") != adoption.get("receiptSha256")
        or active.get("runtimeContractId") != adoption.get("runtimeContractId")
        or active.get("runtimeContractSha256")
        != adoption.get("runtimeContractSha256")
    ):
        fail("committed internal-test active state differs from its adoption intent")

    archive = Path(active["onboardingArchivePath"])
    require_root_controlled_file(archive, secret=True)
    if release_guard.sha256_file(archive) != active["onboardingReceiptSha256"]:
        fail("committed internal-test onboarding archive changed")

    validate_existing_runtime_authority(
        target=target,
        manifest=manifest,
        live_evidence=live_evidence,
    )
    require_root_controlled_file(RUNTIME_AUTHORITY, secret=True)
    authority = strict_json_object(
        read_root_evidence_bytes(RUNTIME_AUTHORITY),
        "committed internal-test runtime authority",
    )
    if (
        authority.get("runtimeContractId") != active["runtimeContractId"]
        or authority.get("runtimeContractSha256")
        != active["runtimeContractSha256"]
    ):
        fail("committed internal-test runtime authority differs from active state")

    first_backup = adoption.get("firstBackup")
    if first_backup is not None:
        if (
            active.get("firstBackup") != first_backup
            or authority.get("firstBackup") != first_backup
        ):
            fail("committed internal-test authorities differ from first-backup adoption")
        archive_internal_test_first_backup(
            first_backup,
            expected_version=manifest["version"],
            live_database_identity=committed_live_identity,
        )
        # The archive rename is the one-use consumption boundary. Re-read both
        # authorities and the archived origin before removing the adoption gate.
        validate_active_release_state(
            strict_json_object(
                read_root_evidence_bytes(active_path),
                "committed internal-test active state after first-backup archive",
            )
        )
        validate_existing_runtime_authority(
            target=target,
            manifest=manifest,
            live_evidence=live_evidence,
            first_backup_binding=first_backup,
        )

    durable_unlink(INTERNAL_TEST_ONBOARDING_ADOPTION)


def reconcile_internal_test_first_backup_adoption_before_activation(
    *, base: Path, releases: Path, allowed_signers: Path
) -> None:
    """Terminalize only a fully committed adoption left by process death.

    A pre-commit adoption intentionally remains live and is resumed by the
    normal first-activation path. A one-sided active/runtime commit is never
    guessed or repaired here; controlled activation recovery owns that state.
    """
    if not os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION):
        return
    if deployment_profile() != "internal-test":
        fail("internal-test onboarding adoption exists under another profile")
    active_path = DEFAULT_ROOT_STATE_DIR / "active.json"
    active_present = os.path.lexists(active_path)
    runtime_present = os.path.lexists(RUNTIME_AUTHORITY)
    if active_present != runtime_present:
        fail(
            "first-backup adoption has a one-sided active/runtime commit; "
            "controlled activation recovery is required"
        )
    if not active_present:
        return
    target = current_release(base, releases)
    if target is None:
        fail("committed first-backup adoption has no current release")
    manifest = load_installed_manifest(target, allowed_signers)
    if manifest is None:
        fail("committed first-backup adoption current release is not signed")
    live_evidence = verify_live_signed_database(
        target_manifest=manifest,
        allow_local_recovery_archive=True,
    )
    finalize_internal_test_onboarding_adoption_if_committed(
        target=target,
        manifest=manifest,
        live_evidence=live_evidence,
    )
    if os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION):
        fail("committed first-backup adoption did not terminalize")


def require_online_database_transition_acceptance(
    *,
    current_info: dict[str, Any],
    target_info: dict[str, Any],
    approve_database_change: bool,
) -> None:
    """Keep signed-current append-only changes closed until a from-to producer exists."""
    approval_note = (
        "The supplied --approve-database-change flag records intent only; it is not "
        "migration evidence. "
        if approve_database_change
        else "--approve-database-change alone would still not be migration evidence. "
    )
    fail(
        "online Flyway activation remains hard NO-GO for signed transition "
        f"{current_info['flywayHeadVersion']} -> {target_info['flywayHeadVersion']}: "
        + approval_note
        + "no reviewed from-to producer yet binds the live runtime authority, fresh "
        "backup, signed migrator, isolated rehearsal, UAT/PITR acceptance, maintenance "
        "window, and expiring approval. Stage and inspect only; do not run Flyway."
    )


def restore_after_failure(
    *,
    base: Path,
    old_target: Path | None,
    old_info: dict[str, Any] | None,
    new_info: dict[str, Any],
    nginx_was_active: bool,
    active_timers: list[str],
    boot_enabled_before: dict[str, bool],
    force_persistent_reason: str | None = None,
    schema_change_attempted: bool = True,
) -> None:
    log("activation failed; entering fail-closed recovery", "err")
    for timer in WATCHDOG_TIMERS:
        try:
            stop_unit(timer)
        except Exception as exc:
            log(f"could not stop {timer} during recovery: {exc}", "err")
    for service in WATCHDOG_SERVICES:
        try:
            stop_unit(service)
        except Exception as exc:
            log(f"could not stop {service} during recovery: {exc}", "err")
    try:
        stop_unit("nginx.service")
    except Exception as exc:
        log(f"could not close ingress during recovery: {exc}", "err")
    try:
        stop_unit("uten-imp.service")
    except Exception as exc:  # best effort while already handling a failure
        log(f"could not stop failed backend during recovery: {exc}", "err")
    if old_target is None:
        try:
            remove_current(base)
        except Exception as exc:
            log(f"could not remove failed first-release current link: {exc}", "err")
        log("first release failed; current is not trusted and ingress remains closed", "err")
        persist_fail_closed_activation(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=boot_enabled_before,
            reason="first-release-failed",
            current_link_restored=False,
        )
        return
    try:
        atomic_current(base, old_target)
    except Exception as exc:
        log(f"could not restore previous current symlink: {exc}", "err")
        persist_fail_closed_activation(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=boot_enabled_before,
            reason="current-restore-failed",
            current_link_restored=False,
        )
        return
    if force_persistent_reason is not None:
        persist_fail_closed_activation(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=boot_enabled_before,
            reason=force_persistent_reason,
            current_link_restored=True,
        )
        return
    migration_compatible = old_info is not None and (
        not schema_change_attempted
        or old_info["flywayMigrationSetSha256"]
        == new_info["flywayMigrationSetSha256"]
    )
    if not migration_compatible:
        log(
            "Flyway migration set changed or previous evidence is unavailable; "
            "automatic old-JAR restart is unsafe, so ingress remains closed",
            "err",
        )
        persist_fail_closed_activation(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=boot_enabled_before,
            reason="database-incompatible",
            current_link_restored=True,
        )
        return
    try:
        if old_info is None:
            fail("signed previous release evidence is required for automatic rollback")
        rollback_database_evidence = verify_live_signed_database(
            target_manifest=old_info,
            allow_local_recovery_archive=deployment_profile() == "internal-test",
        )
        validate_existing_runtime_authority(
            target=old_target,
            manifest=old_info,
            live_evidence=rollback_database_evidence,
        )
        start_application_authorized(
            mode="rollback",
            marker=ACTIVATION_IN_PROGRESS_MARKER,
            target=old_target,
            manifest=old_info,
            live_evidence=rollback_database_evidence,
        )
        validate_health(HEALTH_BASE_URL)
        if nginx_was_active:
            run(["nginx", "-t"])
        # Arm watchdogs while the activation marker still blocks recovery;
        # commit the signed old runtime before exposing ingress.
        # Re-arm both reconcilers before removing the transaction gate. If the
        # activator is killed after commit_boot_enablement but before Nginx is
        # explicitly opened, the entry watchdog must still converge ingress.
        for timer in WATCHDOG_TIMERS:
            start_unit(timer)
            if not unit_active(timer):
                fail(f"watchdog timer did not remain active during rollback: {timer}")
        commit_boot_enablement(boot_enabled_before, old_info)
        if nginx_was_active:
            start_unit("nginx.service")
            if not unit_active("nginx.service"):
                fail("nginx did not remain active after rollback commit")
        log("previous release restored after activation failure", "warning")
    except Exception as exc:
        log(f"previous release recovery also failed; ingress remains closed: {exc}", "err")
        persist_fail_closed_activation(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=boot_enabled_before,
            reason="previous-release-recovery-failed",
            current_link_restored=True,
        )


def recover_failed_activation(
    *,
    activation_error: Exception,
    base: Path,
    old_target: Path | None,
    old_info: dict[str, Any] | None,
    new_info: dict[str, Any],
    nginx_was_active: bool,
    active_timers: list[str],
    boot_enabled_before: dict[str, bool],
    transaction_started: bool,
    schema_change_attempted: bool,
    activation_state_commit_started: bool,
    legacy_retirement: bool,
    legacy_retirement_committed: bool,
    legacy_current_evidence: dict[str, str] | None,
) -> None:
    # A terminal-evidence/fsync failure must not let the ordinary failure path
    # delete activation-in-progress and orphan a replay-resistant grant in
    # /run. Keep the original marker and authorization plan-bindable for the
    # evidence-driven interrupted containment command, while closing every
    # runtime and boot path immediately.
    if os.path.lexists(MIGRATION_AUTHORIZATION_DIR):
        try:
            outstanding_authorizations = _migration_authorization_entries()
        except Exception:
            _stop_and_disable_for_interrupted_containment()
            raise
        if outstanding_authorizations:
            log(
                "migration authorization terminal evidence is incomplete; "
                "preserving the activation marker for interrupted containment",
                "err",
            )
            _stop_and_disable_for_interrupted_containment()
            return
    if activation_state_commit_started:
        persist_fail_closed_activation(
            old_info=old_info,
            new_info=new_info,
            boot_enabled_before=boot_enabled_before,
            reason="activation-commit-failed",
            current_link_restored=False,
            legacy_current_evidence=(
                legacy_current_evidence if legacy_retirement else None
            ),
        )
        return
    if legacy_retirement and not legacy_retirement_committed:
        if legacy_current_evidence is None:
            fail("legacy retirement failure lost its approved current evidence")
        persist_fail_closed_activation(
            old_info=None,
            new_info=new_info,
            boot_enabled_before=boot_enabled_before,
            reason="legacy-retirement-preparation-failed",
            current_link_restored=True,
            legacy_current_evidence=legacy_current_evidence,
        )
        return
    restore_after_failure(
        base=base,
        old_target=None if legacy_retirement else old_target,
        old_info=old_info,
        new_info=new_info,
        nginx_was_active=nginx_was_active,
        active_timers=active_timers,
        boot_enabled_before=boot_enabled_before,
        force_persistent_reason=(
            "migration-process-failed"
            if isinstance(activation_error, MigrationUnitError)
            else (
                "activation-preparation-failed"
                if not transaction_started
                else None
            )
        ),
        schema_change_attempted=schema_change_attempted,
    )


def validate_database_recovery_receipt(value: dict[str, Any]) -> None:
    release_guard.exact_keys(
        value,
        {
            "approvalReference",
            "completedAtUtc",
            "evidenceReference",
            "flywayHeadVersion",
            "flywayMigrationSetSha256",
            "receiptType",
            "schemaVersion",
            "successful",
            "targetVersion",
        },
        "database backup/restore receipt",
    )
    require_recovery_schema_version(value, "database receipt")
    if value.get("receiptType") not in {
        "backup",
        "restore",
    }:
        fail("database receipt schema/type is unsupported")
    if value.get("successful") is not True:
        fail("database receipt does not record a successful operation")
    approval = release_guard.require_string(
        value.get("approvalReference"), "database receipt approval reference"
    )
    if not RECOVERY_APPROVAL_RE.fullmatch(approval):
        fail("database receipt approval reference is not canonical")
    version = release_guard.require_string(
        value.get("targetVersion"), "database receipt target version"
    )
    release_guard.version_sequence(version)
    head = release_guard.require_string(
        value.get("flywayHeadVersion"), "database receipt Flyway head"
    )
    if not head.isdigit():
        fail("database receipt Flyway head is malformed")
    release_guard.require_string(
        value.get("flywayMigrationSetSha256"),
        "database receipt Flyway digest",
        release_guard.SHA256_RE,
    )
    require_recovery_timestamp(value.get("completedAtUtc"), "database receipt time")
    evidence_reference = release_guard.require_string(
        value.get("evidenceReference"), "database receipt evidence reference"
    )
    if not RECOVERY_DETAIL_REFERENCE_RE.fullmatch(evidence_reference):
        fail("database receipt must bind one fixed detailed receipt path and SHA-256")


def require_recovery_integer(
    value: Any, label: str, *, minimum: int = 0, maximum: int = 2**63 - 1
) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < minimum
        or value > maximum
    ):
        fail(f"{label} is not a canonical integer")
    return value


def require_recovery_sha256(value: Any, label: str) -> str:
    return release_guard.require_string(value, label, release_guard.SHA256_RE)


def validate_database_recovery_detail(
    value: dict[str, Any],
    *,
    narrow: dict[str, Any],
    target_manifest: dict[str, Any],
) -> dict[str, Any]:
    """Validate the immutable detailed backup/PITR receipt, not just its pointer."""
    release_guard.exact_keys(
        value,
        {
            "activeRepo2Preflight",
            "approvalReference",
            "completedAtUtc",
            "continuousWal",
            "databaseIdentity",
            "externalAlertDeliveryVerifiedSeparately",
            "externalAlertEvidence",
            "flywayHeadVersion",
            "flywayMigrationCount",
            "flywayMigrationSetSha256",
            "healthReportSha256",
            "isolatedPitrEvidence",
            "isolatedRepo2PitrVerifiedSeparately",
            "receiptType",
            "remoteImmutabilityVerifiedSeparately",
            "repositories",
            "schemaVersion",
            "signedReleaseEvidence",
            "successful",
            "targetVersion",
            "wormEvidence",
            "wormEvidenceSha256",
        },
        "detailed database recovery receipt",
    )
    require_recovery_schema_version(value, "detailed database receipt")
    if value.get("receiptType") != "backup-acceptance-detail" or value.get("successful") is not True:
        fail("detailed database receipt is not a successful backup acceptance")
    for key in (
        "approvalReference",
        "completedAtUtc",
        "flywayHeadVersion",
        "flywayMigrationSetSha256",
        "targetVersion",
    ):
        if value.get(key) != narrow.get(key):
            fail(f"detailed database receipt {key} differs from the narrow receipt")
    require_recovery_timestamp(value.get("completedAtUtc"), "detailed database receipt time")
    if value["targetVersion"] != target_manifest["version"]:
        fail("detailed database receipt target differs from the signed target")
    if value["flywayHeadVersion"] != target_manifest["flywayHeadVersion"]:
        fail("detailed database receipt Flyway head differs from the signed target")
    if value["flywayMigrationSetSha256"] != target_manifest["flywayMigrationSetSha256"]:
        fail("detailed database receipt migration-set digest differs from the signed target")
    migration_count = require_recovery_integer(
        value.get("flywayMigrationCount"),
        "detailed database receipt Flyway count",
        minimum=1,
        maximum=100_000,
    )
    if migration_count != target_manifest["flywayMigrationCount"]:
        fail("detailed database receipt Flyway count differs from the signed target")

    identity = value.get("databaseIdentity")
    if not isinstance(identity, dict):
        fail("detailed database receipt identity is missing")
    release_guard.exact_keys(
        identity,
        {"flyway", "systemIdentifier", "timeline"},
        "detailed database identity",
    )
    system_identifier = release_guard.require_string(
        identity.get("systemIdentifier"), "detailed PostgreSQL system identifier"
    )
    if not POSTGRES_SYSTEM_IDENTIFIER_RE.fullmatch(system_identifier):
        fail("detailed PostgreSQL system identifier is malformed")
    timeline = require_recovery_integer(
        identity.get("timeline"),
        "detailed PostgreSQL timeline",
        minimum=1,
        maximum=0xFFFFFFFF,
    )
    flyway = identity.get("flyway")
    if not isinstance(flyway, dict):
        fail("detailed database Flyway identity is missing")
    release_guard.exact_keys(
        flyway,
        {
            "canonicalHistorySha256",
            "headVersion",
            "signedProjectionSha256",
            "successfulMigrationCount",
        },
        "detailed database Flyway identity",
    )
    if require_recovery_integer(
        flyway.get("headVersion"), "detailed live Flyway head", minimum=1
    ) != int(target_manifest["flywayHeadVersion"]):
        fail("detailed live Flyway head differs from the signed target")
    if require_recovery_integer(
        flyway.get("successfulMigrationCount"),
        "detailed live Flyway count",
        minimum=1,
        maximum=100_000,
    ) != migration_count:
        fail("detailed live Flyway count differs from the signed target")
    canonical_history_sha = require_recovery_sha256(
        flyway.get("canonicalHistorySha256"),
        "detailed canonical Flyway history digest",
    )
    signed_projection_sha = require_recovery_sha256(
        flyway.get("signedProjectionSha256"),
        "detailed signed Flyway projection digest",
    )

    continuous_wal = value.get("continuousWal")
    if not isinstance(continuous_wal, dict):
        fail("detailed continuous WAL evidence is missing")
    release_guard.exact_keys(
        continuous_wal,
        {
            "archivedCount",
            "currentWal",
            "failedCount",
            "lastArchivedWal",
            "latestArchiveSuccessAgeSeconds",
            "latestArchiveSuccessEpoch",
            "nowEpoch",
            "systemIdentifier",
            "timeline",
        },
        "detailed continuous WAL evidence",
    )
    if (
        continuous_wal.get("systemIdentifier") != system_identifier
        or continuous_wal.get("timeline") != timeline
    ):
        fail("detailed WAL evidence differs from the database identity")
    for key in (
        "archivedCount",
        "failedCount",
        "latestArchiveSuccessAgeSeconds",
        "latestArchiveSuccessEpoch",
        "nowEpoch",
    ):
        require_recovery_integer(
            continuous_wal.get(key), f"detailed WAL evidence {key}"
        )
    if (
        continuous_wal["nowEpoch"] - continuous_wal["latestArchiveSuccessEpoch"]
        != continuous_wal["latestArchiveSuccessAgeSeconds"]
    ):
        fail("detailed WAL age is inconsistent with its fixed timestamps")
    for label in ("currentWal", "lastArchivedWal"):
        wal = continuous_wal.get(label)
        if not isinstance(wal, str) or not POSTGRES_WAL_RE.fullmatch(wal):
            fail(f"detailed WAL evidence {label} is malformed")

    signed = value.get("signedReleaseEvidence")
    if not isinstance(signed, dict):
        fail("detailed signed release evidence is missing")
    release_guard.exact_keys(
        signed,
        {
            "flywayRowsSha256",
            "manifestSha256",
            "migrationSetSha256",
            "signatureSha256",
        },
        "detailed signed release evidence",
    )
    for key in ("flywayRowsSha256", "manifestSha256", "migrationSetSha256", "signatureSha256"):
        require_recovery_sha256(signed.get(key), f"detailed signed release {key}")
    if (
        signed["manifestSha256"] != target_manifest["manifestSha256"]
        or signed["migrationSetSha256"] != target_manifest["flywayMigrationSetSha256"]
        or signed["flywayRowsSha256"] != signed_projection_sha
    ):
        fail("detailed signed release evidence differs from the verified target/history")

    pitr = value.get("isolatedPitrEvidence")
    if not isinstance(pitr, dict):
        fail("detailed isolated PITR evidence is missing")
    release_guard.exact_keys(
        pitr,
        {
            "actualRpoSeconds",
            "actualRtoSeconds",
            "backupSet",
            "businessAcceptanceSha256",
            "checks",
            "repository",
            "restoreReceiptSha256",
            "targetTimeUtc",
            "walStart",
            "walStop",
        },
        "detailed isolated PITR evidence",
    )
    if pitr.get("repository") != 2:
        fail("detailed PITR evidence is not bound to immutable repo2")
    require_recovery_integer(pitr.get("actualRpoSeconds"), "detailed PITR RPO")
    require_recovery_integer(pitr.get("actualRtoSeconds"), "detailed PITR RTO")
    release_guard.require_string(pitr.get("backupSet"), "detailed PITR backup set")
    require_recovery_timestamp(pitr.get("targetTimeUtc"), "detailed PITR target time")
    for key in ("walStart", "walStop"):
        wal = pitr.get(key)
        if not isinstance(wal, str) or not POSTGRES_WAL_RE.fullmatch(wal):
            fail(f"detailed PITR {key} is malformed")
    if pitr["walStart"] > pitr["walStop"]:
        fail("detailed PITR WAL range is reversed")
    for key in ("businessAcceptanceSha256", "restoreReceiptSha256"):
        require_recovery_sha256(pitr.get(key), f"detailed PITR {key}")
    checks = pitr.get("checks")
    if not isinstance(checks, dict) or set(checks) != REQUIRED_DATABASE_BUSINESS_CHECKS:
        fail("detailed PITR receipt lacks the exact seven business checks")
    for name, check in checks.items():
        if not isinstance(check, dict):
            fail(f"detailed PITR {name} check is malformed")
        release_guard.exact_keys(
            check, {"evidenceReference", "status"}, f"detailed PITR {name} check"
        )
        reference = check.get("evidenceReference")
        if (
            check.get("status") != "PASS"
            or not isinstance(reference, str)
            or not RECOVERY_EVIDENCE_REFERENCE_RE.fullmatch(reference)
        ):
            fail(f"detailed PITR {name} check is not independently evidenced PASS")

    for key in (
        "externalAlertDeliveryVerifiedSeparately",
        "isolatedRepo2PitrVerifiedSeparately",
        "remoteImmutabilityVerifiedSeparately",
    ):
        if value.get(key) is not True:
            fail(f"detailed database receipt does not prove {key}")
    repositories = value.get("repositories")
    if (
        not isinstance(repositories, list)
        or len(repositories) != 2
        or any(not isinstance(repository, dict) for repository in repositories)
        or [repository.get("repo") for repository in repositories] != [1, 2]
    ):
        fail("detailed database receipt does not contain exact repo1/repo2 evidence")
    for repository in repositories:
        release_guard.exact_keys(
            repository,
            {
                "databaseId",
                "latestArchivedWal",
                "latestSuccessfulFullAgeSeconds",
                "latestSuccessfulFullLabel",
                "latestSuccessfulFullStopEpoch",
                "latestSuccessfulFullWalStart",
                "latestSuccessfulFullWalStop",
                "repo",
                "restorePoints",
                "successfulFullRestorePointLabels",
                "successfulFullRestorePoints",
            },
            f"detailed repo{repository.get('repo')} evidence",
        )
        require_recovery_integer(
            repository.get("databaseId"),
            f"repo{repository.get('repo')} database identity",
            minimum=1,
        )
        if require_recovery_integer(
            repository.get("successfulFullRestorePoints"),
            f"repo{repository.get('repo')} successful restore points",
            minimum=7,
        ) < 7:
            fail("detailed database receipt has fewer than seven restore points")
        points = repository.get("restorePoints")
        if not isinstance(points, list) or len(points) < 7:
            fail("detailed database receipt has fewer than seven restore point identities")
        labels = repository.get("successfulFullRestorePointLabels")
        if not isinstance(labels, list) or len(labels) != len(points):
            fail("detailed database receipt restore-point labels are inconsistent")
        previous_stop = -1
        point_labels: list[str] = []
        for point in points:
            if not isinstance(point, dict):
                fail("detailed database receipt restore point is malformed")
            release_guard.exact_keys(
                point,
                {"label", "stopEpoch", "walStart", "walStop"},
                "detailed database restore point",
            )
            label = release_guard.require_string(
                point.get("label"), "detailed database restore point label"
            )
            if len(label) > 128 or label in point_labels:
                fail("detailed database restore point label is invalid or duplicated")
            stop = require_recovery_integer(
                point.get("stopEpoch"), "detailed database restore point epoch"
            )
            if stop <= previous_stop:
                fail("detailed database restore points are not strictly ordered")
            for key in ("walStart", "walStop"):
                wal = point.get(key)
                if not isinstance(wal, str) or not POSTGRES_WAL_RE.fullmatch(wal):
                    fail(f"detailed database restore point {key} is malformed")
            if point["walStart"] > point["walStop"]:
                fail("detailed database restore point WAL range is reversed")
            point_labels.append(label)
            previous_stop = stop
        if labels != point_labels:
            fail("detailed database restore-point labels differ from their identities")
        latest = points[-1]
        if (
            repository.get("latestSuccessfulFullLabel") != latest["label"]
            or repository.get("latestSuccessfulFullStopEpoch") != latest["stopEpoch"]
            or repository.get("latestSuccessfulFullWalStart") != latest["walStart"]
            or repository.get("latestSuccessfulFullWalStop") != latest["walStop"]
        ):
            fail("detailed database latest restore-point summary is inconsistent")
        require_recovery_integer(
            repository.get("latestSuccessfulFullAgeSeconds"),
            f"repo{repository.get('repo')} latest restore-point age",
        )
        latest_archived_wal = repository.get("latestArchivedWal")
        if (
            not isinstance(latest_archived_wal, str)
            or not POSTGRES_WAL_RE.fullmatch(latest_archived_wal)
        ):
            fail("detailed database latest archived WAL is malformed")
    for key in ("healthReportSha256", "wormEvidenceSha256"):
        require_recovery_sha256(value.get(key), f"detailed receipt {key}")
    if not isinstance(value.get("wormEvidence"), dict) or not isinstance(
        value.get("activeRepo2Preflight"), dict
    ):
        fail("detailed immutability/repo2 evidence is malformed")
    alert = value.get("externalAlertEvidence")
    if not isinstance(alert, dict):
        fail("detailed external alert evidence is missing")
    release_guard.exact_keys(
        alert,
        {"eventId", "eventSha256", "providerMessageId", "receiptSha256"},
        "detailed external alert evidence",
    )
    require_recovery_sha256(alert.get("eventSha256"), "detailed alert event digest")
    require_recovery_sha256(alert.get("receiptSha256"), "detailed alert receipt digest")
    return {
        "canonicalHistorySha256": canonical_history_sha,
        "flywayMigrationCount": migration_count,
        "signedProjectionSha256": signed_projection_sha,
        "systemIdentifier": system_identifier,
        "timeline": timeline,
    }


def canonical_signed_flyway_projection(target_manifest: dict[str, Any]) -> bytes:
    migrations = target_manifest.get("flywayMigrations")
    if not isinstance(migrations, list) or not migrations:
        fail("signed target has no canonical Flyway migration inventory")
    return "".join(
        f"{migration['version']}\t{migration['file']}\t{migration['flywayChecksum']}\n"
        for migration in migrations
    ).encode("utf-8")


def validate_detail_against_signed_manifest(
    database_receipt: dict[str, Any],
    target_manifest: dict[str, Any],
    target_release: Path,
) -> None:
    detail = database_receipt["detailFields"]
    signed = detail["signedReleaseEvidence"]
    projection_sha = hashlib.sha256(
        canonical_signed_flyway_projection(target_manifest)
    ).hexdigest()
    if projection_sha != signed["flywayRowsSha256"]:
        fail("detailed Flyway rows digest differs from the signed manifest")
    signature_path = target_release / ".release/manifest.sig"
    require_root_controlled_file(signature_path)
    if release_guard.sha256_file(signature_path) != signed["signatureSha256"]:
        fail("detailed release signature digest differs from the installed target")


def canonical_live_flyway_identity(
    rows: Any, target_manifest: dict[str, Any]
) -> dict[str, Any]:
    if not isinstance(rows, list) or not rows:
        fail("live Flyway history must be a non-empty array")
    expected_keys = {
        "checksum",
        "description",
        "installedRank",
        "script",
        "success",
        "type",
        "version",
    }
    canonical_rows: list[dict[str, Any]] = []
    # Keep this byte-for-byte canonicalization contract aligned with
    # pgbackrest_health._flyway_identity.  The signed-manifest comparison below
    # deliberately adds stricter version/file/checksum constraints.
    prior_rank = -1
    versions: set[str] = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != expected_keys:
            fail("live Flyway row schema differs from the fixed query")
        rank = require_recovery_integer(
            row.get("installedRank"), "live Flyway installed rank", minimum=0
        )
        checksum = require_recovery_integer(
            row.get("checksum"),
            "live Flyway checksum",
            minimum=-(2**31),
            maximum=2**31 - 1,
        )
        version = row.get("version")
        script = row.get("script")
        description = row.get("description")
        if rank <= prior_rank:
            fail("live Flyway installed ranks are not strictly increasing")
        if (
            not isinstance(version, str)
            or not version.isdigit()
            or version in versions
        ):
            fail("live Flyway version is null, non-numeric or duplicated")
        if (
            row.get("type") != "SQL"
            or row.get("success") is not True
            or not isinstance(script, str)
            or not script.endswith(".sql")
            or not isinstance(description, str)
        ):
            fail("live Flyway history contains a failed, non-SQL or malformed row")
        canonical_rows.append(
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

    migrations = target_manifest.get("flywayMigrations")
    if not isinstance(migrations, list) or len(canonical_rows) != len(migrations):
        fail("live Flyway count differs from the signed target")
    for row, migration in zip(canonical_rows, migrations, strict=True):
        if (
            row["version"] != migration.get("version")
            or row["description"] != migration.get("description")
            or row["script"] != migration.get("file")
            or row["checksum"] != migration.get("flywayChecksum")
        ):
            fail("live Flyway version/script/checksum history differs from the signed target")
    canonical_payload = json.dumps(
        canonical_rows, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    projection = "".join(
        f"{row['version']}\t{row['script']}\t{row['checksum']}\n"
        for row in canonical_rows
    ).encode("utf-8")
    return {
        "canonicalHistorySha256": hashlib.sha256(canonical_payload).hexdigest(),
        "headVersion": max(int(version) for version in versions),
        "signedProjectionSha256": hashlib.sha256(projection).hexdigest(),
        "successfulMigrationCount": len(canonical_rows),
    }


def internal_test_role_acl_contract() -> dict[str, Any]:
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
        "defaultSequenceAcl": [
            "uten:SELECT:false",
            "uten:UPDATE:false",
            "uten:USAGE:false",
        ],
        "defaultTableAcl": [
            "uten:DELETE:false",
            "uten:INSERT:false",
            "uten:SELECT:false",
            "uten:UPDATE:false",
        ],
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


def validate_live_database_against_signed_release(
    value: dict[str, Any],
    *,
    target_manifest: dict[str, Any],
    require_internal_role_acl: bool,
    allow_local_recovery_archive: bool = False,
) -> dict[str, Any]:
    """Bind one fixed local database observation to the signed migration inventory."""
    release_guard.exact_keys(
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
        "live recovery database observation",
    )
    require_recovery_schema_version(value, "live recovery database observation")
    if (
        value.get("databaseName") != "uten_imp"
        or value.get("schemaName") != "public"
        or value.get("serverPort") != 5432
        or value.get("serverVersionNum") not in range(160000, 170000)
        or value.get("dataDirectory") != "/data/postgresql/16/main"
        or value.get("configFile") != "/etc/postgresql/16/main/postgresql.conf"
        or value.get("hbaFile") != "/etc/postgresql/16/main/pg_hba.conf"
        or value.get("listenAddresses") != "127.0.0.1,::1"
        or value.get("inRecovery") is not False
    ):
        fail(
            "live query reached an unexpected database/schema/version/config/listener or standby"
        )
    if require_internal_role_acl:
        expected_archive_mode = "on" if allow_local_recovery_archive else "off"
        expected_archive_command = (
            INTERNAL_TEST_LOCAL_ARCHIVE_COMMAND if allow_local_recovery_archive else ""
        )
        if (
            value.get("archiveMode") != expected_archive_mode
            or value.get("archiveCommand") != expected_archive_command
        ):
            fail("internal-test PostgreSQL archive settings differ from the fixed phase")
    postmaster_pid = require_recovery_integer(
        value.get("postmasterPid"), "live PostgreSQL postmaster PID", minimum=2
    )
    systemd_main_pid = require_recovery_integer(
        value.get("systemdMainPid"), "live PostgreSQL systemd MainPID", minimum=2
    )
    if postmaster_pid != systemd_main_pid:
        fail("live PostgreSQL socket instance differs from postgresql@16-main.service")
    tcp_listener_pid = require_recovery_integer(
        value.get("tcpListenerPid"), "live PostgreSQL TCP listener PID", minimum=2
    )
    if tcp_listener_pid != postmaster_pid:
        fail("127.0.0.1:5432 differs from the verified PostgreSQL socket instance")
    system_identifier = release_guard.require_string(
        value.get("systemIdentifier"), "live PostgreSQL system identifier"
    )
    if not POSTGRES_SYSTEM_IDENTIFIER_RE.fullmatch(system_identifier):
        fail("live PostgreSQL system_identifier is malformed")
    timeline = require_recovery_integer(
        value.get("timeline"), "live PostgreSQL timeline", minimum=1, maximum=0xFFFFFFFF
    )
    flyway = canonical_live_flyway_identity(value.get("flywayHistory"), target_manifest)
    if flyway["headVersion"] != int(target_manifest["flywayHeadVersion"]):
        fail("live Flyway head differs from the signed target")
    migrations = target_manifest.get("flywayMigrations")
    if not isinstance(migrations, list) or not migrations:
        fail("signed target has no canonical Flyway migration inventory")
    if flyway["successfulMigrationCount"] != len(migrations):
        fail("live Flyway count differs from the signed target")
    expected_role_acl = internal_test_role_acl_contract()
    if require_internal_role_acl and value.get("roleAclContract") != expected_role_acl:
        fail("live PostgreSQL role/ownership/ACL contract differs")
    role_acl_sha256 = hashlib.sha256(
        json.dumps(
            value.get("roleAclContract"), sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
    ).hexdigest()
    return {
        "archiveCommand": value["archiveCommand"],
        "archiveMode": value["archiveMode"],
        "databaseName": "uten_imp",
        "dataDirectory": "/data/postgresql/16/main",
        "flyway": flyway,
        "schemaName": "public",
        "serverPort": 5432,
        "serverVersionNum": value["serverVersionNum"],
        "roleAclContractSha256": role_acl_sha256,
        "systemdMainPid": systemd_main_pid,
        "systemIdentifier": system_identifier,
        "timeline": timeline,
        "verifiedAtUtc": utc_now(),
        "verifierSha256": DATABASE_RECOVERY_VERIFIER_SHA256,
    }


def validate_live_database_observation(
    value: dict[str, Any],
    *,
    database_receipt: dict[str, Any],
    target_manifest: dict[str, Any],
    require_internal_role_acl: bool | None = None,
    allow_local_recovery_archive: bool = False,
) -> dict[str, Any]:
    if require_internal_role_acl is None:
        require_internal_role_acl = False
    evidence = validate_live_database_against_signed_release(
        value,
        target_manifest=target_manifest,
        require_internal_role_acl=require_internal_role_acl,
        allow_local_recovery_archive=allow_local_recovery_archive,
    )
    detail_identity = database_receipt["detailIdentity"]
    if evidence["systemIdentifier"] != detail_identity["systemIdentifier"]:
        fail("live PostgreSQL system_identifier differs from the accepted authority")
    if evidence["timeline"] != detail_identity["timeline"]:
        fail("live PostgreSQL timeline differs from the accepted authority")
    for key in ("canonicalHistorySha256", "signedProjectionSha256"):
        if evidence["flyway"][key] != detail_identity[key]:
            fail(f"live Flyway {key} differs from the accepted detailed receipt")
    return evidence


def observe_live_database() -> dict[str, Any]:
    """Run the fixed peer-authenticated local query and return one strict object."""
    verifier_bytes = read_root_controlled_bytes(
        DATABASE_RECOVERY_VERIFIER,
        exact_mode=0o644,
        maximum_bytes=4 * 1024 * 1024,
    )
    if not secrets.compare_digest(
        hashlib.sha256(verifier_bytes).hexdigest(),
        DATABASE_RECOVERY_VERIFIER_SHA256,
    ):
        fail("installed database recovery verifier differs from the reviewed digest")
    command = [
        "/usr/sbin/runuser",
        "-u",
        "postgres",
        "--",
        "/usr/bin/python3",
        "-I",
        "-",
    ]
    try:
        result = subprocess.run(
            command,
            input=verifier_bytes,
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
        raise UpdaterError("fixed live database recovery verification could not complete") from exc
    if (
        result.returncode != 0
        or not result.stdout
        or len(result.stdout) > MAX_DATABASE_OBSERVATION_BYTES
        or b"\0" in result.stdout
    ):
        fail("fixed live database recovery verification failed closed")
    try:
        value = strict_json_object(
            result.stdout, "fixed live database recovery verification"
        )
    except UpdaterError:
        raise
    except Exception as exc:
        raise UpdaterError(
            "fixed live database recovery verification returned invalid JSON"
        ) from exc
    return value


def verify_live_signed_database(
    *,
    target_manifest: dict[str, Any],
    allow_local_recovery_archive: bool = False,
) -> dict[str, Any]:
    return validate_live_database_against_signed_release(
        observe_live_database(),
        target_manifest=target_manifest,
        require_internal_role_acl=deployment_profile() == "internal-test",
        allow_local_recovery_archive=allow_local_recovery_archive,
    )


def verify_live_internal_test_signed_database(
    *, target_manifest: dict[str, Any]
) -> dict[str, Any]:
    return validate_live_database_against_signed_release(
        observe_live_database(),
        target_manifest=target_manifest,
        require_internal_role_acl=True,
    )


def verify_live_recovery_database(
    *,
    database_receipt: dict[str, Any],
    target_manifest: dict[str, Any],
    require_internal_role_acl: bool = False,
    allow_local_recovery_archive: bool = False,
) -> dict[str, Any]:
    return validate_live_database_observation(
        observe_live_database(),
        database_receipt=database_receipt,
        target_manifest=target_manifest,
        require_internal_role_acl=require_internal_role_acl,
        allow_local_recovery_archive=allow_local_recovery_archive,
    )


def runtime_database_identity(evidence: dict[str, Any]) -> dict[str, Any]:
    flyway = evidence.get("flyway")
    if not isinstance(flyway, dict):
        fail("live database evidence lacks canonical Flyway identity")
    value = {
        "canonicalHistorySha256": flyway["canonicalHistorySha256"],
        "headVersion": flyway["headVersion"],
        "signedProjectionSha256": flyway["signedProjectionSha256"],
        "successfulMigrationCount": flyway["successfulMigrationCount"],
        "systemIdentifier": evidence["systemIdentifier"],
        "timeline": evidence["timeline"],
    }
    if deployment_profile() == "internal-test":
        expected_role_acl_sha = hashlib.sha256(
            json.dumps(
                internal_test_role_acl_contract(),
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        if evidence.get("roleAclContractSha256") != expected_role_acl_sha:
            fail("live PostgreSQL role/ownership/ACL contract differs")
        value["roleAclContractSha256"] = expected_role_acl_sha
    return value


def installed_manifest_sha256(target: Path) -> str:
    manifest_path = target / ".release/manifest.json"
    require_root_controlled_file(manifest_path)
    return release_guard.sha256_file(manifest_path)


def runtime_authority_value(
    *,
    target: Path,
    manifest: dict[str, Any],
    live_evidence: dict[str, Any],
    first_backup_binding: dict[str, Any] | None = None,
) -> dict[str, Any]:
    value = {
        "commitSha": manifest["commitSha"],
        "databaseIdentity": runtime_database_identity(live_evidence),
        "manifestSha256": installed_manifest_sha256(target),
        "releaseSequence": manifest["releaseSequence"],
        "schemaVersion": 1,
        "verifiedAtUtc": utc_now(),
        "version": manifest["version"],
    }
    if deployment_profile() == "internal-test":
        contract, contract_sha = internal_test_runtime_contract()
        value["runtimeContractId"] = contract["contractId"]
        value["runtimeContractSha256"] = contract_sha
        if first_backup_binding is None:
            active_path = DEFAULT_ROOT_STATE_DIR / "active.json"
            if os.path.lexists(active_path):
                active = strict_json_object(
                    read_root_evidence_bytes(active_path),
                    "active state for runtime first-backup binding",
                )
                observed = active.get("firstBackup")
                if observed is not None:
                    if not isinstance(observed, dict):
                        fail("active first-backup binding is malformed")
                    first_backup_binding = observed
        if first_backup_binding is not None:
            validate_internal_test_first_backup_binding(
                first_backup_binding,
                live_database_identity=runtime_database_identity(live_evidence),
                require_archive=(
                    None
                    if os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION)
                    else True
                ),
            )
            value["firstBackup"] = dict(first_backup_binding)
    return value


def write_runtime_authority(
    *,
    target: Path,
    manifest: dict[str, Any],
    live_evidence: dict[str, Any],
    first_backup_binding: dict[str, Any] | None = None,
) -> dict[str, Any]:
    value = runtime_authority_value(
        target=target,
        manifest=manifest,
        live_evidence=live_evidence,
        first_backup_binding=first_backup_binding,
    )
    atomic_json(RUNTIME_AUTHORITY, value, mode=0o600)
    require_root_controlled_file(RUNTIME_AUTHORITY, secret=True)
    return value


def validate_existing_runtime_authority(
    *,
    target: Path,
    manifest: dict[str, Any],
    live_evidence: dict[str, Any],
    first_backup_binding: dict[str, Any] | None = None,
) -> None:
    require_root_controlled_file(RUNTIME_AUTHORITY, secret=True)
    authority = strict_json_object(
        read_root_evidence_bytes(RUNTIME_AUTHORITY), "runtime authority"
    )
    expected_release = runtime_authority_value(
        target=target,
        manifest=manifest,
        live_evidence=live_evidence,
        first_backup_binding=first_backup_binding,
    )
    expected_keys = set(expected_release)
    release_guard.exact_keys(
        authority,
        expected_keys,
        "runtime authority",
    )
    if authority.get("schemaVersion") != 1 or isinstance(
        authority.get("schemaVersion"), bool
    ):
        fail("runtime authority schema is unsupported")
    require_recovery_timestamp(authority.get("verifiedAtUtc"), "runtime authority time")
    expected_release.pop("verifiedAtUtc")
    if any(
        authority.get(key) != expected
        for key, expected in expected_release.items()
    ):
        fail("live database/current release differs from the committed runtime authority")


def current_boot_id() -> str:
    try:
        value = BOOT_ID_PATH.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise UpdaterError("kernel boot ID cannot be read") from exc
    if not BOOT_ID_RE.fullmatch(value):
        fail("kernel boot ID is malformed")
    return value


def require_runtime_boot_verifier() -> None:
    require_root_controlled_file(RUNTIME_BOOT_VERIFIER)
    details = RUNTIME_BOOT_VERIFIER.lstat()
    if (
        details.st_gid != 0
        or details.st_nlink != 1
        or stat.S_IMODE(details.st_mode) != 0o644
    ):
        fail("runtime boot verifier must be root:root mode 0644 with one hard link")
    if release_guard.sha256_file(RUNTIME_BOOT_VERIFIER) != RUNTIME_BOOT_VERIFIER_SHA256:
        fail("runtime boot verifier differs from the reviewed digest")
    require_root_controlled_file(STORAGE_BOOT_VERIFIER)
    storage_details = STORAGE_BOOT_VERIFIER.lstat()
    if (
        storage_details.st_gid != 0
        or storage_details.st_nlink != 1
        or stat.S_IMODE(storage_details.st_mode) != 0o644
        or release_guard.sha256_file(STORAGE_BOOT_VERIFIER)
        != STORAGE_BOOT_VERIFIER_SHA256
    ):
        fail("runtime storage verifier differs from the reviewed digest")


def prepare_start_authorization(
    *,
    mode: str,
    marker: Path,
    target: Path,
    manifest: dict[str, Any],
    live_evidence: dict[str, Any],
) -> str:
    if mode not in {"activation", "rollback", "recovery"}:
        fail("application start authorization mode is unsupported")
    expected_marker = (
        RECOVERY_IN_PROGRESS_MARKER if mode == "recovery" else ACTIVATION_IN_PROGRESS_MARKER
    )
    if marker != expected_marker:
        fail("application start authorization references the wrong transaction marker")
    require_runtime_boot_verifier()
    require_root_controlled_file(marker, secret=True)
    if os.path.lexists(START_AUTHORIZATION_DIR):
        require_real_directory(START_AUTHORIZATION_DIR, owner_uid=0)
        if (
            START_AUTHORIZATION_DIR.lstat().st_gid != 0
            or stat.S_IMODE(START_AUTHORIZATION_DIR.lstat().st_mode) != 0o700
        ):
            fail("runtime start-authorization directory is unsafe")
    else:
        START_AUTHORIZATION_DIR.mkdir(mode=0o700)
        os.chown(START_AUTHORIZATION_DIR, 0, 0)
        os.chmod(START_AUTHORIZATION_DIR, 0o700)
        fsync_directory(START_AUTHORIZATION_DIR.parent)
    if os.path.lexists(START_AUTHORIZATION):
        require_root_controlled_file(START_AUTHORIZATION, secret=True)
        fail("an unconsumed application start authorization already exists")
    authorization_id = os.urandom(16).hex()
    if not START_AUTHORIZATION_ID_RE.fullmatch(authorization_id):
        fail("generated application start authorization ID is malformed")
    value = {
        "authorizationId": authorization_id,
        "bootId": current_boot_id(),
        "commitSha": manifest["commitSha"],
        "createdAtUtc": utc_now(),
        "databaseIdentity": runtime_database_identity(live_evidence),
        **recovery_issuer_identity(os.getpid()),
        "manifestSha256": installed_manifest_sha256(target),
        "markerPath": str(marker),
        "markerSha256": release_guard.sha256_file(marker),
        "mode": mode,
        "releaseSequence": manifest["releaseSequence"],
        "schemaVersion": 1,
        "version": manifest["version"],
    }
    if deployment_profile() == "internal-test":
        contract, contract_sha = internal_test_runtime_contract()
        value["runtimeContractId"] = contract["contractId"]
        value["runtimeContractSha256"] = contract_sha
    atomic_json(START_AUTHORIZATION, value, mode=0o600)
    require_root_controlled_file(START_AUTHORIZATION, secret=True)
    return authorization_id


def discard_unconsumed_start_authorization(authorization_id: str) -> None:
    if not os.path.lexists(START_AUTHORIZATION):
        return
    require_root_controlled_file(START_AUTHORIZATION, secret=True)
    value = strict_json_object(
        read_root_evidence_bytes(START_AUTHORIZATION), "unconsumed start authorization"
    )
    if value.get("authorizationId") != authorization_id:
        fail("application start authorization changed before cleanup")
    durable_unlink(START_AUTHORIZATION)


def start_application_authorized(
    *,
    mode: str,
    marker: Path,
    target: Path,
    manifest: dict[str, Any],
    live_evidence: dict[str, Any],
) -> None:
    authorization_id = prepare_start_authorization(
        mode=mode,
        marker=marker,
        target=target,
        manifest=manifest,
        live_evidence=live_evidence,
    )
    try:
        start_unit("uten-imp.service")
        if os.path.lexists(START_AUTHORIZATION):
            stop_unit("uten-imp.service")
            fail("runtime boot verifier did not consume its one-time authorization")
    finally:
        discard_unconsumed_start_authorization(authorization_id)


def archive_interrupted_start_authorization(transaction: Path) -> None:
    """Preserve one pre-ExecStart application or migration grant after interruption."""
    candidates = _start_authorization_candidates()
    if not candidates:
        return
    source = candidates[0]
    require_root_controlled_file(source, secret=True)
    raw = read_root_evidence_bytes(source)
    validate_start_authorization(
        strict_json_object(raw, "interrupted one-time authorization")
    )
    destination = transaction / "start-authorization.interrupted.json"
    if os.path.lexists(destination):
        fail("interrupted start-authorization archive already exists")
    atomic_bytes(destination, raw, mode=0o600)
    durable_unlink(source)


def load_database_recovery_receipt(
    *,
    path_text: str,
    expected_sha256: str,
    approval_reference: str,
    target_manifest: dict[str, Any],
) -> dict[str, Any]:
    expected_sha256 = release_guard.require_string(
        expected_sha256, "expected database receipt digest", release_guard.SHA256_RE
    )
    path = Path(path_text)
    if (
        not path.is_absolute()
        or path.parent != RECOVERY_DATABASE_RECEIPTS_DIR
        or not RECOVERY_RECEIPT_NAME_RE.fullmatch(path.name)
    ):
        fail(
            "database receipt must be one canonical direct child of the fixed "
            "root-only receipt directory"
        )
    require_real_directory(RECOVERY_DATABASE_RECEIPTS_DIR, owner_uid=0)
    if RECOVERY_DATABASE_RECEIPTS_DIR.lstat().st_mode & 0o077:
        fail("database receipt directory must be root-only")
    raw = read_root_evidence_bytes(path)
    actual_sha = hashlib.sha256(raw).hexdigest()
    if actual_sha != expected_sha256:
        fail("database receipt digest differs from --expected-database-receipt-sha256")
    value = strict_json_object(raw, "database backup/restore receipt")
    validate_database_recovery_receipt(value)
    if value["approvalReference"] != approval_reference:
        fail("database receipt approval reference differs from the recovery approval")
    if value["targetVersion"] != target_manifest["version"]:
        fail("database receipt target differs from the verified release target")
    if value["flywayHeadVersion"] != target_manifest["flywayHeadVersion"]:
        fail("database receipt Flyway head differs from the verified release target")
    if (
        value["flywayMigrationSetSha256"]
        != target_manifest["flywayMigrationSetSha256"]
    ):
        fail("database receipt Flyway digest differs from the verified release target")
    detail_reference = RECOVERY_DETAIL_REFERENCE_RE.fullmatch(value["evidenceReference"])
    if detail_reference is None:
        fail("database receipt detailed evidence reference is malformed")
    detail_path = Path(detail_reference.group(1))
    detail_sha = detail_reference.group(2)
    if (
        detail_path.parent != RECOVERY_DATABASE_DETAIL_DIR
        or not RECOVERY_RECEIPT_NAME_RE.fullmatch(detail_path.name)
    ):
        fail("database detailed receipt escaped its fixed root-only directory")
    require_real_directory(RECOVERY_DATABASE_DETAIL_DIR, owner_uid=0)
    if RECOVERY_DATABASE_DETAIL_DIR.lstat().st_mode & 0o077:
        fail("database detailed receipt directory must be root-only")
    detail_raw = read_root_evidence_bytes(detail_path)
    if hashlib.sha256(detail_raw).hexdigest() != detail_sha:
        fail("database detailed receipt digest differs from evidenceReference")
    detail_fields = strict_json_object(detail_raw, "detailed database recovery receipt")
    detail_identity = validate_database_recovery_detail(
        detail_fields,
        narrow=value,
        target_manifest=target_manifest,
    )
    return {
        "detailFields": detail_fields,
        "detailIdentity": detail_identity,
        "detailPath": str(detail_path),
        "detailSha256": detail_sha,
        "fields": value,
        "path": str(path),
        "sha256": actual_sha,
        "sizeBytes": len(raw),
    }


def archive_root_evidence(
    source: Path, destination: Path, expected_sha256: str
) -> bytes:
    """Move exact evidence bytes and persist destination before source-directory removal."""
    if destination.parent == source.parent:
        fail("recovery evidence archive must cross into its transaction directory")
    require_real_directory(destination.parent, owner_uid=0)
    if destination.parent.lstat().st_mode & 0o077:
        fail("recovery transaction directory must be root-only")
    if os.path.lexists(destination):
        fail(f"recovery evidence destination already exists: {destination}")
    raw = read_root_evidence_bytes(source)
    if hashlib.sha256(raw).hexdigest() != expected_sha256:
        fail(f"recovery evidence changed before archive: {source}")
    os.replace(source, destination)
    fsync_directory(destination.parent)
    fsync_directory(source.parent)
    archived = read_root_evidence_bytes(destination)
    if archived != raw:
        fail("archived recovery evidence bytes differ from the original marker")
    return raw


def create_recovery_transaction(plan_sha256: str, action: str) -> Path:
    release_guard.require_string(
        plan_sha256, "recovery transaction plan digest", release_guard.SHA256_RE
    )
    if action not in {
        "finish-activation", "restore-previous", "abandon-candidate",
        "remain-contained",
    }:
        fail("recovery transaction action is unsupported")
    require_real_directory(RECOVERY_EVIDENCE_DIR, owner_uid=0)
    if RECOVERY_EVIDENCE_DIR.lstat().st_mode & 0o077:
        fail("recovery evidence directory must be root-only")
    transaction = RECOVERY_EVIDENCE_DIR / f"{plan_sha256[:16]}-{action}"
    if os.path.lexists(transaction):
        require_real_directory(transaction, owner_uid=0)
        if stat.S_IMODE(transaction.lstat().st_mode) != 0o700:
            fail("resumable recovery transaction has unsafe permissions")
    else:
        os.mkdir(transaction, 0o700)
        os.chown(transaction, 0, 0)
        os.chmod(transaction, 0o700)
        fsync_directory(RECOVERY_EVIDENCE_DIR)
    require_real_directory(transaction, owner_uid=0)
    return transaction


def validate_start_authorization(value: dict[str, Any]) -> str:
    """Validate volatile one-time authorization before preserving it as evidence."""
    if "nonce" in value:
        return validate_migration_authorization(value)
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
    profile = deployment_profile()
    if profile == "internal-test":
        expected_keys.update({"runtimeContractId", "runtimeContractSha256"})
    release_guard.exact_keys(
        value,
        expected_keys,
        "one-time start authorization",
    )
    require_recovery_schema_version(value, "one-time start authorization")
    release_guard.require_string(
        value.get("authorizationId"),
        "start authorization ID",
        START_AUTHORIZATION_ID_RE,
    )
    release_guard.require_string(
        value.get("issuerCommandLineSha256"),
        "start authorization issuer command digest",
        release_guard.SHA256_RE,
    )
    release_guard.require_string(
        value.get("issuerExecutableSha256"),
        "start authorization issuer executable digest",
        release_guard.SHA256_RE,
    )
    issuer_path = release_guard.require_string(
        value.get("issuerExecutablePath"), "start authorization issuer executable"
    )
    if not re.fullmatch(r"/usr/bin/python3(?:\.[0-9]+)?", issuer_path):
        fail("start authorization issuer executable path is not fixed")
    require_recovery_integer(
        value.get("issuerPid"), "start authorization issuer PID", minimum=2
    )
    require_recovery_integer(
        value.get("issuerStartTimeTicks"),
        "start authorization issuer start time",
        minimum=1,
    )
    release_guard.require_string(value.get("bootId"), "start authorization boot ID", BOOT_ID_RE)
    release_guard.require_string(
        value.get("commitSha"), "start authorization commit", release_guard.COMMIT_RE
    )
    require_recovery_timestamp(
        value.get("createdAtUtc"), "start authorization creation time"
    )
    for key in ("manifestSha256", "markerSha256"):
        release_guard.require_string(
            value.get(key), f"start authorization {key}", release_guard.SHA256_RE
        )
    version = release_guard.require_string(
        value.get("version"), "start authorization version"
    )
    if release_guard.version_sequence(version) != value.get("releaseSequence"):
        fail("start authorization version/sequence is inconsistent")
    mode = value.get("mode")
    marker_path = value.get("markerPath")
    expected_marker = (
        str(RECOVERY_IN_PROGRESS_MARKER)
        if mode == "recovery"
        else str(ACTIVATION_IN_PROGRESS_MARKER)
        if mode in {"activation", "rollback"}
        else None
    )
    if expected_marker is None or marker_path != expected_marker:
        fail("start authorization mode/marker path is inconsistent")
    identity = value.get("databaseIdentity")
    if not isinstance(identity, dict):
        fail("start authorization database identity is malformed")
    identity_keys = {
        "canonicalHistorySha256",
        "headVersion",
        "signedProjectionSha256",
        "successfulMigrationCount",
        "systemIdentifier",
        "timeline",
    }
    identity_digest_keys = [
        "canonicalHistorySha256",
        "signedProjectionSha256",
    ]
    if profile == "internal-test":
        identity_keys.add("roleAclContractSha256")
        identity_digest_keys.append("roleAclContractSha256")
    release_guard.exact_keys(
        identity,
        identity_keys,
        "start authorization database identity",
    )
    for key in identity_digest_keys:
        release_guard.require_string(
            identity.get(key),
            f"start authorization database identity {key}",
            release_guard.SHA256_RE,
        )
    system_identifier = release_guard.require_string(
        identity.get("systemIdentifier"),
        "start authorization database system identifier",
    )
    if not POSTGRES_SYSTEM_IDENTIFIER_RE.fullmatch(system_identifier):
        fail("start authorization database system identifier is malformed")
    require_recovery_integer(
        identity.get("timeline"), "start authorization database timeline", minimum=1
    )
    require_recovery_integer(
        identity.get("headVersion"), "start authorization Flyway head", minimum=1
    )
    require_recovery_integer(
        identity.get("successfulMigrationCount"),
        "start authorization Flyway count",
        minimum=1,
    )
    return "start-authorization-v1"


def interrupted_marker_specs() -> dict[str, tuple[Path, str, Any]]:
    """Return the fixed interrupted marker set; callers cannot supply paths."""
    return {
        "activation": (
            ACTIVATION_IN_PROGRESS_MARKER,
            "activation-in-progress marker",
            validate_activation_in_progress_marker,
        ),
        "recovery": (
            RECOVERY_IN_PROGRESS_MARKER,
            "recovery-in-progress marker",
            validate_recovery_in_progress_marker,
        ),
        "boot": (
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
            "boot-enablement-in-progress marker",
            validate_boot_enablement_marker,
        ),
    }


def interrupted_archive_path(transaction: Path, marker_path: Path) -> Path:
    return transaction / f"{marker_path.stem}.original.json"


def interrupted_containment_confirmation(state_kind: str, plan_sha256: str) -> str:
    interrupted_state_kind(state_kind.split("+"))
    release_guard.require_string(
        plan_sha256, "interrupted containment plan digest", release_guard.SHA256_RE
    )
    return f"CONTAIN-INTERRUPTED:{state_kind}:{plan_sha256}"


def require_interrupted_transaction(transaction: Path, plan_sha256: str) -> None:
    expected = RECOVERY_EVIDENCE_DIR / f"interrupted-{plan_sha256}"
    if transaction != expected:
        fail("interrupted containment transaction path differs from its plan digest")
    require_real_directory(transaction, owner_uid=0)
    if transaction.lstat().st_mode & 0o077:
        fail("interrupted containment transaction directory must be root-only")


def create_interrupted_transaction(plan_sha256: str) -> Path:
    """Create or resume the one deterministic evidence directory for this plan."""
    release_guard.require_string(
        plan_sha256, "interrupted containment plan digest", release_guard.SHA256_RE
    )
    require_real_directory(RECOVERY_EVIDENCE_DIR, owner_uid=0)
    if RECOVERY_EVIDENCE_DIR.lstat().st_mode & 0o077:
        fail("recovery evidence directory must be root-only")
    transaction = RECOVERY_EVIDENCE_DIR / f"interrupted-{plan_sha256}"
    if os.path.lexists(transaction):
        require_interrupted_transaction(transaction, plan_sha256)
        return transaction
    os.mkdir(transaction, 0o700)
    os.chown(transaction, 0, 0)
    os.chmod(transaction, 0o700)
    require_interrupted_transaction(transaction, plan_sha256)
    fsync_directory(RECOVERY_EVIDENCE_DIR)
    return transaction


def validate_interrupted_containment_plan(value: dict[str, Any]) -> str:
    release_guard.exact_keys(
        value,
        {"kind", "planBasis", "planSha256", "schemaVersion"},
        "interrupted containment plan",
    )
    require_recovery_schema_version(value, "interrupted containment plan")
    if value.get("kind") != "uten-imp-interrupted-containment-plan":
        fail("interrupted containment plan kind is not canonical")
    basis = value.get("planBasis")
    if not isinstance(basis, dict):
        fail("interrupted containment plan basis is malformed")
    plan_sha = release_guard.require_string(
        value.get("planSha256"),
        "interrupted containment plan digest",
        release_guard.SHA256_RE,
    )
    if canonical_json_sha256(basis) != plan_sha:
        fail("interrupted containment plan digest differs from its canonical basis")
    return "interrupted-containment-plan-v1"


def validate_interrupted_containment_receipt(value: dict[str, Any]) -> str:
    release_guard.exact_keys(
        value,
        {
            "action",
            "activationFailureMarkerPath",
            "activationFailureMarkerSha256",
            "completedAtUtc",
            "interruptedMarkerArchive",
            "planSha256",
            "schemaVersion",
            "startAuthorizationArchive",
            "stateKind",
            "status",
            "transactionDirectory",
        },
        "interrupted containment receipt",
    )
    require_recovery_schema_version(value, "interrupted containment receipt")
    if value.get("action") != "contain" or value.get("status") != "contained-no-start":
        fail("interrupted containment receipt control fields are not canonical")
    require_recovery_timestamp(
        value.get("completedAtUtc"), "interrupted containment completion time"
    )
    plan_sha = release_guard.require_string(
        value.get("planSha256"),
        "interrupted containment receipt plan digest",
        release_guard.SHA256_RE,
    )
    release_guard.require_string(
        value.get("activationFailureMarkerSha256"),
        "interrupted containment gate digest",
        release_guard.SHA256_RE,
    )
    if value.get("activationFailureMarkerPath") != str(ACTIVATION_FAILURE_MARKER):
        fail("interrupted containment receipt gate path is not fixed")
    transaction = Path(
        release_guard.require_string(
            value.get("transactionDirectory"),
            "interrupted containment receipt transaction directory",
        )
    )
    if transaction != RECOVERY_EVIDENCE_DIR / f"interrupted-{plan_sha}":
        fail("interrupted containment receipt transaction is not plan-bound")
    archives = value.get("interruptedMarkerArchive")
    if not isinstance(archives, dict):
        fail("interrupted containment receipt archive map is malformed")
    state_kind = interrupted_state_kind(set(archives))
    if value.get("stateKind") != state_kind:
        fail("interrupted containment receipt state kind differs from its archive set")
    specs = interrupted_marker_specs()
    for name, evidence in archives.items():
        if not isinstance(evidence, dict) or set(evidence) != {"path", "sha256"}:
            fail(f"interrupted {name} archive receipt is malformed")
        release_guard.require_string(
            evidence.get("sha256"),
            f"interrupted {name} archive digest",
            release_guard.SHA256_RE,
        )
        expected_path = interrupted_archive_path(transaction, specs[name][0])
        if evidence.get("path") != str(expected_path):
            fail(f"interrupted {name} archive path is not fixed")
    authorization_archive = value.get("startAuthorizationArchive")
    if authorization_archive is not None:
        if not isinstance(authorization_archive, dict) or set(
            authorization_archive
        ) != {"originalPath", "path", "sha256"}:
            fail("interrupted start authorization archive receipt is malformed")
        original = Path(
            release_guard.require_string(
                authorization_archive.get("originalPath"),
                "archived start authorization original path",
            )
        )
        application_path = (
            original.parent == START_AUTHORIZATION_DIR
            and (
                original == START_AUTHORIZATION
                or START_AUTHORIZATION_CONSUMED_RE.fullmatch(original.name)
            )
        )
        migration_path = (
            original.parent == MIGRATION_AUTHORIZATION_DIR
            and (
                original == MIGRATION_AUTHORIZATION
                or MIGRATION_AUTHORIZATION_ARCHIVE_RE.fullmatch(original.name)
            )
        )
        if not application_path and not migration_path:
            fail("archived start authorization original path is not fixed")
        if authorization_archive.get("path") != str(
            _start_authorization_archive_path(transaction)
        ):
            fail("archived start authorization destination path is not fixed")
        release_guard.require_string(
            authorization_archive.get("sha256"),
            "archived start authorization digest",
            release_guard.SHA256_RE,
        )
    return "interrupted-containment-receipt-v1"


def _normalized_interrupted_observation(
    evidence_path: Path,
    source_path: Path,
    label: str,
    validator: Any,
) -> dict[str, Any]:
    observation, _ = root_json_observation(evidence_path, label, validator)
    observation["path"] = str(source_path)
    return observation


def _start_authorization_candidates() -> list[Path]:
    candidates: list[Path] = []
    if os.path.lexists(START_AUTHORIZATION_DIR):
        require_real_directory(START_AUTHORIZATION_DIR, owner_uid=0)
        details = START_AUTHORIZATION_DIR.lstat()
        if details.st_gid != 0 or stat.S_IMODE(details.st_mode) != 0o700:
            fail("runtime start-authorization directory must be root:root mode 0700")
        try:
            entries = sorted(START_AUTHORIZATION_DIR.iterdir(), key=lambda path: path.name)
        except OSError as exc:
            raise UpdaterError("cannot enumerate runtime start-authorization evidence") from exc
        for entry in entries:
            if entry == START_AUTHORIZATION or START_AUTHORIZATION_CONSUMED_RE.fullmatch(
                entry.name
            ):
                candidates.append(entry)
            else:
                fail(
                    f"unexpected entry in the fixed start-authorization directory: {entry.name}"
                )
    migration_entries = _migration_authorization_entries()
    candidates.extend(migration_entries)
    if len(candidates) > 1:
        fail("multiple application/migration one-time authorizations are present")
    return candidates


def _start_authorization_snapshot_path(transaction: Path) -> Path:
    return transaction / "start-authorization.precontainment.json"


def _start_authorization_archive_path(transaction: Path) -> Path:
    return transaction / "start-authorization.interrupted.json"


def observe_interrupted_start_authorization(
    containment_gate: dict[str, Any] | None,
    transaction: Path | None,
) -> dict[str, Any] | None:
    candidates = _start_authorization_candidates()
    expected: dict[str, Any] | None = None
    if containment_gate is not None:
        expected = containment_gate["fields"]["startAuthorization"]
    if expected is None:
        if containment_gate is not None and candidates:
            fail("an unexpected start authorization appeared after containment authorization")
        if transaction is not None and any(
            os.path.lexists(path)
            for path in (
                _start_authorization_snapshot_path(transaction),
                _start_authorization_archive_path(transaction),
            )
        ):
            fail("unexpected persisted start authorization evidence is present")
        if not candidates:
            return None
        source = candidates[0]
        return _normalized_interrupted_observation(
            source,
            source,
            "one-time start authorization",
            validate_start_authorization,
        )

    if transaction is None:
        fail("start authorization containment transaction is missing")
    original = Path(expected["path"])
    if candidates and candidates[0] != original:
        fail("a different start authorization appeared after containment authorization")
    evidence_paths = [
        path
        for path in (
            original if candidates else None,
            _start_authorization_snapshot_path(transaction),
            _start_authorization_archive_path(transaction),
        )
        if path is not None and os.path.lexists(path)
    ]
    if not evidence_paths:
        fail("plan-bound start authorization evidence is missing from all fixed locations")
    observations = [
        _normalized_interrupted_observation(
            path,
            original,
            "contained one-time start authorization",
            validate_start_authorization,
        )
        for path in evidence_paths
    ]
    if any(observation["sha256"] != expected["sha256"] for observation in observations):
        fail("plan-bound start authorization evidence digest changed")
    if any(
        observation["fields"] != observations[0]["fields"]
        for observation in observations[1:]
    ):
        fail("plan-bound start authorization copies differ")
    return observations[0]


def _ensure_start_authorization_snapshot(
    transaction: Path, observation: dict[str, Any] | None
) -> None:
    snapshot = _start_authorization_snapshot_path(transaction)
    archive = _start_authorization_archive_path(transaction)
    if observation is None:
        if os.path.lexists(snapshot) or os.path.lexists(archive):
            fail("unexpected start authorization evidence exists for an empty plan")
        return
    expected_sha = observation["sha256"]
    if os.path.lexists(archive):
        archived = _normalized_interrupted_observation(
            archive,
            Path(observation["path"]),
            "archived one-time start authorization",
            validate_start_authorization,
        )
        if archived["sha256"] != expected_sha:
            fail("archived start authorization digest differs from the plan")
        return
    if os.path.lexists(snapshot):
        persisted = _normalized_interrupted_observation(
            snapshot,
            Path(observation["path"]),
            "snapshotted one-time start authorization",
            validate_start_authorization,
        )
        if persisted["sha256"] != expected_sha:
            fail("start authorization snapshot digest differs from the plan")
        return
    source = Path(observation["path"])
    raw = read_root_evidence_bytes(source)
    if hashlib.sha256(raw).hexdigest() != expected_sha:
        fail("start authorization changed before persistent snapshot")
    atomic_bytes(snapshot, raw, mode=0o600)
    persisted = read_root_evidence_bytes(snapshot)
    if persisted != raw:
        fail("persistent start authorization snapshot differs from the source")


def archive_plan_bound_start_authorization(
    transaction: Path, observation: dict[str, Any] | None
) -> dict[str, str] | None:
    """Finalize a durable cross-filesystem authorization archive after shutdown."""
    if observation is None:
        if _start_authorization_candidates():
            fail("an unplanned start authorization appeared before receipt")
        return None
    original = Path(observation["path"])
    expected_sha = observation["sha256"]
    snapshot = _start_authorization_snapshot_path(transaction)
    archive = _start_authorization_archive_path(transaction)
    _ensure_start_authorization_snapshot(transaction, observation)

    candidates = _start_authorization_candidates()
    if candidates and candidates[0] != original:
        fail("start authorization path changed before archive")
    if candidates:
        live_raw = read_root_evidence_bytes(original)
        if hashlib.sha256(live_raw).hexdigest() != expected_sha:
            fail("start authorization changed before archive")
        durable_unlink(original)
    if os.path.lexists(snapshot):
        if os.path.lexists(archive):
            fail("start authorization snapshot and final archive both exist")
        os.replace(snapshot, archive)
        fsync_directory(transaction)
    archived_raw = read_root_evidence_bytes(archive)
    if hashlib.sha256(archived_raw).hexdigest() != expected_sha:
        fail("final start authorization archive digest differs from the plan")
    if _start_authorization_candidates():
        fail("live start authorization remains after archive")
    return {
        "originalPath": str(original),
        "path": str(archive),
        "sha256": expected_sha,
    }


def _interrupted_plan_marker(observation: dict[str, Any]) -> dict[str, Any]:
    return {
        "path": observation["path"],
        "schemaKind": observation["schemaKind"],
        "sha256": observation["sha256"],
        "sizeBytes": observation["sizeBytes"],
    }


def _validate_interrupted_marker_relationships(
    markers: dict[str, dict[str, Any]], state_kind: str
) -> None:
    if state_kind == "activation+boot":
        activation = markers["activation"]["fields"]
        boot = markers["boot"]["fields"]
        if any(
            activation[key] != boot[key]
            for key in ("version", "commitSha", "releaseSequence")
        ):
            fail("activation and boot interrupted markers identify different releases")
    if state_kind == "recovery+boot":
        recovery = markers["recovery"]["fields"]
        boot = markers["boot"]["fields"]
        if recovery["targetVersion"] != boot["version"]:
            fail("recovery and boot interrupted markers identify different releases")


def build_interrupted_containment_assessment() -> dict[str, Any]:
    """Assess only fixed interrupted markers without querying or changing the database."""
    require_real_directory(DEFAULT_ROOT_STATE_DIR, owner_uid=0)
    require_real_directory(RECOVERY_EVIDENCE_DIR, owner_uid=0)
    if RECOVERY_EVIDENCE_DIR.lstat().st_mode & 0o077:
        fail("recovery evidence directory must be root-only")

    containment_gate: dict[str, Any] | None = None
    preexisting_failure: dict[str, Any] | None = None
    if os.path.lexists(ACTIVATION_FAILURE_MARKER):
        observed_failure, _ = root_json_observation(
            ACTIVATION_FAILURE_MARKER,
            "activation-failed marker",
            validate_activation_failure_marker,
        )
        if observed_failure["schemaKind"] == "interrupted-containment-v1":
            containment_gate = observed_failure
        else:
            preexisting_failure = observed_failure

    specs = interrupted_marker_specs()
    source_names = {
        name for name, (path, _label, _validator) in specs.items() if os.path.lexists(path)
    }
    expected_names: set[str] = set()
    transaction: Path | None = None
    if containment_gate is not None:
        gate_fields = containment_gate["fields"]
        expected_names = set(gate_fields["interruptedMarkerSha256"])
        transaction = Path(gate_fields["transactionDirectory"])
        require_interrupted_transaction(transaction, gate_fields["planSha256"])
    marker_names = source_names | expected_names
    state_kind = interrupted_state_kind(marker_names)
    if containment_gate is not None and marker_names != expected_names:
        fail("an unexpected interrupted marker appeared after containment authorization")
    if preexisting_failure is not None and "recovery" not in marker_names:
        fail(
            "an unrelated activation-failed marker already exists; use the ordinary "
            "evidence-driven recovery assessment and do not delete either marker"
        )

    markers: dict[str, dict[str, Any]] = {}
    for name in specs:
        if name not in marker_names:
            continue
        source, label, validator = specs[name]
        archive = (
            interrupted_archive_path(transaction, source)
            if transaction is not None
            else None
        )
        source_present = os.path.lexists(source)
        archive_present = archive is not None and os.path.lexists(archive)
        if source_present and archive_present:
            fail(f"interrupted {name} marker exists in both live and archive locations")
        if source_present:
            observation = _normalized_interrupted_observation(
                source, source, label, validator
            )
        elif archive_present and archive is not None:
            observation = _normalized_interrupted_observation(
                archive, source, f"archived {label}", validator
            )
        else:
            fail(f"interrupted {name} marker evidence is missing from both fixed locations")
        markers[name] = observation

    _validate_interrupted_marker_relationships(markers, state_kind)
    recovery_marker = markers.get("recovery")
    if containment_gate is not None and recovery_marker is not None:
        preexisting_failure = _interrupted_original_failure(recovery_marker)
    if preexisting_failure is not None:
        if recovery_marker is None:
            fail("preexisting activation failure is not bound to an interrupted recovery")
        if preexisting_failure["sha256"] != recovery_marker["fields"]["markerSha256"]:
            fail("interrupted recovery marker does not bind the preexisting failure gate")
    start_authorization = observe_interrupted_start_authorization(
        containment_gate, transaction
    )
    basis = {
        "action": "contain",
        "markers": {
            name: _interrupted_plan_marker(markers[name]) for name in specs if name in markers
        },
        "paths": {
            "activationFailure": str(ACTIVATION_FAILURE_MARKER),
            "operationLock": str(DEFAULT_LOCK_FILE),
            "recoveryEvidence": str(RECOVERY_EVIDENCE_DIR),
        },
        "preexistingFailure": (
            _interrupted_plan_marker(preexisting_failure)
            if preexisting_failure is not None
            else None
        ),
        "schemaVersion": 1,
        "startAuthorization": (
            _interrupted_plan_marker(start_authorization)
            if start_authorization is not None
            else None
        ),
        "stateKind": state_kind,
    }
    plan_sha = canonical_json_sha256(basis)
    receipt: dict[str, Any] | None = None
    if containment_gate is not None:
        gate_fields = containment_gate["fields"]
        expected_digests = {name: markers[name]["sha256"] for name in markers}
        expected_authorization = (
            {
                "path": start_authorization["path"],
                "sha256": start_authorization["sha256"],
            }
            if start_authorization is not None
            else None
        )
        if (
            gate_fields["planSha256"] != plan_sha
            or gate_fields["stateKind"] != state_kind
            or gate_fields["interruptedMarkerSha256"] != expected_digests
            or gate_fields["startAuthorization"] != expected_authorization
        ):
            fail("interrupted marker evidence drifted from the persistent containment gate")
        if transaction is None:
            fail("interrupted containment transaction evidence is missing")
        plan_observation, _ = root_json_observation(
            transaction / INTERRUPTED_CONTAINMENT_PLAN,
            "interrupted containment plan",
            validate_interrupted_containment_plan,
        )
        if (
            plan_observation["fields"]["planSha256"] != plan_sha
            or plan_observation["fields"]["planBasis"] != basis
        ):
            fail("persistent interrupted containment plan evidence drifted")
        receipt_path = transaction / INTERRUPTED_CONTAINMENT_RECEIPT
        if os.path.lexists(receipt_path):
            receipt, _ = root_json_observation(
                receipt_path,
                "interrupted containment receipt",
                validate_interrupted_containment_receipt,
            )
            receipt_fields = receipt["fields"]
            if (
                receipt_fields["planSha256"] != plan_sha
                or receipt_fields["stateKind"] != state_kind
                or receipt_fields["activationFailureMarkerSha256"]
                != containment_gate["sha256"]
                or {
                    name: evidence["sha256"]
                    for name, evidence in receipt_fields["interruptedMarkerArchive"].items()
                }
                != expected_digests
                or receipt_fields["startAuthorizationArchive"]
                != (
                    {
                        "originalPath": start_authorization["path"],
                        "path": str(_start_authorization_archive_path(transaction)),
                        "sha256": start_authorization["sha256"],
                    }
                    if start_authorization is not None
                    else None
                )
            ):
                fail("interrupted containment receipt drifted from its gate and plan")

    controlled_units = tuple(
        dict.fromkeys(
            (
                "nginx.service",
                APPLICATION_UNIT,
                MIGRATION_UNIT,
                *WATCHDOG_SERVICES,
                *WATCHDOG_TIMERS,
            )
        )
    )
    return {
        "actions": {
            "contain": {
                "allowed": True,
                "reasons": [],
                "requiredConfirmation": interrupted_containment_confirmation(
                    state_kind, plan_sha
                ),
            }
        },
        "kind": "uten-imp-interrupted-containment-assessment",
        "planBasis": basis,
        "planSha256": plan_sha,
        "readOnly": True,
        "schemaVersion": 1,
        "state": {
            "containmentGate": containment_gate,
            "markers": markers,
            "preexistingFailure": preexisting_failure,
            "receipt": receipt,
            "startAuthorization": start_authorization,
            "stateKind": state_kind,
            "transactionDirectory": str(transaction) if transaction is not None else None,
            "units": {unit: observe_recovery_unit(unit) for unit in controlled_units},
        },
    }


def _ensure_interrupted_plan(
    transaction: Path, assessment: dict[str, Any]
) -> None:
    path = transaction / INTERRUPTED_CONTAINMENT_PLAN
    expected = {
        "kind": "uten-imp-interrupted-containment-plan",
        "planBasis": assessment["planBasis"],
        "planSha256": assessment["planSha256"],
        "schemaVersion": 1,
    }
    if os.path.lexists(path):
        observation, _ = root_json_observation(
            path, "interrupted containment plan", validate_interrupted_containment_plan
        )
        if observation["fields"] != expected:
            fail("existing interrupted containment plan evidence differs")
        return
    atomic_json(path, expected, mode=0o600)
    observation, _ = root_json_observation(
        path, "interrupted containment plan", validate_interrupted_containment_plan
    )
    if observation["fields"] != expected:
        fail("persisted interrupted containment plan evidence differs")


def _stop_and_disable_for_interrupted_containment() -> None:
    """Best-effort every close action, then require an exact fail-closed result."""
    controlled_units = tuple(
        dict.fromkeys(
            (
                "nginx.service",
                APPLICATION_UNIT,
                MIGRATION_UNIT,
                *WATCHDOG_SERVICES,
                *WATCHDOG_TIMERS,
            )
        )
    )
    problems: list[str] = []
    for unit in controlled_units:
        try:
            stop_unit(unit)
        except Exception as exc:
            problems.append(f"stop {unit}: {exc}")
    for unit in BOOT_UNITS:
        try:
            run(["systemctl", "disable", unit], check=False)
        except Exception as exc:
            problems.append(f"disable {unit}: {exc}")
    try:
        fsync_boot_enablement()
    except Exception as exc:
        problems.append(f"boot enablement fsync: {exc}")
    for unit in controlled_units:
        try:
            observed = observe_recovery_unit(unit)
            if observed.get("error"):
                problems.append(
                    f"final state {unit}: {observed['error']}"
                )
                continue
            if observed.get("active") is not False:
                problems.append(f"inactive check {unit}: unit remains active")
            if unit in BOOT_UNITS and observed.get("enabled") is not False:
                problems.append(f"disabled check {unit}: unit remains enabled")
        except Exception as exc:
            problems.append(f"final state {unit}: {exc}")
    if problems:
        for problem in problems:
            log(f"interrupted containment problem: {problem}", "err")
        fail(
            "interrupted transaction remains persistently gated, but stop/disable "
            "containment could not be fully verified"
        )


def contain_interrupted_transaction(assessment: dict[str, Any]) -> dict[str, Any]:
    """Persist a gate, close every entry path, archive markers, and never start."""
    if assessment.get("kind") != "uten-imp-interrupted-containment-assessment":
        fail("interrupted containment assessment kind is unsupported")
    plan_sha = assessment["planSha256"]
    if canonical_json_sha256(assessment["planBasis"]) != plan_sha:
        fail("interrupted containment assessment plan digest is inconsistent")
    state = assessment["state"]
    markers = state["markers"]
    state_kind = state["stateKind"]
    marker_digests = {name: marker["sha256"] for name, marker in markers.items()}
    start_authorization = state["startAuthorization"]
    gate_observation = state["containmentGate"]
    preexisting_failure = state.get("preexistingFailure")

    transaction = create_interrupted_transaction(plan_sha)
    _ensure_interrupted_plan(transaction, assessment)
    # /run is volatile: persist the exact bytes before the durable gate so a
    # whole-machine power loss cannot erase evidence that the plan already bound.
    _ensure_start_authorization_snapshot(transaction, start_authorization)
    if preexisting_failure is not None:
        recovery_marker = markers.get("recovery")
        if recovery_marker is None:
            fail("double-marker interrupted recovery lost its recovery marker")
        # A recovery apply writes recovery-in-progress before it archives the
        # existing failure gate.  A SIGKILL in that necessary ordering window
        # leaves both live.  Snapshot the exact original into the recovery's own
        # transaction first, then atomically replace (never remove) the live gate.
        ensure_interrupted_recovery_original_failure(
            recovery_marker, preexisting_failure
        )
    if gate_observation is None:
        gate_fields = {
            "containmentStartedAtUtc": utc_now(),
            "interruptedMarkerSha256": marker_digests,
            "planSha256": plan_sha,
            "reason": "interrupted-transaction-containment",
            "recoveryRequired": True,
            "schemaVersion": 1,
            "startAuthorization": (
                {
                    "path": start_authorization["path"],
                    "sha256": start_authorization["sha256"],
                }
                if start_authorization is not None
                else None
            ),
            "stateKind": state_kind,
            "transactionDirectory": str(transaction),
        }
        atomic_json(ACTIVATION_FAILURE_MARKER, gate_fields, mode=0o600)
        gate_observation, _ = root_json_observation(
            ACTIVATION_FAILURE_MARKER,
            "activation-failed marker",
            validate_activation_failure_marker,
        )
        if (
            gate_observation["schemaKind"] != "interrupted-containment-v1"
            or gate_observation["fields"] != gate_fields
        ):
            fail("persistent interrupted containment gate differs after write")
    else:
        if gate_observation["fields"]["transactionDirectory"] != str(transaction):
            fail("persistent interrupted containment gate transaction changed")

    # The durable activation-failed gate must exist before any mutable systemd action.
    _stop_and_disable_for_interrupted_containment()
    authorization_archive = archive_plan_bound_start_authorization(
        transaction, start_authorization
    )

    specs = interrupted_marker_specs()
    archives: dict[str, dict[str, str]] = {}
    for name in specs:
        if name not in markers:
            continue
        source, label, validator = specs[name]
        destination = interrupted_archive_path(transaction, source)
        source_present = os.path.lexists(source)
        destination_present = os.path.lexists(destination)
        if source_present and destination_present:
            fail(f"interrupted {name} marker is duplicated during archive")
        if source_present:
            archive_root_evidence(source, destination, markers[name]["sha256"])
        elif destination_present:
            archived = _normalized_interrupted_observation(
                destination, source, f"archived {label}", validator
            )
            if archived["sha256"] != markers[name]["sha256"]:
                fail(f"archived interrupted {name} marker digest changed")
        else:
            fail(f"interrupted {name} marker disappeared before archive")
        archives[name] = {
            "path": str(destination),
            "sha256": markers[name]["sha256"],
        }

    if any(os.path.lexists(path) for path, _label, _validator in specs.values()):
        fail("a live interrupted marker remains or appeared after containment archive")

    receipt_path = transaction / INTERRUPTED_CONTAINMENT_RECEIPT
    expected_receipt = {
        "action": "contain",
        "activationFailureMarkerPath": str(ACTIVATION_FAILURE_MARKER),
        "activationFailureMarkerSha256": gate_observation["sha256"],
        "completedAtUtc": utc_now(),
        "interruptedMarkerArchive": archives,
        "planSha256": plan_sha,
        "schemaVersion": 1,
        "startAuthorizationArchive": authorization_archive,
        "stateKind": state_kind,
        "status": "contained-no-start",
        "transactionDirectory": str(transaction),
    }
    if os.path.lexists(receipt_path):
        receipt_observation, _ = root_json_observation(
            receipt_path,
            "interrupted containment receipt",
            validate_interrupted_containment_receipt,
        )
        existing = receipt_observation["fields"]
        comparable = dict(expected_receipt)
        comparable["completedAtUtc"] = existing.get("completedAtUtc")
        if existing != comparable:
            fail("existing interrupted containment receipt evidence differs")
        return existing
    atomic_json(receipt_path, expected_receipt, mode=0o600)
    receipt_observation, _ = root_json_observation(
        receipt_path,
        "interrupted containment receipt",
        validate_interrupted_containment_receipt,
    )
    if receipt_observation["fields"] != expected_receipt:
        fail("persisted interrupted containment receipt differs after write")
    return expected_receipt


def contain_recovery_failure(
    *,
    original_marker: bytes,
    marker_sha256: str,
    transaction: Path,
    recovery_error: Exception,
) -> None:
    """Restore the exact failure gate and durably disable every boot path."""
    problems: list[str] = []
    controlled_units = tuple(
        dict.fromkeys(
            (
                *BOOT_UNITS,
                *WATCHDOG_SERVICES,
                MIGRATION_UNIT,
            )
        )
    )
    for unit in controlled_units:
        try:
            stop_unit(unit)
        except Exception as exc:
            problems.append(f"stop {unit}: {exc}")
    for unit in BOOT_UNITS:
        try:
            if unit_exists(unit):
                run(["systemctl", "disable", unit])
            if unit_enabled(unit):
                problems.append(f"disable {unit}: unit remains enabled")
        except Exception as exc:
            problems.append(f"disable {unit}: {exc}")
    try:
        fsync_boot_enablement()
    except Exception as exc:
        problems.append(f"boot enablement fsync: {exc}")

    try:
        if os.path.lexists(ACTIVATION_FAILURE_MARKER):
            existing = read_root_evidence_bytes(ACTIVATION_FAILURE_MARKER)
            if hashlib.sha256(existing).hexdigest() != marker_sha256:
                problems.append("restored activation failure marker has unexpected bytes")
        else:
            atomic_bytes(ACTIVATION_FAILURE_MARKER, original_marker, mode=0o600)
            restored = read_root_evidence_bytes(ACTIVATION_FAILURE_MARKER)
            if hashlib.sha256(restored).hexdigest() != marker_sha256:
                problems.append("activation failure marker restoration digest mismatch")
    except Exception as exc:
        problems.append(f"activation failure marker restoration: {exc}")

    try:
        atomic_json(
            transaction / "recovery-failed.json",
            {
                "error": str(recovery_error),
                "errorType": type(recovery_error).__name__,
                "failedAtUtc": utc_now(),
                "markerSha256": marker_sha256,
                "schemaVersion": 1,
            },
            mode=0o600,
        )
    except Exception as exc:
        problems.append(f"failure receipt: {exc}")

    if os.path.lexists(RECOVERY_IN_PROGRESS_MARKER):
        try:
            progress = read_root_evidence_bytes(RECOVERY_IN_PROGRESS_MARKER)
            archive_root_evidence(
                RECOVERY_IN_PROGRESS_MARKER,
                transaction / "recovery-in-progress.failed.json",
                hashlib.sha256(progress).hexdigest(),
            )
        except Exception as exc:
            problems.append(f"recovery-in-progress archive: {exc}")

    for unit in controlled_units:
        try:
            if unit_active(unit):
                problems.append(f"inactive check {unit}: unit remains active")
        except Exception as exc:
            problems.append(f"inactive check {unit}: {exc}")
    if problems:
        for problem in problems:
            log(f"recovery containment problem: {problem}", "err")
        fail("recovery failed and fail-closed containment could not be fully verified")
    if os.path.lexists(RECOVERY_INGRESS_AUTHORIZATION):
        durable_unlink(RECOVERY_INGRESS_AUTHORIZATION)
    if os.path.lexists(RECOVERY_INGRESS_PENDING):
        durable_unlink(RECOVERY_INGRESS_PENDING)
    if os.path.lexists(RECOVERY_INGRESS_FINALIZING):
        require_root_controlled_file(RECOVERY_INGRESS_FINALIZING, secret=True)
        finalizing_raw = read_root_evidence_bytes(RECOVERY_INGRESS_FINALIZING)
        archive_root_evidence(
            RECOVERY_INGRESS_FINALIZING,
            transaction / "recovery-ingress-finalizing.failed.json",
            hashlib.sha256(finalizing_raw).hexdigest(),
        )


def finish_activation_recovery(
    *,
    assessment: dict[str, Any],
    approval_reference: str,
    database_receipt: dict[str, Any],
) -> dict[str, Any]:
    state = assessment["state"]
    marker = state["activationFailure"]
    marker_sha = marker["sha256"]
    marker_raw = read_root_evidence_bytes(ACTIVATION_FAILURE_MARKER)
    if hashlib.sha256(marker_raw).hexdigest() != marker_sha:
        fail("activation failure marker changed after assessment")
    context = state["recoveryContext"]
    target_version = context["finishTargetVersion"]
    target_manifest = state["manifests"][target_version]
    target = DEFAULT_RELEASE_BASE / "releases" / target_version
    desired_boot = context.get("resumeDesiredBootEnablement") or (
        {unit: True for unit in BOOT_UNITS}
        if context.get("previousVersion") is None
        else context["originalBootEnablement"]
    )

    assert_privilege_separation(DEFAULT_STATE_DIR)
    verified_again = observe_installed_release(target, DEFAULT_ALLOWED_SIGNERS)
    if not verified_again.get("verified") or verified_again != target_manifest:
        fail("target installed release changed after recovery assessment")
    full_target_manifest = load_installed_manifest(target, DEFAULT_ALLOWED_SIGNERS)
    if full_target_manifest is None:
        fail("target signed manifest disappeared after recovery assessment")
    validate_detail_against_signed_manifest(
        database_receipt, full_target_manifest, target
    )
    run(["nginx", "-t"])

    transaction = create_recovery_transaction(
        assessment["planSha256"], "finish-activation"
    )
    transaction_started = True
    try:
        atomic_json(
            RECOVERY_IN_PROGRESS_MARKER,
            {
                "action": "finish-activation",
                "approvalReference": approval_reference,
                "databaseReceiptPath": database_receipt["path"],
                "databaseReceiptSha256": database_receipt["sha256"],
                "desiredBootEnablement": desired_boot,
                "markerSha256": marker_sha,
                "planSha256": assessment["planSha256"],
                "schemaVersion": 1,
                "startedAtUtc": utc_now(),
                "targetVersion": target_version,
                "transactionDirectory": str(transaction),
            },
            mode=0o600,
        )
        require_root_controlled_file(RECOVERY_IN_PROGRESS_MARKER, secret=True)
        archive_root_evidence(
            ACTIVATION_FAILURE_MARKER,
            transaction / "activation-failed.original.json",
            marker_sha,
        )
        existing_boot_marker = state["bootEnablementInProgress"]
        if existing_boot_marker is not None:
            archive_root_evidence(
                BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
                transaction / "boot-enablement.original.json",
                existing_boot_marker["sha256"],
            )
        archive_interrupted_start_authorization(transaction)

        # This independent fixed query is intentionally the last database gate
        # before any application, ingress or watchdog start. Any identity,
        # timeline or exact Flyway-row mismatch is contained by the outer block.
        live_database_evidence = verify_live_recovery_database(
            database_receipt=database_receipt,
            target_manifest=full_target_manifest,
            require_internal_role_acl=deployment_profile() == "internal-test",
            allow_local_recovery_archive=deployment_profile() == "internal-test",
        )
        start_application_authorized(
            mode="recovery",
            marker=RECOVERY_IN_PROGRESS_MARKER,
            target=target,
            manifest=full_target_manifest,
            live_evidence=live_database_evidence,
        )
        validate_health(HEALTH_BASE_URL)
        run(["nginx", "-t"])
        # Keep ingress closed, but arm the watchdogs while the recovery marker
        # still blocks them. After the durable commit they guarantee automatic
        # convergence if this process is killed before the explicit Nginx start.
        for timer in WATCHDOG_TIMERS:
            start_unit(timer)
            if not unit_active(timer):
                fail(f"watchdog timer did not remain active during recovery: {timer}")

        database_changed = (
            context.get("previousFlywayMigrationSetSha256")
            != full_target_manifest["flywayMigrationSetSha256"]
        )
        recovery_active_value = {
            "activatedAtUtc": utc_now(),
            "commitSha": full_target_manifest["commitSha"],
            "databaseChanged": database_changed,
            "flywayHeadVersion": full_target_manifest["flywayHeadVersion"],
            "flywayMigrationSetSha256": full_target_manifest[
                "flywayMigrationSetSha256"
            ],
            "manifestSha256": installed_manifest_sha256(target),
            "releaseSequence": full_target_manifest["releaseSequence"],
            "version": full_target_manifest["version"],
        }
        recovery_onboarding: dict[str, Any] | None = None
        recovery_onboarding_archive: Path | None = None
        recovery_first_backup: dict[str, Any] | None = None
        if deployment_profile() == "internal-test":
            contract, contract_sha = internal_test_runtime_contract()
            prior_active_path = DEFAULT_ROOT_STATE_DIR / "active.json"
            if os.path.lexists(prior_active_path):
                require_root_controlled_file(prior_active_path, secret=True)
                prior_active = strict_json_object(
                    read_root_evidence_bytes(prior_active_path),
                    "pre-recovery internal-test active state",
                )
                validate_active_release_state(prior_active)
                recovery_first_backup = prior_active.get("firstBackup")
                if not isinstance(recovery_first_backup, dict):
                    fail("pre-recovery internal-test state lacks first-backup authority")
                recovery_onboarding_archive = Path(prior_active["onboardingArchivePath"])
                recovery_active_value.update(
                    {
                        "firstBackup": recovery_first_backup,
                        "onboardingArchivePath": str(recovery_onboarding_archive),
                        "onboardingReceiptSha256": prior_active[
                            "onboardingReceiptSha256"
                        ],
                        "runtimeContractId": contract["contractId"],
                        "runtimeContractSha256": contract_sha,
                    }
                )
            else:
                recovery_onboarding = require_initial_database_onboarding_acceptance(
                    target_info=full_target_manifest,
                    target_manifest_sha256=installed_manifest_sha256(target),
                    live_evidence=live_database_evidence,
                    legacy_retirement=False,
                    approve_database_change=False,
                )
                recovery_onboarding_archive = INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
                    recovery_onboarding["fields"]["transactionId"] + ".json"
                )
                recovery_first_backup = require_initial_internal_test_first_backup(
                    target_info=full_target_manifest,
                    target_manifest_sha256=installed_manifest_sha256(target),
                    onboarding_receipt=recovery_onboarding,
                    live_evidence=live_database_evidence,
                )
                recovery_active_value.update(
                    {
                        "firstBackup": recovery_first_backup,
                        "onboardingArchivePath": str(recovery_onboarding_archive),
                        "onboardingReceiptSha256": recovery_onboarding["sha256"],
                        "runtimeContractId": contract["contractId"],
                        "runtimeContractSha256": contract_sha,
                    }
                )
                adoption = prepare_internal_test_onboarding_adoption(
                    recovery_onboarding,
                    runtime_contract_id=contract["contractId"],
                    runtime_contract_sha256=contract_sha,
                    first_backup=recovery_first_backup,
                    authenticated_expected_target=full_target_manifest,
                    live_database_identity=runtime_database_identity(
                        live_database_evidence
                    ),
                )
                validate_internal_test_onboarding_adoption(
                    adoption,
                    authenticated_expected_target=full_target_manifest,
                    live_database_identity=runtime_database_identity(
                        live_database_evidence
                    ),
                )
                adopted = archive_internal_test_onboarding(
                    recovery_onboarding,
                    authenticated_expected_target=full_target_manifest,
                    live_database_identity=runtime_database_identity(
                        live_database_evidence
                    ),
                )
                if adopted != recovery_onboarding_archive:
                    fail("recovery adopted the onboarding receipt at another path")
        atomic_json(
            DEFAULT_ROOT_STATE_DIR / "active.json",
            recovery_active_value,
            mode=0o600,
        )
        write_runtime_authority(
            target=target,
            manifest=full_target_manifest,
            live_evidence=live_database_evidence,
            first_backup_binding=recovery_first_backup,
        )
        if deployment_profile() == "internal-test":
            finalize_internal_test_onboarding_adoption_if_committed(
                target=target,
                manifest=full_target_manifest,
                live_evidence=live_database_evidence,
            )

        atomic_json(
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
            {
                "commitSha": target_manifest["commitSha"],
                "desiredBootEnablement": desired_boot,
                "releaseSequence": target_manifest["releaseSequence"],
                "schemaVersion": 1,
                "startedAtUtc": utc_now(),
                "version": target_version,
            },
            mode=0o600,
        )
        require_root_controlled_file(
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER, secret=True
        )
        restore_boot_enablement(desired_boot)

        commit_receipt = {
            "action": "finish-activation",
            "approvalReference": approval_reference,
            "committedAtUtc": utc_now(),
            "databaseReceiptPath": database_receipt["path"],
            "databaseReceiptSha256": database_receipt["sha256"],
            "databaseDetailPath": database_receipt["detailPath"],
            "databaseDetailSha256": database_receipt["detailSha256"],
            "desiredBootEnablement": desired_boot,
            "liveDatabaseEvidence": live_database_evidence,
            "markerSha256": marker_sha,
            "manifestSha256": target_manifest["manifestSha256"],
            "planSha256": assessment["planSha256"],
            "schemaVersion": 1,
            "status": "runtime-committed-pending-ingress",
            "targetVersion": target_version,
            "transactionDirectory": str(transaction),
        }
        commit_path = transaction / "recovery-commit.json"
        atomic_json(commit_path, commit_receipt, mode=0o600)
        arm_recovery_ingress_pending(
            transaction=transaction,
            commit_receipt=commit_receipt,
            commit_path=commit_path,
        )
        progress_raw = read_root_evidence_bytes(RECOVERY_IN_PROGRESS_MARKER)
        archive_root_evidence(
            RECOVERY_IN_PROGRESS_MARKER,
            transaction / "recovery-in-progress.completed.json",
            hashlib.sha256(progress_raw).hexdigest(),
        )
        boot_raw = read_root_evidence_bytes(BOOT_ENABLEMENT_IN_PROGRESS_MARKER)
        archive_root_evidence(
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
            transaction / "boot-enablement.recovery.json",
            hashlib.sha256(boot_raw).hexdigest(),
        )

        # Convert the closed persistent gate into an immutable, systemd-owned
        # finalization authority before opening ingress. Nginx ExecStartPost is
        # then responsible for probes + terminal receipt even if this updater
        # process is SIGKILLed after systemctl start returns control to PID 1.
        commit_recovery_ingress_for_systemd_finalizer(
            transaction=transaction, commit_path=commit_path
        )
        start_unit("nginx.service")
        if not unit_active("nginx.service"):
            fail("nginx did not remain active after the recovery commit")
        receipt = read_systemd_finalized_recovery_receipt(
            transaction=transaction, commit_receipt=commit_receipt
        )
        transaction_started = False
        return receipt
    except Exception as recovery_error:
        if transaction_started:
            try:
                contain_recovery_failure(
                    original_marker=marker_raw,
                    marker_sha256=marker_sha,
                    transaction=transaction,
                    recovery_error=recovery_error,
                )
            except Exception as containment_error:
                raise UpdaterError(
                    "finish recovery failed and containment also failed; all entry paths "
                    "must be treated as NO-GO"
                ) from containment_error
        raise


def validated_internal_active_origin(state: dict[str, Any]) -> dict[str, Any] | None:
    """Return the immutable onboarding origin required by internal-test restore."""
    if deployment_profile() != "internal-test":
        return None
    contract, contract_sha = internal_test_runtime_contract()
    active_observation = state.get("active")
    if not isinstance(active_observation, dict) or active_observation.get("valid") is not True:
        fail("internal-test previous recovery lacks its validated active origin")
    active_fields = active_observation.get("fields")
    if not isinstance(active_fields, dict):
        fail("internal-test previous recovery active origin is malformed")
    validate_active_release_state(active_fields)
    if (
        active_fields.get("runtimeContractId") != contract["contractId"]
        or active_fields.get("runtimeContractSha256") != contract_sha
    ):
        fail("internal-test previous recovery names another runtime contract")
    archive = Path(active_fields["onboardingArchivePath"])
    require_root_controlled_file(archive, secret=True)
    if release_guard.sha256_file(archive) != active_fields["onboardingReceiptSha256"]:
        fail("internal-test previous recovery onboarding origin changed")
    result = {
        "onboardingArchivePath": str(archive),
        "onboardingReceiptSha256": active_fields["onboardingReceiptSha256"],
        "runtimeContractId": contract["contractId"],
        "runtimeContractSha256": contract_sha,
    }
    first_backup = active_fields.get("firstBackup")
    if first_backup is not None:
        if not isinstance(first_backup, dict):
            fail("internal-test previous recovery first-backup origin is malformed")
        validate_internal_test_first_backup_binding(
            first_backup,
            require_archive=True,
        )
        result["firstBackup"] = first_backup
    return result


def restore_previous_recovery(
    *,
    action: str,
    assessment: dict[str, Any],
    approval_reference: str,
    database_receipt: dict[str, Any],
) -> dict[str, Any]:
    """Restore a signed previous runtime only after exact database recovery evidence."""
    if action not in {"restore-previous", "abandon-candidate"}:
        fail("previous release recovery action is unsupported")
    state = assessment["state"]
    context = state["recoveryContext"]
    marker = state["activationFailure"]
    marker_sha = marker["sha256"]
    marker_raw = read_root_evidence_bytes(ACTIVATION_FAILURE_MARKER)
    if hashlib.sha256(marker_raw).hexdigest() != marker_sha:
        fail("activation failure marker changed after assessment")
    target_version = context.get("previousVersion")
    if target_version is None:
        fail("previous release recovery has no signed previous version")
    target_manifest = state["manifests"][target_version]
    target = DEFAULT_RELEASE_BASE / "releases" / target_version
    desired_boot = context["originalBootEnablement"]

    assert_privilege_separation(DEFAULT_STATE_DIR)
    verified_again = observe_installed_release(target, DEFAULT_ALLOWED_SIGNERS)
    if not verified_again.get("verified") or verified_again != target_manifest:
        fail("previous installed release changed after recovery assessment")
    full_target_manifest = load_installed_manifest(target, DEFAULT_ALLOWED_SIGNERS)
    if full_target_manifest is None:
        fail("previous signed manifest disappeared after recovery assessment")
    validate_detail_against_signed_manifest(
        database_receipt, full_target_manifest, target
    )
    run(["nginx", "-t"])

    internal_origin = validated_internal_active_origin(state)

    transaction = create_recovery_transaction(assessment["planSha256"], action)
    transaction_started = True
    try:
        atomic_json(
            RECOVERY_IN_PROGRESS_MARKER,
            {
                "action": action,
                "approvalReference": approval_reference,
                "databaseReceiptPath": database_receipt["path"],
                "databaseReceiptSha256": database_receipt["sha256"],
                "desiredBootEnablement": desired_boot,
                "markerSha256": marker_sha,
                "planSha256": assessment["planSha256"],
                "schemaVersion": 1,
                "startedAtUtc": utc_now(),
                "targetVersion": target_version,
                "transactionDirectory": str(transaction),
            },
            mode=0o600,
        )
        require_root_controlled_file(RECOVERY_IN_PROGRESS_MARKER, secret=True)

        # Re-close and durably disable every boot path under the persistent
        # activation gate. This catches out-of-band systemctl activity after assess.
        _stop_and_disable_for_interrupted_containment()
        archive_root_evidence(
            ACTIVATION_FAILURE_MARKER,
            transaction / "activation-failed.original.json",
            marker_sha,
        )
        existing_boot_marker = state["bootEnablementInProgress"]
        if existing_boot_marker is not None:
            archive_root_evidence(
                BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
                transaction / "boot-enablement.original.json",
                existing_boot_marker["sha256"],
            )
        archive_interrupted_start_authorization(transaction)

        # The current symlink switch is idempotent. The recovery marker remains
        # the durable start/ingress gate until the signed previous DB is proven,
        # the process is healthy, and all authority records are committed.
        atomic_current(DEFAULT_RELEASE_BASE, target)
        live_database_evidence = verify_live_recovery_database(
            database_receipt=database_receipt,
            target_manifest=full_target_manifest,
            require_internal_role_acl=deployment_profile() == "internal-test",
            allow_local_recovery_archive=deployment_profile() == "internal-test",
        )
        start_application_authorized(
            mode="recovery",
            marker=RECOVERY_IN_PROGRESS_MARKER,
            target=target,
            manifest=full_target_manifest,
            live_evidence=live_database_evidence,
        )
        validate_health(HEALTH_BASE_URL)
        run(["nginx", "-t"])
        for timer in WATCHDOG_TIMERS:
            start_unit(timer)
            if not unit_active(timer):
                fail(
                    f"watchdog timer did not remain active during previous recovery: {timer}"
                )

        restored_active = {
                "activatedAtUtc": utc_now(),
                "commitSha": full_target_manifest["commitSha"],
                "databaseChanged": context.get(
                    "failedFlywayMigrationSetSha256"
                )
                not in {None, full_target_manifest["flywayMigrationSetSha256"]},
                "flywayHeadVersion": full_target_manifest["flywayHeadVersion"],
                "flywayMigrationSetSha256": full_target_manifest[
                    "flywayMigrationSetSha256"
                ],
                "manifestSha256": installed_manifest_sha256(target),
                "releaseSequence": full_target_manifest["releaseSequence"],
                "version": full_target_manifest["version"],
            }
        if internal_origin is not None:
            restored_active.update(internal_origin)
        atomic_json(
            DEFAULT_ROOT_STATE_DIR / "active.json",
            restored_active,
            mode=0o600,
        )
        validate_active_release_state(restored_active)
        write_runtime_authority(
            target=target,
            manifest=full_target_manifest,
            live_evidence=live_database_evidence,
        )
        atomic_json(
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
            {
                "commitSha": target_manifest["commitSha"],
                "desiredBootEnablement": desired_boot,
                "releaseSequence": target_manifest["releaseSequence"],
                "schemaVersion": 1,
                "startedAtUtc": utc_now(),
                "version": target_version,
            },
            mode=0o600,
        )
        require_root_controlled_file(
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER, secret=True
        )
        restore_boot_enablement(desired_boot)

        commit_receipt = {
            "action": action,
            "approvalReference": approval_reference,
            "committedAtUtc": utc_now(),
            "databaseReceiptPath": database_receipt["path"],
            "databaseReceiptSha256": database_receipt["sha256"],
            "databaseDetailPath": database_receipt["detailPath"],
            "databaseDetailSha256": database_receipt["detailSha256"],
            "desiredBootEnablement": desired_boot,
            "liveDatabaseEvidence": live_database_evidence,
            "markerSha256": marker_sha,
            "manifestSha256": target_manifest["manifestSha256"],
            "planSha256": assessment["planSha256"],
            "schemaVersion": 1,
            "status": "previous-runtime-committed-pending-ingress",
            "targetVersion": target_version,
            "transactionDirectory": str(transaction),
        }
        commit_path = transaction / "recovery-commit.json"
        atomic_json(commit_path, commit_receipt, mode=0o600)
        arm_recovery_ingress_pending(
            transaction=transaction,
            commit_receipt=commit_receipt,
            commit_path=commit_path,
        )
        progress_raw = read_root_evidence_bytes(RECOVERY_IN_PROGRESS_MARKER)
        archive_root_evidence(
            RECOVERY_IN_PROGRESS_MARKER,
            transaction / "recovery-in-progress.completed.json",
            hashlib.sha256(progress_raw).hexdigest(),
        )
        boot_raw = read_root_evidence_bytes(BOOT_ENABLEMENT_IN_PROGRESS_MARKER)
        archive_root_evidence(
            BOOT_ENABLEMENT_IN_PROGRESS_MARKER,
            transaction / "boot-enablement.recovery.json",
            hashlib.sha256(boot_raw).hexdigest(),
        )

        commit_recovery_ingress_for_systemd_finalizer(
            transaction=transaction, commit_path=commit_path
        )
        start_unit("nginx.service")
        if not unit_active("nginx.service"):
            fail("nginx did not remain active after previous recovery commit")
        receipt = read_systemd_finalized_recovery_receipt(
            transaction=transaction, commit_receipt=commit_receipt
        )
        transaction_started = False
        return receipt
    except Exception as recovery_error:
        if transaction_started:
            try:
                contain_recovery_failure(
                    original_marker=marker_raw,
                    marker_sha256=marker_sha,
                    transaction=transaction,
                    recovery_error=recovery_error,
                )
            except Exception as containment_error:
                raise UpdaterError(
                    "previous recovery failed and containment also failed; all entry "
                    "paths must be treated as NO-GO"
                ) from containment_error
        raise


def remain_contained_recovery(
    *, assessment: dict[str, Any], approval_reference: str
) -> dict[str, Any]:
    """Reassert fail-closed state and persist a plan-bound operator decision."""
    marker = assessment["state"]["activationFailure"]
    marker_raw = read_root_evidence_bytes(ACTIVATION_FAILURE_MARKER)
    if hashlib.sha256(marker_raw).hexdigest() != marker["sha256"]:
        fail("activation failure marker changed after assessment")
    _stop_and_disable_for_interrupted_containment()
    transaction = create_recovery_transaction(
        assessment["planSha256"], "remain-contained"
    )
    receipt = {
        "action": "remain-contained",
        "approvalReference": approval_reference,
        "completedAtUtc": utc_now(),
        "markerPath": str(ACTIVATION_FAILURE_MARKER),
        "markerSha256": marker["sha256"],
        "planSha256": assessment["planSha256"],
        "schemaVersion": 1,
        "status": "contained-no-start-no-marker-clear",
        "subjectVersion": assessment["state"]["recoveryContext"]["failedVersion"],
        "transactionDirectory": str(transaction),
    }
    path = transaction / "remain-contained-receipt.json"
    atomic_json(path, receipt, mode=0o600)
    require_root_controlled_file(path, secret=True)
    if not os.path.lexists(ACTIVATION_FAILURE_MARKER):
        fail("remain-contained action must never remove the persistent failure gate")
    return receipt


def recover_interrupted_assess() -> None:
    if os.geteuid() != 0:
        fail("interrupted recovery assessment must run explicitly as root")
    # This command deliberately ignores all environment and global CLI path overrides.
    require_real_directory(DEFAULT_ROOT_STATE_DIR, owner_uid=0)
    require_real_directory(RECOVERY_EVIDENCE_DIR, owner_uid=0)
    with StateLock(DEFAULT_LOCK_FILE).allow_persistent_markers(
        recovery_state_lock_compatible_markers()
    ):
        assessment = build_interrupted_containment_assessment()
    print(json.dumps(assessment, ensure_ascii=True, indent=2, sort_keys=True))


def recover_interrupted_apply(args: argparse.Namespace) -> None:
    if os.geteuid() != 0:
        fail("interrupted recovery apply must run explicitly as root")
    require_real_directory(DEFAULT_ROOT_STATE_DIR, owner_uid=0)
    require_real_directory(RECOVERY_EVIDENCE_DIR, owner_uid=0)
    # Emergency interrupted containment intentionally does not take the
    # database-maintenance lock: it never observes or mutates PostgreSQL/current
    # and must be able to close entry paths while a backup is still running.
    with StateLock(DEFAULT_LOCK_FILE).allow_persistent_markers(
        recovery_state_lock_compatible_markers()
    ):
        assessment = build_interrupted_containment_assessment()
        if args.action != "contain":
            fail("interrupted recovery action is unsupported")
        plan_sha = release_guard.require_string(
            args.expected_plan_sha256,
            "expected interrupted containment plan digest",
            release_guard.SHA256_RE,
        )
        if plan_sha != assessment["planSha256"]:
            fail(
                "interrupted containment assessment changed; run recover "
                "interrupted-assess again"
            )
        expected_confirmation = assessment["actions"]["contain"][
            "requiredConfirmation"
        ]
        if args.confirm != expected_confirmation:
            fail("interrupted containment confirmation phrase is not exact")
        if not assessment["actions"]["contain"]["allowed"]:
            fail(
                "interrupted containment assessment is NO-GO: "
                + "; ".join(assessment["actions"]["contain"]["reasons"])
            )
        receipt = contain_interrupted_transaction(assessment)
    print(json.dumps(receipt, ensure_ascii=True, indent=2, sort_keys=True))


def recover_assess() -> None:
    if os.geteuid() != 0:
        fail("activation recovery assessment must run explicitly as root")
    # Recovery deliberately ignores every environment/CLI path override.
    require_real_directory(DEFAULT_ROOT_STATE_DIR, owner_uid=0)
    with StateLock(DEFAULT_LOCK_FILE).allow_persistent_markers(
        recovery_state_lock_compatible_markers()
    ):
        assessment = build_recovery_assessment()
    print(json.dumps(assessment, ensure_ascii=True, indent=2, sort_keys=True))


def recover_apply(args: argparse.Namespace) -> None:
    if os.geteuid() != 0:
        fail("activation recovery apply must run explicitly as root")
    require_real_directory(DEFAULT_ROOT_STATE_DIR, owner_uid=0)
    require_real_directory(RECOVERY_EVIDENCE_DIR, owner_uid=0)
    require_real_directory(RECOVERY_DATABASE_RECEIPTS_DIR, owner_uid=0)
    # Fixed lock order: release transaction first, then the database-wide
    # maintenance inode shared with backup jobs. The latter remains held
    # through evidence revalidation, every mutation, and terminal containment.
    with StateLock(DEFAULT_LOCK_FILE).allow_persistent_markers(
        recovery_state_lock_compatible_markers()
    ), DatabaseMaintenanceLock():
        assessment = build_recovery_assessment()
        plan_sha = release_guard.require_string(
            args.expected_plan_sha256,
            "expected recovery plan digest",
            release_guard.SHA256_RE,
        )
        marker_sha = release_guard.require_string(
            args.expected_marker_sha256,
            "expected activation marker digest",
            release_guard.SHA256_RE,
        )
        if plan_sha != assessment["planSha256"]:
            fail("recovery assessment changed; run recover assess again")
        marker = assessment["state"]["activationFailure"]
        if marker_sha != marker["sha256"]:
            fail("activation failure marker digest changed")
        target_version = release_guard.require_string(
            args.target_version, "recovery target version"
        )
        release_guard.version_sequence(target_version)
        action_assessment = assessment["actions"][args.action]
        if target_version != action_assessment["targetVersion"]:
            fail("recovery target version differs from the assessed action")
        approval = release_guard.require_string(
            args.approval_reference, "recovery approval reference"
        )
        if not RECOVERY_APPROVAL_RE.fullmatch(approval):
            fail("recovery approval reference is not canonical")
        expected_confirmation = recovery_confirmation(
            args.action, target_version, plan_sha
        )
        if args.confirm != expected_confirmation:
            fail("recovery confirmation phrase is not exact")
        eligibility = assessment["actions"][args.action]
        if args.action != "retry-activation" and not eligibility["allowed"]:
            fail(
                f"{args.action} assessment is NO-GO: "
                + "; ".join(eligibility["reasons"])
            )
        if args.action == "remain-contained":
            if args.database_receipt or args.expected_database_receipt_sha256:
                fail("remain-contained must not accept database recovery receipt inputs")
            receipt = remain_contained_recovery(
                assessment=assessment, approval_reference=approval
            )
            print(json.dumps(receipt, ensure_ascii=True, indent=2, sort_keys=True))
            return

        target_manifest = assessment["state"]["manifests"].get(target_version)
        if not target_manifest or not target_manifest.get("verified"):
            fail("recovery target manifest/payload is not verified")
        if not args.database_receipt or not args.expected_database_receipt_sha256:
            fail("this recovery action requires an exact database receipt path and digest")
        database_receipt = load_database_recovery_receipt(
            path_text=args.database_receipt,
            expected_sha256=args.expected_database_receipt_sha256,
            approval_reference=approval,
            target_manifest=target_manifest,
        )
        if args.action == "retry-activation":
            fail(
                "retry-activation is intentionally unavailable: restore/PITR state cannot "
                "be inferred and formal activation cannot be safely re-entered under this lock"
            )
        if args.action == "finish-activation":
            receipt = finish_activation_recovery(
                assessment=assessment,
                approval_reference=approval,
                database_receipt=database_receipt,
            )
        else:
            receipt = restore_previous_recovery(
                action=args.action,
                assessment=assessment,
                approval_reference=approval,
                database_receipt=database_receipt,
            )
    print(json.dumps(receipt, ensure_ascii=True, indent=2, sort_keys=True))


def activate_release(args: argparse.Namespace) -> None:
    if os.geteuid() != 0:
        fail("release activation must be invoked explicitly as root")
    if args.confirm_version != args.version:
        fail("--confirm-version must exactly equal the requested version")
    issue_reauthorization_only = bool(
        getattr(args, "issue_activation_reauthorization_only", False)
    )
    reauthorization_approval_reference = getattr(
        args, "reauthorization_approval_reference", None
    )
    expected_reauthorization_sha256 = getattr(
        args, "expected_activation_reauthorization_sha256", None
    )
    if issue_reauthorization_only:
        if not args.first_release or args.retire_legacy_current:
            fail(
                "activation reauthorization issuance requires a non-legacy first release"
            )
        if (
            not isinstance(reauthorization_approval_reference, str)
            or not INTERNAL_TEST_APPROVAL_RE.fullmatch(
                reauthorization_approval_reference
            )
        ):
            fail("--reauthorization-approval-reference is missing or malformed")
        if expected_reauthorization_sha256 is not None:
            fail(
                "reauthorization issuance must not accept "
                "--expected-activation-reauthorization-sha256"
            )
    elif reauthorization_approval_reference is not None:
        fail(
            "--reauthorization-approval-reference is valid only with "
            "--issue-activation-reauthorization-only"
        )
    if expected_reauthorization_sha256 is not None:
        require_recovery_sha256(
            expected_reauthorization_sha256,
            "expected activation reauthorization digest",
        )
    if args.retire_legacy_current:
        if args.confirm_legacy_retirement != LEGACY_RETIREMENT_CONFIRMATION:
            fail(
                "--retire-legacy-current requires the exact no-rollback "
                "--confirm-legacy-retirement value"
            )
    elif args.confirm_legacy_retirement is not None:
        fail("--confirm-legacy-retirement is valid only with --retire-legacy-current")
    # Privileged activation deliberately ignores all environment/CLI path overrides.
    # The root wrapper also clears them, but this keeps direct invocation fail-closed.
    state_dir = DEFAULT_STATE_DIR
    require_real_directory(state_dir)
    allowed_signers = DEFAULT_ALLOWED_SIGNERS
    authorized_key_ids(allowed_signers)
    base = DEFAULT_RELEASE_BASE
    releases = base / "releases"
    require_real_directory(base, owner_uid=0)
    require_real_directory(releases, owner_uid=0)
    report_capacity(state_dir, "staging")
    report_capacity(releases, "installed releases")
    if base.stat().st_dev != releases.stat().st_dev:
        fail("release base and releases directory must be on the same filesystem")
    root_state = DEFAULT_ROOT_STATE_DIR
    require_real_directory(root_state, owner_uid=0)
    if root_state.lstat().st_mode & 0o022:
        fail("root release-state directory must not be group/world-writable")
    # Never create a release marker, install/switch current, or observe/migrate
    # the database while a fixed backup/maintenance job owns its operation lock.
    activation_compatible_markers: set[Path] = set()
    if issue_reauthorization_only or expected_reauthorization_sha256 is not None:
        activation_compatible_markers.add(INTERNAL_TEST_ACTIVATION_REAUTHORIZATION)
    if os.path.lexists(INTERNAL_TEST_ONBOARDING_ADOPTION):
        activation_compatible_markers.add(INTERNAL_TEST_ONBOARDING_ADOPTION)
    with StateLock(DEFAULT_LOCK_FILE).allow_persistent_markers(
        activation_compatible_markers
    ), DatabaseMaintenanceLock():
        if os.path.lexists(ACTIVATION_FAILURE_MARKER):
            require_root_controlled_file(ACTIVATION_FAILURE_MARKER, secret=True)
            fail(
                "a persistent activation failure gate is present; complete the controlled "
                "database/release recovery procedure before another activation"
            )
        if os.path.lexists(ACTIVATION_IN_PROGRESS_MARKER):
            require_root_controlled_file(ACTIVATION_IN_PROGRESS_MARKER, secret=True)
            fail(
                "an interrupted activation transaction is present; boot units must remain "
                "disabled until controlled database/release recovery is complete"
            )
        if os.path.lexists(BOOT_ENABLEMENT_IN_PROGRESS_MARKER):
            require_root_controlled_file(
                BOOT_ENABLEMENT_IN_PROGRESS_MARKER, secret=True
            )
            fail(
                "an interrupted boot-enablement transaction is present; all boot units "
                "must remain disabled until controlled recovery proves one exact state"
            )
        if os.path.lexists(RECOVERY_IN_PROGRESS_MARKER):
            require_root_controlled_file(RECOVERY_IN_PROGRESS_MARKER, secret=True)
            fail(
                "an interrupted evidence-driven recovery transaction is present; "
                "ordinary activation is forbidden"
            )
        reconcile_internal_test_first_backup_adoption_before_activation(
            base=base,
            releases=releases,
            allowed_signers=allowed_signers,
        )
        release_guard.version_sequence(args.version)
        untrusted_candidate = state_dir / "candidates" / args.version
        candidate, manifest_info = snapshot_candidate(
            untrusted_candidate, releases, allowed_signers
        )
        target_manifest_sha256 = release_guard.sha256_file(candidate / "manifest.json")
        cleanup_snapshot = lambda: shutil.rmtree(candidate, ignore_errors=True)
        atexit.register(cleanup_snapshot)
        if manifest_info["version"] != args.version:
            fail("requested version differs from staged evidence")
        if args.confirm_flyway != manifest_info["flywayHeadVersion"]:
            fail("--confirm-flyway must exactly equal the signed Flyway head version")
        if args.confirm_flyway_digest != manifest_info["flywayMigrationSetSha256"]:
            fail(
                "--confirm-flyway-digest must exactly equal the signed Flyway migration-set digest"
            )
        if not args.confirm_session_clearance:
            fail("--confirm-session-clearance is required for this non-rolling release")
        active_state_path = root_state / "active.json"
        active_sequence = 0
        active_state: dict[str, Any] | None = None
        if os.path.lexists(active_state_path):
            require_root_controlled_file(active_state_path, secret=True)
            active_state = release_guard.load_json(active_state_path, 64 * 1024)
            validate_active_release_state(active_state)
            value = active_state.get("releaseSequence")
            if not isinstance(value, int) or isinstance(value, bool) or value < 1:
                fail("root-owned active release state is malformed")
            active_version = release_guard.require_string(
                active_state.get("version"), "active.version"
            )
            if release_guard.version_sequence(active_version) != value:
                fail("root-owned active version/sequence state is inconsistent")
            release_guard.require_string(
                active_state.get("commitSha"), "active.commitSha", release_guard.COMMIT_RE
            )
            active_flyway_head = release_guard.require_string(
                active_state.get("flywayHeadVersion"), "active.flywayHeadVersion"
            )
            if not active_flyway_head.isdigit():
                fail("root-owned active Flyway head is malformed")
            release_guard.require_string(
                active_state.get("manifestSha256"),
                "active.manifestSha256",
                release_guard.SHA256_RE,
            )
            release_guard.require_string(
                active_state.get("flywayMigrationSetSha256"),
                "active.flywayMigrationSetSha256",
                release_guard.SHA256_RE,
            )
            if not isinstance(active_state.get("databaseChanged"), bool):
                fail("root-owned active databaseChanged state is malformed")
            active_sequence = value
        if (
            active_state is not None
            and manifest_info["releaseSequence"] <= active_sequence
        ):
            fail("activation would replay or downgrade the root-owned active release")

        assert_privilege_separation(state_dir)
        old_target = current_release(base, releases)
        old_info = load_installed_manifest(old_target, allowed_signers) if old_target else None
        legacy_retirement = old_target is not None and old_info is None
        if args.retire_legacy_current:
            if not legacy_retirement:
                fail("--retire-legacy-current requires one unsigned legacy current link")
            if not args.first_release:
                fail("legacy retirement must use the explicit --first-release contract")
            if active_state is not None:
                fail("legacy retirement is forbidden when root-owned active state exists")
            if os.path.lexists(LEGACY_RETIREMENT_MARKER):
                require_root_controlled_file(LEGACY_RETIREMENT_MARKER, secret=True)
                fail("legacy current retirement has already been recorded")
        else:
            if old_target is None and not args.first_release:
                fail("the first activation requires the explicit --first-release flag")
            if old_target is not None and args.first_release:
                fail("--first-release is invalid because current already exists")
        if old_target is None and args.retire_legacy_current:
            fail("--retire-legacy-current is invalid because current is absent")
        if old_target is not None and old_info is None and not args.retire_legacy_current:
            fail(
                "current lacks signed release evidence; use the one-time "
                "--retire-legacy-current no-rollback contract only after backup and "
                "migration review"
            )
        legacy_current_evidence = (
            capture_legacy_current_evidence(
                base=base, legacy_target=old_target
            )
            if legacy_retirement
            else None
        )
        if args.first_release and not args.enable_on_boot:
            fail("the first activation requires explicit --enable-on-boot confirmation")
        if not args.first_release and args.enable_on_boot:
            fail("--enable-on-boot is only valid for the first activation")
        if (
            old_info is not None
            and manifest_info["releaseSequence"] <= old_info["releaseSequence"]
        ):
            fail("activation would replay or downgrade the signed current release")

        if active_state is not None:
            if old_target is None:
                fail("root-owned active state exists but current release is missing")
            if old_info is None:
                fail("root-owned active state requires signed evidence on current release")
            if old_info is not None and (
                active_state["version"] != old_info["version"]
                or active_state["releaseSequence"] != old_info["releaseSequence"]
                or active_state["flywayHeadVersion"] != old_info["flywayHeadVersion"]
                or active_state["flywayMigrationSetSha256"]
                != old_info["flywayMigrationSetSha256"]
            ):
                fail("root-owned active state disagrees with the signed current release")

        # The target manifest was authenticated while snapshotting the candidate; the
        # signed current manifest and installed payload were verified when old_info was
        # loaded. Ordinary activation may keep the same inventory or append to it, but
        # may never reinterpret already signed/applied history. This gate deliberately
        # runs before root installs the candidate or starts the maintenance transaction.
        require_append_only_flyway_transition(old_info, manifest_info)

        target_database = (
            manifest_info["flywayHeadVersion"],
            manifest_info["flywayMigrationSetSha256"],
        )
        database_migration_required = False

        # A first/legacy takeover is not a request to migrate whatever database happens
        # to be listening. First prove the live fixed endpoint is already the complete
        # signed target, then hit the explicit source-level NO-GO until a trustworthy
        # authority/migration/cutover acceptance producer exists. Both checks precede
        # release installation and every maintenance side effect.
        onboarding_receipt: dict[str, Any] | None = None
        first_backup_binding: dict[str, Any] | None = None
        if old_info is None:
            live_onboarding_target = verify_live_signed_database(
                target_manifest=manifest_info,
                allow_local_recovery_archive=True,
            )
            onboarding_receipt = require_initial_database_onboarding_acceptance(
                target_info=manifest_info,
                target_manifest_sha256=target_manifest_sha256,
                live_evidence=live_onboarding_target,
                legacy_retirement=legacy_retirement,
                approve_database_change=args.approve_database_change,
                expected_activation_reauthorization_sha256=(
                    expected_reauthorization_sha256
                ),
                allow_expired_for_reauthorization_issue=(
                    issue_reauthorization_only
                ),
            )
            if issue_reauthorization_only:
                reauthorization = issue_internal_test_activation_reauthorization(
                    onboarding_receipt=onboarding_receipt,
                    authenticated_expected_target=manifest_info,
                    live_database_identity=runtime_database_identity(
                        live_onboarding_target
                    ),
                    runtime_contract_sha256=onboarding_receipt[
                        "runtimeContractSha256"
                    ],
                    approval_reference=reauthorization_approval_reference,
                )
                print(
                    json.dumps(
                        {
                            "expiresAtUtc": reauthorization["fields"]["expiresAtUtc"],
                            "path": reauthorization["path"],
                            "sha256": reauthorization["sha256"],
                            "status": "ACTIVATION_REAUTHORIZATION_ISSUED_ENTRY_CLOSED",
                            "version": reauthorization["fields"]["version"],
                        },
                        ensure_ascii=True,
                        indent=2,
                        sort_keys=True,
                    )
                )
                cleanup_snapshot()
                atexit.unregister(cleanup_snapshot)
                return
            first_backup_binding = require_initial_internal_test_first_backup(
                target_info=manifest_info,
                target_manifest_sha256=target_manifest_sha256,
                onboarding_receipt=onboarding_receipt,
                live_evidence=live_onboarding_target,
            )
            contract, contract_sha = internal_test_runtime_contract()
            prepare_internal_test_onboarding_adoption(
                onboarding_receipt,
                runtime_contract_id=contract["contractId"],
                runtime_contract_sha256=contract_sha,
                first_backup=first_backup_binding,
                authenticated_expected_target=manifest_info,
                live_database_identity=runtime_database_identity(
                    live_onboarding_target
                ),
            )
            # This is deliberately exact-target onboarding, not an online migration.
            # Once a reviewed producer replaces the hard gate above, first/legacy
            # activation must retain these values and skip the migration unit.
            database_changed = False
            database_migration_required = False
        else:
            if issue_reauthorization_only or expected_reauthorization_sha256 is not None:
                fail("activation reauthorization is valid only for first activation")
            # Before touching the current link or schema, prove that an established
            # installation is still attached to the exact signed release and the
            # PostgreSQL system/timeline/history recorded at its last commit. This
            # prevents a restored or accidentally replaced database from being
            # migrated merely because pg_isready succeeds.
            if old_target is None:
                fail("signed current release disappeared before database authority check")
            live_before_migration = verify_live_signed_database(
                target_manifest=old_info,
                allow_local_recovery_archive=True,
            )
            if deployment_profile() == "internal-test":
                if active_state is None or not isinstance(
                    active_state.get("firstBackup"), dict
                ):
                    fail(
                        "subsequent internal-test activation lacks its archived "
                        "first-backup authority"
                    )
                first_backup_binding = active_state["firstBackup"]
                validate_internal_test_first_backup_binding(
                    first_backup_binding,
                    live_database_identity=runtime_database_identity(
                        live_before_migration
                    ),
                    require_archive=True,
                )
            validate_existing_runtime_authority(
                target=old_target,
                manifest=old_info,
                live_evidence=live_before_migration,
                first_backup_binding=first_backup_binding,
            )
            if active_state is not None:
                approved_database_baseline = (
                    active_state["flywayHeadVersion"],
                    active_state["flywayMigrationSetSha256"],
                )
            else:
                approved_database_baseline = (
                    old_info["flywayHeadVersion"],
                    old_info["flywayMigrationSetSha256"],
                )
            database_changed = approved_database_baseline != target_database
            if database_changed:
                require_online_database_transition_acceptance(
                    current_info=old_info,
                    target_info=manifest_info,
                    approve_database_change=args.approve_database_change,
                )
                database_migration_required = True
            elif args.approve_database_change:
                fail(
                    "--approve-database-change is invalid because the signed Flyway "
                    "head and migration inventory are unchanged"
                )

        target = install_root_owned_release(candidate, releases, manifest_info)
        if target.stat().st_dev != base.stat().st_dev:
            fail("installed release is not on the atomic current filesystem")

        for unit in BOOT_UNITS:
            if not unit_exists(unit):
                fail(f"required boot unit is not installed: {unit}")
        if not unit_exists(MIGRATION_UNIT):
            fail(f"required migration unit is not installed: {MIGRATION_UNIT}")
        if unit_enabled(MIGRATION_UNIT):
            fail("migration unit must be explicit-start only and never boot-enabled")
        if legacy_retirement:
            require_legacy_retirement_quiescence()
        active_timers = [unit for unit in WATCHDOG_TIMERS if unit_active(unit)]
        boot_enabled_before = {unit: unit_enabled(unit) for unit in BOOT_UNITS}
        if old_target is not None and not legacy_retirement and not all(
            boot_enabled_before.values()
        ):
            fail(
                "existing installation has disabled backend/nginx/watchdog entry "
                "boot units"
            )
        nginx_was_active = unit_active("nginx.service")
        maintenance_started = False
        switched = False
        schema_change_attempted = False
        transaction_preparing = False
        transaction_started = False
        legacy_retirement_committed = False
        activation_state_commit_started = False
        try:
            transaction_preparing = True
            begin_activation_transaction(
                old_info=old_info,
                new_info=manifest_info,
                boot_enabled_before=boot_enabled_before,
            )
            transaction_started = True
            for timer in active_timers:
                stop_unit(timer)
            for service in WATCHDOG_SERVICES:
                if unit_active(service):
                    stop_unit(service)
            if nginx_was_active:
                stop_unit("nginx.service")
            maintenance_started = True
            if unit_active("uten-imp.service"):
                stop_unit("uten-imp.service")
            if legacy_retirement:
                record_and_remove_legacy_current(
                    base=base,
                    legacy_target=old_target,
                    new_info=manifest_info,
                    expected_evidence=legacy_current_evidence,
                )
                legacy_retirement_committed = True
            if database_migration_required:
                validate_migration_environment()
            atomic_current(base, target)
            switched = True
            if database_migration_required:
                schema_change_attempted = True
                migration_authorization_nonce = prepare_migration_authorization(
                    target=target,
                    manifest=manifest_info,
                )
                try:
                    run_migration_unit(migration_authorization_nonce)
                finally:
                    # If systemd never reached the root ExecStartPre consumer, leave
                    # an atomic, non-replayable cancellation archive rather than a
                    # live grant. A killed updater is rejected independently by the
                    # helper's PID/starttime/operation-lock proof.
                    discard_unconsumed_migration_authorization(
                        migration_authorization_nonce
                    )
            live_database_evidence = verify_live_signed_database(
                target_manifest=manifest_info,
                allow_local_recovery_archive=deployment_profile() == "internal-test",
            )
            start_application_authorized(
                mode="activation",
                marker=ACTIVATION_IN_PROGRESS_MARKER,
                target=target,
                manifest=manifest_info,
                live_evidence=live_database_evidence,
            )
            validate_health(HEALTH_BASE_URL)
            run(["nginx", "-t"])
            # Start both watchdog timers while the transaction marker still
            # blocks every recovery action. Once the durable commit removes the
            # marker they provide automatic convergence even if the activator is
            # killed before the explicit Nginx start below.
            for timer in WATCHDOG_TIMERS:
                start_unit(timer)
                if not unit_active(timer):
                    fail(f"watchdog timer did not remain active: {timer}")
            activation_state_commit_started = True
            internal_contract: dict[str, Any] | None = None
            internal_contract_sha: str | None = None
            onboarding_archive: Path | None = None
            onboarding_sha: str | None = None
            if deployment_profile() == "internal-test":
                internal_contract, internal_contract_sha = internal_test_runtime_contract()
                if onboarding_receipt is not None:
                    onboarding_archive = INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
                        onboarding_receipt["fields"]["transactionId"] + ".json"
                    )
                    onboarding_sha = onboarding_receipt["sha256"]
                    adoption = prepare_internal_test_onboarding_adoption(
                        onboarding_receipt,
                        runtime_contract_id=internal_contract["contractId"],
                        runtime_contract_sha256=internal_contract_sha,
                        first_backup=first_backup_binding,
                        authenticated_expected_target=manifest_info,
                        live_database_identity=runtime_database_identity(
                            live_database_evidence
                        ),
                    )
                    validate_internal_test_onboarding_adoption(
                        adoption,
                        authenticated_expected_target=manifest_info,
                        live_database_identity=runtime_database_identity(
                            live_database_evidence
                        ),
                    )
                    archived_origin = archive_internal_test_onboarding(
                        onboarding_receipt,
                        authenticated_expected_target=manifest_info,
                        live_database_identity=runtime_database_identity(
                            live_database_evidence
                        ),
                    )
                    if archived_origin != onboarding_archive:
                        fail("internal-test onboarding archive destination changed")
                else:
                    if active_state is None:
                        fail("internal-test activation lacks its onboarding origin")
                    onboarding_archive = Path(active_state["onboardingArchivePath"])
                    onboarding_sha = active_state["onboardingReceiptSha256"]
                    require_root_controlled_file(onboarding_archive, secret=True)
                    if release_guard.sha256_file(onboarding_archive) != onboarding_sha:
                        fail("internal-test onboarding origin archive changed")
            committed_active_state = {
                "activatedAtUtc": utc_now(),
                "commitSha": manifest_info["commitSha"],
                "databaseChanged": database_changed,
                "flywayHeadVersion": manifest_info["flywayHeadVersion"],
                "flywayMigrationSetSha256": manifest_info[
                    "flywayMigrationSetSha256"
                ],
                "manifestSha256": installed_manifest_sha256(target),
                "releaseSequence": manifest_info["releaseSequence"],
                "version": manifest_info["version"],
            }
            if internal_contract is not None:
                if first_backup_binding is None:
                    fail("internal-test activation lacks first-backup authority")
                committed_active_state.update(
                    {
                        "firstBackup": first_backup_binding,
                        "onboardingArchivePath": str(onboarding_archive),
                        "onboardingReceiptSha256": onboarding_sha,
                        "runtimeContractId": internal_contract["contractId"],
                        "runtimeContractSha256": internal_contract_sha,
                    }
                )
            atomic_json(
                active_state_path,
                committed_active_state,
                mode=0o600,
            )
            write_runtime_authority(
                target=target,
                manifest=manifest_info,
                live_evidence=live_database_evidence,
                first_backup_binding=first_backup_binding,
            )
            if internal_contract is not None:
                finalize_internal_test_onboarding_adoption_if_committed(
                    target=target,
                    manifest=manifest_info,
                    live_evidence=live_database_evidence,
                )
            desired_boot_enablement = (
                {unit: True for unit in BOOT_UNITS}
                if args.first_release
                else boot_enabled_before
            )
            commit_boot_enablement(desired_boot_enablement, manifest_info)
            start_unit("nginx.service")
            if not unit_active("nginx.service"):
                fail("nginx did not remain active after committed release start")
            validate_static_entry(manifest_info)
            for service in WATCHDOG_SERVICES:
                run_oneshot_probe(service)
            log(
                f"activated signed release {manifest_info['version']} commit "
                f"{manifest_info['commitSha']} after strict health verification"
            )
        except Exception as activation_error:
            if transaction_preparing or maintenance_started or switched:
                recover_failed_activation(
                    activation_error=activation_error,
                    base=base,
                    old_target=old_target,
                    old_info=old_info,
                    new_info=manifest_info,
                    nginx_was_active=nginx_was_active,
                    active_timers=active_timers,
                    boot_enabled_before=boot_enabled_before,
                    transaction_started=transaction_started,
                    schema_change_attempted=schema_change_attempted,
                    activation_state_commit_started=activation_state_commit_started,
                    legacy_retirement=legacy_retirement,
                    legacy_retirement_committed=legacy_retirement_committed,
                    legacy_current_evidence=legacy_current_evidence,
                )
            raise
        cleanup_snapshot()
        atexit.unregister(cleanup_snapshot)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--state-dir",
        default=os.environ.get("UTEN_UPDATER_STATE_DIR", str(DEFAULT_STATE_DIR)),
    )
    result.add_argument(
        "--allowed-signers",
        default=os.environ.get(
            "UTEN_RELEASE_ALLOWED_SIGNERS", str(DEFAULT_ALLOWED_SIGNERS)
        ),
    )
    result.add_argument(
        "--lock-file",
        default=os.environ.get("UTEN_RELEASE_LOCK_FILE", str(DEFAULT_LOCK_FILE)),
    )
    subcommands = result.add_subparsers(dest="command", required=True)
    subcommands.add_parser("stage")
    inspect = subcommands.add_parser("inspect")
    inspect.add_argument("version")

    activate = subcommands.add_parser("activate")
    activate.add_argument("version")
    activate.add_argument("--confirm-version", required=True)
    activate.add_argument("--confirm-flyway", required=True)
    activate.add_argument("--confirm-flyway-digest", required=True)
    activate.add_argument("--approve-database-change", action="store_true")
    activate.add_argument("--confirm-session-clearance", action="store_true")
    activate.add_argument("--first-release", action="store_true")
    activate.add_argument("--enable-on-boot", action="store_true")
    activate.add_argument("--retire-legacy-current", action="store_true")
    activate.add_argument("--confirm-legacy-retirement")
    activate.add_argument(
        "--issue-activation-reauthorization-only", action="store_true"
    )
    activate.add_argument("--reauthorization-approval-reference")
    activate.add_argument("--expected-activation-reauthorization-sha256")

    recover = subcommands.add_parser("recover")
    recovery_commands = recover.add_subparsers(dest="recovery_command", required=True)
    recovery_commands.add_parser("assess")
    recovery_commands.add_parser("interrupted-assess")
    recovery_apply = recovery_commands.add_parser("apply")
    recovery_apply.add_argument(
        "--action",
        choices=(
            "retry-activation",
            "finish-activation",
            "restore-previous",
            "abandon-candidate",
            "remain-contained",
        ),
        required=True,
    )
    recovery_apply.add_argument("--expected-plan-sha256", required=True)
    recovery_apply.add_argument("--expected-marker-sha256", required=True)
    recovery_apply.add_argument("--target-version", required=True)
    recovery_apply.add_argument("--approval-reference", required=True)
    recovery_apply.add_argument("--database-receipt")
    recovery_apply.add_argument("--expected-database-receipt-sha256")
    recovery_apply.add_argument("--confirm", required=True)
    interrupted_apply = recovery_commands.add_parser("interrupted-apply")
    interrupted_apply.add_argument("--action", choices=("contain",), required=True)
    interrupted_apply.add_argument("--expected-plan-sha256", required=True)
    interrupted_apply.add_argument("--confirm", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "stage":
            stage_release(args)
        elif args.command == "inspect":
            inspect_release(args)
        elif args.command == "activate":
            activate_release(args)
        elif args.command == "recover":
            if args.recovery_command == "assess":
                recover_assess()
            elif args.recovery_command == "interrupted-assess":
                recover_interrupted_assess()
            elif args.recovery_command == "apply":
                recover_apply(args)
            elif args.recovery_command == "interrupted-apply":
                recover_interrupted_apply(args)
            else:
                fail(f"unsupported recovery command: {args.recovery_command}")
        else:
            fail(f"unsupported updater command: {args.command}")
        return 0
    except (
        OSError,
        subprocess.CalledProcessError,
        release_guard.ReleaseGuardError,
        UpdaterError,
    ) as exc:
        log(f"ERROR: {exc}", "err")
        return 1


if __name__ == "__main__":
    sys.exit(main())
