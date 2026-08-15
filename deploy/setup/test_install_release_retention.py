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
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = PROJECT_ROOT / "deploy/setup/install-release-retention.py"
SPEC = importlib.util.spec_from_file_location("release_retention_installer_tested", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
installer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = installer
SPEC.loader.exec_module(installer)


class FakeRunner:
    def __init__(self, layout: installer.Layout) -> None:
        self.layout = layout
        self.commands: list[tuple[str, ...]] = []
        self.active_overrides: dict[str, str] = {}
        self.enabled_overrides: dict[str, str] = {}

    def __call__(self, command):
        values = tuple(command)
        self.commands.append(values)
        if values[:2] == ("/usr/bin/systemctl", "is-active"):
            value = self.active_overrides.get(values[2], "inactive")
            return installer.Completed(0 if value == "active" else 3, value + "\n", "")
        if values[:2] == ("/usr/bin/systemctl", "is-enabled"):
            value = self.enabled_overrides.get(values[2], "disabled")
            return installer.Completed(0 if value == "enabled" else 1, value + "\n", "")
        if values[:2] == ("/usr/bin/systemctl", "daemon-reload"):
            return installer.Completed(0, "", "")
        if values[:2] == ("/usr/bin/systemd-analyze", "verify"):
            return installer.Completed(0, "", "")
        if values[:2] == ("/usr/bin/systemctl", "show"):
            unit = values[2]
            targets = {
                "uten-imp-retention.service": self.layout.systemd_dir
                / "uten-imp-retention.service",
                "uten-imp-retention.timer": self.layout.systemd_dir
                / "uten-imp-retention.timer",
                "uten-imp-retention-alert@.service": self.layout.systemd_dir
                / "uten-imp-retention-alert@.service",
            }
            return installer.Completed(0, str(targets[unit]) + "\n", "")
        return installer.Completed(1, "", "unexpected command")


@unittest.skipUnless(os.name == "posix", "installer requires Linux no-follow APIs")
class ReleaseRetentionInstallerTest(unittest.TestCase):
    def setUp(self) -> None:
        if os.geteuid() != 0:
            self.skipTest("transaction tests run as WSL root")
        self.temporary = tempfile.TemporaryDirectory(
            prefix="retention-installer-", dir="/root"
        )
        self.root = Path(self.temporary.name)
        self.layout = installer.Layout(
            source_root=self.root / "source",
            root_state=self.root / "var/lib/uten-imp-release",
            updater_state=self.root / "var/lib/uten-imp-updater",
            release_base=self.root / "opt/uten-imp",
            policy_dir=self.root / "etc/uten-imp-release-retention",
            systemd_dir=self.root / "etc/systemd/system",
            local_sbin=self.root / "usr/local/sbin",
        )
        for directory in (
            self.layout.source_root / "deploy/updater",
            self.layout.source_root / "deploy/systemd",
            self.layout.root_state,
            self.layout.updater_state,
            self.layout.release_base / "releases",
            self.layout.updater_runtime_dir,
            self.layout.systemd_dir,
            self.layout.local_sbin,
        ):
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(0o755 if directory not in {self.layout.root_state} else 0o750)
            os.chown(directory, 0, 0)
        self._write(self.layout.lock_path, b"", 0o660)

        self.guard_raw = b"# frozen guard\n"
        self.guard_sha = hashlib.sha256(self.guard_raw).hexdigest()
        self.updater_raw = f'_GUARD_SHA256 = "{self.guard_sha}"\n'.encode()
        self.updater_sha = hashlib.sha256(self.updater_raw).hexdigest()
        self.manager_raw = b"# frozen retention manager\n"
        self.manager_sha = hashlib.sha256(self.manager_raw).hexdigest()
        launcher_raw = (
            f'APPROVED_RELEASE_UPDATER_SHA256 = "{self.updater_sha}"\n'
            f'APPROVED_RETENTION_MANAGER_SHA256 = "{self.manager_sha}"\n'
        ).encode()
        source_payloads = {
            "release_updater.py": self.updater_raw,
            "release_guard.py": self.guard_raw,
            "retention_manager.py": self.manager_raw,
            "retention_launcher.py": launcher_raw,
            "uten-imp-retention.sh": b"#!/bin/sh\nexit 78\n",
            "retention-policy.json.example": json.dumps(
                {
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
                },
                sort_keys=True,
            ).encode(),
        }
        for name, payload in source_payloads.items():
            self._write(self.layout.source_root / "deploy/updater" / name, payload, 0o400)
        for name in (
            "uten-imp-retention.service.example",
            "uten-imp-retention.timer.example",
            "uten-imp-retention-alert@.service.example",
        ):
            self._write(
                self.layout.source_root / "deploy/systemd" / name,
                f"# {name}\n".encode(),
                0o400,
            )
        self._write(
            self.layout.updater_runtime_dir / "release_updater.py",
            self.updater_raw,
            0o644,
        )
        self._write(
            self.layout.updater_runtime_dir / "release_guard.py",
            self.guard_raw,
            0o644,
        )
        self.runner = FakeRunner(self.layout)
        self.options = {
            "trusted_source_uid": 0,
            "trusted_source_gid": 0,
            "trusted_source_mode": 0o400,
            "pins_override": (self.updater_sha, self.manager_sha),
            "lock_gid": 0,
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _write(path: Path, raw: bytes, mode: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        path.chmod(mode)
        os.chown(path, 0, 0)

    def assessment(self):
        return installer.build_assessment(
            self.layout, runner=self.runner, **self.options
        )

    def record(self):
        assessment = self.assessment()
        self.assertEqual(assessment["blockers"], [])
        return installer.record_plan(
            self.layout,
            expected_assessment_sha256=installer.canonical_sha256(assessment),
            approver_one="ops.alice",
            approver_two="security.bob",
            approval_reference="CHANGE-RETENTION-1",
            runner=self.runner,
            assessment_options=self.options,
        )

    def test_assess_is_read_only_and_pending_updater_pin_is_no_go(self) -> None:
        before = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        assessment = self.assessment()
        after = sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*"))
        self.assertEqual(before, after)
        self.assertEqual(assessment["blockers"], [])
        pending = installer.build_assessment(
            self.layout,
            runner=self.runner,
            trusted_source_uid=0,
            trusted_source_gid=0,
            trusted_source_mode=0o400,
            pins_override=(None, self.manager_sha),
            lock_gid=0,
        )
        self.assertTrue(any("not frozen" in value for value in pending["blockers"]))
        self.assertFalse(self.layout.installer_state.exists())

    def test_plan_binds_assets_preimages_live_policy_and_two_approvers(self) -> None:
        preexisting = self.layout.systemd_dir / "uten-imp-retention.service"
        self._write(preexisting, b"# old exact unit\n", 0o640)
        path, plan, digest = self.record()
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)
        self.assertNotEqual(
            plan["approval"]["approverOne"], plan["approval"]["approverTwo"]
        )
        for asset in plan["assessment"]["assets"]:
            self.assertEqual(
                set(asset),
                {
                    "mode",
                    "name",
                    "source",
                    "sourceSha256",
                    "sourceSize",
                    "target",
                    "targetPreimage",
                },
            )
        service = next(
            item
            for item in plan["assessment"]["assets"]
            if item["name"] == "retention-service"
        )
        self.assertEqual(service["targetPreimage"]["sha256"], hashlib.sha256(b"# old exact unit\n").hexdigest())
        self.assertEqual(plan["assessment"]["livePolicy"]["state"], "missing")
        self.assertNotEqual(
            Path(
                next(
                    item for item in plan["assessment"]["assets"] if item["name"] == "policy-example"
                )["target"]
            ),
            self.layout.live_policy,
        )

    def test_unknown_preimage_and_post_plan_drift_refuse_without_install_write(self) -> None:
        unsafe = self.layout.systemd_dir / "uten-imp-retention.timer"
        unsafe.symlink_to(self.layout.lock_path)
        assessment = self.assessment()
        self.assertTrue(any("unknown preimage" in value for value in assessment["blockers"]))
        unsafe.unlink()
        path, _plan, digest = self.record()
        drift = self.layout.systemd_dir / "uten-imp-retention.timer"
        self._write(drift, b"external drift\n", 0o644)
        with self.assertRaisesRegex(installer.InstallerError, "assessment drifted"):
            installer.apply_plan(
                self.layout,
                plan_path=path,
                expected_plan_sha256=digest,
                confirm=f"APPLY-RELEASE-RETENTION:{digest}",
                runner=self.runner,
                assessment_options=self.options,
            )
        self.assertFalse(self.layout.active_path.exists())
        self.assertFalse((self.layout.updater_runtime_dir / "retention_manager.py").exists())

    def test_apply_resume_and_rollback_are_exact_and_never_mutate_timer_state(self) -> None:
        old_service = self.layout.systemd_dir / "uten-imp-retention.service"
        self._write(old_service, b"# old unit preimage\n", 0o640)
        release_sentinel = self.layout.release_base / "releases/v-test/sentinel"
        self._write(release_sentinel, b"do not touch\n", 0o600)
        path, _plan, digest = self.record()

        def crash(phase: str) -> None:
            if phase == "asset-000-installed":
                raise RuntimeError("injected crash")

        with self.assertRaisesRegex(RuntimeError, "injected crash"):
            installer.apply_plan(
                self.layout,
                plan_path=path,
                expected_plan_sha256=digest,
                confirm=f"APPLY-RELEASE-RETENTION:{digest}",
                runner=self.runner,
                hook=crash,
                assessment_options=self.options,
            )
        active = json.loads(self.layout.active_path.read_text())
        transaction = Path(active["transactionPath"])
        transaction_path = transaction / "transaction.json"
        transaction_sha = hashlib.sha256(transaction_path.read_bytes()).hexdigest()
        receipt, _receipt_sha = installer.resume(
            self.layout,
            transaction=transaction,
            expected_transaction_sha256=transaction_sha,
            confirm=f"RESUME-RELEASE-RETENTION:{transaction_sha}",
            runner=self.runner,
            source_options={
                "trusted_source_uid": 0,
                "trusted_source_gid": 0,
                "trusted_source_mode": 0o400,
                "lock_gid": 0,
            },
        )
        self.assertEqual(receipt["status"], "installed-uncommissioned-timers-disabled")
        self.assertFalse(self.layout.active_path.exists())
        self.assertFalse(self.layout.live_policy.exists())
        self.assertTrue((self.layout.policy_dir / "policy.json.example").exists())
        forbidden = {"start", "stop", "enable", "disable", "restart"}
        self.assertFalse(
            any(len(command) > 1 and command[1] in forbidden for command in self.runner.commands)
        )

        current_transaction_sha = hashlib.sha256(transaction_path.read_bytes()).hexdigest()
        rollback_receipt, _rollback_sha = installer.rollback(
            self.layout,
            transaction=transaction,
            expected_transaction_sha256=current_transaction_sha,
            confirm=f"ROLLBACK-RELEASE-RETENTION:{current_transaction_sha}",
            runner=self.runner,
            lock_gid=0,
        )
        self.assertEqual(rollback_receipt["status"], "exact-preimages-restored")
        self.assertEqual(old_service.read_bytes(), b"# old unit preimage\n")
        self.assertEqual(stat.S_IMODE(old_service.stat().st_mode), 0o640)
        self.assertEqual(release_sentinel.read_bytes(), b"do not touch\n")
        self.assertFalse((self.layout.updater_runtime_dir / "retention_manager.py").exists())
        rolled_back_sha = hashlib.sha256(transaction_path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(installer.InstallerError, "cannot be resumed"):
            installer.resume(
                self.layout,
                transaction=transaction,
                expected_transaction_sha256=rolled_back_sha,
                confirm=f"RESUME-RELEASE-RETENTION:{rolled_back_sha}",
                runner=self.runner,
                source_options={
                    "trusted_source_uid": 0,
                    "trusted_source_gid": 0,
                    "trusted_source_mode": 0o400,
                    "lock_gid": 0,
                },
            )
        self.assertFalse((self.layout.updater_runtime_dir / "retention_manager.py").exists())

    def test_resume_recovers_orphan_preimage_after_exact_fsync_window(self) -> None:
        old_service = self.layout.systemd_dir / "uten-imp-retention.service"
        self._write(old_service, b"# durable old unit\n", 0o640)
        path, _plan, digest = self.record()
        real_atomic_create = installer.atomic_create
        crashed = False

        def crash_after_preimage_fsync(target, raw, mode=0o600):
            nonlocal crashed
            real_atomic_create(target, raw, mode)
            if target.parent.name == "preimages" and not crashed:
                crashed = True
                raise RuntimeError("crash after preimage fsync")

        with mock.patch.object(installer, "atomic_create", side_effect=crash_after_preimage_fsync):
            with self.assertRaisesRegex(RuntimeError, "crash after preimage fsync"):
                installer.apply_plan(
                    self.layout,
                    plan_path=path,
                    expected_plan_sha256=digest,
                    confirm=f"APPLY-RELEASE-RETENTION:{digest}",
                    runner=self.runner,
                    assessment_options=self.options,
                )
        active = json.loads(self.layout.active_path.read_text())
        transaction = Path(active["transactionPath"])
        transaction_path = transaction / "transaction.json"
        before = json.loads(transaction_path.read_text())
        self.assertIsNone(before["assets"][4]["preimage"])
        self.assertTrue((transaction / "preimages/004.bin").exists())

        transaction_sha = hashlib.sha256(transaction_path.read_bytes()).hexdigest()
        receipt, _receipt_sha = installer.resume(
            self.layout,
            transaction=transaction,
            expected_transaction_sha256=transaction_sha,
            confirm=f"RESUME-RELEASE-RETENTION:{transaction_sha}",
            runner=self.runner,
            source_options={
                "trusted_source_uid": 0,
                "trusted_source_gid": 0,
                "trusted_source_mode": 0o400,
                "lock_gid": 0,
            },
        )
        self.assertEqual(receipt["status"], "installed-uncommissioned-timers-disabled")

    def test_resume_rejects_timer_drift_before_any_recovery_write(self) -> None:
        path, _plan, digest = self.record()

        def crash(phase: str) -> None:
            if phase == "transaction-active":
                raise RuntimeError("injected early crash")

        with self.assertRaisesRegex(RuntimeError, "injected early crash"):
            installer.apply_plan(
                self.layout,
                plan_path=path,
                expected_plan_sha256=digest,
                confirm=f"APPLY-RELEASE-RETENTION:{digest}",
                runner=self.runner,
                hook=crash,
                assessment_options=self.options,
            )
        active = json.loads(self.layout.active_path.read_text())
        transaction = Path(active["transactionPath"])
        transaction_path = transaction / "transaction.json"
        before = transaction_path.read_bytes()
        self.runner.active_overrides["uten-imp-retention.timer"] = "active"
        transaction_sha = hashlib.sha256(before).hexdigest()
        with self.assertRaisesRegex(installer.InstallerError, "timer is not disabled"):
            installer.resume(
                self.layout,
                transaction=transaction,
                expected_transaction_sha256=transaction_sha,
                confirm=f"RESUME-RELEASE-RETENTION:{transaction_sha}",
                runner=self.runner,
                source_options={
                    "trusted_source_uid": 0,
                    "trusted_source_gid": 0,
                    "trusted_source_mode": 0o400,
                    "lock_gid": 0,
                },
            )
        self.assertEqual(transaction_path.read_bytes(), before)
        self.assertEqual(list((transaction / "preimages").iterdir()), [])
        self.assertFalse((self.layout.updater_runtime_dir / "retention_manager.py").exists())

    def test_record_plan_takes_operation_lock_before_first_write(self) -> None:
        assessment = self.assessment()
        events: list[str] = []
        real_lock = installer.OperationLock
        real_ensure = installer._ensure_installer_state

        class TracedLock(real_lock):
            def __enter__(self):
                result = super().__enter__()
                events.append("lock")
                return result

        def traced_ensure(layout):
            events.append("write")
            return real_ensure(layout)

        with mock.patch.object(installer, "OperationLock", TracedLock), mock.patch.object(
            installer, "_ensure_installer_state", side_effect=traced_ensure
        ):
            installer.record_plan(
                self.layout,
                expected_assessment_sha256=installer.canonical_sha256(assessment),
                approver_one="ops.alice",
                approver_two="security.bob",
                approval_reference="CHANGE-RETENTION-2",
                runner=self.runner,
                assessment_options=self.options,
            )
        self.assertEqual(events[:2], ["lock", "write"])


if __name__ == "__main__":
    unittest.main()
