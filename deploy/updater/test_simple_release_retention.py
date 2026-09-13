"""Exercise the active Simple Release retention using real temporary directories."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "deploy/simple/uten-imp-updater.sh"


def bash_path():
    if os.name == "nt" and shutil.which("git"):
        candidate = Path(shutil.which("git")).parents[1] / "bin/bash.exe"
        if candidate.is_file():
            return str(candidate)
    return shutil.which("bash")


class SimpleReleaseRetentionTest(unittest.TestCase):
    def run_functions(self, releases, command, active="", keep="2", actual=None):
        source = SCRIPT.read_text(encoding="utf-8")
        functions = "\n".join(
            re.search(r"(?ms)^" + name + r"\(\) \{.*?^\}", source).group(0)
            for name in ("release_versions", "prune_old", "do_status")
        )
        env = dict(os.environ, RELEASES_DIR=str(releases), UTEN_BASE=str(releases),
                   UTEN_KEEP_RELEASES=keep, TEST_ACTIVE=active,
                   TEST_LINK_ACTIVE=active if actual is None else actual)
        result = subprocess.run(
            [bash_path(), "-c", 'set -euo pipefail\nlog() { :; }\n'
             'current_version() { printf "%s" "$TEST_ACTIVE"; }\n'
             'current_link_version() { printf "%s" "$TEST_LINK_ACTIVE"; }\n'
             'oss_get() { printf "%s" "$TEST_ACTIVE"; }\nhealth_ok() { return 0; }\n'
             + functions + "\n" + command],
            env=env, capture_output=True, text=True, check=True)
        return result.stdout.strip().splitlines()

    def test_lists_real_versions_and_ignores_unrecognized_directories(self):
        with tempfile.TemporaryDirectory(prefix="uten-release-retention-") as temp:
            root = Path(temp)
            for name in ("v2026.09.12-10", "v2026.09.12-2", "v2026.09.12-1.backup", "notes"):
                (root / name).mkdir()
            self.assertEqual(self.run_functions(root, "release_versions"),
                             ["v2026.09.12-2", "v2026.09.12-10"])

    def test_retention_never_deletes_active_or_unknown_directories(self):
        with tempfile.TemporaryDirectory(prefix="uten-release-retention-") as temp:
            root = Path(temp)
            active = "v2026.09.01-1"
            names = (active, "v2026.09.10-1", "v2026.09.11-1", "v2026.09.12-1", "v-unreviewed")
            for name in names:
                (root / name).mkdir()
                (root / name / "marker").write_text(name)
            self.run_functions(root, "prune_old", active=active)
            self.assertEqual({p.name for p in root.iterdir()},
                             {active, "v2026.09.11-1", "v2026.09.12-1", "v-unreviewed"})
            self.assertEqual((root / active / "marker").read_text(), active)

    def test_status_displays_nonempty_staged_version_names(self):
        with tempfile.TemporaryDirectory(prefix="uten-release-retention-") as temp:
            root = Path(temp)
            (root / "v2026.09.12-1").mkdir()
            lines = self.run_functions(root, "do_status", active="v2026.09.12-1")
            self.assertIn("  - v2026.09.12-1", lines)
            self.assertNotIn("  - ", lines)

    def test_empty_release_directory_is_safe(self):
        with tempfile.TemporaryDirectory(prefix="uten-release-retention-") as temp:
            self.assertEqual(self.run_functions(Path(temp), "release_versions; prune_old"), [])

    def test_invalid_retention_or_inconsistent_current_preserves_all_versions(self):
        for keep, actual in (("0", None), ("-1", None), ("invalid", None), ("2", "v2026.09.12-1")):
            with self.subTest(keep=keep, actual=actual), tempfile.TemporaryDirectory(prefix="uten-release-retention-") as temp:
                root = Path(temp)
                versions = {"v2026.09.01-1", "v2026.09.10-1", "v2026.09.11-1", "v2026.09.12-1"}
                for version in versions:
                    (root / version).mkdir()
                self.run_functions(root, "prune_old", active="v2026.09.01-1", keep=keep, actual=actual)
                self.assertEqual({p.name for p in root.iterdir()}, versions)


if __name__ == "__main__":
    unittest.main()
