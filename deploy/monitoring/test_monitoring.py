from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import re
import stat
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


common = load("test_monitor_common", "monitoring_common.py")
sys.modules["uten_imp_monitoring_common"] = common
alerts = load("test_monitor_alerts", "alert_spool.py")
sys.modules["uten_imp_monitoring_alert_spool"] = alerts
host = load("test_host_monitor", "host_monitor.py")
external = load("test_external_monitor", "external_probe.py")


def canonical(value):
    return common.canonical_json(value)


def issue(code="unit.nginx-activity", severity="critical", summary="nginx down"):
    return {
        "code": code,
        "severity": severity,
        "summary": summary,
        "requiredAction": "inspect evidence before changing service state",
    }


def report(source, issues):
    return {
        "format": alerts.REPORT_FORMATS[source],
        "source": source,
        "observedAtUtc": "2026-08-12T00:00:00Z",
        "bootId": "test-boot",
        "policySha256": "a" * 64,
        "status": "PASS" if not issues else "FAIL",
        "issues": issues,
        "evidence": {},
        "containsSecrets": False,
    }


class CommonTests(unittest.TestCase):
    def test_strict_json_rejects_duplicate(self):
        with self.assertRaises(common.MonitoringError):
            common.strict_json(b'{"x":1,"x":2}\n')

    def test_atomic_replace_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target = root / "target"
            target.write_text("x", encoding="utf-8")
            link = root / "state.json"
            link.symlink_to(target)
            with self.assertRaises(common.MonitoringError):
                common.atomic_replace(link, b"{}\n")

    def test_clean_text_suppresses_secret_words(self):
        self.assertIn("suppressed", common.clean_text("token=do-not-print"))


class AlertSpoolTests(unittest.TestCase):
    def setUp(self):
        self.environment = mock.patch.dict(os.environ, {"UTEN_MONITOR_TEST_MODE": "1"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def _state_and_report(self, source="host", issues=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        state = pathlib.Path(temporary.name) / "state"
        state.mkdir(mode=0o700)
        report_path = pathlib.Path(temporary.name) / "report.json"
        report_path.write_bytes(canonical(report(source, issues or [])))
        os.chmod(report_path, 0o600)
        return state, report_path

    def test_open_deduplicates_and_recovery_are_episode_bound(self):
        state, report_path = self._state_and_report(issues=[issue()])
        now = datetime(2026, 8, 12, tzinfo=timezone.utc)
        created, pending = alerts.record_report(report_path, "host", state, now=now)
        self.assertEqual((created, pending), (1, 1))
        first = next((state / "alerts" / "pending").glob("*.json"))
        first_event = json.loads(first.read_text(encoding="utf-8"))

        created, pending = alerts.record_report(report_path, "host", state, now=now)
        self.assertEqual((created, pending), (0, 1))

        changed = report("host", [issue(summary="nginx still down")])
        report_path.write_bytes(canonical(changed))
        created, pending = alerts.record_report(report_path, "host", state, now=now)
        self.assertEqual((created, pending), (1, 2))

        report_path.write_bytes(canonical(report("host", [])))
        created, pending = alerts.record_report(report_path, "host", state, now=now)
        self.assertEqual((created, pending), (1, 3))
        events = [json.loads(path.read_text(encoding="utf-8")) for path in (state / "alerts" / "pending").glob("*.json")]
        self.assertEqual({value["kind"] for value in events}, {"opened", "updated", "recovered"})
        self.assertEqual({value["episodeId"] for value in events}, {first_event["episodeId"]})

    def test_report_tamper_and_duplicate_codes_fail_closed(self):
        state, report_path = self._state_and_report(issues=[issue(), issue()])
        with self.assertRaises(alerts.AlertError):
            alerts.record_report(report_path, "host", state)
        report_path.write_text('{"not":"canonical"}', encoding="utf-8")
        with self.assertRaises(Exception):
            alerts.record_report(report_path, "host", state)

    def test_transition_recovery_is_idempotent(self):
        state, report_path = self._state_and_report(issues=[issue()])
        created, _ = alerts.record_report(report_path, "host", state)
        self.assertEqual(created, 1)
        paths = alerts._paths(state)
        event_path = next(paths["pending"].glob("*.json"))
        _, event = alerts._read_private_json(event_path)
        _, active = alerts._read_private_json(paths["active"])
        transition = {
            "format": "uten-imp-monitor-alert-transition-v1",
            "source": "host",
            "reportSha256": event["reportSha256"],
            "events": [event],
            "activeState": active,
        }
        paths["transition"].write_bytes(canonical(transition))
        os.chmod(paths["transition"], 0o600)
        created, pending = alerts.record_report(report_path, "host", state)
        self.assertEqual((created, pending), (0, 1))
        self.assertFalse(paths["transition"].exists())

    def test_pending_quota_does_not_publish_active_state(self):
        state, report_path = self._state_and_report(issues=[issue()])
        paths = alerts._prepare_state(state)
        with mock.patch.object(alerts, "MAX_PENDING_EVENTS", 0):
            with self.assertRaises(alerts.AlertError):
                alerts.record_report(report_path, "host", state)
        self.assertFalse(paths["active"].exists())
        self.assertFalse(paths["transition"].exists())

    def test_sender_zero_without_receipt_stays_pending(self):
        state, report_path = self._state_and_report(issues=[issue()])
        alerts.record_report(report_path, "host", state)
        sender = pathlib.Path(state.parent) / "sender"
        sender.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        os.chmod(sender, 0o700)
        delivered, pending = alerts.drain(state, sender)
        self.assertEqual((delivered, pending), (0, 1))

    def test_unit_failure_deduplicates_pending_but_not_delivered_history(self):
        state, _ = self._state_and_report()
        now = datetime(2026, 8, 12, tzinfo=timezone.utc)
        self.assertEqual(
            alerts.emit_unit_failure("uten-imp-host-monitor.service", state, now=now),
            1,
        )
        self.assertEqual(
            alerts.emit_unit_failure("uten-imp-host-monitor.service", state, now=now),
            0,
        )
        paths = alerts._paths(state)
        pending = next(paths["pending"].glob("*.json"))
        delivered = paths["delivered"] / pending.name
        os.replace(pending, delivered)
        self.assertEqual(
            alerts.emit_unit_failure("uten-imp-host-monitor.service", state, now=now),
            1,
        )

    @unittest.skipUnless(os.name == "posix", "receipt sender fixture uses POSIX shell")
    def test_valid_receipt_delivers(self):
        state, report_path = self._state_and_report(issues=[issue()])
        alerts.record_report(report_path, "host", state)
        sender = pathlib.Path(state.parent) / "sender"
        sender.write_text(
            "#!/bin/sh\n"
            "event= receipt=\n"
            "while [ $# -gt 0 ]; do case \"$1\" in --event-file) event=$2;; --receipt-file) receipt=$2;; esac; shift 2; done\n"
            "id=$(sed -n 's/.*\"eventId\":\"\\([^\"]*\\)\".*/\\1/p' \"$event\")\n"
            "printf '{\"accepted\":true,\"deliveredAtUtc\":\"%s\",\"eventId\":\"%s\",\"providerMessageId\":\"provider-1\",\"schemaVersion\":1}\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"$id\" > \"$receipt\"\n"
            "chmod 600 \"$receipt\"\n",
            encoding="utf-8",
        )
        os.chmod(sender, 0o700)
        with mock.patch.object(alerts, "_production", return_value=False):
            delivered, pending = alerts.drain(state, sender)
        self.assertEqual((delivered, pending), (1, 0))
        self.assertEqual(len(list((state / "alerts" / "delivered").glob("*.json"))), 1)


class PolicyTests(unittest.TestCase):
    def test_host_example_is_canonical_and_valid(self):
        path = ROOT / "host-policy.example.json"
        raw = path.read_bytes()
        value = common.strict_json(raw, canonical=True)
        host.validate_policy(value)
        self.assertEqual(value["postgres"]["socketDirectory"], "/var/run/postgresql")
        names = {item["name"] for item in value["units"]}
        self.assertIn("postgresql.service", names)
        self.assertIn("postgresql@16-main.service", names)

    def test_nvme_host_example_is_canonical_and_valid(self):
        path = ROOT / "host-policy.nvme.example.json"
        raw = path.read_bytes()
        value = common.strict_json(raw, canonical=True)
        host.validate_policy(value)
        self.assertEqual(value["hardware"]["mode"], "local-lvm-nvme")
        self.assertEqual(
            value["filesystems"][0]["expectedSource"],
            "/dev/mapper/ubuntu--vg-uten--data",
        )

    def test_hardware_example_is_canonical_and_valid(self):
        path = ROOT / "storage-hardware-authority.example.json"
        raw = path.read_bytes()
        value = common.strict_json(raw, canonical=True)
        host.validate_hardware_authority(value)

    def test_nvme_hardware_example_is_canonical_and_valid(self):
        path = ROOT / "storage-hardware-authority.nvme.example.json"
        raw = path.read_bytes()
        value = common.strict_json(raw, canonical=True)
        validated = host.validate_hardware_authority(value)
        self.assertEqual(
            validated["format"], "uten-imp-monitor-storage-hardware-authority-v2"
        )
        self.assertNotIn("raid", validated)

    def test_external_example_is_canonical_and_valid(self):
        path = ROOT / "external-policy.example.json"
        raw = path.read_bytes()
        value = common.strict_json(raw, canonical=True)
        external.validate_policy(value)

    def test_external_policy_rejects_secret_query_redirect_shape(self):
        value = json.loads((ROOT / "external-policy.example.json").read_text(encoding="utf-8"))
        value["checks"][0]["url"] += "?token=bad"
        with self.assertRaises(external.ExternalProbeError):
            external.validate_policy(value)

    def test_hardware_policy_cannot_contain_device_paths(self):
        value = json.loads((ROOT / "host-policy.example.json").read_text(encoding="utf-8"))
        value["hardware"]["smart"] = [{"device": "/dev/sda"}]
        with self.assertRaises(host.HostMonitorError):
            host.validate_policy(value)


class HostParsersTests(unittest.TestCase):
    def test_lvm_nvme_monitor_proves_single_nonrotating_parent(self):
        vg = "AAAAAA-bbbb-2222-3333-4444-5555-CCCCCC"
        lv = "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF"
        dm_uuid = "LVM-" + vg.replace("-", "") + lv.replace("-", "")
        policy = {
            "erpStorageAuthority": {
                "dataSource": "/dev/mapper/ubuntu--vg-uten--data",
                "dataUuid": "11111111-2222-3333-4444-555555555555",
                "lvm": {
                    "dmUuid": dm_uuid,
                    "lvSizeBytes": 350 * 1024**3,
                    "lvUuid": lv,
                    "vgUuid": vg,
                },
                "nvme": {
                    "namespaceById": "/dev/disk/by-id/nvme-UTEN_NVME",
                    "partitionById": "/dev/disk/by-id/nvme-UTEN_NVME-part3",
                    "partitionNumber": 3,
                },
                "schemaVersion": 3,
            }
        }
        data = SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(253, 1))
        partition = SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(259, 3))
        namespace = SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(259, 0))
        with tempfile.TemporaryDirectory() as temporary:
            sysfs = pathlib.Path(temporary)
            (sysfs / "253:1/dm").mkdir(parents=True)
            (sysfs / "253:1/slaves/nvme0n1p3").mkdir(parents=True)
            (sysfs / "259:3").mkdir(parents=True)
            (sysfs / "259:0/queue").mkdir(parents=True)
            (sysfs / "253:1/dm/uuid").write_text(dm_uuid + "\n", encoding="ascii")
            (sysfs / "253:1/size").write_text(str(350 * 1024**3 // 512), encoding="ascii")
            (sysfs / "259:3/partition").write_text("3\n", encoding="ascii")
            (sysfs / "259:0/queue/rotational").write_text("0\n", encoding="ascii")

            def block_rdev(path: pathlib.Path, _label: str):
                text = str(path)
                if text in {policy["erpStorageAuthority"]["dataSource"], "/dev/disk/by-uuid/11111111-2222-3333-4444-555555555555"}:
                    return data, "253:1"
                if text in {policy["erpStorageAuthority"]["nvme"]["partitionById"], "/dev/nvme0n1p3"}:
                    return partition, "259:3"
                if text == policy["erpStorageAuthority"]["nvme"]["namespaceById"]:
                    return namespace, "259:0"
                raise AssertionError(text)

            resolutions = {
                policy["erpStorageAuthority"]["dataSource"]: "/dev/dm-1",
                policy["erpStorageAuthority"]["nvme"]["partitionById"]: "/dev/nvme0n1p3",
                policy["erpStorageAuthority"]["nvme"]["namespaceById"]: "/dev/nvme0n1",
            }
            with mock.patch.object(host, "_block_rdev", side_effect=block_rdev), mock.patch.object(
                host.os.path, "realpath", side_effect=lambda value: resolutions.get(str(value), str(value))
            ):
                evidence, issues = host.inspect_lvm_nvme(policy, sys_dev_block=sysfs)
        self.assertEqual(issues, [])
        self.assertEqual(evidence["mode"], "local-lvm-nvme")
        self.assertEqual(evidence["partitionRdev"], "259:3")

    def test_journal_effective_config_is_last_assignment(self):
        values = host._effective_journal_config(
            "[Journal]\nStorage=volatile\n# x\n[Other]\nStorage=auto\n[Journal]\nStorage=persistent\nSystemMaxUse=2G\n"
        )
        self.assertEqual(values["Storage"], "persistent")
        self.assertEqual(host._parse_size(values["SystemMaxUse"]), 2 * 1024**3)
        self.assertEqual(host._parse_duration_seconds("30day"), 30 * 86400)

    def test_ntp_parser_handles_microseconds_and_seconds(self):
        text = "Offset: +123us\nRoot distance: 1.5s\n"
        self.assertAlmostEqual(host._parse_timesync_metric(text, "Offset"), 0.123)
        self.assertAlmostEqual(host._parse_timesync_metric(text, "Root distance"), 1500)

    def test_smart_health_faults_are_reported_without_starting_tests(self):
        policy = {
            "device": "/dev/disk/by-id/ata-X",
            "serialSha256": hashlib.sha256(b"SERIAL").hexdigest(),
            "maximumTemperatureC": 55,
            "maximumReallocatedSectors": 0,
            "maximumPendingSectors": 0,
            "maximumOfflineUncorrectable": 0,
            "maximumMediaErrors": 0,
            "maximumSelfTestAgeHours": 720,
        }
        value = {
            "smartctl": {"exit_status": 8},
            "serial_number": "SERIAL",
            "smart_status": {"passed": False},
            "temperature": {"current": 70},
            "ata_smart_attributes": {"table": [{"id": 5, "raw": {"value": 2}}]},
            "power_on_time": {"hours": 1000},
            "ata_smart_self_test_log": {"standard": {"table": []}},
        }

        def run(arguments, timeout, accepted):
            self.assertNotIn("--test", arguments)
            self.assertEqual(arguments[-1], policy["device"])
            return SimpleNamespace(stdout=json.dumps(value), stderr="", returncode=8)

        _, issues = host.inspect_smart_device(policy, run)
        codes = {item["code"] for item in issues}
        self.assertIn("smart.health", codes)
        self.assertIn("smart.temperature", codes)
        self.assertIn("smart.reallocated", codes)
        self.assertIn("smart.selftest-freshness", codes)

        def mismatched_run(arguments, timeout, accepted):
            self.assertNotIn("--test", arguments)
            return SimpleNamespace(stdout=json.dumps(value), stderr="", returncode=0)

        with self.assertRaisesRegex(host.HostMonitorError, "exit statuses differ"):
            host.inspect_smart_device(policy, mismatched_run)

    def test_unit_disabled_failed_stale_and_restart_storm(self):
        policy = {
            "name": "nginx.service",
            "expectedEnabled": ["enabled"],
            "expectedActive": ["active"],
            "requireSuccessfulResult": True,
            "maximumNRestarts": 2,
            "maximumLastSuccessAgeSeconds": 300,
            "maximumLastTriggerAgeSeconds": 300,
        }
        properties = {
            "LoadState": "loaded",
            "ActiveState": "failed",
            "SubState": "failed",
            "UnitFileState": "disabled",
            "Result": "exit-code",
            "ExecMainStatus": "1",
            "NRestarts": "9",
            "ExecMainExitTimestampMonotonic": "1",
            "LastTriggerUSecMonotonic": "1",
        }
        with mock.patch.object(host, "_systemctl_show", return_value=properties):
            _, issues = host.inspect_unit(policy, uptime_seconds=1000)
        codes = {item["code"] for item in issues}
        self.assertTrue(any(code.endswith("-enablement") for code in codes))
        self.assertTrue(any(code.endswith("-activity") for code in codes))
        self.assertTrue(any(code.endswith("-result") for code in codes))
        self.assertTrue(any(code.endswith("-restarts") for code in codes))
        self.assertTrue(any(code.endswith("-success-age") for code in codes))
        self.assertTrue(any(code.endswith("-trigger-age") for code in codes))


class ExternalProbeTests(unittest.TestCase):
    def test_collection_turns_tls_network_failure_into_durable_issue_shape(self):
        policy = json.loads((ROOT / "external-policy.example.json").read_text(encoding="utf-8"))
        raw = canonical(policy)

        def fail_probe(check, now):
            raise external.ExternalProbeError("simulated TLS failure")

        with mock.patch.object(external, "_boot_id", return_value="test-boot"):
            result = external.collect_report(
                raw,
                external.validate_policy(policy),
                now=datetime(2026, 8, 12, tzinfo=timezone.utc),
                probe=fail_probe,
            )
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(len(result["issues"]), 2)
        self.assertTrue(all(item["severity"] == "critical" for item in result["issues"]))
        self.assertFalse(result["containsSecrets"])


class SystemdContractTests(unittest.TestCase):
    def test_timers_are_templates_only_and_no_installer_enables_them(self):
        timer_names = {
            "uten-imp-host-monitor.timer",
            "uten-imp-external-monitor.timer",
            "uten-imp-monitor-alert-drain.timer",
        }
        repository = ROOT.parent
        for name in timer_names:
            self.assertTrue((repository / "systemd" / f"{name}.example").is_file())
        for path in repository.rglob("*.sh"):
            if path.is_symlink():
                continue
            text = path.read_text(encoding="utf-8")
            for name in timer_names:
                self.assertNotRegex(text, rf"systemctl\s+enable(?:\s+--now)?[^\n]*{re.escape(name)}")

    def test_observer_units_do_not_mutate_business_units(self):
        repository = ROOT.parent
        names = (
            "uten-imp-host-monitor.service.example",
            "uten-imp-external-monitor.service.example",
            "uten-imp-monitor-failure@.service.example",
            "uten-imp-monitor-alert-drain.service.example",
        )
        for name in names:
            text = (repository / "systemd" / name).read_text(encoding="utf-8")
            self.assertNotRegex(text, r"Exec(?:Start|Stop)=.*systemctl")
        host_unit = (repository / "systemd" / names[0]).read_text(encoding="utf-8")
        self.assertIn("PrivateNetwork=true", host_unit)
        self.assertIn("/proc/mdstat", host_unit)
        self.assertIn("/var/run/postgresql", host_unit)
        host_source = (ROOT / "host_monitor.py").read_text(encoding="utf-8")
        self.assertNotIn('"127.0.0.1"', host_source)
        external_unit = (repository / "systemd" / names[1]).read_text(encoding="utf-8")
        self.assertNotIn("/dev", external_unit)

    def test_sender_path_is_fixed_and_no_shell_execution(self):
        self.assertEqual(
            alerts.FIXED_SENDER,
            pathlib.Path("/usr/local/libexec/uten-imp-alerting/submit"),
        )
        text = (ROOT / "alert_spool.py").read_text(encoding="utf-8")
        self.assertNotIn("shell=True", text)
        self.assertNotIn("os.system", text)


if __name__ == "__main__":
    unittest.main()
