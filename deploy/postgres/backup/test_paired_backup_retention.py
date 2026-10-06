"""Automatic paired-set retention against real temporary directories.

No database, company backup root or mocked file system: every test creates real
set directories, manifests, links and pointers under its own temporary root.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import paired_internal_backup as paired

NOW = datetime(2026, 10, 6, 19, 43, 45, tzinfo=timezone.utc)


def link_directory(target: Path, link: Path):
    try:
        os.symlink(target, link, target_is_directory=True)
    except OSError:
        if os.name != "nt":
            raise
        import _winapi
        _winapi.CreateJunction(str(target), str(link))


class RetentionFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uten-paired-retention-")
        base = Path(os.path.realpath(self.temp.name))
        self.root = base / "paired"
        self.root.mkdir(mode=0o700)
        self.outside = base / "outside"
        self.outside.mkdir()
        (self.outside / "keep.txt").write_bytes(b"outside the backup root")
        self.counter = 0
        self.sizes = {}

    def tearDown(self):
        self.temp.cleanup()

    def add_set(self, created: datetime, *, manifest=True, set_id=None, format="uten-paired-internal-v2",
                payload=b"database dump bytes", parent=None) -> str:
        self.counter += 1
        name = created.strftime("%Y%m%dT%H%M%SZ") + "-" + format_suffix(self.counter)
        directory = (parent or self.root) / name
        (directory / "media" / "final").mkdir(parents=True)
        (directory / "database.dump").write_bytes(payload)
        (directory / "media" / "final" / "object.bin").write_bytes(b"x" * self.counter)
        if manifest:
            (directory / "manifest.json").write_text(json.dumps({
                "format": format, "set_id": set_id or name,
                "completed_at": (created + timedelta(seconds=5)).isoformat()}), encoding="utf-8")
        self.sizes[name] = paired.tree_bytes(directory)
        return name

    def days_ago(self, days: float, **kwargs) -> str:
        return self.add_set(NOW - timedelta(days=days), **kwargs)

    def point_to(self, name: str):
        (self.root / "latest-success.json").write_text(
            json.dumps({"set_id": name, "completed_at": NOW.isoformat()}), encoding="utf-8")

    def prune(self, current: str, days=7, moment=NOW):
        stream = io.StringIO()
        with contextlib.redirect_stderr(stream):
            result = paired.prune_expired_sets(self.root, days, current, moment)
        return result, [json.loads(line) for line in stream.getvalue().splitlines()]

    def names(self) -> set:
        return {path.name for path in self.root.iterdir()}


def format_suffix(number: int) -> str:
    return format(number, "012x")


class PairedRetentionTest(RetentionFixture):
    def test_expired_sets_are_removed_and_the_last_seven_days_are_kept(self):
        recent = [self.days_ago(days) for days in range(7)]
        expired = [self.days_ago(days) for days in (7, 8, 30)]
        self.point_to(recent[0])
        result, events = self.prune(recent[0])
        self.assertEqual(set(recent) | {"latest-success.json"}, self.names())
        self.assertEqual(sorted(expired), sorted(item["name"] for item in result["removed"]))
        self.assertEqual(sum(self.sizes[name] for name in expired), result["freed_bytes"])
        self.assertEqual([], result["failed"])
        plan, done = events
        self.assertEqual(("paired_backup_retention_plan", "paired_backup_retention_done"), (plan["event"], done["event"]))
        self.assertEqual(sorted(expired), plan["expire"])
        self.assertEqual(7, done["remaining_sets"])
        self.assertEqual(result["freed_bytes"], done["freed_bytes"])
        self.assertEqual([], [path for path in self.root.iterdir() if path.name.startswith(".expired-")])

    def test_age_comes_from_the_set_name_by_calendar_day_not_mtime(self):
        current = self.days_ago(0)
        for days in range(1, 6):  # Enough recent sets that the count floor does not decide this case.
            self.days_ago(days)
        old_mtime_recent_name = self.days_ago(6)
        os.utime(self.root / old_mtime_recent_name, (0, 0))
        fresh_mtime_old_name = self.days_ago(8)
        # Fewer than 7x24h old, but dated on the 8th calendar day back: outside "the last 7 days".
        late_on_eighth_day = self.add_set(datetime(2026, 9, 29, 23, 59, 59, tzinfo=timezone.utc))
        first_of_seventh_day = self.add_set(datetime(2026, 9, 30, 0, 0, 0, tzinfo=timezone.utc))
        self.point_to(current)
        result, _ = self.prune(current)
        self.assertEqual({fresh_mtime_old_name, late_on_eighth_day}, {item["name"] for item in result["removed"]})
        self.assertTrue({current, old_mtime_recent_name, first_of_seventh_day} <= self.names())

    def test_success_pointer_set_is_kept_regardless_of_age(self):
        pointed = self.days_ago(30)
        other_old = self.days_ago(29)
        current = self.days_ago(0)
        for days in range(1, 7):
            self.days_ago(days)
        self.point_to(pointed)
        result, events = self.prune(current)
        self.assertIn(pointed, self.names())
        self.assertEqual([other_old], [item["name"] for item in result["removed"]])
        self.assertEqual(pointed, events[0]["pointer"])

    def test_newest_complete_set_is_kept_even_when_every_set_is_old(self):
        oldest = self.days_ago(30)
        current = self.days_ago(20)
        newest = self.days_ago(10)
        self.point_to(current)
        # One day keeps a count floor of one, so only the explicit newest/current/pointer rules protect.
        result, events = self.prune(current, days=1)
        self.assertEqual([oldest], [item["name"] for item in result["removed"]])
        self.assertTrue({current, newest} <= self.names())
        self.assertEqual(newest, events[0]["newest"])
        # A wrong future clock still cannot remove the only remaining protected sets.
        result, _ = self.prune(current, days=1, moment=NOW + timedelta(days=3650))
        self.assertEqual([], result["removed"])
        self.assertTrue({current, newest} <= self.names())

    def test_shipped_default_keeps_three_calendar_days_of_twice_daily_sets(self):
        # 2026-10-06 owner decision: 3 days for every backup; the timer runs at 03:40 and 13:10.
        days = paired.Config().retention_days
        self.assertEqual(3, days)
        moment = datetime(2026, 10, 6, 5, 10, 0, tzinfo=timezone.utc)  # 13:10 at UTC+8
        runs = [datetime(2026, 9, 28, 19, 40, tzinfo=timezone.utc) + timedelta(hours=offset)
                for day in range(9) for offset in (24 * day, 24 * day + 9.5)]
        sets = [self.add_set(created) for created in runs if created <= moment]
        current = sets[-1]
        self.point_to(current)
        result, _ = self.prune(current, days=days, moment=moment.astimezone(timezone(timedelta(hours=8))))
        kept = sorted(self.names() - {"latest-success.json"})
        # Local 10-04, 10-05 and 10-06: two sets each = 6; everything dated 10-03 or earlier is gone.
        self.assertEqual(6, len(kept))
        self.assertEqual(6, result["complete_sets"])
        self.assertEqual(sorted(sets[-6:]), kept)
        self.assertEqual(sorted(sets[:-6]), sorted(item["name"] for item in result["removed"]))

    def test_count_floor_survives_a_week_of_failures_before_the_next_success(self):
        # Daily sets 09-09..10-06, every run 10-07..10-13 failed, 10-14 is the first success again.
        daily = [self.add_set(datetime(2026, 9, 9, 19, 43, 45, tzinfo=timezone.utc) + timedelta(days=day))
                 for day in range(28)]
        failed = [".incomplete-" + (datetime(2026, 10, 7, 19, 43, 45, tzinfo=timezone.utc) + timedelta(days=day))
                  .strftime("%Y%m%dT%H%M%SZ") + "-" + format_suffix(900 + day) for day in range(7)]
        for name in failed:
            (self.root / name / "media").mkdir(parents=True)
        moment = datetime(2026, 10, 14, 19, 43, 45, tzinfo=timezone.utc)
        current = self.add_set(moment)
        self.point_to(current)
        result, events = self.prune(current, moment=moment)
        # The last clean sets before the failure window survive: 7 complete sets remain, not 1.
        # Failed-run evidence keeps the plain calendar window (10-07 is the 8th day back).
        kept = {current, *daily[-6:]}
        self.assertEqual(sorted(daily[:-6] + failed[:1]), sorted(item["name"] for item in result["removed"]))
        self.assertEqual(kept | set(failed[1:]) | {"latest-success.json"}, self.names())
        self.assertEqual(7, result["complete_sets"])
        self.assertEqual(sorted(daily[-6:]), events[0]["kept_by_count"])
        self.assertEqual(7, events[-1]["remaining_sets"])

    def test_forward_clock_jump_removes_one_set_not_the_whole_history(self):
        week = [self.days_ago(days) for days in range(7)]
        jumped = NOW + timedelta(days=30)
        current = self.add_set(jumped)
        self.point_to(current)
        result, _ = self.prune(current, moment=jumped)
        self.assertEqual([week[-1]], [item["name"] for item in result["removed"]])
        self.assertEqual({current, *week[:-1], "latest-success.json"}, self.names())
        self.assertEqual(7, result["complete_sets"])

    def test_nothing_is_removed_without_a_recognized_new_set_and_success_pointer(self):
        old = self.days_ago(30)
        stale = ".incomplete-" + (NOW - timedelta(days=30)).strftime("%Y%m%dT%H%M%SZ") + "-" + "e" * 12
        (self.root / stale).mkdir()
        current = self.days_ago(0)
        missing_manifest = self.days_ago(0, manifest=False)
        before = self.names()
        for case in ("no pointer", "corrupt pointer", "pointer to missing set", "pointer to invalid name",
                     "current without manifest", "current unknown"):
            with self.subTest(case=case):
                pointer = self.root / "latest-success.json"
                if case == "corrupt pointer":
                    pointer.write_text("{not json", encoding="utf-8")
                elif case == "pointer to missing set":
                    self.point_to((NOW.strftime("%Y%m%dT%H%M%SZ")) + "-" + "f" * 12)
                elif case == "pointer to invalid name":
                    self.point_to("../outside")
                elif case.startswith("current"):
                    self.point_to(current)
                target = missing_manifest if case == "current without manifest" else (
                    "20261006T000000Z-" + "d" * 12 if case == "current unknown" else current)
                result, events = self.prune(target)
                self.assertTrue(result["skipped"])
                self.assertEqual("paired_backup_retention_skipped", events[-1]["event"])
                self.assertEqual(before | ({"latest-success.json"} if pointer.exists() else set()), self.names())
                self.assertIn(old, self.names())
                self.assertIn(stale, self.names())

    def test_unrecognized_names_and_sets_without_a_valid_manifest_are_never_deleted(self):
        old = NOW - timedelta(days=40)
        stamp = old.strftime("%Y%m%dT%H%M%SZ")
        current = self.days_ago(0)
        self.point_to(current)
        protected = {
            stamp + "-abc", stamp + "-0123456789AB", "20261301T000000Z-0123456789ab", "20260230T000000Z-0123456789ab",
            "backup-old", stamp + "-0123456789ab.bak", ".incomplete-bad", ".incomplete-" + stamp + "-0123456789ab.x",
            ".expired-" + stamp + "-short", "x" + stamp + "-0123456789ab"}
        for name in protected:
            (self.root / name).mkdir()
            (self.root / name / "manifest.json").write_text("{}", encoding="utf-8")
        no_manifest = self.add_set(old, manifest=False)
        wrong_id = self.add_set(old, set_id="20200101T000000Z-" + "0" * 12)
        unknown_format = self.add_set(old, format="someone-elses-backup")
        broken_json = self.add_set(old)
        (self.root / broken_json / "manifest.json").write_text("{", encoding="utf-8")
        naive_time = self.add_set(old)
        (self.root / naive_time / "manifest.json").write_text(json.dumps(
            {"format": "uten-paired-internal-v1", "set_id": naive_time, "completed_at": "2026-08-27T19:43:50"}), encoding="utf-8")
        regular_file = stamp + "-" + "9" * 12
        (self.root / regular_file).write_bytes(b"not a directory")
        stale_file = ".incomplete-" + stamp + "-" + "8" * 12
        (self.root / stale_file).write_bytes(b"not a directory")
        before = self.names()
        result, events = self.prune(current)
        self.assertEqual([], result["removed"])
        self.assertEqual(before, self.names())
        unrecognized = set(events[0]["unrecognized"])
        self.assertTrue({no_manifest, wrong_id, unknown_format, broken_json, naive_time, regular_file, stale_file} <= unrecognized)

    def test_links_are_never_followed_or_deleted(self):
        old = NOW - timedelta(days=40)
        current = self.days_ago(0)
        self.point_to(current)
        outside_set = self.add_set(old, parent=self.outside)
        linked_set = old.strftime("%Y%m%dT%H%M%SZ") + "-" + "a" * 12
        link_directory(self.outside / outside_set, self.root / linked_set)
        linked_stale = ".incomplete-" + old.strftime("%Y%m%dT%H%M%SZ") + "-" + "b" * 12
        link_directory(self.outside, self.root / linked_stale)
        expired = self.add_set(old)
        link_directory(self.outside, self.root / expired / "media" / "escape")
        linked_manifest = self.add_set(old)
        (self.root / linked_manifest / "manifest.json").unlink()
        try:
            os.symlink(self.outside / outside_set / "manifest.json", self.root / linked_manifest / "manifest.json")
        except OSError:
            linked_manifest = None  # File symlinks need extra Windows privilege; directory junctions are still covered.
        result, events = self.prune(current, days=1)
        self.assertEqual([expired], [item["name"] for item in result["removed"]])
        self.assertEqual(self.sizes[expired], result["freed_bytes"])
        self.assertEqual(b"outside the backup root", (self.outside / "keep.txt").read_bytes())
        self.assertTrue((self.outside / outside_set / "manifest.json").is_file())
        self.assertTrue(os.path.lexists(self.root / linked_set))
        self.assertTrue(os.path.lexists(self.root / linked_stale))
        self.assertIn(linked_set, events[0]["unrecognized"])
        if linked_manifest:
            self.assertIn(linked_manifest, self.names())
            self.assertIn(linked_manifest, events[0]["unrecognized"])

    def test_paths_outside_the_backup_root_or_a_linked_root_are_refused(self):
        owner = os.lstat(self.root).st_uid
        victim = self.add_set(NOW - timedelta(days=40), parent=self.outside)
        for name in ("../outside", str(self.outside), "..", ".", "../outside/" + victim, victim):
            with self.subTest(name=name), self.assertRaises((ValueError, FileNotFoundError)):
                paired.remove_owned_directory(self.root, name, owner)
        self.assertTrue((self.outside / victim / "database.dump").is_file())
        linked_root = self.root.parent / "linked-root"
        link_directory(self.root, linked_root)
        current = self.days_ago(0)
        old = self.days_ago(30)
        self.point_to(current)
        with self.assertRaises(ValueError):
            paired.prune_expired_sets(linked_root, 7, current, NOW)
        self.assertIn(old, self.names())

    def test_stale_unpublished_work_is_removed_only_after_the_same_window(self):
        current = self.days_ago(0)
        self.point_to(current)
        def work(prefix, days, letter):
            name = prefix + (NOW - timedelta(days=days)).strftime("%Y%m%dT%H%M%SZ") + "-" + letter * 12
            (self.root / name / "media").mkdir(parents=True)
            (self.root / name / "media" / "partial").write_bytes(b"p" * 10)
            return name
        old_failed = work(".incomplete-", 8, "1")
        recent_failed = work(".incomplete-", 1, "2")
        interrupted_delete = work(".expired-", 1, "3")
        for name in ("last-attempt.json", ".backup.lock", ".latest-0123", ".attempt-0123"):
            (self.root / name).write_bytes(b"{}")
        result, events = self.prune(current)
        self.assertEqual({old_failed, interrupted_delete}, {item["name"] for item in result["removed"]})
        self.assertEqual(20, result["freed_bytes"])
        self.assertEqual(sorted([old_failed, interrupted_delete]), sorted(events[0]["stale_unpublished"]))
        self.assertTrue({recent_failed, "last-attempt.json", ".backup.lock", ".latest-0123", ".attempt-0123"} <= self.names())

    def test_retention_days_must_be_an_integer_from_1_to_365(self):
        self.assertEqual(3, paired.Config().retention_days)
        for value in (1, 7, 365):
            self.assertEqual(value, paired.check_retention_days(value))
        current = self.days_ago(0)
        old = self.days_ago(400)
        self.point_to(current)
        for value in (0, -1, 366, "7", 7.0, True, None):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "retention_days"):
                    paired.check_retention_days(value)
                with self.assertRaisesRegex(ValueError, "retention_days"):
                    paired.prune_expired_sets(self.root, value, current, NOW)
                with patch.object(paired.os, "geteuid", create=True, return_value=0), \
                        self.assertRaisesRegex(ValueError, "retention_days"):
                    paired.validate_config(paired.Config(retention_days=value))
        self.assertIn(old, self.names())
        # 365 is accepted; with only two sets its count floor of 365 still keeps both.
        result, _ = self.prune(current, days=365)
        self.assertEqual([], result["removed"])
        result, _ = self.prune(current, days=1)
        self.assertEqual([old], [item["name"] for item in result["removed"]])

    def test_one_failed_delete_is_logged_and_the_rest_continue(self):
        current = self.days_ago(0)
        blocked = self.days_ago(20)
        removable = self.days_ago(21)
        self.point_to(current)
        real_rmtree = shutil.rmtree
        def failing_rmtree(path, *args, **kwargs):
            if Path(path).name.endswith(blocked.split("-")[1]):
                raise PermissionError("simulated busy directory")
            return real_rmtree(path, *args, **kwargs)
        with patch.object(paired.shutil, "rmtree", side_effect=failing_rmtree):
            result, events = self.prune(current, days=1)
        self.assertEqual([removable], [item["name"] for item in result["removed"]])
        self.assertEqual([{"name": blocked, "error": "PermissionError"}], result["failed"])
        self.assertEqual(result["failed"], events[-1]["failed"])
        # The partially handled set is no longer in the published namespace and is finished next time.
        leftover = ".expired-" + blocked
        self.assertIn(leftover, self.names())
        self.assertNotIn(blocked, self.names())
        result, _ = self.prune(current, days=1)
        self.assertEqual([leftover], [item["name"] for item in result["removed"]])

    def test_retention_problem_never_escapes_the_success_path(self):
        published = self.root / self.days_ago(0)
        stream = io.StringIO()
        with patch.object(paired, "prune_expired_sets", side_effect=RuntimeError("simulated")), \
                contextlib.redirect_stderr(stream):
            state = paired.retain_after_success(self.root, paired.Config(), published)
        event = json.loads(stream.getvalue())
        self.assertEqual(("paired_backup_retention_failed", "RuntimeError"), (event["event"], event["error"]))
        self.assertEqual({"status": "FAILED", "retentionDays": 3}, state)
        with patch.object(paired, "prune_expired_sets", side_effect=InterruptedError("signal")), \
                contextlib.redirect_stderr(io.StringIO()):
            state = paired.retain_after_success(self.root, paired.Config(), published)
        self.assertEqual("FAILED", state["status"])

    def test_monitoring_state_is_counts_only_and_flags_every_non_clean_outcome(self):
        current = self.days_ago(0)
        expired = self.days_ago(20)
        stale = ".incomplete-" + (NOW - timedelta(days=20)).strftime("%Y%m%dT%H%M%SZ") + "-" + "c" * 12
        (self.root / stale).mkdir()
        (self.root / (NOW.strftime("%Y%m%dT%H%M%SZ") + "-" + "d" * 12)).mkdir()  # Set-like, no manifest.
        self.point_to(current)
        config = paired.Config(retention_days=1)
        def retain():
            with patch.object(paired, "datetime", wraps=datetime) as clock, contextlib.redirect_stderr(io.StringIO()):
                clock.now.return_value = NOW
                return paired.retain_after_success(self.root, config, self.root / current)
        state = retain()
        self.assertEqual({"status": "APPLIED", "retentionDays": 1, "completeSets": 1, "removedSets": 1,
                          "removedUnpublished": 1, "failedDeletes": 0, "unrecognizedEntries": 1,
                          "freedBytes": self.sizes[expired]}, state)
        self.assertNotIn(current, json.dumps(state))
        older = self.days_ago(30)
        with patch.object(paired.shutil, "rmtree", side_effect=PermissionError("busy")):
            state = retain()
        # The failed set already left the published namespace, so it no longer counts as complete.
        self.assertEqual(("FAILED", 1, 1), (state["status"], state["failedDeletes"], state["completeSets"]))
        (self.root / "latest-success.json").unlink()
        state = retain()
        self.assertEqual(("SKIPPED", 1), (state["status"], state["completeSets"]))
        self.assertIn(".expired-" + older, self.names())


@unittest.skipUnless(os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0, "root-owned backup root")
class PairedRetentionAfterBackupTest(RetentionFixture):
    """The real backup() entry point, with only the database snapshot step replaced by a real set writer."""

    def publish(self, config):
        name = self.days_ago(0)
        self.point_to(name)
        return self.root / name

    def run_backup(self):
        # One day keeps a one-set count floor, so the 10-day-old set is beyond both limits.
        config = paired.Config(backup_root=str(self.root), retention_days=1)
        stream = io.StringIO()
        with patch.object(paired, "validate_config"), patch.object(paired, "_backup_locked", side_effect=self.publish), \
                contextlib.redirect_stderr(stream):
            published = paired.backup(config)
        return published, [json.loads(line) for line in stream.getvalue().splitlines() if line.startswith("{")]

    def attempt(self):
        return json.loads((self.root / "last-attempt.json").read_text())

    def test_successful_run_removes_expired_sets_and_records_success(self):
        old = self.days_ago(10)
        published, events = self.run_backup()
        self.assertTrue(published.is_dir())
        self.assertNotIn(old, self.names())
        attempt = self.attempt()
        self.assertEqual("SUCCESS", attempt["status"])
        self.assertEqual({"status": "APPLIED", "retentionDays": 1, "completeSets": 1, "removedSets": 1,
                          "removedUnpublished": 0, "failedDeletes": 0, "unrecognizedEntries": 0,
                          "freedBytes": self.sizes[old]}, attempt["retention"])
        self.assertEqual("paired_backup_retention_done", events[-1]["event"])

    def test_cleanup_exception_does_not_change_the_successful_result(self):
        old = self.days_ago(10)
        with patch.object(paired, "prune_expired_sets", side_effect=OSError("simulated cleanup failure")):
            published, events = self.run_backup()
        self.assertTrue(published.is_dir())
        self.assertIn(old, self.names())
        attempt = self.attempt()
        self.assertEqual("SUCCESS", attempt["status"])
        self.assertEqual({"status": "FAILED", "retentionDays": 1}, attempt["retention"])
        self.assertEqual("paired_backup_retention_failed", events[-1]["event"])
        self.assertEqual(0o600, stat.S_IMODE((self.root / "last-attempt.json").stat().st_mode))

    def test_unwritable_cleanup_state_leaves_pending_for_monitoring(self):
        self.days_ago(10)
        real_record = paired.record_attempt
        def record(root, status, started, completed, retention=None):
            if retention is not None and retention["status"] != "PENDING":
                raise OSError("simulated full disk")
            return real_record(root, status, started, completed, retention)
        with patch.object(paired, "record_attempt", side_effect=record):
            published, events = self.run_backup()
        self.assertTrue(published.is_dir())
        self.assertEqual(("SUCCESS", {"status": "PENDING", "retentionDays": 1}),
                         (self.attempt()["status"], self.attempt()["retention"]))
        self.assertEqual("paired_backup_retention_state_unwritten", events[-1]["event"])

    def test_failed_backup_never_runs_retention(self):
        old = self.days_ago(10)
        config = paired.Config(backup_root=str(self.root))
        with patch.object(paired, "validate_config"), \
                patch.object(paired, "_backup_locked", side_effect=RuntimeError("simulated dump failure")), \
                patch.object(paired, "prune_expired_sets") as prune, self.assertRaises(RuntimeError):
            paired.backup(config)
        prune.assert_not_called()
        self.assertIn(old, self.names())
        self.assertEqual("FAILED", self.attempt()["status"])
        self.assertNotIn("retention", self.attempt())


if __name__ == "__main__":
    unittest.main()
