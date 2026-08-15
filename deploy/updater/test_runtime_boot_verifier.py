from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
import tempfile
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


if os.name == "nt":
    sys.modules.setdefault(
        "fcntl",
        types.SimpleNamespace(
            LOCK_EX=2,
            LOCK_NB=4,
            LOCK_UN=8,
            flock=lambda *_args, **_kwargs: None,
        ),
    )
    sys.modules.setdefault(
        "grp",
        types.SimpleNamespace(getgrnam=lambda _name: types.SimpleNamespace(gr_gid=0)),
    )


MODULE_PATH = Path(__file__).with_name("runtime_boot_verifier.py")
SPEC = importlib.util.spec_from_file_location("runtime_boot_verifier_under_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
boot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(boot)

STORAGE_MODULE_PATH = Path(__file__).with_name("storage_boot_verifier.py")
STORAGE_SPEC = importlib.util.spec_from_file_location(
    "storage_boot_verifier_under_test", STORAGE_MODULE_PATH
)
assert STORAGE_SPEC is not None and STORAGE_SPEC.loader is not None
storage = importlib.util.module_from_spec(STORAGE_SPEC)
STORAGE_SPEC.loader.exec_module(storage)


def manifest() -> dict[str, object]:
    return {
        "commitSha": "a" * 40,
        "flywayHeadVersion": "255",
        "flywayMigrationSetSha256": "b" * 64,
        "flywayMigrations": [
            {
                "description": "attachment quarantine",
                "file": "V255__attachment_quarantine.sql",
                "flywayChecksum": 123456789,
                "sha256": "c" * 64,
                "version": "255",
            }
        ],
        "releaseSequence": 7,
        "version": "v2026.08.12-7",
    }


def rows() -> list[dict[str, object]]:
    return [
        {
            "checksum": 123456789,
            "description": "attachment quarantine",
            "installedRank": 255,
            "script": "V255__attachment_quarantine.sql",
            "success": True,
            "type": "SQL",
            "version": "255",
        }
    ]


def live_identity() -> dict[str, object]:
    flyway = boot._canonical_live_flyway(rows(), manifest())
    return {
        **flyway,
        "systemIdentifier": "7523456789012345678",
        "timeline": 4,
    }


def internal_runtime_contract() -> tuple[dict[str, object], str]:
    return (
        {"contractId": "uten-imp-internal-test-runtime-v1"},
        "9" * 64,
    )


class CanonicalDatabaseTests(unittest.TestCase):
    def test_exact_signed_flyway_projection_is_accepted(self) -> None:
        value = boot._canonical_live_flyway(rows(), manifest())
        self.assertEqual(value["headVersion"], 255)
        self.assertEqual(value["successfulMigrationCount"], 1)
        self.assertRegex(value["canonicalHistorySha256"], r"^[0-9a-f]{64}$")

    def test_checksum_drift_is_rejected(self) -> None:
        changed = rows()
        changed[0]["checksum"] = 123456790
        with self.assertRaisesRegex(boot.BootVerificationError, "version/script/checksum"):
            boot._canonical_live_flyway(changed, manifest())

    def test_failed_or_extra_migration_is_rejected(self) -> None:
        failed = rows()
        failed[0]["success"] = False
        with self.assertRaisesRegex(boot.BootVerificationError, "failed"):
            boot._canonical_live_flyway(failed, manifest())


class RuntimeAuthorityTests(unittest.TestCase):
    def authority(self) -> dict[str, object]:
        return {
            "commitSha": "a" * 40,
            "databaseIdentity": live_identity(),
            "manifestSha256": "d" * 64,
            "releaseSequence": 7,
            "schemaVersion": 1,
            "verifiedAtUtc": "2026-08-12T00:00:00Z",
            "version": "v2026.08.12-7",
        }

    def test_live_database_and_release_must_match_authority(self) -> None:
        boot._validate_runtime_authority(
            self.authority(), manifest(), "d" * 64, live_identity()
        )

    def test_wrong_postgres_system_identifier_is_rejected(self) -> None:
        observed = live_identity()
        observed["systemIdentifier"] = "7523456789012345679"
        with self.assertRaisesRegex(boot.BootVerificationError, "differs"):
            boot._validate_runtime_authority(
                self.authority(), manifest(), "d" * 64, observed
            )

    def test_active_state_must_match_signed_manifest(self) -> None:
        active = {
            "activatedAtUtc": "2026-08-12T00:00:00Z",
            "commitSha": "a" * 40,
            "databaseChanged": True,
            "flywayHeadVersion": "255",
            "flywayMigrationSetSha256": "b" * 64,
            "manifestSha256": "d" * 64,
            "releaseSequence": 7,
            "version": "v2026.08.12-7",
        }
        boot._validate_active(active, manifest(), "d" * 64)
        active["releaseSequence"] = 8
        with self.assertRaisesRegex(boot.BootVerificationError, "differs"):
            boot._validate_active(active, manifest(), "d" * 64)

    def test_internal_active_and_authority_require_runtime_and_acl_binding(self) -> None:
        contract = internal_runtime_contract()
        identity = {
            **live_identity(),
            "roleAclContractSha256": "8" * 64,
        }
        active = {
            "activatedAtUtc": "2026-08-12T00:00:00Z",
            "commitSha": "a" * 40,
            "databaseChanged": False,
            "flywayHeadVersion": "255",
            "flywayMigrationSetSha256": "b" * 64,
            "manifestSha256": "d" * 64,
            "onboardingArchivePath": str(
                boot.INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR
                / "internal-test-db-20260812T120000Z-abcdef123456.json"
            ),
            "onboardingReceiptSha256": "7" * 64,
            "releaseSequence": 7,
            "runtimeContractId": contract[0]["contractId"],
            "runtimeContractSha256": contract[1],
            "version": "v2026.08.12-7",
        }
        authority = {
            "commitSha": "a" * 40,
            "databaseIdentity": identity,
            "manifestSha256": "d" * 64,
            "releaseSequence": 7,
            "runtimeContractId": contract[0]["contractId"],
            "runtimeContractSha256": contract[1],
            "schemaVersion": 1,
            "verifiedAtUtc": "2026-08-12T00:00:00Z",
            "version": "v2026.08.12-7",
        }
        with mock.patch.object(boot, "_require_root_file"), mock.patch.object(
            boot, "_sha256", return_value="7" * 64
        ):
            boot._validate_active(active, manifest(), "d" * 64, contract)
        boot._validate_runtime_authority(
            authority, manifest(), "d" * 64, identity, contract
        )

        for label, changed in (
            ("active", {**active, "runtimeContractSha256": "6" * 64}),
            (
                "authority",
                {**authority, "runtimeContractSha256": "6" * 64},
            ),
        ):
            with self.subTest(label=label), self.assertRaises(
                boot.BootVerificationError
            ), mock.patch.object(boot, "_require_root_file"), mock.patch.object(
                boot, "_sha256", return_value="7" * 64
            ):
                if label == "active":
                    boot._validate_active(changed, manifest(), "d" * 64, contract)
                else:
                    boot._validate_runtime_authority(
                        changed, manifest(), "d" * 64, identity, contract
                    )


class TransactionAuthorizationTests(unittest.TestCase):
    def authorization(self) -> dict[str, object]:
        return {
            "authorizationId": "e" * 32,
            "bootId": "11111111-2222-3333-4444-555555555555",
            "commitSha": "a" * 40,
            "createdAtUtc": datetime.now(timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
            "databaseIdentity": live_identity(),
            "issuerCommandLineSha256": "1" * 64,
            "issuerExecutablePath": "/usr/bin/python3.14",
            "issuerExecutableSha256": "2" * 64,
            "issuerPid": 4242,
            "issuerStartTimeTicks": 123456,
            "manifestSha256": "d" * 64,
            "markerPath": str(boot.ACTIVATION_IN_PROGRESS_MARKER),
            "markerSha256": "f" * 64,
            "mode": "activation",
            "releaseSequence": 7,
            "schemaVersion": 1,
            "version": "v2026.08.12-7",
        }

    @mock.patch.object(boot, "_operation_lock_is_held_by", return_value=True)
    @mock.patch.object(boot, "_validate_authorization_issuer", return_value=4242)
    @mock.patch.object(boot, "_sha256", return_value="f" * 64)
    @mock.patch.object(boot, "_require_root_file")
    @mock.patch.object(
        boot, "_boot_id", return_value="11111111-2222-3333-4444-555555555555"
    )
    def test_one_use_authorization_binds_marker_boot_release_and_database(
        self, *_mocks: mock.Mock
    ) -> None:
        boot._validate_transaction_authorization(
            self.authorization(),
            boot.ACTIVATION_IN_PROGRESS_MARKER,
            manifest(),
            "d" * 64,
            live_identity(),
        )

    @mock.patch.object(boot, "_operation_lock_is_held_by", return_value=False)
    @mock.patch.object(boot, "_validate_authorization_issuer", return_value=4242)
    @mock.patch.object(boot, "_sha256", return_value="f" * 64)
    @mock.patch.object(boot, "_require_root_file")
    @mock.patch.object(
        boot, "_boot_id", return_value="11111111-2222-3333-4444-555555555555"
    )
    def test_authorization_without_live_updater_lock_is_rejected(
        self, *_mocks: mock.Mock
    ) -> None:
        with self.assertRaisesRegex(boot.BootVerificationError, "coordination lock"):
            boot._validate_transaction_authorization(
                self.authorization(),
                boot.ACTIVATION_IN_PROGRESS_MARKER,
                manifest(),
                "d" * 64,
                live_identity(),
            )

    @mock.patch.object(boot, "_operation_lock_is_held_by", return_value=True)
    @mock.patch.object(boot, "_validate_authorization_issuer", return_value=4242)
    @mock.patch.object(boot, "_sha256", return_value="f" * 64)
    @mock.patch.object(boot, "_require_root_file")
    @mock.patch.object(
        boot, "_boot_id", return_value="11111111-2222-3333-4444-555555555555"
    )
    def test_internal_authorization_requires_runtime_and_role_acl_binding(
        self, *_mocks: mock.Mock
    ) -> None:
        contract = internal_runtime_contract()
        authorization = self.authorization()
        authorization["runtimeContractId"] = contract[0]["contractId"]
        authorization["runtimeContractSha256"] = contract[1]
        authorization["databaseIdentity"] = {
            **authorization["databaseIdentity"],
            "roleAclContractSha256": "8" * 64,
        }
        internal_live = {
            **live_identity(),
            "roleAclContractSha256": "8" * 64,
        }
        boot._validate_transaction_authorization(
            authorization,
            boot.ACTIVATION_IN_PROGRESS_MARKER,
            manifest(),
            "d" * 64,
            internal_live,
            contract,
        )
        authorization["runtimeContractSha256"] = "6" * 64
        with self.assertRaisesRegex(boot.BootVerificationError, "runtime contract"):
            boot._validate_transaction_authorization(
                authorization,
                boot.ACTIVATION_IN_PROGRESS_MARKER,
                manifest(),
                "d" * 64,
                internal_live,
                contract,
            )

    def test_authorization_is_atomically_consumed_before_validation(self) -> None:
        if getattr(os, "geteuid", lambda: 1)() != 0:
            self.skipTest("root ownership contract requires root test runtime")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "run"
            directory.mkdir(mode=0o700)
            source = directory / "start-authorization.json"
            source.write_text(json.dumps(self.authorization()), encoding="utf-8")
            source.chmod(0o600)
            with (
                mock.patch.object(boot, "START_AUTHORIZATION_DIR", directory),
                mock.patch.object(boot, "START_AUTHORIZATION", source),
            ):
                value, consumed = boot._consume_start_authorization()
            self.assertFalse(source.exists())
            self.assertTrue(consumed.is_file())
            self.assertEqual(value["authorizationId"], "e" * 32)


class RuntimeModeTests(unittest.TestCase):
    @mock.patch.object(boot.os, "geteuid", return_value=0, create=True)
    @mock.patch.object(boot, "_validate_runtime_authority")
    @mock.patch.object(boot, "_validate_active")
    @mock.patch.object(boot, "_read_root_json")
    @mock.patch.object(boot, "_query_live_database", return_value=live_identity())
    @mock.patch.object(
        boot,
        "_verified_current_release",
        return_value=(Path("/opt/uten-imp/releases/v2026.08.12-7"), manifest(), "d" * 64),
    )
    @mock.patch.object(boot, "_load_release_guard", return_value=object())
    @mock.patch.object(boot, "_verify_data_mount")
    @mock.patch.object(boot, "_require_root_directory")
    @mock.patch.object(boot, "_lexists", return_value=False)
    def test_normal_boot_requires_active_and_runtime_authority(
        self,
        _lexists: mock.Mock,
        _root: mock.Mock,
        _storage: mock.Mock,
        _guard: mock.Mock,
        _release: mock.Mock,
        _database: mock.Mock,
        read_json: mock.Mock,
        validate_active: mock.Mock,
        validate_authority: mock.Mock,
        _euid: mock.Mock,
    ) -> None:
        read_json.side_effect = [{"active": True}, {"authority": True}]
        with mock.patch.object(
            boot, "_internal_test_runtime_contract", return_value=None
        ):
            boot.verify_runtime_boot()
        self.assertEqual(
            [call.args[0] for call in read_json.call_args_list],
            [boot.ACTIVE_STATE, boot.RUNTIME_AUTHORITY],
        )
        validate_active.assert_called_once()
        validate_authority.assert_called_once()

    @mock.patch.object(boot.os, "geteuid", return_value=0, create=True)
    @mock.patch.object(boot, "_require_root_file")
    @mock.patch.object(boot, "_verify_data_mount")
    @mock.patch.object(boot, "_require_root_directory")
    @mock.patch.object(
        boot,
        "_lexists",
        side_effect=lambda path: path == boot.ACTIVATION_FAILURE_MARKER,
    )
    def test_persistent_failure_marker_blocks_before_release_or_database_access(
        self, *_mocks: mock.Mock
    ) -> None:
        with mock.patch.object(boot, "_load_release_guard") as load_guard, self.assertRaisesRegex(
            boot.BootVerificationError, "fail-closed marker"
        ):
            boot.verify_runtime_boot()
        load_guard.assert_not_called()

    @mock.patch.object(boot.os, "geteuid", return_value=0, create=True)
    @mock.patch.object(boot, "_fsync_directory")
    @mock.patch.object(boot, "_validate_transaction_authorization")
    @mock.patch.object(boot, "_consume_start_authorization")
    @mock.patch.object(boot, "_query_live_database", return_value=live_identity())
    @mock.patch.object(
        boot,
        "_verified_current_release",
        return_value=(Path("/opt/uten-imp/releases/v2026.08.12-7"), manifest(), "d" * 64),
    )
    @mock.patch.object(boot, "_load_release_guard", return_value=object())
    @mock.patch.object(boot, "_verify_data_mount")
    @mock.patch.object(boot, "_require_root_directory")
    @mock.patch.object(
        boot,
        "_lexists",
        side_effect=lambda path: path == boot.ACTIVATION_IN_PROGRESS_MARKER,
    )
    def test_transaction_boot_consumes_exactly_one_authorization(
        self,
        _lexists: mock.Mock,
        _root: mock.Mock,
        _storage: mock.Mock,
        _guard: mock.Mock,
        _release: mock.Mock,
        _database: mock.Mock,
        consume: mock.Mock,
        validate: mock.Mock,
        fsync: mock.Mock,
        _euid: mock.Mock,
    ) -> None:
        consumed = mock.MagicMock()
        consume.return_value = ({"authorizationId": "e" * 32}, consumed)
        with mock.patch.object(
            boot, "_internal_test_runtime_contract", return_value=None
        ):
            boot.verify_runtime_boot()
        validate.assert_called_once()
        consumed.unlink.assert_called_once_with()
        fsync.assert_called_once_with(boot.START_AUTHORIZATION_DIR)

    @mock.patch.object(boot.os, "geteuid", return_value=0, create=True)
    @mock.patch.object(boot, "_validate_runtime_authority")
    @mock.patch.object(boot, "_validate_active")
    @mock.patch.object(boot, "_read_root_json")
    @mock.patch.object(boot, "_query_live_database", return_value=live_identity())
    @mock.patch.object(
        boot,
        "_verified_current_release",
        return_value=(Path("/opt/uten-imp/releases/v2026.08.12-7"), manifest(), "d" * 64),
    )
    @mock.patch.object(boot, "_load_release_guard", return_value=object())
    @mock.patch.object(boot, "_verify_data_mount")
    @mock.patch.object(boot, "_require_root_directory")
    @mock.patch.object(boot, "_lexists", return_value=False)
    def test_normal_internal_boot_threads_contract_through_every_gate(
        self,
        _lexists: mock.Mock,
        _root: mock.Mock,
        _storage: mock.Mock,
        _guard: mock.Mock,
        _release: mock.Mock,
        query_database: mock.Mock,
        read_json: mock.Mock,
        validate_active: mock.Mock,
        validate_authority: mock.Mock,
        _euid: mock.Mock,
    ) -> None:
        contract = internal_runtime_contract()
        read_json.side_effect = [{"active": True}, {"authority": True}]
        with mock.patch.object(
            boot, "_internal_test_runtime_contract", return_value=contract
        ):
            boot.verify_runtime_boot()
        query_database.assert_called_once_with(
            manifest(), require_internal_role_acl=True
        )
        self.assertEqual(validate_active.call_args.args[-1], contract)
        self.assertEqual(validate_authority.call_args.args[-1], contract)


class StorageAuthorityTests(unittest.TestCase):
    def authority(self) -> dict[str, object]:
        return {
            "dataFilesystem": "ext4",
            "dataSource": "/dev/md0",
            "dataUuid": "11111111-2222-3333-4444-555555555555",
            "minimumFreeBytes": 2 * 1024**3,
            "minimumFreeInodes": 100000,
            "mountPoint": "/data",
            "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],
            "schemaVersion": 2,
        }

    def completed(self, line: str) -> types.SimpleNamespace:
        return types.SimpleNamespace(returncode=0, stdout=line)

    @mock.patch.object(storage.os, "geteuid", return_value=0, create=True)
    @mock.patch.object(storage.os, "statvfs", create=True)
    @mock.patch.object(storage.subprocess, "run")
    @mock.patch.object(storage, "_read_authority")
    @mock.patch.object(storage, "_verify_postgres_data_directory")
    def test_storage_uuid_options_and_reserve_are_rechecked_on_every_boot(
        self,
        _pgdata: mock.Mock,
        read_json: mock.Mock,
        run: mock.Mock,
        statvfs: mock.Mock,
        _euid: mock.Mock,
    ) -> None:
        read_json.return_value = self.authority()
        run.return_value = self.completed(
            "/data /dev/md0 ext4 rw,nodev,nosuid,noexec 11111111-2222-3333-4444-555555555555\n"
        )
        statvfs.return_value = types.SimpleNamespace(
            f_bavail=20_000_000,
            f_frsize=4096,
            f_blocks=100_000_000,
            f_favail=2_000_000,
        )
        storage.verify_storage_boot()

    @mock.patch.object(storage.os, "geteuid", return_value=0, create=True)
    @mock.patch.object(storage.os, "statvfs", create=True)
    @mock.patch.object(storage.subprocess, "run")
    @mock.patch.object(storage, "_read_authority")
    @mock.patch.object(storage, "_verify_postgres_data_directory")
    def test_wrong_storage_uuid_fails_closed(
        self,
        _pgdata: mock.Mock,
        read_json: mock.Mock,
        run: mock.Mock,
        statvfs: mock.Mock,
        _euid: mock.Mock,
    ) -> None:
        read_json.return_value = self.authority()
        run.return_value = self.completed(
            "/data /dev/md0 ext4 rw,nodev,nosuid,noexec aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n"
        )
        with self.assertRaisesRegex(storage.StorageBootError, "differs"):
            storage.verify_storage_boot()
        statvfs.assert_not_called()

    @mock.patch.object(storage.os, "geteuid", return_value=0, create=True)
    @mock.patch.object(storage.os, "statvfs", create=True)
    @mock.patch.object(storage.subprocess, "run")
    @mock.patch.object(storage, "_read_authority")
    @mock.patch.object(storage, "_verify_postgres_data_directory")
    def test_different_md_device_fails_even_when_uuid_matches(
        self,
        _pgdata: mock.Mock,
        read_json: mock.Mock,
        run: mock.Mock,
        statvfs: mock.Mock,
        _euid: mock.Mock,
    ) -> None:
        read_json.return_value = self.authority()
        run.return_value = self.completed(
            "/data /dev/md1 ext4 rw,nodev,nosuid,noexec 11111111-2222-3333-4444-555555555555\n"
        )
        with self.assertRaisesRegex(storage.StorageBootError, "differs"):
            storage.verify_storage_boot()
        statvfs.assert_not_called()

    @mock.patch.object(storage, "_postgres_identity")
    @mock.patch.object(storage.subprocess, "run")
    @mock.patch.object(Path, "is_symlink", return_value=False)
    @mock.patch.object(Path, "lstat")
    @mock.patch.object(Path, "stat")
    def test_postgres_effective_data_directory_is_pinned_before_start(
        self,
        path_stat: mock.Mock,
        path_lstat: mock.Mock,
        _is_symlink: mock.Mock,
        run: mock.Mock,
        postgres_identity: mock.Mock,
    ) -> None:
        run.return_value = self.completed(
            "data_directory = '/data/postgresql/16/main'\n"
        )
        postgres_identity.return_value = types.SimpleNamespace(pw_uid=116, pw_gid=123)
        safe = types.SimpleNamespace(
            st_dev=42,
            st_uid=116,
            st_gid=123,
            st_mode=stat.S_IFDIR | 0o700,
        )
        path_stat.return_value = safe
        path_lstat.return_value = safe
        storage._verify_postgres_data_directory()
        run.assert_called_once()

    @mock.patch.object(storage.subprocess, "run")
    def test_postgres_root_disk_data_directory_fails_closed(
        self, run: mock.Mock
    ) -> None:
        run.return_value = self.completed(
            "data_directory = /var/lib/postgresql/16/main\n"
        )
        with self.assertRaisesRegex(storage.StorageBootError, "outside commissioned"):
            storage._verify_postgres_data_directory()

    @mock.patch.object(boot, "_stable_python_module")
    def test_runtime_gate_delegates_to_the_pinned_storage_verifier(
        self,
        stable_module: mock.Mock,
    ) -> None:
        module = types.SimpleNamespace(verify_storage_boot=mock.Mock())
        stable_module.return_value = module
        boot._verify_data_mount()
        stable_module.assert_called_once_with(
            boot.STABLE_STORAGE_VERIFIER,
            expected_sha256=boot.STORAGE_VERIFIER_SHA256,
            module_name="uten_imp_storage_boot_verifier",
        )
        module.verify_storage_boot.assert_called_once_with()


class StaticOrderingContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.updater = Path(__file__).with_name("release_updater.py").read_text(
            encoding="utf-8"
        )
        cls.phase3 = (Path(__file__).parents[1] / "setup/phase3-runtime.sh").read_text(
            encoding="utf-8"
        )
        cls.phase4 = (Path(__file__).parents[1] / "setup/phase4-updater-nginx.sh").read_text(
            encoding="utf-8"
        )
        cls.unit = (Path(__file__).parents[1] / "systemd/uten-imp.service.example").read_text(
            encoding="utf-8"
        )
        cls.postgres_dropin = (
            Path(__file__).parents[1]
            / "systemd/postgresql-uten-imp-storage.conf.example"
        ).read_text(encoding="utf-8")

    def function_source(self, name: str, next_name: str) -> str:
        start = self.updater.index(f"def {name}(")
        end = self.updater.index(f"def {next_name}(", start)
        return self.updater[start:end]

    def test_activation_commits_authority_before_ingress(self) -> None:
        body = self.function_source("activate_release", "parser")
        migration = body.index("run_migration_unit(migration_authorization_nonce)")
        authorized = body.index("start_application_authorized(", migration)
        authority = body.index("write_runtime_authority(", authorized)
        commit = body.index("commit_boot_enablement(", authority)
        ingress = body.index('start_unit("nginx.service")', commit)
        self.assertLess(migration, authorized)
        self.assertLess(authorized, authority)
        self.assertLess(authority, commit)
        self.assertLess(commit, ingress)

    def test_recovery_commits_and_archives_markers_before_ingress(self) -> None:
        body = self.function_source("finish_activation_recovery", "recover_assess")
        authorized = body.index("start_application_authorized(")
        authority = body.index("write_runtime_authority(", authorized)
        progress_archive = body.index("recovery-in-progress.completed.json", authority)
        boot_archive = body.index("boot-enablement.recovery.json", progress_archive)
        ingress = body.index('start_unit("nginx.service")', boot_archive)
        self.assertLess(authorized, authority)
        self.assertLess(authority, progress_archive)
        self.assertLess(progress_archive, boot_archive)
        self.assertLess(boot_archive, ingress)

    def test_runtime_and_storage_contracts_are_installed(self) -> None:
        self.assertIn(
            "ExecStartPre=+/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/runtime_boot_verifier.py",
            self.unit,
        )
        self.assertIn("storage-authority.json", self.phase3)
        self.assertIn("--expected-data-source", self.phase3)
        self.assertIn("--expected-data-uuid", self.phase3)
        self.assertIn("--storage-approval-reference", self.phase3)
        self.assertIn("--confirm-storage-authority", self.phase3)
        self.assertIn('"schemaVersion": 2', self.phase3)
        self.assertIn("COMMISSION $storage_commissioning_mode /data:", self.phase3)
        self.assertIn("existing-host storage commissioning requires inactive", self.phase3)
        self.assertIn("existing-host storage commissioning requires disabled", self.phase3)
        self.assertIn("atomic_install_root_file", self.phase3)
        self.assertIn('sync -f "$temporary_file"', self.phase3)
        self.assertIn('mv -fT -- "$temporary_file" "$target_file"', self.phase3)
        self.assertLess(
            self.phase3.index("Publish the PostgreSQL fail-closed pre-start gate"),
            self.phase3.index("Pin the persistent /data identity"),
        )
        self.assertIn(
            "existing PostgreSQL storage drop-in differs from the reviewed resumable gate",
            self.phase3,
        )
        self.assertIn("RUNTIME_BOOT_VERIFIER_SOURCE", self.phase4)
        self.assertIn("RUNTIME_BOOT_VERIFIER_SHA256", self.phase4)
        self.assertIn("STORAGE_BOOT_VERIFIER_SOURCE", self.phase4)
        self.assertIn("atomic_install_root_file", self.phase4)
        self.assertIn("BindsTo=data.mount", self.postgres_dropin)
        self.assertIn(
            "ExecStartPre=+/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/storage_boot_verifier.py",
            self.postgres_dropin,
        )


class StableModuleExecutionTest(unittest.TestCase):
    def test_executes_the_verified_bytes_even_if_the_path_changes_after_capture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guard.py"
            verified = b"VALUE = 'verified'\n"
            path.write_bytes(verified)

            def capture(*_args, **_kwargs):
                path.write_bytes(b"VALUE = 'path-replaced'\n")
                return verified

            with mock.patch.object(boot, "_stable_root_bytes", side_effect=capture):
                module = boot._stable_python_module(
                    path,
                    expected_sha256=boot.hashlib.sha256(verified).hexdigest(),
                    module_name="verified_bytes_only",
                )
            self.assertEqual("verified", module.VALUE)
            self.assertIn(b"path-replaced", path.read_bytes())

    def test_digest_mismatch_is_rejected_before_any_module_code_runs(self) -> None:
        payload = b"raise AssertionError('must not execute')\n"
        with mock.patch.object(boot, "_stable_root_bytes", return_value=payload):
            with self.assertRaisesRegex(boot.BootVerificationError, "reviewed digest"):
                boot._stable_python_module(
                    Path("/root/guard.py"),
                    expected_sha256="0" * 64,
                    module_name="digest_mismatch",
                )


class InternalTestTlsContractTest(unittest.TestCase):
    def fixture(self, directory: str) -> tuple[Path, Path, Path, dict[str, object]]:
        tls_root = Path(directory) / "tls"
        tls_root.mkdir()
        certificate = tls_root / "internal-fullchain.pem"
        key = tls_root / "internal-privkey.pem"
        certificate.write_bytes(b"certificate-bytes")
        key.write_bytes(b"private-key-bytes")
        value: dict[str, object] = {
            "internalDomain": "erp.office.example.invalid",
            "tlsCertificatePath": str(certificate),
            "tlsCertificateSha256": boot.hashlib.sha256(certificate.read_bytes()).hexdigest(),
            "tlsKeyPath": str(key),
            "tlsKeySha256": boot.hashlib.sha256(key.read_bytes()).hexdigest(),
        }
        return tls_root, certificate, key, value

    @staticmethod
    def openssl_result(arguments: list[str], *, san: bytes, chain_ok: bool = True):
        if "subjectAltName" in arguments:
            stdout = san
            returncode = 0
        elif arguments[1] == "verify":
            stdout = b"/dev/stdin: OK\n" if chain_ok else b""
            returncode = 0 if chain_ok else 2
        elif "-pubkey" in arguments or "-pubout" in arguments:
            stdout = b"same-public-key\n"
            returncode = 0
        else:
            stdout = b""
            returncode = 0
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=b"")

    def invoke(self, directory: str, *, san: bytes, chain_ok: bool = True) -> None:
        tls_root, certificate, key, value = self.fixture(directory)

        def stable(path: Path, **_kwargs):
            if path == certificate:
                return certificate.read_bytes()
            if path == key:
                return key.read_bytes()
            raise AssertionError(path)

        def openssl(arguments, **_kwargs):
            return self.openssl_result(arguments, san=san, chain_ok=chain_ok)

        with mock.patch.object(boot, "INTERNAL_TEST_TLS_ROOT", tls_root), mock.patch.object(
            boot, "_stable_root_bytes", side_effect=stable
        ), mock.patch.object(
            boot, "_require_root_directory"
        ), mock.patch.object(boot.subprocess, "run", side_effect=openssl):
            boot._validate_internal_test_tls(value)

    def test_exact_dns_san_and_valid_chain_are_required(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            self.invoke(
                directory,
                san=(
                    b"X509v3 Subject Alternative Name:\n"
                    b"    DNS:erp.office.example.invalid\n"
                ),
            )

    def test_cn_only_wrong_san_and_untrusted_chain_fail_closed(self) -> None:
        cases = (
            (b"subject=CN=erp.office.example.invalid\n", True),
            (b"X509v3 Subject Alternative Name:\n    DNS:other.example.invalid\n", True),
            (
                b"X509v3 Subject Alternative Name:\n    DNS:erp.office.example.invalid\n",
                False,
            ),
        )
        for san, chain_ok in cases:
            with self.subTest(san=san, chain_ok=chain_ok), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(boot.BootVerificationError):
                    self.invoke(directory, san=san, chain_ok=chain_ok)


if __name__ == "__main__":
    unittest.main()
