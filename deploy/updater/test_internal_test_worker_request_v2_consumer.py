#!/usr/bin/env python3
"""Focused terminal-consumer tests for the fixed-cgroup worker request v2."""

from __future__ import annotations

import contextlib
import copy
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "uten_imp_release_updater_worker_request_v2_test",
    HERE / "release_updater.py",
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load release_updater.py")
updater = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = updater
SPEC.loader.exec_module(updater)
TERMINAL_ERRORS = (updater.UpdaterError, updater.release_guard.ReleaseGuardError)


VERSION = "v2026.08.14-1"
OTHER_VERSION = "v2026.08.14-2"
APPROVAL = "CHG-2026-0814-WORKER-V2"
OTHER_APPROVAL = "CHG-2026-0814-WORKER-OTHER"
BOOT_ID = "11111111-1111-4111-8111-111111111111"
OTHER_BOOT_ID = "22222222-2222-4222-8222-222222222222"
TRANSACTION_ID = "internal-test-db-20260814T120000Z-0123456789ab"
RUNTIME_CONTRACT_SHA256 = "4" * 64
OTHER_RUNTIME_CONTRACT_SHA256 = "5" * 64


def canonical_bytes(value: dict[str, object]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def worker_request(
    *,
    approval: str = APPROVAL,
    boot_id: str = BOOT_ID,
    control_group: str = updater.INTERNAL_TEST_DB_COMMISSIONER_CONTROL_GROUP,
    runtime_contract_sha256: str = RUNTIME_CONTRACT_SHA256,
    systemd_unit: str = updater.INTERNAL_TEST_DB_COMMISSIONER_UNIT,
    unit_sha256: str,
    version: str = VERSION,
) -> dict[str, object]:
    core: dict[str, object] = {
        "approvalReference": approval,
        "bootId": boot_id,
        "controlGroup": control_group,
        "kind": "uten-imp-internal-test-db-worker-request",
        "runtimeContractSha256": runtime_contract_sha256,
        "schemaVersion": 2,
        "status": "AUTHORIZED_FIXED_CGROUP",
        "systemdUnit": systemd_unit,
        "unitSha256": unit_sha256,
        "version": version,
    }
    request_id = hashlib.sha256(
        (json.dumps(core, sort_keys=True, indent=2) + "\n").encode("utf-8")
    ).hexdigest()[:32]
    return {**core, "requestId": request_id}


def rehash_request_id(value: dict[str, object]) -> dict[str, object]:
    core = {key: item for key, item in value.items() if key != "requestId"}
    request_id = hashlib.sha256(
        (json.dumps(core, sort_keys=True, indent=2) + "\n").encode("utf-8")
    ).hexdigest()[:32]
    return {**core, "requestId": request_id}


class WorkerRequestV2TerminalConsumerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database_root = self.root / "commissioning"
        self.evidence = self.database_root / TRANSACTION_ID
        self.evidence.mkdir(parents=True)
        self.request_path = self.evidence / "worker-request.committed.json"
        self.complete_path = self.evidence / "worker-complete.json"
        self.unit_path = self.root / "uten-imp-internal-db-commissioner.service"
        self.unit_bytes = b"[Service]\nExecStart=/fixed/commissioner\n"
        self.unit_path.write_bytes(self.unit_bytes)
        self.unit_path.chmod(0o644)
        self.unit_sha256 = hashlib.sha256(self.unit_bytes).hexdigest()
        self.onboarding: dict[str, object] = {
            "approvalReference": APPROVAL,
            "manifest": {"version": VERSION},
            "runtimeContractSha256": RUNTIME_CONTRACT_SHA256,
            "transactionId": TRANSACTION_ID,
        }
        self.install_request(worker_request(unit_sha256=self.unit_sha256))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def install_request(
        self,
        request: dict[str, object],
        *,
        completion_overrides: dict[str, object] | None = None,
    ) -> None:
        request_raw = canonical_bytes(request)
        self.request_path.write_bytes(request_raw)
        self.request_path.chmod(0o600)
        complete: dict[str, object] = {
            "kind": "uten-imp-internal-test-db-worker-receipt",
            "onboardingReceiptSha256": hashlib.sha256(
                canonical_bytes(self.onboarding)
            ).hexdigest(),
            "requestSha256": hashlib.sha256(request_raw).hexdigest(),
            "schemaVersion": 1,
            "status": "FIXED_CGROUP_COMPLETED",
            "transactionId": TRANSACTION_ID,
        }
        if completion_overrides:
            complete.update(completion_overrides)
        self.complete_path.write_bytes(canonical_bytes(complete))
        self.complete_path.chmod(0o600)

    @contextlib.contextmanager
    def live_boundary(
        self,
        *,
        runtime_contract_sha256: str = RUNTIME_CONTRACT_SHA256,
        unit_pin: str | None = None,
    ):
        contract = {
            "databaseCommissionerUnitSha256": (
                self.unit_sha256 if unit_pin is None else unit_pin
            )
        }
        actual_fstat = os.fstat
        actual_lstat = Path.lstat

        def root_details(details: os.stat_result) -> SimpleNamespace:
            return SimpleNamespace(
                st_mode=details.st_mode,
                st_dev=details.st_dev,
                st_ino=details.st_ino,
                st_nlink=details.st_nlink,
                st_uid=0,
                st_gid=0,
                st_size=details.st_size,
                st_mtime_ns=details.st_mtime_ns,
                st_ctime_ns=details.st_ctime_ns,
            )

        def root_fstat(descriptor: int) -> SimpleNamespace:
            return root_details(actual_fstat(descriptor))

        def root_lstat(path: Path) -> SimpleNamespace:
            return root_details(actual_lstat(path))

        with mock.patch.object(
            updater,
            "INTERNAL_TEST_DB_COMMISSIONER_UNIT_FILE",
            self.unit_path,
        ), mock.patch.object(
            updater,
            "internal_test_runtime_contract",
            return_value=(contract, runtime_contract_sha256),
        ), mock.patch.object(
            updater,
            "require_root_controlled_file",
        ), mock.patch.object(
            updater.os,
            "fstat",
            side_effect=root_fstat,
        ), mock.patch.object(
            updater.Path,
            "lstat",
            new=root_lstat,
        ):
            yield

    def validate(self) -> str:
        return updater.validate_internal_test_database_worker_terminal(
            self.onboarding,
            evidence_root=self.evidence,
            database_commissioning_root=self.database_root,
        )

    def test_accepts_exact_v2_and_does_not_rebind_to_activation_boot(self) -> None:
        expected_sha256 = hashlib.sha256(self.request_path.read_bytes()).hexdigest()
        with self.live_boundary(), mock.patch.object(
            updater,
            "current_boot_id",
            side_effect=AssertionError(
                "terminal adoption must not compare with the activation boot"
            ),
        ):
            self.assertEqual(expected_sha256, self.validate())

    def test_v1_and_unknown_schema_are_rejected_before_completion_is_read(self) -> None:
        v1 = {
            "approvalReference": APPROVAL,
            "kind": "uten-imp-internal-test-db-worker-request",
            "requestId": "a" * 32,
            "schemaVersion": 1,
            "status": "AUTHORIZED_FIXED_CGROUP",
            "version": VERSION,
        }
        cases = {
            "v1": v1,
            "schema-float": {
                **worker_request(unit_sha256=self.unit_sha256),
                "schemaVersion": 2.0,
            },
            "unknown-field": {
                **worker_request(unit_sha256=self.unit_sha256),
                "unexpected": True,
            },
        }
        actual_read = updater.read_root_evidence_bytes
        for label, request in cases.items():
            with self.subTest(case=label):
                self.install_request(request)
                reads: list[Path] = []

                def tracked_read(path: Path, **kwargs: object) -> bytes:
                    reads.append(Path(path))
                    return actual_read(path, **kwargs)

                with self.live_boundary(), mock.patch.object(
                    updater,
                    "read_root_evidence_bytes",
                    side_effect=tracked_read,
                ), self.assertRaises(TERMINAL_ERRORS):
                    self.validate()
                self.assertNotIn(self.complete_path, reads)

    def test_rehashed_request_cannot_escape_any_fixed_or_onboarding_binding(self) -> None:
        valid = worker_request(unit_sha256=self.unit_sha256)
        cases = {
            "approval": {**valid, "approvalReference": OTHER_APPROVAL},
            "version": {**valid, "version": OTHER_VERSION},
            "boot-format": {**valid, "bootId": "not-a-boot"},
            "runtime-contract": {
                **valid,
                "runtimeContractSha256": OTHER_RUNTIME_CONTRACT_SHA256,
            },
            "unit-pin": {**valid, "unitSha256": "6" * 64},
            "systemd-unit": {**valid, "systemdUnit": "unreviewed.service"},
            "control-group": {
                **valid,
                "controlGroup": "/system.slice/unreviewed.service",
            },
        }
        for label, changed in cases.items():
            with self.subTest(case=label):
                changed = rehash_request_id(changed)
                self.install_request(changed)
                before = {
                    self.request_path: self.request_path.read_bytes(),
                    self.complete_path: self.complete_path.read_bytes(),
                }
                with self.live_boundary(), self.assertRaises(TERMINAL_ERRORS):
                    self.validate()
                self.assertEqual(
                    before,
                    {path: path.read_bytes() for path in before},
                    "terminal rejection must not mutate durable evidence",
                )

    def test_request_id_tamper_is_rejected_even_when_all_core_fields_match(self) -> None:
        changed = worker_request(unit_sha256=self.unit_sha256)
        changed["requestId"] = "f" * 32
        self.install_request(changed)
        with self.live_boundary(), self.assertRaisesRegex(
            updater.UpdaterError,
            "request differs",
        ):
            self.validate()

    def test_live_runtime_contract_and_unit_are_revalidated_before_completion(self) -> None:
        actual_read = updater.read_root_evidence_bytes
        cases = {
            "runtime-contract": {
                "runtime_contract_sha256": OTHER_RUNTIME_CONTRACT_SHA256,
                "unit_pin": self.unit_sha256,
            },
            "unit-pin": {
                "runtime_contract_sha256": RUNTIME_CONTRACT_SHA256,
                "unit_pin": "7" * 64,
            },
        }
        for label, boundary in cases.items():
            with self.subTest(case=label):
                reads: list[Path] = []

                def tracked_read(path: Path, **kwargs: object) -> bytes:
                    reads.append(Path(path))
                    return actual_read(path, **kwargs)

                with self.live_boundary(**boundary), mock.patch.object(
                    updater,
                    "read_root_evidence_bytes",
                    side_effect=tracked_read,
                ), self.assertRaises(updater.UpdaterError):
                    self.validate()
                self.assertNotIn(self.complete_path, reads)

    def test_live_unit_byte_drift_is_rejected_before_completion(self) -> None:
        self.unit_path.write_bytes(self.unit_bytes + b"# drift\n")
        self.unit_path.chmod(0o644)
        actual_read = updater.read_root_evidence_bytes
        reads: list[Path] = []

        def tracked_read(path: Path, **kwargs: object) -> bytes:
            reads.append(Path(path))
            return actual_read(path, **kwargs)

        with self.live_boundary(), mock.patch.object(
            updater,
            "read_root_evidence_bytes",
            side_effect=tracked_read,
        ), self.assertRaisesRegex(updater.UpdaterError, "unit changed after review"):
            self.validate()
        self.assertNotIn(self.complete_path, reads)

    def test_completion_binds_request_onboarding_and_transaction(self) -> None:
        cases = {
            "request": {"requestSha256": "8" * 64},
            "onboarding": {"onboardingReceiptSha256": "9" * 64},
            "transaction": {
                "transactionId": "internal-test-db-20260814T130000Z-abcdefabcdef"
            },
            "status": {"status": "NOT_COMPLETED"},
            "schema-float": {"schemaVersion": 1.0},
        }
        request = worker_request(unit_sha256=self.unit_sha256)
        for label, changes in cases.items():
            with self.subTest(case=label):
                self.install_request(request, completion_overrides=changes)
                with self.live_boundary(), self.assertRaisesRegex(
                    updater.UpdaterError,
                    "completion receipt differs",
                ):
                    self.validate()

    def test_request_path_replacement_after_capture_is_never_reopened(self) -> None:
        original_raw = self.request_path.read_bytes()
        expected_sha256 = hashlib.sha256(original_raw).hexdigest()
        actual_read = updater.read_root_evidence_bytes
        replaced = False

        def replace_after_capture(path: Path, **kwargs: object) -> bytes:
            nonlocal replaced
            raw = actual_read(path, **kwargs)
            if Path(path) == self.request_path and not replaced:
                replacement = self.evidence / "replacement.json"
                tampered = copy.deepcopy(
                    worker_request(unit_sha256=self.unit_sha256)
                )
                tampered["requestId"] = "f" * 32
                replacement.write_bytes(canonical_bytes(tampered))
                replacement.chmod(0o600)
                os.replace(replacement, self.request_path)
                replaced = True
            return raw

        with self.live_boundary(), mock.patch.object(
            updater,
            "read_root_evidence_bytes",
            side_effect=replace_after_capture,
        ):
            self.assertEqual(expected_sha256, self.validate())
        self.assertTrue(replaced)
        self.assertNotEqual(original_raw, self.request_path.read_bytes())


if __name__ == "__main__":
    unittest.main()
