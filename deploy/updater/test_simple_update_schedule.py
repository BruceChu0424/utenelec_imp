"""Runtime schedule regression: no OSS call before due, durable single attempt."""

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo


SPEC = importlib.util.spec_from_file_location(
    "simple_update_schedule", Path(__file__).parents[1] / "simple" / "update_schedule.py")
schedule = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = schedule
SPEC.loader.exec_module(schedule)
SHANGHAI = ZoneInfo("Asia/Shanghai")


def instant(value):
    return dt.datetime.fromisoformat(value)


class UpdateScheduleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.status = self.root / "status.json"
        self.calls = self.root / "calls"
        self.updater = self.root / "updater"
        self.updater.write_text(
            f"#!/bin/sh\nprintf '%s\\n' \"$1\" >> '{self.calls}'\nexit 0\n")
        self.updater.chmod(0o700)
        self.patcher = patch.object(schedule, "UPDATER", str(self.updater))
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        self.config = {"intervalDays": "7", "updatedAt": "2026-09-26T10:00:00+08:00"}

    def tick(self, when, reader=None, zone=SHANGHAI):
        return schedule.tick(instant(when), zone, self.state, self.status,
                             os.getgid(), reader=reader or (lambda: self.config))

    def call_count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def test_default_weekly_before_due_contacts_no_updater(self):
        result = self.tick("2026-09-27T04:59:59+08:00")
        self.assertEqual(result["nextCheckAt"], "2026-09-27T05:00:00+08:00")
        self.assertEqual(result["appliedIntervalDays"], 7)
        self.assertEqual(self.call_count(), 0)

    def test_due_invokes_real_subprocess_once_across_repeated_ticks(self):
        result = self.tick("2026-09-27T05:00:00+08:00")
        self.assertEqual(result["lastResult"], "SUCCESS")
        self.assertEqual(self.calls.read_text(), "check\n")
        self.tick("2026-09-27T05:01:00+08:00")
        self.tick("2026-09-27T23:59:00+08:00")
        self.assertEqual(self.call_count(), 1)
        self.assertEqual(self.status.stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.state / "attempt.json").stat().st_mode & 0o777, 0o600)

    def test_next_sunday_executes_again(self):
        self.tick("2026-09-27T05:00:00+08:00")
        result = self.tick("2026-10-04T05:00:00+08:00")
        self.assertEqual(self.call_count(), 2)
        self.assertEqual(result["nextCheckAt"], "2026-10-11T05:00:00+08:00")

    def test_missed_yesterday_never_catches_up(self):
        result = self.tick("2026-09-28T07:00:00+08:00")
        self.assertEqual(self.call_count(), 0)
        self.assertEqual(result["nextCheckAt"], "2026-10-04T05:00:00+08:00")

    def test_disabled_has_no_next_time_and_no_network(self):
        self.config["intervalDays"] = "0"
        result = self.tick("2026-09-27T05:00:00+08:00")
        self.assertIsNone(result["nextCheckAt"])
        self.assertEqual(self.call_count(), 0)

    def test_weekly_setting_saved_at_sunday_five_starts_next_week(self):
        self.config["updatedAt"] = "2026-09-27T05:00:00+08:00"
        result = self.tick("2026-09-27T05:01:00+08:00")
        self.assertEqual(result["nextCheckAt"], "2026-10-04T05:00:00+08:00")
        self.assertEqual(self.call_count(), 0)

    def test_arbitrary_interval_crosses_month_and_uses_local_date(self):
        self.config = {"intervalDays": "3", "updatedAt": "2026-09-28T22:00:00Z"}
        result = self.tick("2026-10-01T05:00:00+08:00")
        self.assertEqual(result["nextCheckAt"], "2026-10-02T05:00:00+08:00")
        self.assertEqual(self.call_count(), 0)
        self.tick("2026-10-02T05:00:00+08:00")
        self.assertEqual(self.call_count(), 1)

    def test_leap_year_and_maximum_interval(self):
        self.config = {"intervalDays": "365", "updatedAt": "2024-02-29T20:00:00+08:00"}
        result = self.tick("2025-02-28T04:59:00+08:00")
        self.assertEqual(result["nextCheckAt"], "2025-02-28T05:00:00+08:00")
        self.tick("2025-02-28T05:00:00+08:00")
        self.assertEqual(self.call_count(), 1)

    def test_daily_schedule_keeps_five_oclock_across_dst(self):
        denver = ZoneInfo("America/Denver")
        self.config = {"intervalDays": "1", "updatedAt": "2026-10-31T10:00:00-06:00"}
        result = self.tick("2026-11-01T04:59:00-07:00", zone=denver)
        self.assertEqual(result["nextCheckAt"], "2026-11-01T05:00:00-07:00")
        self.tick("2026-11-01T05:00:00-07:00", zone=denver)
        self.assertEqual(self.call_count(), 1)

    def test_bad_or_missing_configuration_never_calls_updater(self):
        for raw in ({}, None, {"intervalDays": "366"}, {"intervalDays": "-1"},
                    {"intervalDays": "1; touch /tmp/no"}, {"intervalDays": 7},
                    {"intervalDays": "7", "updatedAt": "2026-09-26T10:00:00"},
                    {"intervalDays": "7", "updatedAt": None}):
            with self.subTest(raw=raw):
                result = self.tick("2026-09-27T05:00:00+08:00", reader=lambda: raw)
                self.assertIsNotNone(result["error"])
                self.assertIsNone(result["appliedIntervalDays"])
        self.assertEqual(self.call_count(), 0)

    def test_integer_strings_accepted_by_backend_are_normalized(self):
        for value, expected in (("007", 7), ("+7", 7), ("-0", 0)):
            with self.subTest(value=value):
                self.config["intervalDays"] = value
                result = self.tick("2026-09-27T04:59:00+08:00")
                self.assertEqual(result["appliedIntervalDays"], expected)
                self.assertIsNone(result["error"])
        self.assertEqual(self.call_count(), 0)

    def test_database_failure_is_redacted_and_never_calls_updater(self):
        def failure():
            raise subprocess.CalledProcessError(1, "sensitive connection details")
        result = self.tick("2026-09-27T05:00:00+08:00", reader=failure)
        self.assertNotIn("sensitive", json.dumps(result))
        self.assertIsNotNone(result["error"])
        self.assertEqual(self.call_count(), 0)

    def test_failed_check_is_not_retried_every_minute(self):
        self.updater.write_text(f"#!/bin/sh\necho check >> '{self.calls}'\nexit 2\n")
        result = self.tick("2026-09-27T05:00:00+08:00")
        self.assertEqual(result["lastResult"], "FAILED")
        self.tick("2026-09-27T05:01:00+08:00")
        self.assertEqual(self.call_count(), 1)

    def test_attempt_is_durable_before_check_and_abrupt_crash_does_not_retry(self):
        def crash():
            persisted = json.loads((self.state / "attempt.json").read_text())
            self.assertEqual(persisted["lastResult"], "RUNNING")
            raise RuntimeError("simulated process crash")
        with self.assertRaises(RuntimeError):
            schedule.tick(instant("2026-09-27T05:00:00+08:00"), SHANGHAI,
                          self.state, self.status, os.getgid(), reader=lambda: self.config, checker=crash)
        result = self.tick("2026-09-27T05:01:00+08:00")
        self.assertEqual(result["lastResult"], "FAILED")
        self.assertEqual(self.call_count(), 0)

    def test_corrupt_state_fails_closed(self):
        path = self.state / "attempt.json"
        path.write_text("not-json")
        path.chmod(0o600)
        result = self.tick("2026-09-27T05:00:00+08:00")
        self.assertIsNotNone(result["error"])
        self.assertEqual(self.call_count(), 0)

    def test_lock_prevents_overlapping_schedule_evaluations(self):
        with open(self.state / "schedule.lock", "w") as lock:
            schedule.fcntl.flock(lock, schedule.fcntl.LOCK_EX)
            self.assertEqual(self.tick("2026-09-27T05:00:00+08:00"), {"busy": True})
        self.assertEqual(self.call_count(), 0)

    def test_reader_uses_fixed_read_only_local_database_argv(self):
        with patch.object(schedule.subprocess, "run") as run:
            run.return_value.stdout = json.dumps(self.config)
            self.assertEqual(schedule.read_config(), self.config)
        args, kwargs = run.call_args
        self.assertNotIn("shell", kwargs)
        self.assertIn("/var/run/postgresql", args[0])
        self.assertIn("-X", args[0])
        self.assertIn("default_transaction_read_only=on", kwargs["env"]["PGOPTIONS"])
        self.assertNotIn("UPDATE ", schedule.CONFIG_SQL)


if __name__ == "__main__":
    unittest.main()
