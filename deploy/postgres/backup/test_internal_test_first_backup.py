#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from contextlib import AbstractContextManager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("internal_test_first_backup.py")
SPEC = importlib.util.spec_from_file_location("internal_test_first_backup", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
first = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(first)


NOW = datetime(2026, 8, 14, 4, 0, 0, tzinfo=timezone.utc)
SYSTEM_ID = "7523456789012345678"
TIMELINE = 1
LABEL = "20260814-030000F"
STOP_EPOCH = int((NOW - timedelta(minutes=30)).timestamp())
WAL_START = "0000000100000000000000A0"
WAL_STOP = "0000000100000000000000A2"


def database_identity() -> dict:
    return {
        "canonicalHistorySha256": "1" * 64,
        "headVersion": 272,
        "roleAclContractSha256": "2" * 64,
        "signedProjectionSha256": "3" * 64,
        "successfulMigrationCount": 272,
        "systemIdentifier": SYSTEM_ID,
        "timeline": TIMELINE,
    }


def repo_info(*, stop: int = STOP_EPOCH, backup_type: str = "full") -> bytes:
    return json.dumps(
        [
            {
                "archive": [
                    {
                        "database": {"id": 1, "repo-key": 1},
                        "max": WAL_STOP,
                        "min": WAL_START,
                    }
                ],
                "backup": [
                    {
                        "archive": {"start": WAL_START, "stop": WAL_STOP},
                        "database": {"id": 1, "repo-key": 1},
                        "error": False,
                        "label": LABEL,
                        "timestamp": {"start": stop - 60, "stop": stop},
                        "type": backup_type,
                    }
                ],
                "db": [{"id": 1, "system-id": SYSTEM_ID, "version": "16"}],
                "name": "uten-imp",
                "repo": [{"key": 1, "status": {"code": 0, "message": "ok"}}],
                "status": {"code": 0, "message": "ok"},
            }
        ],
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def inventory(*items: tuple[str, str, int]) -> dict:
    backups = [
        {"label": label, "type": backup_type, "stopEpoch": stop}
        for label, backup_type, stop in sorted(items)
    ]
    return {
        "repository": 1,
        "stanza": "uten-imp",
        "backups": backups,
        "inventorySha256": first._sha256(first._canonical_bytes(backups)),
    }


def latest_full() -> dict:
    return first.parse_latest_full(
        repo_info(),
        identity=database_identity(),
        onboarding_completed_at=NOW - timedelta(hours=1),
        now=NOW,
    )


def locked_job_receipt() -> dict:
    pre = inventory()
    post = inventory((LABEL, "full", STOP_EPOCH))
    transaction_id = "20260814T033000Z-" + "a" * 32
    return {
        "schemaVersion": 1,
        "kind": "uten-imp-pgbackrest-backup-transaction-receipt",
        "transaction": {
            "schemaVersion": 1,
            "kind": "uten-imp-pgbackrest-backup-transaction",
            "transactionId": transaction_id,
            "job": "repo1",
            "repository": 1,
            "phase": "complete",
            "createdAtUtc": "2026-08-14T03:20:00Z",
            "updatedAtUtc": "2026-08-14T03:32:00Z",
            "preInventory": pre,
            "backupCommandSha256": first._sha256(
                first._canonical_bytes(list(first.PGBACKREST_BACKUP))
            ),
            "expireCommandSha256": first._sha256(
                first._canonical_bytes(list(first.PGBACKREST_EXPIRE))
            ),
            "postBackupInventory": post,
            "committedBackup": {
                "label": LABEL,
                "type": "full",
                "stopEpoch": STOP_EPOCH,
            },
            "committedAtUtc": "2026-08-14T03:31:00Z",
            "expireStartedAtUtc": "2026-08-14T03:31:30Z",
            "finalInventory": post,
            "completedAtUtc": "2026-08-14T03:32:00Z",
        },
        "containsSecrets": False,
    }


def authority(*, fingerprint: str = "f" * 64) -> dict:
    binding = {
        "commitSha": "a" * 40,
        "flywayHeadVersion": "272",
        "flywayMigrationSetSha256": "4" * 64,
        "manifestSha256": "5" * 64,
        "migratorJarSha256": "6" * 64,
        "releaseSequence": 1,
        "serverJarSha256": "7" * 64,
        "signedFlywayProjectionSha256": "3" * 64,
        "signingKeyId": "test-key",
        "version": "v2026.08.14-1",
    }
    fields = {
        "candidateBinding": binding,
        "candidatePayloadInventorySha256": "8" * 64,
        "onboardingSha256": "9" * 64,
        "runtimeContractSha256": "a" * 64,
        "transactionManifestSha256": "b" * 64,
    }
    return {
        "binding": binding,
        "fingerprint": fingerprint,
        "fingerprintFields": fields,
        "info": {},
        "onboarding": {
            "completedAtUtc": "2026-08-14T03:00:00Z",
            "databaseIdentity": database_identity(),
            "status": "COMMITTED_DATABASE_MIGRATED_ENTRY_CLOSED",
            "transactionId": "internal-test-db-20260814T030000Z-0123456789ab",
        },
        "updater": object(),
    }


def locked_reference(_latest: object) -> dict:
    return {
        "completedAtUtc": "2026-08-14T03:32:00Z",
        "path": (
            "/var/lib/uten-imp-backup-transactions/receipts/"
            "repo1-20260814T033000Z-" + "a" * 32 + ".json"
        ),
        "sha256": "c" * 64,
        "transactionId": "20260814T033000Z-" + "a" * 32,
    }


def repo_check() -> dict:
    return {
        "commandSha256": first._sha256(
            first._canonical_bytes(list(first.PGBACKREST_CHECK))
        ),
        "completedAtUtc": "2026-08-14T03:59:00Z",
        "passed": True,
        "repository": 1,
    }


class StrictJsonTest(unittest.TestCase):
    def test_duplicate_keys_and_nonfinite_numbers_fail_closed(self):
        for raw in (b'{"a":1,"a":2}\n', b'{"a":NaN}\n', b'{"a":Infinity}\n'):
            with self.subTest(raw=raw), self.assertRaises(first.FirstBackupError):
                first._strict_json(raw, "fixture")

    def test_unknown_locked_receipt_fields_are_rejected(self):
        value = locked_job_receipt()
        value["unreviewed"] = True
        with self.assertRaises(first.FirstBackupError):
            first.validate_locked_job_receipt(value, latest_full())

    def test_captured_module_exec_never_reopens_a_replaced_source_path(self):
        with tempfile.TemporaryDirectory() as directory_text:
            path = Path(directory_text) / "trusted_module.py"
            trusted = b"VALUE = 'trusted'\n"
            path.write_bytes(trusted)
            captured = path.read_bytes()
            replacement = path.with_name("replacement.py")
            replacement.write_text("VALUE = 'replaced'\n", encoding="utf-8")
            os.replace(replacement, path)
            with mock.patch.object(
                first, "compile", wraps=compile, create=True
            ) as compiler:
                module = first._exec_captured_module(
                    captured, path, "uten_first_backup_capture_test"
                )
            self.assertEqual("trusted", module.VALUE)
            self.assertEqual(trusted, compiler.call_args.args[0])
            self.assertEqual("VALUE = 'replaced'\n", path.read_text(encoding="utf-8"))

    def test_updater_loader_refuses_unknown_path_import_bootstrap(self):
        with self.assertRaises(first.FirstBackupError):
            first._exec_captured_module(
                b"release_guard = None\n",
                Path("/fixed/release_updater.py"),
                "uten_first_backup_bad_updater",
                stable_release_guard=object(),
            )

    def test_current_updater_consumes_the_preverified_captured_guard(self):
        guard_source = (
            HERE_GUARD := Path(__file__).parents[2] / "updater" / "release_guard.py"
        ).read_bytes()
        updater_source = (
            HERE_UPDATER := Path(__file__).parents[2] / "updater" / "release_updater.py"
        ).read_bytes()
        self.assertTrue(HERE_GUARD.is_file())
        self.assertTrue(HERE_UPDATER.is_file())
        guard = first._exec_captured_module(
            guard_source,
            first.RELEASE_GUARD,
            "uten_first_backup_real_guard_test",
        )
        updater = first._exec_captured_module(
            updater_source,
            first.UPDATER_MODULE,
            "uten_first_backup_real_updater_test",
            stable_release_guard=guard,
        )
        self.assertIs(guard, updater.release_guard)


class Repo1EvidenceTest(unittest.TestCase):
    def test_fresh_full_binds_live_system_timeline_and_wal(self):
        latest = latest_full()
        self.assertEqual(LABEL, latest["label"])
        self.assertEqual(SYSTEM_ID, latest["systemIdentifier"])
        self.assertEqual(TIMELINE, latest["timeline"])
        self.assertEqual(WAL_START, latest["walStart"])
        self.assertEqual(WAL_STOP, latest["walStop"])
        self.assertLessEqual(latest["ageSeconds"], first.MAX_FULL_AGE_SECONDS)

    def test_stale_or_non_full_backup_is_rejected(self):
        with self.assertRaises(first.FirstBackupError):
            first.parse_latest_full(
                repo_info(stop=int((NOW - timedelta(hours=7)).timestamp())),
                identity=database_identity(),
                onboarding_completed_at=NOW - timedelta(days=1),
                now=NOW,
            )

    def test_newer_incremental_cannot_hide_behind_an_older_full(self):
        value = json.loads(repo_info())
        newer = copy.deepcopy(value[0]["backup"][0])
        newer["label"] = "20260814-034500I"
        newer["type"] = "incr"
        newer["timestamp"] = {
            "start": int((NOW - timedelta(minutes=16)).timestamp()),
            "stop": int((NOW - timedelta(minutes=15)).timestamp()),
        }
        value[0]["backup"].append(newer)
        with self.assertRaises(first.FirstBackupError):
            first.parse_latest_full(
                json.dumps(value).encode(),
                identity=database_identity(),
                onboarding_completed_at=NOW - timedelta(hours=1),
                now=NOW,
            )
        with self.assertRaises(first.FirstBackupError):
            first.parse_latest_full(
                repo_info(backup_type="incr"),
                identity=database_identity(),
                onboarding_completed_at=NOW - timedelta(hours=1),
                now=NOW,
            )

    def test_system_timeline_and_wal_drift_are_rejected(self):
        wrong_system = database_identity()
        wrong_system["systemIdentifier"] = "7000000000000000000"
        with self.assertRaises(first.FirstBackupError):
            first.parse_latest_full(
                repo_info(),
                identity=wrong_system,
                onboarding_completed_at=NOW - timedelta(hours=1),
                now=NOW,
            )
        wrong_timeline = database_identity()
        wrong_timeline["timeline"] = 2
        with self.assertRaises(first.FirstBackupError):
            first.parse_latest_full(
                repo_info(),
                identity=wrong_timeline,
                onboarding_completed_at=NOW - timedelta(hours=1),
                now=NOW,
            )

    def test_missing_or_reversed_wal_range_is_rejected(self):
        value = json.loads(repo_info())
        del value[0]["backup"][0]["archive"]["stop"]
        with self.assertRaises(first.FirstBackupError):
            first.parse_latest_full(
                json.dumps(value).encode(),
                identity=database_identity(),
                onboarding_completed_at=NOW - timedelta(hours=1),
                now=NOW,
            )


class LockedJobReceiptTest(unittest.TestCase):
    def test_terminal_receipt_proves_exact_new_full_and_fixed_commands(self):
        transaction = first.validate_locked_job_receipt(
            locked_job_receipt(), latest_full()
        )
        self.assertEqual("complete", transaction["phase"])
        self.assertEqual(LABEL, transaction["committedBackup"]["label"])

    def test_command_or_inventory_replay_is_rejected(self):
        changed = locked_job_receipt()
        changed["transaction"]["backupCommandSha256"] = "0" * 64
        with self.assertRaises(first.FirstBackupError):
            first.validate_locked_job_receipt(changed, latest_full())
        changed = locked_job_receipt()
        changed["transaction"]["committedBackup"]["label"] = "20260813-000000F"
        with self.assertRaises(first.FirstBackupError):
            first.validate_locked_job_receipt(changed, latest_full())


class ExclusiveReceiptWriterTest(unittest.TestCase):
    def test_o_excl_receipt_is_single_link_0600_and_replay_is_refused(self):
        with tempfile.TemporaryDirectory() as directory_text:
            directory = Path(directory_text)
            uid = os.geteuid()
            gid = os.getegid()
            raw = first.write_receipt_exclusive(
                {"kind": "fixture", "schemaVersion": 1},
                directory=directory,
                owner_uid=uid,
                owner_gid=gid,
            )
            path = directory / "first-backup.json"
            details = path.lstat()
            self.assertEqual(first._canonical_bytes({"kind": "fixture", "schemaVersion": 1}), raw)
            self.assertEqual(0o600, stat.S_IMODE(details.st_mode))
            self.assertEqual(1, details.st_nlink)
            with self.assertRaises(first.FirstBackupError):
                first.write_receipt_exclusive(
                    {"kind": "fixture", "schemaVersion": 1},
                    directory=directory,
                    owner_uid=uid,
                    owner_gid=gid,
                )

    def test_symlink_at_fixed_name_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory_text:
            directory = Path(directory_text)
            target = directory / "target.json"
            target.write_text("preserve\n", encoding="utf-8")
            (directory / "first-backup.json").symlink_to(target)
            with self.assertRaises(first.FirstBackupError):
                first.write_receipt_exclusive(
                    {"kind": "fixture"},
                    directory=directory,
                    owner_uid=os.geteuid(),
                    owner_gid=os.getegid(),
                )
            self.assertEqual("preserve\n", target.read_text(encoding="utf-8"))

    def test_interrupted_write_leaves_poison_file_and_cannot_be_replayed(self):
        with tempfile.TemporaryDirectory() as directory_text:
            directory = Path(directory_text)
            original_write = first.os.write
            calls = 0

            def interrupted(descriptor: int, raw: bytes) -> int:
                nonlocal calls
                calls += 1
                if calls == 1:
                    original_write(descriptor, raw[:3])
                    raise OSError("simulated interruption")
                return original_write(descriptor, raw)

            with mock.patch.object(first.os, "write", side_effect=interrupted):
                with self.assertRaises(OSError):
                    first.write_receipt_exclusive(
                        {"kind": "fixture", "payload": "x" * 100},
                        directory=directory,
                        owner_uid=os.geteuid(),
                        owner_gid=os.getegid(),
                    )
            self.assertTrue((directory / "first-backup.json").exists())
            with self.assertRaises(first.FirstBackupError):
                first.write_receipt_exclusive(
                    {"kind": "fixture", "payload": "x" * 100},
                    directory=directory,
                    owner_uid=os.geteuid(),
                    owner_gid=os.getegid(),
                )


class OrchestrationTest(unittest.TestCase):
    class Lock(AbstractContextManager[object]):
        def __init__(self, events: list[str]) -> None:
            self.events = events

        def __enter__(self) -> object:
            self.events.append("lock-enter")
            return self

        def __exit__(self, *_: object) -> None:
            self.events.append("lock-exit")

    def test_record_rechecks_every_authority_before_one_exclusive_write(self):
        events: list[str] = []
        marker_calls = 0
        authority_calls = 0
        live_calls = 0
        info_calls = 0
        locked_calls = 0
        written: list[dict] = []

        def marker() -> None:
            nonlocal marker_calls
            marker_calls += 1
            events.append("marker")

        def load_auth() -> dict:
            nonlocal authority_calls
            authority_calls += 1
            events.append("authority")
            return authority()

        def live(_authority: object) -> dict:
            nonlocal live_calls
            live_calls += 1
            events.append("live")
            return database_identity()

        def info() -> bytes:
            nonlocal info_calls
            info_calls += 1
            events.append("info")
            return repo_info()

        def locked(value: object) -> dict:
            nonlocal locked_calls
            locked_calls += 1
            events.append("locked")
            self.assertEqual(LABEL, value["label"])
            return locked_reference(value)

        def writer(value: object) -> bytes:
            written.append(dict(value))
            events.append("write")
            return first._canonical_bytes(value)

        receipt, digest = first.produce_first_backup_receipt(
            lock_factory=lambda: self.Lock(events),
            marker_gate=marker,
            authority_loader=load_auth,
            live_observer=live,
            check_runner=repo_check,
            info_loader=info,
            locked_loader=locked,
            producer_loader=lambda: {"path": "/fixed/producer", "sha256": "e" * 64},
            writer=writer,
            now_provider=lambda: NOW,
            require_environment=False,
        )
        self.assertEqual(3, marker_calls)
        self.assertEqual(2, authority_calls)
        self.assertEqual(2, live_calls)
        self.assertEqual(2, info_calls)
        self.assertEqual(2, locked_calls)
        self.assertEqual(1, len(written))
        self.assertEqual("lock-enter", events[0])
        self.assertEqual("lock-exit", events[-1])
        self.assertTrue(receipt["localRecoveryOnly"])
        self.assertFalse(receipt["restoreVerified"])
        self.assertFalse(receipt["productionAuthority"])
        self.assertEqual("2026-08-15T04:00:00Z", receipt["expiresAt"])
        self.assertEqual(first._sha256(first._canonical_bytes(receipt)), digest)

    def test_authority_or_live_drift_prevents_receipt(self):
        auth_values = [authority(), authority(fingerprint="0" * 64)]
        with self.assertRaises(first.FirstBackupError):
            first.produce_first_backup_receipt(
                lock_factory=lambda: self.Lock([]),
                marker_gate=lambda: None,
                authority_loader=lambda: auth_values.pop(0),
                live_observer=lambda _value: database_identity(),
                check_runner=repo_check,
                info_loader=repo_info,
                locked_loader=locked_reference,
                producer_loader=lambda: {},
                writer=lambda _value: self.fail("drift must prevent write"),
                now_provider=lambda: NOW,
                require_environment=False,
            )

    def test_fixed_check_and_info_commands_can_never_start_a_backup(self):
        self.assertEqual("check", first.PGBACKREST_CHECK[-1])
        self.assertEqual("info", first.PGBACKREST_INFO[-1])
        self.assertNotIn("backup", first.PGBACKREST_CHECK)
        self.assertNotIn("backup", first.PGBACKREST_INFO)
        with self.assertRaises(first.FirstBackupError):
            first._run_as_postgres(first.PGBACKREST_BACKUP, capture=False, timeout=1)

    def test_check_failure_or_stale_check_evidence_is_rejected(self):
        failed = repo_check()
        failed["passed"] = False
        with self.assertRaises(first.FirstBackupError):
            first.validate_repo1_check(
                failed,
                onboarding_completed_at=NOW - timedelta(hours=1),
                now=NOW,
            )
        stale = repo_check()
        stale["completedAtUtc"] = "2026-08-14T03:40:00Z"
        with self.assertRaises(first.FirstBackupError):
            first.validate_repo1_check(
                stale,
                onboarding_completed_at=NOW - timedelta(hours=1),
                now=NOW,
            )


class MarkerAndPrivilegeTest(unittest.TestCase):
    def test_present_marker_and_unsafe_parent_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory_text:
            parent = Path(directory_text)
            marker = parent / "active.json"
            marker.write_text("{}\n", encoding="utf-8")
            with mock.patch.object(first, "_safe_chain", return_value=None):
                with self.assertRaises(first.FirstBackupError):
                    first._marker_absent(marker)
            symlink = parent / "link"
            symlink.symlink_to(parent, target_is_directory=True)
            with self.assertRaises(first.FirstBackupError):
                first._safe_directory(symlink)

    def test_non_root_environment_is_rejected(self):
        with mock.patch.object(first.os, "geteuid", return_value=1000):
            with self.assertRaises(first.FirstBackupError):
                first._require_root()

    def test_all_known_release_and_commissioning_transactions_are_blockers(self):
        names = {str(path) for path in first.BLOCKING_MARKERS}
        for suffix in (
            "/var/lib/uten-imp-release/activation-in-progress.json",
            "/var/lib/uten-imp-release/recovery-ingress-finalizing.json",
            "/var/lib/uten-imp-internal-test-commissioning/active.json",
            "/var/lib/uten-imp-backup-commissioner/active-transaction.json",
            "/var/lib/uten-imp-backup-transactions/repo1.active.json",
            "/run/uten-imp-migration-authorization/migration-authorization.json",
        ):
            self.assertIn(suffix, names)


if __name__ == "__main__":
    unittest.main()
