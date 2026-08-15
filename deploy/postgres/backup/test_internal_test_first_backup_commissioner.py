#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "internal_test_first_backup_commissioner_tested",
    HERE / "internal_test_first_backup_commissioner.py",
)
assert SPEC is not None and SPEC.loader is not None
commissioner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(commissioner)


class NoopLock:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None


class OrderedLock:
    def __init__(self, name: str, events: list[str]):
        self.name = name
        self.events = events

    def __enter__(self):
        self.events.append(f"{self.name}-enter")
        return self

    def __exit__(self, *_args):
        self.events.append(f"{self.name}-exit")


def unit(*, active: str = "inactive", enabled: str = "disabled", pid: int = 0) -> dict:
    return {
        "ActiveState": active,
        "DropInPaths": "",
        "ExecStart": "",
        "FragmentPath": "/etc/systemd/system/fixed",
        "Group": "root",
        "LoadState": "loaded",
        "MainPID": pid,
        "SubState": "dead" if active != "active" else "running",
        "UnitFileState": enabled,
        "User": "root",
    }


def systemd_observation(*, postgres_pid: int = 100, backup_active: str = "inactive") -> dict:
    timers = {name: unit() for name in commissioner.TIMER_UNITS}
    services = {name: unit(active=backup_active if name == commissioner.PGBACKREST_SERVICE else "inactive") for name in commissioner.QUIESCENT_SERVICES}
    services[commissioner.PGBACKREST_SERVICE].update(
        {
            "ExecStart": "/usr/bin/python3 -I /usr/local/libexec/uten-imp-backup/locked_job.py repo1",
            "FragmentPath": str(commissioner.PGBACKREST_SERVICE_FILE),
        }
    )
    timers[commissioner.PGBACKREST_TIMER]["FragmentPath"] = str(
        commissioner.PGBACKREST_TIMER_FILE
    )
    return {
        "postgres": unit(active="active", enabled="enabled", pid=postgres_pid),
        "services": services,
        "timers": timers,
    }


def minimal_assessment() -> dict:
    value = {
        "archiveOverridePreimage": {
            "path": str(commissioner.ARCHIVE_OVERRIDE),
            "state": "absent",
        },
        "assets": {"producer": {"sha256": "1" * 64}},
        "authority": {"fingerprint": "2" * 64},
        "capacity": {"freePercent": 80},
        "cipherDirectoryPreimage": {
            "path": str(commissioner.CIPHER_DIRECTORY),
            "state": "absent",
        },
        "cipherTargetPreimage": {
            "path": str(commissioner.CIPHER_TARGET),
            "state": "absent",
        },
        "databaseIdentity": {"systemIdentifier": "123", "timeline": 1},
        "deploymentProfile": "internal-test",
        "firstBackupReceiptPreimage": {
            "path": str(commissioner.FIRST_BACKUP_RECEIPT),
            "state": "absent",
        },
        "loopback": {"endpoints": ["127.0.0.1:5432"], "outputSha256": "3" * 64},
        "pgBackRestIncludeDirPreimage": {
            "path": str(commissioner.PGBACKREST_INCLUDE_DIR),
            "state": "absent",
        },
        "pgBackRestIncludeRootPreimage": {
            "path": str(commissioner.PGBACKREST_INCLUDE_ROOT),
            "state": "absent",
        },
        "pgBackRestTool": {
            "binary": {"sha256": "6" * 64},
            "version": "pgBackRest 2.56.0",
            "versionOutputSha256": "7" * 64,
        },
        "pgBackRestConfigPreimage": {"state": "absent"},
        "repository": {
            "dev": 1,
            "entries": [],
            "gid": 1,
            "ino": 2,
            "mode": 0o750,
            "path": str(commissioner.REPOSITORY),
            "state": "empty-directory",
            "uid": 1,
        },
        "systemd": systemd_observation(),
    }
    value["stableBindingSha256"] = commissioner.sha256_bytes(
        commissioner.canonical_bytes(commissioner._stable_binding(value))
    )
    return value


def plan_for(assessment: dict | None = None) -> dict:
    assessment = assessment or minimal_assessment()
    return {
        "assessment": assessment,
        "assessmentSha256": commissioner.sha256_bytes(
            commissioner.canonical_bytes(assessment)
        ),
        "archiveOverrideSha256": commissioner.sha256_bytes(
            commissioner.ARCHIVE_OVERRIDE_BYTES
        ),
        "containsSecrets": False,
        "kind": commissioner.PLAN_KIND,
        "pgBackRestTargetSha256": "4" * 64,
        "recordedAtUtc": "2026-08-14T04:00:00Z",
        "repo1CipherSha256": "5" * 64,
        "schemaVersion": commissioner.SCHEMA_VERSION,
        "stableBindingSha256": assessment["stableBindingSha256"],
    }


class FakeProducer:
    FIRST_BACKUP_RECEIPT = commissioner.FIRST_BACKUP_RECEIPT
    RECEIPT_KIND = "uten-imp-internal-test-first-local-backup"

    def __init__(self):
        self.authority = {
            "binding": {"version": "v2026.08.14-1"},
            "onboarding": {
                "databaseIdentity": {"systemIdentifier": "123", "timeline": 1}
            },
            "updater": SimpleNamespace(StateLock=lambda _path: NoopLock()),
        }

    def load_authority(self):
        return self.authority

    def assert_no_markers(self):
        return None


class FakeLedger:
    def __init__(self, initial: list[str] | None = None):
        self.values: list[dict] = []
        for phase in initial or []:
            self.append(phase, {})

    def names(self):
        return [value["phase"] for value in self.values]

    def append(self, phase, evidence):
        expected = commissioner.PHASES[len(self.values)]
        if phase != expected:
            raise AssertionError(f"expected {expected}, got {phase}")
        self.values.append({"phase": phase, "evidence": dict(evidence)})
        return str(len(self.values))

    def load(self):
        return self.values


class StrictSchemaAndSecretContractTest(unittest.TestCase):
    def test_duplicate_keys_and_nonfinite_numbers_are_rejected(self):
        for raw in (b'{"a":1,"a":2}\n', b'{"a":NaN}\n', b'{"a":Infinity}\n'):
            with self.assertRaises(commissioner.CommissioningError):
                commissioner.strict_json_bytes(raw, "test")

    def test_repo1_config_is_fixed_encrypted_and_secret_never_enters_plan_json(self):
        secret = ("a" * 64 + "\n").encode()
        rendered = commissioner._render_pgbackrest(secret)
        self.assertIn(b"repo1-cipher-type=aes-256-cbc", rendered)
        self.assertIn(b"repo1-path=/data/backups/pgbackrest", rendered)
        self.assertIn(b"repo1-cipher-pass=" + b"a" * 64, rendered)
        plan = plan_for()
        encoded = commissioner.canonical_bytes(plan)
        self.assertNotIn(b"a" * 64, encoded)
        self.assertFalse(plan["containsSecrets"])

    def test_archive_override_is_later_than_pinned_disabled_fragment(self):
        self.assertGreater(
            commissioner.ARCHIVE_OVERRIDE.name,
            commissioner.INTERNAL_TEST_ARCHIVE_DISABLED.name,
        )
        self.assertIn(b"archive_mode = on", commissioner.ARCHIVE_OVERRIDE_BYTES)
        self.assertIn(b"archive-push %p", commissioner.ARCHIVE_OVERRIDE_BYTES)

    def test_existing_noncomment_pgbackrest_config_is_refused(self):
        observed = {"sha256": "a" * 64}
        with mock.patch.object(
            commissioner,
            "capture_file",
            return_value=(b"[global]\nrepo1-path=/old\n", observed),
        ), mock.patch.object(commissioner.os.path, "lexists", return_value=True):
            with self.assertRaisesRegex(commissioner.CommissioningError, "not an empty"):
                commissioner._observe_blank_config(123)

    def test_terminal_receipt_rejects_unknown_first_receipt_path_or_changed_bytes(self):
        transaction = commissioner.TRANSACTIONS_ROOT / ("a" * 64)
        receipt = {
            "completedAtUtc": "2026-08-14T04:00:00Z",
            "containsSecrets": False,
            "firstBackupReceipt": {
                "path": str(commissioner.FIRST_BACKUP_RECEIPT),
                "sha256": "b" * 64,
            },
            "kind": commissioner.TERMINAL_KIND,
            "localRecoveryOnly": True,
            "planSha256": "a" * 64,
            "productionAuthority": False,
            "repositoryMutationIsIrreversible": True,
            "restoreVerified": False,
            "schemaVersion": commissioner.SCHEMA_VERSION,
            "status": "COMMISSIONED_LOCAL_FIRST_FULL_ENTRY_CLOSED",
            "transactionPath": str(transaction),
        }
        changed_path = json.loads(json.dumps(receipt))
        changed_path["firstBackupReceipt"]["path"] = "/tmp/forged.json"
        with self.assertRaisesRegex(commissioner.CommissioningError, "schema"):
            commissioner._validate_terminal(changed_path, "a" * 64)
        commissioner._validate_terminal(receipt, "a" * 64)
        with mock.patch.object(
            commissioner,
            "capture_file",
            return_value=(b"changed\n", {"sha256": "c" * 64}),
        ):
            with self.assertRaisesRegex(commissioner.CommissioningError, "bytes changed"):
                commissioner._verify_terminal_first_receipt_reference(receipt)

    def test_durable_receipt_authorization_recovers_only_a_json_half_write(self):
        partial = b'{"schemaVersion":1'
        with mock.patch.object(
            commissioner.os.path, "lexists", return_value=True
        ), mock.patch.object(
            commissioner,
            "capture_file",
            return_value=(
                partial,
                {"sha256": commissioner.sha256_bytes(partial)},
            ),
        ), mock.patch.object(commissioner, "_durable_unlink") as unlink:
            evidence = commissioner._recover_authorized_partial_first_receipt()
        unlink.assert_called_once_with(commissioner.FIRST_BACKUP_RECEIPT)
        self.assertTrue(evidence["partialReceiptRemoved"])

        structured_unknown = commissioner.canonical_bytes({"forged": True})
        with mock.patch.object(
            commissioner.os.path, "lexists", return_value=True
        ), mock.patch.object(
            commissioner,
            "capture_file",
            return_value=(
                structured_unknown,
                {"sha256": commissioner.sha256_bytes(structured_unknown)},
            ),
        ), mock.patch.object(commissioner, "_durable_unlink") as unlink:
            evidence = commissioner._recover_authorized_partial_first_receipt()
        unlink.assert_not_called()
        self.assertFalse(evidence["partialReceiptRemoved"])


class StableCaptureContractTest(unittest.TestCase):
    def test_path_replacement_after_open_is_detected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "source.py"
            replacement = root / "replacement.py"
            target.write_bytes(b"a" * (1024 * 1024 + 5))
            replacement.write_bytes(b"b" * (1024 * 1024 + 5))
            target.chmod(0o600)
            replacement.chmod(0o600)
            real_read = commissioner.os.read
            swapped = False

            def read_then_swap(fd, size):
                nonlocal swapped
                block = real_read(fd, size)
                if block and not swapped:
                    os.replace(replacement, target)
                    swapped = True
                return block

            with mock.patch.object(commissioner, "_root_chain"), mock.patch.object(
                commissioner.os, "read", side_effect=read_then_swap
            ):
                with self.assertRaisesRegex(
                    commissioner.CommissioningError, "path changed"
                ):
                    commissioner.capture_file(
                        target,
                        "source",
                        uid=os.getuid(),
                        gid=os.getgid(),
                        mode=0o600,
                        maximum=2 * 1024 * 1024,
                    )

    def test_unpublished_phase_temporary_is_ignored_for_exact_resume(self):
        with tempfile.TemporaryDirectory() as temporary:
            transaction = Path(temporary)
            phases = transaction / "phases"
            preimages = transaction / "preimages"
            phases.mkdir()
            preimages.mkdir()
            orphan = phases / ".000-started.json.commission.1234.0123456789abcdef"
            orphan.write_bytes(b"partial")
            ledger = commissioner.PhaseLedger(transaction, "a" * 64)
            with mock.patch.object(
                commissioner, "_safe_directory"
            ), mock.patch.object(
                commissioner,
                "capture_file",
                return_value=(b"partial", {"sha256": "b" * 64}),
            ) as captured:
                self.assertEqual([], ledger.load())
            captured.assert_called_once()

    def test_unpublished_configuration_writer_stage_is_removed_for_resume(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "pgbackrest.conf"
            orphan = root / ".pgbackrest.conf.commission.1234.0123456789abcdef"
            orphan.write_bytes(b"partial-secret")
            orphan.chmod(0o600)
            with mock.patch.object(commissioner, "_root_chain"):
                commissioner._remove_interrupted_temporaries(
                    target,
                    uid=os.getuid(),
                    gid=os.getgid(),
                    mode=0o640,
                    maximum=64 * 1024,
                )
            self.assertFalse(orphan.exists())


class AssessmentAndPlanContractTest(unittest.TestCase):
    def test_assess_is_lock_free_and_write_free(self):
        assessment = minimal_assessment()
        with mock.patch.object(
            commissioner, "build_assessment", return_value=assessment
        ) as builder, mock.patch.object(
            commissioner, "_atomic_write"
        ) as writer, mock.patch.object(
            commissioner, "_default_release_lock"
        ) as lock:
            envelope, digest = commissioner.assess()
        builder.assert_called_once_with()
        writer.assert_not_called()
        lock.assert_not_called()
        self.assertEqual(digest, envelope["assessmentSha256"])

    def test_record_plan_reobserves_under_release_lock_and_never_serializes_cipher(self):
        assessment = minimal_assessment()
        expected = commissioner.sha256_bytes(commissioner.canonical_bytes(assessment))
        secret = ("c" * 64 + "\n").encode()
        writes: dict[Path, bytes] = {}

        def exists(path):
            return Path(path) in writes

        def write(path, raw, **_kwargs):
            writes[Path(path)] = raw

        def capture(path, *_args, **_kwargs):
            self.assertEqual(Path(path), commissioner.STAGED_CIPHER)
            return secret, {"sha256": commissioner.sha256_bytes(secret)}

        producer = FakeProducer()
        with mock.patch.object(commissioner, "_require_root"), mock.patch.object(
            commissioner.os.path, "lexists", side_effect=exists
        ), mock.patch.object(commissioner, "_atomic_write", side_effect=write), mock.patch.object(
            commissioner, "capture_file", side_effect=capture
        ), mock.patch.object(
            commissioner, "assert_external_markers_absent"
        ):
            plan, digest = commissioner.record_plan(
                expected_assessment_sha256=expected,
                confirmation=commissioner.RECORD_CONFIRMATION,
                assessor=lambda: assessment,
                producer_loader=lambda: (producer, {}),
                release_lock_factory=NoopLock,
                token_hex=lambda _size: "c" * 64,
            )
        self.assertEqual(commissioner.sha256_bytes(writes[commissioner.PLAN_PATH]), digest)
        self.assertNotIn(secret.strip(), writes[commissioner.PLAN_PATH])
        self.assertEqual(commissioner.sha256_bytes(secret), plan["repo1CipherSha256"])

    def test_record_plan_drift_refuses_before_secret_or_plan_write(self):
        assessment = minimal_assessment()
        writes = mock.Mock()
        producer = FakeProducer()
        with mock.patch.object(commissioner, "_require_root"), mock.patch.object(
            commissioner.os.path, "lexists", return_value=False
        ), mock.patch.object(commissioner, "_atomic_write", writes), mock.patch.object(
            commissioner, "assert_external_markers_absent"
        ):
            with self.assertRaisesRegex(commissioner.CommissioningError, "changed"):
                commissioner.record_plan(
                    expected_assessment_sha256="f" * 64,
                    confirmation=commissioner.RECORD_CONFIRMATION,
                    assessor=lambda: assessment,
                    producer_loader=lambda: (producer, {}),
                    release_lock_factory=NoopLock,
                )
        writes.assert_not_called()


class SystemdContractTest(unittest.TestCase):
    def test_pid1_full_uses_only_fixed_service_and_keeps_timer_disabled(self):
        observations = [systemd_observation(), systemd_observation()]
        calls: list[tuple[str, str | None]] = []
        with mock.patch.object(
            commissioner, "observe_systemd", side_effect=observations
        ), mock.patch.object(
            commissioner,
            "_systemctl",
            side_effect=lambda action, unit=None, **_kwargs: calls.append((action, unit)),
        ):
            evidence = commissioner._run_pid1_full()
        self.assertEqual(
            [("reset-failed", commissioner.PGBACKREST_SERVICE), ("start", commissioner.PGBACKREST_SERVICE)],
            calls,
        )
        self.assertFalse(evidence["timerEnabled"])

    def test_source_contains_no_enable_disable_or_direct_backup_command(self):
        source = (HERE / "internal_test_first_backup_commissioner.py").read_text(
            encoding="utf-8"
        )
        self.assertNotIn('"enable"', source)
        self.assertNotIn('"disable"', source)
        self.assertNotIn('("backup",)', source)
        service = (HERE.parents[1] / "systemd" / "uten-pgbackup.service.example").read_text(
            encoding="utf-8"
        )
        self.assertIn("locked_job.py repo1", service)

    def test_completed_full_and_locked_receipt_are_reconciled_without_second_start(self):
        producer = FakeProducer()
        terminal = {
            "backupCount": 1,
            "backupLabel": "20260814-040000F",
            "lockedJobReceipt": {"sha256": "a" * 64},
        }
        with mock.patch.object(
            commissioner, "_repo1_backup_state", return_value=terminal
        ), mock.patch.object(commissioner, "_run_pid1_full") as start:
            observed = commissioner._reconcile_or_run_pid1_full(
                producer, producer.authority
            )
        start.assert_not_called()
        self.assertTrue(observed["reconciledAfterInterruption"])

    def test_active_locked_job_without_pid1_service_is_contained_not_restarted(self):
        producer = FakeProducer()
        inactive = unit(active="inactive")
        with mock.patch.object(
            commissioner,
            "_repo1_backup_state",
            return_value={"backupCount": 0, "infoSha256": "b" * 64},
        ), mock.patch.object(
            commissioner.os.path, "lexists", return_value=True
        ), mock.patch.object(
            commissioner, "observe_unit", return_value=inactive
        ), mock.patch.object(commissioner, "_run_pid1_full") as start:
            with self.assertRaisesRegex(
                commissioner.CommissioningError, "reconcile it first"
            ):
                commissioner._reconcile_or_run_pid1_full(
                    producer, producer.authority
                )
        start.assert_not_called()

    def test_full_authorization_cannot_backdate_an_existing_backup(self):
        producer = FakeProducer()
        with mock.patch.object(
            commissioner,
            "_repo1_backup_state",
            return_value={"backupCount": 1, "infoSha256": "b" * 64},
        ), mock.patch.object(commissioner, "observe_systemd") as systemd:
            with self.assertRaisesRegex(
                commissioner.CommissioningError,
                "before durable PID1 full authorization",
            ):
                commissioner._pid1_full_authorization_preimage(
                    producer, producer.authority
                )
        systemd.assert_not_called()

    def test_full_authorization_requires_no_locked_job_marker(self):
        producer = FakeProducer()
        with mock.patch.object(
            commissioner,
            "_repo1_backup_state",
            return_value={"backupCount": 0, "infoSha256": "b" * 64},
        ), mock.patch.object(
            commissioner.os.path, "lexists", return_value=True
        ), mock.patch.object(commissioner, "observe_systemd") as systemd:
            with self.assertRaisesRegex(
                commissioner.CommissioningError, "preceded durable"
            ):
                commissioner._pid1_full_authorization_preimage(
                    producer, producer.authority
                )
        systemd.assert_not_called()


class ApplyResumeStateMachineTest(unittest.TestCase):
    def _patch_apply(self, ledger: FakeLedger, events: list[str], terminal_box: dict):
        assessment = minimal_assessment()
        plan = plan_for(assessment)
        producer = FakeProducer()

        def exclusive(path, value):
            if Path(path).name == "terminal.json":
                terminal_box.update(value)
            return "e" * 64

        def read_json(_path, label, **_kwargs):
            if "terminal" in label:
                raw = commissioner.canonical_bytes(terminal_box)
                return dict(terminal_box), raw
            raise AssertionError(label)

        postgres = SimpleNamespace(pw_uid=123, pw_gid=124)
        patchers = [
            mock.patch.object(commissioner, "_require_root"),
            mock.patch.object(commissioner, "_load_plan", return_value=(plan, commissioner.canonical_bytes(plan))),
            mock.patch.object(commissioner, "assert_external_markers_absent"),
            mock.patch.object(commissioner, "_revalidate_static_authority"),
            mock.patch.object(commissioner, "_verify_materialized_configuration"),
            mock.patch.object(commissioner, "_ensure_transaction", return_value=(Path("/fixed/transaction"), ledger)),
            mock.patch.object(commissioner, "_current_stable_binding", return_value=assessment["stableBindingSha256"]),
            mock.patch.object(commissioner, "_capture_preimage", side_effect=lambda *_args: events.append("capture") or {}),
            mock.patch.object(commissioner, "_materialize_configuration", side_effect=lambda *_args: events.append("config") or {}),
            mock.patch.object(commissioner, "_systemctl", side_effect=lambda action, *_args, **_kwargs: events.append(action)),
            mock.patch.object(
                commissioner,
                "_verified_restart_preimage",
                return_value={
                    "databaseIdentity": assessment["databaseIdentity"],
                    "loopback": assessment["loopback"],
                    "postgresMainPID": assessment["systemd"]["postgres"]["MainPID"],
                },
            ),
            mock.patch.object(commissioner, "_post_restart_evidence", return_value={"databaseIdentity": assessment["databaseIdentity"]}),
            mock.patch.object(commissioner, "_directory_entries", return_value=(SimpleNamespace(), [])),
            mock.patch.object(commissioner.pwd, "getpwnam", return_value=postgres),
            mock.patch.object(commissioner, "_stanza_create_and_check", side_effect=lambda *_args: events.append("stanza") or {"repositoryHasBytes": True}),
            mock.patch.object(
                commissioner,
                "_pid1_full_authorization_preimage",
                return_value={"infoSha256": "8" * 64, "timerEnabled": False},
            ),
            mock.patch.object(
                commissioner,
                "_reconcile_or_run_pid1_full",
                side_effect=lambda *_args: events.append("pid1-full") or {},
            ),
            mock.patch.object(commissioner, "_first_receipt_evidence", side_effect=lambda *_args: events.append("producer") or {"path": str(commissioner.FIRST_BACKUP_RECEIPT), "sha256": "f" * 64}),
            mock.patch.object(commissioner, "_exclusive_json", side_effect=exclusive),
            mock.patch.object(commissioner, "_read_root_json", side_effect=read_json),
            mock.patch.object(commissioner, "_durable_unlink", side_effect=lambda _path: events.append("active-unlink")),
            mock.patch.object(commissioner.os.path, "lexists", return_value=False),
        ]
        return assessment, plan, producer, patchers

    def test_lock_order_releases_maintenance_only_for_pid1_full_then_reacquires(self):
        ledger = FakeLedger()
        events: list[str] = []
        terminal: dict = {}
        assessment, plan, producer, patchers = self._patch_apply(ledger, events, terminal)
        for patcher in patchers:
            patcher.start()
        try:
            commissioner.apply_plan(
                expected_plan_sha256="a" * 64,
                confirmation=commissioner.APPLY_CONFIRMATION,
                producer_loader=lambda: (producer, {}),
                assessor=lambda: assessment,
                release_lock_factory=lambda: OrderedLock("release", events),
                maintenance_lock_factory=lambda: OrderedLock("maintenance", events),
            )
        finally:
            for patcher in reversed(patchers):
                patcher.stop()
        first_exit = events.index("maintenance-exit")
        full = events.index("pid1-full")
        second_enter = events.index("maintenance-enter", first_exit + 1)
        self.assertLess(first_exit, full)
        self.assertLess(full, second_enter)
        self.assertLess(second_enter, events.index("release-exit"))
        self.assertEqual(commissioner.PHASES, tuple(ledger.names()))
        self.assertFalse(terminal["productionAuthority"])
        self.assertFalse(terminal["restoreVerified"])

    def test_sigkill_after_repository_authorization_resumes_without_replaying_prior_mutations(self):
        ledger = FakeLedger()
        events: list[str] = []
        terminal: dict = {}
        assessment, _plan, producer, patchers = self._patch_apply(ledger, events, terminal)
        for patcher in patchers:
            patcher.start()
        try:
            with self.assertRaisesRegex(RuntimeError, "simulated-kill"):
                commissioner.apply_plan(
                    expected_plan_sha256="a" * 64,
                    confirmation=commissioner.APPLY_CONFIRMATION,
                    producer_loader=lambda: (producer, {}),
                    assessor=lambda: assessment,
                    release_lock_factory=NoopLock,
                    maintenance_lock_factory=NoopLock,
                    fault_hook=lambda phase: (_ for _ in ()).throw(RuntimeError("simulated-kill"))
                    if phase == commissioner.REPOSITORY_BOUNDARY
                    else None,
                )
            before = list(events)
            commissioner.apply_plan(
                expected_plan_sha256="a" * 64,
                confirmation=commissioner.APPLY_CONFIRMATION,
                producer_loader=lambda: (producer, {}),
                assessor=lambda: assessment,
                release_lock_factory=NoopLock,
                maintenance_lock_factory=NoopLock,
            )
        finally:
            for patcher in reversed(patchers):
                patcher.stop()
        after = events[len(before) :]
        self.assertNotIn("capture", after)
        self.assertNotIn("config", after)
        self.assertNotIn("daemon-reload", after)
        self.assertIn("stanza", after)
        self.assertEqual(commissioner.PHASES, tuple(ledger.names()))

    def test_repository_boundary_forbids_rollback_even_when_repo_probe_looks_empty(self):
        assessment = minimal_assessment()
        plan = plan_for(assessment)
        ledger = FakeLedger(list(commissioner.PHASES[: commissioner.PHASES.index(commissioner.REPOSITORY_BOUNDARY) + 1]))
        producer = FakeProducer()
        with mock.patch.object(commissioner, "_require_root"), mock.patch.object(
            commissioner, "_load_plan", return_value=(plan, b"plan")
        ), mock.patch.object(
            commissioner, "_ensure_transaction", return_value=(Path("/fixed/transaction"), ledger)
        ), mock.patch.object(
            commissioner, "_repository_has_bytes", return_value=False
        ), mock.patch.object(
            commissioner, "_revalidate_static_authority"
        ), mock.patch.object(commissioner, "_durable_unlink") as unlink:
            with self.assertRaisesRegex(commissioner.CommissioningError, "forbidden"):
                commissioner.rollback_pre_repository(
                    expected_plan_sha256="a" * 64,
                    confirmation=commissioner.ROLLBACK_CONFIRMATION,
                    producer_loader=lambda: (producer, {}),
                    release_lock_factory=NoopLock,
                    maintenance_lock_factory=NoopLock,
                )
        unlink.assert_not_called()

    def test_identity_drift_before_restart_is_zero_write_refusal(self):
        assessment = minimal_assessment()
        plan = plan_for(assessment)
        producer = FakeProducer()
        with mock.patch.object(
            commissioner,
            "_database_identity",
            return_value={"systemIdentifier": "different", "timeline": 1},
        ), mock.patch.object(commissioner, "_systemctl") as systemctl:
            with self.assertRaisesRegex(commissioner.CommissioningError, "drifted"):
                commissioner._verified_restart_preimage(
                    producer, producer.authority, plan
                )
        systemctl.assert_not_called()


class InstallerIntegrationContractTest(unittest.TestCase):
    def test_existing_host_installer_installs_both_fixed_assets_root_owned(self):
        spec = importlib.util.spec_from_file_location(
            "existing_host_installer_for_first_backup_test",
            HERE / "existing_host_installer.py",
        )
        assert spec is not None and spec.loader is not None
        installer = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = installer
        try:
            spec.loader.exec_module(installer)
        finally:
            sys.modules.pop(spec.name, None)
        assets = {asset.name: asset for asset in installer.ASSETS}
        for name, filename in (
            ("internal-test-first-backup-producer", "internal_test_first_backup.py"),
            (
                "internal-test-first-backup-commissioner",
                "internal_test_first_backup_commissioner.py",
            ),
        ):
            self.assertIn(name, assets)
            self.assertEqual(0o755, assets[name].mode)
            self.assertEqual(installer.LIBEXEC_DIR / filename, assets[name].target)
        specs = installer._expected_directory_specs(installer.Identity(100, 101))
        for path in (
            installer.INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR,
            installer.INTERNAL_TEST_FIRST_BACKUP_TRANSACTIONS_DIR,
            installer.INTERNAL_TEST_FIRST_BACKUP_RECEIPTS_DIR,
        ):
            self.assertEqual((0, 0, 0o700), specs[str(path)])


if __name__ == "__main__":
    unittest.main()
