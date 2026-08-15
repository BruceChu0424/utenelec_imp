from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    import sys

    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


repo2 = load_module("pgbackrest_repo2", "pgbackrest_repo2.py")
health = load_module("pgbackrest_health", "pgbackrest_health.py")
locked_job = load_module("locked_job", "locked_job.py")
alert = load_module("backup_alert", "backup_alert.py") if os.name == "posix" else None
if alert is not None:
    acceptance = load_module("backup_acceptance", "backup_acceptance.py")


def policy() -> dict:
    return {
        "schemaVersion": 1,
        "stanza": "uten-imp",
        "repo2": {
            "type": "s3",
            "path": "/uten-imp/postgresql",
            "s3Bucket": "uten-imp-backup-prod",
            "s3Endpoint": "backup.vendor.invalid",
            "s3Region": "cn-test-1",
            "s3UriStyle": "host",
            "storageVerifyTls": True,
            "cipherType": "aes-256-cbc",
            "retentionFullType": "count",
            "retentionFull": 7,
            "retentionArchiveType": "full",
            "retentionArchive": 7,
            "minimumImmutableDays": 30,
        },
        "health": {
            "minimumSuccessfulFullRestorePoints": 7,
            "maximumFullAgeSeconds": 129600,
            "maximumArchiveAgeSeconds": 900,
        },
    }


def secrets_value() -> dict:
    return {
        "schemaVersion": 1,
        "s3AccessKeyId": "AKID1234567890123456",
        "s3AccessKeySecret": "secret-value-1234567890123456",
        "cipherPass": "cipher-value-abcdef0123456789",
    }


def worm(now: datetime) -> dict:
    return {
        "schemaVersion": 1,
        "status": "VERIFIED",
        "provider": "approved-provider",
        "bucket": "uten-imp-backup-prod",
        "endpoint": "backup.vendor.invalid",
        "versioningEnabled": True,
        "immutabilityMode": "COMPLIANCE",
        "retentionDays": 30,
        "credentialsIndependent": True,
        "failureDomainIndependent": True,
        "checkedAtUtc": (now - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAtUtc": (now + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "evidenceReference": "private-evidence-123",
        "approvalReference": "change-approval-123",
        "reviewer": "second-reviewer",
    }


def repo_info(repo_number: int, now_epoch: int, wal: str = "0000000100000000000000AA") -> list:
    backups = []
    for index in range(7):
        stop = now_epoch - (6 - index) * 86400 - 1800
        backups.append(
            {
                "type": "full",
                "error": False,
                "label": f"202608{index + 1:02d}-000000F",
                "database": {"repo-key": repo_number, "id": 1},
                "timestamp": {"start": stop - 60, "stop": stop},
                "archive": {
                    "start": f"0000000100000000000000{index + 1:02X}",
                    "stop": f"0000000100000000000000{index + 2:02X}",
                },
            }
        )
    return [
        {
            "name": "uten-imp",
            "status": {"code": 0, "message": "ok"},
            "repo": [{"key": repo_number, "status": {"code": 0, "message": "ok"}}],
            "db": [
                {
                    "id": 1,
                    "system-id": "7523456789012345678",
                    "version": "16",
                }
            ],
            "backup": backups,
            "archive": [
                {
                    "database": {"repo-key": repo_number, "id": 1},
                    "min": "000000010000000000000001",
                    "max": wal,
                }
            ],
        }
    ]


def archiver(now_epoch: int) -> dict:
    return {
        "nowEpoch": now_epoch,
        "archiveMode": "on",
        "archiveCommand": "pgbackrest --stanza=uten-imp archive-push %p",
        "inRecovery": False,
        "lastArchivedEpoch": now_epoch - 120,
        "lastArchivedWal": "0000000100000000000000AA",
        "archivedCount": 100,
        "failedCount": 2,
        "lastFailedEpoch": now_epoch - 300,
        "currentWal": "0000000100000000000000AB",
        "systemIdentifier": "7523456789012345678",
        "timeline": 1,
    }


def flyway_history() -> list:
    return [
        {
            "installedRank": index,
            "version": str(index),
            "description": f"migration {index}",
            "type": "SQL",
            "script": f"V{index}__migration_{index}.sql",
            "checksum": index * 17,
            "success": True,
        }
        for index in range(1, 8)
    ]


class Repo2ContractTest(unittest.TestCase):
    def test_valid_policy_evidence_and_secret_render(self):
        now = datetime(2026, 8, 12, tzinfo=timezone.utc)
        parsed = repo2.parse_policy(policy())
        secret = repo2.parse_secrets(secrets_value())
        repo2.validate_worm_evidence(worm(now), parsed, now=now)
        rendered = repo2.render_config(parsed, secret).decode("utf-8")
        self.assertIn("archive-async=y", rendered)
        self.assertIn("repo2-retention-full=7", rendered)
        self.assertIn("repo2-retention-archive=7", rendered)
        self.assertIn("repo2-storage-verify-tls=y", rendered)
        self.assertNotIn("repo1-", rendered)

    def test_policy_rejects_weak_retention_or_tls(self):
        value = policy()
        value["repo2"]["retentionFull"] = 6
        with self.assertRaisesRegex(repo2.ContractError, "between 7"):
            repo2.parse_policy(value)
        value = policy()
        value["repo2"]["storageVerifyTls"] = False
        with self.assertRaisesRegex(repo2.ContractError, "TLS"):
            repo2.parse_policy(value)
        value = policy()
        value["repo2"]["path"] = "/safe\nrepo1-path=/attacker"
        with self.assertRaisesRegex(repo2.ContractError, "dedicated absolute object prefix"):
            repo2.parse_policy(value)
        value = policy()
        value["stanza"] = "another-stanza"
        with self.assertRaisesRegex(repo2.ContractError, "fixed uten-imp"):
            repo2.parse_policy(value)

    def test_placeholders_and_stale_worm_evidence_are_rejected(self):
        value = secrets_value()
        value["cipherPass"] = "REPLACE_cipher_secret"
        with self.assertRaisesRegex(repo2.ContractError, "placeholder"):
            repo2.parse_secrets(value)
        now = datetime(2026, 8, 12, tzinfo=timezone.utc)
        evidence = worm(now)
        evidence["expiresAtUtc"] = "2026-08-11T00:00:00Z"
        with self.assertRaisesRegex(repo2.ContractError, "validity"):
            repo2.validate_worm_evidence(evidence, repo2.parse_policy(policy()), now=now)

    def test_worm_digest_is_out_of_band_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "worm.json"
            path.write_text("{}\n", encoding="utf-8")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            repo2.validate_sha256(path, digest)
            with self.assertRaisesRegex(repo2.ContractError, "differs"):
                repo2.validate_sha256(path, "0" * 64)

    def test_candidate_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.conf"
            digest = repo2._write_candidate(path, b"safe\n")
            self.assertEqual(hashlib.sha256(b"safe\n").hexdigest(), digest)
            with self.assertRaisesRegex(repo2.ContractError, "overwrite"):
                repo2._write_candidate(path, b"other\n")

    def test_active_preflight_binds_policy_config_and_expiry_without_secret_output(self):
        now = datetime(2026, 8, 12, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy_path = root / "policy.json"
            config_path = root / "repo2.conf"
            approval_path = root / "approved.json"
            worm_path = root / "worm.json"
            repo1_override_path = root / "repo1-override.conf"
            policy_path.write_text(json.dumps(policy()), encoding="utf-8")
            rendered_config = repo2.render_config(
                repo2.parse_policy(policy()), repo2.parse_secrets(secrets_value())
            )
            config_path.write_bytes(rendered_config)
            worm_path.write_text(json.dumps(worm(now)), encoding="utf-8")
            repo1_override_path.write_bytes(repo2.REPO1_OVERRIDE)
            approval_value = {
                "schemaVersion": 1,
                "status": "APPROVED",
                "approvalReference": "change-approval-123",
                "policySha256": hashlib.sha256(policy_path.read_bytes()).hexdigest(),
                "configSha256": hashlib.sha256(config_path.read_bytes()).hexdigest(),
                "repo1OverrideSha256": hashlib.sha256(
                    repo1_override_path.read_bytes()
                ).hexdigest(),
                "wormEvidenceSha256": hashlib.sha256(worm_path.read_bytes()).hexdigest(),
                "approvedAtUtc": "2026-08-11T00:00:00Z",
                "expiresAtUtc": "2026-08-20T00:00:00Z",
                "reviewer": "second-reviewer",
            }
            approval_path.write_text(json.dumps(approval_value), encoding="utf-8")
            fake_grp = SimpleNamespace(
                getgrnam=lambda _name: SimpleNamespace(
                    gr_gid=getattr(os, "getgid", lambda: 0)()
                )
            )
            with mock.patch.object(repo2, "_assert_secure_file"), mock.patch.object(
                repo2.os, "name", "posix"
            ), mock.patch.dict(sys.modules, {"grp": fake_grp}):
                result = repo2.validate_active(
                    policy_path,
                    config_path,
                    approval_path,
                    worm_path,
                    now=now,
                    repo1_override_path=repo1_override_path,
                )
                self.assertEqual("ACTIVE_PREFLIGHT_PASS", result["status"])
                self.assertNotIn(secrets_value()["s3AccessKeySecret"], json.dumps(result))
                expired = dict(approval_value)
                expired["expiresAtUtc"] = "2026-08-12T00:00:00Z"
                approval_path.write_text(json.dumps(expired), encoding="utf-8")
                with self.assertRaisesRegex(repo2.ContractError, "validity window"):
                    repo2.validate_active(
                        policy_path, config_path, approval_path, worm_path, now=now,
                        repo1_override_path=repo1_override_path,
                    )
                approval_path.write_text(json.dumps(approval_value), encoding="utf-8")
                config_path.write_text("drift\n", encoding="utf-8")
                with self.assertRaisesRegex(repo2.ContractError, "approved digest"):
                    repo2.validate_active(
                        policy_path, config_path, approval_path, worm_path, now=now,
                        repo1_override_path=repo1_override_path,
                    )
                config_path.write_bytes(rendered_config)
                worm_path.write_text("{}\n", encoding="utf-8")
                with self.assertRaisesRegex(repo2.ContractError, "WORM evidence differs"):
                    repo2.validate_active(
                        policy_path, config_path, approval_path, worm_path, now=now,
                        repo1_override_path=repo1_override_path,
                    )
                worm_path.write_text(json.dumps(worm(now)), encoding="utf-8")
                repo1_override_path.write_bytes(repo2.REPO1_OVERRIDE + b"# drift\n")
                with self.assertRaisesRegex(repo2.ContractError, "reviewed explicit-repository"):
                    repo2.validate_active(
                        policy_path, config_path, approval_path, worm_path, now=now,
                        repo1_override_path=repo1_override_path,
                    )

        injected = repo2.render_config(
            repo2.parse_policy(policy()), repo2.parse_secrets(secrets_value())
        ) + b"repo1-path=/attacker\n"
        with self.assertRaisesRegex(repo2.ContractError, "exact key set"):
            repo2.validate_active_config(injected, repo2.parse_policy(policy()))


class HealthContractTest(unittest.TestCase):
    def setUp(self):
        self.now_epoch = 1786492800

    def test_dual_repo_seven_full_and_fresh_wal_pass(self):
        report = health.evaluate(
            policy(), repo_info(1, self.now_epoch), repo_info(2, self.now_epoch), archiver(self.now_epoch), flyway_history()
        )
        self.assertEqual("PASS", report["status"])
        self.assertEqual([7, 7], [item["successfulFullRestorePoints"] for item in report["repositories"]])
        self.assertFalse(report["remoteImmutabilityProvenByThisCheck"])
        self.assertFalse(report["pitrRestoreDrillProvenByThisCheck"])
        self.assertFalse(report["walInventoryContinuityProvenByThisCheck"])
        self.assertFalse(report["repositoryCheckPerformedByThisRun"])
        self.assertEqual("7523456789012345678", report["databaseIdentity"]["systemIdentifier"])
        self.assertEqual(7, report["databaseIdentity"]["flyway"]["headVersion"])
        expected_rows = "".join(
            f"{row['version']}\t{row['script']}\t{row['checksum']}\n"
            for row in flyway_history()
        ).encode("utf-8")
        self.assertEqual(
            hashlib.sha256(expected_rows).hexdigest(),
            report["databaseIdentity"]["flyway"]["signedProjectionSha256"],
        )

    def test_six_restore_points_fail_closed(self):
        second = repo_info(2, self.now_epoch)
        second[0]["backup"].pop()
        with self.assertRaisesRegex(repo2.ContractError, "at least 7"):
            health.evaluate(policy(), repo_info(1, self.now_epoch), second, archiver(self.now_epoch), flyway_history())

    def test_old_database_identity_cannot_fake_current_restore_points(self):
        second = repo_info(2, self.now_epoch)
        old = second[0]["backup"].pop()
        old["database"] = {"repo-key": 2, "id": 99}
        second[0]["backup"].append(old)
        second[0]["db"].append(
            {"id": 99, "system-id": "7000000000000000000", "version": "15"}
        )
        with self.assertRaisesRegex(repo2.ContractError, "at least 7"):
            health.evaluate(
                policy(),
                repo_info(1, self.now_epoch),
                second,
                archiver(self.now_epoch),
                flyway_history(),
            )

    def test_same_day_fulls_do_not_fake_seven_daily_points(self):
        second = repo_info(2, self.now_epoch)
        for index, backup in enumerate(second[0]["backup"]):
            backup["timestamp"]["stop"] = self.now_epoch - index * 60
        with self.assertRaisesRegex(repo2.ContractError, "distinct UTC dates"):
            health.evaluate(
                policy(), repo_info(1, self.now_epoch), second, archiver(self.now_epoch), flyway_history()
            )

    def test_repo2_wal_lag_fails_closed(self):
        with self.assertRaisesRegex(repo2.ContractError, "WAL identities differ"):
            health.evaluate(
                policy(),
                repo_info(1, self.now_epoch),
                repo_info(2, self.now_epoch, "0000000100000000000000A9"),
                archiver(self.now_epoch),
                flyway_history(),
            )

    def test_both_repositories_behind_postgres_archiver_fail_closed(self):
        with self.assertRaisesRegex(repo2.ContractError, "behind PostgreSQL"):
            health.evaluate(
                policy(),
                repo_info(1, self.now_epoch, "0000000100000000000000A9"),
                repo_info(2, self.now_epoch, "0000000100000000000000A9"),
                archiver(self.now_epoch),
                flyway_history(),
            )

    def test_stale_or_latest_failed_archiver_fails_closed(self):
        stale = archiver(self.now_epoch)
        stale["lastArchivedEpoch"] = self.now_epoch - 901
        with self.assertRaisesRegex(repo2.ContractError, "exceeds"):
            health.evaluate(policy(), repo_info(1, self.now_epoch), repo_info(2, self.now_epoch), stale, flyway_history())
        failed = archiver(self.now_epoch)
        failed["lastFailedEpoch"] = self.now_epoch - 30
        with self.assertRaisesRegex(repo2.ContractError, "latest.*failed"):
            health.evaluate(policy(), repo_info(1, self.now_epoch), repo_info(2, self.now_epoch), failed, flyway_history())

    def test_archive_command_shell_extension_is_rejected(self):
        value = archiver(self.now_epoch)
        value["archiveCommand"] += " || true"
        with self.assertRaisesRegex(repo2.ContractError, "differs"):
            health.evaluate(policy(), repo_info(1, self.now_epoch), repo_info(2, self.now_epoch), value, flyway_history())

    def test_flyway_history_drift_shape_fails_closed(self):
        rows = flyway_history()
        rows[-1]["success"] = False
        with self.assertRaisesRegex(repo2.ContractError, "unsuccessful"):
            health.evaluate(
                policy(), repo_info(1, self.now_epoch), repo_info(2, self.now_epoch), archiver(self.now_epoch), rows
            )


class LockedJobContractTest(unittest.TestCase):
    class Lock:
        def __init__(self, *, busy: bool = False):
            self.busy = busy
            self.entered = False
            self.exited = False

        def __enter__(self):
            if self.busy:
                raise locked_job.LockedJobError(
                    "another database maintenance operation is already running"
                )
            self.entered = True
            return self

        def __exit__(self, *_):
            self.exited = True

    class Transaction:
        def __init__(self, job_name: str):
            self.job_name = job_name
            self.events: list[str] = []

        def begin(self):
            self.events.append("running")

        def backup_returned_success(self):
            self.events.append("committed")

        def mark_expire_pending(self):
            self.events.append("expire-pending")

        def mark_uncertain(self, reason):
            self.events.append(f"uncertain:{reason}")

        def complete(self):
            self.events.append("complete")
            return {}, "a" * 64

    def transaction_factory(self, job_name):
        return self.Transaction(job_name)

    def test_job_names_and_every_command_are_fixed_without_shell_or_secret_arguments(self):
        self.assertEqual({"repo1", "repo2", "health"}, set(locked_job.JOB_PLANS))
        flattened = []
        for plan in locked_job.JOB_PLANS.values():
            for command in plan.steps:
                flattened.append(command)
                self.assertTrue(command[0].startswith("/usr/"))
                self.assertNotIn(command[0], {"/bin/sh", "/usr/bin/bash", "/usr/bin/env"})
                self.assertTrue(all(isinstance(part, str) and "\n" not in part for part in command))
        rendered = json.dumps(flattened)
        self.assertNotRegex(rendered.lower(), r"password|secret|access[_-]?key")
        self.assertIn(("--repo=1", "--no-expire-auto", "--type=full", "backup"), [command[-4:] for command in flattened])
        self.assertIn(("--repo=2", "--no-expire-auto", "--type=full", "backup"), [command[-4:] for command in flattened])
        self.assertIn(
            locked_job.PGBACKREST_BASE + ("--repo=2", "check"),
            locked_job.JOB_PLANS["repo2"].steps,
        )
        self.assertNotIn(
            locked_job.PGBACKREST_BASE + ("check",),
            locked_job.JOB_PLANS["repo2"].steps,
        )

    def test_busy_lock_rejects_before_any_preflight_or_command(self):
        calls = []
        lock = self.Lock(busy=True)
        with self.assertRaisesRegex(locked_job.LockedJobError, "already running"):
            locked_job.run_job(
                "repo1",
                lock_factory=lambda: lock,
                runner=calls.append,
                marker_gate=lambda: calls.append("gate"),
            )
        self.assertEqual([], calls)

    def test_backup_failure_never_runs_expire(self):
        calls = []

        def runner(command):
            calls.append(command)
            if command[-1] == "backup":
                raise subprocess.CalledProcessError(42, command)

        with self.assertRaisesRegex(locked_job.TerminalLockedJobError, "exit 42"):
            locked_job.run_job(
                "repo1",
                lock_factory=self.Lock,
                runner=runner,
                marker_gate=lambda: None,
                pending_gate=lambda: None,
                transaction_factory=self.transaction_factory,
            )
        self.assertTrue(any(command[-1] == "backup" for command in calls))
        self.assertFalse(any(command[-1] == "expire" for command in calls))

    def test_marker_appearing_after_backup_blocks_expire(self):
        calls = []
        backup_completed = False

        def runner(command):
            nonlocal backup_completed
            calls.append(command)
            if command[-1] == "backup":
                backup_completed = True

        def marker_gate():
            if backup_completed:
                raise locked_job.LockedJobError("release transaction gate is present")

        with self.assertRaisesRegex(locked_job.TerminalLockedJobError, "release gate"):
            locked_job.run_job(
                "repo2",
                lock_factory=self.Lock,
                runner=runner,
                marker_gate=marker_gate,
                pending_gate=lambda: None,
                transaction_factory=self.transaction_factory,
            )
        self.assertTrue(any(command[-1] == "backup" for command in calls))
        self.assertFalse(any(command[-1] == "expire" for command in calls))

    def test_every_failure_step_is_retryable_only_until_backup_success(self):
        for job_name in ("repo1", "repo2"):
            plan = locked_job.JOB_PLANS[job_name]
            self.assertIsNotNone(plan.backup_step)
            assert plan.backup_step is not None
            self.assertEqual("backup", plan.steps[plan.backup_step - 1][-1])
            self.assertEqual("expire", plan.steps[plan.backup_step][-1])
            for failed_step in range(1, len(plan.steps) + 1):
                seen = 0

                def runner(command):
                    nonlocal seen
                    seen += 1
                    if seen == failed_step:
                        raise subprocess.CalledProcessError(9, command)

                expected = (
                    locked_job.TerminalLockedJobError
                    if failed_step >= plan.backup_step
                    else locked_job.LockedJobError
                )
                with self.assertRaises(expected) as raised:
                    locked_job.run_job(
                        job_name,
                        lock_factory=self.Lock,
                        runner=runner,
                        marker_gate=lambda: None,
                        pending_gate=lambda: None,
                        transaction_factory=self.transaction_factory,
                    )
                if failed_step < plan.backup_step:
                    self.assertNotIsInstance(
                        raised.exception, locked_job.TerminalLockedJobError
                    )

    def test_any_signalled_child_is_terminal_even_before_backup_success(self):
        def signalled(command):
            raise subprocess.CalledProcessError(-9, command)

        with self.assertRaises(locked_job.TerminalLockedJobError):
            locked_job.run_job(
                "repo1",
                lock_factory=self.Lock,
                runner=signalled,
                marker_gate=lambda: None,
                pending_gate=lambda: None,
                transaction_factory=self.transaction_factory,
            )

    def test_unexpected_exception_after_backup_success_is_terminal(self):
        backup_completed = False

        def runner(command):
            nonlocal backup_completed
            if command[-1] == "backup":
                backup_completed = True
            elif command[-1] == "expire" and backup_completed:
                raise RuntimeError("unexpected post-backup failure")

        with self.assertRaises(locked_job.TerminalLockedJobError):
            locked_job.run_job(
                "repo1",
                lock_factory=self.Lock,
                runner=runner,
                marker_gate=lambda: None,
                pending_gate=lambda: None,
                transaction_factory=self.transaction_factory,
            )

    def test_lock_release_failure_after_backup_success_is_terminal(self):
        class ExitFailureLock(self.Lock):
            def __exit__(self, *_):
                raise RuntimeError("unexpected lock release failure")

        with self.assertRaises(locked_job.TerminalLockedJobError):
            locked_job.run_job(
                "repo1",
                lock_factory=ExitFailureLock,
                runner=lambda _command: None,
                marker_gate=lambda: None,
                pending_gate=lambda: None,
                transaction_factory=self.transaction_factory,
            )

    def test_keyboard_interrupt_is_terminal_even_before_backup_success(self):
        def interrupted(_command):
            raise KeyboardInterrupt

        with self.assertRaises(locked_job.TerminalLockedJobError):
            locked_job.run_job(
                "repo1",
                lock_factory=self.Lock,
                runner=interrupted,
                marker_gate=lambda: None,
                pending_gate=lambda: None,
                transaction_factory=self.transaction_factory,
            )

    def test_gate_runs_before_every_step_and_after_the_final_step(self):
        events = []
        locked_job.run_job(
            "health",
            lock_factory=self.Lock,
            runner=lambda command: events.append(("command", command)),
            marker_gate=lambda: events.append(("gate", None)),
            health_state_gate=lambda: None,
            pending_gate=lambda: None,
        )
        commands = locked_job.JOB_PLANS["health"].steps
        self.assertEqual(len(commands) + 1, sum(kind == "gate" for kind, _ in events))
        for index, command in enumerate(commands):
            self.assertEqual(("gate", None), events[index * 2])
            self.assertEqual(("command", command), events[index * 2 + 1])
        self.assertEqual(("gate", None), events[-1])

    def test_subprocess_uses_clean_environment_and_exact_postgres_credentials(self):
        with mock.patch.object(locked_job, "_postgres_identity", return_value=(1234, 1235)), mock.patch.object(
            locked_job.subprocess, "run"
        ) as invoked, mock.patch.dict(os.environ, {"LEAK_THIS_SECRET": "must-not-pass"}):
            locked_job._run_fixed(locked_job.MOUNT_PREFLIGHT)
        args, kwargs = invoked.call_args
        self.assertEqual(list(locked_job.MOUNT_PREFLIGHT), args[0])
        self.assertEqual(1234, kwargs["user"])
        self.assertEqual(1235, kwargs["group"])
        self.assertEqual((), kwargs["extra_groups"])
        self.assertEqual(0o077, kwargs["umask"])
        self.assertNotIn("LEAK_THIS_SECRET", kwargs["env"])
        self.assertEqual("postgres", kwargs["env"]["USER"])

    def test_health_state_directory_requires_exact_root_postgres_0770_leaf(self):
        valid = SimpleNamespace(
            st_mode=stat.S_IFDIR | 0o770,
            st_uid=0,
            st_gid=1235,
            st_dev=7,
            st_ino=11,
        )
        path_type = type(locked_job.HEALTH_STATE_DIRECTORY)
        with mock.patch.object(locked_job, "_assert_safe_root_directory"), mock.patch.object(
            locked_job, "_postgres_identity", return_value=(1234, 1235)
        ), mock.patch.object(path_type, "lstat", return_value=valid), mock.patch.object(
            locked_job.os, "open", return_value=19
        ), mock.patch.object(locked_job.os, "fstat", return_value=valid), mock.patch.object(
            locked_job.os, "close"
        ), mock.patch.object(
            locked_job.os, "O_NOFOLLOW", 0, create=True
        ):
            locked_job.assert_health_state_directory()

        for label, changed in (
            ("owner", {"st_uid": 1234}),
            ("group", {"st_gid": 0}),
            ("mode", {"st_mode": stat.S_IFDIR | 0o750}),
            ("symlink", {"st_mode": stat.S_IFLNK | 0o770}),
        ):
            details = SimpleNamespace(**{**vars(valid), **changed})
            with self.subTest(label=label), mock.patch.object(
                locked_job, "_assert_safe_root_directory"
            ), mock.patch.object(
                locked_job, "_postgres_identity", return_value=(1234, 1235)
            ), mock.patch.object(path_type, "lstat", return_value=details):
                with self.assertRaisesRegex(locked_job.LockedJobError, "root:postgres"):
                    locked_job.assert_health_state_directory()

    @unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "requires a root POSIX host")
    def test_real_posix_subprocess_drop_is_non_root_postgres(self):
        if locked_job.pwd is None:
            self.skipTest("POSIX pwd module is unavailable")
        try:
            record = locked_job.pwd.getpwnam("postgres")
        except KeyError:
            self.skipTest("postgres service account is unavailable")
        completed = subprocess.run(
            ["/usr/bin/id", "-u"],
            check=True,
            capture_output=True,
            text=True,
            user=record.pw_uid,
            group=record.pw_gid,
            extra_groups=(),
            umask=0o077,
        )
        self.assertNotEqual(0, record.pw_uid)
        self.assertEqual(str(record.pw_uid), completed.stdout.strip())

    @unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "requires a root POSIX host")
    def test_postgres_can_write_health_leaf_but_cannot_replace_its_root_parent_entry(self):
        if locked_job.pwd is None:
            self.skipTest("POSIX pwd module is unavailable")
        try:
            record = locked_job.pwd.getpwnam("postgres")
        except KeyError:
            self.skipTest("postgres service account is unavailable")
        with tempfile.TemporaryDirectory(dir="/var/lib") as temporary:
            parent = Path(temporary)
            parent.chmod(0o755)
            health_state = parent / "uten-imp-backup-health"
            health_state.mkdir(mode=0o770)
            os.chown(health_state, 0, record.pw_gid)
            health_state.chmod(0o770)
            with mock.patch.object(locked_job, "HEALTH_STATE_DIRECTORY", health_state):
                locked_job.assert_health_state_directory()
            report = health_state / "health.json"
            writer = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-c",
                    "import os,sys; fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.fchmod(fd,0o640); os.close(fd)",
                    str(report),
                ],
                check=False,
                capture_output=True,
                user=record.pw_uid,
                group=record.pw_gid,
                extra_groups=(),
                umask=0o077,
            )
            self.assertEqual(0, writer.returncode, writer.stderr.decode(errors="replace"))
            report_details = report.lstat()
            self.assertEqual(record.pw_uid, report_details.st_uid)
            self.assertEqual(record.pw_gid, report_details.st_gid)
            self.assertEqual(0o640, stat.S_IMODE(report_details.st_mode))
            replacement = parent / "replacement"
            attacker = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-c",
                    "import os,sys; os.rename(sys.argv[1],sys.argv[2])",
                    str(health_state),
                    str(replacement),
                ],
                check=False,
                capture_output=True,
                user=record.pw_uid,
                group=record.pw_gid,
                extra_groups=(),
                umask=0o077,
            )
            self.assertNotEqual(0, attacker.returncode)
            self.assertTrue(health_state.is_dir())
            self.assertFalse(replacement.exists())

    @unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "requires a root POSIX host")
    def test_real_flock_competition_is_nonblocking(self):
        if locked_job.pwd is None:
            self.skipTest("POSIX pwd module is unavailable")
        try:
            record = locked_job.pwd.getpwnam("postgres")
        except KeyError:
            self.skipTest("postgres service account is unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "maintenance"
            directory.mkdir(mode=0o750)
            os.chown(directory, 0, record.pw_gid)
            lock_path = directory / "operation.lock"
            lock_path.touch(mode=0o660)
            os.chown(lock_path, 0, record.pw_gid)
            lock_path.chmod(0o660)
            with mock.patch.object(locked_job, "MAINTENANCE_DIRECTORY", directory), mock.patch.object(
                locked_job, "MAINTENANCE_LOCK", lock_path
            ):
                with locked_job.MaintenanceLock():
                    with self.assertRaisesRegex(locked_job.LockedJobError, "already running"):
                        with locked_job.MaintenanceLock():
                            self.fail("a second nonblocking lock unexpectedly succeeded")

    @unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "requires a root POSIX host")
    def test_marker_symlink_is_a_fail_closed_gate(self):
        with tempfile.TemporaryDirectory(dir="/var/lib") as temporary:
            state = Path(temporary)
            state.chmod(0o700)
            (state / "activation-failed.json").symlink_to("missing-target")
            with mock.patch.object(locked_job, "RELEASE_STATE_DIRECTORY", state):
                with self.assertRaisesRegex(locked_job.LockedJobError, "transaction gate"):
                    locked_job.assert_no_release_transaction_markers()


class SystemdContractTest(unittest.TestCase):
    SYSTEMD = HERE.parents[1] / "systemd"

    def text(self, name: str) -> str:
        return (self.SYSTEMD / name).read_text(encoding="utf-8")

    def test_repo2_timer_is_separate_persistent_and_approval_gated(self):
        service = self.text("uten-pgbackup-repo2.service.example")
        timer = self.text("uten-pgbackup-repo2.timer.example")
        self.assertNotIn("ConditionPathExists=", service + timer)
        self.assertIn("locked_job.py repo2", service)
        self.assertNotIn("ExecStart=/usr/bin/pgbackrest", service)
        self.assertIn("network-online.target uten-pgbackup.service", service)
        self.assertNotIn("Requisite=postgresql@16-main.service", service)
        self.assertNotIn("Requires=postgresql@16-main.service", service)
        self.assertIn("OnFailure=uten-pgbackup-alert@%n.service", service)
        self.assertIn("OnCalendar=*-*-* 03:17:00", timer)
        self.assertIn("Persistent=true", timer)
        self.assertNotIn("systemctl enable", service + timer)

    def test_health_and_alert_timers_fail_closed(self):
        health_service = self.text("uten-pgbackup-health.service.example")
        health_timer = self.text("uten-pgbackup-health.timer.example")
        local_service = self.text("uten-pgbackup.service.example")
        obsolete_dropin = self.text("uten-pgbackup-repo1-override.conf.example")
        alert_service = self.text("uten-pgbackup-alert@.service.example")
        drain_service = self.text("uten-pgbackup-alert-drain.service.example")
        drain_timer = self.text("uten-pgbackup-alert-drain.timer.example")
        self.assertIn("OnFailure=uten-pgbackup-alert@%n.service", health_service)
        self.assertIn("OnFailure=uten-pgbackup-alert@%n.service", local_service)
        self.assertIn("locked_job.py repo1", local_service)
        self.assertIn("locked_job.py health", health_service)
        self.assertNotIn("StateDirectory=uten-imp-backup", health_service)
        health_path = "/var/lib/uten-imp-backup-health/health.json"
        self.assertIn(health_path, (HERE / "locked_job.py").read_text(encoding="utf-8"))
        self.assertIn(health_path, (HERE / "pgbackrest_health.py").read_text(encoding="utf-8"))
        self.assertIn(health_path, (HERE / "backup_alert.py").read_text(encoding="utf-8"))
        self.assertIn(health_path, (HERE / "backup_acceptance.py").read_text(encoding="utf-8"))
        self.assertIn(health_path, alert_service)
        self.assertEqual(
            repo2.REPO1_OVERRIDE,
            (self.SYSTEMD / "uten-pgbackup.service.example").read_bytes(),
        )
        self.assertIn("OBSOLETE AND INTENTIONALLY NON-INSTALLABLE", obsolete_dropin)
        self.assertNotIn("[Unit]", obsolete_dropin)
        self.assertNotIn("[Service]", obsolete_dropin)
        self.assertIn("uten-pgbackup.service uten-pgbackup-repo2.service", health_service)
        self.assertIn("OnUnitActiveSec=5m", health_timer)
        self.assertIn("StateDirectory=uten-imp-backup-alerts", alert_service)
        self.assertIn("/usr/local/libexec/uten-imp-alerting/submit", (HERE / "backup_alert.py").read_text(encoding="utf-8"))
        self.assertNotIn("OnFailure=", drain_service)
        self.assertIn("OnBootSec=5m", drain_timer)
        self.assertNotIn("Persistent=true", health_timer + drain_timer)
        self.assertNotIn("SuccessExitStatus=1", alert_service + drain_service)

    def test_all_database_jobs_use_root_marker_gates_and_have_no_pull_dependencies(self):
        marker_names = (
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
        for name, job in (
            ("uten-pgbackup.service.example", "repo1"),
            ("uten-pgbackup-repo2.service.example", "repo2"),
            ("uten-pgbackup-health.service.example", "health"),
        ):
            service = self.text(name)
            self.assertIn("User=root", service)
            self.assertIn("Group=root", service)
            self.assertIn("CapabilityBoundingSet=CAP_SETUID CAP_SETGID", service)
            self.assertNotIn("Requisite=postgresql@16-main.service", service)
            self.assertNotIn("Requires=postgresql@16-main.service", service)
            self.assertNotIn("RequiresMountsFor=/data", service)
            start_index = service.index(f"locked_job.py {job}")
            for marker in marker_names:
                gate = f"ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/{marker}"
                self.assertIn(gate, service)
                self.assertLess(service.index(gate), start_index)

    def test_daily_backup_jobs_retry_lock_contention_but_health_uses_its_timer(self):
        repo1 = self.text("uten-pgbackup.service.example")
        repo2_service = self.text("uten-pgbackup-repo2.service.example")
        health_service = self.text("uten-pgbackup-health.service.example")
        self.assertIn("Restart=on-failure", repo1)
        self.assertIn("RestartPreventExitStatus=78", repo1)
        self.assertIn("RestartPreventExitStatus=78 130", repo1)
        self.assertIn("SIGKILL", repo1)
        self.assertIn("SIGTERM", repo1)
        self.assertIn("RestartSec=15m", repo1)
        self.assertIn("StartLimitIntervalSec=3h", repo1)
        self.assertIn("StartLimitBurst=8", repo1)
        self.assertIn("Restart=on-failure", repo2_service)
        self.assertIn("RestartPreventExitStatus=78", repo2_service)
        self.assertIn("RestartPreventExitStatus=78 130", repo2_service)
        self.assertIn("RestartSec=30m", repo2_service)
        self.assertIn("StartLimitIntervalSec=6h", repo2_service)
        self.assertIn("StartLimitBurst=8", repo2_service)
        self.assertNotIn("Restart=", health_service)

    def test_phase2_fresh_baseline_installs_the_same_locked_repo1_contract(self):
        phase2 = (HERE.parents[1] / "setup" / "phase2-postgres.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("postgre" + "s/backup/locked_job.py", phase2)
        self.assertIn("root:postgres:660:1", phase2)
        self.assertIn("BACKUP_HEALTH_STATE_DIR=/var/lib/uten-imp-backup-health", phase2)
        self.assertIn("root:postgres:770", phase2)
        self.assertNotIn("Requisite=postgresql@16-main.service", phase2)
        self.assertNotIn("Requires=postgresql@16-main.service", phase2)
        self.assertNotIn("RequiresMountsFor=/data", phase2)
        self.assertIn("OnFailure=uten-pgbackup-alert@%n.service", phase2)
        self.assertIn("locked_job.py repo1", phase2)
        self.assertIn('/usr/bin/python3 -I "$BACKUP_LOCKED_JOB" repo1', phase2)
        for marker in (
            "activation-failed.json",
            "activation-in-progress.json",
            "boot-enablement-in-progress.json",
            "recovery-in-progress.json",
            "recovery-ingress-pending.json",
            "recovery-ingress-authorization.json",
            "recovery-ingress-finalizing.json",
            "internal-test-onboarding-adoption.json",
            "internal-test-activation-reauthorization.json",
        ):
            self.assertIn(f"ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/{marker}", phase2)

    @unittest.skipUnless(os.name == "posix", "isolated Python execution is production-POSIX only")
    def test_systemd_python_entrypoints_start_under_isolated_mode(self):
        import subprocess
        import sys

        for filename in (
            "locked_job.py",
            "pgbackrest_repo2.py",
            "pgbackrest_health.py",
            "backup_alert.py",
            "backup_acceptance.py",
        ):
            result = subprocess.run(
                [sys.executable, "-I", "-B", str(HERE / filename), "--help"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=10,
                check=False,
            )
            self.assertEqual(0, result.returncode, f"{filename}: {result.stderr.decode()}")


@unittest.skipUnless(os.name == "posix", "durable alert spool is production-POSIX only")
class AlertContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.alert = alert

    def test_missing_sender_keeps_event_pending(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            health_path = root / "health.json"
            health_path.write_text('{"status":"FAIL","failure":"repo2 unavailable"}\n', encoding="utf-8")
            missing = root / "missing-sender"
            with mock.patch.dict(os.environ, {"UTEN_BACKUP_ALERT_TEST_MODE": "1"}):
                delivered = self.alert.emit(
                    "uten-pgbackup-health.service", root / "state", health_path, missing
                )
            self.assertFalse(delivered)
            self.assertEqual(1, len(list((root / "state" / "pending").glob("*.json"))))

    def test_valid_external_receipt_moves_event(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            health_path = root / "health.json"
            health_path.write_text('{"status":"FAIL","failure":"WAL stale"}\n', encoding="utf-8")
            sender = root / "sender.py"
            sender.write_text(
                """#!/usr/bin/env python3
import json, sys
args=dict(zip(sys.argv[1::2],sys.argv[2::2]))
event=json.load(open(args['--event-file'],encoding='utf-8'))
receipt={'schemaVersion':1,'eventId':event['eventId'],'accepted':True,'deliveredAtUtc':event['occurredAtUtc'],'providerMessageId':'provider-message-1'}
with open(args['--receipt-file'],'x',encoding='utf-8') as out: json.dump(receipt,out)
""",
                encoding="utf-8",
            )
            sender.chmod(sender.stat().st_mode | stat.S_IXUSR)
            with mock.patch.dict(os.environ, {"UTEN_BACKUP_ALERT_TEST_MODE": "1"}):
                delivered = self.alert.emit(
                    "uten-pgbackup-health.service", root / "state", health_path, sender
                )
            self.assertTrue(delivered)
            self.assertEqual([], list((root / "state" / "pending").glob("*.json")))
            self.assertEqual(1, len(list((root / "state" / "delivered").glob("*.json"))))
            self.assertEqual(1, len(list((root / "state" / "receipts").glob("*.json"))))

    def test_valid_work_receipt_resumes_after_power_loss(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = root / "state"
            health_path = root / "health.json"
            health_path.write_text('{"status":"FAIL","failure":"WAL stale"}\n', encoding="utf-8")
            with mock.patch.dict(os.environ, {"UTEN_BACKUP_ALERT_TEST_MODE": "1"}):
                self.alert._prepare_state(state)
                event = self.alert.create_event(
                    "uten-pgbackup-health.service",
                    health_path,
                    now=datetime.now(timezone.utc).replace(microsecond=0),
                )
                event_path = state / "pending" / f"{event['eventId']}.json"
                self.alert._atomic_new(event_path, self.alert._canonical(event))
                work_path = state / "work" / f"{event['eventId']}.receipt.json"
                self.alert._atomic_new(
                    work_path,
                    self.alert._canonical(
                        {
                            "schemaVersion": 1,
                            "eventId": event["eventId"],
                            "accepted": True,
                            "deliveredAtUtc": event["occurredAtUtc"],
                            "providerMessageId": "provider-message-after-restart",
                        }
                    ),
                )
                delivered = self.alert.deliver_event(event_path, state, root / "missing-sender")
            self.assertTrue(delivered)
            self.assertFalse(work_path.exists())
            self.assertTrue((state / "delivered" / f"{event['eventId']}.json").exists())
            self.assertTrue((state / "receipts" / f"{event['eventId']}.json").exists())

    def test_repeated_failure_deduplicates_pending_unit_and_redacts_secret_words(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            health_path = root / "health.json"
            health_path.write_text(
                '{"status":"FAIL","failure":"access_key secret accidentally present"}\n',
                encoding="utf-8",
            )
            missing = root / "missing-sender"
            with mock.patch.dict(os.environ, {"UTEN_BACKUP_ALERT_TEST_MODE": "1"}):
                self.assertFalse(
                    self.alert.emit("uten-pgbackup-health.service", root / "state", health_path, missing)
                )
                self.assertFalse(
                    self.alert.emit("uten-pgbackup-health.service", root / "state", health_path, missing)
                )
            pending = list((root / "state" / "pending").glob("*.json"))
            self.assertEqual(1, len(pending))
            event = json.loads(pending[0].read_text(encoding="utf-8"))
            self.assertNotIn("secret", event["summary"].lower())
            self.assertNotIn("access_key", event["summary"].lower())


@unittest.skipUnless(os.name == "posix", "acceptance receipt is production-POSIX only")
class BackupAcceptanceTest(unittest.TestCase):
    def setUp(self):
        self.now_epoch = 1786492800
        self.now = datetime.fromtimestamp(self.now_epoch, tz=timezone.utc)
        self.health = health.evaluate(
            policy(),
            repo_info(1, self.now_epoch),
            repo_info(2, self.now_epoch),
            archiver(self.now_epoch),
            flyway_history(),
        )

    def pitr(self, restore_sha: str) -> dict:
        point = self.health["repositories"][1]["restorePoints"][0]
        return {
            "schemaVersion": 1,
            "status": "PASS",
            "completedAtUtc": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "repository": 2,
            "sourceSystemIdentifier": "7523456789012345678",
            "sourceTimeline": 1,
            "backupSet": point["label"],
            "walStart": point["walStart"],
            "walStop": point["walStop"],
            "targetTimeUtc": self.now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "restoreReceiptSha256": restore_sha,
            "actualRtoSeconds": 900,
            "actualRpoSeconds": 120,
            "authorityReference": "authority-v238-accepted",
            "acceptanceOwner": "business-owner",
            "secondReviewer": "independent-reviewer",
            "checks": {
                key: {"status": "PASS", "evidenceReference": f"private-{key}-evidence"}
                for key in acceptance.REQUIRED_BUSINESS_CHECKS
            },
        }

    def test_detailed_receipt_binds_narrow_recovery_receipt(self):
        restore_sha = "a" * 64
        pitr = self.pitr(restore_sha)
        acceptance.validate_health(self.health, "7", 7, self.now)
        acceptance.validate_pitr_acceptance(pitr, self.health, restore_sha, self.now)
        signed_rows = "".join(
            f"{row['version']}\t{row['script']}\t{row['checksum']}\n"
            for row in flyway_history()
        ).encode("utf-8")
        signed_rows_sha = acceptance.validate_signed_flyway_rows(
            signed_rows, self.health, "7", 7
        )
        event = {
            "schemaVersion": 1,
            "eventId": "20260812T000000Z-" + "a" * 32,
        }
        receipt = {"providerMessageId": "provider-message-1"}
        detail_path = Path("/var/lib/uten-imp-backup/acceptance-receipts/backup-1.json")
        detail, narrow = acceptance.build_receipts(
            health=self.health,
            health_sha="1" * 64,
            worm_evidence=worm(self.now),
            worm_sha="2" * 64,
            alert_event=event,
            alert_event_sha="3" * 64,
            alert_receipt=receipt,
            alert_receipt_sha="4" * 64,
            restore_receipt_sha=restore_sha,
            pitr_acceptance=pitr,
            pitr_acceptance_sha="5" * 64,
            active_repo2_preflight={
                "schemaVersion": 1,
                "status": "ACTIVE_PREFLIGHT_PASS",
                "approvalReference": "change-approval-123",
                "policySha256": "9" * 64,
                "configSha256": "a" * 64,
                "repo1OverrideSha256": "b" * 64,
                "wormEvidenceSha256": "2" * 64,
                "secretsIncluded": False,
            },
            signed_release_evidence={
                "manifestSha256": "7" * 64,
                "signatureSha256": "8" * 64,
                "flywayRowsSha256": signed_rows_sha,
                "migrationSetSha256": "6" * 64,
            },
            approval="approval-123",
            version="v2026.08.12-1",
            head="7",
            migration_count=7,
            migration_set_sha="6" * 64,
            detail_path=detail_path,
        )
        detail_bytes = (json.dumps(detail, sort_keys=True, indent=2) + "\n").encode("utf-8")
        expected = hashlib.sha256(detail_bytes).hexdigest()
        self.assertEqual("backup", narrow["receiptType"])
        self.assertEqual(f"path={detail_path};sha256={expected}", narrow["evidenceReference"])
        self.assertEqual("7523456789012345678", detail["databaseIdentity"]["systemIdentifier"])
        self.assertEqual(2, detail["isolatedPitrEvidence"]["repository"])
        self.assertEqual("VERIFIED", detail["wormEvidence"]["status"])
        self.assertEqual(
            "ACTIVE_PREFLIGHT_PASS", detail["activeRepo2Preflight"]["status"]
        )
        self.assertEqual(signed_rows_sha, detail["signedReleaseEvidence"]["flywayRowsSha256"])

        drifted_rows = signed_rows.replace(b"\t119\n", b"\t120\n")
        with self.assertRaisesRegex(repo2.ContractError, "differ from the signed manifest"):
            acceptance.validate_signed_flyway_rows(
                drifted_rows, self.health, "7", 7
            )

    def test_restore_receipt_must_bind_repo2_set_and_target_time(self):
        pitr = self.pitr("a" * 64)
        restore = {
            "completedAtUtc": pitr["completedAtUtc"],
            "evidenceReference": (
                f"pgbackrest:repo=2;set={pitr['backupSet']};target={pitr['targetTimeUtc']}"
            )
        }
        acceptance.validate_restore_binding(restore, pitr)
        restore["evidenceReference"] = (
            f"pgbackrest:repo=1;set={pitr['backupSet']};target={pitr['targetTimeUtc']}"
        )
        with self.assertRaisesRegex(repo2.ContractError, "repo2"):
            acceptance.validate_restore_binding(restore, pitr)

    def test_installed_guard_output_is_bound_to_manifest_and_live_history(self):
        rows = "".join(
            f"{row['version']}\t{row['script']}\t{row['checksum']}\n"
            for row in flyway_history()
        ).encode("utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "manifest.json"
            signature = root / "manifest.sig"
            manifest.write_text(
                json.dumps(
                    {
                        "flyway": {
                            "headVersion": "7",
                            "migrationCount": 7,
                            "migrationSetSha256": "6" * 64,
                        }
                    }
                ),
                encoding="utf-8",
            )
            signature.write_bytes(b"test-signature")
            with mock.patch.object(
                acceptance.subprocess,
                "run",
                return_value=SimpleNamespace(returncode=0, stdout=rows),
            ) as invoked:
                evidence = acceptance.verify_signed_flyway(
                    manifest_path=manifest,
                    signature_path=signature,
                    expected_manifest_sha=hashlib.sha256(manifest.read_bytes()).hexdigest(),
                    expected_signature_sha=hashlib.sha256(signature.read_bytes()).hexdigest(),
                    version="v2026.08.12-1",
                    head="7",
                    migration_count=7,
                    migration_set_sha="6" * 64,
                    health=self.health,
                )
            self.assertEqual(hashlib.sha256(rows).hexdigest(), evidence["flywayRowsSha256"])
            command = invoked.call_args.args[0]
            self.assertEqual(str(acceptance.TRUSTED_RELEASE_GUARD), command[2])
            self.assertIn("verified-flyway-checksums", command)

    def test_missing_business_check_fails_closed(self):
        pitr = self.pitr("a" * 64)
        pitr["checks"].pop("finance")
        with self.assertRaisesRegex(repo2.ContractError, "incomplete"):
            acceptance.validate_pitr_acceptance(pitr, self.health, "a" * 64, self.now)

    def test_receipt_restart_reuses_exact_bytes_and_rejects_drift(self):
        value = {
            "schemaVersion": 1,
            "receiptType": "backup-acceptance-detail",
            "successful": True,
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.json"
            first_sha, first_created = acceptance._write_or_verify(path, value)
            with mock.patch.object(acceptance, "_secure_root_file"):
                second_sha, second_created = acceptance._write_or_verify(path, value)
                self.assertTrue(first_created)
                self.assertFalse(second_created)
                self.assertEqual(first_sha, second_sha)
                with self.assertRaisesRegex(repo2.ContractError, "overwrite is forbidden"):
                    acceptance._write_or_verify(path, {**value, "successful": False})


if __name__ == "__main__":
    unittest.main()
