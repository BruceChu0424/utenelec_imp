"""Run the real backup helper with a fixture dump producer, never a live database."""
from datetime import datetime, timedelta
from pathlib import Path
import os
import re
import stat
import subprocess
import tempfile
import unittest

from test_simple_release_retention import SCRIPT, bash_path


def shell_function(name):
    return re.search(r"(?ms)^" + name + r"\(\) \{.*?^\}", SCRIPT.read_text(encoding="utf-8")).group(0)


def backup_helper():
    return shell_function("create_database_backup")


@unittest.skipIf(os.name == "nt", "Backup DAC permissions require native Linux; NTFS/MSYS cannot apply them")
class SimpleReleaseBackupTest(unittest.TestCase):
    def run_backup(self, directory, producer="printf fixture-database", command=None):
        env = dict(os.environ, UTEN_BACKUP_DIR=directory.as_posix(), UTEN_PG_DATABASE="uten_fixture")
        script = ("set -euo pipefail\numask 022\nlog() { :; }\n"
                  "date() { printf 20260912-000000; }\n"
                  "runuser() { " + producer + "; }\n" + backup_helper() + "\n" +
                  (command or 'create_database_backup v1.33.3'))
        return subprocess.run([bash_path(), "-c", script], env=env,
                              capture_output=True, text=True, encoding="utf-8", check=False)

    def test_backup_is_private_even_under_permissive_service_umask(self):
        with tempfile.TemporaryDirectory(prefix="uten-private-backup-") as temp:
            directory = Path(temp) / "backups"
            directory.mkdir(mode=0o755)
            result = self.run_backup(directory, command=(
                'create_database_backup v1.33.3\n'
                'test "$(umask)" = 0022'))
            self.assertEqual(result.returncode, 0, result.stderr)
            dump = next(directory.glob("*.dump"))
            self.assertEqual(dump.read_text(), "fixture-database")
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(dump.stat().st_mode), 0o600)

    def test_same_version_and_second_never_overwrites_a_prior_backup(self):
        with tempfile.TemporaryDirectory(prefix="uten-private-backup-") as temp:
            directory = Path(temp) / "backups"
            one = self.run_backup(directory, "printf first")
            two = self.run_backup(directory, "printf second")
            self.assertEqual(one.returncode, 0, one.stderr)
            self.assertEqual(two.returncode, 0, two.stderr)
            self.assertNotEqual(one.stdout.strip(), two.stdout.strip())
            self.assertEqual({p.read_text() for p in directory.glob("*.dump")}, {"first", "second"})

    def test_empty_or_failed_dump_cannot_report_a_successful_backup(self):
        for producer in (":", "printf incomplete; return 7"):
            with self.subTest(producer=producer), tempfile.TemporaryDirectory(prefix="uten-private-backup-") as temp:
                result = self.run_backup(Path(temp) / "backups", producer)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                # Nothing that the cleanup could later mistake for the newest backup is left behind.
                self.assertEqual([], list((Path(temp) / "backups").iterdir()))

    def test_successful_dump_is_published_under_its_final_name_only(self):
        with tempfile.TemporaryDirectory(prefix="uten-private-backup-") as temp:
            directory = Path(temp) / "backups"
            result = self.run_backup(directory, "printf complete")
            self.assertEqual(result.returncode, 0, result.stderr)
            dump = Path(result.stdout.strip())
            self.assertEqual([dump.name], [path.name for path in directory.iterdir()])
            self.assertRegex(dump.name, r"^uten_fixture-v1\.33\.3-20260912-000000\.[A-Za-z0-9]{6}\.dump$")
            self.assertEqual(dump.read_text(), "complete")
            self.assertEqual(stat.S_IMODE(dump.stat().st_mode), 0o600)


class SimpleReleaseBackupRetentionTest(unittest.TestCase):
    """Real files in a temporary directory; the shell's own date decides 'today'."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uten-backup-retention-")
        self.directory = Path(self.temp.name) / "backups"
        self.directory.mkdir()
        today = subprocess.run([bash_path(), "-c", "date +%Y%m%d"], capture_output=True, text=True, check=True)
        self.today = datetime.strptime(today.stdout.strip(), "%Y%m%d")

    def tearDown(self):
        self.temp.cleanup()

    def dump(self, days_ago, suffix="AbC123", version="v2.3.0", database="uten_fixture", clock="024638",
             content=None, extension=".dump"):
        day = (self.today - timedelta(days=days_ago)).strftime("%Y%m%d")
        name = f"{database}-{version}-{day}-{clock}.{suffix}{extension}"
        (self.directory / name).write_bytes(b"d" * (days_ago + 1) if content is None else content)
        return name

    def prune(self, keep="3", directory=None):
        env = dict(os.environ, UTEN_BACKUP_DIR=(directory or self.directory).as_posix(),
                   UTEN_PG_DATABASE="uten_fixture", UTEN_BACKUP_KEEP_DAYS=keep)
        script = ("set -euo pipefail\nlog() { printf '%s\\n' \"$*\"; }\n"
                  + shell_function("prune_database_backups") + "\nprune_database_backups\n")
        result = subprocess.run([bash_path(), "-c", script], env=env, capture_output=True,
                                text=True, encoding="utf-8", check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def names(self):
        return {path.name for path in self.directory.iterdir()}

    def test_keeps_the_last_three_calendar_days_and_logs_freed_bytes(self):
        # 2026-10-06 owner decision: every server backup keeps 3 days (default UTEN_BACKUP_KEEP_DAYS).
        kept = {self.dump(days) for days in (0, 1, 2)}
        expired = {self.dump(3, suffix="Old003"), self.dump(30, suffix="Old030")}
        output = self.prune()
        self.assertEqual(kept, self.names())
        for name in expired:
            self.assertIn(name, output)
        self.assertIn("释放 4 字节", output)
        self.assertIn("释放 31 字节", output)

    def test_an_explicit_longer_window_is_still_honoured(self):
        kept = {self.dump(days) for days in (0, 3, 6)}
        expired = self.dump(7, suffix="Old007")
        self.prune(keep="7")
        self.assertEqual(kept, self.names())
        self.assertNotIn(expired, self.names())

    def test_newest_dump_is_kept_even_when_every_dump_is_old(self):
        newest = self.dump(30, suffix="New030")
        same_second = self.dump(30, suffix="Tie030")
        self.dump(40, suffix="Old040")
        self.prune()
        self.assertEqual({newest, same_second}, self.names())

    def test_manual_unrecognized_and_linked_entries_are_never_deleted(self):
        current = self.dump(0)
        old_day = (self.today - timedelta(days=60)).strftime("%Y%m%d")
        untouched = {
            f"uten_fixture-pre-rollback-v230-{old_day}-024638.dump",
            f"other_db-v1.0.0-{old_day}-000000.AbC123.dump",
            f"uten_fixture-v1.0.0-{old_day}-000000.AbC1234.dump",
            f"uten_fixture-v1.0-{old_day}-000000.AbC123.dump",
            f"uten_fixture-v1.0.0-{old_day}-000000.AbC123.dump.bak",
            f"uten_fixture-v1.0.0-{old_day}-000000.AbC123.sql",
        }
        for name in untouched:
            (self.directory / name).write_bytes(b"manual")
        folder = f"uten_fixture-v1.0.0-{old_day}-000000.Dir123.dump"
        (self.directory / folder).mkdir()
        (self.directory / folder / "inside").write_bytes(b"keep")
        outside = Path(self.temp.name) / "outside.dump"
        outside.write_bytes(b"outside")
        link = f"uten_fixture-v1.0.0-{old_day}-000000.Lnk123.dump"
        os.symlink(outside, self.directory / link)
        self.prune()
        self.assertEqual(untouched | {current, folder, link}, self.names())
        self.assertEqual(b"outside", outside.read_bytes())
        self.assertEqual(b"keep", (self.directory / folder / "inside").read_bytes())

    def test_invalid_setting_missing_or_linked_directory_deletes_nothing(self):
        current = self.dump(0)
        old = self.dump(30, suffix="Old030")
        for keep in ("0", "366", "-1", "7d", "", "07"):
            with self.subTest(keep=keep):
                output = self.prune(keep=keep)
                self.assertIn("跳过升级前备份清理", output)
                self.assertEqual({current, old}, self.names())
        linked = Path(self.temp.name) / "linked-backups"
        os.symlink(self.directory, linked, target_is_directory=True)
        self.prune(directory=linked)
        self.prune(directory=Path(self.temp.name) / "missing")
        self.assertEqual({current, old}, self.names())

    def test_failed_empty_or_interrupted_dumps_are_never_kept_as_the_newest(self):
        # Day 0: a good dump A. Day 9: a dump died midway (legacy empty file or a .partial),
        # then an operator re-activated a code-only release, which runs the cleanup.
        good = self.dump(9, suffix="Good09")
        empty = self.dump(0, suffix="Empty0", content=b"")
        partial = self.dump(0, suffix="Part00", content=b"half", extension=".dump.partial")
        old_partial = self.dump(30, suffix="Part30", content=b"half", extension=".dump.partial")
        old_empty = self.dump(30, suffix="Empty3", content=b"")
        output = self.prune()
        self.assertEqual({good, empty, partial}, self.names())
        self.assertIn(old_partial, output)
        self.assertIn(old_empty, output)

    def test_without_any_finished_dump_nothing_is_deleted(self):
        partial = self.dump(30, suffix="Part30", content=b"half", extension=".dump.partial")
        empty = self.dump(40, suffix="Empty4", content=b"")
        self.prune()
        self.assertEqual({partial, empty}, self.names())

    def test_dump_failure_leaves_no_file_on_any_platform(self):
        for producer in (":", "printf incomplete; return 7"):
            with self.subTest(producer=producer):
                env = dict(os.environ, UTEN_BACKUP_DIR=self.directory.as_posix(), UTEN_PG_DATABASE="uten_fixture")
                script = ("set -euo pipefail\nlog() { :; }\nrunuser() { " + producer + "; }\n"
                          + shell_function("create_database_backup") + "\ncreate_database_backup v1.33.3\n")
                result = subprocess.run([bash_path(), "-c", script], env=env, capture_output=True,
                                        text=True, encoding="utf-8", check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(set(), self.names())

    def test_cleanup_runs_only_after_a_healthy_activation(self):
        source = SCRIPT.read_text(encoding="utf-8")
        activate = shell_function("do_activate")
        healthy = activate[activate.index("if systemctl start"):activate.index('log "启动或健康检查失败')]
        self.assertIn("prune_database_backups", healthy)
        self.assertEqual(1, source.count("\n    prune_database_backups\n"))
        self.assertIn('"${UTEN_BACKUP_KEEP_DAYS:=3}"', source)
        # Pre-activation dumps live on the local NVMe backup volume, not on the database's /data array.
        self.assertIn('"${UTEN_BACKUP_DIR:=/srv/uten-backup/pre-activation}"', source)
        example = (SCRIPT.parent / "updater.env.example").read_text(encoding="utf-8")
        self.assertIn("\nUTEN_BACKUP_DIR=/srv/uten-backup/pre-activation\n", example)
        self.assertIn("\nUTEN_BACKUP_KEEP_DAYS=3\n", example)


if __name__ == "__main__":
    unittest.main()
