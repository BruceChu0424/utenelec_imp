#!/usr/bin/env python3
"""Publish the reviewed internal-test host policy without opening any entry."""

from __future__ import annotations

import argparse
import ast
import contextlib
import fcntl
import grp
import hashlib
import ipaddress
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_BUILDER = ROOT / "setup/build-internal-test-reviewed-host-manifest.py"
REVIEWED_BACKUP_INSTALLER_LAUNCHER_SHA256 = (
    "a9f7e32cb8011f0a15af27d4620a9afa8cae7eee50f09a214a3cb84034d040a8"
)
BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY = "backupInstallerLauncherSha256"
BACKUP_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY = (
    "backupInstallerBundleInventorySha256"
)
BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY = {
    "existingBackupInstallerSha256": "deploy/postgres/backup/existing_host_installer.py",
    "backupLockedJobSha256": "deploy/postgres/backup/locked_job.py",
    "backupRepo2HelperSha256": "deploy/postgres/backup/pgbackrest_repo2.py",
    "backupHealthHelperSha256": "deploy/postgres/backup/pgbackrest_health.py",
    "backupAlertHelperSha256": "deploy/postgres/backup/backup_alert.py",
    "backupAcceptanceHelperSha256": "deploy/postgres/backup/backup_acceptance.py",
    "backupCommissionerSha256": "deploy/postgres/backup/backup_commissioner.py",
    "internalTestFirstBackupSha256": "deploy/postgres/backup/internal_test_first_backup.py",
    "internalTestFirstBackupCommissionerSha256": "deploy/postgres/backup/internal_test_first_backup_commissioner.py",
    "backupServiceTemplateSha256": "deploy/systemd/uten-pgbackup.service.example",
    "backupTimerTemplateSha256": "deploy/systemd/uten-pgbackup.timer.example",
    "backupRepo2ServiceTemplateSha256": "deploy/systemd/uten-pgbackup-repo2.service.example",
    "backupRepo2TimerTemplateSha256": "deploy/systemd/uten-pgbackup-repo2.timer.example",
    "backupHealthServiceTemplateSha256": "deploy/systemd/uten-pgbackup-health.service.example",
    "backupHealthTimerTemplateSha256": "deploy/systemd/uten-pgbackup-health.timer.example",
    "backupAlertServiceTemplateSha256": "deploy/systemd/uten-pgbackup-alert@.service.example",
    "backupAlertDrainServiceTemplateSha256": "deploy/systemd/uten-pgbackup-alert-drain.service.example",
    "backupAlertDrainTimerTemplateSha256": "deploy/systemd/uten-pgbackup-alert-drain.timer.example",
}
BACKUP_INSTALLER_BUNDLE_ROOT_POSIX = (
    "/usr/local/share/uten-imp-backup-installer-source"
)
BACKUP_INSTALLER_LAUNCHER_TARGET_POSIX = (
    "/usr/local/sbin/uten-imp-existing-backup-installer"
)
BACKUP_INSTALLER_BUNDLE_ROOT = Path(BACKUP_INSTALLER_BUNDLE_ROOT_POSIX)
BACKUP_INSTALLER_LAUNCHER_TARGET = Path(BACKUP_INSTALLER_LAUNCHER_TARGET_POSIX)
BACKUP_INSTALLER_BUNDLE_SOURCE_KEYS = frozenset(
    BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY
)
BACKUP_INSTALLER_SOURCE_KEYS = frozenset(
    {BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY, *BACKUP_INSTALLER_BUNDLE_SOURCE_KEYS}
)
BACKUP_INSTALLER_INSTALLER_SOURCE_KEY = "existingBackupInstallerSha256"
BACKUP_INSTALLER_BUNDLE_TARGETS = {
    key: BACKUP_INSTALLER_BUNDLE_ROOT / relative
    for key, relative in BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
}
REVIEWED_MONITORING_INSTALLER_LAUNCHER_SHA256 = (
    "afc33acd916d70430da6447a0c5de27b602a879fa82ba27a15ad63dbab2b3726"
)
MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY = "monitoringInstallerLauncherSha256"
MONITORING_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY = (
    "monitoringInstallerBundleInventorySha256"
)
MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY = {
    "existingMonitoringInstallerSha256": "deploy/monitoring/existing_host_monitoring_installer.py",
    "monitorRuntimeLauncherSha256": "deploy/monitoring/monitor_runtime_launcher.py",
    "monitoringCommonSha256": "deploy/monitoring/monitoring_common.py",
    "monitorAlertSpoolSha256": "deploy/monitoring/alert_spool.py",
    "hostMonitorSha256": "deploy/monitoring/host_monitor.py",
    "externalMonitorProbeSha256": "deploy/monitoring/external_probe.py",
    "monitoringReadmeSha256": "deploy/monitoring/README.zh-CN.md",
    "monitoringInstallerRunbookSha256": "deploy/monitoring/EXISTING_HOST_MONITORING_INSTALLER.zh-CN.md",
    "hostMonitorServiceTemplateSha256": "deploy/systemd/uten-imp-host-monitor.service.example",
    "hostMonitorTimerTemplateSha256": "deploy/systemd/uten-imp-host-monitor.timer.example",
    "externalMonitorServiceTemplateSha256": "deploy/systemd/uten-imp-external-monitor.service.example",
    "externalMonitorTimerTemplateSha256": "deploy/systemd/uten-imp-external-monitor.timer.example",
    "monitorAlertDrainServiceTemplateSha256": "deploy/systemd/uten-imp-monitor-alert-drain.service.example",
    "monitorAlertDrainTimerTemplateSha256": "deploy/systemd/uten-imp-monitor-alert-drain.timer.example",
    "monitorFailureServiceTemplateSha256": "deploy/systemd/uten-imp-monitor-failure@.service.example",
}
MONITORING_INSTALLER_BUNDLE_ROOT_POSIX = (
    "/usr/local/share/uten-imp-monitoring-installer-source"
)
MONITORING_INSTALLER_LAUNCHER_TARGET_POSIX = (
    "/usr/local/sbin/uten-imp-existing-monitoring-installer"
)
MONITORING_INSTALLER_BUNDLE_ROOT = Path(MONITORING_INSTALLER_BUNDLE_ROOT_POSIX)
MONITORING_INSTALLER_LAUNCHER_TARGET = Path(
    MONITORING_INSTALLER_LAUNCHER_TARGET_POSIX
)
MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS = frozenset(
    MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY
)
MONITORING_INSTALLER_SOURCE_KEYS = frozenset(
    {
        MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY,
        *MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS,
    }
)
MONITORING_INSTALLER_INSTALLER_SOURCE_KEY = "existingMonitoringInstallerSha256"
MONITORING_INSTALLER_BUNDLE_TARGETS = {
    key: MONITORING_INSTALLER_BUNDLE_ROOT / relative
    for key, relative in MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
}
REVIEWED_RETENTION_INSTALLER_LAUNCHER_SHA256 = (
    "248cf15947ab442a6d79b2de21276edad58a8bd0820bb78f63a83146a30da153"
)
RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY = "retentionInstallerLauncherSha256"
RETENTION_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY = (
    "retentionInstallerBundleInventorySha256"
)
RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY = {
    "releaseRetentionInstallerSha256": "deploy/setup/install-release-retention.py",
    "retentionBundleReleaseUpdaterSha256": "deploy/updater/release_updater.py",
    "retentionBundleReleaseGuardSha256": "deploy/updater/release_guard.py",
    "retentionManagerSha256": "deploy/updater/retention_manager.py",
    "retentionRuntimeLauncherSha256": "deploy/updater/retention_launcher.py",
    "retentionEntrypointSha256": "deploy/updater/uten-imp-retention.sh",
    "retentionPolicyExampleSha256": "deploy/updater/retention-policy.json.example",
    "retentionServiceTemplateSha256": "deploy/systemd/uten-imp-retention.service.example",
    "retentionTimerTemplateSha256": "deploy/systemd/uten-imp-retention.timer.example",
    "retentionAlertServiceTemplateSha256": "deploy/systemd/uten-imp-retention-alert@.service.example",
}
RETENTION_INSTALLER_BUNDLE_ROOT_POSIX = (
    "/usr/local/share/uten-imp-release-retention-installer-source"
)
RETENTION_INSTALLER_LAUNCHER_TARGET_POSIX = (
    "/usr/local/sbin/uten-imp-release-retention-installer"
)
RETENTION_INSTALLER_BUNDLE_ROOT = Path(RETENTION_INSTALLER_BUNDLE_ROOT_POSIX)
RETENTION_INSTALLER_LAUNCHER_TARGET = Path(
    RETENTION_INSTALLER_LAUNCHER_TARGET_POSIX
)
RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS = frozenset(
    RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY
)
RETENTION_INSTALLER_SOURCE_KEYS = frozenset(
    {RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY, *RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS}
)
RETENTION_INSTALLER_INSTALLER_SOURCE_KEY = "releaseRetentionInstallerSha256"
RETENTION_INSTALLER_UPDATER_SOURCE_KEY = "retentionBundleReleaseUpdaterSha256"
RETENTION_INSTALLER_GUARD_SOURCE_KEY = "retentionBundleReleaseGuardSha256"
RETENTION_INSTALLER_MANAGER_SOURCE_KEY = "retentionManagerSha256"
RETENTION_INSTALLER_RUNTIME_LAUNCHER_SOURCE_KEY = "retentionRuntimeLauncherSha256"
RETENTION_INSTALLER_BUNDLE_TARGETS = {
    key: RETENTION_INSTALLER_BUNDLE_ROOT / relative
    for key, relative in RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
}
TRUSTED_INSTALLER_SOURCE_KEYS = frozenset(
    BACKUP_INSTALLER_SOURCE_KEYS
    | MONITORING_INSTALLER_SOURCE_KEYS
    | RETENTION_INSTALLER_SOURCE_KEYS
)
TRUSTED_INSTALLER_BUNDLE_SOURCE_KEYS = frozenset(
    BACKUP_INSTALLER_BUNDLE_SOURCE_KEYS
    | MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS
    | RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS
)
TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS = frozenset(
    {
        BACKUP_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY,
        MONITORING_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY,
        RETENTION_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY,
    }
)
SOURCES = {
    "serviceUnitSha256": ROOT / "systemd/uten-imp-internal-test.service.example",
    "environmentValidatorSha256": ROOT / "setup/validate-internal-test-server-env.sh",
    "storageValidatorSha256": ROOT / "setup/validate-internal-test-storage.sh",
    "databaseCommissionerSha256": ROOT / "setup/existing-test-host-internal-db-commissioner.py",
    "databaseCommissionerUnitSha256": ROOT / "systemd/uten-imp-internal-db-commissioner.service.example",
    "releaseGuardSha256": ROOT / "updater/release_guard.py",
    "updaterReleaseGuardSha256": ROOT / "updater/release_guard.py",
    "releaseUpdaterSha256": ROOT / "updater/release_updater.py",
    "databaseRecoveryVerifierSha256": ROOT / "updater/database_recovery_verifier.py",
    "runtimeBootVerifierSha256": ROOT / "updater/runtime_boot_verifier.py",
    "recoveryCommitBootVerifierSha256": ROOT / "updater/recovery_commit_boot_verifier.py",
    "recoveryCommitBootUnitSha256": ROOT / "systemd/uten-imp-recovery-commit-verifier.service.example",
    "recoveryIngressGateSha256": ROOT / "updater/recovery_ingress_gate.py",
    "storageBootVerifierSha256": ROOT / "updater/storage_boot_verifier.py",
    "postgresInternalTestConfigSha256": ROOT / "postgres/internal-test-archive-disabled.conf",
    "postgresHbaSha256": ROOT / "postgres/internal-test-pg_hba.conf",
    "updaterOssIoSha256": ROOT / "updater/oss_io.py",
    "updaterEnvironmentValidatorSha256": ROOT / "updater/validate_oss_pull_env.py",
    "updaterEntrypointSha256": ROOT / "updater/uten-imp-updater.sh",
    "updaterServiceUnitSha256": ROOT / "updater/uten-imp-updater.service",
    "updaterTimerUnitSha256": ROOT / "updater/uten-imp-updater.timer",
    "activationEntrypointSha256": ROOT / "updater/uten-imp-activate.sh",
    "recoveryEntrypointSha256": ROOT / "updater/uten-imp-recover.sh",
    "migrationAuthorizationHelperSha256": ROOT / "updater/migration_authorization.py",
    "storageMountObserverSha256": ROOT / "updater/storage_mount_observer.py",
    "migratorEnvironmentValidatorSha256": ROOT / "setup/validate-migrator-env.sh",
    "nginxReadinessGateSha256": ROOT / "setup/wait-for-erp-readiness.sh",
    "migrationServiceUnitSha256": ROOT / "systemd/uten-imp-migrate.service.example",
    "nginxSystemdDropinSha256": ROOT / "systemd/nginx-uten-imp-override.conf.example",
    "postgresStorageDropinSha256": ROOT / "systemd/postgresql-uten-imp-storage.conf.example",
    "storageObserverUnitSha256": ROOT / "systemd/uten-imp-storage-observer.service.example",
    "watchdogScriptSha256": ROOT / "watchdog/uten-imp-watchdog.sh",
    "watchdogServiceUnitSha256": ROOT / "systemd/uten-imp-watchdog.service.example",
    "watchdogTimerUnitSha256": ROOT / "systemd/uten-imp-watchdog.timer.example",
    "entryWatchdogScriptSha256": ROOT / "watchdog/uten-imp-entry-watchdog.sh",
    "entryWatchdogServiceUnitSha256": ROOT / "systemd/uten-imp-entry-watchdog.service.example",
    "entryWatchdogTimerUnitSha256": ROOT / "systemd/uten-imp-entry-watchdog.timer.example",
    "wheelhouseSupplyChainSha256": ROOT / "updater/wheelhouse_supply_chain.py",
    "updaterRequirementsLockSha256": ROOT / "updater/wheelhouse/requirements.lock",
    BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY: ROOT
    / "postgres/backup/launch-existing-host-installer.py",
    **{
        key: ROOT.parent / relative
        for key, relative in BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
    },
    MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY: ROOT
    / "monitoring/launch-existing-host-monitoring-installer.py",
    **{
        key: ROOT.parent / relative
        for key, relative in MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
    },
    RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY: ROOT
    / "setup/launch-install-release-retention.py",
    **{
        key: ROOT.parent / relative
        for key, relative in RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
    },
}
TARGETS = {
    "serviceUnitSha256": Path("/etc/systemd/system/uten-imp.service"),
    "environmentValidatorSha256": Path("/usr/local/sbin/uten-imp-validate-internal-test-server-env"),
    "storageValidatorSha256": Path("/usr/local/sbin/uten-imp-validate-internal-test-storage"),
    "databaseCommissionerSha256": Path("/usr/local/sbin/uten-imp-existing-test-host-db-commissioner"),
    "databaseCommissionerUnitSha256": Path(
        "/etc/systemd/system/uten-imp-internal-db-commissioner.service"
    ),
    "releaseGuardSha256": Path("/usr/local/libexec/uten-imp-release/release_guard.py"),
    "updaterReleaseGuardSha256": Path("/opt/uten-imp/updater/release_guard.py"),
    "releaseUpdaterSha256": Path("/opt/uten-imp/updater/release_updater.py"),
    "databaseRecoveryVerifierSha256": Path("/usr/local/libexec/uten-imp-release/database_recovery_verifier.py"),
    "runtimeBootVerifierSha256": Path("/usr/local/libexec/uten-imp-release/runtime_boot_verifier.py"),
    "recoveryCommitBootVerifierSha256": Path(
        "/usr/local/libexec/uten-imp-release/recovery_commit_boot_verifier.py"
    ),
    "recoveryCommitBootUnitSha256": Path(
        "/etc/systemd/system/uten-imp-recovery-commit-verifier.service"
    ),
    "recoveryIngressGateSha256": Path(
        "/usr/local/libexec/uten-imp-release/recovery_ingress_gate.py"
    ),
    "storageBootVerifierSha256": Path("/usr/local/libexec/uten-imp-release/storage_boot_verifier.py"),
    "postgresInternalTestConfigSha256": Path(
        "/etc/postgresql/16/main/conf.d/99-uten-imp-internal-test.conf"
    ),
    "postgresHbaSha256": Path("/etc/postgresql/16/main/pg_hba.conf"),
    "updaterOssIoSha256": Path("/opt/uten-imp/updater/oss_io.py"),
    "updaterEnvironmentValidatorSha256": Path(
        "/opt/uten-imp/updater/validate_oss_pull_env.py"
    ),
    "updaterEntrypointSha256": Path("/opt/uten-imp/updater/uten-imp-updater.sh"),
    "updaterServiceUnitSha256": Path(
        "/etc/systemd/system/uten-imp-updater.service"
    ),
    "updaterTimerUnitSha256": Path(
        "/etc/systemd/system/uten-imp-updater.timer"
    ),
    "activationEntrypointSha256": Path("/usr/local/sbin/uten-imp-activate"),
    "recoveryEntrypointSha256": Path("/usr/local/sbin/uten-imp-recover"),
    "migrationAuthorizationHelperSha256": Path(
        "/usr/local/libexec/uten-imp-release/migration_authorization.py"
    ),
    "storageMountObserverSha256": Path(
        "/usr/local/libexec/uten-imp-release/storage_mount_observer.py"
    ),
    "migratorEnvironmentValidatorSha256": Path(
        "/usr/local/sbin/uten-imp-validate-migrator-env"
    ),
    "nginxReadinessGateSha256": Path(
        "/usr/local/libexec/uten-imp/uten-imp-wait-ready"
    ),
    "migrationServiceUnitSha256": Path(
        "/etc/systemd/system/uten-imp-migrate.service"
    ),
    "nginxSystemdDropinSha256": Path(
        "/etc/systemd/system/nginx.service.d/uten-imp.conf"
    ),
    "postgresStorageDropinSha256": Path(
        "/etc/systemd/system/postgresql@16-main.service.d/uten-imp-storage.conf"
    ),
    "storageObserverUnitSha256": Path(
        "/etc/systemd/system/uten-imp-storage-observer.service"
    ),
    "watchdogScriptSha256": Path("/usr/local/libexec/uten-imp/uten-imp-watchdog"),
    "watchdogServiceUnitSha256": Path(
        "/etc/systemd/system/uten-imp-watchdog.service"
    ),
    "watchdogTimerUnitSha256": Path(
        "/etc/systemd/system/uten-imp-watchdog.timer"
    ),
    "entryWatchdogScriptSha256": Path(
        "/usr/local/libexec/uten-imp/uten-imp-entry-watchdog"
    ),
    "entryWatchdogServiceUnitSha256": Path(
        "/etc/systemd/system/uten-imp-entry-watchdog.service"
    ),
    "entryWatchdogTimerUnitSha256": Path(
        "/etc/systemd/system/uten-imp-entry-watchdog.timer"
    ),
    "wheelhouseSupplyChainSha256": Path(
        "/opt/uten-imp/updater/wheelhouse_supply_chain.py"
    ),
    "updaterRequirementsLockSha256": Path(
        "/opt/uten-imp/updater/requirements.lock"
    ),
    BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY: BACKUP_INSTALLER_LAUNCHER_TARGET,
    **BACKUP_INSTALLER_BUNDLE_TARGETS,
    MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY: MONITORING_INSTALLER_LAUNCHER_TARGET,
    **MONITORING_INSTALLER_BUNDLE_TARGETS,
    RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY: RETENTION_INSTALLER_LAUNCHER_TARGET,
    **RETENTION_INSTALLER_BUNDLE_TARGETS,
}
SYSTEMD_UNIT_SOURCE_KEYS = {
    "databaseCommissionerUnitSha256": "uten-imp-internal-db-commissioner.service",
    "entryWatchdogServiceUnitSha256": "uten-imp-entry-watchdog.service",
    "entryWatchdogTimerUnitSha256": "uten-imp-entry-watchdog.timer",
    "migrationServiceUnitSha256": "uten-imp-migrate.service",
    "recoveryCommitBootUnitSha256": "uten-imp-recovery-commit-verifier.service",
    "serviceUnitSha256": "uten-imp.service",
    "storageObserverUnitSha256": "uten-imp-storage-observer.service",
    "updaterServiceUnitSha256": "uten-imp-updater.service",
    "updaterTimerUnitSha256": "uten-imp-updater.timer",
    "watchdogServiceUnitSha256": "uten-imp-watchdog.service",
    "watchdogTimerUnitSha256": "uten-imp-watchdog.timer",
}
SYSTEMD_DROPIN_SOURCE_KEYS = {
    "nginxSystemdDropinSha256": "nginx.service",
    "postgresStorageDropinSha256": "postgresql@16-main.service",
}
SYSTEMD_REFERENCE_DIRECTIVES = frozenset(
    {
        "After",
        "Before",
        "BindsTo",
        "Conflicts",
        "OnFailure",
        "PartOf",
        "Requisite",
        "Requires",
        "Unit",
        "Wants",
    }
)
SYSTEMD_EXECUTABLE_RE = re.compile(
    r"(?m)^Exec(?:Condition|Reload|Start(?:Pre|Post)?|Stop(?:Post)?)="
    r"[@:+!\-]*(/[^\s;]+)"
)
NGINX_SOURCE = ROOT / "nginx/uten-imp-internal-test.conf.example"
NGINX_TARGET = Path("/etc/nginx/sites-available/uten-imp-internal-test.conf")
NGINX_LINK = Path("/etc/nginx/sites-enabled/uten-imp-internal-test.conf")
LEGACY_NGINX_TARGET = Path("/etc/nginx/conf.d/uten-imp.conf")
LEGACY_NGINX_ARCHIVE_ROOT = Path("/etc/nginx/uten-imp-disabled")
SERVER_ENV = Path("/etc/uten-imp/server.env")
SERVER_ENV_PENDING = Path("/etc/uten-imp/server.env.pending")
MIGRATOR_ENV_DIR = Path("/etc/uten-imp-migrator")
MIGRATOR_ENV = MIGRATOR_ENV_DIR / "migrator.env"
MIGRATOR_SECRET = Path("/etc/uten-imp-postgres/migrator.password")
ROOT_STATE = Path("/var/lib/uten-imp-release")
CONTRACT = ROOT_STATE / "internal-test-runtime-contract.json"
EVIDENCE = Path("/var/lib/uten-imp-internal-test-host-preparation")
ACTIVE = EVIDENCE / "active.json"
MUTATION_ACTIVE = EVIDENCE / "mutation-active.json"
LOCK_FILE = Path("/run/lock/uten-imp-internal-test-host-preparation.lock")
STORAGE_AUTHORITY = Path("/etc/uten-imp/storage-authority.json")
NVME_EVIDENCE = Path("/var/lib/uten-imp-nvme-commissioning")
NVME_ACTIVE_POINTER = NVME_EVIDENCE / "active.json"
STORAGE_BOOT_VERIFIER = Path(
    "/usr/local/libexec/uten-imp-release/storage_boot_verifier.py"
)
ATTACHMENT_ROOT = Path("/data/uten-imp/attachments")
ENTRY_UNITS = (
    "uten-imp.service",
    "nginx.service",
    "uten-imp-watchdog.timer",
    "uten-imp-entry-watchdog.timer",
    "uten-imp-updater.timer",
    "uten-imp-updater.service",
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
DOMAIN_RE = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")
APPROVAL_RE = re.compile(r"CHG-[A-Z0-9][A-Z0-9._-]{5,95}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
UTC_RE = re.compile(r"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z")
MAX_JSON_BYTES = 4 * 1024 * 1024
TLS_ROOT = Path("/etc/uten-imp/tls")
UPDATER_ROOT = Path("/opt/uten-imp/updater")
UPDATER_VENV_PYTHON = UPDATER_ROOT / "venv/bin/python"
UPDATER_ALLOWED_SIGNERS = Path("/etc/uten-imp-updater/release-allowed-signers")
STABLE_ALLOWED_SIGNERS = Path(
    "/etc/uten-imp-release-trust/release-allowed-signers"
)
UPDATER_OSS_ENV = Path("/etc/uten-imp-updater/oss-pull.env")
UPDATER_STATE = Path("/var/lib/uten-imp-updater")
OPERATION_LOCK = ROOT_STATE / "operation.lock"
UPDATER_SERVICE = "uten-imp-updater.service"
UPDATER_TIMER = "uten-imp-updater.timer"
SSH_ALLOWED_SIGNER_RE = re.compile(
    rb"uten-imp-release[ \t]+ssh-ed25519[ \t]+[A-Za-z0-9+/]+={0,2}(?:[ \t]+[^\r\n]+)?\n?"
)
DB_EVIDENCE_ROOT = Path("/var/lib/uten-imp-internal-test-commissioning")
ONBOARDING_ARCHIVE_ROOT = ROOT_STATE / "internal-test-onboarding-evidence"


class PreparationError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise PreparationError(message)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def stable_root_digest(path: Path, *, mode: int, maximum_bytes: int = 16 * 1024 * 1024) -> str:
    """Hash an exact root:root file through one no-follow stable descriptor."""

    expected = root_file(path, mode=mode)
    if expected.st_gid != 0 or not hasattr(os, "O_NOFOLLOW"):
        fail(f"root digest input metadata is unsafe: {path}")
    descriptor = os.open(
        path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        before = os.fstat(descriptor)
        live = path.lstat()
        if (
            (before.st_dev, before.st_ino) != (live.st_dev, live.st_ino)
            or before.st_uid != 0
            or before.st_gid != 0
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != mode
            or not 1 <= before.st_size <= maximum_bytes
        ):
            fail(f"root digest input changed before read: {path}")
        digest = hashlib.sha256()
        remaining = maximum_bytes + 1
        read_bytes = 0
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                break
            digest.update(block)
            read_bytes += len(block)
            remaining -= len(block)
        after = os.fstat(descriptor)
        live_after = path.lstat()
        if (
            read_bytes != before.st_size
            or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            != (live_after.st_dev, live_after.st_ino, live_after.st_size, live_after.st_mtime_ns, live_after.st_ctime_ns)
        ):
            fail(f"root digest input changed while read: {path}")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def stable_root_bytes(
    path: Path,
    *,
    mode: int | None = None,
    maximum_bytes: int = 16 * 1024 * 1024,
) -> bytes:
    """Read one exact root-controlled inode without a hash/path reopen gap."""

    expected = root_file(path, mode=mode)
    if expected.st_gid != 0 or not hasattr(os, "O_NOFOLLOW"):
        fail(f"root byte input metadata is unsafe: {path}")
    descriptor = os.open(
        path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        before = os.fstat(descriptor)
        live = path.lstat()
        if (
            (before.st_dev, before.st_ino) != (live.st_dev, live.st_ino)
            or before.st_uid != 0
            or before.st_gid != 0
            or before.st_nlink != 1
            or (mode is not None and stat.S_IMODE(before.st_mode) != mode)
            or not 1 <= before.st_size <= maximum_bytes
        ):
            fail(f"root byte input changed before read: {path}")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        read_bytes = 0
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                break
            chunks.append(block)
            read_bytes += len(block)
            remaining -= len(block)
        after = os.fstat(descriptor)
        live_after = path.lstat()
        identity = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        if (
            read_bytes != before.st_size
            or identity
            != (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            )
            or identity
            != (
                live_after.st_dev,
                live_after.st_ino,
                live_after.st_size,
                live_after.st_mtime_ns,
                live_after.st_ctime_ns,
            )
        ):
            fail(f"root byte input changed while read: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def strict_json_document(raw: bytes, label: str) -> dict[str, Any]:
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
            parse_constant=lambda item: fail(
                f"{label} contains a non-finite value: {item}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PreparationError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} root is not an object")
    return value


def _backup_installer_launcher_contract(payload: bytes) -> dict[str, Any]:
    """Parse, but never execute, the fixed launcher's reviewed constants."""

    try:
        source = payload.decode("utf-8", errors="strict")
        tree = ast.parse(source, filename="launch-existing-host-installer.py")
    except (UnicodeDecodeError, SyntaxError) as exc:
        raise PreparationError("backup installer launcher is not strict Python source") from exc
    required = {
        "INSTALLED_INSTALLER",
        "INSTALLED_LAUNCHER",
        "INSTALLER_MODE",
        "LAUNCHER_MODE",
        "REVIEWED_INSTALLER_SHA256",
        "SOURCE_BUNDLE_RELATIVE_FILES",
        "SOURCE_BUNDLE_ROOT",
        "SOURCE_DIRECTORY_MODE",
    }
    assignments: dict[str, ast.AST] = {}
    for statement in tree.body:
        if (
            isinstance(statement, ast.Assign)
            and len(statement.targets) == 1
            and isinstance(statement.targets[0], ast.Name)
            and statement.targets[0].id in required
        ):
            name = statement.targets[0].id
            if name in assignments:
                fail(f"backup installer launcher repeats reviewed constant {name}")
            assignments[name] = statement.value
    if set(assignments) != required:
        fail("backup installer launcher reviewed constant inventory differs")

    def literal(name: str, expected_type: type[Any]) -> Any:
        try:
            value = ast.literal_eval(assignments[name])
        except (ValueError, TypeError, SyntaxError) as exc:
            raise PreparationError(
                f"backup installer launcher constant {name} is not literal"
            ) from exc
        if not isinstance(value, expected_type):
            fail(f"backup installer launcher constant {name} has the wrong type")
        return value

    def path_literal(name: str) -> str:
        node = assignments[name]
        if (
            not isinstance(node, ast.Call)
            or not isinstance(node.func, ast.Name)
            or node.func.id != "Path"
            or len(node.args) != 1
            or node.keywords
        ):
            fail(f"backup installer launcher path {name} is not a fixed Path literal")
        try:
            value = ast.literal_eval(node.args[0])
        except (ValueError, TypeError, SyntaxError) as exc:
            raise PreparationError(
                f"backup installer launcher path {name} is not literal"
            ) from exc
        if not isinstance(value, str):
            fail(f"backup installer launcher path {name} is not text")
        return value

    return {
        "installedInstaller": path_literal("INSTALLED_INSTALLER"),
        "installedLauncher": path_literal("INSTALLED_LAUNCHER"),
        "installerMode": literal("INSTALLER_MODE", int),
        "launcherMode": literal("LAUNCHER_MODE", int),
        "reviewedInstallerSha256": literal("REVIEWED_INSTALLER_SHA256", str),
        "sourceBundleRelativeFiles": literal(
            "SOURCE_BUNDLE_RELATIVE_FILES", tuple
        ),
        "sourceBundleRoot": path_literal("SOURCE_BUNDLE_ROOT"),
        "sourceDirectoryMode": literal("SOURCE_DIRECTORY_MODE", int),
    }


def validate_backup_installer_source_payloads(
    payloads: dict[str, bytes],
) -> dict[str, str]:
    """Bind the launcher allowlist and embedded installer pin to captured bytes."""

    if set(payloads) != BACKUP_INSTALLER_SOURCE_KEYS:
        fail("backup installer captured source inventory differs")
    if any(not isinstance(value, bytes) or not value for value in payloads.values()):
        fail("backup installer captured source bytes are empty or malformed")
    launcher_payload = payloads[BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY]
    launcher_sha = hashlib.sha256(launcher_payload).hexdigest()
    if launcher_sha != REVIEWED_BACKUP_INSTALLER_LAUNCHER_SHA256:
        fail("backup installer launcher differs from the frozen reviewed digest")
    contract = _backup_installer_launcher_contract(launcher_payload)
    expected_relative = tuple(BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.values())
    installer_sha = hashlib.sha256(
        payloads[BACKUP_INSTALLER_INSTALLER_SOURCE_KEY]
    ).hexdigest()
    expected_installer = (
        BACKUP_INSTALLER_BUNDLE_ROOT_POSIX
        + "/"
        + BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY[
            BACKUP_INSTALLER_INSTALLER_SOURCE_KEY
        ]
    )
    if (
        contract["installedLauncher"] != BACKUP_INSTALLER_LAUNCHER_TARGET_POSIX
        or contract["installedInstaller"] != expected_installer
        or contract["sourceBundleRoot"] != BACKUP_INSTALLER_BUNDLE_ROOT_POSIX
        or contract["sourceBundleRelativeFiles"] != expected_relative
        or len(set(expected_relative)) != 18
        or contract["reviewedInstallerSha256"] != installer_sha
        or contract["installerMode"] != 0o400
        or contract["sourceDirectoryMode"] != 0o500
        or contract["launcherMode"] != 0o500
    ):
        fail("backup installer launcher/source-bundle contract differs")
    source_inventory = {
        BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY[key]: hashlib.sha256(
            payloads[key]
        ).hexdigest()
        for key in BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY
    }
    return {
        "installerSha256": installer_sha,
        "launcherSha256": launcher_sha,
        "sourceBundleInventorySha256": hashlib.sha256(
            canonical(source_inventory)
        ).hexdigest(),
    }


def _reviewed_python_assignments(
    payload: bytes,
    *,
    label: str,
    required: set[str],
) -> dict[str, ast.AST]:
    """Capture exact top-level constants from inert reviewed Python bytes."""

    try:
        source = payload.decode("utf-8", errors="strict")
        tree = ast.parse(source, filename=label)
    except (UnicodeDecodeError, SyntaxError) as exc:
        raise PreparationError(f"{label} is not strict Python source") from exc
    assignments: dict[str, ast.AST] = {}
    for statement in tree.body:
        name: str | None = None
        value: ast.AST | None = None
        if (
            isinstance(statement, ast.Assign)
            and len(statement.targets) == 1
            and isinstance(statement.targets[0], ast.Name)
        ):
            name = statement.targets[0].id
            value = statement.value
        elif isinstance(statement, ast.AnnAssign) and isinstance(
            statement.target, ast.Name
        ):
            name = statement.target.id
            value = statement.value
        if name not in required or value is None:
            continue
        if name in assignments:
            fail(f"{label} repeats reviewed constant {name}")
        assignments[name] = value
    if set(assignments) != required:
        fail(f"{label} reviewed constant inventory differs")
    return assignments


def _reviewed_literal(
    assignments: dict[str, ast.AST],
    name: str,
    expected_type: type[Any],
    *,
    label: str,
) -> Any:
    try:
        value = ast.literal_eval(assignments[name])
    except (ValueError, TypeError, SyntaxError) as exc:
        raise PreparationError(f"{label} constant {name} is not literal") from exc
    if not isinstance(value, expected_type) or (
        expected_type is int and isinstance(value, bool)
    ):
        fail(f"{label} constant {name} has the wrong type")
    return value


def _reviewed_path_expression(
    node: ast.AST,
    *,
    label: str,
    known: dict[str, str],
) -> str:
    if (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "Path"
        and len(node.args) == 1
        and not node.keywords
    ):
        try:
            value = ast.literal_eval(node.args[0])
        except (ValueError, TypeError, SyntaxError) as exc:
            raise PreparationError(f"{label} path is not literal") from exc
        if not isinstance(value, str) or not Path(value).is_absolute():
            fail(f"{label} path is not fixed and absolute")
        return value
    if isinstance(node, ast.Name) and node.id in known:
        return known[node.id]
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
        base = _reviewed_path_expression(node.left, label=label, known=known)
        try:
            relative = ast.literal_eval(node.right)
        except (ValueError, TypeError, SyntaxError) as exc:
            raise PreparationError(f"{label} path suffix is not literal") from exc
        relative_path = Path(relative) if isinstance(relative, str) else Path("/")
        if (
            not isinstance(relative, str)
            or relative_path.is_absolute()
            or any(part in {"", ".", ".."} for part in relative_path.parts)
        ):
            fail(f"{label} path suffix is unsafe")
        return str(Path(base) / relative_path)
    fail(f"{label} is not a fixed Path expression")


def _monitoring_installer_launcher_contract(payload: bytes) -> dict[str, Any]:
    label = "monitoring installer launcher"
    required = {
        "BUNDLE_DIRECTORY_MODE",
        "INSTALLED_INSTALLER",
        "INSTALLED_LAUNCHER",
        "INSTALLER_MODE",
        "LAUNCHER_MODE",
        "REVIEWED_INSTALLER_SHA256",
        "REVIEWED_SOURCE_SHA256",
        "SOURCE_BUNDLE_RELATIVE_FILES",
        "SOURCE_BUNDLE_ROOT",
    }
    assignments = _reviewed_python_assignments(
        payload, label=label, required=required
    )
    known = {
        "SOURCE_BUNDLE_ROOT": _reviewed_path_expression(
            assignments["SOURCE_BUNDLE_ROOT"], label=label, known={}
        )
    }
    reviewed = _reviewed_literal(
        assignments, "REVIEWED_SOURCE_SHA256", dict, label=label
    )
    installer_pin = assignments["REVIEWED_INSTALLER_SHA256"]
    installer_relative = MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY[
        MONITORING_INSTALLER_INSTALLER_SOURCE_KEY
    ]
    if not (
        isinstance(installer_pin, ast.Subscript)
        and isinstance(installer_pin.value, ast.Name)
        and installer_pin.value.id == "REVIEWED_SOURCE_SHA256"
        and isinstance(installer_pin.slice, ast.Constant)
        and installer_pin.slice.value == installer_relative
    ):
        fail("monitoring installer pin is not derived from its reviewed inventory")
    return {
        "installedInstaller": _reviewed_path_expression(
            assignments["INSTALLED_INSTALLER"], label=label, known=known
        ),
        "installedLauncher": _reviewed_path_expression(
            assignments["INSTALLED_LAUNCHER"], label=label, known=known
        ),
        "installerMode": _reviewed_literal(
            assignments, "INSTALLER_MODE", int, label=label
        ),
        "launcherMode": _reviewed_literal(
            assignments, "LAUNCHER_MODE", int, label=label
        ),
        "reviewedSourceSha256": reviewed,
        "sourceBundleRelativeFiles": _reviewed_literal(
            assignments, "SOURCE_BUNDLE_RELATIVE_FILES", tuple, label=label
        ),
        "sourceBundleRoot": known["SOURCE_BUNDLE_ROOT"],
        "sourceDirectoryMode": _reviewed_literal(
            assignments, "BUNDLE_DIRECTORY_MODE", int, label=label
        ),
    }


def validate_monitoring_installer_source_payloads(
    payloads: dict[str, bytes],
) -> dict[str, str]:
    if set(payloads) != MONITORING_INSTALLER_SOURCE_KEYS:
        fail("monitoring installer captured source inventory differs")
    if any(not isinstance(value, bytes) or not value for value in payloads.values()):
        fail("monitoring installer captured source bytes are empty or malformed")
    launcher = payloads[MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY]
    launcher_sha = hashlib.sha256(launcher).hexdigest()
    if launcher_sha != REVIEWED_MONITORING_INSTALLER_LAUNCHER_SHA256:
        fail("monitoring installer launcher differs from the frozen reviewed digest")
    contract = _monitoring_installer_launcher_contract(launcher)
    expected_relative = tuple(
        MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.values()
    )
    source_inventory = {
        MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY[key]: hashlib.sha256(
            payloads[key]
        ).hexdigest()
        for key in MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY
    }
    installer_sha = hashlib.sha256(
        payloads[MONITORING_INSTALLER_INSTALLER_SOURCE_KEY]
    ).hexdigest()
    expected_installer = (
        MONITORING_INSTALLER_BUNDLE_ROOT_POSIX + "/" + expected_relative[0]
    )
    if (
        contract["installedLauncher"]
        != MONITORING_INSTALLER_LAUNCHER_TARGET_POSIX
        or contract["installedInstaller"] != expected_installer
        or contract["sourceBundleRoot"] != MONITORING_INSTALLER_BUNDLE_ROOT_POSIX
        or contract["sourceBundleRelativeFiles"] != expected_relative
        or len(set(expected_relative)) != 15
        or contract["reviewedSourceSha256"] != source_inventory
        or contract["reviewedSourceSha256"].get(expected_relative[0])
        != installer_sha
        or contract["installerMode"] != 0o400
        or contract["sourceDirectoryMode"] != 0o500
        or contract["launcherMode"] != 0o500
    ):
        fail("monitoring installer launcher/source-bundle contract differs")
    return {
        "installerSha256": installer_sha,
        "launcherSha256": launcher_sha,
        "sourceBundleInventorySha256": hashlib.sha256(
            canonical(source_inventory)
        ).hexdigest(),
    }


def _retention_installer_launcher_contract(payload: bytes) -> dict[str, Any]:
    label = "retention installer launcher"
    required = {
        "INSTALLED_INSTALLER",
        "INSTALLED_LAUNCHER",
        "INSTALLER_MODE",
        "LAUNCHER_MODE",
        "REVIEWED_INSTALLER_SHA256",
        "SOURCE_BUNDLE_RELATIVE_FILES",
        "SOURCE_BUNDLE_ROOT",
        "SOURCE_DIRECTORY_MODE",
    }
    assignments = _reviewed_python_assignments(
        payload, label=label, required=required
    )
    known = {
        "SOURCE_BUNDLE_ROOT": _reviewed_path_expression(
            assignments["SOURCE_BUNDLE_ROOT"], label=label, known={}
        )
    }
    return {
        "installedInstaller": _reviewed_path_expression(
            assignments["INSTALLED_INSTALLER"], label=label, known=known
        ),
        "installedLauncher": _reviewed_path_expression(
            assignments["INSTALLED_LAUNCHER"], label=label, known=known
        ),
        "installerMode": _reviewed_literal(
            assignments, "INSTALLER_MODE", int, label=label
        ),
        "launcherMode": _reviewed_literal(
            assignments, "LAUNCHER_MODE", int, label=label
        ),
        "reviewedInstallerSha256": _reviewed_literal(
            assignments, "REVIEWED_INSTALLER_SHA256", str, label=label
        ),
        "sourceBundleRelativeFiles": _reviewed_literal(
            assignments, "SOURCE_BUNDLE_RELATIVE_FILES", tuple, label=label
        ),
        "sourceBundleRoot": known["SOURCE_BUNDLE_ROOT"],
        "sourceDirectoryMode": _reviewed_literal(
            assignments, "SOURCE_DIRECTORY_MODE", int, label=label
        ),
    }


def _retention_runtime_launcher_contract(payload: bytes) -> dict[str, Any]:
    label = "retention runtime launcher"
    required = {
        "APPROVED_RELEASE_UPDATER_SHA256",
        "APPROVED_RETENTION_MANAGER_SHA256",
        "LAUNCHER_PATH",
        "RELEASE_UPDATER_PATH",
        "RETENTION_MANAGER_PATH",
        "RUNTIME_DIR",
    }
    assignments = _reviewed_python_assignments(
        payload, label=label, required=required
    )
    known = {
        "RUNTIME_DIR": _reviewed_path_expression(
            assignments["RUNTIME_DIR"], label=label, known={}
        )
    }
    return {
        "launcherPath": _reviewed_path_expression(
            assignments["LAUNCHER_PATH"], label=label, known=known
        ),
        "managerPath": _reviewed_path_expression(
            assignments["RETENTION_MANAGER_PATH"], label=label, known=known
        ),
        "managerSha256": _reviewed_literal(
            assignments, "APPROVED_RETENTION_MANAGER_SHA256", str, label=label
        ),
        "runtimeDirectory": known["RUNTIME_DIR"],
        "updaterPath": _reviewed_path_expression(
            assignments["RELEASE_UPDATER_PATH"], label=label, known=known
        ),
        "updaterSha256": _reviewed_literal(
            assignments, "APPROVED_RELEASE_UPDATER_SHA256", str, label=label
        ),
    }


def validate_retention_installer_source_payloads(
    payloads: dict[str, bytes],
) -> dict[str, str]:
    if set(payloads) != RETENTION_INSTALLER_SOURCE_KEYS:
        fail("retention installer captured source inventory differs")
    if any(not isinstance(value, bytes) or not value for value in payloads.values()):
        fail("retention installer captured source bytes are empty or malformed")
    launcher = payloads[RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY]
    launcher_sha = hashlib.sha256(launcher).hexdigest()
    if launcher_sha != REVIEWED_RETENTION_INSTALLER_LAUNCHER_SHA256:
        fail("retention installer launcher differs from the frozen reviewed digest")
    contract = _retention_installer_launcher_contract(launcher)
    runtime = _retention_runtime_launcher_contract(
        payloads[RETENTION_INSTALLER_RUNTIME_LAUNCHER_SOURCE_KEY]
    )
    expected_relative = tuple(
        RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.values()
    )
    installer_sha = hashlib.sha256(
        payloads[RETENTION_INSTALLER_INSTALLER_SOURCE_KEY]
    ).hexdigest()
    updater_sha = hashlib.sha256(
        payloads[RETENTION_INSTALLER_UPDATER_SOURCE_KEY]
    ).hexdigest()
    guard_sha = hashlib.sha256(
        payloads[RETENTION_INSTALLER_GUARD_SOURCE_KEY]
    ).hexdigest()
    manager_sha = hashlib.sha256(
        payloads[RETENTION_INSTALLER_MANAGER_SOURCE_KEY]
    ).hexdigest()
    updater_assignments = _reviewed_python_assignments(
        payloads[RETENTION_INSTALLER_UPDATER_SOURCE_KEY],
        label="retention bundle release updater",
        required={"_GUARD_SHA256"},
    )
    updater_guard_sha = _reviewed_literal(
        updater_assignments,
        "_GUARD_SHA256",
        str,
        label="retention bundle release updater",
    )
    expected_installer = RETENTION_INSTALLER_BUNDLE_ROOT_POSIX + "/" + expected_relative[0]
    if (
        contract["installedLauncher"] != RETENTION_INSTALLER_LAUNCHER_TARGET_POSIX
        or contract["installedInstaller"] != expected_installer
        or contract["sourceBundleRoot"] != RETENTION_INSTALLER_BUNDLE_ROOT_POSIX
        or contract["sourceBundleRelativeFiles"] != expected_relative
        or len(set(expected_relative)) != 10
        or contract["reviewedInstallerSha256"] != installer_sha
        or contract["installerMode"] != 0o400
        or contract["sourceDirectoryMode"] != 0o500
        or contract["launcherMode"] != 0o500
        or runtime["runtimeDirectory"] != "/opt/uten-imp/updater"
        or runtime["launcherPath"] != "/opt/uten-imp/updater/retention_launcher.py"
        or runtime["updaterPath"] != "/opt/uten-imp/updater/release_updater.py"
        or runtime["managerPath"] != "/opt/uten-imp/updater/retention_manager.py"
        or runtime["updaterSha256"] != updater_sha
        or runtime["managerSha256"] != manager_sha
        or updater_guard_sha != guard_sha
    ):
        fail("retention installer launcher/source-bundle contract differs")
    source_inventory = {
        RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY[key]: hashlib.sha256(
            payloads[key]
        ).hexdigest()
        for key in RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY
    }
    return {
        "installerSha256": installer_sha,
        "launcherSha256": launcher_sha,
        "runtimeLauncherSha256": hashlib.sha256(
            payloads[RETENTION_INSTALLER_RUNTIME_LAUNCHER_SOURCE_KEY]
        ).hexdigest(),
        "sourceBundleInventorySha256": hashlib.sha256(
            canonical(source_inventory)
        ).hexdigest(),
    }


def validate_trusted_installer_source_payloads(
    payloads: dict[str, bytes],
) -> dict[str, dict[str, str]]:
    if set(payloads) != TRUSTED_INSTALLER_SOURCE_KEYS:
        fail("trusted installer captured source inventory differs")
    return {
        "backup": validate_backup_installer_source_payloads(
            {key: payloads[key] for key in BACKUP_INSTALLER_SOURCE_KEYS}
        ),
        "monitoring": validate_monitoring_installer_source_payloads(
            {key: payloads[key] for key in MONITORING_INSTALLER_SOURCE_KEYS}
        ),
        "retention": validate_retention_installer_source_payloads(
            {key: payloads[key] for key in RETENTION_INSTALLER_SOURCE_KEYS}
        ),
    }


def capture_backup_installer_snapshot_payloads(
    source_snapshot: dict[str, Path], reviewed: dict[str, Any]
) -> dict[str, bytes]:
    """Read every durable source snapshot once through a stable root-only fd."""

    payloads: dict[str, bytes] = {}
    for key in sorted(BACKUP_INSTALLER_SOURCE_KEYS):
        if key not in source_snapshot:
            fail(f"backup installer source snapshot is missing: {key}")
        payload = stable_root_bytes(source_snapshot[key], mode=0o600)
        if hashlib.sha256(payload).hexdigest() != reviewed["sourceSha256"].get(key):
            fail(f"backup installer source snapshot digest differs: {key}")
        payloads[key] = payload
    validate_backup_installer_source_payloads(payloads)
    return payloads


def capture_trusted_installer_snapshot_payloads(
    source_snapshot: dict[str, Path], reviewed: dict[str, Any]
) -> dict[str, bytes]:
    """Capture every trusted installer source from the durable transaction."""

    payloads: dict[str, bytes] = {}
    for key in sorted(TRUSTED_INSTALLER_SOURCE_KEYS):
        if key not in source_snapshot:
            fail(f"trusted installer source snapshot is missing: {key}")
        payload = stable_root_bytes(source_snapshot[key], mode=0o600)
        if hashlib.sha256(payload).hexdigest() != reviewed["sourceSha256"].get(key):
            fail(f"trusted installer source snapshot digest differs: {key}")
        payloads[key] = payload
    validate_trusted_installer_source_payloads(payloads)
    return payloads


def _backup_installer_expected_directories() -> frozenset[Path]:
    directories = {Path(".")}
    for relative in BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.values():
        parent = Path(relative).parent
        while parent != Path("."):
            directories.add(parent)
            parent = parent.parent
    return frozenset(directories)


def _validate_backup_installer_parent_chain(path: Path) -> None:
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise PreparationError(
                "backup installer fixed target parent cannot be inspected"
            ) from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail("backup installer fixed target parent chain is not root controlled")
        if current == current.parent:
            return
        current = current.parent


def backup_installer_bundle_state(*, require_complete: bool) -> dict[str, Any]:
    """Observe the fixed live bundle without following or tolerating extra objects."""

    _validate_backup_installer_parent_chain(BACKUP_INSTALLER_BUNDLE_ROOT)
    expected_directories = _backup_installer_expected_directories()
    expected_files = {
        Path(relative): key
        for key, relative in BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
    }
    empty_files = {key: None for key in BACKUP_INSTALLER_BUNDLE_SOURCE_KEYS}
    if not os.path.lexists(BACKUP_INSTALLER_BUNDLE_ROOT):
        if require_complete:
            fail("backup installer source bundle is missing")
        return {"fileSha256": empty_files, "inventorySha256": None}

    seen_directories: set[Path] = set()
    file_hashes = dict(empty_files)
    pending = [(BACKUP_INSTALLER_BUNDLE_ROOT, Path("."))]
    while pending:
        directory, relative_directory = pending.pop()
        try:
            details = directory.lstat()
        except OSError as exc:
            raise PreparationError(
                "backup installer source-bundle directory cannot be inspected"
            ) from exc
        if (
            relative_directory not in expected_directories
            or not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != 0o500
        ):
            fail("backup installer source-bundle directory metadata differs")
        seen_directories.add(relative_directory)
        try:
            entries = list(os.scandir(directory))
        except OSError as exc:
            raise PreparationError(
                "backup installer source-bundle directory cannot be enumerated"
            ) from exc
        for entry in entries:
            relative = (
                Path(entry.name)
                if relative_directory == Path(".")
                else relative_directory / entry.name
            )
            try:
                child = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise PreparationError(
                    "backup installer source-bundle object cannot be inspected"
                ) from exc
            if stat.S_ISDIR(child.st_mode):
                if relative not in expected_directories:
                    fail("backup installer source bundle has an unexpected directory")
                pending.append((Path(entry.path), relative))
                continue
            if not stat.S_ISREG(child.st_mode) or relative not in expected_files:
                fail("backup installer source bundle has a missing or unexpected object")
            key = expected_files[relative]
            file_hashes[key] = stable_root_digest(Path(entry.path), mode=0o400)

    present_files = {
        Path(BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY[key])
        for key, digest in file_hashes.items()
        if digest is not None
    }
    if require_complete and (
        seen_directories != set(expected_directories)
        or present_files != set(expected_files)
    ):
        fail("backup installer source bundle has a missing or unexpected object")
    inventory = {
        "directories": sorted(path.as_posix() for path in seen_directories),
        "fileSha256": {
            BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY[key]: file_hashes[key]
            for key in sorted(BACKUP_INSTALLER_BUNDLE_SOURCE_KEYS)
        },
    }
    return {
        "fileSha256": file_hashes,
        "inventorySha256": hashlib.sha256(canonical(inventory)).hexdigest(),
    }


def backup_installer_launcher_preimage_digest() -> str | None:
    _validate_backup_installer_parent_chain(BACKUP_INSTALLER_LAUNCHER_TARGET)
    if not os.path.lexists(BACKUP_INSTALLER_LAUNCHER_TARGET):
        return None
    return stable_root_digest(BACKUP_INSTALLER_LAUNCHER_TARGET, mode=0o500)


def validate_backup_installer_target_preimage(
    reviewed: dict[str, Any],
    payloads: dict[str, bytes],
    *,
    resume_authorized: bool,
) -> None:
    """Reject unreviewed live bytes before any host-runtime target mutation."""

    validate_backup_installer_source_payloads(payloads)
    expected = reviewed["targetPreimageSha256"]
    state = backup_installer_bundle_state(
        require_complete=(
            not resume_authorized
            and os.path.lexists(BACKUP_INSTALLER_BUNDLE_ROOT)
        )
    )
    launcher_live = backup_installer_launcher_preimage_digest()
    if not resume_authorized:
        if (
            launcher_live != expected[BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY]
            or state["inventorySha256"]
            != expected[BACKUP_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY]
            or any(
                state["fileSha256"][key] != expected[key]
                for key in BACKUP_INSTALLER_BUNDLE_SOURCE_KEYS
            )
        ):
            fail("backup installer live target differs from reviewed preimage")
        return

    current = {
        BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY: launcher_live,
        **state["fileSha256"],
    }
    for key in BACKUP_INSTALLER_SOURCE_KEYS:
        observed = current[key]
        preimage = expected[key]
        desired = hashlib.sha256(payloads[key]).hexdigest()
        if observed is None:
            if preimage is not None:
                fail(f"backup installer resume lost an authorized preimage: {key}")
        elif observed not in {preimage, desired}:
            fail(f"backup installer resume found unknown live bytes: {key}")


def _trusted_bundle_expected_directories(
    relative_by_source_key: dict[str, str],
) -> frozenset[Path]:
    directories = {Path(".")}
    for relative in relative_by_source_key.values():
        parent = Path(relative).parent
        while parent != Path("."):
            directories.add(parent)
            parent = parent.parent
    return frozenset(directories)


def _validate_trusted_bundle_parent_chain(path: Path, label: str) -> None:
    current = path.parent
    while True:
        try:
            details = current.lstat()
        except OSError as exc:
            raise PreparationError(
                f"{label} fixed target parent cannot be inspected"
            ) from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail(f"{label} fixed target parent chain is not root controlled")
        if current == current.parent:
            return
        current = current.parent


def _trusted_bundle_state(
    *,
    label: str,
    bundle_root: Path,
    relative_by_source_key: dict[str, str],
    bundle_source_keys: frozenset[str],
    require_complete: bool,
) -> dict[str, Any]:
    _validate_trusted_bundle_parent_chain(bundle_root, label)
    expected_directories = _trusted_bundle_expected_directories(
        relative_by_source_key
    )
    expected_files = {
        Path(relative): key for key, relative in relative_by_source_key.items()
    }
    empty_files = {key: None for key in bundle_source_keys}
    if not os.path.lexists(bundle_root):
        if require_complete:
            fail(f"{label} source bundle is missing")
        return {"fileSha256": empty_files, "inventorySha256": None}

    seen_directories: set[Path] = set()
    file_hashes = dict(empty_files)
    pending = [(bundle_root, Path("."))]
    while pending:
        directory, relative_directory = pending.pop()
        try:
            details = directory.lstat()
        except OSError as exc:
            raise PreparationError(
                f"{label} source-bundle directory cannot be inspected"
            ) from exc
        if (
            relative_directory not in expected_directories
            or not stat.S_ISDIR(details.st_mode)
            or stat.S_ISLNK(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != 0o500
        ):
            fail(f"{label} source-bundle directory metadata differs")
        seen_directories.add(relative_directory)
        try:
            entries = list(os.scandir(directory))
        except OSError as exc:
            raise PreparationError(
                f"{label} source-bundle directory cannot be enumerated"
            ) from exc
        for entry in entries:
            relative = (
                Path(entry.name)
                if relative_directory == Path(".")
                else relative_directory / entry.name
            )
            try:
                child = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise PreparationError(
                    f"{label} source-bundle object cannot be inspected"
                ) from exc
            if stat.S_ISDIR(child.st_mode):
                if relative not in expected_directories:
                    fail(f"{label} source bundle has an unexpected directory")
                pending.append((Path(entry.path), relative))
                continue
            if not stat.S_ISREG(child.st_mode) or relative not in expected_files:
                fail(f"{label} source bundle has a missing or unexpected object")
            key = expected_files[relative]
            file_hashes[key] = stable_root_digest(Path(entry.path), mode=0o400)

    present_files = {
        Path(relative_by_source_key[key])
        for key, digest in file_hashes.items()
        if digest is not None
    }
    if require_complete and (
        seen_directories != set(expected_directories)
        or present_files != set(expected_files)
    ):
        fail(f"{label} source bundle has a missing or unexpected object")
    inventory = {
        "directories": sorted(path.as_posix() for path in seen_directories),
        "fileSha256": {
            relative_by_source_key[key]: file_hashes[key]
            for key in sorted(bundle_source_keys)
        },
    }
    return {
        "fileSha256": file_hashes,
        "inventorySha256": hashlib.sha256(canonical(inventory)).hexdigest(),
    }


def _trusted_launcher_preimage_digest(target: Path, label: str) -> str | None:
    _validate_trusted_bundle_parent_chain(target, label)
    if not os.path.lexists(target):
        return None
    return stable_root_digest(target, mode=0o500)


def trusted_installer_target_preimages() -> dict[str, str | None]:
    """Observe all three exact inert installer trees for manifest production."""

    backup = backup_installer_bundle_state(
        require_complete=os.path.lexists(BACKUP_INSTALLER_BUNDLE_ROOT)
    )
    monitoring = _trusted_bundle_state(
        label="monitoring installer",
        bundle_root=MONITORING_INSTALLER_BUNDLE_ROOT,
        relative_by_source_key=MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
        bundle_source_keys=MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS,
        require_complete=os.path.lexists(MONITORING_INSTALLER_BUNDLE_ROOT),
    )
    retention = _trusted_bundle_state(
        label="retention installer",
        bundle_root=RETENTION_INSTALLER_BUNDLE_ROOT,
        relative_by_source_key=RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
        bundle_source_keys=RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS,
        require_complete=os.path.lexists(RETENTION_INSTALLER_BUNDLE_ROOT),
    )
    return {
        BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY: backup_installer_launcher_preimage_digest(),
        **backup["fileSha256"],
        BACKUP_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY: backup["inventorySha256"],
        MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY: _trusted_launcher_preimage_digest(
            MONITORING_INSTALLER_LAUNCHER_TARGET, "monitoring installer"
        ),
        **monitoring["fileSha256"],
        MONITORING_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY: monitoring[
            "inventorySha256"
        ],
        RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY: _trusted_launcher_preimage_digest(
            RETENTION_INSTALLER_LAUNCHER_TARGET, "retention installer"
        ),
        **retention["fileSha256"],
        RETENTION_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY: retention[
            "inventorySha256"
        ],
    }


def _validate_trusted_bundle_target_preimage(
    reviewed: dict[str, Any],
    payloads: dict[str, bytes],
    *,
    label: str,
    launcher_source_key: str,
    inventory_preimage_key: str,
    bundle_root: Path,
    launcher_target: Path,
    relative_by_source_key: dict[str, str],
    bundle_source_keys: frozenset[str],
    source_keys: frozenset[str],
    resume_authorized: bool,
) -> None:
    expected = reviewed["targetPreimageSha256"]
    state = _trusted_bundle_state(
        label=label,
        bundle_root=bundle_root,
        relative_by_source_key=relative_by_source_key,
        bundle_source_keys=bundle_source_keys,
        require_complete=(not resume_authorized and os.path.lexists(bundle_root)),
    )
    launcher_live = _trusted_launcher_preimage_digest(launcher_target, label)
    if not resume_authorized:
        if (
            launcher_live != expected[launcher_source_key]
            or state["inventorySha256"] != expected[inventory_preimage_key]
            or any(
                state["fileSha256"][key] != expected[key]
                for key in bundle_source_keys
            )
        ):
            fail(f"{label} live target differs from reviewed preimage")
        return
    current = {launcher_source_key: launcher_live, **state["fileSha256"]}
    for key in source_keys:
        observed = current[key]
        preimage = expected[key]
        desired = hashlib.sha256(payloads[key]).hexdigest()
        if observed is None:
            if preimage is not None:
                fail(f"{label} resume lost an authorized preimage: {key}")
        elif observed not in {preimage, desired}:
            fail(f"{label} resume found unknown live bytes: {key}")


def validate_trusted_installer_target_preimages(
    reviewed: dict[str, Any],
    payloads: dict[str, bytes],
    *,
    resume_authorized: bool,
) -> None:
    validate_trusted_installer_source_payloads(payloads)
    validate_backup_installer_target_preimage(
        reviewed,
        {key: payloads[key] for key in BACKUP_INSTALLER_SOURCE_KEYS},
        resume_authorized=resume_authorized,
    )
    _validate_trusted_bundle_target_preimage(
        reviewed,
        payloads,
        label="monitoring installer",
        launcher_source_key=MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY,
        inventory_preimage_key=MONITORING_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY,
        bundle_root=MONITORING_INSTALLER_BUNDLE_ROOT,
        launcher_target=MONITORING_INSTALLER_LAUNCHER_TARGET,
        relative_by_source_key=MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
        bundle_source_keys=MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS,
        source_keys=MONITORING_INSTALLER_SOURCE_KEYS,
        resume_authorized=resume_authorized,
    )
    _validate_trusted_bundle_target_preimage(
        reviewed,
        payloads,
        label="retention installer",
        launcher_source_key=RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY,
        inventory_preimage_key=RETENTION_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY,
        bundle_root=RETENTION_INSTALLER_BUNDLE_ROOT,
        launcher_target=RETENTION_INSTALLER_LAUNCHER_TARGET,
        relative_by_source_key=RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
        bundle_source_keys=RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS,
        source_keys=RETENTION_INSTALLER_SOURCE_KEYS,
        resume_authorized=resume_authorized,
    )


def parse_utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not UTC_RE.fullmatch(value):
        fail(f"{label} is malformed")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise PreparationError(f"{label} is malformed") from exc
    return parsed


def require_fresh_review(reviewed: dict[str, Any]) -> None:
    created = parse_utc(reviewed.get("createdAtUtc"), "review creation time")
    expires = parse_utc(reviewed.get("expiresAtUtc"), "review expiry time")
    now = datetime.now(timezone.utc)
    if not created <= now <= expires or expires <= created or expires - created > timedelta(days=7):
        fail("reviewed host source authorization is expired or has unsafe chronology")


def root_file(path: Path, *, mode: int | None = None) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise PreparationError(f"required root-controlled file is missing: {path}") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or path.is_symlink()
        or details.st_uid != 0
        or details.st_nlink != 1
        or details.st_mode & 0o022
        or (mode is not None and stat.S_IMODE(details.st_mode) != mode)
    ):
        fail(f"root-controlled source/target is unsafe: {path}")
    return details


def root_directory(path: Path) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise PreparationError(f"required root-controlled directory is missing: {path}") from exc
    if not stat.S_ISDIR(details.st_mode) or path.is_symlink() or details.st_uid != 0 or details.st_mode & 0o022:
        fail(f"root-controlled directory is unsafe: {path}")
    return details


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextlib.contextmanager
def operation_lock() -> Any:
    """Hold the exact cross-privilege stage/activate lock for all live writes."""

    _uid, updater_gid = _updater_identity()
    _exact_owned_path(
        OPERATION_LOCK,
        uid=0,
        gid=updater_gid,
        mode=0o660,
        directory=False,
    )
    flags = os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(OPERATION_LOCK, flags)
    except OSError as exc:
        raise PreparationError("common release operation lock cannot be opened") from exc
    try:
        details = os.fstat(descriptor)
        live = OPERATION_LOCK.lstat()
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != updater_gid
            or stat.S_IMODE(details.st_mode) != 0o660
            or details.st_nlink != 1
            or (details.st_dev, details.st_ino) != (live.st_dev, live.st_ino)
        ):
            fail("common release operation lock metadata changed")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PreparationError("another stage or activation holds the release lock") from exc
        yield
    finally:
        os.close(descriptor)


def ensure_root_runtime_directories(transaction_dir: Path) -> dict[str, Any]:
    created: list[str] = []
    for path in (DB_EVIDENCE_ROOT, ONBOARDING_ARCHIVE_ROOT):
        if os.path.lexists(path):
            details = root_directory(path)
            if (
                details.st_uid != 0
                or details.st_gid != 0
                or stat.S_IMODE(details.st_mode) != 0o700
                or any(path.iterdir())
            ):
                fail(f"internal-test evidence directory preimage is not empty root:root 0700: {path}")
        else:
            root_directory(path.parent)
            path.mkdir(mode=0o700)
            os.chown(path, 0, 0)
            os.chmod(path, 0o700)
            fsync_directory(path.parent)
            created.append(str(path))
    value = {
        "createdDirectories": created,
        "directories": [str(DB_EVIDENCE_ROOT), str(ONBOARDING_ARCHIVE_ROOT)],
        "kind": "uten-imp-internal-test-runtime-evidence-layout",
        "schemaVersion": 1,
        "status": "COMMITTED_EMPTY_ENTRY_CLOSED",
        "transactionId": transaction_dir.name,
    }
    path = transaction_dir / "runtime-evidence-layout.json"
    if path.exists():
        prior = strict_json_document(path.read_bytes(), "runtime evidence layout receipt")
        comparable = dict(value)
        comparable["createdDirectories"] = prior.get("createdDirectories")
        if prior != comparable:
            fail("runtime evidence directory receipt differs")
        value = prior
    else:
        atomic(path, canonical(value), 0o600)
    return {"path": str(path), "sha256": sha256_file(path), **value}


def atomic(path: Path, payload: bytes, mode: int, *, replace: bool = False) -> None:
    root_directory(path.parent)
    incoming = path.parent / f".{path.name}.incoming-{os.getpid()}"
    if os.path.lexists(incoming):
        fail(f"preparation temporary already exists: {incoming}")
    descriptor = os.open(incoming, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                fail(f"preparation temporary write made no progress: {incoming}")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chown(incoming, 0, 0)
    os.chmod(incoming, mode)
    if os.path.lexists(path) and not replace:
        incoming.unlink()
        fail(f"refusing to overwrite existing target without preimage authority: {path}")
    os.replace(incoming, path)
    fsync_directory(path.parent)


def run(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[bytes]:
    completed = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env={
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
        },
        timeout=90,
        check=False,
    )
    if completed.returncode != 0:
        fail(f"fixed preparation command failed: {command[0]}")
    return completed


def require_employee_ports_closed() -> None:
    """Reject unmanaged TCP and UDP/QUIC entry, not only inactive units."""

    protected = {80, 443, 8080, 8081}
    observations = (
        ("TCP", ["/usr/bin/ss", "-H", "-ltnp"]),
        ("UDP", ["/usr/bin/ss", "-H", "-lunp"]),
    )
    for protocol, command in observations:
        raw = run(command, capture=True).stdout
        if len(raw) > 1024 * 1024:
            fail(f"live {protocol} listener observation is unexpectedly large")
        try:
            lines = raw.decode("ascii", errors="strict").splitlines()
        except UnicodeDecodeError as exc:
            raise PreparationError(
                f"live {protocol} listener observation is not canonical ASCII"
            ) from exc
        for line in lines:
            columns = line.split(None, 5)
            expected_state = "LISTEN" if protocol == "TCP" else "UNCONN"
            if len(columns) < 5 or columns[0] != expected_state:
                fail(f"live {protocol} listener observation is malformed")
            # ss TCP rows: LISTEN recv-q send-q local peer [process]
            # ss UDP rows: UNCONN recv-q send-q local peer [process]
            local_index = 3
            try:
                port_text = columns[local_index].rsplit(":", 1)[1]
                if not port_text.isdigit() or port_text != str(int(port_text)):
                    raise ValueError
                port = int(port_text)
            except (IndexError, ValueError) as exc:
                raise PreparationError(
                    f"live {protocol} listener endpoint is malformed"
                ) from exc
            if port in protected:
                fail(f"employee-facing {protocol} port is still listening: {port}")


def entry_closed() -> None:
    for unit in ENTRY_UNITS:
        state = run(["/usr/bin/systemctl", "show", unit, "--property=ActiveState", "--value"], capture=True).stdout.decode().strip()
        enabled = run(["/usr/bin/systemctl", "show", unit, "--property=UnitFileState", "--value"], capture=True).stdout.decode().strip()
        if state not in {"inactive", "failed"} or enabled not in {"disabled", "static", "masked", "indirect"}:
            fail(f"host preparation requires entry disabled and inactive: {unit}")
    for unit in ("postgresql.service", "postgresql@16-main.service"):
        state = run(
            ["/usr/bin/systemctl", "show", unit, "--property=ActiveState", "--value"],
            capture=True,
        ).stdout.decode().strip()
        enabled = run(
            ["/usr/bin/systemctl", "show", unit, "--property=UnitFileState", "--value"],
            capture=True,
        ).stdout.decode().strip()
        if state not in {"inactive", "failed"} or enabled not in {
            "disabled", "static", "masked", "indirect"
        }:
            fail(f"host preparation requires PostgreSQL stopped before configuration: {unit}")
    if os.path.lexists(Path("/opt/uten-imp/current")):
        fail("host preparation cannot run after current is published")
    require_employee_ports_closed()


def close_legacy_backup_units(transaction_dir: Path) -> dict[str, Any]:
    before_path = transaction_dir / "legacy-backup-units-before.json"
    if before_path.exists():
        before = strict_json_document(before_path.read_bytes(), "backup unit preimage")
    else:
        before = {
            unit: {
                "activeState": run(
                    ["/usr/bin/systemctl", "show", unit, "--property=ActiveState", "--value"],
                    capture=True,
                ).stdout.decode("utf-8", errors="strict").strip(),
                "unitFileState": run(
                    ["/usr/bin/systemctl", "show", unit, "--property=UnitFileState", "--value"],
                    capture=True,
                ).stdout.decode("utf-8", errors="strict").strip(),
            }
            for unit in LEGACY_BACKUP_UNITS
        }
        atomic(before_path, canonical(before), 0o600)
    # The storage-only terminal already disabled these units.  Never kill a
    # drifted/running backup process here: that requires separate investigation.
    for unit in LEGACY_BACKUP_UNITS:
        active = run(
            ["/usr/bin/systemctl", "show", unit, "--property=ActiveState", "--value"],
            capture=True,
        ).stdout.decode().strip()
        enabled = run(
            ["/usr/bin/systemctl", "show", unit, "--property=UnitFileState", "--value"],
            capture=True,
        ).stdout.decode().strip()
        if active not in {"inactive", "failed"} or enabled not in {
            "disabled",
            "static",
            "indirect",
            "masked",
        }:
            fail(f"legacy backup unit remains usable: {unit}")
    value = {
        "backupEnabled": False,
        "beforeSha256": sha256_file(before_path),
        "kind": "uten-imp-internal-test-legacy-backup-containment",
        "schemaVersion": 1,
        "status": "OLD_BACKUP_JOBS_DISABLED_ENTRY_CLOSED",
        "transactionId": transaction_dir.name,
        "units": list(LEGACY_BACKUP_UNITS),
    }
    path = transaction_dir / "legacy-backup-units-closed.json"
    if path.exists():
        if path.read_bytes() != canonical(value):
            fail("legacy backup containment receipt differs")
    else:
        atomic(path, canonical(value), 0o600)
    return {"path": str(path), "sha256": sha256_file(path)}


def nvme_storage_terminal() -> dict[str, Any]:
    root_directory(NVME_EVIDENCE)
    if os.path.lexists(NVME_ACTIVE_POINTER):
        fail("NVMe commissioning active pointer still requires late finalization")
    authority = strict_json_document(
        STORAGE_AUTHORITY.read_bytes(), "NVMe storage authority"
    )
    if authority.get("schemaVersion") != 3:
        fail("host preparation requires the v3 NVMe storage authority")
    candidates: list[tuple[Path, Path]] = []
    for complete in NVME_EVIDENCE.glob("nvme-*/complete.json"):
        late = complete.parent / "late-committed-finalization.json"
        if not late.exists():
            continue
        complete_value = strict_json_document(
            complete.read_bytes(), "NVMe storage terminal"
        )
        late_value = strict_json_document(
            late.read_bytes(), "NVMe late-finalization terminal"
        )
        if (
            complete_value.get("status") == "COMMITTED_STORAGE_ONLY"
            and late_value.get("status") == "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED"
            and complete_value.get("transactionId") == complete.parent.name
            and late_value.get("transactionId") == complete.parent.name
            and complete_value.get("authoritySha256") == sha256_file(STORAGE_AUTHORITY)
            and late_value.get("authoritySha256") == sha256_file(STORAGE_AUTHORITY)
            and complete_value.get("protectedUnitsDisabledInactive")
            == late_value.get("protectedUnitsDisabledInactive")
        ):
            root_file(complete, mode=0o600)
            root_file(late, mode=0o600)
            candidates.append((complete, late))
    if len(candidates) != 1:
        fail("exactly one terminal live-verified NVMe transaction is required")
    complete, late = candidates[0]
    return {
        "completePath": str(complete),
        "completeSha256": sha256_file(complete),
        "lateFinalizationPath": str(late),
        "lateFinalizationSha256": sha256_file(late),
        "storageAuthoritySha256": sha256_file(STORAGE_AUTHORITY),
        "transactionId": complete.parent.name,
    }


@contextlib.contextmanager
def preparation_lock() -> Any:
    root_directory(LOCK_FILE.parent)
    try:
        descriptor = os.open(
            LOCK_FILE,
            os.O_RDWR | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as exc:
        raise PreparationError(
            "pre-installed host preparation lock cannot be opened safely"
        ) from exc
    try:
        details = os.fstat(descriptor)
        live = LOCK_FILE.lstat()
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != 0o600
            or details.st_nlink != 1
            or (details.st_dev, details.st_ino) != (live.st_dev, live.st_ino)
        ):
            fail("host preparation lock is unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PreparationError("another host preparation holds the fixed lock") from exc
        yield
    finally:
        os.close(descriptor)


def read_environment_file(path: Path) -> dict[str, str]:
    root_file(path)
    raw = path.read_bytes()
    if not 1 <= len(raw) <= 256 * 1024 or b"\0" in raw:
        fail("server environment size is outside the reviewed range")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise PreparationError("server environment is not UTF-8") from exc
    values: dict[str, str] = {}
    for line in lines:
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail("server environment contains a malformed row")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
            fail("server environment contains a duplicate or malformed key")
        values[key] = value
    return values


def validate_server_environment_path(
    path: Path, domain: str, cidr: str, expected_sha: str
) -> None:
    if not SHA256_RE.fullmatch(expected_sha) or sha256_file(path) != expected_sha:
        fail("server environment differs from reviewed bytes")
    values = read_environment_file(path)
    if (
        values.get("UTEN_PROFILE") != "internal-test"
        or values.get("UTEN_LOCAL_ALLOWED_CIDRS") != f"127.0.0.0/8,{cidr}"
        or values.get("UTEN_CORS_ORIGINS") != f"https://{domain}"
    ):
        fail("server environment does not match the internal Nginx boundary")


def validate_server_environment(domain: str, cidr: str, expected_sha: str) -> None:
    validate_server_environment_path(SERVER_ENV, domain, cidr, expected_sha)


def snapshot_server_environment(
    transaction_dir: Path, expected_sha: str, *, resume_authorized: bool
) -> Path:
    snapshot = transaction_dir / "server.env.snapshot"
    if os.path.lexists(snapshot):
        root_file(snapshot, mode=0o600)
        if sha256_file(snapshot) != expected_sha:
            fail("server environment transaction snapshot digest changed")
        return snapshot
    if resume_authorized:
        fail("server environment snapshot disappeared from a resumed transaction")
    pending = root_file(SERVER_ENV_PENDING, mode=0o600)
    if pending.st_gid != 0 or sha256_file(SERVER_ENV_PENDING) != expected_sha:
        fail("pending internal-test server environment differs from reviewed bytes")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    descriptor = os.open(SERVER_ENV_PENDING, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino, opened.st_size) != (
            pending.st_dev,
            pending.st_ino,
            pending.st_size,
        ):
            fail("pending server environment changed while snapshotting")
        payload = b""
        remaining = 256 * 1024 + 1
        chunks: list[bytes] = []
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(payload) != pending.st_size or hashlib.sha256(payload).hexdigest() != expected_sha:
        fail("pending server environment changed while snapshotting")
    atomic(snapshot, payload, 0o600)
    return snapshot


def install_internal_server_environment(
    *,
    transaction_dir: Path,
    snapshot: Path,
    validator: Path,
    expected_preimage_sha: str,
    expected_sha: str,
    domain: str,
    cidr: str,
    approval_reference: str,
    resume_authorized: bool,
) -> dict[str, Any]:
    if not SHA256_RE.fullmatch(expected_preimage_sha):
        fail("reviewed server environment preimage digest is malformed")
    validate_server_environment_path(snapshot, domain, cidr, expected_sha)
    run(["/bin/bash", "--noprofile", "--norc", str(validator), str(snapshot)])
    live = root_file(SERVER_ENV)
    live_sha = sha256_file(SERVER_ENV)
    try:
        application_gid = grp.getgrnam("uten-imp").gr_gid
    except KeyError as exc:
        raise PreparationError("application group is unavailable") from exc
    if live_sha == expected_sha:
        if not resume_authorized and expected_preimage_sha != expected_sha:
            fail("first internal environment bridge bypassed its reviewed preimage")
    elif live_sha == expected_preimage_sha:
        atomic(SERVER_ENV, snapshot.read_bytes(), 0o640, replace=True)
    else:
        fail("live server environment matches neither reviewed preimage nor target")
    # A crash after the atomic replace but before the metadata update must be
    # convergent.  Re-assert the exact live metadata even when target bytes are
    # already present; never treat matching bytes alone as a terminal bridge.
    os.chown(SERVER_ENV, 0, application_gid)
    os.chmod(SERVER_ENV, 0o640)
    descriptor = os.open(SERVER_ENV, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    fsync_directory(SERVER_ENV.parent)
    validate_server_environment(domain, cidr, expected_sha)
    receipt = {
        "approvalReference": approval_reference,
        "kind": "uten-imp-internal-test-server-environment-bridge",
        "newSha256": expected_sha,
        "oldSha256": expected_preimage_sha,
        "schemaVersion": 1,
        "status": "COMMITTED_INTERNAL_TEST_ENV_ENTRY_CLOSED",
        "transactionId": transaction_dir.name,
    }
    receipt_path = transaction_dir / "server-environment-bridge.json"
    if os.path.lexists(receipt_path):
        if strict_json_document(
            receipt_path.read_bytes(), "server environment bridge receipt"
        ) != receipt:
            fail("server environment bridge receipt differs")
    else:
        atomic(receipt_path, canonical(receipt), 0o600)
    return {"path": str(receipt_path), "sha256": sha256_file(receipt_path)}


def ensure_migrator_environment() -> None:
    """Materialize the fixed dedicated env from the root PostgreSQL secret."""

    try:
        migrator_gid = grp.getgrnam("uten-imp-migrate").gr_gid
        postgres_gid = grp.getgrnam("postgres").gr_gid
    except KeyError as exc:
        raise PreparationError("dedicated migrator/PostgreSQL group is missing") from exc
    secret_details = root_file(MIGRATOR_SECRET, mode=0o640)
    if secret_details.st_gid != postgres_gid:
        fail("migrator PostgreSQL secret group differs")
    try:
        password = MIGRATOR_SECRET.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as exc:
        raise PreparationError("migrator PostgreSQL secret is unreadable") from exc
    if password.endswith("\n"):
        password = password[:-1]
    if not re.fullmatch(r"[A-Za-z0-9]{20,512}", password):
        fail("migrator PostgreSQL secret is outside the reviewed format")
    if os.path.lexists(MIGRATOR_ENV_DIR):
        details = root_directory(MIGRATOR_ENV_DIR)
        if details.st_gid != migrator_gid or stat.S_IMODE(details.st_mode) != 0o750:
            fail("dedicated migrator environment directory metadata differs")
    else:
        os.mkdir(MIGRATOR_ENV_DIR, 0o750)
        os.chown(MIGRATOR_ENV_DIR, 0, migrator_gid)
        os.chmod(MIGRATOR_ENV_DIR, 0o750)
        fsync_directory(MIGRATOR_ENV_DIR.parent)
    payload = f"UTEN_MIGRATOR_DB_PASSWORD={password}\n".encode("ascii")
    password = ""
    if os.path.lexists(MIGRATOR_ENV):
        details = root_file(MIGRATOR_ENV, mode=0o640)
        if details.st_gid != migrator_gid or MIGRATOR_ENV.read_bytes() != payload:
            fail("dedicated migrator environment differs from its root secret")
    else:
        incoming = MIGRATOR_ENV_DIR / ".migrator.env.internal-preparation.incoming"
        if os.path.lexists(incoming):
            fail("dedicated migrator environment incoming path exists")
        descriptor = os.open(
            incoming,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
            0o640,
        )
        try:
            os.fchown(descriptor, 0, migrator_gid)
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    fail("dedicated migrator environment write made no progress")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(incoming, MIGRATOR_ENV)
        fsync_directory(MIGRATOR_ENV_DIR)
    payload = b""
    run([str(TARGETS["migratorEnvironmentValidatorSha256"]), str(MIGRATOR_ENV)])


def validate_tls_material(domain: str, cert: Path, key: Path) -> None:
    for path in (cert, key):
        try:
            if path.parent.resolve(strict=True) != TLS_ROOT.resolve(strict=True):
                fail("TLS material must be a direct child of the fixed private directory")
        except OSError as exc:
            raise PreparationError("TLS directory cannot be resolved") from exc
        if any(character.isspace() or ord(character) < 32 for character in str(path)) or re.search(
            r"[;{}]", str(path)
        ):
            fail("TLS path contains unsafe configuration characters")
    root_directory(TLS_ROOT)
    cert_details = root_file(cert, mode=0o644)
    key_details = root_file(key, mode=0o600)
    if cert_details.st_gid != 0 or key_details.st_gid != 0:
        fail("TLS certificate/key group ownership is unsafe")
    run(["/usr/bin/openssl", "x509", "-in", str(cert), "-noout", "-checkend", "86400"])
    san_output = run(
        [
            "/usr/bin/openssl",
            "x509",
            "-in",
            str(cert),
            "-noout",
            "-ext",
            "subjectAltName",
        ],
        capture=True,
    ).stdout
    try:
        san_text = san_output.decode("ascii", errors="strict")
    except UnicodeDecodeError as exc:
        raise PreparationError("TLS subjectAltName output is not canonical ASCII") from exc
    dns_sans = {
        value.rstrip(".").lower()
        for value in re.findall(r"(?:^|[,\s])DNS:([^,\s]+)", san_text)
    }
    if domain not in dns_sans:
        fail("TLS certificate lacks the exact reviewed DNS subjectAltName")
    root_directory(Path("/etc/ssl/certs"))
    run(
        [
            "/usr/bin/openssl",
            "verify",
            "-x509_strict",
            "-purpose",
            "sslserver",
            "-verify_hostname",
            domain,
            "-CApath",
            "/etc/ssl/certs",
            str(cert),
        ]
    )
    cert_key = run(
        ["/usr/bin/openssl", "x509", "-in", str(cert), "-pubkey", "-noout"],
        capture=True,
    ).stdout
    private_key = run(
        ["/usr/bin/openssl", "pkey", "-in", str(key), "-pubout"],
        capture=True,
    ).stdout
    if not cert_key or cert_key != private_key:
        fail("TLS certificate and private key do not match")


def validate_network_inputs(domain: str, cidr: str) -> None:
    if not DOMAIN_RE.fullmatch(domain) or any(character.isupper() for character in domain):
        fail("internal domain is not a canonical DNS name")
    try:
        network = ipaddress.ip_network(cidr, strict=True)
    except ValueError as exc:
        raise PreparationError("office CIDR is not canonical") from exc
    private_parents = tuple(
        ipaddress.ip_network(value)
        for value in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    )
    allowed = network.version == 4 and any(
        network.subnet_of(parent) and network.prefixlen > parent.prefixlen
        for parent in private_parents
    )
    if not allowed:
        fail("office CIDR is outside the narrow private boundary")


def validate_inputs(domain: str, cidr: str, cert: Path, key: Path) -> None:
    validate_network_inputs(domain, cidr)
    validate_tls_material(domain, cert, key)


def rendered_nginx_payload(domain: str, cidr: str, cert: Path, key: Path, template: bytes) -> bytes:
    try:
        rendered = template.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PreparationError("reviewed Nginx template is not UTF-8") from exc
    for placeholder, replacement in {
        "__INTERNAL_DOMAIN__": domain,
        "__EXACT_OFFICE_CIDR__": cidr,
        "__INTERNAL_TLS_CERT_PATH__": str(cert),
        "__INTERNAL_TLS_KEY_PATH__": str(key),
    }.items():
        rendered = rendered.replace(placeholder, replacement)
    if re.search(r"__[A-Z0-9_]+__", rendered):
        fail("reviewed Nginx template still contains a placeholder")
    return rendered.encode("utf-8")


def prospective_nginx_expanded(
    domain: str, cidr: str, cert: Path, key: Path, template: bytes
) -> bytes:
    """Compile the candidate against the live base graph without touching /etc."""

    main_path = Path("/etc/nginx/nginx.conf")
    main = stable_root_bytes(main_path, mode=0o644, maximum_bytes=1024 * 1024)
    if len(main) > 1024 * 1024 or b"\0" in main:
        fail("base Nginx configuration is outside the reviewed range")
    try:
        main_text = main.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PreparationError("base Nginx configuration is not UTF-8") from exc
    conf_pattern = re.compile(
        r"(?m)^(?P<indent>[ \t]*)include[ \t]+/etc/nginx/conf\.d/\*\.conf[ \t]*;[ \t]*$"
    )
    sites_pattern = re.compile(
        r"(?m)^(?P<indent>[ \t]*)include[ \t]+/etc/nginx/sites-enabled/\*[ \t]*;[ \t]*$"
    )
    if len(conf_pattern.findall(main_text)) != 1 or len(sites_pattern.findall(main_text)) != 1:
        fail("base Nginx include graph is not the canonical dedicated-host shape")
    payload = rendered_nginx_payload(domain, cidr, cert, key, template)
    with tempfile.TemporaryDirectory(prefix="uten-imp-nginx-preview-", dir="/run") as temporary:
        preview = Path(temporary)
        os.chown(preview, 0, 0)
        os.chmod(preview, 0o700)
        conf_dir = preview / "conf.d"
        sites_dir = preview / "sites-enabled"
        conf_dir.mkdir(mode=0o700)
        sites_dir.mkdir(mode=0o700)
        canonical_paths: dict[bytes, bytes] = {}

        def validate_live_includes(
            source_directory: Path,
            *,
            conf_only: bool,
        ) -> None:
            """Reject every include not owned by this exact handoff transaction."""

            root_directory(source_directory)
            for source in sorted(source_directory.iterdir(), key=lambda item: item.name):
                if source.name.startswith(".") or (conf_only and not source.name.endswith(".conf")):
                    continue
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", source.name):
                    fail("enabled Nginx include name is outside the reviewed character set")
                if source in {NGINX_LINK, LEGACY_NGINX_TARGET}:
                    # The canonical link is replaced by the candidate.  The one
                    # legacy Phase-4 include is separately digest-bound and moved
                    # to the root-only archive by this same transaction.
                    continue
                # This is a dedicated ERP endpoint.  A second enabled include can
                # add an implicit port-80 server or alter the http scope, so reject
                # it before publishing a plan, preimage, or mutation marker.
                fail(f"unreviewed Nginx include is enabled before preparation: {source}")

        validate_live_includes(Path("/etc/nginx/conf.d"), conf_only=True)
        validate_live_includes(Path("/etc/nginx/sites-enabled"), conf_only=False)
        candidate = sites_dir / NGINX_LINK.name
        candidate.write_bytes(payload)
        os.chown(candidate, 0, 0)
        os.chmod(candidate, 0o600)
        canonical_paths[str(candidate).encode()] = str(NGINX_LINK).encode()
        preview_main = preview / "nginx.conf"
        rewritten = conf_pattern.sub(
            lambda match: f"{match.group('indent')}include {conf_dir}/*.conf;",
            main_text,
        )
        rewritten = sites_pattern.sub(
            lambda match: f"{match.group('indent')}include {sites_dir}/*;",
            rewritten,
        )
        preview_main.write_text(rewritten, encoding="utf-8", newline="")
        os.chown(preview_main, 0, 0)
        os.chmod(preview_main, 0o600)
        expanded = run(
            ["/usr/sbin/nginx", "-T", "-p", "/", "-c", str(preview_main)],
            capture=True,
        ).stdout
        replacements = {
            str(preview_main).encode(): b"/etc/nginx/nginx.conf",
            f"{conf_dir}/*.conf".encode(): b"/etc/nginx/conf.d/*.conf",
            f"{sites_dir}/*".encode(): b"/etc/nginx/sites-enabled/*",
            **canonical_paths,
        }
        for transient, canonical_path in sorted(
            replacements.items(), key=lambda item: len(item[0]), reverse=True
        ):
            expanded = expanded.replace(transient, canonical_path)
        if str(preview).encode() in expanded or not expanded:
            fail("prospective Nginx graph retained a transient path")
        return expanded


def reviewed_nginx_preview_digest(
    domain: str, cidr: str, cert: Path, key: Path
) -> str:
    template = Path(NGINX_SOURCE).read_bytes()
    return hashlib.sha256(
        prospective_nginx_expanded(domain, cidr, cert, key, template)
    ).hexdigest()


def _write_systemd_preview_file(path: Path, payload: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    os.chown(path, 0, 0)
    os.chmod(path, mode)


def _systemd_preview_stub(unit: str) -> bytes:
    if unit.endswith(".target"):
        return b"[Unit]\nDescription=Uten IMP verification fixture target\nDefaultDependencies=no\n"
    if unit.endswith(".mount"):
        if unit != "data.mount":
            fail(f"prospective systemd graph contains an unsupported mount: {unit}")
        return (
            b"[Unit]\nDescription=Uten IMP verification fixture mount\n"
            b"DefaultDependencies=no\n[Mount]\nWhat=tmpfs\nWhere=/data\nType=tmpfs\n"
        )
    if unit.endswith(".service"):
        return (
            b"[Unit]\nDescription=Uten IMP verification fixture service\n"
            b"[Service]\nType=oneshot\nExecStart=/bin/true\nRemainAfterExit=yes\n"
        )
    if unit.endswith(".timer"):
        return (
            b"[Unit]\nDescription=Uten IMP verification fixture timer\n"
            b"[Timer]\nOnActiveSec=1h\n"
        )
    if unit.endswith(".socket"):
        return (
            b"[Unit]\nDescription=Uten IMP verification fixture socket\n"
            b"[Socket]\nListenStream=/run/uten-imp-systemd-preview.sock\n"
        )
    fail(f"prospective systemd graph contains an unsupported unit reference: {unit}")


def _systemd_unit_references(payload: bytes) -> set[str]:
    try:
        text = payload.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        fail("prospective systemd source is not strict UTF-8")
    references: set[str] = set()
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";", "[")):
            continue
        directive, separator, value = line.partition("=")
        if separator and directive in SYSTEMD_REFERENCE_DIRECTIVES:
            for token in value.split():
                candidate = token.removeprefix("-")
                if candidate.endswith(
                    (".automount", ".mount", ".path", ".service", ".slice", ".socket", ".target", ".timer")
                ):
                    references.add(candidate)
    return references


def prospective_systemd_verify(reviewed: dict[str, Any]) -> None:
    """Parse the exact reviewed units and drop-ins in an isolated target graph."""

    source_hashes = reviewed.get("sourceSha256")
    if not isinstance(source_hashes, dict):
        fail("reviewed systemd source inventory is malformed")
    with tempfile.TemporaryDirectory(
        prefix="uten-imp-systemd-preview-", dir="/run"
    ) as temporary:
        preview = Path(temporary)
        os.chown(preview, 0, 0)
        os.chmod(preview, 0o700)
        unit_root = preview / "etc/systemd/system"
        unit_root.mkdir(parents=True)
        candidate_payloads: dict[str, bytes] = {}
        unit_paths: list[Path] = []
        for key, unit in SYSTEMD_UNIT_SOURCE_KEYS.items():
            source = SOURCES[key]
            payload = stable_root_bytes(source, maximum_bytes=1024 * 1024)
            if hashlib.sha256(payload).hexdigest() != source_hashes.get(key):
                fail(f"prospective systemd source differs from review: {key}")
            destination = unit_root / unit
            _write_systemd_preview_file(destination, payload, 0o600)
            candidate_payloads[unit] = payload
            unit_paths.append(destination)
        for key, unit in SYSTEMD_DROPIN_SOURCE_KEYS.items():
            source = SOURCES[key]
            payload = stable_root_bytes(source, maximum_bytes=1024 * 1024)
            if hashlib.sha256(payload).hexdigest() != source_hashes.get(key):
                fail(f"prospective systemd source differs from review: {key}")
            destination = unit_root / f"{unit}.d" / TARGETS[key].name
            _write_systemd_preview_file(destination, payload, 0o600)
            candidate_payloads[f"{unit}.d/{TARGETS[key].name}"] = payload

        references = {
            "basic.target",
            "shutdown.target",
            "sysinit.target",
        }
        references.update(SYSTEMD_DROPIN_SOURCE_KEYS.values())
        for payload in candidate_payloads.values():
            references.update(_systemd_unit_references(payload))
        for unit in sorted(references.difference(SYSTEMD_UNIT_SOURCE_KEYS.values())):
            _write_systemd_preview_file(
                unit_root / unit, _systemd_preview_stub(unit), 0o600
            )

        executable_paths = {"/bin/true"}
        for payload in candidate_payloads.values():
            try:
                text = payload.decode("utf-8", errors="strict")
            except UnicodeDecodeError:
                fail("prospective systemd source is not strict UTF-8")
            executable_paths.update(SYSTEMD_EXECUTABLE_RE.findall(text))
        for executable in sorted(executable_paths):
            relative = executable.removeprefix("/")
            if not relative or ".." in Path(relative).parts:
                fail("prospective systemd executable path is unsafe")
            _write_systemd_preview_file(
                preview / relative, b"#!/bin/sh\nexit 0\n", 0o755
            )
        run(
            [
                "/usr/bin/systemd-analyze",
                f"--root={preview}",
                "verify",
                *[str(path) for path in unit_paths],
            ]
        )


def validate_loaded_systemd_contract() -> None:
    """Bind PID 1's effective fragments/drop-ins to the installed targets."""

    for key, unit in SYSTEMD_UNIT_SOURCE_KEYS.items():
        target = TARGETS[key]
        if (
            _systemd_value(unit, "LoadState") != "loaded"
            or _systemd_value(unit, "FragmentPath") != str(target)
            or _systemd_value(unit, "DropInPaths")
        ):
            fail(f"loaded systemd unit graph differs from the reviewed target: {unit}")
    for key, unit in SYSTEMD_DROPIN_SOURCE_KEYS.items():
        target = TARGETS[key]
        dropins = _systemd_value(unit, "DropInPaths").split()
        if dropins != [str(target)]:
            fail(f"loaded systemd drop-in graph differs from the reviewed target: {unit}")


def _updater_identity() -> tuple[int, int]:
    try:
        account = __import__("pwd").getpwnam("uten-imp-updater")
        group = grp.getgrnam("uten-imp-updater")
    except KeyError as exc:
        raise PreparationError("dedicated updater identity is missing") from exc
    if account.pw_gid != group.gr_gid:
        fail("dedicated updater primary group differs")
    if account.pw_shell not in {
        "/usr/sbin/nologin",
        "/sbin/nologin",
        "/bin/false",
    }:
        fail("dedicated updater account does not have a nologin shell")
    return account.pw_uid, group.gr_gid


def _exact_owned_path(
    path: Path, *, uid: int, gid: int, mode: int, directory: bool
) -> os.stat_result:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise PreparationError(f"required updater substrate path is missing: {path}") from exc
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not expected_type(details.st_mode)
        or path.is_symlink()
        or details.st_uid != uid
        or details.st_gid != gid
        or stat.S_IMODE(details.st_mode) != mode
        or (not directory and details.st_nlink != 1)
    ):
        fail(f"updater substrate metadata is unsafe: {path}")
    return details


def validate_common_updater_prerequisites() -> dict[str, Any]:
    """Prove the already commissioned, profile-neutral staging substrate.

    The internal preparer replaces reviewed executable/configuration bytes but
    deliberately does not build a network client virtualenv or invent a trust
    key.  Those Phase 4 assets must therefore exist with their original narrow
    ownership before the first host-policy mutation.
    """

    updater_uid, updater_gid = _updater_identity()
    root_directory(UPDATER_ROOT)
    for directory in (UPDATER_ROOT / "venv", UPDATER_ROOT / "venv/bin"):
        root_directory(directory)
    try:
        python_link = UPDATER_VENV_PYTHON.lstat()
        resolved_python = UPDATER_VENV_PYTHON.resolve(strict=True)
    except OSError as exc:
        raise PreparationError("updater virtualenv Python is unavailable") from exc
    if (
        not (stat.S_ISLNK(python_link.st_mode) or stat.S_ISREG(python_link.st_mode))
        or python_link.st_uid != 0
        or (stat.S_ISREG(python_link.st_mode) and python_link.st_mode & 0o022)
        or not re.fullmatch(r"/usr/bin/python3(?:\.[0-9]+)?", str(resolved_python))
        or not os.access(UPDATER_VENV_PYTHON, os.X_OK)
    ):
        fail("updater virtualenv Python escaped the fixed system interpreter")
    root_file(resolved_python)

    verifier_source = SOURCES["wheelhouseSupplyChainSha256"]
    requirements_lock = SOURCES["updaterRequirementsLockSha256"]
    root_file(verifier_source)
    root_file(requirements_lock)
    try:
        run(
            [
                "/usr/bin/python3",
                "-I",
                str(verifier_source),
                "verify-installed",
                "--lock",
                str(requirements_lock),
                "--venv",
                str(UPDATER_ROOT / "venv"),
            ]
        )
    except Exception as exc:
        raise PreparationError("updater virtualenv differs from its reviewed RECORD inventory") from exc

    venv_inventory: list[dict[str, Any]] = []
    for path in sorted((UPDATER_ROOT / "venv").rglob("*"), key=lambda item: item.as_posix()):
        details = path.lstat()
        relative = path.relative_to(UPDATER_ROOT / "venv").as_posix()
        if stat.S_ISLNK(details.st_mode):
            value = os.readlink(path).encode("utf-8")
            kind = "symlink"
        elif stat.S_ISREG(details.st_mode):
            value = path.read_bytes()
            kind = "file"
        elif stat.S_ISDIR(details.st_mode):
            value = b""
            kind = "directory"
        else:
            fail("updater virtualenv contains an unsafe file type")
        venv_inventory.append(
            {
                "gid": details.st_gid,
                "kind": kind,
                "mode": f"{stat.S_IMODE(details.st_mode):04o}",
                "path": relative,
                "sha256": hashlib.sha256(value).hexdigest(),
                "uid": details.st_uid,
            }
        )

    _exact_owned_path(
        UPDATER_ALLOWED_SIGNERS,
        uid=0,
        gid=updater_gid,
        mode=0o640,
        directory=False,
    )
    _exact_owned_path(
        STABLE_ALLOWED_SIGNERS,
        uid=0,
        gid=0,
        mode=0o640,
        directory=False,
    )
    updater_signers = UPDATER_ALLOWED_SIGNERS.read_bytes()
    stable_signers = STABLE_ALLOWED_SIGNERS.read_bytes()
    if (
        not 1 <= len(updater_signers) <= 64 * 1024
        or updater_signers != stable_signers
        or SSH_ALLOWED_SIGNER_RE.fullmatch(updater_signers) is None
    ):
        fail("updater and stable release trust roots are not one exact reviewed key")

    _exact_owned_path(
        UPDATER_OSS_ENV,
        uid=0,
        gid=updater_gid,
        mode=0o640,
        directory=False,
    )
    _exact_owned_path(
        UPDATER_STATE,
        uid=updater_uid,
        gid=updater_gid,
        mode=0o750,
        directory=True,
    )
    _exact_owned_path(
        OPERATION_LOCK,
        uid=0,
        gid=updater_gid,
        mode=0o660,
        directory=False,
    )
    return {
        "allowedSignersSha256": hashlib.sha256(updater_signers).hexdigest(),
        "ossEnvironmentSha256": sha256_file(UPDATER_OSS_ENV),
        "resolvedVenvPython": str(resolved_python),
        "updaterVenvInventorySha256": hashlib.sha256(
            canonical(venv_inventory)
        ).hexdigest(),
        "updaterGid": updater_gid,
        "updaterUid": updater_uid,
    }


def validate_reviewed_updater_prerequisites(
    reviewed: dict[str, Any], prerequisite: dict[str, Any]
) -> None:
    host = reviewed.get("hostParameters")
    if not isinstance(host, dict):
        fail("reviewed host parameters are malformed")
    if (
        prerequisite.get("allowedSignersSha256")
        != host.get("allowedSignersSha256")
        or prerequisite.get("updaterVenvInventorySha256")
        != host.get("updaterVenvInventorySha256")
    ):
        fail("live updater trust/venv differs from the reviewed host authority")


def _systemd_value(unit: str, property_name: str) -> str:
    return (
        run(
            [
                "/usr/bin/systemctl",
                "show",
                unit,
                f"--property={property_name}",
                "--value",
            ],
            capture=True,
        )
        .stdout.decode("utf-8", errors="strict")
        .strip()
    )


def validate_common_updater_substrate(
    transaction_dir: Path, prerequisite: dict[str, Any]
) -> dict[str, Any]:
    """Validate the installed downloader/activation substrate and persist proof."""

    current = validate_common_updater_prerequisites()
    if current != prerequisite:
        fail("updater trust, virtualenv, credential or coordination substrate drifted")
    expected_units = {
        UPDATER_SERVICE: str(TARGETS["updaterServiceUnitSha256"]),
        UPDATER_TIMER: str(TARGETS["updaterTimerUnitSha256"]),
    }
    for unit, fragment in expected_units.items():
        if (
            _systemd_value(unit, "LoadState") != "loaded"
            or _systemd_value(unit, "FragmentPath") != fragment
            or _systemd_value(unit, "DropInPaths")
            or _systemd_value(unit, "ActiveState") not in {"inactive", "failed"}
        ):
            fail(f"loaded updater unit escaped its reviewed fragment: {unit}")
    if (
        _systemd_value(UPDATER_SERVICE, "User") != "uten-imp-updater"
        or _systemd_value(UPDATER_SERVICE, "Group") != "uten-imp-updater"
        or _systemd_value(UPDATER_SERVICE, "SupplementaryGroups")
        or _systemd_value(UPDATER_SERVICE, "UnitFileState") != "static"
        or _systemd_value(UPDATER_TIMER, "UnitFileState") != "disabled"
    ):
        fail("loaded updater privilege or enablement contract differs")
    run(
        [
            "/usr/sbin/runuser",
            "-u",
            "uten-imp-updater",
            "--",
            "/usr/bin/python3",
            "-I",
            str(TARGETS["updaterEnvironmentValidatorSha256"]),
            str(UPDATER_OSS_ENV),
        ]
    )
    installed = {key: sha256_file(TARGETS[key]) for key in sorted(SOURCES)}
    value = {
        "allowedSignersSha256": current["allowedSignersSha256"],
        "installedInventorySha256": hashlib.sha256(canonical(installed)).hexdigest(),
        "kind": "uten-imp-internal-test-common-updater-substrate",
        "ossEnvironmentSha256": current["ossEnvironmentSha256"],
        "resolvedVenvPython": current["resolvedVenvPython"],
        "schemaVersion": 1,
        "status": "COMMITTED_ENTRY_CLOSED_STAGING_MANUAL_ONLY",
        "transactionId": transaction_dir.name,
        "updaterVenvInventorySha256": current["updaterVenvInventorySha256"],
    }
    path = transaction_dir / "common-updater-substrate.json"
    if path.exists():
        if path.read_bytes() != canonical(value):
            fail("common updater substrate receipt differs from the live installation")
    else:
        atomic(path, canonical(value), 0o600)
    return {"path": str(path), "sha256": sha256_file(path), **value}


def rendered_nginx(domain: str, cidr: str, cert: Path, key: Path) -> bytes:
    root_file(NGINX_SOURCE)
    text = NGINX_SOURCE.read_text(encoding="utf-8")
    replacements = {
        "__INTERNAL_DOMAIN__": domain,
        "__EXACT_OFFICE_CIDR__": cidr,
        "__INTERNAL_TLS_CERT_PATH__": str(cert),
        "__INTERNAL_TLS_KEY_PATH__": str(key),
    }
    for source, target in replacements.items():
        text = text.replace(source, target)
    if re.search(r"__[A-Z0-9_]+__", text):
        fail("rendered internal Nginx config still contains a placeholder")
    return text.encode("utf-8")


def unique_nginx_include() -> bytes:
    def normalized_listen_port(argument: str) -> int:
        endpoint = argument.strip().split()[0] if argument.strip() else ""
        if not endpoint or "$" in endpoint or endpoint.startswith("unix:"):
            fail("enabled Nginx include contains an ambiguous listener")
        if endpoint.isdigit():
            if endpoint != str(int(endpoint)):
                fail("enabled Nginx include contains a non-canonical listener")
            return int(endpoint)
        if endpoint in {"*", "0.0.0.0", "127.0.0.1", "localhost", "[::]", "[::1]"}:
            return 80
        match = re.fullmatch(r"(?:\[[0-9A-Fa-f:]+\]|[0-9A-Za-z.*_-]+):(\d+)", endpoint)
        if match is None or match.group(1) != str(int(match.group(1))):
            fail("enabled Nginx include contains a non-canonical listener")
        return int(match.group(1))

    root_file(NGINX_TARGET, mode=0o644)
    link_details = NGINX_LINK.lstat()
    if (
        not stat.S_ISLNK(link_details.st_mode)
        or link_details.st_uid != 0
        or link_details.st_gid != 0
        or NGINX_LINK.resolve(strict=True) != NGINX_TARGET
    ):
        fail("internal Nginx site is not enabled through its unique canonical link")
    enabled: list[Path] = []
    for directory in (Path("/etc/nginx/conf.d"), Path("/etc/nginx/sites-enabled")):
        if not directory.is_dir():
            continue
        root_directory(directory)
        for candidate in directory.iterdir():
            details = candidate.lstat()
            if (
                details.st_uid != 0
                or details.st_gid != 0
                or (not stat.S_ISREG(details.st_mode) and not stat.S_ISLNK(details.st_mode))
            ):
                fail(f"enabled Nginx directory contains an unsafe object: {candidate}")
            try:
                resolved = candidate.resolve(strict=True)
                root_file(resolved, mode=0o644)
                text = candidate.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                raise PreparationError(
                    f"enabled Nginx include cannot be read safely: {candidate}"
                ) from exc
            if resolved == NGINX_TARGET:
                enabled.append(resolved)
                continue
            # This machine is a dedicated internal ERP endpoint.  There is no
            # safe directive-only or unrelated-site exception here: an inline
            # ``server { ... }`` without listen implicitly binds port 80, while
            # http-scope directives can alter the canonical site's behavior.
            # The reviewed canonical symlink must therefore be the *only*
            # enabled conf.d/sites-enabled object.  Base nginx.conf and its
            # immutable system include graph are independently bound by the
            # reviewed expanded configuration digest below.
            fail(f"unreviewed Nginx include is enabled: {candidate}")
    if enabled != [NGINX_TARGET]:
        fail("another Uten Nginx include is enabled")
    expanded = run(["/usr/sbin/nginx", "-T"], capture=True).stdout
    if len(expanded) > 4 * 1024 * 1024:
        fail("expanded Nginx configuration exceeds the reviewed size")
    try:
        expanded_text = expanded.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise PreparationError("expanded Nginx configuration is not strict UTF-8") from exc
    def nginx_tokens(text: str) -> list[str]:
        """Tokenize directives/braces without trusting line boundaries.

        This intentionally implements only the lexical layer required for the
        reviewed graph.  It preserves quoted strings and escapes, removes
        comments only outside quotes, and emits ``;``, ``{`` and ``}`` as
        standalone tokens.  Malformed quote/escape state is rejected.
        """

        tokens: list[str] = []
        current: list[str] = []
        quote: str | None = None
        escaped = False
        index = 0
        while index < len(text):
            character = text[index]
            if escaped:
                current.append(character)
                escaped = False
            elif character == "\\":
                current.append(character)
                escaped = True
            elif quote is not None:
                current.append(character)
                if character == quote:
                    quote = None
            elif character in {"'", '"'}:
                current.append(character)
                quote = character
            elif character == "#":
                while index < len(text) and text[index] not in "\r\n":
                    index += 1
                if current and current[-1] not in {" ", "\t"}:
                    current.append(" ")
                continue
            elif character in ";{}":
                value = "".join(current).strip()
                if value:
                    tokens.append(value)
                tokens.append(character)
                current = []
            elif character.isspace():
                if current and current[-1] != " ":
                    current.append(" ")
            else:
                current.append(character)
            index += 1
        if quote is not None or escaped:
            fail("expanded Nginx configuration has unterminated lexical state")
        value = "".join(current).strip()
        if value:
            tokens.append(value)
        return tokens

    tokens = nginx_tokens(expanded_text)
    forwarding: list[tuple[str, str]] = []
    expanded_listens: list[int] = []
    expanded_server_blocks = 0
    depth = 0
    block_stack: list[str] = []
    pending_block: str | None = None
    for token in tokens:
        if token == "{":
            if pending_block is None:
                fail("expanded Nginx configuration contains an anonymous block")
            directive = pending_block.split(" ", 1)[0]
            block_stack.append(directive)
            if directive == "server":
                expanded_server_blocks += 1
            depth += 1
            pending_block = None
        elif token == "}":
            if pending_block is not None or depth == 0 or not block_stack:
                fail("expanded Nginx configuration block structure is malformed")
            depth -= 1
            block_stack.pop()
        elif token == ";":
            if pending_block is None:
                fail("expanded Nginx configuration contains an empty directive")
            parts = pending_block.split(" ", 1)
            name = parts[0]
            argument = parts[1] if len(parts) == 2 else ""
            if name in {
                "proxy_pass", "grpc_pass", "uwsgi_pass", "fastcgi_pass",
                "scgi_pass", "memcached_pass",
            }:
                forwarding.append((name, argument))
            if name == "listen":
                expanded_listens.append(normalized_listen_port(argument))
            pending_block = None
        else:
            if pending_block is not None:
                fail("expanded Nginx configuration has adjacent directives")
            pending_block = token
    if pending_block is not None or depth != 0 or block_stack:
        fail("expanded Nginx configuration did not terminate cleanly")
    allowed_forwarding = [
        ("proxy_pass", "http://uten_imp_internal_test_backend/actuator/health"),
        *[("proxy_pass", "http://uten_imp_internal_test_backend")] * 6,
    ]
    # The reviewed target has exactly five explicit HTTP server blocks: one
    # loopback static probe, two default-deny listeners and two employee-site
    # listeners.  An extra block with no ``listen`` would otherwise acquire
    # Nginx's implicit port 80 and escape a directive-only count.
    if (
        expanded_server_blocks != 5
        or len(expanded_listens) != expanded_server_blocks
        or sorted(expanded_listens) != [80, 80, 443, 443, 8081]
    ):
        fail("expanded Nginx configuration listener boundary differs")
    if (
        expanded.count(b"upstream uten_imp_internal_test_backend {") != 1
        or b"upstream uten_imp_backend {" in expanded
        or expanded.count(b"server 127.0.0.1:8080;") != 1
        or expanded.count(b"listen 127.0.0.1:8081;") != 1
        or sorted((kind, value.strip()) for kind, value in forwarding)
        != sorted(allowed_forwarding)
    ):
        fail("expanded Nginx configuration contains another Uten entry")
    return expanded


def handoff_legacy_nginx(
    transaction_dir: Path,
    expected_preimage: str | None,
    *,
    resume_authorized: bool,
) -> dict[str, Any]:
    """Atomically disable the Phase4 production include without deleting it."""

    if expected_preimage is not None and not SHA256_RE.fullmatch(expected_preimage):
        fail("legacy Nginx reviewed preimage digest is malformed")
    archive = LEGACY_NGINX_ARCHIVE_ROOT / f"{transaction_dir.name}.conf"
    live_present = os.path.lexists(LEGACY_NGINX_TARGET)
    archive_present = os.path.lexists(archive)
    if live_present and archive_present:
        fail("legacy Nginx live and archived paths coexist")
    if live_present:
        root_file(LEGACY_NGINX_TARGET, mode=0o644)
        if expected_preimage is None or sha256_file(LEGACY_NGINX_TARGET) != expected_preimage:
            fail("legacy Phase4 Nginx include differs from the reviewed preimage")
        if LEGACY_NGINX_ARCHIVE_ROOT.exists():
            root_directory(LEGACY_NGINX_ARCHIVE_ROOT, mode=0o700)
            if any(LEGACY_NGINX_ARCHIVE_ROOT.iterdir()):
                fail("legacy Nginx archive contains an unrelated entry")
        else:
            LEGACY_NGINX_ARCHIVE_ROOT.mkdir(mode=0o700)
            os.chown(LEGACY_NGINX_ARCHIVE_ROOT, 0, 0)
            os.chmod(LEGACY_NGINX_ARCHIVE_ROOT, 0o700)
            fsync_directory(LEGACY_NGINX_ARCHIVE_ROOT.parent)
        os.replace(LEGACY_NGINX_TARGET, archive)
        fsync_directory(LEGACY_NGINX_TARGET.parent)
        fsync_directory(LEGACY_NGINX_ARCHIVE_ROOT)
    elif archive_present:
        if not resume_authorized:
            fail("first legacy Nginx handoff bypassed its reviewed live preimage")
        root_directory(LEGACY_NGINX_ARCHIVE_ROOT, mode=0o700)
        root_file(archive, mode=0o644)
        if expected_preimage is None or sha256_file(archive) != expected_preimage:
            fail("archived legacy Nginx include differs from the reviewed preimage")
    elif expected_preimage is not None:
        fail("reviewed legacy Phase4 Nginx include disappeared before handoff")
    if os.path.lexists(LEGACY_NGINX_TARGET):
        fail("legacy Phase4 Nginx include remains enabled")
    archived_sha = sha256_file(archive) if archive.exists() else None
    receipt = {
        "archivePath": str(archive) if archive.exists() else None,
        "archiveSha256": archived_sha,
        "kind": "uten-imp-internal-test-legacy-nginx-handoff",
        "legacyPath": str(LEGACY_NGINX_TARGET),
        "preimageSha256": expected_preimage,
        "schemaVersion": 1,
        "status": "COMMITTED_LEGACY_INCLUDE_DISABLED_ENTRY_CLOSED",
        "transactionId": transaction_dir.name,
    }
    receipt_path = transaction_dir / "legacy-nginx-handoff.json"
    if os.path.lexists(receipt_path):
        if strict_json_document(
            receipt_path.read_bytes(), "legacy Nginx handoff receipt"
        ) != receipt:
            fail("legacy Nginx handoff receipt differs")
    else:
        atomic(receipt_path, canonical(receipt), 0o600)
    return {
        "archivePath": receipt["archivePath"],
        "archiveSha256": archived_sha,
        "path": str(receipt_path),
        "sha256": sha256_file(receipt_path),
    }


def install_source(
    source: Path,
    target: Path,
    mode: int,
    expected_preimage: str | None,
    *,
    resume_authorized: bool = False,
) -> None:
    root_file(source)
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    root_directory(target.parent)
    desired_sha = sha256_file(source)
    if os.path.lexists(target):
        root_file(target)
        current_sha = sha256_file(target)
        if current_sha == desired_sha:
            if not resume_authorized and expected_preimage != current_sha:
                fail(
                    f"first host preparation did not authorize the desired live preimage: {target}"
                )
            os.chmod(target, mode)
            return
        if expected_preimage is None or current_sha != expected_preimage:
            fail(f"live target differs from both authorized preimage and desired source: {target}")
        atomic(target, source.read_bytes(), mode, replace=True)
    else:
        if expected_preimage is not None:
            fail(f"authorized target preimage is unexpectedly absent: {target}")
        atomic(target, source.read_bytes(), mode)
    root_file(target, mode=mode)
    if sha256_file(target) != sha256_file(source):
        fail(f"installed bytes differ from reviewed source: {target}")


def _backup_installer_directory(path: Path) -> os.stat_result:
    details = root_directory(path)
    if details.st_gid != 0 or stat.S_IMODE(details.st_mode) != 0o500:
        fail(f"backup installer source-bundle directory is not root:root 0500: {path}")
    return details


def _ensure_backup_installer_directories() -> None:
    parent = root_directory(BACKUP_INSTALLER_BUNDLE_ROOT.parent)
    if parent.st_gid != 0:
        fail("backup installer source-bundle parent is not root controlled")
    for relative in sorted(
        _backup_installer_expected_directories(),
        key=lambda value: (len(value.parts), value.as_posix()),
    ):
        target = (
            BACKUP_INSTALLER_BUNDLE_ROOT
            if relative == Path(".")
            else BACKUP_INSTALLER_BUNDLE_ROOT / relative
        )
        if os.path.lexists(target):
            _backup_installer_directory(target)
            continue
        target_parent = target.parent
        if target_parent == BACKUP_INSTALLER_BUNDLE_ROOT.parent:
            checked_parent = root_directory(target_parent)
            if checked_parent.st_gid != 0:
                fail("backup installer source-bundle parent is not root controlled")
        else:
            _backup_installer_directory(target_parent)
        target.mkdir(mode=0o500)
        os.chown(target, 0, 0)
        os.chmod(target, 0o500)
        _backup_installer_directory(target)
        fsync_directory(target_parent)


def _publish_backup_installer_payload(
    payload: bytes,
    target: Path,
    *,
    mode: int,
    expected_preimage: str | None,
    resume_authorized: bool,
) -> None:
    desired = hashlib.sha256(payload).hexdigest()
    if os.path.lexists(target):
        current_payload = stable_root_bytes(target, mode=mode)
        current = hashlib.sha256(current_payload).hexdigest()
        if current == desired:
            if not resume_authorized and expected_preimage != current:
                fail(
                    f"first backup installer publication did not authorize desired live bytes: {target}"
                )
            return
        if expected_preimage is None or current != expected_preimage:
            fail(
                f"backup installer target differs from preimage and reviewed source: {target}"
            )
        atomic(target, payload, mode, replace=True)
    else:
        if expected_preimage is not None:
            fail(f"backup installer authorized preimage is unexpectedly absent: {target}")
        atomic(target, payload, mode)
    if stable_root_bytes(target, mode=mode) != payload:
        fail(f"backup installer target differs after atomic publication: {target}")


def validate_backup_installer_live_contract(
    payloads: dict[str, bytes],
) -> dict[str, str]:
    """Rebind the installed exact tree and launcher constants without executing it."""

    expected_contract = validate_backup_installer_source_payloads(payloads)
    state = backup_installer_bundle_state(require_complete=True)
    live_payloads = {
        BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY: stable_root_bytes(
            BACKUP_INSTALLER_LAUNCHER_TARGET, mode=0o500
        )
    }
    for key, target in BACKUP_INSTALLER_BUNDLE_TARGETS.items():
        live_payloads[key] = stable_root_bytes(target, mode=0o400)
        desired = hashlib.sha256(payloads[key]).hexdigest()
        if state["fileSha256"][key] != desired or live_payloads[key] != payloads[key]:
            fail(f"backup installer installed bundle digest differs: {key}")
    live_contract = validate_backup_installer_source_payloads(live_payloads)
    if live_contract != expected_contract:
        fail("backup installer installed launcher contract differs")
    return {
        **live_contract,
        "installedBundleInventorySha256": state["inventorySha256"],
    }


def install_backup_installer_assets(
    reviewed: dict[str, Any],
    payloads: dict[str, bytes],
    *,
    resume_authorized: bool,
) -> dict[str, str]:
    """Atomically publish the reviewed inert source bundle, then its launcher."""

    validate_backup_installer_target_preimage(
        reviewed, payloads, resume_authorized=resume_authorized
    )
    _ensure_backup_installer_directories()
    for key in BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY:
        _publish_backup_installer_payload(
            payloads[key],
            BACKUP_INSTALLER_BUNDLE_TARGETS[key],
            mode=0o400,
            expected_preimage=reviewed["targetPreimageSha256"][key],
            resume_authorized=resume_authorized,
        )
    # The executable entrypoint is deliberately the last published object.
    # The source bundle remains inert data and no helper is imported or run.
    launcher_parent = root_directory(BACKUP_INSTALLER_LAUNCHER_TARGET.parent)
    if launcher_parent.st_gid != 0:
        fail("backup installer launcher parent is not root controlled")
    _publish_backup_installer_payload(
        payloads[BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY],
        BACKUP_INSTALLER_LAUNCHER_TARGET,
        mode=0o500,
        expected_preimage=reviewed["targetPreimageSha256"][
            BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY
        ],
        resume_authorized=resume_authorized,
    )
    return validate_backup_installer_live_contract(payloads)


def _trusted_bundle_directory(path: Path, label: str) -> os.stat_result:
    details = root_directory(path)
    if details.st_gid != 0 or stat.S_IMODE(details.st_mode) != 0o500:
        fail(f"{label} source-bundle directory is not root:root 0500: {path}")
    return details


def _ensure_trusted_bundle_directories(
    *,
    label: str,
    bundle_root: Path,
    relative_by_source_key: dict[str, str],
) -> None:
    parent = root_directory(bundle_root.parent)
    if parent.st_gid != 0:
        fail(f"{label} source-bundle parent is not root controlled")
    for relative in sorted(
        _trusted_bundle_expected_directories(relative_by_source_key),
        key=lambda value: (len(value.parts), value.as_posix()),
    ):
        target = bundle_root if relative == Path(".") else bundle_root / relative
        if os.path.lexists(target):
            _trusted_bundle_directory(target, label)
            continue
        target_parent = target.parent
        if target_parent == bundle_root.parent:
            checked_parent = root_directory(target_parent)
            if checked_parent.st_gid != 0:
                fail(f"{label} source-bundle parent is not root controlled")
        else:
            _trusted_bundle_directory(target_parent, label)
        target.mkdir(mode=0o500)
        os.chown(target, 0, 0)
        os.chmod(target, 0o500)
        _trusted_bundle_directory(target, label)
        fsync_directory(target_parent)


def _publish_trusted_installer_payload(
    payload: bytes,
    target: Path,
    *,
    label: str,
    mode: int,
    expected_preimage: str | None,
    resume_authorized: bool,
) -> None:
    desired = hashlib.sha256(payload).hexdigest()
    if os.path.lexists(target):
        current_payload = stable_root_bytes(target, mode=mode)
        current = hashlib.sha256(current_payload).hexdigest()
        if current == desired:
            if not resume_authorized and expected_preimage != current:
                fail(f"first {label} publication did not authorize desired live bytes")
            return
        if expected_preimage is None or current != expected_preimage:
            fail(f"{label} target differs from preimage and reviewed source: {target}")
        atomic(target, payload, mode, replace=True)
    else:
        if expected_preimage is not None:
            fail(f"{label} authorized preimage is unexpectedly absent: {target}")
        atomic(target, payload, mode)
    if stable_root_bytes(target, mode=mode) != payload:
        fail(f"{label} target differs after atomic publication: {target}")


def _validate_trusted_installer_live_bundle(
    payloads: dict[str, bytes],
    *,
    label: str,
    launcher_source_key: str,
    launcher_target: Path,
    bundle_root: Path,
    relative_by_source_key: dict[str, str],
    bundle_source_keys: frozenset[str],
    bundle_targets: dict[str, Path],
    source_keys: frozenset[str],
    validator: Any,
) -> dict[str, str]:
    expected_contract = validator({key: payloads[key] for key in source_keys})
    state = _trusted_bundle_state(
        label=label,
        bundle_root=bundle_root,
        relative_by_source_key=relative_by_source_key,
        bundle_source_keys=bundle_source_keys,
        require_complete=True,
    )
    live_payloads = {
        launcher_source_key: stable_root_bytes(launcher_target, mode=0o500)
    }
    for key, target in bundle_targets.items():
        live_payloads[key] = stable_root_bytes(target, mode=0o400)
        desired = hashlib.sha256(payloads[key]).hexdigest()
        if state["fileSha256"][key] != desired or live_payloads[key] != payloads[key]:
            fail(f"{label} installed bundle digest differs: {key}")
    live_contract = validator(live_payloads)
    if live_contract != expected_contract:
        fail(f"{label} installed launcher contract differs")
    return {
        **live_contract,
        "installedBundleInventorySha256": state["inventorySha256"],
    }


def _install_trusted_installer_bundle(
    reviewed: dict[str, Any],
    payloads: dict[str, bytes],
    *,
    label: str,
    launcher_source_key: str,
    launcher_target: Path,
    bundle_root: Path,
    relative_by_source_key: dict[str, str],
    bundle_targets: dict[str, Path],
    source_keys: frozenset[str],
    bundle_source_keys: frozenset[str],
    validator: Any,
    resume_authorized: bool,
) -> dict[str, str]:
    _ensure_trusted_bundle_directories(
        label=label,
        bundle_root=bundle_root,
        relative_by_source_key=relative_by_source_key,
    )
    for key in relative_by_source_key:
        _publish_trusted_installer_payload(
            payloads[key],
            bundle_targets[key],
            label=label,
            mode=0o400,
            expected_preimage=reviewed["targetPreimageSha256"][key],
            resume_authorized=resume_authorized,
        )
    # Publish the only executable object last; the complete bundle stays inert.
    launcher_parent = root_directory(launcher_target.parent)
    if launcher_parent.st_gid != 0:
        fail(f"{label} launcher parent is not root controlled")
    _publish_trusted_installer_payload(
        payloads[launcher_source_key],
        launcher_target,
        label=label,
        mode=0o500,
        expected_preimage=reviewed["targetPreimageSha256"][launcher_source_key],
        resume_authorized=resume_authorized,
    )
    return _validate_trusted_installer_live_bundle(
        payloads,
        label=label,
        launcher_source_key=launcher_source_key,
        launcher_target=launcher_target,
        bundle_root=bundle_root,
        relative_by_source_key=relative_by_source_key,
        bundle_source_keys=bundle_source_keys,
        bundle_targets=bundle_targets,
        source_keys=source_keys,
        validator=validator,
    )


def validate_trusted_installer_live_contracts(
    payloads: dict[str, bytes],
) -> dict[str, dict[str, str]]:
    validate_trusted_installer_source_payloads(payloads)
    return {
        "backup": validate_backup_installer_live_contract(
            {key: payloads[key] for key in BACKUP_INSTALLER_SOURCE_KEYS}
        ),
        "monitoring": _validate_trusted_installer_live_bundle(
            payloads,
            label="monitoring installer",
            launcher_source_key=MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY,
            launcher_target=MONITORING_INSTALLER_LAUNCHER_TARGET,
            bundle_root=MONITORING_INSTALLER_BUNDLE_ROOT,
            relative_by_source_key=MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
            bundle_source_keys=MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS,
            bundle_targets=MONITORING_INSTALLER_BUNDLE_TARGETS,
            source_keys=MONITORING_INSTALLER_SOURCE_KEYS,
            validator=validate_monitoring_installer_source_payloads,
        ),
        "retention": _validate_trusted_installer_live_bundle(
            payloads,
            label="retention installer",
            launcher_source_key=RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY,
            launcher_target=RETENTION_INSTALLER_LAUNCHER_TARGET,
            bundle_root=RETENTION_INSTALLER_BUNDLE_ROOT,
            relative_by_source_key=RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
            bundle_source_keys=RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS,
            bundle_targets=RETENTION_INSTALLER_BUNDLE_TARGETS,
            source_keys=RETENTION_INSTALLER_SOURCE_KEYS,
            validator=validate_retention_installer_source_payloads,
        ),
    }


def install_trusted_installer_assets(
    reviewed: dict[str, Any],
    payloads: dict[str, bytes],
    *,
    resume_authorized: bool,
) -> dict[str, dict[str, str]]:
    """Install exact inert bundles only after durable host mutation authority."""

    validate_trusted_installer_target_preimages(
        reviewed, payloads, resume_authorized=resume_authorized
    )
    results = {
        "backup": install_backup_installer_assets(
            reviewed,
            {key: payloads[key] for key in BACKUP_INSTALLER_SOURCE_KEYS},
            resume_authorized=resume_authorized,
        )
    }
    results["monitoring"] = _install_trusted_installer_bundle(
        reviewed,
        payloads,
        label="monitoring installer",
        launcher_source_key=MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY,
        launcher_target=MONITORING_INSTALLER_LAUNCHER_TARGET,
        bundle_root=MONITORING_INSTALLER_BUNDLE_ROOT,
        relative_by_source_key=MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
        bundle_targets=MONITORING_INSTALLER_BUNDLE_TARGETS,
        source_keys=MONITORING_INSTALLER_SOURCE_KEYS,
        bundle_source_keys=MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS,
        validator=validate_monitoring_installer_source_payloads,
        resume_authorized=resume_authorized,
    )
    results["retention"] = _install_trusted_installer_bundle(
        reviewed,
        payloads,
        label="retention installer",
        launcher_source_key=RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY,
        launcher_target=RETENTION_INSTALLER_LAUNCHER_TARGET,
        bundle_root=RETENTION_INSTALLER_BUNDLE_ROOT,
        relative_by_source_key=RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
        bundle_targets=RETENTION_INSTALLER_BUNDLE_TARGETS,
        source_keys=RETENTION_INSTALLER_SOURCE_KEYS,
        bundle_source_keys=RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS,
        validator=validate_retention_installer_source_payloads,
        resume_authorized=resume_authorized,
    )
    return results


def reviewed_source_manifest(
    args: argparse.Namespace, *, resume_authorized: bool = False
) -> tuple[dict[str, Any], str]:
    transaction = "prepare-internal-runtime-" + args.expected_source_manifest_sha256[:16]
    snapshot = EVIDENCE / transaction / "reviewed-source-manifest.json"
    source = snapshot if resume_authorized else args.source_manifest
    root_file(source, mode=0o600)
    raw = source.read_bytes()
    raw_sha = hashlib.sha256(raw).hexdigest()
    if raw_sha != args.expected_source_manifest_sha256:
        fail("reviewed source manifest differs from its out-of-band digest")
    value = strict_json_document(raw, "reviewed source manifest")
    if set(value) != {
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
    }:
        fail("reviewed source manifest schema differs")
    expected_source_keys = set(SOURCES) | {
        "manifestBuilderSha256",
        "nginxTemplateSha256",
    }
    source_hashes = value.get("sourceSha256")
    host = value.get("hostParameters")
    if (
        not isinstance(source_hashes, dict)
        or set(source_hashes) != expected_source_keys
        or any(not isinstance(item, str) or not SHA256_RE.fullmatch(item) for item in source_hashes.values())
    ):
        fail("reviewed source manifest inventory is malformed")
    expected_sources = None
    if not resume_authorized:
        expected_sources = {key: sha256_file(path) for key, path in SOURCES.items()}
        expected_sources["manifestBuilderSha256"] = sha256_file(MANIFEST_BUILDER)
        expected_sources["nginxTemplateSha256"] = sha256_file(NGINX_SOURCE)
    if (
        value.get("schemaVersion") != 1
        or value.get("kind") != "uten-imp-internal-test-reviewed-host-sources"
        or value.get("approvalReference") != args.approval_reference
        or value.get("builderSha256") != source_hashes.get("manifestBuilderSha256")
        or value.get("preparerSha256") != args.expected_preparer_sha256
        or not isinstance(host, dict)
        or set(host)
        != {
            "allowedSignersSha256",
            "domain",
            "expectedNginxExpandedConfigSha256",
            "officeCidr",
            "serverEnvironmentPreimageSha256",
            "serverEnvironmentSha256",
            "tlsCertificateSha256",
            "tlsKeySha256",
            "updaterVenvInventorySha256",
        }
        or host
        != {
            "allowedSignersSha256": args.expected_allowed_signers_sha256,
            "domain": args.domain,
            "expectedNginxExpandedConfigSha256": host.get(
                "expectedNginxExpandedConfigSha256"
            ),
            "officeCidr": args.office_cidr,
            "serverEnvironmentPreimageSha256": args.expected_server_environment_preimage_sha256,
            "serverEnvironmentSha256": args.expected_server_environment_sha256,
            "tlsCertificateSha256": stable_root_digest(args.tls_cert, mode=0o644),
            "tlsKeySha256": stable_root_digest(args.tls_key, mode=0o600),
            "updaterVenvInventorySha256": args.expected_updater_venv_inventory_sha256,
        }
        or not isinstance(host.get("expectedNginxExpandedConfigSha256"), str)
        or SHA256_RE.fullmatch(host["expectedNginxExpandedConfigSha256"]) is None
        or (expected_sources is not None and source_hashes != expected_sources)
        or not isinstance(value.get("targetPreimageSha256"), dict)
        or set(value["targetPreimageSha256"])
        != (
            set(TARGETS)
            | {"legacyNginxConfigSha256", "nginxConfigSha256"}
            | TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS
        )
    ):
        fail("reviewed source manifest does not authorize the exact source inventory")
    if not resume_authorized:
        require_fresh_review(value)
    for digest in value["targetPreimageSha256"].values():
        if digest is not None and not re.fullmatch(r"[0-9a-f]{64}", str(digest)):
            fail("reviewed target preimage digest is malformed")
    return value, raw_sha


def snapshot_reviewed_source_manifest(
    transaction_dir: Path,
    source_manifest: Path,
    expected_sha256: str,
) -> Path:
    destination = transaction_dir / "reviewed-source-manifest.json"
    if destination.exists():
        root_file(destination, mode=0o600)
        if sha256_file(destination) != expected_sha256:
            fail("root reviewed source manifest snapshot changed")
        return destination
    root_file(source_manifest, mode=0o600)
    raw = source_manifest.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_sha256:
        fail("reviewed source manifest changed before durable snapshot")
    atomic(destination, raw, 0o600)
    root_file(destination, mode=0o600)
    if sha256_file(destination) != expected_sha256:
        fail("published reviewed source manifest snapshot differs")
    return destination


def snapshot_sources(
    transaction_dir: Path,
    reviewed: dict[str, Any],
    *,
    resume_authorized: bool = False,
) -> dict[str, Path]:
    snapshot = transaction_dir / "source-snapshot"
    if not snapshot.exists():
        snapshot.mkdir(mode=0o700)
        os.chown(snapshot, 0, 0)
        os.chmod(snapshot, 0o700)
        fsync_directory(transaction_dir)
    else:
        root_directory(snapshot)
    inventory = {
        **SOURCES,
        "manifestBuilderSha256": MANIFEST_BUILDER,
        "nginxTemplateSha256": NGINX_SOURCE,
    }
    results: dict[str, Path] = {}
    for key, source in inventory.items():
        expected = reviewed["sourceSha256"][key]
        destination = snapshot / key
        if destination.exists():
            root_file(destination, mode=0o600)
            if sha256_file(destination) != expected:
                fail(f"root source snapshot changed: {key}")
            results[key] = destination
            continue
        if resume_authorized:
            fail("authorized source snapshot is incomplete; live source cannot refill it")
        flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        try:
            descriptor = os.open(source, flags)
        except OSError as exc:
            raise PreparationError(
                f"reviewed source could not be opened without following links: {source}"
            ) from exc
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != 0
                or before.st_nlink != 1
                or before.st_mode & 0o022
                or before.st_size <= 0
                or before.st_size > 8 * 1024 * 1024
            ):
                fail(f"reviewed source metadata is unsafe: {source}")
            chunks: list[bytes] = []
            remaining = before.st_size
            while remaining:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    fail(f"reviewed source truncated while snapshotting: {source}")
                chunks.append(chunk)
                remaining -= len(chunk)
            after = os.fstat(descriptor)
            stable = (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            ) == (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            )
            payload = b"".join(chunks)
            if not stable or hashlib.sha256(payload).hexdigest() != expected:
                fail(f"reviewed source changed while snapshotting: {source}")
        finally:
            os.close(descriptor)
        atomic(destination, payload, 0o600)
        if sha256_file(destination) != expected:
            fail(f"published root source snapshot differs from reviewed digest: {key}")
        results[key] = destination
    fsync_directory(snapshot)
    return results


def mutation_authority_path(transaction_dir: Path) -> Path:
    return transaction_dir / "mutation-authorized.committed.json"


def read_mutation_authority(
    transaction: str,
    reviewed_sha: str,
) -> dict[str, Any] | None:
    transaction_dir = EVIDENCE / transaction
    committed = mutation_authority_path(transaction_dir)
    present = [path for path in (MUTATION_ACTIVE, committed) if os.path.lexists(path)]
    if len(present) > 1:
        # The terminal transition is one same-filesystem rename.  Seeing both
        # names therefore cannot be a valid crash boundary and must never be
        # "repaired" by deleting either piece of evidence.
        fail("live and committed host mutation authorities coexist")
    if not present:
        return None
    path = present[0]
    root_file(path, mode=0o600)
    value = strict_json_document(path.read_bytes(), "host mutation authority")
    if (
        set(value)
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
        or value.get("schemaVersion") != 1
        or value.get("kind") != "uten-imp-internal-test-host-mutation-authority"
        or value.get("transactionId") != transaction
        or value.get("reviewedSourceManifestSha256") != reviewed_sha
        or value.get("planPath") != str(transaction_dir / "plan.json")
        # The bytes are deliberately preserved by the terminal rename.  The
        # fixed committed pathname, subsequently bound by complete.json and
        # active.json, is the terminal state; the authorization document itself
        # remains an append-only record of what was approved.
        or value.get("status") != "MUTATION_AUTHORIZED_ENTRY_CLOSED"
    ):
        fail("host mutation authority differs from this transaction")
    for key in ("planSha256", "reviewedSourceManifestSha256", "snapshotInventorySha256"):
        if not isinstance(value.get(key), str) or not SHA256_RE.fullmatch(value[key]):
            fail("host mutation authority digest is malformed")
    authorized = parse_utc(
        value.get("authorizedAtUtc"), "host mutation authorization time"
    )
    plan_path = transaction_dir / "plan.json"
    root_file(plan_path, mode=0o600)
    if sha256_file(plan_path) != value["planSha256"]:
        fail("host mutation authority plan digest changed")
    reviewed_snapshot = transaction_dir / "reviewed-source-manifest.json"
    root_file(reviewed_snapshot, mode=0o600)
    if sha256_file(reviewed_snapshot) != reviewed_sha:
        fail("host mutation authority reviewed manifest digest changed")
    reviewed = strict_json_document(
        reviewed_snapshot.read_bytes(), "host mutation reviewed source manifest"
    )
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
        or reviewed.get("builderSha256")
        != reviewed.get("sourceSha256", {}).get("manifestBuilderSha256")
    ):
        fail("host mutation reviewed manifest schema differs")
    created = parse_utc(reviewed.get("createdAtUtc"), "host review creation time")
    expires = parse_utc(reviewed.get("expiresAtUtc"), "host review expiry time")
    if (
        expires <= created
        or expires > created + timedelta(days=7)
        or not created <= authorized < expires
    ):
        fail("host mutation authorization was outside its reviewed window")
    return value


def authorize_host_mutation(
    transaction_dir: Path,
    reviewed_sha: str,
    reviewed: dict[str, Any],
    source_snapshot: dict[str, Path],
) -> dict[str, Any]:
    plan_path = transaction_dir / "plan.json"
    inventory = {key: sha256_file(path) for key, path in sorted(source_snapshot.items())}
    value = {
        "authorizedAtUtc": utc_now(),
        "kind": "uten-imp-internal-test-host-mutation-authority",
        "planPath": str(plan_path),
        "planSha256": sha256_file(plan_path),
        "reviewedSourceManifestSha256": reviewed_sha,
        "schemaVersion": 1,
        "snapshotInventorySha256": hashlib.sha256(canonical(inventory)).hexdigest(),
        "status": "MUTATION_AUTHORIZED_ENTRY_CLOSED",
        "transactionId": transaction_dir.name,
    }
    existing = read_mutation_authority(transaction_dir.name, reviewed_sha)
    if existing is not None:
        comparable = dict(value)
        comparable["authorizedAtUtc"] = existing["authorizedAtUtc"]
        comparable["status"] = existing["status"]
        if existing != comparable:
            fail("existing host mutation authority differs from immutable inputs")
        return existing
    require_fresh_review(reviewed)
    atomic(MUTATION_ACTIVE, canonical(value), 0o600)
    return value


def commit_host_mutation_authority(
    transaction_dir: Path, reviewed_sha: str
) -> dict[str, Any]:
    committed = mutation_authority_path(transaction_dir)
    authority = read_mutation_authority(transaction_dir.name, reviewed_sha)
    if authority is None:
        fail("host mutation authority disappeared before terminal commit")
    if os.path.lexists(MUTATION_ACTIVE):
        if os.path.lexists(committed):
            fail("committed host mutation authority unexpectedly already exists")
        if MUTATION_ACTIVE.lstat().st_dev != transaction_dir.lstat().st_dev:
            fail("host mutation authority cannot be committed across filesystems")
        os.rename(MUTATION_ACTIVE, committed)
        # fsync both directory entries even though the destination is nested
        # below the source directory.  After any crash, exactly one authorized
        # pathname can be adopted without synthesizing or overwriting evidence.
        fsync_directory(transaction_dir)
        fsync_directory(EVIDENCE)
        root_file(committed, mode=0o600)
        if committed.read_bytes() != canonical(authority):
            fail("committed host mutation authority bytes changed during rename")
    return authority


def _attachment_directory(
    path: Path,
    *,
    uid: int,
    gid: int,
    mode: int,
    data_device: int,
) -> None:
    if os.path.lexists(path):
        details = path.lstat()
        if (
            not stat.S_ISDIR(details.st_mode)
            or path.is_symlink()
            or details.st_uid != uid
            or details.st_gid != gid
            or stat.S_IMODE(details.st_mode) != mode
            or details.st_dev != data_device
        ):
            fail(f"attachment directory preimage is unsafe: {path}")
        return
    path.mkdir(mode=mode)
    os.chown(path, uid, gid)
    os.chmod(path, mode)
    fsync_directory(path.parent)
    details = path.lstat()
    if (
        details.st_uid != uid
        or details.st_gid != gid
        or stat.S_IMODE(details.st_mode) != mode
        or details.st_dev != data_device
    ):
        fail(f"attachment directory did not converge: {path}")


def ensure_attachment_layout(
    transaction_dir: Path,
    storage_authority_sha: str,
) -> dict[str, Any]:
    if not SHA256_RE.fullmatch(storage_authority_sha):
        fail("attachment layout storage authority digest is malformed")
    root_file(STORAGE_AUTHORITY, mode=0o640)
    if sha256_file(STORAGE_AUTHORITY) != storage_authority_sha:
        fail("attachment layout names another storage authority")
    root_file(STORAGE_BOOT_VERIFIER, mode=0o644)
    run(["/usr/bin/python3", "-I", str(STORAGE_BOOT_VERIFIER)])
    data = Path("/data")
    data_details = root_directory(data)
    if stat.S_IMODE(data_details.st_mode) != 0o755:
        fail("/data must remain root:root mode 0755")
    try:
        app = __import__("pwd").getpwnam("uten-imp")
        app_group = grp.getgrnam("uten-imp")
    except KeyError as exc:
        raise PreparationError("internal-test service identity is missing") from exc
    if app.pw_gid != app_group.gr_gid:
        fail("internal-test service primary group differs")
    if os.path.lexists(ATTACHMENT_ROOT):
        existing_children = set(ATTACHMENT_ROOT.iterdir())
        allowed_children = {
            ATTACHMENT_ROOT / "staging",
            ATTACHMENT_ROOT / "final",
        }
        if not existing_children.issubset(allowed_children):
            fail("attachment layout contains unapproved preexisting content")
    paths = (
        (data / "uten-imp", 0, 0, 0o755),
        (ATTACHMENT_ROOT, 0, app_group.gr_gid, 0o750),
        (ATTACHMENT_ROOT / "staging", app.pw_uid, app_group.gr_gid, 0o750),
        (ATTACHMENT_ROOT / "final", app.pw_uid, app_group.gr_gid, 0o750),
    )
    for path, uid, gid, mode in paths:
        _attachment_directory(
            path, uid=uid, gid=gid, mode=mode, data_device=data_details.st_dev
        )
    if any(ATTACHMENT_ROOT.rglob("*")):
        allowed = {
            ATTACHMENT_ROOT / "staging",
            ATTACHMENT_ROOT / "final",
        }
        unexpected = [path for path in ATTACHMENT_ROOT.rglob("*") if path not in allowed]
        if unexpected:
            fail("attachment layout contains unapproved preexisting content")
    layout = [
        {
            "gid": path.lstat().st_gid,
            "mode": f"{stat.S_IMODE(path.lstat().st_mode):04o}",
            "path": str(path),
            "uid": path.lstat().st_uid,
        }
        for path, _uid, _gid, _mode in paths
    ]
    receipt = {
        "kind": "uten-imp-internal-test-attachment-layout",
        "layout": layout,
        "layoutSha256": hashlib.sha256(canonical(layout)).hexdigest(),
        "schemaVersion": 1,
        "status": "COMMITTED_ENTRY_CLOSED_UPLOADS_DISABLED",
        "storageAuthoritySha256": storage_authority_sha,
        "transactionId": transaction_dir.name,
    }
    receipt_path = transaction_dir / "attachment-layout.json"
    if receipt_path.exists():
        if receipt_path.read_bytes() != canonical(receipt):
            fail("attachment layout receipt differs from live directories")
    else:
        atomic(receipt_path, canonical(receipt), 0o600)
    run([str(TARGETS["storageValidatorSha256"])])
    return {
        "layoutSha256": receipt["layoutSha256"],
        "receiptPath": str(receipt_path),
        "receiptSha256": sha256_file(receipt_path),
        "storageAuthoritySha256": storage_authority_sha,
    }


def _apply_locked(args: argparse.Namespace) -> dict[str, Any]:
    if os.geteuid() != 0:
        fail("host preparation must run as root")
    if not APPROVAL_RE.fullmatch(args.approval_reference):
        fail("host preparation approval reference is malformed")
    validate_inputs(args.domain, args.office_cidr, args.tls_cert, args.tls_key)
    entry_closed()
    root_file(SERVER_ENV)
    if sha256_file(Path(__file__).resolve()) != args.expected_preparer_sha256:
        fail("host preparer differs from the independently reviewed digest")
    if not SHA256_RE.fullmatch(args.expected_source_manifest_sha256):
        fail("expected reviewed source manifest digest is malformed")
    if (
        not SHA256_RE.fullmatch(args.expected_allowed_signers_sha256)
        or not SHA256_RE.fullmatch(args.expected_updater_venv_inventory_sha256)
        or not SHA256_RE.fullmatch(
            args.expected_server_environment_preimage_sha256
        )
    ):
        fail("expected updater trust, virtualenv or environment preimage digest is malformed")
    reviewed_sha = args.expected_source_manifest_sha256
    transaction = "prepare-internal-runtime-" + reviewed_sha[:16]
    resume_authority = read_mutation_authority(transaction, reviewed_sha)
    existing_terminal_same_transaction = False
    if os.path.lexists(ACTIVE):
        reviewed, confirmed_reviewed_sha = reviewed_source_manifest(
            args, resume_authorized=True
        )
        if confirmed_reviewed_sha != reviewed_sha:
            fail("terminal host preparation reviewed manifest digest changed")
        root_file(ACTIVE, mode=0o600)
        active_receipt = strict_json_document(
            ACTIVE.read_bytes(), "active host preparation receipt"
        )
        if set(active_receipt) != {
            "contractSha256", "entryEnabled", "kind", "mutationAuthorityPath",
            "mutationAuthoritySha256", "nginxEnabledLink",
            "nginxEnabledTargetSha256", "planSha256", "productionAuthority",
            "schemaVersion", "status", "transactionId",
        } or (
            active_receipt.get("schemaVersion") != 1
            or active_receipt.get("kind")
            != "uten-imp-internal-test-host-preparation-receipt"
            or active_receipt.get("status") != "COMMITTED_ENTRY_CLOSED"
            or active_receipt.get("entryEnabled") is not False
            or active_receipt.get("productionAuthority") is not False
        ):
            fail("terminal host preparation receipt schema differs")
        if active_receipt.get("transactionId") != transaction:
            fail(
                "another host preparation is already terminal; use the signed updater"
            )
        existing_terminal_same_transaction = True
        complete_path = EVIDENCE / transaction / "complete.json"
        root_file(complete_path, mode=0o600)
        if complete_path.read_bytes() != ACTIVE.read_bytes():
            fail("same host preparation active/complete receipts differ")
        if not os.path.lexists(CONTRACT):
            fail("terminal host preparation lost its runtime contract")
        root_file(CONTRACT, mode=0o600)
        if active_receipt.get("contractSha256") != sha256_file(CONTRACT):
            fail("terminal host preparation runtime contract changed")
        transaction_dir = EVIDENCE / transaction
        root_directory(transaction_dir)
        plan_path = transaction_dir / "plan.json"
        root_file(plan_path, mode=0o600)
        if active_receipt.get("planSha256") != sha256_file(plan_path):
            fail("terminal host preparation plan digest changed")
        plan = strict_json_document(plan_path.read_bytes(), "terminal host preparation plan")
        if (
            plan.get("schemaVersion") != 1
            or plan.get("kind") != "uten-imp-internal-test-host-preparation-plan"
            or plan.get("status") != "APPROVED_ENTRY_CLOSED"
            or plan.get("entryEnabled") is not False
            or plan.get("transactionId") != transaction
            or plan.get("approvalReference") != args.approval_reference
            or plan.get("expectedPreparerSha256") != args.expected_preparer_sha256
            or plan.get("reviewedSourceManifestSha256") != reviewed_sha
            or plan.get("reviewedSourceManifestPath")
            != str(transaction_dir / "reviewed-source-manifest.json")
            or plan.get("parameters")
            != {
                "allowedSignersSha256": args.expected_allowed_signers_sha256,
                "domain": args.domain,
                "expectedNginxExpandedConfigSha256": reviewed["hostParameters"][
                    "expectedNginxExpandedConfigSha256"
                ],
                "officeCidr": args.office_cidr,
                "serverEnvironmentPreimageSha256": args.expected_server_environment_preimage_sha256,
                "tlsCertificateSha256": stable_root_digest(args.tls_cert, mode=0o644),
                "tlsKeySha256": stable_root_digest(args.tls_key, mode=0o600),
                "serverEnvironmentSha256": args.expected_server_environment_sha256,
                "updaterVenvInventorySha256": args.expected_updater_venv_inventory_sha256,
            }
            or plan.get("sourceSha256") != reviewed["sourceSha256"]
            or plan.get("targetPreimageSha256")
            != reviewed["targetPreimageSha256"]
        ):
            fail("terminal host preparation plan differs from requested inputs")
        committed_authority = mutation_authority_path(transaction_dir)
        authority = read_mutation_authority(transaction, reviewed_sha)
        if (
            authority is None
            or os.path.lexists(MUTATION_ACTIVE)
            or active_receipt.get("mutationAuthorityPath") != str(committed_authority)
            or active_receipt.get("mutationAuthoritySha256")
            != sha256_file(committed_authority)
            or authority.get("planSha256") != active_receipt["planSha256"]
        ):
            fail("terminal host preparation mutation authority differs")
        contract = strict_json_document(CONTRACT.read_bytes(), "terminal runtime contract")
        if (
            contract.get("contractId") != "uten-imp-internal-test-runtime-v1"
            or contract.get("deploymentProfile") != "internal-test-local-v1"
            or contract.get("internalDomain") != args.domain
            or contract.get("tlsCertificatePath") != str(args.tls_cert)
            or contract.get("tlsCertificateSha256")
            != stable_root_digest(args.tls_cert, mode=0o644)
            or contract.get("tlsKeyPath") != str(args.tls_key)
            or contract.get("tlsKeySha256")
            != stable_root_digest(args.tls_key, mode=0o600)
            or contract.get("serverEnvironmentSha256")
            != args.expected_server_environment_sha256
        ):
            fail("terminal internal-test runtime contract boundary differs")
        terminal_prerequisite = validate_common_updater_prerequisites()
        validate_reviewed_updater_prerequisites(reviewed, terminal_prerequisite)
        if (
            contract.get("updaterAllowedSignersSha256")
            != terminal_prerequisite["allowedSignersSha256"]
            or contract.get("updaterVenvInventorySha256")
            != terminal_prerequisite["updaterVenvInventorySha256"]
        ):
            fail("terminal updater trust or virtualenv contract changed")
        terminal_snapshot = {
            key: transaction_dir / "source-snapshot" / key
            for key in TRUSTED_INSTALLER_SOURCE_KEYS
        }
        terminal_installer_payloads = capture_trusted_installer_snapshot_payloads(
            terminal_snapshot, reviewed
        )
        validate_trusted_installer_live_contracts(terminal_installer_payloads)
        for key, target in TARGETS.items():
            if key in TRUSTED_INSTALLER_SOURCE_KEYS:
                continue
            if contract.get(key) != sha256_file(target):
                fail(f"terminal runtime target drifted: {key}")
        if (
            active_receipt.get("nginxEnabledLink") != str(NGINX_LINK)
            or active_receipt.get("nginxEnabledTargetSha256") != sha256_file(NGINX_TARGET)
            or contract.get("nginxConfigSha256") != sha256_file(NGINX_TARGET)
            or not NGINX_LINK.is_symlink()
            or NGINX_LINK.resolve(strict=True) != NGINX_TARGET
            or hashlib.sha256(unique_nginx_include()).hexdigest()
            != contract.get("nginxExpandedConfigSha256")
        ):
            fail("terminal host preparation Nginx boundary changed")
        validate_server_environment(
            args.domain,
            args.office_cidr,
            args.expected_server_environment_sha256,
        )
        run([str(TARGETS["migratorEnvironmentValidatorSha256"]), str(MIGRATOR_ENV)])
        # A fully terminal same-manifest call is a read-only idempotent
        # validation.  Downstream DB/onboarding evidence may legitimately be
        # non-empty, so never rerun the first-install empty-layout mutation.
        return active_receipt
    if EVIDENCE.exists():
        root_directory(EVIDENCE)
        for complete_path in EVIDENCE.glob("prepare-internal-runtime-*/complete.json"):
            root_file(complete_path, mode=0o600)
            complete_value = strict_json_document(
                complete_path.read_bytes(), "host preparation terminal receipt"
            )
            if complete_value.get("transactionId") != transaction:
                fail(
                    "a different host preparation terminal already exists; use the signed updater"
                )
    if os.path.lexists(CONTRACT) and not (
        existing_terminal_same_transaction or resume_authority is not None
    ):
        fail("an existing runtime contract is not owned by this preparation transaction")
    live_environment_sha = sha256_file(SERVER_ENV)
    if resume_authority is None:
        if live_environment_sha != args.expected_server_environment_preimage_sha256:
            fail("live server environment differs from the reviewed Phase4 preimage")
    elif live_environment_sha not in {
        args.expected_server_environment_preimage_sha256,
        args.expected_server_environment_sha256,
    }:
        fail("resumed server environment matches neither reviewed preimage nor target")
    reviewed, reviewed_sha = reviewed_source_manifest(
        args, resume_authorized=resume_authority is not None
    )
    updater_prerequisite = validate_common_updater_prerequisites()
    validate_reviewed_updater_prerequisites(reviewed, updater_prerequisite)
    prospective_sha = reviewed_nginx_preview_digest(
        args.domain, args.office_cidr, args.tls_cert, args.tls_key
    )
    if (
        prospective_sha
        != reviewed["hostParameters"]["expectedNginxExpandedConfigSha256"]
    ):
        fail("prospective Nginx graph differs from the externally reviewed digest")
    EVIDENCE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chown(EVIDENCE, 0, 0)
    os.chmod(EVIDENCE, 0o700)
    _updater_uid, updater_gid = _updater_identity()
    _exact_owned_path(
        ROOT_STATE,
        uid=0,
        gid=updater_gid,
        mode=0o750,
        directory=True,
    )
    root_directory(EVIDENCE)
    root_directory(ROOT_STATE)
    transaction_dir = EVIDENCE / transaction
    if not transaction_dir.exists():
        transaction_dir.mkdir(mode=0o700)
        os.chown(transaction_dir, 0, 0)
        os.chmod(transaction_dir, 0o700)
        fsync_directory(EVIDENCE)
    else:
        root_directory(transaction_dir)
    reviewed_manifest_snapshot = snapshot_reviewed_source_manifest(
        transaction_dir,
        args.source_manifest,
        reviewed_sha,
    )
    plan_path = transaction_dir / "plan.json"
    recorded_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if plan_path.exists():
        try:
            prior_plan = strict_json_document(
                plan_path.read_bytes(), "existing host preparation plan"
            )
            recorded_at = str(prior_plan["createdAtUtc"])
        except (OSError, KeyError) as exc:
            raise PreparationError("existing host preparation plan is malformed") from exc
    source_snapshot = snapshot_sources(
        transaction_dir, reviewed, resume_authorized=resume_authority is not None
    )
    trusted_installer_payloads = capture_trusted_installer_snapshot_payloads(
        source_snapshot, reviewed
    )
    validate_trusted_installer_target_preimages(
        reviewed,
        trusted_installer_payloads,
        resume_authorized=resume_authority is not None,
    )
    server_environment_snapshot = snapshot_server_environment(
        transaction_dir,
        args.expected_server_environment_sha256,
        resume_authorized=resume_authority is not None,
    )
    storage_terminal = nvme_storage_terminal()
    plan = {
        "approvalReference": args.approval_reference,
        "createdAtUtc": recorded_at,
        "entryEnabled": False,
        "expectedPreparerSha256": args.expected_preparer_sha256,
        "kind": "uten-imp-internal-test-host-preparation-plan",
        "parameters": {
            "allowedSignersSha256": args.expected_allowed_signers_sha256,
            "domain": args.domain,
            "expectedNginxExpandedConfigSha256": reviewed["hostParameters"][
                "expectedNginxExpandedConfigSha256"
            ],
            "officeCidr": args.office_cidr,
            "serverEnvironmentPreimageSha256": args.expected_server_environment_preimage_sha256,
            "tlsCertificateSha256": stable_root_digest(args.tls_cert, mode=0o644),
            "tlsKeySha256": stable_root_digest(args.tls_key, mode=0o600),
            "serverEnvironmentSha256": args.expected_server_environment_sha256,
            "updaterVenvInventorySha256": args.expected_updater_venv_inventory_sha256,
        },
        "schemaVersion": 1,
        "sourceSha256": reviewed["sourceSha256"],
        "targetPreimageSha256": reviewed["targetPreimageSha256"],
        "sourceSnapshotPath": str(transaction_dir / "source-snapshot"),
        "serverEnvironmentSnapshotPath": str(server_environment_snapshot),
        "serverEnvironmentSnapshotSha256": sha256_file(server_environment_snapshot),
        "reviewedSourceManifestPath": str(reviewed_manifest_snapshot),
        "reviewedSourceManifestSha256": reviewed_sha,
        "storageTerminal": storage_terminal,
        "status": "APPROVED_ENTRY_CLOSED",
        "transactionId": transaction,
    }
    if plan_path.exists():
        if plan_path.read_bytes() != canonical(plan):
            fail("host preparation plan differs from the durable transaction")
    else:
        atomic(plan_path, canonical(plan), 0o600)
    authorize_host_mutation(
        transaction_dir, reviewed_sha, reviewed, source_snapshot
    )
    environment_bridge = install_internal_server_environment(
        transaction_dir=transaction_dir,
        snapshot=server_environment_snapshot,
        validator=source_snapshot["environmentValidatorSha256"],
        expected_preimage_sha=args.expected_server_environment_preimage_sha256,
        expected_sha=args.expected_server_environment_sha256,
        domain=args.domain,
        cidr=args.office_cidr,
        approval_reference=args.approval_reference,
        resume_authorized=resume_authority is not None,
    )
    install_trusted_installer_assets(
        reviewed,
        trusted_installer_payloads,
        resume_authorized=resume_authority is not None,
    )
    executable_sources = {
        "activationEntrypointSha256",
        "databaseCommissionerSha256",
        "entryWatchdogScriptSha256",
        "environmentValidatorSha256",
        "migratorEnvironmentValidatorSha256",
        "nginxReadinessGateSha256",
        "recoveryEntrypointSha256",
        "recoveryCommitBootVerifierSha256",
        "recoveryIngressGateSha256",
        "storageValidatorSha256",
        "updaterEntrypointSha256",
        "watchdogScriptSha256",
    }
    for key in SOURCES:
        if key in TRUSTED_INSTALLER_SOURCE_KEYS:
            continue
        source = source_snapshot[key]
        mode = 0o755 if key in executable_sources else 0o644
        install_source(
            source,
            TARGETS[key],
            mode,
            reviewed["targetPreimageSha256"][key],
            resume_authorized=resume_authority is not None,
        )
    legacy_nginx_handoff = handoff_legacy_nginx(
        transaction_dir,
        reviewed["targetPreimageSha256"]["legacyNginxConfigSha256"],
        resume_authorized=resume_authority is not None,
    )
    ensure_migrator_environment()
    backup_containment = close_legacy_backup_units(transaction_dir)
    evidence_layout = ensure_root_runtime_directories(transaction_dir)
    storage_authority_sha = storage_terminal["storageAuthoritySha256"]
    attachment_layout = ensure_attachment_layout(
        transaction_dir, storage_authority_sha
    )
    nginx_payload = rendered_nginx_payload(
        args.domain,
        args.office_cidr,
        args.tls_cert,
        args.tls_key,
        source_snapshot["nginxTemplateSha256"].read_bytes(),
    )
    if os.path.lexists(NGINX_TARGET):
        root_file(NGINX_TARGET)
        live_sha = sha256_file(NGINX_TARGET)
        desired_sha = hashlib.sha256(nginx_payload).hexdigest()
        if live_sha == desired_sha:
            if (
                resume_authority is None
                and reviewed["targetPreimageSha256"]["nginxConfigSha256"]
                != live_sha
            ):
                fail("first host preparation did not authorize the desired Nginx preimage")
        else:
            expected = reviewed["targetPreimageSha256"]["nginxConfigSha256"]
            if expected is None or live_sha != expected:
                fail("live internal Nginx config differs from the authorized preimage")
            atomic(NGINX_TARGET, nginx_payload, 0o644, replace=True)
    else:
        if reviewed["targetPreimageSha256"]["nginxConfigSha256"] is not None:
            fail("authorized Nginx preimage is unexpectedly absent")
        atomic(NGINX_TARGET, nginx_payload, 0o644)
    NGINX_LINK.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    root_directory(NGINX_LINK.parent)
    if os.path.lexists(NGINX_LINK):
        if not NGINX_LINK.is_symlink() or NGINX_LINK.resolve(strict=True) != NGINX_TARGET:
            fail("existing internal Nginx enabled path differs")
    else:
        os.symlink(str(NGINX_TARGET), NGINX_LINK)
        fsync_directory(NGINX_LINK.parent)
    expanded_nginx = unique_nginx_include()
    expanded_nginx_sha = hashlib.sha256(expanded_nginx).hexdigest()
    if (
        expanded_nginx_sha
        != reviewed["hostParameters"]["expectedNginxExpandedConfigSha256"]
    ):
        fail("effective Nginx graph differs from the externally reviewed digest")
    run(["/usr/bin/systemctl", "daemon-reload"])
    validate_loaded_systemd_contract()
    run(
        [
            "/usr/bin/systemctl",
            "enable",
            "uten-imp-recovery-commit-verifier.service",
        ]
    )
    if _systemd_value(
        "uten-imp-recovery-commit-verifier.service", "UnitFileState"
    ) != "enabled":
        fail("recovery commit boot verifier is not persistently enabled")
    entry_closed()
    updater_substrate = validate_common_updater_substrate(
        transaction_dir, updater_prerequisite
    )
    run([str(TARGETS["environmentValidatorSha256"]), str(SERVER_ENV)])
    validate_server_environment(
        args.domain,
        args.office_cidr,
        args.expected_server_environment_sha256,
    )
    contract = {
        "attachmentLayoutReceiptPath": attachment_layout["receiptPath"],
        "attachmentLayoutReceiptSha256": attachment_layout["receiptSha256"],
        "activationEntrypointSha256": sha256_file(
            TARGETS["activationEntrypointSha256"]
        ),
        "backupContainmentReceiptPath": backup_containment["path"],
        "backupContainmentReceiptSha256": backup_containment["sha256"],
        "contractId": "uten-imp-internal-test-runtime-v1",
        "databaseCommissionerSha256": sha256_file(TARGETS["databaseCommissionerSha256"]),
        "databaseCommissionerUnitSha256": sha256_file(
            TARGETS["databaseCommissionerUnitSha256"]
        ),
        "databaseRecoveryVerifierSha256": sha256_file(TARGETS["databaseRecoveryVerifierSha256"]),
        "deploymentProfile": "internal-test-local-v1",
        "internalDomain": args.domain,
        "environmentValidatorSha256": sha256_file(TARGETS["environmentValidatorSha256"]),
        "entryWatchdogScriptSha256": sha256_file(
            TARGETS["entryWatchdogScriptSha256"]
        ),
        "entryWatchdogServiceUnitSha256": sha256_file(
            TARGETS["entryWatchdogServiceUnitSha256"]
        ),
        "entryWatchdogTimerUnitSha256": sha256_file(
            TARGETS["entryWatchdogTimerUnitSha256"]
        ),
        "evidenceLayoutReceiptPath": evidence_layout["path"],
        "evidenceLayoutReceiptSha256": evidence_layout["sha256"],
        "migrationAuthorizationHelperSha256": sha256_file(
            TARGETS["migrationAuthorizationHelperSha256"]
        ),
        "legacyNginxArchivePath": legacy_nginx_handoff["archivePath"],
        "legacyNginxArchiveSha256": legacy_nginx_handoff["archiveSha256"],
        "legacyNginxHandoffReceiptPath": legacy_nginx_handoff["path"],
        "legacyNginxHandoffReceiptSha256": legacy_nginx_handoff["sha256"],
        "migrationServiceUnitSha256": sha256_file(
            TARGETS["migrationServiceUnitSha256"]
        ),
        "migratorEnvironmentValidatorSha256": sha256_file(
            TARGETS["migratorEnvironmentValidatorSha256"]
        ),
        "nginxConfigSha256": sha256_file(NGINX_TARGET),
        "nginxExpandedConfigSha256": expanded_nginx_sha,
        "nginxReadinessGateSha256": sha256_file(
            TARGETS["nginxReadinessGateSha256"]
        ),
        "nginxSystemdDropinSha256": sha256_file(
            TARGETS["nginxSystemdDropinSha256"]
        ),
        "postgresInternalTestConfigSha256": sha256_file(
            TARGETS["postgresInternalTestConfigSha256"]
        ),
        "postgresHbaSha256": sha256_file(TARGETS["postgresHbaSha256"]),
        "postgresStorageDropinSha256": sha256_file(
            TARGETS["postgresStorageDropinSha256"]
        ),
        "recoveryEntrypointSha256": sha256_file(
            TARGETS["recoveryEntrypointSha256"]
        ),
        "recordedAtUtc": recorded_at,
        "releaseGuardSha256": sha256_file(TARGETS["releaseGuardSha256"]),
        "releaseUpdaterSha256": sha256_file(TARGETS["releaseUpdaterSha256"]),
        "runtimeBootVerifierSha256": sha256_file(TARGETS["runtimeBootVerifierSha256"]),
        "recoveryCommitBootVerifierSha256": sha256_file(
            TARGETS["recoveryCommitBootVerifierSha256"]
        ),
        "recoveryCommitBootUnitSha256": sha256_file(
            TARGETS["recoveryCommitBootUnitSha256"]
        ),
        "recoveryIngressGateSha256": sha256_file(
            TARGETS["recoveryIngressGateSha256"]
        ),
        "schemaVersion": 1,
        "serverEnvironmentBridgeReceiptPath": environment_bridge["path"],
        "serverEnvironmentBridgeReceiptSha256": environment_bridge["sha256"],
        "serverEnvironmentSha256": sha256_file(SERVER_ENV),
        "serviceUnitSha256": sha256_file(TARGETS["serviceUnitSha256"]),
        "storageBootVerifierSha256": sha256_file(TARGETS["storageBootVerifierSha256"]),
        "storageMountObserverSha256": sha256_file(
            TARGETS["storageMountObserverSha256"]
        ),
        "storageObserverUnitSha256": sha256_file(
            TARGETS["storageObserverUnitSha256"]
        ),
        "storageValidatorSha256": sha256_file(TARGETS["storageValidatorSha256"]),
        "tlsCertificatePath": str(args.tls_cert),
        "tlsCertificateSha256": stable_root_digest(args.tls_cert, mode=0o644),
        "tlsKeyPath": str(args.tls_key),
        "tlsKeySha256": stable_root_digest(args.tls_key, mode=0o600),
        "storageAuthoritySha256": storage_authority_sha,
        "storageCompleteReceiptPath": storage_terminal["completePath"],
        "storageCompleteReceiptSha256": storage_terminal["completeSha256"],
        "storageLateFinalizationReceiptPath": storage_terminal[
            "lateFinalizationPath"
        ],
        "storageLateFinalizationReceiptSha256": storage_terminal[
            "lateFinalizationSha256"
        ],
        "updaterReleaseGuardSha256": sha256_file(TARGETS["updaterReleaseGuardSha256"]),
        "updaterAllowedSignersSha256": updater_substrate[
            "allowedSignersSha256"
        ],
        "stableAllowedSignersSha256": updater_substrate[
            "allowedSignersSha256"
        ],
        "updaterEntrypointSha256": sha256_file(
            TARGETS["updaterEntrypointSha256"]
        ),
        "updaterEnvironmentValidatorSha256": sha256_file(
            TARGETS["updaterEnvironmentValidatorSha256"]
        ),
        "updaterOssIoSha256": sha256_file(TARGETS["updaterOssIoSha256"]),
        "updaterServiceUnitSha256": sha256_file(
            TARGETS["updaterServiceUnitSha256"]
        ),
        "updaterSubstrateReceiptPath": updater_substrate["path"],
        "updaterSubstrateReceiptSha256": updater_substrate["sha256"],
        "updaterTimerUnitSha256": sha256_file(
            TARGETS["updaterTimerUnitSha256"]
        ),
        "updaterVenvInventorySha256": updater_substrate[
            "updaterVenvInventorySha256"
        ],
        "updaterRequirementsLockSha256": sha256_file(
            TARGETS["updaterRequirementsLockSha256"]
        ),
        "watchdogScriptSha256": sha256_file(TARGETS["watchdogScriptSha256"]),
        "watchdogServiceUnitSha256": sha256_file(
            TARGETS["watchdogServiceUnitSha256"]
        ),
        "watchdogTimerUnitSha256": sha256_file(
            TARGETS["watchdogTimerUnitSha256"]
        ),
        "wheelhouseSupplyChainSha256": sha256_file(
            TARGETS["wheelhouseSupplyChainSha256"]
        ),
    }
    if os.path.lexists(CONTRACT):
        root_file(CONTRACT, mode=0o600)
        if CONTRACT.read_bytes() != canonical(contract):
            fail("existing runtime contract differs from the resumed preparation")
    else:
        atomic(CONTRACT, canonical(contract), 0o600)
    mutation_terminal = commit_host_mutation_authority(transaction_dir, reviewed_sha)
    mutation_terminal_path = mutation_authority_path(transaction_dir)
    root_file(mutation_terminal_path, mode=0o600)
    if mutation_terminal_path.read_bytes() != canonical(mutation_terminal):
        fail("host mutation terminal differs from the authorized bytes")
    receipt = {
        "contractSha256": sha256_file(CONTRACT),
        "entryEnabled": False,
        "kind": "uten-imp-internal-test-host-preparation-receipt",
        "mutationAuthorityPath": str(mutation_terminal_path),
        "mutationAuthoritySha256": sha256_file(mutation_terminal_path),
        "nginxEnabledLink": str(NGINX_LINK),
        "nginxEnabledTargetSha256": sha256_file(NGINX_TARGET),
        "planSha256": sha256_file(transaction_dir / "plan.json"),
        "productionAuthority": False,
        "schemaVersion": 1,
        "status": "COMMITTED_ENTRY_CLOSED",
        "transactionId": transaction,
    }
    complete = transaction_dir / "complete.json"
    if complete.exists():
        if complete.read_bytes() != canonical(receipt):
            fail("existing host preparation receipt differs")
    else:
        atomic(complete, canonical(receipt), 0o600)
    if ACTIVE.exists():
        if ACTIVE.read_bytes() != canonical(receipt):
            fail("another host preparation is already active")
    else:
        atomic(ACTIVE, canonical(receipt), 0o600)
    return receipt


def read_only_preflight(args: argparse.Namespace) -> None:
    """Reject an unsafe request before any persistent preparation write."""

    if os.geteuid() != 0:
        fail("host preparation must run as root")
    if not APPROVAL_RE.fullmatch(args.approval_reference):
        fail("host preparation approval reference is malformed")
    validate_inputs(args.domain, args.office_cidr, args.tls_cert, args.tls_key)
    entry_closed()
    root_file(SERVER_ENV)
    if (
        not SHA256_RE.fullmatch(args.expected_preparer_sha256)
        or sha256_file(Path(__file__).resolve()) != args.expected_preparer_sha256
    ):
        fail("host preparer differs from the independently reviewed digest")
    digest_arguments = (
        args.expected_source_manifest_sha256,
        args.expected_server_environment_sha256,
        args.expected_server_environment_preimage_sha256,
        args.expected_allowed_signers_sha256,
        args.expected_updater_venv_inventory_sha256,
    )
    if any(SHA256_RE.fullmatch(value) is None for value in digest_arguments):
        fail("one or more reviewed preparation digests are malformed")

    reviewed_sha = args.expected_source_manifest_sha256
    transaction = "prepare-internal-runtime-" + reviewed_sha[:16]
    resume_authority = read_mutation_authority(transaction, reviewed_sha)
    resume_authorized = resume_authority is not None or os.path.lexists(ACTIVE)
    reviewed, confirmed_sha = reviewed_source_manifest(
        args, resume_authorized=resume_authorized
    )
    if confirmed_sha != reviewed_sha:
        fail("reviewed host source manifest digest changed during preflight")
    prerequisite = validate_common_updater_prerequisites()
    validate_reviewed_updater_prerequisites(reviewed, prerequisite)
    prospective_systemd_verify(reviewed)

    if resume_authorized:
        pending = EVIDENCE / transaction / "server.env.snapshot"
    else:
        pending = SERVER_ENV_PENDING
        if sha256_file(SERVER_ENV) != args.expected_server_environment_preimage_sha256:
            fail("live server environment differs from the reviewed Phase4 preimage")
    validate_server_environment_path(
        pending,
        args.domain,
        args.office_cidr,
        args.expected_server_environment_sha256,
    )
    prospective_sha = reviewed_nginx_preview_digest(
        args.domain, args.office_cidr, args.tls_cert, args.tls_key
    )
    if prospective_sha != reviewed["hostParameters"]["expectedNginxExpandedConfigSha256"]:
        fail("prospective Nginx graph differs from the externally reviewed digest")


def apply(args: argparse.Namespace) -> dict[str, Any]:
    # The common operation lock is pre-created by the neutral updater substrate.
    # Perform a complete read-only pass before even opening that inode, then
    # repeat the pass while holding it so concurrent drift cannot authorize a
    # plan or any live mutation.
    read_only_preflight(args)
    with operation_lock():
        read_only_preflight(args)
        return _apply_locked(args)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--domain", required=True)
    result.add_argument("--office-cidr", required=True)
    result.add_argument("--tls-cert", required=True, type=Path)
    result.add_argument("--tls-key", required=True, type=Path)
    result.add_argument("--approval-reference", required=True)
    result.add_argument("--expected-preparer-sha256", required=True)
    result.add_argument("--source-manifest", required=True, type=Path)
    result.add_argument("--expected-source-manifest-sha256", required=True)
    result.add_argument("--expected-server-environment-sha256", required=True)
    result.add_argument(
        "--expected-server-environment-preimage-sha256", required=True
    )
    result.add_argument("--expected-allowed-signers-sha256", required=True)
    result.add_argument("--expected-updater-venv-inventory-sha256", required=True)
    return result


def main() -> int:
    try:
        receipt = apply(parser().parse_args())
    except Exception as exc:
        print(f"INTERNAL_TEST_HOST_PREPARATION_NO_GO: {exc}", file=os.sys.stderr)
        return 1
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
