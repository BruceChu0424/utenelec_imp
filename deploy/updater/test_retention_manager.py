from __future__ import annotations

import json
import hashlib
import os
import stat
import sys
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "deploy" / "updater"))


@unittest.skipUnless(os.name == "posix", "retention controls require Linux no-follow APIs")
class RetentionManagerTest(unittest.TestCase):
    def setUp(self) -> None:
        import retention_launcher

        updater = PROJECT_ROOT / "deploy/updater/release_updater.py"
        manager = PROJECT_ROOT / "deploy/updater/retention_manager.py"
        self.manager = retention_launcher.load_runtime(
            release_updater_path=updater,
            retention_manager_path=manager,
            pins=retention_launcher.RuntimePins(
                hashlib.sha256(updater.read_bytes()).hexdigest(),
                hashlib.sha256(manager.read_bytes()).hexdigest(),
            ),
            require_root_control=False,
        )
        self.policy = {
            "criticalFreePercent": 20,
            "incomingTtlSeconds": 86400,
            "installedProjectHardBytes": 100 * 1024**3,
            "installedProjectId": 2102,
            "keepVerifiedCandidates": 3,
            "keepVerifiedInstalled": 3,
            "minimumAgeSeconds": 604800,
            "minimumFreeBytes": 2 * 1024**3,
            "minimumFreePercent": 15,
            "schemaVersion": 1,
            "stagingProjectHardBytes": 50 * 1024**3,
            "stagingProjectId": 2101,
            "warningFreePercent": 30,
        }

    def test_policy_is_exact_numeric_and_has_no_path_override(self) -> None:
        validated = self.manager.validate_policy(dict(self.policy))
        self.assertEqual(validated, self.policy)

        with_path = dict(self.policy)
        with_path["releasePath"] = "/tmp/attacker"
        with self.assertRaisesRegex(self.manager.RetentionError, "path overrides are forbidden"):
            self.manager.validate_policy(with_path)

        boolean_schema = dict(self.policy)
        boolean_schema["schemaVersion"] = True
        with self.assertRaisesRegex(self.manager.RetentionError, "schemaVersion"):
            self.manager.validate_policy(boolean_schema)

        unsafe_keep = dict(self.policy)
        unsafe_keep["keepVerifiedInstalled"] = 2
        with self.assertRaisesRegex(self.manager.RetentionError, "keepVerifiedInstalled"):
            self.manager.validate_policy(unsafe_keep)

        example = json.loads(
            (PROJECT_ROOT / "deploy/updater/retention-policy.json.example").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(self.manager.validate_policy(example), self.policy)

    def test_every_persistent_release_transaction_blocks_retention(self) -> None:
        self.assertEqual(
            {
                "activation-failed.json",
                "activation-in-progress.json",
                "boot-enablement-in-progress.json",
                "recovery-in-progress.json",
                "recovery-ingress-pending.json",
                "recovery-ingress-authorization.json",
                "recovery-ingress-finalizing.json",
                "internal-test-onboarding-adoption.json",
                "internal-test-activation-reauthorization.json",
                "worker-request.json",
                "retention-in-progress.json",
            },
            {path.name for path in self.manager.BLOCKING_MARKERS},
        )
        self.assertEqual(
            self.manager.RETENTION_MARKER,
            self.manager.BLOCKING_MARKERS[-1],
        )

    def release(self, kind: str, sequence: int, age: int = 700000) -> dict[str, object]:
        version = f"v2026.08.{sequence:02d}-1"
        return {
            "ageSeconds": age,
            "bytes": sequence,
            "device": 1,
            "inode": sequence,
            "kind": kind,
            "maximumMtimeNs": sequence,
            "name": version,
            "path": f"/{kind}/{version}",
            "releaseSequence": self.manager.release_guard.version_sequence(version),
            "verified": True,
            "version": version,
        }

    def trusted_recovery_scandir(self, recoveries: Path):
        real_scandir = os.scandir

        class TrustedDirectoryEntry:
            def __init__(self, entry) -> None:
                self._entry = entry
                self.name = entry.name

            def stat(self, *, follow_symlinks: bool = True):
                details = self._entry.stat(follow_symlinks=follow_symlinks)
                return SimpleNamespace(
                    st_dev=details.st_dev,
                    st_gid=0,
                    st_mode=details.st_mode,
                    st_uid=0,
                )

        def scan(path):
            entries = list(real_scandir(path))
            if Path(path) == recoveries:
                return iter(TrustedDirectoryEntry(entry) for entry in entries)
            return iter(entries)

        return scan

    def test_plan_keeps_references_top_three_and_signed_predecessor(self) -> None:
        installed = [self.release("installed", number) for number in range(1, 8)]
        candidates = [self.release("candidate", number) for number in range(1, 7)]
        active = installed[-1]["version"]
        high_water = candidates[1]["version"]
        pending = candidates[2]["version"]
        protected = {active, high_water, pending}
        deletions, protection, alerts = self.manager.select_deletions(
            candidates=candidates,
            installed=installed,
            incoming=[],
            protected_versions=protected,
            active_version=active,
            policy=self.policy,
        )
        deleted = {(item["kind"], item["version"]) for item in deletions}
        self.assertEqual(protection["fallbackPredecessor"], installed[-2]["version"])
        self.assertNotIn(("installed", installed[-2]["version"]), deleted)
        self.assertNotIn(("candidate", high_water), deleted)
        self.assertNotIn(("candidate", pending), deleted)
        for item in installed[-3:]:
            self.assertNotIn(("installed", item["version"]), deleted)
        for item in candidates[-3:]:
            self.assertNotIn(("candidate", item["version"]), deleted)
        self.assertEqual(alerts, [])

    def test_no_predecessor_disables_installed_pruning(self) -> None:
        active = self.release("installed", 1)
        older_candidate = self.release("candidate", 1)
        deletions, protection, alerts = self.manager.select_deletions(
            candidates=[older_candidate],
            installed=[active],
            incoming=[],
            protected_versions={active["version"]},
            active_version=active["version"],
            policy=self.policy,
        )
        self.assertFalse(any(item["kind"] == "installed" for item in deletions))
        self.assertIsNone(protection["fallbackPredecessor"])
        self.assertTrue(any("no verified installed predecessor" in item for item in alerts))

    def test_quota_requires_project_inherit_and_exact_hard_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            mount = {
                "fstype": "xfs",
                "options": "rw,relatime,prjquota",
                "source": "/dev/mock",
                "target": temporary,
            }
            quota = {
                "currentBytes": 123,
                "hardBytes": self.policy["stagingProjectHardBytes"],
                "softBytes": 0,
            }
            with mock.patch.object(self.manager, "find_mount", return_value=mount), mock.patch.object(
                self.manager, "project_attributes_fd", return_value=(2101, True)
            ), mock.patch.object(self.manager, "query_project_quota", return_value=quota):
                observed = self.manager.quota_observation(
                    path, 2101, self.policy["stagingProjectHardBytes"]
                )
            self.assertTrue(observed["valid"])
            self.manager.add_quota_capacity(observed, self.policy)
            self.assertEqual(observed["severity"], "ok")

            nearly_full = dict(observed)
            nearly_full["currentBytes"] = nearly_full["hardBytes"] - 1024**3
            self.manager.add_quota_capacity(nearly_full, self.policy)
            self.assertEqual(nearly_full["severity"], "minimum")

            wrong = dict(quota)
            wrong["hardBytes"] += 1024
            with mock.patch.object(self.manager, "find_mount", return_value=mount), mock.patch.object(
                self.manager, "project_attributes_fd", return_value=(2101, True)
            ), mock.patch.object(self.manager, "query_project_quota", return_value=wrong):
                rejected = self.manager.quota_observation(
                    path, 2101, self.policy["stagingProjectHardBytes"]
                )
            self.assertFalse(rejected["valid"])
            self.assertIn("hard limit differs", rejected["error"])

    def test_tree_validation_rejects_symlink_and_hardlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            tree = parent / "v2026.08.11-1"
            tree.mkdir()
            target = tree / "payload"
            target.write_text("payload", encoding="utf-8")
            (tree / "link").symlink_to(target)
            details = parent.stat()
            with mock.patch.object(
                self.manager, "project_attributes_fd", return_value=(2101, True)
            ), self.assertRaisesRegex(self.manager.RetentionError, "symlink or special"):
                self.manager.validate_tree_at(
                    parent,
                    tree.name,
                    expected_uid=os.geteuid(),
                    expected_gid=os.getegid(),
                    expected_project_id=2101,
                    expected_dev=details.st_dev,
                )
            (tree / "link").unlink()
            os.link(target, tree / "hardlink")
            with mock.patch.object(
                self.manager, "project_attributes_fd", return_value=(2101, True)
            ), self.assertRaisesRegex(self.manager.RetentionError, "multiply-linked"):
                self.manager.validate_tree_at(
                    parent,
                    tree.name,
                    expected_uid=os.geteuid(),
                    expected_gid=os.getegid(),
                    expected_project_id=2101,
                    expected_dev=details.st_dev,
                )

    def test_quarantine_residue_is_observed_and_always_blocks_pruning(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            quarantine = Path(temporary)
            transaction = "20260812T000000Z-" + "d" * 32
            version = "v2026.08.11-1"
            residue = quarantine / f"{transaction}-candidate-{version}"
            residue.mkdir()
            (residue / "partial").write_text("evidence", encoding="utf-8")
            with mock.patch.object(
                self.manager, "project_attributes_fd", return_value=(2101, True)
            ):
                observations, blockers = self.manager.observe_quarantine(
                    path=quarantine,
                    updater_uid=os.geteuid(),
                    updater_gid=os.getegid(),
                    policy=self.policy,
                )
            self.assertTrue(observations[0]["valid"])
            self.assertTrue(any("evidence-driven recovery" in item for item in blockers))

    def test_database_recovery_receipt_version_is_retention_protected(self) -> None:
        target_version = "v2026.08.11-1"
        receipt_value = {
            "approvalReference": "CHANGE-1234",
            "completedAtUtc": "2026-08-12T00:00:00Z",
            "evidenceReference": (
                "path=/var/lib/uten-imp-backup/acceptance-receipts/"
                "restore-detail.json;sha256=" + "e" * 64
            ),
            "flywayHeadVersion": "254",
            "flywayMigrationSetSha256": "f" * 64,
            "receiptType": "restore",
            "schemaVersion": 1,
            "successful": True,
            "targetVersion": target_version,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recoveries = root / "recovery-evidence"
            database = root / "database-receipts"
            recoveries.mkdir()
            database.mkdir()
            receipt = database / "restore-proof.json"
            receipt.write_text(json.dumps(receipt_value), encoding="utf-8")
            receipt.chmod(0o600)
            with mock.patch.object(
                self.manager, "RECOVERY_EVIDENCE_DIR", recoveries
            ), mock.patch.object(
                self.manager, "DATABASE_RECEIPTS_DIR", database
            ), mock.patch.object(
                self.manager, "require_fixed_directory"
            ), mock.patch.object(
                self.manager,
                "stable_read_file",
                side_effect=lambda path, **_kwargs: path.read_bytes(),
            ):
                protected, blockers, observations = self.manager.recovery_references()
            self.assertEqual(blockers, [])
            self.assertIn(target_version, protected)
            self.assertTrue(observations["databaseReceipts"][0]["valid"])

    def test_completed_recovery_commit_and_receipt_are_validated_together(self) -> None:
        target = "v2026.08.12-1"
        sequence = self.manager.release_guard.version_sequence(target)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recoveries = root / "recovery-evidence"
            database = root / "database-receipts"
            details = root / "acceptance-receipts"
            recoveries.mkdir(mode=0o700)
            database.mkdir(mode=0o700)
            details.mkdir(mode=0o700)
            transaction = recoveries / ("a" * 16 + "-recovery01")
            transaction.mkdir(mode=0o700)

            database_path = database / "restore-proof.json"
            database_value = {
                "approvalReference": "CHANGE-1234",
                "completedAtUtc": "2026-08-12T00:00:00Z",
                "evidenceReference": (
                    "path=/var/lib/uten-imp-backup/acceptance-receipts/"
                    "detail.json;sha256=" + "d" * 64
                ),
                "flywayHeadVersion": "255",
                "flywayMigrationSetSha256": "e" * 64,
                "receiptType": "restore",
                "schemaVersion": 1,
                "successful": True,
                "targetVersion": target,
            }
            database_path.write_text(json.dumps(database_value), encoding="utf-8")
            database_path.chmod(0o600)

            boot_map = {
                unit: True for unit in self.manager.release_updater.BOOT_UNITS
            }
            failure = {
                "currentLinkRestored": False,
                "failedAtUtc": "2026-08-12T00:01:00Z",
                "failedCommitSha": "a" * 40,
                "failedFlywayHeadVersion": "255",
                "failedFlywayMigrationSetSha256": "e" * 64,
                "failedVersion": target,
                "originalBootEnablement": boot_map,
                "previousFlywayHeadVersion": "254",
                "previousFlywayMigrationSetSha256": "f" * 64,
                "previousVersion": "v2026.08.11-1",
                "reason": "activation-commit-failed",
                "recoveryRequired": True,
                "schemaVersion": 1,
            }
            progress = {
                "action": "finish-activation",
                "approvalReference": "CHANGE-1234",
                "databaseReceiptPath": str(database_path),
                "databaseReceiptSha256": "1" * 64,
                "desiredBootEnablement": boot_map,
                "markerSha256": "2" * 64,
                "planSha256": "3" * 64,
                "schemaVersion": 1,
                "startedAtUtc": "2026-08-12T00:02:00Z",
                "targetVersion": target,
                "transactionDirectory": str(transaction),
            }
            boot = {
                "commitSha": "a" * 40,
                "desiredBootEnablement": boot_map,
                "releaseSequence": sequence,
                "schemaVersion": 1,
                "startedAtUtc": "2026-08-12T00:03:00Z",
                "version": target,
            }
            live_database = {
                "databaseName": "uten_imp",
                "dataDirectory": "/data/postgresql/16/main",
                "flyway": {
                    "canonicalHistorySha256": "4" * 64,
                    "headVersion": 255,
                    "signedProjectionSha256": "5" * 64,
                    "successfulMigrationCount": 236,
                },
                "schemaName": "public",
                "serverPort": 5432,
                "serverVersionNum": 160004,
                "systemdMainPid": 321,
                "systemIdentifier": "7523456789012345678",
                "timeline": 4,
                "verifiedAtUtc": "2026-08-12T00:04:00Z",
                "verifierSha256": self.manager.release_updater.DATABASE_RECOVERY_VERIFIER_SHA256,
            }
            common = {
                "action": "finish-activation",
                "approvalReference": "CHANGE-1234",
                "databaseDetailPath": str(details / "detail.json"),
                "databaseDetailSha256": "d" * 64,
                "databaseReceiptPath": str(database_path),
                "databaseReceiptSha256": "1" * 64,
                "desiredBootEnablement": boot_map,
                "liveDatabaseEvidence": live_database,
                "manifestSha256": "6" * 64,
                "markerSha256": "2" * 64,
                "planSha256": "3" * 64,
                "schemaVersion": 1,
                "targetVersion": target,
                "transactionDirectory": str(transaction),
            }
            evidence = {
                "activation-failed.original.json": failure,
                "boot-enablement.recovery.json": boot,
                "recovery-in-progress.completed.json": progress,
                "recovery-commit.json": {
                    **common,
                    "committedAtUtc": "2026-08-12T00:05:00Z",
                    "status": "runtime-committed-pending-ingress",
                },
                "recovery-receipt.json": {
                    **common,
                    "completedAtUtc": "2026-08-12T00:06:00Z",
                    "status": "completed",
                },
            }
            for name, value in evidence.items():
                path = transaction / name
                path.write_text(json.dumps(value), encoding="utf-8")
                path.chmod(0o600)

            trusted_scan = self.trusted_recovery_scandir(recoveries)
            with mock.patch.object(
                self.manager, "RECOVERY_EVIDENCE_DIR", recoveries
            ), mock.patch.object(
                self.manager, "DATABASE_RECEIPTS_DIR", database
            ), mock.patch.object(
                self.manager.release_updater, "RECOVERY_DATABASE_RECEIPTS_DIR", database
            ), mock.patch.object(
                self.manager.release_updater, "RECOVERY_DATABASE_DETAIL_DIR", details
            ), mock.patch.object(
                self.manager.release_updater, "RECOVERY_EVIDENCE_DIR", recoveries
            ), mock.patch.object(
                self.manager, "require_fixed_directory"
            ), mock.patch.object(
                self.manager,
                "stable_read_file",
                side_effect=lambda path, **_kwargs: path.read_bytes(),
            ), mock.patch.object(
                self.manager.os, "scandir", side_effect=trusted_scan
            ):
                protected, blockers, observations = self.manager.recovery_references()
                self.assertEqual(blockers, [])
                self.assertIn(target, protected)
                self.assertTrue(observations["transactions"][0]["valid"])

                (transaction / "recovery-commit.json").unlink()
                _protected, partial_blockers, partial = self.manager.recovery_references()
                self.assertTrue(
                    any("incomplete/failed recovery" in item for item in partial_blockers)
                )
                self.assertFalse(partial["transactions"][0]["valid"])

    def test_remain_contained_and_interrupted_transactions_are_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recoveries = root / "recovery-evidence"
            database = root / "database-receipts"
            recoveries.mkdir(mode=0o700)
            database.mkdir(mode=0o700)

            remain = recoveries / ("b" * 16 + "-remain01")
            remain.mkdir(mode=0o700)
            remain_value = {
                "action": "remain-contained",
                "approvalReference": "CHANGE-5678",
                "completedAtUtc": "2026-08-12T01:00:00Z",
                "markerPath": str(root / "activation-failed.json"),
                "markerSha256": "7" * 64,
                "planSha256": "8" * 64,
                "schemaVersion": 1,
                "status": "contained-no-start-no-marker-clear",
                "subjectVersion": "v2026.08.12-1",
                "transactionDirectory": str(remain),
            }
            remain_path = remain / "remain-contained-receipt.json"
            remain_path.write_text(json.dumps(remain_value), encoding="utf-8")
            remain_path.chmod(0o600)

            activation = {
                "commitSha": "a" * 40,
                "originalBootEnablement": {
                    unit: True for unit in self.manager.release_updater.BOOT_UNITS
                },
                "previousVersion": "v2026.08.11-1",
                "releaseSequence": 20260812001,
                "schemaVersion": 1,
                "startedAtUtc": "2026-08-12T01:01:00Z",
                "version": "v2026.08.12-1",
            }
            activation_raw = (
                json.dumps(activation, sort_keys=True, indent=2) + "\n"
            ).encode("utf-8")
            activation_sha = self.manager.hashlib.sha256(activation_raw).hexdigest()
            basis = {
                "action": "contain",
                "markers": {
                    "activation": {
                        "path": str(root / "activation-in-progress.json"),
                        "schemaKind": "activation-in-progress-v1",
                        "sha256": activation_sha,
                        "sizeBytes": len(activation_raw),
                    }
                },
                "paths": {
                    "activationFailure": str(root / "activation-failed.json"),
                    "operationLock": str(root / "operation.lock"),
                    "recoveryEvidence": str(recoveries),
                },
                "preexistingFailure": None,
                "schemaVersion": 1,
                "startAuthorization": None,
                "stateKind": "activation",
            }
            plan_sha = self.manager.release_updater.canonical_json_sha256(basis)
            interrupted = recoveries / f"interrupted-{plan_sha}"
            interrupted.mkdir(mode=0o700)
            activation_archive = interrupted / "activation-in-progress.original.json"
            activation_archive.write_bytes(activation_raw)
            activation_archive.chmod(0o600)
            plan = {
                "kind": "uten-imp-interrupted-containment-plan",
                "planBasis": basis,
                "planSha256": plan_sha,
                "schemaVersion": 1,
            }
            receipt = {
                "action": "contain",
                "activationFailureMarkerPath": str(root / "activation-failed.json"),
                "activationFailureMarkerSha256": "9" * 64,
                "completedAtUtc": "2026-08-12T01:02:00Z",
                "interruptedMarkerArchive": {
                    "activation": {
                        "path": str(activation_archive),
                        "sha256": activation_sha,
                    }
                },
                "planSha256": plan_sha,
                "schemaVersion": 1,
                "startAuthorizationArchive": None,
                "stateKind": "activation",
                "status": "contained-no-start",
                "transactionDirectory": str(interrupted),
            }
            for name, value in (
                (self.manager.INTERRUPTED_CONTAINMENT_PLAN, plan),
                (self.manager.INTERRUPTED_CONTAINMENT_RECEIPT, receipt),
            ):
                path = interrupted / name
                path.write_text(json.dumps(value), encoding="utf-8")
                path.chmod(0o600)

            updater = self.manager.release_updater
            trusted_scan = self.trusted_recovery_scandir(recoveries)
            with mock.patch.object(
                self.manager, "RECOVERY_EVIDENCE_DIR", recoveries
            ), mock.patch.object(
                self.manager, "DATABASE_RECEIPTS_DIR", database
            ), mock.patch.object(
                self.manager, "ROOT_STATE_DIR", root
            ), mock.patch.object(
                updater, "RECOVERY_EVIDENCE_DIR", recoveries
            ), mock.patch.object(
                updater, "ACTIVATION_FAILURE_MARKER", root / "activation-failed.json"
            ), mock.patch.object(
                updater, "ACTIVATION_IN_PROGRESS_MARKER", root / "activation-in-progress.json"
            ), mock.patch.object(
                self.manager, "require_fixed_directory"
            ), mock.patch.object(
                self.manager,
                "stable_read_file",
                side_effect=lambda path, **_kwargs: path.read_bytes(),
            ), mock.patch.object(
                self.manager.os, "scandir", side_effect=trusted_scan
            ):
                protected, blockers, observations = self.manager.recovery_references()
                self.assertEqual(blockers, [])
                self.assertIn("v2026.08.12-1", protected)
                self.assertTrue(all(item["valid"] for item in observations["transactions"]))

                extra = interrupted / "start-authorization.precontainment.json"
                extra.write_text(json.dumps({"unexpected": True}), encoding="utf-8")
                extra.chmod(0o600)
                _protected, partial_blockers, partial = self.manager.recovery_references()
                self.assertTrue(
                    any("interrupted recovery transaction" in item for item in partial_blockers)
                )
                self.assertFalse(
                    next(
                        item["valid"]
                        for item in partial["transactions"]
                        if item["name"].startswith("interrupted-")
                    )
                )

    def test_unknown_recovery_transaction_is_a_global_prune_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recoveries = root / "recovery-evidence"
            database = root / "database-receipts"
            recoveries.mkdir()
            database.mkdir()
            (recoveries / "unknown-transaction").mkdir()
            with mock.patch.object(
                self.manager, "RECOVERY_EVIDENCE_DIR", recoveries
            ), mock.patch.object(
                self.manager, "DATABASE_RECEIPTS_DIR", database
            ), mock.patch.object(self.manager, "require_fixed_directory"):
                _protected, blockers, observations = self.manager.recovery_references()
            self.assertTrue(any("unknown or damaged" in item for item in blockers))
            self.assertFalse(observations["transactions"][0]["valid"])

    def test_quarantine_fsyncs_destination_then_source_before_deletion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidates = root / "candidates"
            quarantine = root / "quarantine"
            candidates.mkdir()
            quarantine.mkdir(mode=0o700)
            version = "v2026.08.11-1"
            source = candidates / version
            source.mkdir()
            (source / "payload").write_text("payload", encoding="utf-8")
            details = candidates.stat()
            with mock.patch.object(
                self.manager, "project_attributes_fd", return_value=(2101, True)
            ):
                descriptor, tree, source_details = self.manager.validate_tree_at(
                    candidates,
                    version,
                    expected_uid=os.geteuid(),
                    expected_gid=os.getegid(),
                    expected_project_id=2101,
                    expected_dev=details.st_dev,
                )
                os.close(descriptor)
                item = {
                    "bytes": tree["bytes"],
                    "device": details.st_dev,
                    "inode": source_details.st_ino,
                    "kind": "candidate",
                    "maximumMtimeNs": tree["maximumMtimeNs"],
                    "name": version,
                }
                manager = mock.Mock()
                real_rename = os.rename
                real_fsync = os.fsync
                real_delete = self.manager.delete_contents_fd
                with mock.patch.object(self.manager, "CANDIDATES_DIR", candidates), mock.patch.object(
                    self.manager, "STAGING_QUARANTINE", quarantine
                ), mock.patch.object(
                    self.manager, "project_attributes_fd", return_value=(2101, True)
                ), mock.patch.object(
                    self.manager,
                    "verify_open_directory",
                    side_effect=lambda descriptor, _path, **_kwargs: os.fstat(descriptor),
                ), mock.patch.object(
                    self.manager.os, "rename", wraps=real_rename
                ) as rename, mock.patch.object(
                    self.manager.os, "fsync", wraps=real_fsync
                ) as fsync, mock.patch.object(
                    self.manager, "delete_contents_fd", wraps=real_delete
                ) as delete:
                    manager.attach_mock(rename, "rename")
                    manager.attach_mock(fsync, "fsync")
                    manager.attach_mock(delete, "delete")
                    result = self.manager.quarantine_and_delete(
                        item,
                        updater_uid=os.geteuid(),
                        updater_gid=os.getegid(),
                        policy=self.policy,
                        transaction_id="20260811T000000Z-" + "a" * 32,
                    )
            calls = manager.mock_calls
            rename_index = next(i for i, call in enumerate(calls) if call[0] == "rename")
            delete_index = next(i for i, call in enumerate(calls) if call[0] == "delete")
            fsync_indexes = [i for i, call in enumerate(calls) if call[0] == "fsync"]
            self.assertLess(rename_index, fsync_indexes[0])
            self.assertLess(fsync_indexes[0], fsync_indexes[1])
            self.assertLess(fsync_indexes[1], delete_index)
            self.assertEqual(result["status"], "deleted-after-durable-quarantine")
            self.assertFalse(source.exists())
            self.assertEqual(list(quarantine.iterdir()), [])

    def test_source_has_no_recursive_path_delete_or_path_override(self) -> None:
        source = (Path(__file__).resolve().parent / "retention_manager.py").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("shutil.rmtree", source)
        self.assertIn("src_dir_fd=source_parent_fd", source)
        self.assertIn("dst_dir_fd=quarantine_fd", source)
        self.assertIn("os.O_NOFOLLOW", source)
        parser_source = source[source.index("def parser()") : source.index("def main()")]
        self.assertNotIn("--state-dir", parser_source)
        self.assertNotIn("--release", parser_source)

    def test_prune_blocker_refuses_before_marker_or_delete(self) -> None:
        plan = {"alerts": [], "blockers": ["transaction marker exists"]}
        with mock.patch.object(self.manager.os, "geteuid", return_value=0), mock.patch.object(
            self.manager, "load_policy", return_value=(self.policy, "a" * 64)
        ), mock.patch.object(
            self.manager.release_updater, "StateLock", return_value=nullcontext()
        ), mock.patch.object(
            self.manager, "build_audit", return_value=plan
        ), mock.patch.object(
            self.manager, "write_new_json", return_value=Path("/receipt/refused.json")
        ), mock.patch.object(
            self.manager.release_updater, "atomic_json"
        ) as marker_write, mock.patch.object(
            self.manager, "quarantine_and_delete"
        ) as delete:
            receipt, status = self.manager.execute_audit("prune")
        self.assertEqual(status, 1)
        self.assertEqual(receipt["status"], "refused")
        marker_write.assert_not_called()
        delete.assert_not_called()

    def test_runtime_hash_or_path_drift_refuses_before_policy_or_receipt_write(self) -> None:
        with mock.patch.object(
            self.manager,
            "_runtime_trust_attestor",
            side_effect=RuntimeError("injected runtime path drift"),
        ), mock.patch.object(self.manager, "load_policy") as load_policy, mock.patch.object(
            self.manager, "write_new_json"
        ) as write:
            with self.assertRaisesRegex(RuntimeError, "runtime path drift"):
                self.manager.execute_audit("audit")
        load_policy.assert_not_called()
        write.assert_not_called()

    def test_runtime_hash_or_path_drift_refuses_before_external_alert(self) -> None:
        with mock.patch.object(
            self.manager,
            "_runtime_trust_attestor",
            side_effect=RuntimeError("injected updater digest drift"),
        ), mock.patch.object(self.manager, "read_alert_json") as read, mock.patch.object(
            self.manager.subprocess, "run"
        ) as external:
            with self.assertRaisesRegex(RuntimeError, "updater digest drift"):
                self.manager.deliver_alert(Path("/not-read.pending.json"))
        read.assert_not_called()
        external.assert_not_called()

    def test_audit_exception_emits_durable_failed_closed_receipt(self) -> None:
        with mock.patch.object(self.manager.os, "geteuid", return_value=0), mock.patch.object(
            self.manager, "load_policy", return_value=(self.policy, "a" * 64)
        ), mock.patch.object(
            self.manager.release_updater, "StateLock", return_value=nullcontext()
        ), mock.patch.object(
            self.manager, "build_audit", side_effect=OSError("injected findmnt failure")
        ), mock.patch.object(
            self.manager,
            "write_new_json",
            return_value=Path("/receipt/audit-failed.json"),
        ) as write:
            receipt, status = self.manager.execute_audit("audit")
        self.assertEqual(status, 1)
        self.assertEqual(receipt["status"], "failed-closed")
        self.assertIn("findmnt failure", receipt["error"])
        self.assertIn("audit-failed.json", write.call_args.args[1])

    def test_new_json_unlinks_partial_receipt_if_directory_fsync_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            real_fsync = os.fsync
            calls = 0

            def fail_second_fsync(descriptor: int) -> None:
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("injected directory fsync failure")
                real_fsync(descriptor)

            with mock.patch.object(
                self.manager, "require_fixed_directory"
            ), mock.patch.object(self.manager.os, "fsync", side_effect=fail_second_fsync):
                with self.assertRaisesRegex(OSError, "injected directory fsync failure"):
                    self.manager.write_new_json(directory, "receipt.json", {"status": "test"})
            self.assertEqual(list(directory.iterdir()), [])

    def alert_event(self, alert_id: str) -> dict[str, object]:
        return {
            "alertId": alert_id,
            "containsSecrets": False,
            "createdAtUtc": "2026-08-12T00:00:00Z",
            "failedUnit": "uten-imp-retention.service",
            "latestReceiptDirectory": str(self.manager.RECEIPTS_DIR),
            "requiredAction": "keep timers disabled and investigate",
            "schemaVersion": 1,
            "severity": "critical",
            "source": "uten-imp-release-retention",
            "summary": "retention failed",
        }

    def test_alert_zero_exit_is_not_delivery_without_bound_receipt(self) -> None:
        alert_id = "20260812T000000Z-" + "a" * 32
        with tempfile.TemporaryDirectory() as temporary:
            alerts = Path(temporary)
            pending = alerts / f"{alert_id}.pending.json"
            pending.write_text(json.dumps(self.alert_event(alert_id)), encoding="utf-8")
            pending.chmod(0o600)
            with mock.patch.object(self.manager, "ALERTS_DIR", alerts), mock.patch.object(
                self.manager, "validate_alert_sink"
            ), mock.patch.object(
                self.manager, "stable_read_file", side_effect=lambda path, **_kwargs: path.read_bytes()
            ), mock.patch.object(
                self.manager.subprocess, "run", return_value=mock.Mock(returncode=0)
            ):
                self.assertFalse(self.manager.deliver_alert(pending))
            self.assertTrue(pending.exists())
            self.assertFalse((alerts / f"{alert_id}.delivered.json").exists())

    def test_alert_existing_receipt_must_bind_event_before_delivery(self) -> None:
        alert_id = "20260812T000000Z-" + "b" * 32
        with tempfile.TemporaryDirectory() as temporary:
            alerts = Path(temporary)
            pending = alerts / f"{alert_id}.pending.json"
            receipt = alerts / f"{alert_id}.receipt.json"
            pending.write_text(json.dumps(self.alert_event(alert_id)), encoding="utf-8")
            receipt.write_text(
                json.dumps(
                    {
                        "accepted": True,
                        "alertId": alert_id,
                        "deliveredAtUtc": "2026-08-12T00:00:01Z",
                        "providerMessageId": "provider/message-1",
                        "schemaVersion": 1,
                    }
                ),
                encoding="utf-8",
            )
            pending.chmod(0o600)
            receipt.chmod(0o600)
            with mock.patch.object(self.manager, "ALERTS_DIR", alerts), mock.patch.object(
                self.manager, "stable_read_file", side_effect=lambda path, **_kwargs: path.read_bytes()
            ):
                self.assertTrue(self.manager.deliver_alert(pending))
            self.assertFalse(pending.exists())
            self.assertTrue((alerts / f"{alert_id}.delivered.json").exists())

    def test_failed_marker_archive_restores_exact_fail_closed_marker(self) -> None:
        transaction_id = "20260812T000000Z-" + "c" * 32
        raw = b'{"schemaVersion":1}\n'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            receipts = Path(temporary) / "receipts"
            root.mkdir()
            receipts.mkdir()
            marker = root / "retention-in-progress.json"
            marker.write_bytes(raw)

            def move_then_fail(source: Path, destination: Path, _digest: str) -> None:
                os.replace(source, destination)
                raise OSError("injected source-parent fsync failure")

            with mock.patch.object(self.manager, "ROOT_STATE_DIR", root), mock.patch.object(
                self.manager, "RECEIPTS_DIR", receipts
            ), mock.patch.object(
                self.manager, "RETENTION_MARKER", marker
            ), mock.patch.object(
                self.manager.release_updater,
                "read_root_evidence_bytes",
                side_effect=lambda path: path.read_bytes(),
            ), mock.patch.object(
                self.manager.release_updater,
                "archive_root_evidence",
                side_effect=move_then_fail,
            ), mock.patch.object(
                self.manager.release_updater, "fsync_directory"
            ):
                with self.assertRaisesRegex(OSError, "injected source-parent fsync failure"):
                    self.manager.archive_retention_marker(transaction_id)
            self.assertEqual(marker.read_bytes(), raw)
            self.assertFalse((receipts / f"{transaction_id}.transaction.json").exists())

    def test_systemd_and_installer_keep_both_timers_disabled(self) -> None:
        project = Path(__file__).resolve().parents[2]
        service = (project / "deploy/systemd/uten-imp-retention.service.example").read_text(
            encoding="utf-8"
        )
        installer = (project / "deploy/setup/install-release-retention.py").read_text(
            encoding="utf-8"
        )
        shell = (project / "deploy/setup/install-release-retention.sh").read_text(
            encoding="utf-8"
        )
        alert = (
            project / "deploy/systemd/uten-imp-retention-alert@.service.example"
        ).read_text(encoding="utf-8")
        self.assertIn("OnFailure=uten-imp-retention-alert@%n.service", service)
        self.assertIn("/usr/local/sbin/uten-imp-retention alert --unit %i", alert)
        self.assertIn('"active": "inactive", "enabled": "disabled"', installer)
        self.assertNotIn("disable --now", installer)
        self.assertNotIn("disable --now", shell)
        self.assertNotIn("systemctl stop", installer)
        self.assertNotIn("systemctl enable", installer)


if __name__ == "__main__":
    unittest.main()
