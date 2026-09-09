import json
import os
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timezone
from unittest.mock import patch

from server_status_export import main, publish, read_report, summarize, summarize_pair


class ServerStatusExportTest(unittest.TestCase):
    def paired(self, status="SUCCESS"):
        return {"format": "uten-paired-backup-attempt-v1", "status": status,
                "startedAt": "2026-09-08T03:40:00Z", "completedAt": "2026-09-08T03:45:00Z",
                "lastSuccessAt": "2026-09-08T03:44:59Z"}

    def observed(self):
        return datetime(2026, 9, 8, 16, 1, tzinfo=timezone.utc)

    def report(self):
        return {"schemaVersion": 1, "status": "PASS", "checkedAtUtc": "2026-09-08T16:00:00Z",
                "stanza": "private-database-name", "databaseIdentity": {"secret": "not-for-the-page"},
                "repositories": [{"repo": 1, "latestSuccessfulFullStopEpoch": 1788881400},
                                 {"repo": 2, "latestSuccessfulFullStopEpoch": 1788885000}]}

    def test_only_local_completion_and_check_time_are_exposed(self):
        result = summarize(self.report())
        self.assertEqual(result["lastAttemptStatus"], "SUCCESS")
        self.assertEqual(result["sampledAt"], "2026-09-08T16:00:00+00:00")
        self.assertNotIn("private", json.dumps(result))
        self.assertNotIn("databaseIdentity", result)
        self.assertEqual(len(result), 4)

    def test_reexport_does_not_refresh_source_age(self):
        first = summarize(self.report())
        self.assertEqual(summarize(self.report(), first), first)

    def test_failed_health_check_does_not_claim_the_last_backup_failed(self):
        previous = summarize(self.report())
        failed = {"schemaVersion": 1, "status": "FAIL", "checkedAtUtc": "2026-09-08T16:01:00Z",
                  "failure": "credentials or private storage details"}
        result = summarize(failed, previous)
        self.assertEqual(result["lastAttemptStatus"], "CHECK_FAILED")
        self.assertEqual(result["lastSuccessAt"], previous["lastSuccessAt"])
        self.assertNotIn("failure", result)

    def test_ambiguous_or_impossible_backup_identity_is_rejected(self):
        report = self.report()
        report["repositories"].append(report["repositories"][0])
        with self.assertRaises(ValueError):
            summarize(report)
        report = self.report()
        report["repositories"][0]["latestSuccessfulFullStopEpoch"] = 9999999999
        with self.assertRaises(ValueError):
            summarize(report)

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "POSIX file protection verified on Linux")
    def test_bounded_atomic_publish_and_symlink_read_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "backup.json"
            summary = summarize(self.report())
            publish(output, summary)
            self.assertEqual(read_report(output), summary)
            self.assertEqual(output.stat().st_mode & 0o777, 0o640)
            self.assertEqual(list(root.iterdir()), [output])
            link = root / "link.json"
            link.symlink_to(output)
            with self.assertRaises(OSError):
                read_report(link)
            output.write_bytes(b"x" * 65537)
            with self.assertRaises(ValueError):
                read_report(output)

    def test_success_requires_both_sources_and_uses_the_older_success(self):
        result = summarize_pair(summarize(self.report()), self.paired(), self.observed())
        self.assertEqual(result["lastAttemptStatus"], "SUCCESS")
        self.assertEqual(result["sampledAt"], self.observed().isoformat())
        self.assertEqual(result["lastSuccessAt"], "2026-09-08T03:44:59+00:00")
        self.assertEqual(result["reason"], "PG_AND_PAIRED_VERIFIED")

    def test_daily_paired_task_is_not_subject_to_fifteen_minute_feed_expiry(self):
        result = summarize_pair(summarize(self.report()), self.paired(), self.observed())
        self.assertEqual(result["lastAttemptStatus"], "SUCCESS")
        self.assertGreater((self.observed() - datetime.fromisoformat(result["lastSuccessAt"])).total_seconds(), 900)

    def test_reexport_cannot_hide_stale_pg_health(self):
        observed = datetime(2026, 9, 8, 17, tzinfo=timezone.utc)
        result = summarize_pair(summarize(self.report()), self.paired(), observed)
        self.assertEqual(result["sampledAt"], observed.isoformat())
        self.assertEqual(result["lastAttemptStatus"], "UNKNOWN")
        self.assertEqual(result["reason"], "PG_HEALTH_STALE_OR_UNAVAILABLE")

    def test_paired_failure_retains_older_success_but_never_stays_green(self):
        paired = self.paired("FAILED")
        paired.update(startedAt="2026-09-08T15:50:00Z", completedAt="2026-09-08T15:51:00Z")
        result = summarize_pair(summarize(self.report()), paired, self.observed())
        self.assertEqual(result["lastAttemptStatus"], "FAILED")
        self.assertEqual(result["lastSuccessAt"], "2026-09-08T03:44:59+00:00")
        self.assertEqual(summarize_pair(None, paired, self.observed())["lastAttemptStatus"], "FAILED")

    def test_missing_unconfigured_invalid_and_running_paired_state_are_unknown(self):
        for state in (None, {}, {"format": "old"}, {**self.paired(), "completedAt": 123},
                      {**self.paired(), "status": "RUNNING", "completedAt": None,
                       "startedAt": "2026-09-08T16:00:00Z"}):
            with self.subTest(state=state):
                result = summarize_pair(summarize(self.report()), state, self.observed())
                self.assertEqual(result["lastAttemptStatus"], "UNKNOWN")

    def test_pg_health_failure_is_not_labeled_as_a_failed_backup_task(self):
        previous = summarize(self.report())
        failed = summarize({"schemaVersion": 1, "status": "FAIL", "checkedAtUtc": "2026-09-08T16:00:00Z"}, previous)
        result = summarize_pair(failed, self.paired(), self.observed())
        self.assertEqual(result["lastAttemptStatus"], "CHECK_FAILED")

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "POSIX export integration")
    def test_cli_bad_or_missing_state_publishes_unknown_without_exposing_private_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, paired, output = root / "pg.json", root / "paired.json", root / "feed.json"
            report = self.report()
            observed = datetime.now(timezone.utc)
            report["checkedAtUtc"] = observed.isoformat()
            report["repositories"][0]["latestSuccessfulFullStopEpoch"] = int(observed.timestamp()) - 60
            source.write_text(json.dumps(report))
            for content in (None, "{bad", json.dumps({**self.paired(), "database": "secret-business-db", "status": []})):
                if content is not None:
                    paired.write_text(content)
                with patch("sys.argv", ["export", "--source", str(source), "--paired-source", str(paired), "--output", str(output)]):
                    main()
                result = read_report(output)
                self.assertEqual(result["lastAttemptStatus"], "UNKNOWN")
                self.assertIn(result["reason"], {"PAIRED_NOT_CONFIGURED_OR_UNAVAILABLE", "PAIRED_STATUS_INVALID"})
                self.assertNotIn("secret-business-db", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
