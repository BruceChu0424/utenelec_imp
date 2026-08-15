#!/usr/bin/env python3
"""Focused fail-closed and power-loss contracts for backup commissioning."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import unittest
from contextlib import nullcontext
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "backup_commissioner_under_test", HERE / "backup_commissioner.py"
)
assert SPEC is not None and SPEC.loader is not None
commissioner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = commissioner
SPEC.loader.exec_module(commissioner)


def utc(delta: timedelta = timedelta()) -> str:
    return (datetime.now(timezone.utc) + delta).strftime("%Y-%m-%dT%H:%M:%SZ")


def capacity_receipt() -> dict[str, object]:
    gib = 1024**3
    return {
        "schemaVersion": 1,
        "receiptType": "backup-capacity-quota-acceptance",
        "status": "PASS",
        "checkedAtUtc": utc(),
        "mountTarget": "/data",
        "backupScope": "/data/backups",
        "quotaScope": "/data/backups/project-42",
        "quotaMechanism": "xfs-project-quota",
        "quotaEnforced": True,
        "quotaBytes": 100 * gib,
        "usedBytes": 20 * gib,
        "availableBytes": 80 * gib,
        "minimumFreeBytes": 10 * gib,
        "largestObservedFullBackupBytes": 5 * gib,
        "simultaneousFullReserveBytes": 20 * gib,
        "alertThresholdBytes": 30 * gib,
        "powerLossRecoveryTested": True,
        "filesystemFullFailureTested": True,
        "evidenceReference": "change/backup-capacity-20260812",
        "acceptanceOwner": "owner/backup",
        "secondReviewer": "reviewer/independent",
    }


def backup_acceptance() -> dict[str, object]:
    wal = "0000000100000000000000AA"
    points = [
        {
            "label": f"202608{i:02d}-010101F",
            "stopEpoch": 100 + i,
            "walStart": wal,
            "walStop": wal,
        }
        for i in range(1, 8)
    ]
    checks = {
        name: {"status": "PASS", "evidenceReference": f"uat/{name}"}
        for name in commissioner.BUSINESS_CHECKS
    }
    return {
        "schemaVersion": 1,
        "receiptType": "backup-acceptance-detail",
        "successful": True,
        "completedAtUtc": utc(),
        "approvalReference": "change/backup-commission",
        "targetVersion": "v1.2.3",
        "flywayHeadVersion": "255",
        "flywayMigrationCount": 236,
        "flywayMigrationSetSha256": "a" * 64,
        "databaseIdentity": {"systemIdentifier": "1234567890123456"},
        "continuousWal": {"lastArchivedWal": wal},
        "repositories": [
            {
                "repo": number,
                "successfulFullRestorePoints": 7,
                "restorePoints": points,
                "latestArchivedWal": wal,
            }
            for number in (1, 2)
        ],
        "healthReportSha256": "b" * 64,
        "wormEvidence": {
            "status": "VERIFIED",
            "versioningEnabled": True,
            "immutabilityMode": "COMPLIANCE",
            "credentialsIndependent": True,
            "failureDomainIndependent": True,
            "expiresAtUtc": utc(timedelta(days=30)),
        },
        "wormEvidenceSha256": "c" * 64,
        "activeRepo2Preflight": {
            "status": "ACTIVE_PREFLIGHT_PASS",
            "secretsIncluded": False,
        },
        "signedReleaseEvidence": {
            "manifestSha256": "d" * 64,
            "signatureSha256": "e" * 64,
        },
        "externalAlertEvidence": {
            "eventId": "evt-123",
            "providerMessageId": "provider-456",
            "eventSha256": "f" * 64,
            "receiptSha256": "1" * 64,
        },
        "isolatedPitrEvidence": {
            "repository": 2,
            "backupSet": points[-1]["label"],
            "restoreReceiptSha256": "2" * 64,
            "businessAcceptanceSha256": "3" * 64,
            "checks": checks,
        },
        "remoteImmutabilityVerifiedSeparately": True,
        "externalAlertDeliveryVerifiedSeparately": True,
        "isolatedRepo2PitrVerifiedSeparately": True,
    }


def unit_map() -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}
    for unit in commissioner.MANAGED_UNITS:
        result[unit] = {
            "LoadState": "loaded",
            "ActiveState": "inactive",
            "SubState": "dead",
            "UnitFileState": "disabled" if unit in commissioner.TIMER_UNITS else "static",
            "FragmentPath": f"/etc/systemd/system/{unit}",
            "DropInPaths": "",
        }
    return result


def record(completed: int = 0, phase: str = "stage-pending") -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "kind": commissioner.TRANSACTION_KIND,
        "transactionId": "20260812T010101Z-" + "a" * 32,
        "planSha256": "b" * 64,
        "phase": phase,
        "createdAtUtc": "2026-08-12T01:01:01Z",
        "updatedAtUtc": "2026-08-12T01:01:01Z",
        "completedStages": [item[0] for item in commissioner.STAGES[:completed]],
        "originalSystemd": unit_map(),
    }


class EvidenceValidationTest(unittest.TestCase):
    def test_json_duplicate_keys_and_non_finite_numbers_are_rejected(self):
        with self.assertRaisesRegex(commissioner.CommissionerError, "duplicate key"):
            commissioner._strict_json(
                b'{"successful":false,"successful":true}', "acceptance"
            )
        with self.assertRaisesRegex(commissioner.CommissionerError, "non-finite"):
            commissioner._strict_json(b'{"status":"PASS","bytes":NaN}', "capacity")

    def test_capacity_requires_quota_two_fulls_headroom_and_independent_review(self):
        validated = commissioner._validate_capacity(capacity_receipt())
        self.assertEqual("xfs-project-quota", validated["quotaMechanism"])
        for mutation in (
            {"quotaEnforced": False},
            {"simultaneousFullReserveBytes": 1},
            {"availableBytes": 1},
            {"secondReviewer": "owner/backup"},
            {"powerLossRecoveryTested": False},
        ):
            value = {**capacity_receipt(), **mutation}
            with self.assertRaises(commissioner.CommissionerError):
                commissioner._validate_capacity(value)

    def test_backup_acceptance_binds_two_repos_wal_worm_alert_and_pitr(self):
        validated = commissioner._validate_backup_acceptance(backup_acceptance())
        self.assertEqual({"repo1": 7, "repo2": 7}, validated["restorePointCounts"])
        for mutate in ("repo2", "worm", "alert", "pitr"):
            value = backup_acceptance()
            if mutate == "repo2":
                value["repositories"][1]["successfulFullRestorePoints"] = 6
            elif mutate == "worm":
                value["wormEvidence"]["versioningEnabled"] = False
            elif mutate == "alert":
                value["externalAlertEvidence"]["providerMessageId"] = ""
            else:
                value["isolatedPitrEvidence"]["checks"].pop("finance")
            with self.assertRaises(commissioner.CommissionerError):
                commissioner._validate_backup_acceptance(value)

    def test_assess_is_read_only_and_never_creates_state(self):
        assessment = {"kind": "safe"}
        with mock.patch.object(commissioner, "_require_root"), mock.patch.object(
            commissioner, "_assert_state_layout"
        ), mock.patch.object(commissioner, "build_assessment", return_value=assessment), mock.patch.object(
            commissioner, "_write_state_json", side_effect=AssertionError("write")
        ), mock.patch.object(commissioner.os, "mkdir", side_effect=AssertionError("mkdir")):
            envelope, digest = commissioner.assess()
        self.assertEqual(digest, envelope["assessmentSha256"])


class StageStateMachineTest(unittest.TestCase):
    def setUp(self):
        self.units = unit_map()
        self.writes: list[dict[str, object]] = []
        self.commands: list[tuple[str, ...]] = []
        self.plan = {
            "assessment": {
                "installer": {},
                "acceptance": {},
            }
        }

    def observe(self, _runner):
        return {key: dict(value) for key, value in self.units.items()}

    def mutate(self, _runner, *arguments):
        self.commands.append(tuple(arguments))
        if arguments[0] == "enable":
            timer = arguments[-1]
            self.units[timer]["UnitFileState"] = "enabled"
        elif arguments[0] == "start":
            timer = arguments[-1]
            self.units[timer]["ActiveState"] = "active"
        elif arguments[0] == "disable":
            timer = arguments[-1]
            self.units[timer]["UnitFileState"] = "disabled"
            self.units[timer]["ActiveState"] = "inactive"

    def persist(self, value, *, replace):
        self.writes.append(dict(value))
        return commissioner.canonical_bytes(value)

    def test_each_resume_advances_exactly_one_stage_in_reviewed_order(self):
        current = record()
        with mock.patch.object(commissioner, "_revalidate_evidence"), mock.patch.object(
            commissioner, "_observe_systemd", side_effect=self.observe
        ), mock.patch.object(commissioner, "_run_systemctl", side_effect=self.mutate), mock.patch.object(
            commissioner, "_contain_job"
        ), mock.patch.object(commissioner, "_set_active", side_effect=self.persist), mock.patch.object(
            commissioner, "_finalize_locked", return_value=({"status": "COMMISSIONED"}, "f" * 64)
        ):
            for index, expected in enumerate(("alert-drain", "repo1", "health")):
                result, _ = commissioner._advance_locked(current, self.plan, mock.Mock())
                self.assertEqual(expected, result["completedStage"])
                current = self.writes[-1]
                current = {**current, "phase": "stage-pending"}
            result, _ = commissioner._advance_locked(current, self.plan, mock.Mock())
        self.assertEqual("COMMISSIONED", result["status"])
        enabled = [command[-1] for command in self.commands if command[0] == "enable"]
        self.assertEqual(list(commissioner.TIMER_UNITS), enabled)
        self.assertEqual(
            list(commissioner.TIMER_UNITS),
            [command[-1] for command in self.commands if command[0] == "start"],
        )

    def test_pending_power_loss_accepts_only_old_or_fully_enabled_timer_state(self):
        current = record()
        self.units[commissioner.TIMER_UNITS[0]]["UnitFileState"] = "enabled"
        # Enabled but inactive is an ambiguous partial mutation.
        with mock.patch.object(commissioner, "_observe_systemd", side_effect=self.observe):
            with self.assertRaises(commissioner.CommissionerError):
                commissioner._verify_stage_map(current, mock.Mock(), pending_ok=True)

    def test_persistent_catch_up_job_failure_is_contained_before_stage_commit(self):
        current = record()
        job = commissioner.STAGES[0][2]

        def mutate(_runner, *arguments):
            self.commands.append(tuple(arguments))
            if arguments[0] == "enable":
                self.units[arguments[-1]]["UnitFileState"] = "enabled"
            elif arguments[0] == "start":
                self.units[arguments[-1]]["ActiveState"] = "active"
                self.units[job]["ActiveState"] = "failed"

        def contain(target, _runner):
            self.commands.append(("contain", target))
            self.units[target]["ActiveState"] = "inactive"

        with mock.patch.object(commissioner, "_revalidate_evidence"), mock.patch.object(
            commissioner, "_observe_systemd", side_effect=self.observe
        ), mock.patch.object(commissioner, "_run_systemctl", side_effect=mutate), mock.patch.object(
            commissioner, "_contain_job", side_effect=contain
        ), mock.patch.object(commissioner, "_set_active", side_effect=self.persist):
            result, _ = commissioner._advance_locked(current, self.plan, mock.Mock())
        self.assertEqual("alert-drain", result["completedStage"])
        self.assertEqual("inactive", self.units[job]["ActiveState"])
        self.assertEqual("active", self.units[commissioner.TIMER_UNITS[0]]["ActiveState"])
        self.assertIn(("contain", job), self.commands)

    def test_rollback_only_disables_timers_and_stops_jobs(self):
        for timer in commissioner.TIMER_UNITS:
            self.units[timer]["UnitFileState"] = "enabled"
            self.units[timer]["ActiveState"] = "active"
        with mock.patch.object(commissioner, "_run_systemctl", side_effect=self.mutate), mock.patch.object(
            commissioner, "_contain_job"
        ), mock.patch.object(commissioner, "_observe_systemd", side_effect=self.observe):
            commissioner._restore_initial_map(record(), mock.Mock())
        self.assertEqual(
            set(commissioner.TIMER_UNITS),
            {command[-1] for command in self.commands if command[0] == "disable"},
        )
        self.assertFalse(any(command[0] in {"start", "restart"} for command in self.commands))


class FinalizationFaultTest(unittest.TestCase):
    def test_marker_and_receipt_are_each_preceded_by_durable_phase_and_receipt_precedes_unlink(self):
        events: list[str] = []
        active = record(4, "stage-complete")
        plan = {
            "assessment": {
                "installer": {"sha256": "1" * 64},
                "acceptance": {
                    "backup": {"sha256": "2" * 64},
                    "capacity": {"sha256": "3" * 64},
                },
            }
        }

        def set_active(value, *, replace):
            events.append(f"active:{value['phase']}")
            return commissioner.canonical_bytes(value)

        marker = commissioner._commission_marker(active, plan)
        with mock.patch.object(commissioner.os.path, "lexists", return_value=False), mock.patch.object(
            commissioner, "_set_active", side_effect=set_active
        ), mock.patch.object(
            commissioner,
            "_write_installer_marker",
            side_effect=lambda _value: events.append("marker") or commissioner.canonical_bytes(marker),
        ), mock.patch.object(
            commissioner,
            "_write_or_verify",
            side_effect=lambda _path, _value: events.append("receipt") or b"receipt\n",
        ), mock.patch.object(
            commissioner, "_durable_unlink", side_effect=lambda _path: events.append("unlink")
        ):
            commissioner._finalize_locked(active, plan)
        self.assertEqual(
            [
                "active:commission-marker-pending",
                "marker",
                "active:commission-marker-written",
                "active:receipt-pending",
                "receipt",
                "active:receipt-written",
                "unlink",
            ],
            events,
        )

    def test_existing_marker_is_reused_after_power_loss_not_regenerated(self):
        active = record(4, "commission-marker-pending")
        plan = {
            "assessment": {
                "installer": {"sha256": "1" * 64},
                "acceptance": {
                    "backup": {"sha256": "2" * 64},
                    "capacity": {"sha256": "3" * 64},
                },
            }
        }
        marker = commissioner._commission_marker(active, plan)
        marker_raw = commissioner.canonical_bytes(marker)
        with mock.patch.object(commissioner.os.path, "lexists", return_value=True), mock.patch.object(
            commissioner, "_read_root_json", return_value=(marker, marker_raw)
        ), mock.patch.object(
            commissioner, "_write_installer_marker", side_effect=AssertionError("must reuse marker")
        ), mock.patch.object(commissioner, "_set_active", return_value=b"active\n"), mock.patch.object(
            commissioner, "_write_or_verify", return_value=b"receipt\n"
        ), mock.patch.object(commissioner, "_durable_unlink"):
            result, _ = commissioner._finalize_locked(active, plan)
        self.assertEqual(marker["commissionedAtUtc"], result["commissionedAtUtc"])

    def test_existing_marker_with_different_acceptance_digest_is_rejected(self):
        active = record(4, "commission-marker-pending")
        plan = {
            "assessment": {
                "installer": {"sha256": "1" * 64},
                "acceptance": {
                    "backup": {"sha256": "2" * 64},
                    "capacity": {"sha256": "3" * 64},
                },
            }
        }
        marker = commissioner._commission_marker(active, plan)
        marker["capacityAcceptanceSha256"] = "9" * 64
        with mock.patch.object(commissioner.os.path, "lexists", return_value=True), mock.patch.object(
            commissioner,
            "_read_root_json",
            return_value=(marker, commissioner.canonical_bytes(marker)),
        ):
            with self.assertRaises(commissioner.CommissionerError):
                commissioner._finalize_locked(active, plan)

    def test_power_cut_after_marker_before_active_update_reuses_exact_marker(self):
        active = record(4, "stage-complete")
        plan = {
            "assessment": {
                "installer": {"sha256": "1" * 64},
                "acceptance": {
                    "backup": {"sha256": "2" * 64},
                    "capacity": {"sha256": "3" * 64},
                },
            }
        }
        marker = commissioner._commission_marker(active, plan)
        marker_raw = commissioner.canonical_bytes(marker)
        # Disk boundary: commissioned marker exists, active is still the old
        # stage-complete bytes.  Resume must reuse the marker timestamp/bytes.
        with mock.patch.object(commissioner.os.path, "lexists", return_value=True), mock.patch.object(
            commissioner, "_read_root_json", return_value=(marker, marker_raw)
        ), mock.patch.object(commissioner, "_write_installer_marker", side_effect=AssertionError("rewrite")), mock.patch.object(
            commissioner, "_set_active", return_value=b"active\n"
        ), mock.patch.object(commissioner, "_write_or_verify", return_value=b"receipt\n"), mock.patch.object(
            commissioner, "_durable_unlink"
        ):
            result, _ = commissioner._finalize_locked(active, plan)
        self.assertEqual(marker["commissionedAtUtc"], result["commissionedAtUtc"])

    def test_power_cut_after_receipt_before_active_unlink_is_idempotent(self):
        active = record(4, "receipt-written")
        active.update(
            {
                "commissionedMarkerSha256": "4" * 64,
                "commissionReceiptSha256": hashlib.sha256(b"receipt\n").hexdigest(),
            }
        )
        plan = {
            "assessment": {
                "installer": {"sha256": "1" * 64},
                "acceptance": {
                    "backup": {"sha256": "2" * 64},
                    "capacity": {"sha256": "3" * 64},
                },
            }
        }
        marker = commissioner._commission_marker(active, plan)
        marker_raw = commissioner.canonical_bytes(marker)
        events: list[str] = []
        with mock.patch.object(commissioner.os.path, "lexists", return_value=True), mock.patch.object(
            commissioner, "_read_root_json", return_value=(marker, marker_raw)
        ), mock.patch.object(commissioner, "_set_active", return_value=b"active\n"), mock.patch.object(
            commissioner,
            "_write_or_verify",
            side_effect=lambda _path, _value: events.append("verify-receipt") or b"receipt\n",
        ), mock.patch.object(
            commissioner, "_durable_unlink", side_effect=lambda _path: events.append("unlink")
        ):
            commissioner._finalize_locked(active, plan)
        self.assertEqual(["verify-receipt", "unlink"], events)


class StaticSafetyContractTest(unittest.TestCase):
    def test_all_nine_release_transaction_markers_block_commissioning(self):
        expected = (
            "activation-failed.json",
            "activation-in-progress.json",
            "boot-enablement-in-progress.json",
            "recovery-in-progress.json",
            "recovery-ingress-pending.json",
            "recovery-ingress-authorization.json",
            "recovery-ingress-finalizing.json",
            "internal-test-onboarding-adoption.json",
            "internal-test-activation-reauthorization.json",
        )
        self.assertEqual(expected, tuple(path.name for path in commissioner.RELEASE_MARKERS))
        for marker in commissioner.RELEASE_MARKERS:
            with self.subTest(marker=marker.name), mock.patch.object(
                commissioner.os.path,
                "lexists",
                side_effect=lambda path, blocked=marker: Path(path) == blocked,
            ):
                with self.assertRaisesRegex(
                    commissioner.CommissionerError,
                    "pending transaction evidence blocks commissioning",
                ):
                    commissioner._require_no_pending_evidence()

    def test_only_four_backup_timers_are_in_commission_scope(self):
        self.assertEqual(
            (
                "uten-pgbackup-alert-drain.timer",
                "uten-pgbackup.timer",
                "uten-pgbackup-health.timer",
                "uten-pgbackup-repo2.timer",
            ),
            commissioner.TIMER_UNITS,
        )
        source = (HERE / "backup_commissioner.py").read_text(encoding="utf-8")
        self.assertNotIn('"uten-imp-updater.timer"', source)
        self.assertNotIn('"uten-imp-retention.timer"', source)
        self.assertNotIn("/etc/pgbackrest", source)
        self.assertNotIn("repo2-secrets", source)

    def test_daily_timers_are_persistent_and_jobs_have_signal_oom_terminal_boundary(self):
        for name in ("uten-pgbackup.timer.example", "uten-pgbackup-repo2.timer.example"):
            self.assertIn("Persistent=true", (HERE.parents[1] / "systemd" / name).read_text(encoding="utf-8"))
        for name in ("uten-pgbackup.service.example", "uten-pgbackup-repo2.service.example"):
            source = (HERE.parents[1] / "systemd" / name).read_text(encoding="utf-8")
            self.assertIn("RestartPreventExitStatus=78", source)
            self.assertIn("SIGKILL", source)
            self.assertIn("TimeoutStartSec=12h", source)
            self.assertIn("active-transaction.json", source)


if __name__ == "__main__":
    unittest.main()
