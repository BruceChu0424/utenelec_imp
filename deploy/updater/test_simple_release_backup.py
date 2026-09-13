"""Run the real backup helper with a fixture dump producer, never a live database."""
from pathlib import Path
import os
import re
import stat
import subprocess
import tempfile
import unittest

from test_simple_release_retention import SCRIPT, bash_path


def backup_helper():
    return re.search(r"(?ms)^create_database_backup\(\) \{.*?^\}",
                     SCRIPT.read_text(encoding="utf-8")).group(0)


@unittest.skipIf(os.name == "nt", "Backup DAC permissions require native Linux; NTFS/MSYS cannot apply them")
class SimpleReleaseBackupTest(unittest.TestCase):
    def run_backup(self, directory, producer="printf fixture-database", command=None):
        env = dict(os.environ, UTEN_BACKUP_DIR=directory.as_posix(), UTEN_PG_DATABASE="uten_fixture")
        script = ("set -euo pipefail\numask 022\nlog() { :; }\n"
                  "date() { printf 20260912-000000; }\n"
                  "runuser() { " + producer + "; }\n" + backup_helper() + "\n" +
                  (command or 'create_database_backup v2026.09.12-4'))
        return subprocess.run([bash_path(), "-c", script], env=env,
                              capture_output=True, text=True, encoding="utf-8", check=False)

    def test_backup_is_private_even_under_permissive_service_umask(self):
        with tempfile.TemporaryDirectory(prefix="uten-private-backup-") as temp:
            directory = Path(temp) / "backups"
            directory.mkdir(mode=0o755)
            result = self.run_backup(directory, command=(
                'create_database_backup v2026.09.12-4\n'
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


if __name__ == "__main__":
    unittest.main()
