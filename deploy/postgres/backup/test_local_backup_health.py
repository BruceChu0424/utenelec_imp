"""Local backup health evidence and read-only command boundaries; no live services."""
import copy
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import local_backup_health as local
from test_backup_controls import archiver, flyway_history, repo_info

NOW = int(datetime(2026, 10, 7, 18, tzinfo=timezone.utc).timestamp())


def inventory(repo):
    result = repo_info(repo, NOW)
    result[0]["backup"] = result[0]["backup"][-3:]
    return result


class LocalBackupHealthTest(unittest.TestCase):
    def evaluate(self, first=None, second=None, archive=None):
        return local.evaluate(first or inventory(1), second or inventory(2), archive or archiver(NOW), flyway_history())

    def test_three_completed_restore_points_per_local_repository_pass(self):
        report = self.evaluate()
        self.assertEqual("PASS", report["status"])
        self.assertEqual(3, report["minimumSuccessfulFullRestorePoints"])
        self.assertEqual([3, 3], [row["successfulFullRestorePoints"] for row in report["repositories"]])
        self.assertFalse(report["repositoryCheckPerformedByThisRun"])
        self.assertFalse(report["pitrRestoreDrillProvenByThisCheck"])

    def test_missing_failed_wrong_database_and_stale_points_fail_closed(self):
        cases = []
        missing = inventory(2)
        missing[0]["backup"].pop()
        cases.append(missing)
        failed = inventory(2)
        failed[0]["backup"][-1]["error"] = True
        cases.append(failed)
        wrong = inventory(2)
        wrong[0]["db"][0]["system-id"] = "7000000000000000000"
        cases.append(wrong)
        stale = inventory(2)
        for backup in stale[0]["backup"]:
            backup["timestamp"]["stop"] -= 31 * 3600
        cases.append(stale)
        for case in cases:
            with self.subTest(case=cases.index(case)), self.assertRaises(local.health.ContractError):
                self.evaluate(second=case)

    def test_wal_may_advance_during_sampling_but_neither_repository_may_lag_or_change_timeline(self):
        ahead = inventory(2)
        ahead[0]["archive"][0]["max"] = "0000000100000000000000AC"
        self.assertEqual("PASS", self.evaluate(second=ahead)["status"])
        for wal in ("0000000100000000000000A9", "0000000200000000000000AA"):
            invalid = copy.deepcopy(ahead)
            invalid[0]["archive"][0]["max"] = wal
            with self.assertRaises(local.health.ContractError):
                self.evaluate(second=invalid)

    def test_collect_runs_only_local_read_only_sql_and_info(self):
        with patch.object(local.health, "_run_json", side_effect=[archiver(NOW), inventory(1), inventory(2), flyway_history()]) as run:
            self.assertEqual("PASS", local.collect_live()["status"])
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(4, len(commands))
        for command in commands:
            if command[0] == "/usr/bin/psql":
                self.assertIn("/run/postgresql", command)
                self.assertTrue(command[-1].startswith("BEGIN READ ONLY;"))
                self.assertIn("statement_timeout='15s'", command[-1])
            else:
                self.assertEqual("/usr/bin/pgbackrest", command[0])
                self.assertEqual("info", command[-1])
                self.assertIn("--log-level-file=off", command)
                self.assertTrue(set(command).isdisjoint({"backup", "check", "expire", "restore", "archive-push"}))

    def test_failed_probe_publishes_a_failed_check_without_raw_errors_or_secrets(self):
        with patch.object(local, "collect_live", side_effect=local.health.LiveCheckError("private credential")), \
                patch.object(local.health, "_atomic_report") as publish:
            self.assertEqual(1, local.main([]))
        report = publish.call_args.args[1]
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("LOCAL_BACKUP_HEALTH_CHECK_FAILED", report["reasonCode"])
        self.assertNotIn("private", str(report))

    def test_report_reaches_the_existing_server_status_export_contract(self):
        path = Path(__file__).resolve().parents[2] / "monitoring" / "server_status_export.py"
        spec = importlib.util.spec_from_file_location("local_health_status_export", path)
        export = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(export)
        summary = export.summarize(self.evaluate())
        self.assertEqual("SUCCESS", summary["lastAttemptStatus"])
        self.assertNotIn("databaseIdentity", summary)
        self.assertEqual("uten-server-backup-status-v1", summary["format"])

    def test_isolated_python_launch_can_load_fixed_sibling_parsers(self):
        result = subprocess.run([sys.executable, "-I", "-B", str(Path(local.__file__).resolve()), "--help"],
                                capture_output=True, timeout=15, check=False)
        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", errors="replace"))


if __name__ == "__main__":
    unittest.main()
