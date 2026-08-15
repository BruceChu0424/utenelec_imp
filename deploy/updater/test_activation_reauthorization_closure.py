#!/usr/bin/env python3
"""Focused closure tests for one-use internal-test activation reauthorization."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import inspect
import json
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "uten_imp_release_updater_reauthorization_test", HERE / "release_updater.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load release_updater.py")
updater = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = updater
SPEC.loader.exec_module(updater)


class ActivationReauthorizationClosureTest(unittest.TestCase):
    BOOT_ID = "11111111-1111-4111-8111-111111111111"
    TRANSACTION_ID = "internal-test-db-20260814T010203Z-abcdef123456"
    DATABASE_IDENTITY = {
        "databaseName": "uten_imp",
        "systemIdentifier": "1234567890123456789",
        "timeline": 1,
    }

    def target(self) -> dict:
        return {
            "commitSha": "c" * 40,
            "executableSha256s": {
                "server/uten-imp-migrator.jar": "d" * 64,
                "server/uten-imp-server.jar": "e" * 64,
            },
            "flywayHeadVersion": "255",
            "flywayMigrationCount": 1,
            "flywayMigrationSetSha256": "f" * 64,
            "flywayMigrations": [
                {
                    "file": "V255__baseline.sql",
                    "flywayChecksum": 123,
                    "version": "255",
                }
            ],
            "releaseSequence": 20260814001,
            "signingKeyId": "SHA256:test-key",
            "version": "v2026.08.14-1",
        }

    def onboarding(self, *, currently_expired: bool = True) -> tuple[dict, bytes]:
        now = datetime.now(timezone.utc).replace(microsecond=0)
        expiry = now - timedelta(hours=1) if currently_expired else now + timedelta(hours=1)
        completed = expiry - timedelta(hours=1)
        target = self.target()
        value = {
            "commissioningAuthorityPath": (
                f"/var/lib/uten-imp-internal-test-commissioning/"
                f"{self.TRANSACTION_ID}/commissioning-authority.json"
            ),
            "completedAtUtc": completed.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "databaseIdentity": copy.deepcopy(self.DATABASE_IDENTITY),
            "evidencePath": (
                f"/var/lib/uten-imp-internal-test-commissioning/{self.TRANSACTION_ID}"
            ),
            "expiresAtUtc": expiry.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "manifest": updater.internal_test_candidate_manifest_binding(
                target, "a" * 64
            ),
            "runtimeContractSha256": "b" * 64,
            "status": "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
            "storageAuthoritySha256": "1" * 64,
            "storageObservationSha256": "2" * 64,
            "transactionId": self.TRANSACTION_ID,
        }
        raw = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()
        return value, raw

    def reauthorization(
        self, onboarding: dict, onboarding_raw: bytes
    ) -> tuple[dict, dict[Path, str]]:
        now = datetime.now(timezone.utc).replace(microsecond=0)
        authority = Path(onboarding["commissioningAuthorityPath"])
        complete = Path(onboarding["evidencePath"]) / "complete.json"
        host = Path("/var/lib/uten-imp-internal-test-host-preparation/active.json")
        digests = {
            authority: "3" * 64,
            complete: "4" * 64,
            host: "5" * 64,
        }
        value = {
            "approvalReference": "CHG-REAUTH-20260814",
            "authorizedAtUtc": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "authorizedBoottimeNs": 10_000_000_000,
            "bootId": self.BOOT_ID,
            "candidateManifestSha256": onboarding["manifest"]["manifestSha256"],
            "commissioningAuthorityPath": str(authority),
            "commissioningAuthoritySha256": digests[authority],
            "completePath": str(complete),
            "completeSha256": digests[complete],
            "databaseIdentity": copy.deepcopy(self.DATABASE_IDENTITY),
            "databaseIdentitySha256": hashlib.sha256(
                (
                    json.dumps(self.DATABASE_IDENTITY, sort_keys=True, indent=2)
                    + "\n"
                ).encode()
            ).hexdigest(),
            "entryEnabled": False,
            "expiresAtUtc": (now + timedelta(hours=1)).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            ),
            "expiresBoottimeNs": 10_000_000_000 + 3600 * 1_000_000_000,
            "hostPreparationActivePath": str(host),
            "hostPreparationActiveSha256": digests[host],
            "kind": "uten-imp-internal-test-activation-reauthorization",
            "nonce": "6" * 32,
            "onboardingPath": str(updater.INTERNAL_TEST_ONBOARDING_RECEIPT),
            "onboardingSha256": hashlib.sha256(onboarding_raw).hexdigest(),
            "productionAuthority": False,
            "runtimeContractSha256": onboarding["runtimeContractSha256"],
            "schemaVersion": 1,
            "status": "AUTHORIZED_ACTIVATION_ONLY_ENTRY_CLOSED",
            "storageAuthoritySha256": onboarding["storageAuthoritySha256"],
            "storageObservationSha256": onboarding["storageObservationSha256"],
            "transactionId": onboarding["transactionId"],
            "version": onboarding["manifest"]["version"],
        }
        return value, digests

    def test_normal_completed_then_expired_onboarding_accepts_bound_reauthorization(self):
        onboarding, onboarding_raw = self.onboarding(currently_expired=True)
        value, digests = self.reauthorization(onboarding, onboarding_raw)
        with mock.patch.object(
            updater, "require_root_controlled_file"
        ), mock.patch.object(
            updater, "read_root_evidence_bytes", return_value=onboarding_raw
        ), mock.patch.object(
            updater.release_guard,
            "sha256_file",
            side_effect=lambda path: digests[Path(path)],
        ), mock.patch.object(
            updater, "current_boot_id", return_value=self.BOOT_ID
        ), mock.patch.object(
            updater, "current_boottime_ns", return_value=20_000_000_000
        ):
            self.assertEqual(
                "internal-test-activation-reauthorization-v1",
                updater.validate_internal_test_activation_reauthorization(
                    value,
                    onboarding=onboarding,
                    authenticated_expected_target=self.target(),
                    live_database_identity=self.DATABASE_IDENTITY,
                    runtime_contract_sha256=onboarding["runtimeContractSha256"],
                ),
            )

    def test_binding_failures_do_not_publish_state(self):
        onboarding, onboarding_raw = self.onboarding(currently_expired=True)
        value, digests = self.reauthorization(onboarding, onboarding_raw)
        publish = mock.Mock()
        cases = {
            "invalid-time": {"authorizedAtUtc": "2026-99-14T01:02:03Z"},
            "wrong-system": {"databaseIdentity": {"systemIdentifier": "other"}},
            "wrong-boot": {"bootId": "22222222-2222-4222-8222-222222222222"},
            "wrong-origin": {"onboardingSha256": "9" * 64},
            "wrong-version": {"version": "v2026.08.14-2"},
        }
        for label, mutation in cases.items():
            with self.subTest(label=label):
                candidate = copy.deepcopy(value)
                candidate.update(mutation)
                with mock.patch.object(
                    updater, "require_root_controlled_file"
                ), mock.patch.object(
                    updater,
                    "read_root_evidence_bytes",
                    return_value=onboarding_raw,
                ), mock.patch.object(
                    updater.release_guard,
                    "sha256_file",
                    side_effect=lambda path: digests[Path(path)],
                ), mock.patch.object(
                    updater, "current_boot_id", return_value=self.BOOT_ID
                ), mock.patch.object(
                    updater, "current_boottime_ns", return_value=20_000_000_000
                ), mock.patch.object(updater, "atomic_json", publish):
                    with self.assertRaises(updater.UpdaterError):
                        updater.validate_internal_test_activation_reauthorization(
                            candidate,
                            onboarding=onboarding,
                            authenticated_expected_target=self.target(),
                            live_database_identity=self.DATABASE_IDENTITY,
                            runtime_contract_sha256=onboarding[
                                "runtimeContractSha256"
                            ],
                        )
        publish.assert_not_called()

    def test_issuer_writes_once_and_binds_origin_target_system_boot_and_window(self):
        onboarding, onboarding_raw = self.onboarding(currently_expired=True)
        receipt = {
            "fields": onboarding,
            "path": str(updater.INTERNAL_TEST_ONBOARDING_RECEIPT),
            "sha256": hashlib.sha256(onboarding_raw).hexdigest(),
        }
        written: dict = {}
        digests = {
            Path(onboarding["commissioningAuthorityPath"]): "3" * 64,
            Path(onboarding["evidencePath"]) / "complete.json": "4" * 64,
            Path(
                "/var/lib/uten-imp-internal-test-host-preparation/active.json"
            ): "5" * 64,
        }

        def capture(_path: Path, value: dict, mode: int = 0o640) -> None:
            self.assertEqual(0o600, mode)
            written.update(copy.deepcopy(value))

        def read(path: Path, **_kwargs) -> bytes:
            if Path(path) == updater.INTERNAL_TEST_ONBOARDING_RECEIPT:
                return onboarding_raw
            return (json.dumps(written, sort_keys=True, indent=2) + "\n").encode()

        with mock.patch.object(
            updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            updater.os.path, "lexists", return_value=False
        ), mock.patch.object(
            updater, "require_root_controlled_file"
        ), mock.patch.object(
            updater, "read_root_evidence_bytes", side_effect=read
        ), mock.patch.object(
            updater.release_guard,
            "sha256_file",
            side_effect=lambda path: digests[Path(path)],
        ), mock.patch.object(
            updater, "current_boot_id", return_value=self.BOOT_ID
        ), mock.patch.object(
            updater, "current_boottime_ns", return_value=10_000_000_000
        ), mock.patch.object(
            updater,
            "require_internal_test_reauthorization_evidence_directory",
        ), mock.patch.object(updater, "atomic_json", side_effect=capture) as publish:
            issued = updater.issue_internal_test_activation_reauthorization(
                onboarding_receipt=receipt,
                authenticated_expected_target=self.target(),
                live_database_identity=self.DATABASE_IDENTITY,
                runtime_contract_sha256=onboarding["runtimeContractSha256"],
                approval_reference="CHG-REAUTH-20260814",
            )
        publish.assert_called_once()
        self.assertEqual(receipt["sha256"], written["onboardingSha256"])
        self.assertEqual(
            onboarding["manifest"]["manifestSha256"],
            written["candidateManifestSha256"],
        )
        self.assertEqual(self.DATABASE_IDENTITY, written["databaseIdentity"])
        self.assertEqual(self.BOOT_ID, written["bootId"])
        self.assertEqual(written["version"], self.target()["version"])
        authorized = datetime.strptime(
            written["authorizedAtUtc"], "%Y-%m-%dT%H:%M:%SZ"
        )
        expires = datetime.strptime(written["expiresAtUtc"], "%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(timedelta(hours=1), expires - authorized)
        self.assertEqual(issued["sha256"], hashlib.sha256(read(Path(issued["path"]))).hexdigest())

    def test_consumed_archive_blocks_reissue_without_a_write(self):
        onboarding, onboarding_raw = self.onboarding(currently_expired=True)
        receipt = {
            "fields": onboarding,
            "path": str(updater.INTERNAL_TEST_ONBOARDING_RECEIPT),
            "sha256": hashlib.sha256(onboarding_raw).hexdigest(),
        }
        archive = updater.internal_test_reauthorization_archive_path(
            onboarding["transactionId"]
        )
        publish = mock.Mock()
        with mock.patch.object(
            updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            updater.os.path,
            "lexists",
            side_effect=lambda path: Path(path) == archive,
        ), mock.patch.object(
            updater, "require_root_controlled_file"
        ), mock.patch.object(updater, "atomic_json", publish):
            with self.assertRaisesRegex(updater.UpdaterError, "already consumed"):
                updater.issue_internal_test_activation_reauthorization(
                    onboarding_receipt=receipt,
                    authenticated_expected_target=self.target(),
                    live_database_identity=self.DATABASE_IDENTITY,
                    runtime_contract_sha256=onboarding["runtimeContractSha256"],
                    approval_reference="CHG-REAUTH-20260814",
                )
        publish.assert_not_called()

    def test_unexpired_origin_refuses_issue_without_a_write(self):
        onboarding, onboarding_raw = self.onboarding(currently_expired=False)
        receipt = {
            "fields": onboarding,
            "path": str(updater.INTERNAL_TEST_ONBOARDING_RECEIPT),
            "sha256": hashlib.sha256(onboarding_raw).hexdigest(),
        }
        publish = mock.Mock()
        with mock.patch.object(
            updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(updater, "atomic_json", publish):
            with self.assertRaisesRegex(updater.UpdaterError, "remains current"):
                updater.issue_internal_test_activation_reauthorization(
                    onboarding_receipt=receipt,
                    authenticated_expected_target=self.target(),
                    live_database_identity=self.DATABASE_IDENTITY,
                    runtime_contract_sha256=onboarding["runtimeContractSha256"],
                    approval_reference="CHG-REAUTH-20260814",
                )
        publish.assert_not_called()

    def test_acceptance_honors_prepared_adoption_before_origin_archive(self):
        onboarding, _ = self.onboarding(currently_expired=True)
        storage_observation = Path(
            f"/var/lib/uten-imp-internal-test-commissioning/{self.TRANSACTION_ID}/"
            f"storage-before-terminal-{self.BOOT_ID}-1.json"
        )
        runtime_contract = {
            "databaseCommissionerSha256": "7" * 64,
            "deploymentProfile": "internal-test-local-v1",
            "storageAuthoritySha256": "8" * 64,
            "storageBootVerifierSha256": "9" * 64,
            "storageCompleteReceiptSha256": "a" * 64,
            "storageValidatorSha256": "b" * 64,
        }
        onboarding.update(
            {
                "commissionerSha256": runtime_contract[
                    "databaseCommissionerSha256"
                ],
                "storageCommissioningReceiptSha256": runtime_contract[
                    "storageCompleteReceiptSha256"
                ],
                "storageAuthoritySha256": runtime_contract[
                    "storageAuthoritySha256"
                ],
                "storageObservationPath": str(storage_observation),
            }
        )
        onboarding_raw = (
            json.dumps(onboarding, sort_keys=True, indent=2) + "\n"
        ).encode()
        receipt_sha = hashlib.sha256(onboarding_raw).hexdigest()
        reauthorization_sha = "d" * 64
        archive = updater.INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR / (
            self.TRANSACTION_ID + ".json"
        )
        adoption = {
            "archivePath": str(archive),
            "preparedAtUtc": datetime.now(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            ),
            "preparedBootId": self.BOOT_ID,
            "preparedBoottimeNs": 20_000_000_000,
            "reauthorizationArchivePath": str(
                updater.internal_test_reauthorization_archive_path(
                    self.TRANSACTION_ID
                )
            ),
            "reauthorizationSha256": reauthorization_sha,
            "receiptSha256": receipt_sha,
            "transactionId": self.TRANSACTION_ID,
        }
        terminal_storage = {
            "authoritySha256": runtime_contract["storageAuthoritySha256"],
            "storageBootVerifierSha256": runtime_contract[
                "storageBootVerifierSha256"
            ],
            "storageValidatorSha256": runtime_contract[
                "storageValidatorSha256"
            ],
        }
        target = self.target()
        projection_sha = hashlib.sha256(
            updater.canonical_signed_flyway_projection(target)
        ).hexdigest()
        live_evidence = {
            "flyway": {
                "headVersion": int(target["flywayHeadVersion"]),
                "signedProjectionSha256": projection_sha,
                "successfulMigrationCount": target["flywayMigrationCount"],
            }
        }
        present = {
            updater.INTERNAL_TEST_ONBOARDING_ADOPTION,
            updater.INTERNAL_TEST_ONBOARDING_RECEIPT,
            updater.INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
        }

        def read(path: Path, **_kwargs) -> bytes:
            path = Path(path)
            if path == updater.INTERNAL_TEST_ONBOARDING_ADOPTION:
                return (json.dumps(adoption, sort_keys=True, indent=2) + "\n").encode()
            if path == updater.INTERNAL_TEST_ONBOARDING_RECEIPT:
                return onboarding_raw
            if path == storage_observation:
                return (
                    json.dumps(terminal_storage, sort_keys=True, indent=2) + "\n"
                ).encode()
            raise AssertionError(f"unexpected evidence read: {path}")

        load = mock.Mock(return_value={"fields": {}, "sha256": reauthorization_sha})
        with mock.patch.object(
            updater, "deployment_profile", return_value="internal-test"
        ), mock.patch.object(
            updater, "internal_test_runtime_contract",
            return_value=(runtime_contract, onboarding["runtimeContractSha256"]),
        ), mock.patch.object(
            updater, "runtime_database_identity", return_value=self.DATABASE_IDENTITY
        ), mock.patch.object(
            updater.os.path, "lexists", side_effect=lambda path: Path(path) in present
        ), mock.patch.object(
            updater, "require_root_controlled_file"
        ), mock.patch.object(
            updater, "read_root_evidence_bytes", side_effect=read
        ), mock.patch.object(
            updater, "validate_internal_test_onboarding_adoption"
        ) as validate_adoption, mock.patch.object(
            updater, "validate_internal_test_onboarding_receipt"
        ), mock.patch.object(
            updater.release_guard,
            "sha256_file",
            return_value=runtime_contract["storageAuthoritySha256"],
        ), mock.patch.object(
            updater, "load_internal_test_activation_reauthorization", load
        ):
            accepted = updater.require_initial_database_onboarding_acceptance(
                target_info=target,
                target_manifest_sha256=onboarding["manifest"]["manifestSha256"],
                live_evidence=live_evidence,
                legacy_retirement=False,
                approve_database_change=False,
            )
        validate_adoption.assert_called_once()
        self.assertEqual(str(updater.INTERNAL_TEST_ONBOARDING_RECEIPT), accepted["path"])
        self.assertEqual(
            updater.INTERNAL_TEST_ONBOARDING_RECEIPT,
            load.call_args.kwargs["onboarding_receipt_path"],
        )
        self.assertEqual(
            reauthorization_sha, load.call_args.kwargs["expected_sha256"]
        )

    def test_adoption_binds_reauthorization_and_revalidates_prepared_boot_window(self):
        onboarding, onboarding_raw = self.onboarding(currently_expired=True)
        reauthorization, _digests = self.reauthorization(onboarding, onboarding_raw)
        reauthorization_raw = (
            json.dumps(reauthorization, sort_keys=True, indent=2) + "\n"
        ).encode()
        reauthorization_sha = hashlib.sha256(reauthorization_raw).hexdigest()
        adoption = {
            "archivePath": str(
                updater.INTERNAL_TEST_ONBOARDING_EVIDENCE_DIR
                / (self.TRANSACTION_ID + ".json")
            ),
            "preparedAtUtc": reauthorization["authorizedAtUtc"],
            "preparedBootId": self.BOOT_ID,
            "preparedBoottimeNs": reauthorization["authorizedBoottimeNs"] + 1,
            "receiptSha256": hashlib.sha256(onboarding_raw).hexdigest(),
            "reauthorizationArchivePath": str(
                updater.internal_test_reauthorization_archive_path(
                    self.TRANSACTION_ID
                )
            ),
            "reauthorizationSha256": reauthorization_sha,
            "reauthorizationSourcePath": str(
                updater.INTERNAL_TEST_ACTIVATION_REAUTHORIZATION
            ),
            "runtimeContractId": "uten-imp-internal-test-runtime-v1",
            "runtimeContractSha256": onboarding["runtimeContractSha256"],
            "schemaVersion": 1,
            "sourcePath": str(updater.INTERNAL_TEST_ONBOARDING_RECEIPT),
            "status": "ADOPTION_PREPARED",
            "transactionId": self.TRANSACTION_ID,
        }
        load = mock.Mock(return_value={"fields": reauthorization})

        def present(path: Path) -> bool:
            return Path(path) in {
                updater.INTERNAL_TEST_ONBOARDING_RECEIPT,
                updater.INTERNAL_TEST_ACTIVATION_REAUTHORIZATION,
            }

        with mock.patch.object(
            updater.os.path, "lexists", side_effect=present
        ), mock.patch.object(
            updater, "require_root_controlled_file"
        ), mock.patch.object(
            updater, "read_root_evidence_bytes", return_value=onboarding_raw
        ), mock.patch.object(
            updater, "validate_internal_test_onboarding_receipt"
        ), mock.patch.object(
            updater,
            "load_internal_test_activation_reauthorization",
            load,
        ):
            updater.validate_internal_test_onboarding_adoption(
                adoption,
                authenticated_expected_target=self.target(),
                live_database_identity=self.DATABASE_IDENTITY,
            )
        call = load.call_args.kwargs
        self.assertEqual(adoption["preparedAtUtc"], call["prepared_at_utc"])
        self.assertEqual(self.BOOT_ID, call["prepared_boot_id"])
        self.assertEqual(adoption["preparedBoottimeNs"], call["prepared_boottime_ns"])
        self.assertEqual(reauthorization_sha, call["expected_sha256"])

    def test_activate_archive_finalize_order_consumes_only_after_commit(self):
        activation = inspect.getsource(updater.activate_release)
        acceptance = activation.index("require_initial_database_onboarding_acceptance(")
        install = activation.index("install_root_owned_release(")
        prepare = activation.index("prepare_internal_test_onboarding_adoption(")
        archive = activation.index("archive_internal_test_onboarding(", prepare)
        active_commit = activation.index("atomic_json(\n                active_state_path", archive)
        runtime_commit = activation.index("write_runtime_authority(", active_commit)
        finalize = activation.index(
            "finalize_internal_test_onboarding_adoption_if_committed(",
            runtime_commit,
        )
        self.assertLess(acceptance, install)
        self.assertLess(prepare, archive)
        self.assertLess(archive, active_commit)
        self.assertLess(active_commit, runtime_commit)
        self.assertLess(runtime_commit, finalize)

        finalizer = inspect.getsource(
            updater.finalize_internal_test_onboarding_adoption_if_committed
        )
        revalidate = finalizer.index("validate_internal_test_onboarding_adoption(")
        active = finalizer.index("validate_active_release_state(", revalidate)
        runtime = finalizer.index("validate_existing_runtime_authority(", active)
        consume = finalizer.index(
            "durable_unlink(INTERNAL_TEST_ONBOARDING_ADOPTION)", runtime
        )
        self.assertLess(revalidate, active)
        self.assertLess(active, runtime)
        self.assertLess(runtime, consume)

        loader = inspect.getsource(
            updater.load_internal_test_activation_reauthorization
        )
        self.assertIn(
            "validate_internal_test_activation_reauthorization(", loader
        )
        for boundary in (
            updater.require_initial_database_onboarding_acceptance,
            updater.validate_internal_test_onboarding_adoption,
            updater.archive_internal_test_onboarding,
        ):
            self.assertIn(
                "load_internal_test_activation_reauthorization(",
                inspect.getsource(boundary),
            )


if __name__ == "__main__":
    unittest.main()
