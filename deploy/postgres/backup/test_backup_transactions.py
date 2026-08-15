#!/usr/bin/env python3
"""Focused contracts for durable pgBackRest job transactions and reconciliation."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "locked_job_transactions_under_test", HERE / "locked_job.py"
)
assert SPEC is not None and SPEC.loader is not None
locked_job = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = locked_job
SPEC.loader.exec_module(locked_job)


def inventory(repository: int, *items: tuple[str, str, int]) -> dict[str, object]:
    backups = [
        {"label": label, "type": backup_type, "stopEpoch": stop_epoch}
        for label, backup_type, stop_epoch in sorted(items)
    ]
    digest = hashlib.sha256(locked_job._canonical_bytes(backups)).hexdigest()
    return {
        "repository": repository,
        "stanza": "uten-imp",
        "backups": backups,
        "inventorySha256": digest,
    }


def base_record(phase: str = "running") -> dict[str, object]:
    before = inventory(1, ("20260810-010101F", "full", 100))
    plan = locked_job.JOB_PLANS["repo1"]
    record = locked_job._base_transaction(
        "repo1",
        1,
        before,
        plan.steps[plan.backup_step - 1],
        plan.steps[plan.backup_step],
    )
    if phase == "running":
        return record
    after = inventory(
        1,
        ("20260810-010101F", "full", 100),
        ("20260812-010101F", "full", 200),
    )
    committed = {"label": "20260812-010101F", "type": "full", "stopEpoch": 200}
    record.update(
        {
            "phase": "committed",
            "postBackupInventory": after,
            "committedBackup": committed,
            "committedAtUtc": "2026-08-12T01:02:03Z",
        }
    )
    if phase == "committed":
        return record
    record.update(
        {
            "phase": "expire-pending",
            "expireStartedAtUtc": "2026-08-12T01:03:03Z",
        }
    )
    if phase == "expire-pending":
        return record
    if phase == "complete":
        record.update(
            {
                "phase": "complete",
                "finalInventory": after,
                "completedAtUtc": "2026-08-12T01:04:03Z",
            }
        )
        return record
    raise AssertionError(phase)


def assessment_for(record: dict[str, object], action: str, current: dict[str, object]):
    raw = locked_job._canonical_bytes(record)
    result = {
        "schemaVersion": 1,
        "kind": "uten-imp-backup-transaction-read-only-assessment",
        "job": "repo1",
        "transactionId": record["transactionId"],
        "activeEvidencePath": str(locked_job.ACTIVE_TRANSACTION_PATHS["repo1"]),
        "activeEvidenceSha256": locked_job._sha256(raw),
        "durablePhase": record["phase"],
        "currentInventory": current,
        "runtime": {"quiescent": True},
        "eligibleAction": action,
        "reason": "test",
        "containsSecrets": False,
    }
    return result, raw


class InventoryAndClassificationTest(unittest.TestCase):
    def test_pgbackrest_inventory_is_normalized_and_unhealthy_is_rejected(self):
        raw = json.dumps(
            [
                {
                    "name": "uten-imp",
                    "status": {"code": 0},
                    "backup": [
                        {
                            "label": "20260812-010101F",
                            "type": "full",
                            "timestamp": {"stop": 200},
                            "error": False,
                        }
                    ],
                }
            ]
        ).encode()
        self.assertEqual(
            ["20260812-010101F"],
            [item["label"] for item in locked_job.parse_pgbackrest_inventory(raw, 2)["backups"]],
        )
        bad = json.loads(raw)
        bad[0]["status"]["code"] = 1
        with self.assertRaises(locked_job.LockedJobError):
            locked_job.parse_pgbackrest_inventory(json.dumps(bad).encode(), 2)

    def test_running_transaction_allows_only_zero_or_exactly_one_new_full(self):
        record = base_record()
        before = record["preInventory"]
        one = inventory(
            1,
            ("20260810-010101F", "full", 100),
            ("20260812-010101F", "full", 200),
        )
        two = inventory(
            1,
            ("20260810-010101F", "full", 100),
            ("20260812-010101F", "full", 200),
            ("20260812-020202F", "full", 300),
        )
        self.assertEqual("abort-retry", locked_job._classification(record, before)[0])
        self.assertEqual("resume-expire", locked_job._classification(record, one)[0])
        self.assertEqual("none", locked_job._classification(record, two)[0])

    def test_committed_transaction_allows_expired_subset_only_if_new_full_remains(self):
        record = base_record("committed")
        committed_only = inventory(1, ("20260812-010101F", "full", 200))
        missing = inventory(1, ("20260810-010101F", "full", 100))
        unknown = inventory(
            1,
            ("20260812-010101F", "full", 200),
            ("20260812-020202F", "full", 300),
        )
        self.assertEqual("resume-expire", locked_job._classification(record, committed_only)[0])
        self.assertEqual("none", locked_job._classification(record, missing)[0])
        self.assertEqual("none", locked_job._classification(record, unknown)[0])


class DurablePhaseTest(unittest.TestCase):
    def test_normal_phase_order_receipt_precedes_active_unlink(self):
        before = inventory(1, ("20260810-010101F", "full", 100))
        after = inventory(
            1,
            ("20260810-010101F", "full", 100),
            ("20260812-010101F", "full", 200),
        )
        events: list[str] = []
        values = iter((before, after, after))
        transaction = locked_job.DurableBackupTransaction(
            "repo1", inventory_provider=lambda _repo: next(values)
        )

        def write_active(_job, value, *, replace):
            events.append(f"active:{value['phase']}:{replace}")
            return locked_job._canonical_bytes(value)

        def write_receipt(_path, _value, *, replace):
            self.assertFalse(replace)
            events.append("receipt")
            return b"receipt\n"

        with mock.patch.object(locked_job, "assert_no_pending_backup_transactions"), mock.patch.object(
            locked_job, "_write_active", side_effect=write_active
        ), mock.patch.object(locked_job, "_atomic_root_json", side_effect=write_receipt), mock.patch.object(
            locked_job, "_durable_unlink", side_effect=lambda _path: events.append("unlink")
        ):
            transaction.begin()
            transaction.backup_returned_success()
            transaction.mark_expire_pending()
            transaction.complete()
        self.assertEqual(
            [
                "active:running:False",
                "active:committed:True",
                "active:expire-pending:True",
                "active:complete:True",
                "receipt",
                "unlink",
            ],
            events,
        )

    def test_any_backup_command_failure_is_terminal_and_never_expires(self):
        commands: list[tuple[str, ...]] = []

        class Transaction:
            def begin(self):
                pass

            def mark_uncertain(self, reason):
                self.reason = reason

            def backup_returned_success(self):
                self.fail("success callback must not run")

        def runner(command):
            commands.append(command)
            if command[-1] == "backup":
                raise subprocess.CalledProcessError(2, command)

        with self.assertRaises(locked_job.TerminalLockedJobError):
            locked_job.run_job(
                "repo1",
                lock_factory=nullcontext,
                runner=runner,
                marker_gate=lambda: None,
                pending_gate=lambda: None,
                transaction_factory=lambda _job: Transaction(),
            )
        self.assertNotIn("expire", [command[-1] for command in commands])

    def test_pending_transaction_blocks_health_and_backup_before_any_command(self):
        for job in ("repo1", "repo2", "health"):
            runner = mock.Mock()
            with self.assertRaises(locked_job.TerminalLockedJobError):
                locked_job.run_job(
                    job,
                    lock_factory=nullcontext,
                    runner=runner,
                    pending_gate=mock.Mock(
                        side_effect=locked_job.TerminalLockedJobError("pending")
                    ),
                )
            runner.assert_not_called()


class ReadOnlyAndReconcileTest(unittest.TestCase):
    def setUp(self):
        self.record = base_record()
        self.current = self.record["preInventory"]
        self.assessment, self.active_raw = assessment_for(
            self.record, "abort-retry", self.current
        )
        self.assessment_sha = locked_job._sha256(
            locked_job._canonical_bytes(self.assessment)
        )
        self.active_sha = locked_job._sha256(self.active_raw)

    def test_assess_does_not_call_any_evidence_writer(self):
        with mock.patch.object(locked_job, "_require_root_supervisor"), mock.patch.object(
            locked_job, "assert_transaction_layout"
        ), mock.patch.object(locked_job, "_load_active", return_value=(self.record, self.active_raw)), mock.patch.object(
            locked_job, "_atomic_root_json", side_effect=AssertionError("write")
        ), mock.patch.object(locked_job, "_durable_unlink", side_effect=AssertionError("unlink")):
            envelope, digest = locked_job.transaction_assess(
                "repo1",
                lock_factory=nullcontext,
                inventory_provider=lambda _repo: self.current,
                runtime_observer=lambda _job: {"quiescent": True},
            )
        self.assertEqual(digest, envelope["assessmentSha256"])
        self.assertEqual("abort-retry", envelope["assessment"]["eligibleAction"])

    def _reconcile_patches(self, events, *, unlink_side_effect=None):
        return (
            mock.patch.object(locked_job, "_require_root_supervisor"),
            mock.patch.object(locked_job, "assert_transaction_layout"),
            mock.patch.object(
                locked_job,
                "_transaction_assessment_locked",
                return_value=self.assessment,
            ),
            mock.patch.object(
                locked_job, "_load_active", return_value=(self.record, self.active_raw)
            ),
            mock.patch.object(
                locked_job,
                "_write_or_verify_reconcile_receipt",
                side_effect=lambda _path, _value: events.append("receipt") or b"receipt\n",
            ),
            mock.patch.object(
                locked_job,
                "_durable_unlink",
                side_effect=unlink_side_effect
                or (lambda _path: events.append("unlink")),
            ),
        )

    def test_abort_receipt_then_unlink_is_idempotent_after_power_cut(self):
        events: list[str] = []

        def power_cut(_path):
            events.append("unlink-attempt")
            raise OSError("simulated power loss")

        patches = self._reconcile_patches(events, unlink_side_effect=power_cut)
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
            with self.assertRaises(OSError):
                locked_job.transaction_reconcile(
                    "repo1",
                    action="abort-retry",
                    expected_active_sha256=self.active_sha,
                    expected_assessment_sha256=self.assessment_sha,
                    confirmation=locked_job.RECONCILE_ABORT_CONFIRMATION,
                    lock_factory=nullcontext,
                    marker_gate=lambda: None,
                )
        self.assertEqual(["receipt", "unlink-attempt"], events)

        events.clear()
        patches = self._reconcile_patches(events)
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
            result, _ = locked_job.transaction_reconcile(
                "repo1",
                action="abort-retry",
                expected_active_sha256=self.active_sha,
                expected_assessment_sha256=self.assessment_sha,
                confirmation=locked_job.RECONCILE_ABORT_CONFIRMATION,
                lock_factory=nullcontext,
                marker_gate=lambda: None,
            )
        self.assertEqual("ABORTED_WITH_PROVEN_NO_NEW_BACKUP", result["status"])
        self.assertEqual(["receipt", "unlink"], events)

    def test_complete_receipt_then_unlink_is_idempotent_after_power_cut(self):
        self.record = base_record("complete")
        self.current = self.record["finalInventory"]
        self.assessment, self.active_raw = assessment_for(
            self.record, "finalize-complete", self.current
        )
        self.assessment_sha = locked_job._sha256(locked_job._canonical_bytes(self.assessment))
        self.active_sha = locked_job._sha256(self.active_raw)
        events: list[str] = []

        def writer(path, _value):
            events.append("completion" if path.name.endswith(".json") and "reconcile" not in path.name else "reconcile")
            return b"receipt\n"

        with mock.patch.object(locked_job, "_require_root_supervisor"), mock.patch.object(
            locked_job, "assert_transaction_layout"
        ), mock.patch.object(locked_job, "_transaction_assessment_locked", return_value=self.assessment), mock.patch.object(
            locked_job, "_load_active", return_value=(self.record, self.active_raw)
        ), mock.patch.object(locked_job, "_write_or_verify_reconcile_receipt", side_effect=writer), mock.patch.object(
            locked_job, "_durable_unlink", side_effect=lambda _path: (_ for _ in ()).throw(OSError("power loss"))
        ):
            with self.assertRaises(OSError):
                locked_job.transaction_reconcile(
                    "repo1",
                    action="finalize-complete",
                    expected_active_sha256=self.active_sha,
                    expected_assessment_sha256=self.assessment_sha,
                    confirmation=locked_job.RECONCILE_COMPLETE_CONFIRMATION,
                    lock_factory=nullcontext,
                    marker_gate=lambda: None,
                )
        self.assertEqual(["reconcile", "completion"], events)

    def test_expire_failure_changes_active_phase_and_requires_fresh_assessment(self):
        self.record = base_record("committed")
        self.current = self.record["postBackupInventory"]
        self.assessment, self.active_raw = assessment_for(
            self.record, "resume-expire", self.current
        )
        self.assessment_sha = locked_job._sha256(locked_job._canonical_bytes(self.assessment))
        self.active_sha = locked_job._sha256(self.active_raw)
        phases: list[dict[str, object]] = []

        def replace(_self, value):
            validated = locked_job._validate_transaction(value, "repo1")
            phases.append(validated)
            _self.record = validated

        with mock.patch.object(locked_job, "_require_root_supervisor"), mock.patch.object(
            locked_job, "assert_transaction_layout"
        ), mock.patch.object(locked_job, "_transaction_assessment_locked", return_value=self.assessment), mock.patch.object(
            locked_job, "_load_active", return_value=(self.record, self.active_raw)
        ), mock.patch.object(locked_job, "_write_or_verify_reconcile_receipt", return_value=b"receipt\n"), mock.patch.object(
            locked_job.DurableBackupTransaction, "_replace", new=replace
        ):
            with self.assertRaises(locked_job.TerminalLockedJobError):
                locked_job.transaction_reconcile(
                    "repo1",
                    action="resume-expire",
                    expected_active_sha256=self.active_sha,
                    expected_assessment_sha256=self.assessment_sha,
                    confirmation=locked_job.RECONCILE_EXPIRE_CONFIRMATION,
                    lock_factory=nullcontext,
                    marker_gate=lambda: None,
                    runner=mock.Mock(side_effect=OSError("expire failed")),
                )
        self.assertEqual(["committed", "expire-pending", "uncertain"], [p["phase"] for p in phases])
        new_active_raw = locked_job._canonical_bytes(phases[-1])
        self.assertNotEqual(self.active_sha, locked_job._sha256(new_active_raw))

    def test_global_pgbackrest_process_conservatively_blocks_assessment(self):
        systemd = subprocess.CompletedProcess(
            [],
            0,
            "LoadState=loaded\nActiveState=inactive\nSubState=dead\nMainPID=0\nResult=success\n",
            "",
        )
        with mock.patch.object(
            locked_job.subprocess,
            "run",
            side_effect=[systemd, subprocess.CompletedProcess([], 0, "", "")],
        ):
            observed = locked_job._runtime_quiescence("repo1")
        self.assertFalse(observed["quiescent"])
        self.assertTrue(observed["pgBackRestProcessPresent"])


if __name__ == "__main__":
    unittest.main()
