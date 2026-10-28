"""Actual local persistence, restart deduplication, retention and unsafe-path rejection."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "simple/host/uten-host-alert.py"
spec = importlib.util.spec_from_file_location("host_alert_recorder", SOURCE)
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)


class HostAlertCategoryTest(unittest.TestCase):
    def test_hook_details_and_paths_never_enter_recorded_message(self):
        key, severity, title = recorder.category("disk-/private/customer-secret")
        self.assertEqual("CRITICAL", severity)
        self.assertNotIn("private", key + title)
        self.assertNotIn("secret", key + title)
        self.assertEqual(recorder.category("uten-imp"), recorder.category("uten-imp.service"))
        self.assertIn("数据盘", recorder.category("disk-/data")[2])
        self.assertIn("病毒扫描服务", recorder.category("down-clamav-daemon")[2])

    def test_disk_reason_is_specific_and_preserves_existing_volume_throttle(self):
        original_key = recorder.category("disk-/srv/uten-backup")[0]
        for reason, expected in {
            "low-free": "本机备份盘可用空间低于20GiB",
            "unmounted": "本机备份盘未挂载",
            "full": "本机备份盘使用率达到九成",
            "inodes": "本机备份盘文件数量接近上限",
            "probe-failed": "本机备份盘容量检查失败",
        }.items():
            with self.subTest(reason=reason):
                self.assertEqual((original_key, "CRITICAL", expected),
                                 recorder.category("disk-/srv/uten-backup:" + reason))
        self.assertEqual(recorder.category("disk-/srv/uten-backup"),
                         recorder.category("disk-/srv/uten-backup:private-secret"))


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Disk check requires Bash")
class HostDiskCheckTest(unittest.TestCase):
    def test_real_disk_branch_identifies_causes_without_changing_thresholds(self):
        source = SOURCE.with_name("uten-host-check.sh").read_text()
        # Execute the shipped disk loop against command fixtures. No real mounts,
        # host alert writes, service checks, or database commands are involved.
        disk_loop = "for item in " + source.split("for item in ", 1)[1].split("# 2.", 1)[0]
        fixture = """
set -uo pipefail
fixture_alert() { printf '%s\\n' "$1"; }
mountpoint() { return "$fixture_mount_status"; }
df() { printf '%s\\n' "$fixture_df_data"; }
alert=fixture_alert
"""
        mounts = ("/", "/data", "/var/lib/uten-imp-media", "/srv/uten-backup")
        cases = (
            ("mounted-low-free", 0, "72% 16895066112 1%", "disk-", ":low-free"),
            ("unmounted", 1, "72% 16895066112 1%", "disk-", ":unmounted"),
            ("full", 0, "90% 30000000000 1%", "disk-", ":full"),
            ("inodes", 0, "70% 30000000000 90%", "disk-", ":inodes"),
            ("warning", 0, "80% 30000000000 1%", "diskwarn-", ""),
            ("exact-free-boundary", 0, "79% 21474836480 89%", None, ""),
            ("failed-probe", 0, "unavailable", "disk-", ":probe-failed"),
        )
        for name, mount_status, row, prefix, suffix in cases:
            with self.subTest(name=name):
                env = {**os.environ, "fixture_mount_status": str(mount_status),
                       "fixture_df_data": "Use% Avail IUse%\n" + row}
                run = subprocess.run(["bash", "-c", fixture + disk_loop], env=env,
                                     text=True, capture_output=True, timeout=5)
                self.assertEqual(0, run.returncode, run.stderr)
                self.assertEqual([] if prefix is None else [prefix + path + suffix for path in mounts],
                                 run.stdout.splitlines())


@unittest.skipUnless(os.name == "posix", "Local recorder requires POSIX flock and no-follow opens")
class HostAlertPersistenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name) / "events"

    def tearDown(self):
        self.temp.cleanup()

    def read(self):
        return json.loads((self.directory / "events.json").read_text())["events"]

    def test_restart_deduplication_and_next_episode(self):
        self.assertTrue(recorder.record(self.directory, "uten-imp", 1000000))
        first = self.read()[0]
        self.assertFalse(recorder.record(self.directory, "uten-imp", 1000001))
        self.assertEqual(first, self.read()[0])
        self.assertTrue(recorder.record(self.directory, "uten-imp", 1021600))
        self.assertEqual(2, len(self.read()))
        self.assertNotEqual(first["id"], self.read()[1]["id"])

    def test_escalation_is_not_hidden_by_warning_throttle(self):
        recorder.record(self.directory, "diskwarn-/data", 1000000)
        recorder.record(self.directory, "disk-/data", 1000001)
        self.assertEqual(["WARNING", "CRITICAL"], [row["severity"] for row in self.read()])

    def test_unrecognized_units_do_not_suppress_each_other(self):
        self.assertTrue(recorder.record(self.directory, "new-unit-a.service", 1000000))
        self.assertTrue(recorder.record(self.directory, "new-unit-b.service", 1000001))
        self.assertFalse(recorder.record(self.directory, "new-unit-a.service", 1000002))
        self.assertEqual(2, len(self.read()))
        self.assertEqual("CRITICAL", recorder.category("uten-pgbackup-health.service")[1])
        self.assertIn("恢复点", recorder.category("uten-pgbackup-health.service")[2])

    def test_expired_events_prune_only_when_new_event_is_safely_written(self):
        recorder.record(self.directory, "uten-imp", 1000000)
        recorder.record(self.directory, "wal-archive", 1000000 + recorder.RETENTION + 1)
        self.assertEqual(["wal-archive"], [row["key"] for row in self.read()])

    def test_corruption_does_not_overwrite_existing_evidence(self):
        recorder.record(self.directory, "uten-imp", 1000000)
        path = self.directory / "events.json"
        path.write_text("{bad")
        with self.assertRaises(ValueError):
            recorder.record(self.directory, "wal-archive", 1000001)
        self.assertEqual("{bad", path.read_text())

    def test_symlink_and_hardlink_state_are_rejected(self):
        self.directory.mkdir(mode=0o750)
        target = Path(self.temp.name) / "outside"
        target.write_text("unchanged")
        path = self.directory / "events.json"
        path.symlink_to(target)
        with self.assertRaises(OSError):
            recorder.record(self.directory, "uten-imp", 1000000)
        path.unlink()
        os.link(target, path)
        with self.assertRaises(ValueError):
            recorder.record(self.directory, "uten-imp", 1000000)
        self.assertEqual("unchanged", target.read_text())

    def test_full_queue_rejects_new_event_without_losing_old_events(self):
        recorder.record(self.directory, "uten-imp", 1000000)
        state = json.loads((self.directory / "events.json").read_text())
        state["events"] = [{**state["events"][0], "key": str(i)} for i in range(recorder.MAX_EVENTS)]
        path = self.directory / "events.json"
        path.write_text(json.dumps(state))
        before = path.read_bytes()
        with self.assertRaises(ValueError):
            recorder.record(self.directory, "wal-archive", 1000001)
        self.assertEqual(before, path.read_bytes())


if __name__ == "__main__":
    unittest.main()
