"""OSS request signing and release permissions of the shipped Simple Release updater.

The real shell functions run against fixture commands: no network, no OSS account and
no company server. The secret used here is a throwaway test value.
"""
import base64
import hashlib
import hmac
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

try:
    import grp
except ImportError:  # Windows: the permission tests below are skipped there
    grp = None

from test_simple_release_retention import SCRIPT, bash_path

# Deliberately not secret-shaped (no keyword, low entropy) so the history scanner stays quiet.
OSS_FIXTURE = "fixture-oss-" + "0123456789" * 3


def interpreter():
    # Some embedded Windows Pythons report a directory as sys.executable.
    candidate = Path(sys.executable)
    if candidate.is_file():
        return candidate
    return Path(shutil.which("python3") or shutil.which("python"))


def shell_function(name):
    return re.search(r"(?ms)^" + name + r"\(\) \{.*?^\}", SCRIPT.read_text(encoding="utf-8")).group(0)


class OssSigningTest(unittest.TestCase):
    """The AccessKey Secret must never be an argument of any process (/proc/<pid>/cmdline is world-readable)."""

    def run_get(self, key="releases/v1.2.3/SHA256SUMS"):
        with tempfile.TemporaryDirectory(prefix="uten-oss-sign-") as temp:
            bin_dir = Path(temp) / "bin"
            bin_dir.mkdir()
            spy = Path(temp) / "argv.log"
            # A python3 stand-in that records its own argv and whether the secret arrived through
            # the environment, then runs the real interpreter with the same arguments.
            shim = bin_dir / "python3"
            shim.write_text(
                "#!/bin/sh\n"
                f"printf 'python3 %s\\n' \"$*\" >> '{spy.as_posix()}'\n"
                f"[ -n \"$UTEN_OSS_SIGNING_SECRET\" ] && printf 'env-secret-present\\n' >> '{spy.as_posix()}'\n"
                f"exec '{interpreter().as_posix()}' \"$@\"\n", encoding="utf-8")
            shim.chmod(0o755)
            script = ("set -euo pipefail\n"
                      "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n"
                      f"curl() {{ printf 'curl %s\\n' \"$*\" >> '{spy.as_posix()}'; printf 'BODY'; }}\n"
                      f"openssl() {{ printf 'openssl %s\\n' \"$*\" >> '{spy.as_posix()}'; return 9; }}\n"
                      "date() { printf 'Mon, 05 Oct 2026 08:00:00 GMT'; }\n"
                      + shell_function("oss_sign") + "\n" + shell_function("oss_get") + "\n"
                      + 'oss_get "$TEST_KEY"\n')
            env = dict(os.environ, PATH=bin_dir.as_posix() + os.pathsep + os.environ.get("PATH", ""),
                       UTEN_OSS_BUCKET="fixture-bucket", UTEN_OSS_ENDPOINT="oss-cn-example.aliyuncs.com",
                       UTEN_OSS_KEY_ID="FIXTUREKEYID", TEST_KEY=key)
            # The secret is a plain (non-exported) shell variable, exactly like the sourced root config.
            result = subprocess.run([bash_path(), "-c", f"UTEN_OSS_KEY_SECRET='{OSS_FIXTURE}'\n" + script],
                                    env=env, capture_output=True, text=True, encoding="utf-8", check=False)
            return result, spy.read_text(encoding="utf-8") if spy.exists() else ""

    def test_signature_is_correct_and_the_secret_is_never_an_argument(self):
        result, log = self.run_get()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual("BODY", result.stdout)
        string_to_sign = b"GET\n\n\nMon, 05 Oct 2026 08:00:00 GMT\n/fixture-bucket/releases/v1.2.3/SHA256SUMS"
        expected = base64.b64encode(hmac.new(OSS_FIXTURE.encode(), string_to_sign, hashlib.sha1).digest()).decode()
        self.assertIn("Authorization: OSS FIXTUREKEYID:" + expected, log)
        self.assertIn("env-secret-present", log)
        self.assertNotIn(OSS_FIXTURE, log)
        self.assertNotIn("openssl", log)
        self.assertIn("https://fixture-bucket.oss-cn-example.aliyuncs.com/releases/v1.2.3/SHA256SUMS", log)

    def test_source_has_no_command_line_hmac_and_does_not_export_the_secret(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("-hmac", source)
        self.assertNotRegex(source, r"(?m)^\s*export\s+UTEN_OSS_KEY_SECRET")
        # The root config is sourced as plain shell variables (only the migrator env is exported).
        self.assertRegex(source, r'(?m)^\. "\$CONFIG"$')
        self.assertNotIn('set -a; . "$CONFIG"', source)
        self.assertIn('os.environ.pop("UTEN_OSS_SIGNING_SECRET")', source)


@unittest.skipUnless(os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
                     "chown/chgrp of release files needs Linux root")
class ReleasePermissionsTest(unittest.TestCase):
    """web/ is readable only through the nginx group; server/ (JARs) stays with the application group."""

    APP_GROUP = "adm"
    WEB_GROUP = "daemon"

    def setUp(self):
        for name in (self.APP_GROUP, self.WEB_GROUP):
            try:
                grp.getgrnam(name)
            except KeyError:
                self.skipTest(f"fixture group {name} is missing in this image")

    def run_shell(self, command):
        script = ("set -euo pipefail\n"
                  "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n"
                  f"APP_GROUP={self.APP_GROUP}\n"
                  + shell_function("require_web_group") + "\n" + shell_function("publish_release_permissions")
                  + "\n" + command)
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, encoding="utf-8",
                              check=False)

    def test_release_layout_modes_and_groups(self):
        with tempfile.TemporaryDirectory(prefix="uten-release-perms-") as temp:
            release = Path(temp) / "v1.2.3"
            (release / "server").mkdir(parents=True, mode=0o755)
            (release / "web" / "assets").mkdir(parents=True, mode=0o755)
            (release / "server" / "uten-imp-server.jar").write_bytes(b"jar")
            (release / "web" / "index.html").write_bytes(b"<html>")
            (release / "web" / "assets" / "main.abcdef12.js").write_bytes(b"js")
            for path in release.rglob("*"):
                path.chmod(0o755 if path.is_dir() else 0o644)
            result = self.run_shell(f"WEB_GROUP={self.WEB_GROUP}\npublish_release_permissions '{release}'\n"
                                    f"publish_release_permissions '{release}'\n")  # idempotent
            self.assertEqual(result.returncode, 0, result.stderr)
            app_gid = grp.getgrnam(self.APP_GROUP).gr_gid
            web_gid = grp.getgrnam(self.WEB_GROUP).gr_gid

            def meta(path):
                info = path.lstat()
                return info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)

            self.assertEqual((0, app_gid, 0o751), meta(release))
            self.assertEqual((0, app_gid, 0o750), meta(release / "server"))
            self.assertEqual((0, app_gid, 0o640), meta(release / "server" / "uten-imp-server.jar"))
            self.assertEqual((0, web_gid, 0o750), meta(release / "web"))
            self.assertEqual((0, web_gid, 0o750), meta(release / "web" / "assets"))
            self.assertEqual((0, web_gid, 0o640), meta(release / "web" / "index.html"))
            self.assertEqual((0, web_gid, 0o640), meta(release / "web" / "assets" / "main.abcdef12.js"))
            # Nothing below the release root is reachable through "other" permissions.
            self.assertFalse(any(meta(path)[2] & 0o007 for path in release.rglob("*")))

    def test_missing_web_group_or_membership_is_a_clear_error(self):
        # The "daemon" account's primary group is "daemon" in Debian/Ubuntu images.
        result = self.run_shell("WEB_USER=daemon\nWEB_GROUP=uten-web-missing-fixture\nrequire_web_group\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("groupadd --system uten-web-missing-fixture", result.stderr)
        result = self.run_shell(f"WEB_USER=daemon\nWEB_GROUP={self.APP_GROUP}\nrequire_web_group\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"usermod -aG {self.APP_GROUP} daemon", result.stderr)
        result = self.run_shell(f"WEB_USER=daemon\nWEB_GROUP={self.WEB_GROUP}\nrequire_web_group\n")
        self.assertEqual(0, result.returncode, result.stderr)


class ReleaseGroupSourceContractTest(unittest.TestCase):
    def test_nginx_no_longer_relies_on_the_application_group(self):
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("\nWEB_GROUP=uten-web\n", source)
        self.assertIn("\nAPP_GROUP=uten-imp\n", source)
        self.assertIn("\nWEB_USER=www-data\n", source)
        self.assertNotIn("加入 uten-imp 组", source)
        check = shell_function("do_check")
        activate = shell_function("do_activate")
        self.assertIn("require_web_group", check)
        self.assertIn('publish_release_permissions "$RELEASES_DIR/$latest"', check)
        self.assertNotIn("chmod -R g+rX \"$RELEASES_DIR", check)
        stop = activate.index('systemctl stop "$UTEN_APP_SERVICE"')
        self.assertLess(activate.index("require_web_group"), stop)
        self.assertLess(activate.index('publish_release_permissions "$RELEASES_DIR/$version"'), stop)
        self.assertLess(activate.index('install -d -m 0700 -- "$UTEN_BACKUP_DIR"'), stop)


if __name__ == "__main__":
    unittest.main()
