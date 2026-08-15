from __future__ import annotations

import contextlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SOURCE = Path(__file__).with_name("existing-test-host-internal-db-commissioner.py")
SPEC = importlib.util.spec_from_file_location(
    "db_commissioner_worker_request_v2_under_test", SOURCE
)
assert SPEC is not None and SPEC.loader is not None
commissioner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = commissioner
SPEC.loader.exec_module(commissioner)


VERSION = "v2026.08.14-1"
APPROVAL = "CHG-2026-0814-WORKER-V2"
BOOT_ID = "11111111-1111-4111-8111-111111111111"
OTHER_BOOT_ID = "22222222-2222-4222-8222-222222222222"
UNIT_SHA256 = "3" * 64
CONTRACT_SHA256 = "4" * 64


def request_value(
    *,
    boot_id: str = BOOT_ID,
    unit_sha256: str = UNIT_SHA256,
    runtime_contract_sha256: str = CONTRACT_SHA256,
) -> dict[str, object]:
    return commissioner.worker_request_value(
        VERSION,
        APPROVAL,
        boot_id=boot_id,
        unit_sha256=unit_sha256,
        runtime_contract_sha256=runtime_contract_sha256,
    )


def recompute_request_id(value: dict[str, object]) -> dict[str, object]:
    core = {key: item for key, item in value.items() if key != "requestId"}
    return {
        **core,
        "requestId": commissioner.sha256_bytes(
            commissioner.canonical_bytes(core)
        )[:32],
    }


class WorkerRequestV2ContractTest(unittest.TestCase):
    def test_producer_emits_the_exact_v2_authority(self) -> None:
        request = request_value()
        self.assertEqual(
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
            set(request),
        )
        self.assertEqual(2, request["schemaVersion"])
        self.assertEqual(commissioner.COMMISSIONER_UNIT, request["systemdUnit"])
        self.assertEqual(commissioner.WORKER_CGROUP, request["controlGroup"])
        commissioner.validate_worker_request(request)

    def test_v1_unknown_fields_and_fixed_identity_tamper_are_rejected(self) -> None:
        v1 = {
            "approvalReference": APPROVAL,
            "kind": "uten-imp-internal-test-db-worker-request",
            "requestId": "a" * 32,
            "schemaVersion": 1,
            "status": "AUTHORIZED_FIXED_CGROUP",
            "version": VERSION,
        }
        request = request_value()
        cases = {
            "v1": v1,
            "unknown": {**request, "unexpected": True},
            "request-id": {**request, "requestId": "f" * 32},
            "unit": recompute_request_id(
                {**request, "systemdUnit": "unreviewed.service"}
            ),
            "cgroup": recompute_request_id(
                {**request, "controlGroup": "/system.slice/unreviewed.service"}
            ),
            "boot-format": recompute_request_id({**request, "bootId": "not-a-boot"}),
            "unit-sha-format": recompute_request_id(
                {**request, "unitSha256": "A" * 64}
            ),
        }
        for label, changed in cases.items():
            with self.subTest(case=label), self.assertRaises(
                commissioner.CommissioningError
            ):
                commissioner.validate_worker_request(changed)

    def test_live_validator_rejects_rehashed_authority_drift(self) -> None:
        contract = {"databaseCommissionerUnitSha256": UNIT_SHA256}

        def validate(value: dict[str, object], live_unit_sha: str = UNIT_SHA256):
            with mock.patch.object(
                commissioner, "current_boot_id", return_value=BOOT_ID
            ), mock.patch.object(
                commissioner, "require_root_file"
            ), mock.patch.object(
                commissioner, "sha256_file", return_value=live_unit_sha
            ):
                commissioner.validate_worker_request_live(
                    value,
                    contract=contract,
                    runtime_contract_sha256=CONTRACT_SHA256,
                )

        validate(request_value())
        for label, changed in {
            "another-boot": request_value(boot_id=OTHER_BOOT_ID),
            "another-unit": request_value(unit_sha256="5" * 64),
            "another-runtime": request_value(runtime_contract_sha256="6" * 64),
        }.items():
            with self.subTest(case=label), self.assertRaises(
                commissioner.CommissioningError
            ):
                validate(changed)

        with self.assertRaisesRegex(
            commissioner.CommissioningError, "unit differs"
        ):
            validate(request_value(), live_unit_sha="7" * 64)
        with mock.patch.object(
            commissioner, "current_boot_id", return_value=BOOT_ID
        ), mock.patch.object(
            commissioner, "require_root_file"
        ), mock.patch.object(
            commissioner, "sha256_file", return_value=UNIT_SHA256
        ), self.assertRaisesRegex(
            commissioner.CommissioningError, "unit differs"
        ):
            commissioner.validate_worker_request_live(
                request_value(),
                contract={"databaseCommissionerUnitSha256": "8" * 64},
                runtime_contract_sha256=CONTRACT_SHA256,
            )


class WorkerRequestV2ExecutionGateTest(unittest.TestCase):
    def runtime(self):
        contract = {"databaseCommissionerUnitSha256": UNIT_SHA256}
        updater = SimpleNamespace(
            DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
            StateLock=lambda _path, **_kwargs: contextlib.nullcontext(),
            DatabaseMaintenanceLock=lambda: contextlib.nullcontext(),
            assert_pre_database_runtime_contract=mock.Mock(),
            read_root_evidence_bytes=mock.Mock(),
        )
        return contract, updater

    def test_worker_rejects_stale_boot_before_apply(self) -> None:
        contract, updater = self.runtime()
        raw = commissioner.canonical_bytes(request_value(boot_id=OTHER_BOOT_ID))
        updater.read_root_evidence_bytes.return_value = raw
        with mock.patch.object(
            commissioner, "assert_fixed_worker_supervision"
        ), mock.patch.object(
            commissioner,
            "bootstrap_runtime_contract",
            return_value=(contract, CONTRACT_SHA256),
        ), mock.patch.object(
            commissioner, "load_modules", return_value=(updater, object())
        ), mock.patch.object(
            commissioner,
            "runtime_contract",
            return_value=(contract, CONTRACT_SHA256),
        ), mock.patch.object(
            commissioner, "current_boot_id", return_value=BOOT_ID
        ), mock.patch.object(
            commissioner, "require_root_file"
        ), mock.patch.object(
            commissioner, "sha256_file", return_value=UNIT_SHA256
        ), mock.patch.object(
            commissioner, "apply"
        ) as apply, self.assertRaisesRegex(
            commissioner.CommissioningError, "another boot"
        ):
            commissioner.worker()
        apply.assert_not_called()

    def test_worker_passes_the_same_captured_request_and_digest_to_apply(self) -> None:
        contract, updater = self.runtime()
        request = request_value()
        raw = commissioner.canonical_bytes(request)
        updater.read_root_evidence_bytes.return_value = raw
        onboarding = {
            "evidencePath": "/fixed/evidence",
            "transactionId": "internal-test-db-20260814T120000Z-0123456789ab",
        }
        with mock.patch.object(
            commissioner, "assert_fixed_worker_supervision"
        ), mock.patch.object(
            commissioner,
            "bootstrap_runtime_contract",
            return_value=(contract, CONTRACT_SHA256),
        ), mock.patch.object(
            commissioner, "load_modules", return_value=(updater, object())
        ), mock.patch.object(
            commissioner,
            "runtime_contract",
            return_value=(contract, CONTRACT_SHA256),
        ), mock.patch.object(
            commissioner, "current_boot_id", return_value=BOOT_ID
        ), mock.patch.object(
            commissioner, "require_root_file"
        ), mock.patch.object(
            commissioner, "sha256_file", return_value=UNIT_SHA256
        ), mock.patch.object(
            commissioner, "strict_json", side_effect=AssertionError("path reopened")
        ), mock.patch.object(
            commissioner, "apply", return_value=onboarding
        ) as apply, mock.patch.object(
            commissioner,
            "archive_worker_request",
            return_value=Path("/fixed/worker-complete.json"),
        ):
            result = commissioner.worker()
        self.assertEqual("FIXED_CGROUP_COMPLETED", result["status"])
        apply.assert_called_once_with(
            VERSION,
            APPROVAL,
            worker_request_sha256=commissioner.sha256_bytes(raw),
            worker_request=request,
        )

    def test_apply_revalidates_the_request_inside_both_locks_before_mutation(self) -> None:
        contract, updater = self.runtime()
        request = request_value()
        refusal = commissioner.CommissioningError("live request authority drifted")
        with mock.patch.object(
            commissioner.os, "geteuid", return_value=0
        ), mock.patch.object(
            commissioner,
            "bootstrap_runtime_contract",
            return_value=(contract, CONTRACT_SHA256),
        ), mock.patch.object(
            commissioner, "load_modules", return_value=(updater, object())
        ), mock.patch.object(
            commissioner, "require_entry_closed"
        ), mock.patch.object(
            commissioner,
            "runtime_contract",
            return_value=(contract, CONTRACT_SHA256),
        ), mock.patch.object(
            commissioner, "validate_worker_request_live", side_effect=refusal
        ) as validate, mock.patch.object(
            commissioner, "verify_runtime_secret_binding"
        ) as verify_secret, mock.patch.object(
            commissioner, "storage_receipt"
        ) as storage, self.assertRaisesRegex(
            commissioner.CommissioningError, "authority drifted"
        ):
            commissioner.apply(
                VERSION,
                APPROVAL,
                worker_request_sha256=commissioner.sha256_bytes(
                    commissioner.canonical_bytes(request)
                ),
                worker_request=request,
            )
        validate.assert_called_once_with(
            request,
            contract=contract,
            runtime_contract_sha256=CONTRACT_SHA256,
        )
        updater.assert_pre_database_runtime_contract.assert_not_called()
        verify_secret.assert_not_called()
        storage.assert_not_called()


class WorkerRequestV2DispatchTest(unittest.TestCase):
    def test_dispatch_publishes_the_live_boot_unit_and_runtime_authority(self) -> None:
        contract = {"databaseCommissionerUnitSha256": UNIT_SHA256}
        state_lock_calls: list[dict[str, object]] = []

        class StateLock:
            def __init__(self, _path: Path, **kwargs: object):
                state_lock_calls.append(kwargs)

            def __enter__(self):
                return self

            def __exit__(self, *_arguments: object):
                return False

        updater = SimpleNamespace(
            DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
            StateLock=StateLock,
            assert_pre_database_runtime_contract=mock.Mock(),
            read_root_evidence_bytes=lambda path, **_kwargs: path.read_bytes(),
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "evidence"
            evidence.mkdir()
            request_path = evidence / "worker-request.json"
            onboarding_path = root / "onboarding.json"
            captured: list[dict[str, object]] = []

            def atomic(path: Path, value: dict[str, object]) -> None:
                path.write_bytes(commissioner.canonical_bytes(value))

            def run(command: list[str], **_kwargs: object):
                if command[:2] == ["/usr/bin/systemctl", "start"]:
                    captured.append(
                        json.loads(request_path.read_text(encoding="utf-8"))
                    )
                    request_path.unlink()
                    onboarding_path.write_bytes(
                        commissioner.canonical_bytes(
                            {
                                "approvalReference": APPROVAL,
                                "manifest": {"version": VERSION},
                            }
                        )
                    )
                return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

            def load_json(path: Path, _label: str):
                return json.loads(path.read_text(encoding="utf-8"))

            with mock.patch.object(
                commissioner.os, "geteuid", return_value=0
            ), mock.patch.object(
                commissioner, "EVIDENCE_BASE", evidence
            ), mock.patch.object(
                commissioner, "WORKER_REQUEST", request_path
            ), mock.patch.object(
                commissioner, "ONBOARDING_RECEIPT", onboarding_path
            ), mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=(contract, CONTRACT_SHA256),
            ), mock.patch.object(
                commissioner, "load_modules", return_value=(updater, object())
            ), mock.patch.object(
                commissioner, "require_entry_closed"
            ), mock.patch.object(
                commissioner,
                "runtime_contract",
                return_value=(contract, CONTRACT_SHA256),
            ), mock.patch.object(
                commissioner, "verify_runtime_secret_binding"
            ), mock.patch.object(
                commissioner, "assert_fixed_worker_unit_pre_dispatch"
            ), mock.patch.object(
                commissioner, "current_boot_id", return_value=BOOT_ID
            ), mock.patch.object(
                commissioner, "atomic_json", side_effect=atomic
            ), mock.patch.object(
                commissioner, "strict_json", side_effect=load_json
            ), mock.patch.object(
                commissioner, "run", side_effect=run
            ):
                result = commissioner.dispatch_worker(VERSION, APPROVAL)

        self.assertEqual(APPROVAL, result["approvalReference"])
        self.assertEqual(1, len(captured))
        request = captured[0]
        commissioner.validate_worker_request(request)
        self.assertEqual(BOOT_ID, request["bootId"])
        self.assertEqual(UNIT_SHA256, request["unitSha256"])
        self.assertEqual(CONTRACT_SHA256, request["runtimeContractSha256"])
        self.assertEqual(
            [{"internal_test_worker_request_sha256": None}], state_lock_calls
        )

    def test_dispatch_refuses_same_business_request_from_another_boot(self) -> None:
        contract = {"databaseCommissionerUnitSha256": UNIT_SHA256}
        updater = SimpleNamespace(
            DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
            StateLock=mock.Mock(side_effect=AssertionError("lock entered")),
            assert_pre_database_runtime_contract=mock.Mock(),
            read_root_evidence_bytes=lambda path, **_kwargs: path.read_bytes(),
        )
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            request_path = evidence / "worker-request.json"
            request_path.write_bytes(
                commissioner.canonical_bytes(request_value(boot_id=OTHER_BOOT_ID))
            )
            with mock.patch.object(
                commissioner.os, "geteuid", return_value=0
            ), mock.patch.object(
                commissioner, "EVIDENCE_BASE", evidence
            ), mock.patch.object(
                commissioner, "WORKER_REQUEST", request_path
            ), mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=(contract, CONTRACT_SHA256),
            ), mock.patch.object(
                commissioner, "load_modules", return_value=(updater, object())
            ), mock.patch.object(
                commissioner, "require_entry_closed"
            ), mock.patch.object(
                commissioner,
                "runtime_contract",
                return_value=(contract, CONTRACT_SHA256),
            ), mock.patch.object(
                commissioner, "verify_runtime_secret_binding"
            ), mock.patch.object(
                commissioner, "assert_fixed_worker_unit_pre_dispatch"
            ), mock.patch.object(
                commissioner, "current_boot_id", return_value=BOOT_ID
            ), mock.patch.object(
                commissioner, "run"
            ) as run, self.assertRaisesRegex(
                commissioner.CommissioningError, "another.*pending"
            ):
                commissioner.dispatch_worker(VERSION, APPROVAL)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
