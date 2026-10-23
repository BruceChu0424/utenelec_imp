import hashlib
import json
import os
import http.client
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(os.name == "posix", "Linux provisioning contract")
class ProvisionTest(unittest.TestCase):
    def setUp(self):
        import grp
        if os.geteuid() != 0:
            self.skipTest("provisioning requires isolated Linux root fixture")
        try:
            self.service_gid = grp.getgrnam("uten-dr-control").gr_gid
        except KeyError:
            self.skipTest("fixture service group must be provisioned outside the test")
        import provision
        self.provision = provision
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "uten-dr-control"
        self.paths = [self.directory / name for name in ("control.json", "broker.token", "backup.token", "totp-master.key")]

    def initialize(self, **options):
        return self.provision.initialize(self.paths[0], "https://admin.justplayit.cn",
                                         *self.paths[1:], **options)

    def test_real_linux_permissions_and_repeat_initialization_preserve_secrets(self):
        self.assertTrue(self.initialize())
        before = [hashlib.sha256(p.read_bytes()).hexdigest() for p in self.paths]
        self.assertEqual(0o750, stat.S_IMODE(self.directory.stat().st_mode))
        self.assertEqual(self.service_gid, self.directory.stat().st_gid)
        self.assertEqual(0o640, stat.S_IMODE(self.paths[0].stat().st_mode))
        self.assertEqual(self.service_gid, self.paths[0].stat().st_gid)
        for p in self.paths[1:]:
            self.assertEqual(0o600, stat.S_IMODE(p.stat().st_mode))
            self.assertEqual(0, p.stat().st_uid)
        self.assertFalse(self.initialize())
        self.assertEqual(before, [hashlib.sha256(p.read_bytes()).hexdigest() for p in self.paths])
        config = json.loads(self.paths[0].read_text())
        self.assertNotIn("users", config)
        self.assertEqual(0, config["enrollmentEnabledUntil"])

    def test_each_partial_commit_failure_cleans_only_new_files_and_is_retryable(self):
        for count in range(1, 5):
            with self.subTest(after=count):
                with self.assertRaises(OSError):
                    self.initialize(fail_after=count)
                self.assertTrue(all(not os.path.lexists(p) for p in self.paths))
                self.assertFalse(list(self.directory.glob(".provision-*")))
        self.assertTrue(self.initialize())

    def test_existing_partial_secret_and_symlink_are_never_overwritten(self):
        self.directory.mkdir(mode=0o750)
        original = self.directory / "existing-protected-material"
        original.write_text("retain-this-fixture")
        self.paths[1].symlink_to(original)
        with self.assertRaises(ValueError):
            self.initialize()
        self.assertTrue(self.paths[1].is_symlink())
        self.assertEqual("retain-this-fixture", original.read_text())
        self.assertFalse(self.paths[0].exists())

    def test_bad_group_and_origin_fail_before_any_credentials_are_committed(self):
        with self.assertRaises(KeyError):
            self.initialize(broker_group="uten-no-such-os-group-test")
        self.assertTrue(all(not p.exists() for p in self.paths))
        with self.assertRaises(ValueError):
            self.provision.initialize(self.paths[0], "http://untrusted.example", *self.paths[1:])
        self.assertTrue(all(not p.exists() for p in self.paths))
        self.assertFalse(list(self.directory.glob(".provision-*")))

    def test_real_unprivileged_process_loads_private_master_without_business_database(self):
        import pwd
        try:
            identity = pwd.getpwnam("uten-dr-control")
        except KeyError:
            self.skipTest("fixture service account required")
        self.initialize()
        os.chown(self.temp.name, 0, self.service_gid)
        os.chmod(self.temp.name, 0o750)
        credential = Path(self.temp.name) / "systemd-master-credential"
        credential.write_bytes(self.paths[3].read_bytes())
        os.chown(credential, identity.pw_uid, identity.pw_gid)
        os.chmod(credential, 0o400)
        state = Path(self.temp.name) / "state"
        state.mkdir(mode=0o700)
        os.chown(state, identity.pw_uid, identity.pw_gid)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        child = subprocess.Popen([sys.executable, "-I", str(Path(__file__).with_name("control_plane.py")),
            "--config", str(self.paths[0]), "--database", str(state / "control.sqlite3"),
            "--master-key-file", str(credential), "--port", str(port)],
            user=identity.pw_uid, group=identity.pw_gid, extra_groups=[], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    self.fail("Unprivileged control process failed: " + child.stderr.read().decode())
                try:
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.5)
                    connection.request("GET", "/healthz")
                    response = connection.getresponse()
                    payload = json.loads(response.read())
                    connection.close()
                    self.assertEqual(200, response.status)
                    self.assertTrue(payload["setupRequired"])
                    self.assertFalse(payload["businessReady"])
                    break
                except OSError:
                    time.sleep(0.05)
            else:
                self.fail("Independent control process did not start")
            self.assertEqual(0o600, stat.S_IMODE((state / "control.sqlite3").stat().st_mode))
            self.assertEqual(identity.pw_uid, (state / "control.sqlite3").stat().st_uid)
        finally:
            child.terminate()
            child.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
