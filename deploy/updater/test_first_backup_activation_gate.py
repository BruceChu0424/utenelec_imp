#!/usr/bin/env python3
"""Focused tests for the one-use internal-test first-backup activation gate."""

from __future__ import annotations

import copy
import hashlib
import inspect
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_updater as updater  # noqa: E402


class FirstBackupActivationGateTest(unittest.TestCase):
    VERSION = "v2026.08.14-1"
    TRANSACTION_ID = "internal-test-db-20260814T110000Z-abcdef123456"
    LOCKED_ID = "20260814T120000Z-0123456789abcdef0123456789abcdef"
    CREATED = "2026-08-14T12:05:00Z"
    EXPIRES = "2026-08-15T12:05:00Z"
    IDENTITY = {
        "canonicalHistorySha256": "1" * 64,
        "headVersion": 272,
        "roleAclContractSha256": "2" * 64,
        "signedProjectionSha256": "3" * 64,
        "successfulMigrationCount": 272,
        "systemIdentifier": "7612345678901234567",
        "timeline": 1,
    }

    @staticmethod
    def canonical(value: object) -> bytes:
        return updater._compact_canonical_json_bytes(value)

    def inventory(self, backups: list[dict[str, object]]) -> dict[str, object]:
        normalized = sorted(backups, key=lambda item: str(item["label"]))
        return {
            "backups": backups,
            "inventorySha256": hashlib.sha256(self.canonical(normalized)).hexdigest(),
            "repository": 1,
            "stanza": "uten-imp",
        }

    def locked_receipt(self) -> tuple[dict[str, object], bytes, Path]:
        stop = int(datetime(2026, 8, 14, 12, 0, tzinfo=timezone.utc).timestamp())
        committed = {"label": "20260814-120000F", "stopEpoch": stop, "type": "full"}
        pgbackrest = [
            "/usr/bin/pgbackrest",
            "--config=/etc/pgbackrest.conf",
            "--config-include-path=/etc/pgbackrest/conf.d",
            "--stanza=uten-imp",
        ]
        transaction = {
            "backupCommandSha256": hashlib.sha256(
                self.canonical(
                    pgbackrest
                    + ["--repo=1", "--no-expire-auto", "--type=full", "backup"]
                )
            ).hexdigest(),
            "committedAtUtc": "2026-08-14T12:01:00Z",
            "committedBackup": committed,
            "completedAtUtc": "2026-08-14T12:03:00Z",
            "createdAtUtc": "2026-08-14T11:59:00Z",
            "expireCommandSha256": hashlib.sha256(
                self.canonical(pgbackrest + ["--repo=1", "expire"])
            ).hexdigest(),
            "expireStartedAtUtc": "2026-08-14T12:02:00Z",
            "finalInventory": self.inventory([committed]),
            "job": "repo1",
            "kind": "uten-imp-pgbackrest-backup-transaction",
            "phase": "complete",
            "postBackupInventory": self.inventory([committed]),
            "preInventory": self.inventory([]),
            "repository": 1,
            "schemaVersion": 1,
            "transactionId": self.LOCKED_ID,
            "updatedAtUtc": "2026-08-14T12:02:30Z",
        }
        value = {
            "containsSecrets": False,
            "kind": "uten-imp-pgbackrest-backup-transaction-receipt",
            "schemaVersion": 1,
            "transaction": transaction,
        }
        path = Path("/var/lib/uten-imp-backup-transactions/receipts") / (
            f"repo1-{self.LOCKED_ID}.json"
        )
        return value, self.canonical(value), path

    def onboarding(self) -> dict[str, object]:
        return {
            "completedAtUtc": "2026-08-14T11:05:00Z",
            "databaseIdentity": copy.deepcopy(self.IDENTITY),
            "manifest": {"version": self.VERSION},
            "runtimeContractSha256": "4" * 64,
            "status": "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
            "transactionId": self.TRANSACTION_ID,
            "transactionManifestPath": "/var/lib/unused/transaction-manifest.json",
            "transactionManifestSha256": "5" * 64,
        }

    def receipt(self) -> tuple[dict[str, object], bytes, bytes, Path]:
        _locked, locked_raw, locked_path = self.locked_receipt()
        locked_sha = hashlib.sha256(locked_raw).hexdigest()
        stop = int(datetime(2026, 8, 14, 12, 0, tzinfo=timezone.utc).timestamp())
        check_command = [
            "/usr/bin/pgbackrest",
            "--config=/etc/pgbackrest.conf",
            "--config-include-path=/etc/pgbackrest/conf.d",
            "--stanza=uten-imp",
            "--repo=1",
            "check",
        ]
        value = {
            "backup": {
                "ageSeconds": 300,
                "label": "20260814-120000F",
                "lockedJobReceiptPath": str(locked_path),
                "lockedJobReceiptSha256": locked_sha,
                "lockedJobTransactionId": self.LOCKED_ID,
                "repository": 1,
                "stopEpoch": stop,
                "walStart": "000000010000000000000001",
                "walStop": "000000010000000000000002",
            },
            "check": {
                "commandSha256": hashlib.sha256(
                    self.canonical(check_command)
                ).hexdigest(),
                "completedAtUtc": "2026-08-14T12:04:00Z",
                "passed": True,
                "repository": 1,
            },
            "containsSecrets": False,
            "createdAtUtc": self.CREATED,
            "databaseIdentity": copy.deepcopy(self.IDENTITY),
            "deploymentProfile": "internal-test",
            "evidenceSetSha256": "6" * 64,
            "expiresAt": self.EXPIRES,
            "kind": "uten-imp-internal-test-first-local-backup",
            "localRecoveryOnly": True,
            "onboarding": {
                "path": str(updater.INTERNAL_TEST_ONBOARDING_RECEIPT),
                "sha256": "7" * 64,
                "status": "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
                "transactionId": self.TRANSACTION_ID,
            },
            "producer": {
                "path": str(updater.INTERNAL_TEST_FIRST_BACKUP_PRODUCER),
                "sha256": updater.INTERNAL_TEST_FIRST_BACKUP_PRODUCER_SHA256,
            },
            "productionAuthority": False,
            "restoreVerified": False,
            "schemaVersion": 1,
            "status": "VERIFIED_LOCAL_FIRST_FULL",
            "version": self.VERSION,
        }
        raw = self.canonical(value)
        return value, raw, locked_raw, locked_path

    def terminal(self, receipt_sha: str) -> tuple[dict[str, object], bytes]:
        plan_sha = "8" * 64
        value = {
            "completedAtUtc": "2026-08-14T12:06:00Z",
            "containsSecrets": False,
            "firstBackupReceipt": {
                "path": str(updater.INTERNAL_TEST_FIRST_BACKUP_RECEIPT),
                "sha256": receipt_sha,
            },
            "kind": "uten-imp-internal-test-first-backup-commissioning-receipt",
            "localRecoveryOnly": True,
            "planSha256": plan_sha,
            "productionAuthority": False,
            "repositoryMutationIsIrreversible": True,
            "restoreVerified": False,
            "schemaVersion": 1,
            "status": "COMMISSIONED_LOCAL_FIRST_FULL_ENTRY_CLOSED",
            "transactionPath": (
                "/var/lib/uten-imp-internal-test-backup-commissioner/transactions/"
                + plan_sha
            ),
        }
        return value, self.canonical(value)

    def binding(self) -> tuple[dict[str, object], dict[Path, tuple[dict, bytes]]]:
        receipt, receipt_raw, _locked_raw, _locked_path = self.receipt()
        receipt_sha = hashlib.sha256(receipt_raw).hexdigest()
        terminal, terminal_raw = self.terminal(receipt_sha)
        terminal_archive = updater._first_backup_terminal_archive_path(
            self.TRANSACTION_ID
        )
        value = {
            "archivePath": str(updater._first_backup_archive_path(self.TRANSACTION_ID)),
            "commissionerPath": str(updater.INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER),
            "commissionerSha256": updater.INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_SHA256,
            "databaseIdentity": copy.deepcopy(self.IDENTITY),
            "onboardingReceiptSha256": "7" * 64,
            "onboardingTransactionId": self.TRANSACTION_ID,
            "producerPath": str(updater.INTERNAL_TEST_FIRST_BACKUP_PRODUCER),
            "producerSha256": updater.INTERNAL_TEST_FIRST_BACKUP_PRODUCER_SHA256,
            "receiptSha256": receipt_sha,
            "sourcePath": str(updater.INTERNAL_TEST_FIRST_BACKUP_RECEIPT),
            "terminalReceiptArchivePath": str(terminal_archive),
            "terminalReceiptPath": str(updater.INTERNAL_TEST_FIRST_BACKUP_TERMINAL),
            "terminalReceiptSha256": hashlib.sha256(terminal_raw).hexdigest(),
            "version": self.VERSION,
        }
        archived = {
            Path(value["archivePath"]): (receipt, receipt_raw),
            terminal_archive: (terminal, terminal_raw),
        }
        return value, archived

    def test_strict_canonical_reader_rejects_duplicate_nan_and_noncanonical(self) -> None:
        cases = (
            (b'{"a":1,"a":2}\n', "duplicate"),
            (b'{"a":NaN}\n', "non-finite"),
            (b'{ "a":1 }\n', "canonical"),
        )
        for raw, message in cases:
            with self.subTest(raw=raw), mock.patch.object(
                updater, "read_root_controlled_bytes", return_value=raw
            ), self.assertRaisesRegex(updater.UpdaterError, message):
                updater._read_canonical_root_receipt(Path("/fixed.json"), "fixture")

    def test_full_receipt_validates_locked_job_wal_check_and_expiry(self) -> None:
        value, raw, locked_raw, locked_path = self.receipt()
        pins = {
            "commissionerPath": str(updater.INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER),
            "commissionerSha256": updater.INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_SHA256,
            "producerPath": str(updater.INTERNAL_TEST_FIRST_BACKUP_PRODUCER),
            "producerSha256": updater.INTERNAL_TEST_FIRST_BACKUP_PRODUCER_SHA256,
        }

        def canonical_read(path: Path, _label: str):
            self.assertEqual(Path(path), locked_path)
            return json.loads(locked_raw), locked_raw

        kwargs = {
            "raw_sha256": hashlib.sha256(raw).hexdigest(),
            "onboarding": self.onboarding(),
            "onboarding_sha256": "7" * 64,
            "live_database_identity": self.IDENTITY,
            "expected_candidate": {"version": self.VERSION},
            "expected_manifest_sha256": "a" * 64,
            "require_fresh": True,
            "now": datetime(2026, 8, 14, 12, 7, tzinfo=timezone.utc),
        }
        with mock.patch.object(
            updater, "_first_backup_source_pins", return_value=pins
        ), mock.patch.object(
            updater, "_read_canonical_root_receipt", side_effect=canonical_read
        ), mock.patch.object(
            updater,
            "internal_test_candidate_manifest_binding",
            return_value={"version": self.VERSION},
        ) as candidate_binding:
            result = updater.validate_internal_test_first_backup_receipt(value, **kwargs)
            self.assertEqual(result["databaseIdentity"], self.IDENTITY)
            for mutate, message in (
                (lambda item: item["backup"].__setitem__("walStart", "000000020000000000000001"), "full/WAL"),
                (lambda item: item["backup"].__setitem__("lockedJobReceiptSha256", "9" * 64), "bytes changed"),
                (lambda item: item.__setitem__("unknown", True), "keys differ"),
            ):
                changed = copy.deepcopy(value)
                mutate(changed)
                with self.subTest(message=message), self.assertRaisesRegex(
                    (updater.UpdaterError, updater.release_guard.ReleaseGuardError),
                    message,
                ):
                    updater.validate_internal_test_first_backup_receipt(
                        changed, **kwargs
                    )
            expired = {**kwargs, "now": datetime(2026, 8, 15, 12, 5, tzinfo=timezone.utc)}
            with self.assertRaisesRegex(updater.UpdaterError, "expired"):
                updater.validate_internal_test_first_backup_receipt(value, **expired)
            candidate_binding.return_value = {"version": "v2026.08.14-2"}
            with self.assertRaisesRegex(updater.UpdaterError, "candidate differs"):
                updater.validate_internal_test_first_backup_receipt(value, **kwargs)

    def test_initial_helper_pins_read_current_reviewed_bytes_and_reject_tamper(self) -> None:
        producer = (
            Path(__file__).resolve().parents[1]
            / "postgres/backup/internal_test_first_backup.py"
        ).read_bytes()
        commissioner = (
            Path(__file__).resolve().parents[1]
            / "postgres/backup/internal_test_first_backup_commissioner.py"
        ).read_bytes()
        self.assertEqual(
            hashlib.sha256(producer).hexdigest(),
            updater.INTERNAL_TEST_FIRST_BACKUP_PRODUCER_SHA256,
        )
        self.assertEqual(
            hashlib.sha256(commissioner).hexdigest(),
            updater.INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_SHA256,
        )
        with mock.patch.object(
            updater,
            "read_root_controlled_bytes",
            side_effect=(producer, commissioner),
        ):
            pins = updater._first_backup_source_pins()
        self.assertEqual(
            pins["commissionerSha256"],
            updater.INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_SHA256,
        )
        with mock.patch.object(
            updater,
            "read_root_controlled_bytes",
            side_effect=(producer + b"tamper", commissioner),
        ), self.assertRaisesRegex(updater.UpdaterError, "reviewed bytes"):
            updater._first_backup_source_pins()

    def test_archived_binding_survives_current_helper_upgrade_but_not_unknown_history(self) -> None:
        binding, archived = self.binding()

        def present(path: object) -> bool:
            return Path(path) in archived

        def read(path: Path, _label: str):
            return archived[Path(path)]

        with mock.patch.object(
            updater.os.path, "lexists", side_effect=present
        ), mock.patch.object(
            updater, "_read_canonical_root_receipt", side_effect=read
        ), mock.patch.object(
            updater,
            "_first_backup_source_pins",
            side_effect=AssertionError("archived authority reopened current helper"),
        ):
            updater.validate_internal_test_first_backup_binding(
                binding,
                live_database_identity=self.IDENTITY,
                require_archive=True,
            )
            changed = copy.deepcopy(binding)
            changed["producerSha256"] = "f" * 64
            with self.assertRaisesRegex(updater.UpdaterError, "source/archive"):
                updater.validate_internal_test_first_backup_binding(
                    changed, require_archive=True
                )

    def test_archived_binding_rejects_live_replay_and_terminal_tamper(self) -> None:
        binding, archived = self.binding()
        receipt_archive = Path(binding["archivePath"])
        terminal_archive = Path(binding["terminalReceiptArchivePath"])

        with mock.patch.object(
            updater.os.path,
            "lexists",
            side_effect=lambda path: Path(path)
            in {receipt_archive, terminal_archive, updater.INTERNAL_TEST_FIRST_BACKUP_RECEIPT},
        ), self.assertRaisesRegex(updater.UpdaterError, "exactly one"):
            updater.validate_internal_test_first_backup_binding(
                binding, require_archive=True
            )

        terminal, terminal_raw = archived[terminal_archive]
        changed_terminal = copy.deepcopy(terminal)
        changed_terminal["status"] = "FORGED"
        archived[terminal_archive] = (changed_terminal, self.canonical(changed_terminal))
        with mock.patch.object(
            updater.os.path, "lexists", side_effect=lambda path: Path(path) in archived
        ), mock.patch.object(
            updater,
            "_read_canonical_root_receipt",
            side_effect=lambda path, _label: archived[Path(path)],
        ), self.assertRaisesRegex(updater.UpdaterError, "terminal"):
            updater.validate_internal_test_first_backup_binding(
                binding, require_archive=True
            )
        self.assertNotEqual(terminal_raw, archived[terminal_archive][1])

    def test_archive_resume_handles_sigkill_between_receipt_and_terminal(self) -> None:
        binding, _archived = self.binding()
        source = updater.INTERNAL_TEST_FIRST_BACKUP_RECEIPT
        destination = Path(binding["archivePath"])
        terminal_source = updater.INTERNAL_TEST_FIRST_BACKUP_TERMINAL
        terminal_destination = Path(binding["terminalReceiptArchivePath"])
        present = {source, terminal_source}
        calls: list[tuple[Path, Path]] = []

        def move(old: Path, new: Path, _digest: str) -> bytes:
            calls.append((Path(old), Path(new)))
            present.remove(Path(old))
            present.add(Path(new))
            if Path(old) == terminal_source and len(calls) == 2:
                raise KeyboardInterrupt("simulated SIGKILL boundary")
            return b"evidence"

        common = (
            mock.patch.object(updater.os.path, "lexists", side_effect=lambda path: Path(path) in present),
            mock.patch.object(updater, "require_real_directory"),
            mock.patch.object(updater, "archive_root_evidence", side_effect=move),
            mock.patch.object(
                updater,
                "validate_internal_test_first_backup_binding",
                return_value="internal-test-first-backup-binding-v1",
            ),
            mock.patch.object(Path, "lstat", return_value=mock.Mock(st_mode=0o40700)),
        )
        with common[0], common[1], common[2], common[3], common[4], self.assertRaises(
            KeyboardInterrupt
        ):
            updater.archive_internal_test_first_backup(
                binding,
                expected_version=self.VERSION,
                live_database_identity=self.IDENTITY,
            )
        self.assertEqual(present, {destination, terminal_destination})

        # The terminal rename completed just before process death. A retry must
        # perform no second move and only revalidate the fully archived state.
        with mock.patch.object(
            updater.os.path, "lexists", side_effect=lambda path: Path(path) in present
        ), mock.patch.object(
            updater, "require_real_directory"
        ), mock.patch.object(
            updater, "archive_root_evidence"
        ) as no_move, mock.patch.object(
            updater,
            "validate_internal_test_first_backup_binding",
            return_value="internal-test-first-backup-binding-v1",
        ), mock.patch.object(
            Path, "lstat", return_value=mock.Mock(st_mode=0o40700)
        ):
            updater.archive_internal_test_first_backup(
                binding,
                expected_version=self.VERSION,
                live_database_identity=self.IDENTITY,
            )
        no_move.assert_not_called()

    def test_commit_and_mutation_order_is_fail_closed(self) -> None:
        activation = inspect.getsource(updater.activate_release)
        gate = activation.index("require_initial_internal_test_first_backup(")
        prepare = activation.index("prepare_internal_test_onboarding_adoption(", gate)
        for mutation in (
            "install_root_owned_release(candidate, releases, manifest_info)",
            "begin_activation_transaction(",
            "stop_unit(",
            "atomic_current(base, target)",
            "run_migration_unit(",
        ):
            self.assertLess(gate, activation.index(mutation), mutation)
            self.assertLess(prepare, activation.index(mutation), mutation)
        active = activation.index("atomic_json(\n                active_state_path")
        runtime = activation.index("write_runtime_authority(", active)
        finalize = activation.index(
            "finalize_internal_test_onboarding_adoption_if_committed(", runtime
        )
        self.assertLess(active, runtime)
        self.assertLess(runtime, finalize)

        finalizer = inspect.getsource(
            updater.finalize_internal_test_onboarding_adoption_if_committed
        )
        active_gate = finalizer.index("validate_active_release_state(")
        runtime_gate = finalizer.index("validate_existing_runtime_authority(")
        archive = finalizer.index("archive_internal_test_first_backup(")
        consume = finalizer.index("durable_unlink(INTERNAL_TEST_ONBOARDING_ADOPTION)")
        self.assertLess(active_gate, runtime_gate)
        self.assertLess(runtime_gate, archive)
        self.assertLess(archive, consume)

    def test_subsequent_runtime_keeps_archived_origin_version(self) -> None:
        binding, _archived = self.binding()
        newer = {
            "commitSha": "a" * 40,
            "releaseSequence": updater.release_guard.version_sequence(
                "v2026.08.14-2"
            ),
            "version": "v2026.08.14-2",
        }
        with mock.patch.object(
            updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            updater,
            "internal_test_runtime_contract",
            return_value=({"contractId": "uten-imp-internal-test-runtime-v1"}, "b" * 64),
        ), mock.patch.object(
            updater, "installed_manifest_sha256", return_value="c" * 64
        ), mock.patch.object(
            updater, "runtime_database_identity", return_value=self.IDENTITY
        ), mock.patch.object(
            updater.os.path, "lexists", return_value=False
        ), mock.patch.object(
            updater,
            "validate_internal_test_first_backup_binding",
            return_value="internal-test-first-backup-binding-v1",
        ) as validate:
            authority = updater.runtime_authority_value(
                target=Path("/opt/uten-imp/releases/v2026.08.14-2"),
                manifest=newer,
                live_evidence={"verified": True},
                first_backup_binding=binding,
            )
        self.assertEqual(authority["firstBackup"]["version"], self.VERSION)
        self.assertNotIn("expected_version", validate.call_args.kwargs)
        self.assertTrue(validate.call_args.kwargs["require_archive"])

    def test_local_archive_phase_requires_exact_pgbackrest_command(self) -> None:
        value = {
            "archiveCommand": updater.INTERNAL_TEST_LOCAL_ARCHIVE_COMMAND,
            "archiveMode": "on",
            "configFile": "/etc/postgresql/16/main/postgresql.conf",
            "dataDirectory": "/data/postgresql/16/main",
            "databaseName": "uten_imp",
            "flywayHistory": [],
            "hbaFile": "/etc/postgresql/16/main/pg_hba.conf",
            "inRecovery": False,
            "listenAddresses": "127.0.0.1,::1",
            "postmasterPid": 100,
            "roleAclContract": updater.internal_test_role_acl_contract(),
            "schemaName": "public",
            "schemaVersion": 1,
            "serverPort": 5432,
            "serverVersionNum": 160010,
            "systemdMainPid": 100,
            "systemIdentifier": self.IDENTITY["systemIdentifier"],
            "tcpListenerPid": 100,
            "timeline": 1,
        }
        flyway = {
            "canonicalHistorySha256": "a" * 64,
            "headVersion": 1,
            "signedProjectionSha256": "b" * 64,
            "successfulMigrationCount": 1,
        }
        manifest = {"flywayHeadVersion": "1", "flywayMigrations": [{}]}
        with mock.patch.object(
            updater, "canonical_live_flyway_identity", return_value=flyway
        ):
            evidence = updater.validate_live_database_against_signed_release(
                value,
                target_manifest=manifest,
                require_internal_role_acl=True,
                allow_local_recovery_archive=True,
            )
            self.assertEqual(evidence["archiveMode"], "on")
            for key, replacement in (
                ("archiveMode", "off"),
                ("archiveCommand", "pgbackrest archive-push %p"),
            ):
                changed = {**value, key: replacement}
                with self.subTest(key=key), self.assertRaisesRegex(
                    updater.UpdaterError, "archive settings"
                ):
                    updater.validate_live_database_against_signed_release(
                        changed,
                        target_manifest=manifest,
                        require_internal_role_acl=True,
                        allow_local_recovery_archive=True,
                    )


if __name__ == "__main__":
    unittest.main()
