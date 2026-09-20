"""Exercise the shipped activation flow with fixture services and real symlinks."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest

from test_simple_release_retention import SCRIPT, bash_path


@unittest.skipIf(os.name == "nt", "Activation symlinks require native Linux")
class SimpleReleaseActivationTest(unittest.TestCase):
    def activation(self, *, migration=False, first=False, start=True,
                   candidate_health=True, restart=True, old_health=True, migrate=True, final_stop=True):
        source = SCRIPT.read_text(encoding="utf-8")
        activate = re.search(r"(?ms)^do_activate\(\) \{.*?^\}", source).group(0)
        with tempfile.TemporaryDirectory(prefix="uten-activation-") as temp:
            root = Path(temp)
            releases = root / "releases"
            for version in ("v1.0.0", "v1.1.0"):
                (releases / version / "server").mkdir(parents=True)
            active = root / "active-version.txt"
            active.write_text("none\n" if first else "v1.0.0\n")
            if not first:
                (root / "current").symlink_to("releases/v1.0.0", target_is_directory=True)
            (root / "migrator.env").write_text("# no credentials in this fixture\n")
            env = dict(os.environ, UTEN_BASE=str(root), RELEASES_DIR=str(releases),
                       ACTIVE_FILE=str(active), LOCK_FILE=str(root / "updater.lock"),
                       UTEN_APP_SERVICE="uten-fixture", UTEN_MIGRATOR_ENV=str(root / "migrator.env"),
                       EVENTS=str(root / "events"), MIGRATION=str(int(migration)),
                       START=str(int(start)), CANDIDATE_HEALTH=str(int(candidate_health)),
                       RESTART=str(int(restart)), OLD_HEALTH=str(int(old_health)), MIGRATE=str(int(migrate)),
                       FINAL_STOP=str(int(final_stop)))
            fixture = r'''
set -euo pipefail
log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
verify_sums() { printf 'verify\n' >> "$EVENTS"; }
flock() { :; }
migration_digest() {
  if [[ "$1" == *"releases/v1.1.0/"* && "$MIGRATION" == 1 ]]; then printf new; else printf old; fi
}
create_database_backup() { printf 'backup\n' >> "$EVENTS"; printf '%s/backup.dump\n' "$UTEN_BASE"; }
timeout() { printf 'migrate\n' >> "$EVENTS"; [[ "$MIGRATE" == 1 ]]; }
systemctl() {
  local current
  current=$(basename "$(readlink -f "$UTEN_BASE/current" 2>/dev/null)" || true)
  printf '%s:%s\n' "$1" "$current" >> "$EVENTS"
  case "$1" in
    start) [[ "$START" == 1 ]];;
    restart) [[ "$RESTART" == 1 ]];;
    stop) [[ "$FINAL_STOP" == 1 || "$(grep -c '^stop:' "$EVENTS")" == 1 ]];;
    *) return 0;;
  esac
}
wait_health() {
  local current
  current=$(basename "$(readlink -f "$UTEN_BASE/current" 2>/dev/null)" || true)
  printf 'health:%s\n' "$current" >> "$EVENTS"
  if [[ "$current" == v1.1.0 ]]; then [[ "$CANDIDATE_HEALTH" == 1 ]]; else [[ "$OLD_HEALTH" == 1 ]]; fi
}
prune_old() { printf 'prune\n' >> "$EVENTS"; }
'''
            result = subprocess.run([bash_path(), "-c", fixture + activate + '\ndo_activate v1.1.0 manual'],
                                    env=env, text=True, capture_output=True, check=False)
            link = root / "current"
            return result, (root / "events").read_text().splitlines(), active.read_text().strip(), (
                os.readlink(link) if link.is_symlink() else None)

    def test_success_records_version_only_after_health(self):
        result, events, active, link = self.activation(migration=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(active, "v1.1.0")
        self.assertEqual(link, "releases/v1.1.0")
        self.assertLess(events.index("backup"), events.index("migrate"))
        self.assertLess(events.index("migrate"), events.index("start:v1.1.0"))
        self.assertLess(events.index("health:v1.1.0"), events.index("prune"))

    def test_start_failure_and_unhealthy_code_only_candidate_both_restore_verified_old_release(self):
        for start in (False, True):
            with self.subTest(start=start):
                result, events, active, link = self.activation(start=start, candidate_health=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
                self.assertIn("restart:v1.0.0", events)
                self.assertIn("health:v1.0.0", events)
                self.assertIn("应用已恢复", result.stderr)
                self.assertNotIn("backup", events)
                self.assertNotIn("prune", events)

    def test_failed_old_restart_or_health_stops_and_never_claims_recovery(self):
        for restart in (False, True):
            with self.subTest(restart=restart):
                result, events, active, link = self.activation(start=False, restart=restart, old_health=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
                self.assertEqual(events[-1], "stop:v1.0.0")
                self.assertNotIn("应用已恢复", result.stderr)
                self.assertIn("应用未恢复", result.stderr)

    def test_migrated_candidate_failure_restores_code_but_never_starts_old_code(self):
        for start in (False, True):
            with self.subTest(start=start):
                result, events, active, link = self.activation(migration=True, start=start, candidate_health=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
                self.assertIn("backup", events)
                self.assertIn("migrate", events)
                self.assertEqual(events[-1], "stop:v1.0.0")
                self.assertNotIn("restart:v1.0.0", events)
                self.assertNotIn("health:v1.0.0", events)
                self.assertIn("人工恢复", result.stderr)

    def test_migrator_failure_never_switches_code_or_starts_application(self):
        result, events, active, link = self.activation(migration=True, migrate=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
        self.assertEqual(events[-1], "migrate")
        self.assertIn("backup", events)
        self.assertFalse(any(event.startswith(("start:", "restart:")) for event in events))

    def test_first_failed_activation_leaves_no_fictitious_previous_release(self):
        result, events, active, link = self.activation(first=True, start=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(active, "none")
        self.assertIsNone(link)
        self.assertFalse(any(event.startswith("restart:") for event in events))
        self.assertIn("previous=none", result.stderr)

    def test_failed_final_stop_is_reported_without_claiming_stopped_or_recovered(self):
        for migration in (False, True):
            with self.subTest(migration=migration):
                result, events, active, link = self.activation(migration=migration, start=False,
                                                              old_health=False, final_stop=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
                self.assertIn("停止失败", result.stderr)
                self.assertNotIn("应用已恢复", result.stderr)
                self.assertNotIn("应用保持停止", result.stderr)


if __name__ == "__main__":
    unittest.main()
