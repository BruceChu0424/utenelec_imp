"""Exercise the shipped activation flow with fixture services and real symlinks."""
from pathlib import Path
import json
import os
import re
import shlex
import subprocess
import tempfile
import unittest

from test_simple_release_retention import SCRIPT, bash_path


@unittest.skipIf(os.name == "nt", "Activation symlinks require native Linux")
class SimpleReleaseActivationTest(unittest.TestCase):
    def activation(self, *, migration=False, first=False, start=True,
                   candidate_health=True, restart=True, old_health=True, migrate=True, final_stop=True,
                   backup_dir_blocked=False, backup_dir_symlink=False, install_noop=False,
                   web_group=True, migrator_readable=True, backup=True, expected='',
                   database='uten_imp', port='5432', migrator_extra='', migrator_mode=0o600):
        source = SCRIPT.read_text(encoding="utf-8")
        activate = re.search(r"(?ms)^do_activate\(\) \{.*?^\}", source).group(0)
        preflight = re.search(r"(?ms)^validate_migrator_config\(\) \{.*?^\}", source).group(0)
        with tempfile.TemporaryDirectory(prefix="uten-activation-") as temp:
            root = Path(temp)
            releases = root / "releases"
            for version in ("v1.0.0", "v1.1.0"):
                (releases / version / "server").mkdir(parents=True)
            active = root / "active-version.txt"
            active.write_text("none\n" if first else "v1.0.0\n")
            if not first:
                (root / "current").symlink_to("releases/v1.0.0", target_is_directory=True)
            (root / "migrator.env").write_text(
                "UTEN_MIGRATOR_DB_PASSWORD=FixtureOnlyPassword1234567890\n" + migrator_extra)
            (root / "migrator.env").chmod(migrator_mode)
            backup_dir = root / "pre-activation"
            if backup_dir_blocked:
                # A regular file where the directory should be: like an unmounted, immutable mount point.
                backup_dir.write_text("not a directory")
            elif backup_dir_symlink:
                real_backup_dir = root / "linked-backup-target"
                real_backup_dir.mkdir()
                backup_dir.symlink_to(real_backup_dir, target_is_directory=True)
            env = dict(os.environ, UTEN_BASE=str(root), RELEASES_DIR=str(releases),
                       ACTIVE_FILE=str(active), LOCK_FILE=str(root / "updater.lock"),
                       UTEN_APP_SERVICE="uten-fixture", UTEN_MIGRATOR_ENV=str(root / "migrator.env"),
                       EVENTS=str(root / "events"), MIGRATION=str(int(migration)),
                       START=str(int(start)), CANDIDATE_HEALTH=str(int(candidate_health)),
                       RESTART=str(int(restart)), OLD_HEALTH=str(int(old_health)), MIGRATE=str(int(migrate)),
                       FINAL_STOP=str(int(final_stop)), UTEN_BACKUP_DIR=backup_dir.as_posix(),
                       WEB_GROUP_PRESENT=str(int(web_group)), MIGRATOR_READABLE=str(int(migrator_readable)),
                       BACKUP_SUCCEEDS=str(int(backup)), UTEN_PG_DATABASE=database, UTEN_PG_PORT=port,
                       UTEN_OSS_KEY_SECRET='FixtureCloudSecretOnly', JAVA_TOOL_OPTIONS='FixtureNoRealJvm')
            fixture = r'''
set -euo pipefail
log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
verify_sums() { printf 'verify\n' >> "$EVENTS"; }
flock() { :; }
migration_digest() {
  if [[ "$1" == *"releases/v1.1.0/"* && "$MIGRATION" == 1 ]]; then printf new; else printf old; fi
}
current_version() { cat "$ACTIVE_FILE"; }
create_database_backup() { printf 'backup\n' >> "$EVENTS"; [[ "$BACKUP_SUCCEEDS" == 1 ]] || return 1; printf '%s/backup.dump\n' "$UTEN_BASE"; }
runuser() { [[ "$1 $2 $3 $4" == '-u uten-imp -- test' && "$MIGRATOR_READABLE" == 1 ]]; }
timeout() {
  [[ "$1 $2 $3 $4 $5 $6" == '900 /usr/sbin/runuser -u uten-imp -- /usr/bin/java' ]] || return 99
  printf 'migration-env:%s\n' "$(/usr/bin/env | cut -d= -f1 | sort | tr '\n' ',')" >> "$EVENTS"
  printf 'migrate\n' >> "$EVENTS"; [[ "$MIGRATE" == 1 ]];
}
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
require_web_group() { printf 'web-group\n' >> "$EVENTS"; [[ "$WEB_GROUP_PRESENT" == 1 ]] || die "缺少系统组 uten-web"; }
publish_release_permissions() { printf 'perms:%s\n' "${1##*/}" >> "$EVENTS"; }
prune_database_backups() { printf 'prune-dumps\n' >> "$EVENTS"; }
'''
            if install_noop:
                # A successful helper exit does not prove that its directory postcondition exists.
                fixture += '\ninstall() { return 0; }\n'
            result = subprocess.run([bash_path(), "-c", fixture + preflight + '\n' + activate + '\ndo_activate v1.1.0 manual ' + expected],
                                    env=env, text=True, encoding="utf-8", capture_output=True, check=False)
            link = root / "current"
            return result, (root / "events").read_text().splitlines(), active.read_text().strip(), (
                os.readlink(link) if link.is_symlink() else None)

    def migration_launch(self, *, launcher_exit=0):
        """Execute the shipped migration subshell, with real timeout and no role launcher on PATH."""
        source = SCRIPT.read_text(encoding="utf-8")
        activate = re.search(r"(?ms)^do_activate\(\) \{.*?^\}", source).group(0)
        body = re.search(r'(?ms)^    \(\n(.*?)^    \) \|\| die "migrator ', activate).group(1)
        hardened_path = "export PATH=/usr/bin:/bin LANG=C.UTF-8"
        self.assertEqual(body.count(hardened_path), 1, "Keep the production minimal PATH unchanged")
        self.assertTrue(Path("/usr/bin/timeout").is_file(), "This regression requires real GNU timeout")
        with tempfile.TemporaryDirectory(prefix="uten-real-migrator-launch-") as temp:
            root = Path(temp)
            private_bin = root / "private-bin"
            private_bin.mkdir()
            (private_bin / "timeout").symlink_to("/usr/bin/timeout")
            self.assertFalse((private_bin / "runuser").exists())
            role_launcher = root / "trusted-runuser"
            record = root / "launch.json"
            release = root / "releases/v1.1.0"
            release.mkdir(parents=True)
            expected_args = ["-u", "uten-imp", "--", "/usr/bin/java",
                             "-Dlogging.file.name=/var/log/uten-imp/migrator.log", "-jar",
                             str(release / "server/uten-imp-migrator.jar")]
            role_launcher.write_text(
                "#!/usr/bin/python3\nimport json, os, sys\nfrom pathlib import Path\n"
                f"expected = {expected_args!r}\n"
                "if sys.argv[1:] != expected: sys.exit(97)\n"
                f"Path({str(record)!r}).write_text(json.dumps({{"
                "'argv':sys.argv[1:], 'environmentNames':sorted(os.environ), "
                "'path':os.environ.get('PATH'), 'lang':os.environ.get('LANG'), "
                "'passwordIsDedicated':os.environ.get('UTEN_MIGRATOR_DB_PASSWORD') "
                "== 'FixtureOnlyPassword1234567890'}))\n"
                f"sys.exit({launcher_exit})\n", encoding="utf-8")
            role_launcher.chmod(0o700)
            poison_bin = root / "parent-path"
            poison_bin.mkdir()
            poison_marker = root / "parent-runuser-was-used"
            poison = poison_bin / "runuser"
            poison.write_text("#!/bin/sh\nprintf invoked > " + shlex.quote(str(poison_marker)) + "\n",
                              encoding="utf-8")
            poison.chmod(0o700)
            migrator_env = root / "migrator.env"
            migrator_env.write_text("UTEN_MIGRATOR_DB_PASSWORD=FixtureOnlyPassword1234567890\n",
                                    encoding="utf-8")
            # Sandbox only the fixed system paths. A bare production runuser is deliberately
            # not substituted, so real timeout must fail to find it in private_bin.
            body = body.replace(hardened_path, "export PATH=" + shlex.quote(str(private_bin)) + " LANG=C.UTF-8")
            body = body.replace("/usr/sbin/runuser", shlex.quote(str(role_launcher)))
            env = dict(os.environ, PATH=str(poison_bin) + ":/usr/bin:/bin",
                       UTEN_MIGRATOR_ENV=str(migrator_env), RELEASES_DIR=str(root / "releases"),
                       UTEN_MIGRATOR_DB_PASSWORD="InheritedWrongPassword1234567890",
                       UTEN_OSS_KEY_SECRET="FixtureCloudSecretOnly", JAVA_TOOL_OPTIONS="FixtureNoRealJvm",
                       _JAVA_OPTIONS="FixtureNoInheritedJvm", JDK_JAVA_OPTIONS="FixtureNoInheritedJvm")
            env.pop("BASH_ENV", None)
            command = "set -euo pipefail\nversion=v1.1.0\nexport BASH_ENV=/fixture/untrusted-parent\n(\n" + body + ")\n"
            result = subprocess.run([bash_path(), "-c", command], env=env, capture_output=True,
                                    text=True, encoding="utf-8", check=False, timeout=10)
            observed = json.loads(record.read_text(encoding="utf-8")) if record.exists() else None
            return result, observed, poison_marker.exists(), str(private_bin)

    def test_minimal_path_launches_migrator_role_with_real_timeout(self):
        result, observed, poison_used, private_bin = self.migration_launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(observed)
        self.assertEqual(observed["argv"][:4], ["-u", "uten-imp", "--", "/usr/bin/java"])
        self.assertEqual(observed["path"], private_bin)
        self.assertFalse(poison_used, "Do not search the inherited parent PATH for a privileged launcher")

    def test_real_timeout_child_keeps_only_dedicated_migration_environment(self):
        result, observed, _, _ = self.migration_launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(observed["passwordIsDedicated"], "The private file must replace any inherited password")
        self.assertEqual(observed["lang"], "C.UTF-8")
        for name in ("UTEN_OSS_KEY_SECRET", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS",
                     "BASH_ENV", "UTEN_MIGRATOR_ENV", "RELEASES_DIR"):
            self.assertNotIn(name, observed["environmentNames"])

    def test_real_timeout_preserves_role_launcher_failure(self):
        result, observed, poison_used, _ = self.migration_launch(launcher_exit=71)
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assertIsNotNone(observed, "The controlled role launcher must actually execute")
        self.assertFalse(poison_used)

    def test_success_records_version_only_after_health(self):
        result, events, active, link = self.activation(migration=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(active, "v1.1.0")
        self.assertEqual(link, "releases/v1.1.0")
        self.assertLess(events.index("backup"), events.index("migrate"))
        self.assertLess(events.index("migrate"), events.index("start:v1.1.0"))
        self.assertLess(events.index("health:v1.1.0"), events.index("prune"))
        # Old pre-migration dumps are pruned only after the new backup exists and the release is healthy.
        self.assertLess(events.index("prune"), events.index("prune-dumps"))
        child_env = next(event for event in events if event.startswith('migration-env:'))
        self.assertIn('UTEN_MIGRATOR_DB_PASSWORD', child_env)
        self.assertNotIn('UTEN_OSS_KEY_SECRET', child_env)
        self.assertNotIn('JAVA_TOOL_OPTIONS', child_env)
        self.assertNotIn('UTEN_MIGRATOR_ENV', child_env)
        # Release permissions (web/ only for uten-web) are fixed before the application is stopped.
        self.assertLess(events.index("web-group"), events.index("stop:v1.0.0"))
        self.assertLess(events.index("perms:v1.1.0"), events.index("stop:v1.0.0"))

    def test_unreadable_migrator_fails_before_stopping_application(self):
        result, events, current, active = self.activation(migration=True, migrator_readable=False)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(any(event.startswith("stop:") for event in events))
        self.assertNotIn("backup", events)
        self.assertNotIn("migrate", events)

    def test_migrator_actual_target_and_static_private_password_are_checked_before_stop(self):
        cases = ({'database': 'other_company'}, {'port': '5433'},
                 {'migrator_extra': 'SPRING_DATASOURCE_URL=jdbc:postgresql://127.0.0.1:5433/other\n'},
                 {'migrator_extra': 'touch "$UTEN_BASE/injected"\n'},
                 {'migrator_extra': 'UTEN_MIGRATOR_DB_PASSWORD=SecondFixturePassword12345\n'},
                 {'migrator_mode': 0o644})
        for case in cases:
            with self.subTest(**case):
                result, events, active, link = self.activation(migration=True, **case)
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(('v1.0.0', 'releases/v1.0.0'), (active, link))
                self.assertFalse(any(event.startswith(('stop:', 'start:', 'restart:')) for event in events))
                self.assertNotIn('backup', events)
                self.assertNotIn('migrate', events)
                self.assertIn('未停应用', result.stderr)

    def test_code_only_activation_does_not_require_migration_credentials_or_target(self):
        result, events, active, _ = self.activation(database='other_company', port='5433', migrator_mode=0o644)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('v1.1.0', active)
        self.assertNotIn('migrate', events)

    def test_final_cutover_dump_failure_restores_original_service_without_migrating(self):
        result, events, active, link = self.activation(migration=True, backup=False)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual((active, link), ('v1.0.0', 'releases/v1.0.0'))
        self.assertIn('stop:v1.0.0', events)
        self.assertIn('start:v1.0.0', events)
        self.assertIn('原服务已恢复', result.stderr)
        self.assertNotIn('migrate', events)
        self.assertNotIn('prune', events)

    def test_expected_current_cas_rejects_a_manual_change_before_any_stop_or_migration(self):
        result, events, active, link = self.activation(migration=True, expected='v0.9.0')
        self.assertEqual(42, result.returncode, result.stderr)
        self.assertEqual((active, link), ('v1.0.0', 'releases/v1.0.0'))
        self.assertIn('未停服', result.stderr)
        self.assertFalse(any(e.startswith(('stop:', 'start:', 'restart:')) for e in events))
        self.assertNotIn('backup', events)
        self.assertNotIn('migrate', events)

    def test_missing_web_group_or_unwritable_backup_dir_fails_before_the_application_stops(self):
        for case in ({"web_group": False}, {"backup_dir_blocked": True}):
            with self.subTest(**case):
                result, events, active, link = self.activation(migration=True, **case)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
                self.assertFalse(any(event.startswith(("stop:", "start:", "restart:")) for event in events), events)
                self.assertNotIn("backup", events)
                self.assertNotIn("migrate", events)
        result, events, _, _ = self.activation(migration=True, backup_dir_blocked=True)
        self.assertIn("未停应用", result.stderr)

    def test_successful_install_exit_cannot_bypass_the_real_backup_directory_preflight(self):
        for blocked in (False, True):
            with self.subTest(backup_dir_blocked=blocked):
                result, events, active, link = self.activation(
                    migration=True, backup_dir_blocked=blocked, install_noop=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("未停应用", result.stderr)
                self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
                self.assertFalse(any(event.startswith(("stop:", "start:", "restart:")) for event in events))
                self.assertNotIn("backup", events)
                self.assertNotIn("migrate", events)

    def test_symbolic_backup_directory_is_refused_before_the_application_stops(self):
        result, events, active, link = self.activation(migration=True, backup_dir_symlink=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未停应用", result.stderr)
        self.assertEqual((active, link), ("v1.0.0", "releases/v1.0.0"))
        self.assertFalse(any(event.startswith(("stop:", "start:", "restart:")) for event in events))
        self.assertNotIn("backup", events)
        self.assertNotIn("migrate", events)

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
                self.assertNotIn("prune-dumps", events)

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
                self.assertNotIn("prune-dumps", events)
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
