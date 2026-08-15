from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_existing_host_monitoring_installer_module",
    ROOT / "existing_host_monitoring_installer.py",
)
assert SPEC is not None and SPEC.loader is not None
installer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = installer
SPEC.loader.exec_module(installer)


def canonical(value):
    return installer.canonical_bytes(value)


class FakeSystemd:
    def __init__(self, systemd_dir: pathlib.Path):
        self.systemd_dir = systemd_dir
        self.commands: list[tuple[str, ...]] = []
        self.jobs: list[str] = []
        self.failure_instances: list[str] = []
        self.journald = {
            "LoadState": "loaded",
            "ActiveState": "active",
            "SubState": "running",
            "MainPID": "123",
        }

    def __call__(self, command):
        values = tuple(command)
        self.commands.append(values)
        if values[:3] == ("/usr/bin/systemctl", "show", "systemd-journald.service"):
            stdout = "".join(f"{key}={value}\n" for key, value in self.journald.items())
            return subprocess.CompletedProcess(command, 0, stdout, "")
        if values[:2] == ("/usr/bin/systemctl", "show"):
            unit = values[2]
            path = self.systemd_dir / unit
            installed = path.is_file()
            exec_start = ""
            if unit in installer.EXECSTART_NEEDLES and installed:
                exec_start = "/usr/bin/python3 -I -B /usr/local/libexec/uten-imp-monitoring/" + installer.EXECSTART_NEEDLES[unit]
            properties = {
                "LoadState": "loaded" if installed else "not-found",
                "ActiveState": "inactive",
                "SubState": "dead",
                "UnitFileState": "disabled" if unit in installer.TIMER_UNITS else ("static" if installed else "not-found"),
                "FragmentPath": str(path) if installed else "",
                "DropInPaths": "",
                "ExecStart": exec_start,
            }
            return subprocess.CompletedProcess(
                command,
                0,
                "".join(f"{key}={properties[key]}\n" for key in installer.UNIT_PROPERTIES),
                "",
            )
        if values[:2] == ("/usr/bin/systemctl", "list-jobs"):
            return subprocess.CompletedProcess(
                command,
                0,
                "".join(f"1 {unit} start running\n" for unit in self.jobs),
                "",
            )
        if values[:2] == ("/usr/bin/systemctl", "list-units"):
            return subprocess.CompletedProcess(
                command,
                0,
                "".join(f"{unit} loaded active running fixture\n" for unit in self.failure_instances),
                "",
            )
        if values == ("/usr/bin/systemctl", "daemon-reload"):
            return subprocess.CompletedProcess(command, 0, "", "")
        if values[:2] == ("/usr/bin/systemd-analyze", "verify"):
            return subprocess.CompletedProcess(command, 0, "", "")
        raise AssertionError(values)


class MonitoringInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        os.chmod(self.root, 0o700)
        self.sources = self.root / "reviewed-sources"
        self.sources.mkdir(mode=0o700)
        self.libexec = self.root / "usr-local-libexec"
        self.config = self.root / "etc-monitoring"
        self.docs = self.root / "docs"
        self.systemd = self.root / "systemd"
        self.systemd.mkdir(mode=0o755)
        self.state = self.root / "state"
        self.journal = self.state / "journal"
        self.installer_root = self.journal / "installer"
        self.journald_installer_root = self.journal / "journald-installer"
        self.journald_target = self.root / "journald.conf.d" / "60-uten-imp.conf"
        self.runner = FakeSystemd(self.systemd)
        self.patches = [
            mock.patch.dict(os.environ, {"UTEN_MONITOR_INSTALLER_TEST_MODE": "1"}),
            mock.patch.multiple(
                installer,
                STATE_ROOT=self.state,
                JOURNAL_ROOT=self.journal,
                INSTALLER_ROOT=self.installer_root,
                PLAN_PATH=self.installer_root / "install-plan.json",
                PLAN_HISTORY=self.installer_root / "plan-history",
                TRANSACTIONS=self.installer_root / "transactions",
                ROLLBACK_RECEIPTS=self.installer_root / "rollback-receipts",
                ACTIVE_TRANSACTION=self.installer_root / "active-transaction.json",
                UNCOMMISSIONED_RECEIPT=self.installer_root / "uncommissioned-install.json",
                COMMISSIONED_MARKER=self.installer_root / "commissioned.json",
                LOCK_PATH=self.installer_root / "installer.lock",
                JOURNALD_INSTALLER_ROOT=self.journald_installer_root,
                JOURNALD_PLAN_PATH=self.journald_installer_root / "install-plan.json",
                JOURNALD_TRANSACTION_PATH=self.journald_installer_root / "active-transaction.json",
                JOURNALD_RECEIPT_PATH=self.journald_installer_root / "uncommissioned-install.json",
                JOURNALD_ROLLBACK_RECEIPTS=self.journald_installer_root / "rollback-receipts",
                JOURNALD_TRANSACTIONS=self.journald_installer_root / "transactions",
                JOURNALD_LOCK_PATH=self.journald_installer_root / "installer.lock",
                JOURNALD_TARGET=self.journald_target,
                LIBEXEC_DIR=self.libexec,
                CONFIG_DIR=self.config,
                DOC_DIR=self.docs,
                SYSTEMD_DIR=self.systemd,
                HOST_POLICY_TARGET=self.config / "host-policy.json",
                EXTERNAL_POLICY_TARGET=self.config / "external-policy.json",
                HARDWARE_AUTHORITY_TARGET=self.config / "storage-hardware-authority.json",
                FIXED_ALERT_SENDER=self.root / "missing-alert-sender",
                DIRECTORIES=((self.libexec, 0o500), (self.config, 0o755), (self.docs, 0o755)),
            ),
            mock.patch.object(
                installer,
                "_root_parent_chain",
                side_effect=lambda path: ((str(path.parent), installer._fingerprint(path.parent.stat())),),
            ),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.static_assets = self._static_assets()
        self.inputs = self._policy_inputs()

    def _source(self, name: str, raw: bytes) -> pathlib.Path:
        path = self.sources / name
        path.write_bytes(raw)
        os.chmod(path, 0o400)
        return path

    def _static_assets(self):
        assets = []
        runtime_names = (
            ("runtime-launcher", "monitor_runtime_launcher.py", 0o500),
            ("monitoring-common", "monitoring_common.py", 0o400),
            ("alert-spool", "alert_spool.py", 0o400),
            ("host-monitor", "host_monitor.py", 0o400),
            ("external-probe", "external_probe.py", 0o400),
        )
        for asset_name, filename, mode in runtime_names:
            assets.append(
                installer.Asset(
                    asset_name,
                    self._source(f"source-{filename}", f"# {asset_name}\n".encode()),
                    self.libexec / filename,
                    mode,
                )
            )
        for unit in installer.MANAGED_UNITS:
            assets.append(
                installer.Asset(
                    f"unit-{unit}",
                    self._source(f"source-{unit}", f"# {unit}\n".encode()),
                    self.systemd / unit,
                    0o644,
                )
            )
        assets.append(
            installer.Asset(
                "runbook",
                self._source("source-README.zh-CN.md", b"reviewed runbook\n"),
                self.docs / "README.zh-CN.md",
                0o644,
            )
        )
        return tuple(assets)

    def _policy_inputs(self):
        hardware = {
            "format": "uten-imp-monitor-storage-hardware-authority-v2",
            "erpStorageAuthorityPath": "/etc/uten-imp/storage-authority.json",
            "erpStorageAuthoritySha256": "1" * 64,
            "smart": [{"device": "/dev/disk/by-id/nvme-UTEN"}],
        }
        hardware_raw = canonical(hardware)
        hardware_sha = hashlib.sha256(hardware_raw).hexdigest()
        host = {
            "format": "uten-imp-host-monitor-policy-v1",
            "journald": {
                "dropInPath": "/etc/systemd/journald.conf.d/60-uten-imp.conf",
                "dropInSha256": "2" * 64,
            },
            "ntp": {"provider": "systemd-timesyncd"},
            "hardware": {
                "mode": "local-lvm-nvme",
                "authorityPath": str(self.config / "storage-hardware-authority.json"),
                "authoritySha256": hardware_sha,
            },
            "filesystems": [{"path": "/data"}],
            "certificates": [{"name": "erp"}],
            "units": [{"name": "nginx.service"}],
            "postgres": {"enabled": True},
        }
        external = {
            "format": "uten-imp-external-monitor-policy-v1",
            "checks": [
                {
                    "name": "erp-health",
                    "url": "https://erp.internal.corp/actuator/health",
                }
            ],
        }
        values = []
        for name, filename, value, target, mode in (
            ("host-policy", "approved-host-policy.json", host, self.config / "host-policy.json", 0o644),
            ("external-policy", "approved-external-policy.json", external, self.config / "external-policy.json", 0o644),
            ("hardware-authority", "approved-hardware-authority.json", hardware, self.config / "storage-hardware-authority.json", 0o640),
        ):
            raw = canonical(value)
            source = self._source(filename, raw)
            values.append(installer.PolicyInput(name, source, hashlib.sha256(raw).hexdigest(), target, mode))
        return tuple(values)

    def _record(self):
        _, assessment_sha = installer.assess(
            self.inputs, static_assets=self.static_assets, runner=self.runner
        )
        _, plan_sha = installer.record_plan(
            self.inputs,
            expected_assessment_sha256=assessment_sha,
            confirmation=installer.RECORD_CONFIRMATION,
            static_assets=self.static_assets,
            runner=self.runner,
        )
        return plan_sha

    def test_assess_is_read_only_and_binds_all_three_inputs(self):
        envelope, digest = installer.assess(
            self.inputs, static_assets=self.static_assets, runner=self.runner
        )
        self.assertFalse(self.state.exists())
        self.assertEqual(digest, envelope["assessmentSha256"])
        names = {item["name"] for item in envelope["assessment"]["sources"]}
        self.assertTrue({"host-policy", "external-policy", "hardware-authority"}.issubset(names))
        self.assertFalse(envelope["assessment"]["timerCommissioningAllowed"])

    def test_apply_leaves_timers_disabled_and_rollback_preserves_journal(self):
        plan_sha = self._record()
        receipt, _ = installer.apply_plan(
            self.inputs,
            plan_path=installer.PLAN_PATH,
            expected_plan_sha256=plan_sha,
            confirmation=installer.APPLY_CONFIRMATION,
            static_assets=self.static_assets,
            runner=self.runner,
        )
        self.assertFalse(receipt["timerCommissioningAllowed"])
        self.assertFalse(receipt["installedSystemd"]["timersEnabled"])
        self.assertFalse(receipt["installedSystemd"]["timersActive"])
        self.assertEqual(receipt["installedSystemd"]["alertSender"]["state"], "absent")
        forbidden = {"start", "stop", "restart", "try-restart", "enable", "disable"}
        self.assertFalse(
            any(len(command) > 1 and command[0] == "/usr/bin/systemctl" and command[1] in forbidden for command in self.runner.commands)
        )
        evidence_raw = installer.UNCOMMISSIONED_RECEIPT.read_bytes()
        original_unlink = pathlib.Path.unlink

        def unlink_as_root(path, *args, **kwargs):
            if path.parent != self.libexec:
                return original_unlink(path, *args, **kwargs)
            os.chmod(self.libexec, 0o700)
            try:
                return original_unlink(path, *args, **kwargs)
            finally:
                if self.libexec.exists():
                    os.chmod(self.libexec, 0o500)

        with mock.patch.object(
            pathlib.Path, "unlink", autospec=True, side_effect=unlink_as_root
        ):
            rollback_receipt, _ = installer.rollback(
                evidence_path=installer.UNCOMMISSIONED_RECEIPT,
                expected_evidence_sha256=hashlib.sha256(evidence_raw).hexdigest(),
                confirmation=installer.ROLLBACK_CONFIRMATION,
                runner=self.runner,
            )
        self.assertEqual(rollback_receipt["journalPreserved"], str(self.journal))
        self.assertTrue(self.journal.is_dir())
        for asset in (*self.static_assets, *installer._policy_assets(self.inputs)):
            self.assertFalse(asset.target.exists())

    def test_source_path_replacement_is_rejected_before_managed_write(self):
        plan_sha = self._record()
        victim = self.static_assets[0].source

        def replace(phase):
            if phase == "sources-captured":
                replacement = victim.parent / "replacement"
                replacement.write_bytes(b"# attacker replacement\n")
                os.chmod(replacement, 0o400)
                os.replace(replacement, victim)

        with self.assertRaisesRegex(installer.InstallerError, "changed after capture"):
            installer.apply_plan(
                self.inputs,
                plan_path=installer.PLAN_PATH,
                expected_plan_sha256=plan_sha,
                confirmation=installer.APPLY_CONFIRMATION,
                static_assets=self.static_assets,
                runner=self.runner,
                fault_hook=replace,
            )
        self.assertFalse(any(asset.target.exists() for asset in self.static_assets))
        self.assertNotIn(("/usr/bin/systemctl", "daemon-reload"), self.runner.commands)

    def test_source_hash_drift_is_rejected_before_transaction_or_target_write(self):
        plan_sha = self._record()
        policy = self.inputs[1].source
        os.chmod(policy, 0o600)
        policy.write_bytes(policy.read_bytes() + b" ")
        os.chmod(policy, 0o400)
        with self.assertRaises(installer.InstallerError):
            installer.apply_plan(
                self.inputs,
                plan_path=installer.PLAN_PATH,
                expected_plan_sha256=plan_sha,
                confirmation=installer.APPLY_CONFIRMATION,
                static_assets=self.static_assets,
                runner=self.runner,
            )
        self.assertFalse(installer.ACTIVE_TRANSACTION.exists())
        self.assertFalse(any(asset.target.exists() for asset in self.static_assets))

    def test_unknown_transaction_preimage_path_is_rejected_before_rollback_write(self):
        self.libexec.mkdir(mode=0o700)
        legacy_target = self.static_assets[0].target
        legacy_target.write_bytes(b"legacy reviewed launcher\n")
        os.chmod(legacy_target, 0o500)
        os.chmod(self.libexec, 0o500)
        plan_sha = self._record()
        receipt, receipt_sha = installer.apply_plan(
            self.inputs,
            plan_path=installer.PLAN_PATH,
            expected_plan_sha256=plan_sha,
            confirmation=installer.APPLY_CONFIRMATION,
            static_assets=self.static_assets,
            runner=self.runner,
        )
        transaction_path = pathlib.Path(receipt["transactionPath"]) / "transaction.json"
        transaction = json.loads(transaction_path.read_text(encoding="utf-8"))
        transaction["files"][0]["preimage"] = str(self.root / "unknown-preimage.bin")
        transaction_path.write_bytes(canonical(transaction))
        os.chmod(transaction_path, 0o600)
        before = {asset.target: asset.target.read_bytes() for asset in self.static_assets}
        with self.assertRaisesRegex(installer.InstallerError, "preimage record is malformed"):
            installer.rollback(
                evidence_path=installer.UNCOMMISSIONED_RECEIPT,
                expected_evidence_sha256=receipt_sha,
                confirmation=installer.ROLLBACK_CONFIRMATION,
                runner=self.runner,
            )
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        self.assertTrue(installer.UNCOMMISSIONED_RECEIPT.exists())

    def test_unknown_target_drift_is_rejected_before_first_restore(self):
        plan_sha = self._record()
        _, receipt_sha = installer.apply_plan(
            self.inputs,
            plan_path=installer.PLAN_PATH,
            expected_plan_sha256=plan_sha,
            confirmation=installer.APPLY_CONFIRMATION,
            static_assets=self.static_assets,
            runner=self.runner,
        )
        all_assets = (*self.static_assets, *installer._policy_assets(self.inputs))
        # The first asset would be restored last by the rollback loop.  A full
        # read-only preflight must still reject its drift before the last asset
        # (the first reverse-order mutation) is touched.
        victim = all_assets[0].target
        os.chmod(victim, 0o600)
        victim.write_bytes(b"unknown drift\n")
        os.chmod(victim, all_assets[0].mode)
        first_reverse = all_assets[-1].target
        first_reverse_before = first_reverse.read_bytes()
        with self.assertRaisesRegex(installer.InstallerError, "target drift"):
            installer.rollback(
                evidence_path=installer.UNCOMMISSIONED_RECEIPT,
                expected_evidence_sha256=receipt_sha,
                confirmation=installer.ROLLBACK_CONFIRMATION,
                runner=self.runner,
            )
        self.assertEqual(first_reverse.read_bytes(), first_reverse_before)
        self.assertTrue(installer.UNCOMMISSIONED_RECEIPT.exists())

    def test_tampered_preimage_bytes_are_rejected_before_first_restore(self):
        self.libexec.mkdir(mode=0o700)
        legacy_target = self.static_assets[0].target
        legacy_target.write_bytes(b"legacy reviewed launcher\n")
        os.chmod(legacy_target, 0o500)
        os.chmod(self.libexec, 0o500)
        plan_sha = self._record()
        receipt, receipt_sha = installer.apply_plan(
            self.inputs,
            plan_path=installer.PLAN_PATH,
            expected_plan_sha256=plan_sha,
            confirmation=installer.APPLY_CONFIRMATION,
            static_assets=self.static_assets,
            runner=self.runner,
        )
        transaction_path = pathlib.Path(receipt["transactionPath"]) / "transaction.json"
        transaction = json.loads(transaction_path.read_text(encoding="utf-8"))
        preimage = pathlib.Path(transaction["files"][0]["preimage"])
        os.chmod(preimage, 0o600)
        preimage.write_bytes(b"unknown preimage bytes\n")
        before = {
            asset.target: asset.target.read_bytes()
            for asset in (*self.static_assets, *installer._policy_assets(self.inputs))
        }
        with self.assertRaisesRegex(installer.InstallerError, "preimage digest differs"):
            installer.rollback(
                evidence_path=installer.UNCOMMISSIONED_RECEIPT,
                expected_evidence_sha256=receipt_sha,
                confirmation=installer.ROLLBACK_CONFIRMATION,
                runner=self.runner,
            )
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        self.assertTrue(installer.UNCOMMISSIONED_RECEIPT.exists())

    def test_interrupted_file_install_resumes_from_evidence(self):
        plan_sha = self._record()

        def crash(phase):
            if phase == "file-001-installed":
                raise RuntimeError("simulated power loss")

        with self.assertRaisesRegex(RuntimeError, "simulated power loss"):
            installer.apply_plan(
                self.inputs,
                plan_path=installer.PLAN_PATH,
                expected_plan_sha256=plan_sha,
                confirmation=installer.APPLY_CONFIRMATION,
                static_assets=self.static_assets,
                runner=self.runner,
                fault_hook=crash,
            )
        evidence = installer.ACTIVE_TRANSACTION.read_bytes()
        receipt, _ = installer.resume(
            self.inputs,
            expected_evidence_sha256=hashlib.sha256(evidence).hexdigest(),
            static_assets=self.static_assets,
            runner=self.runner,
        )
        self.assertFalse(receipt["timerCommissioningAllowed"])
        self.assertFalse(installer.ACTIVE_TRANSACTION.exists())

    def test_power_loss_between_durable_and_active_phase_resumes(self):
        plan_sha = self._record()
        original_write = installer._atomic_write
        failed = False

        def interrupt_active(path, payload, **kwargs):
            nonlocal failed
            if (
                path == installer.ACTIVE_TRANSACTION
                and kwargs.get("replace") is True
                and not failed
            ):
                failed = True
                raise RuntimeError("simulated mirror power loss")
            return original_write(path, payload, **kwargs)

        with mock.patch.object(installer, "_atomic_write", side_effect=interrupt_active):
            with self.assertRaisesRegex(RuntimeError, "mirror power loss"):
                installer.apply_plan(
                    self.inputs,
                    plan_path=installer.PLAN_PATH,
                    expected_plan_sha256=plan_sha,
                    confirmation=installer.APPLY_CONFIRMATION,
                    static_assets=self.static_assets,
                    runner=self.runner,
                )
        evidence = installer.ACTIVE_TRANSACTION.read_bytes()
        receipt, _ = installer.resume(
            self.inputs,
            expected_evidence_sha256=hashlib.sha256(evidence).hexdigest(),
            static_assets=self.static_assets,
            runner=self.runner,
        )
        self.assertFalse(receipt["timerCommissioningAllowed"])

    def test_active_job_and_example_input_fail_closed(self):
        self.runner.jobs = [installer.TIMER_UNITS[0]]
        with self.assertRaises(installer.InstallerError):
            installer.assess(self.inputs, static_assets=self.static_assets, runner=self.runner)
        self.runner.jobs = []
        self.runner.failure_instances = [
            "uten-imp-monitor-failure@uten-imp-host-monitor.service.service"
        ]
        with self.assertRaises(installer.InstallerError):
            installer.assess(self.inputs, static_assets=self.static_assets, runner=self.runner)
        self.runner.failure_instances = []
        bad = list(self.inputs)
        bad[0] = installer.PolicyInput(
            bad[0].name,
            bad[0].source.with_name("host-policy.example.json"),
            bad[0].expected_sha256,
            bad[0].target,
            bad[0].mode,
        )
        bad[0].source.write_bytes(self.inputs[0].source.read_bytes())
        os.chmod(bad[0].source, 0o400)
        with self.assertRaisesRegex(installer.InstallerError, "not an example"):
            installer.assess(tuple(bad), static_assets=self.static_assets, runner=self.runner)

    def test_optional_journald_transaction_never_restarts_and_rolls_back(self):
        source = self._source(
            "approved-journald.conf",
            b"[Journal]\nStorage=persistent\nCompress=yes\nSeal=yes\nSystemMaxUse=2G\nSystemKeepFree=5G\nSystemMaxFileSize=128M\nMaxRetentionSec=30day\nRateLimitIntervalSec=30s\nRateLimitBurst=20000\n",
        )
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        _, assessment_sha = installer.journald_assess(source, digest, runner=self.runner)
        _, plan_sha = installer.journald_record_plan(
            source,
            digest,
            expected_assessment_sha256=assessment_sha,
            confirmation=installer.JOURNALD_RECORD_CONFIRMATION,
            runner=self.runner,
        )
        receipt, receipt_sha = installer.journald_apply(
            source,
            digest,
            expected_plan_sha256=plan_sha,
            confirmation=installer.JOURNALD_APPLY_CONFIRMATION,
            runner=self.runner,
        )
        self.assertFalse(receipt["restartPerformed"])
        self.assertTrue(receipt["activationPending"])
        self.assertEqual(hashlib.sha256(self.journald_target.read_bytes()).hexdigest(), digest)
        forbidden = {"reload", "restart", "try-restart", "kill"}
        self.assertFalse(
            any(len(command) > 1 and command[0] == "/usr/bin/systemctl" and command[1] in forbidden for command in self.runner.commands)
        )
        rollback_receipt, _ = installer.journald_rollback(
            evidence_path=installer.JOURNALD_RECEIPT_PATH,
            expected_evidence_sha256=receipt_sha,
            confirmation=installer.JOURNALD_ROLLBACK_CONFIRMATION,
            runner=self.runner,
        )
        self.assertFalse(rollback_receipt["restartPerformed"])
        self.assertFalse(self.journald_target.exists())
        self.assertTrue(self.journal.is_dir())


class StaticContractTests(unittest.TestCase):
    def test_installer_has_no_enable_start_or_network_command(self):
        text = (ROOT / "existing_host_monitoring_installer.py").read_text(encoding="utf-8")
        self.assertNotRegex(text, r"systemctl[^\n]*(?:enable|start|restart|try-restart)")
        self.assertNotIn("urllib", text)
        self.assertNotIn("requests", text)
        self.assertIn("journalPreserved", text)

    def test_units_only_execute_the_reviewed_runtime_launcher(self):
        systemd = ROOT.parent / "systemd"
        for unit in installer.SERVICE_UNITS:
            text = (systemd / f"{unit}.example").read_text(encoding="utf-8")
            self.assertIn("monitor_runtime_launcher.py", text)
            self.assertIn("/usr/bin/python3 -I -B", text)


if __name__ == "__main__":
    unittest.main()
