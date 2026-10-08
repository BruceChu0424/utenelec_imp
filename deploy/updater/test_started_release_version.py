"""Process version follows its physical jar, including atomic activation and rollback."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "simple" / "host" / "start-server.py"
SPEC = importlib.util.spec_from_file_location("uten_started_release", SOURCE)
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


class StartedReleaseVersionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-started-release-")
        self.root = Path(os.path.realpath(self.temporary.name))
        self.releases = self.root / "releases"
        self.releases.mkdir()
        self.arguments = ["-Xms512m", "-Xmx4g", "-Dspring.flyway.enabled=false",
                          "-XX:+ExitOnOutOfMemoryError", "-jar", "server/uten-imp-server.jar"]

    def tearDown(self):
        self.temporary.cleanup()

    def release(self, name):
        directory = self.releases / name
        (directory / "server").mkdir(parents=True)
        (directory / "server" / "uten-imp-server.jar").write_bytes(b"synthetic verified jar")
        return directory

    def test_start_command_freezes_version_and_absolute_jar_for_the_same_release(self):
        old, new = self.release("v1.2.3"), self.release("v1.2.4")
        started = launcher.server_command(old, self.arguments, self.releases)
        activated = launcher.server_command(new, self.arguments, self.releases)
        self.assertIn(launcher.VERSION_OPTION + "v1.2.3", started)
        self.assertEqual(str(old / "server" / "uten-imp-server.jar"), started[-1])
        self.assertIn(launcher.VERSION_OPTION + "v1.2.4", activated)
        self.assertEqual(started, launcher.server_command(old, self.arguments, self.releases))
        self.assertEqual(["-Xms512m", "-Xmx4g", "-Dspring.flyway.enabled=false",
                          "-XX:+ExitOnOutOfMemoryError"], started[1:5])

    def test_a_stale_manual_version_option_cannot_override_the_started_artifact(self):
        release = self.release("v2.0.0")
        arguments = [launcher.VERSION_OPTION + "v0.1.0", *self.arguments]
        command = launcher.server_command(release, arguments, self.releases)
        self.assertEqual([launcher.VERSION_OPTION + "v2.0.0"],
                         [option for option in command if option.startswith(launcher.VERSION_OPTION)])

    def test_the_live_unit_uses_the_launcher_and_release_local_jar(self):
        unit = (SOURCE.parent.parent / "units" / "uten-imp.service").read_text(encoding="utf-8")
        self.assertIn("ExecStart=/usr/bin/python3 -I /usr/local/lib/uten-imp/start-server.py", unit)
        self.assertIn("-jar server/uten-imp-server.jar", unit)
        self.assertIn("WorkingDirectory=/opt/uten-imp/current", unit)

    def test_unversioned_or_wrong_jar_roots_fail_closed(self):
        for name in ("current", "v01.2.3", "v1.2.3-staging"):
            with self.assertRaises(ValueError):
                launcher.server_command(self.release(name), self.arguments, self.releases)
        release = self.release("v1.0.0")
        with self.assertRaises(ValueError):
            launcher.server_command(release, ["-jar", "/opt/uten-imp/current/server/uten-imp-server.jar"], self.releases)
        with self.assertRaises(ValueError):
            launcher.server_command(release, self.arguments, self.root)

    @unittest.skipUnless(os.name == "posix", "POSIX activation symlink and physical cwd")
    def test_switching_current_does_not_relabel_an_already_selected_process(self):
        old, new = self.release("v1.0.1"), self.release("v1.0.2")
        current = self.root / "current"
        current.symlink_to(old, target_is_directory=True)
        previous_cwd = Path.cwd()
        try:
            os.chdir(current)
            current.unlink()
            current.symlink_to(new, target_is_directory=True)
            command = launcher.server_command(Path.cwd(), self.arguments, self.releases)
        finally:
            os.chdir(previous_cwd)
        self.assertIn(launcher.VERSION_OPTION + "v1.0.1", command)
        self.assertEqual(str(old / "server" / "uten-imp-server.jar"), command[-1])

    @unittest.skipUnless(os.name == "posix", "POSIX release-file links")
    def test_a_jar_linked_outside_the_versioned_release_is_rejected(self):
        old, new = self.release("v1.0.1"), self.release("v1.0.2")
        jar = old / "server" / "uten-imp-server.jar"
        jar.unlink()
        jar.symlink_to(new / "server" / "uten-imp-server.jar")
        with self.assertRaises(ValueError):
            launcher.server_command(old, self.arguments, self.releases)


if __name__ == "__main__":
    unittest.main()
