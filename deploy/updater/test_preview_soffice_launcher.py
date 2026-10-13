"""Real POSIX exec probes for the permanent, fixed-target preview launcher."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


LAUNCHER = Path(__file__).resolve().parents[1] / "simple/host/uten-preview-soffice.py"


class LauncherSourceTest(unittest.TestCase):
    def test_direct_execution_uses_isolated_python_and_a_fixed_system_converter(self):
        source = LAUNCHER.read_text(encoding="utf-8")
        self.assertEqual("#!/usr/bin/python3 -I", source.splitlines()[0])
        self.assertIn('SOFFICE_EXECUTABLE = "/usr/bin/soffice"', source)
        self.assertNotIn("subprocess", source)


@unittest.skipUnless(os.name == "posix", "Linux/POSIX private-directory and exec checks")
class PosixLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-preview-launcher-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.work = self.root / "private conversion work"
        self.work.mkdir(mode=0o700)
        self.fake = self.root / "fake-soffice"
        self.fake.write_text('''#!/usr/bin/python3 -I
import json,os,sys
print(json.dumps({"names":sorted(os.environ),"argv":sys.argv[1:],
    "fixedPath":os.environ.get("PATH")=="/usr/bin:/bin",
    "privateDirectories":all(os.environ.get(k)==os.getcwd() for k in ("HOME","TMPDIR","TMP","TEMP")),
    "localePreserved":os.environ.get("LANG")=="zh_CN.UTF-8" and os.environ.get("LC_ALL")=="C.UTF-8" and os.environ.get("TZ")=="UTC"}))
''', encoding="utf-8")
        self.fake.chmod(0o700)
        self.harness = '''import importlib.util,sys
spec=importlib.util.spec_from_file_location("launcher",sys.argv[1])
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.SOFFICE_EXECUTABLE=sys.argv[2]
sys.argv=[sys.argv[1],*sys.argv[3:]]
raise SystemExit(module.main())
'''

    def run_launcher(self, args=(), environment=None, isolated=True):
        command = [sys.executable]
        if isolated:
            command.append("-I")
        command += ["-c", self.harness, str(LAUNCHER), str(self.fake), *args]
        return subprocess.run(command, cwd=self.work, env=environment,
                              capture_output=True, text=True, timeout=10)

    def test_real_exec_drops_credentials_agent_loader_and_future_environment_names(self):
        credentials = ("UTEN_DB_PASSWORD", "UTEN_JWT_SECRET", "UTEN_PGP_MASTER_KEY", "UTEN_HMAC_KEY",
                       "UTEN_SECRET_CIPHER_KEY", "AWS_SECRET_ACCESS_KEY", "SSH_AUTH_SOCK",
                       "LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME", "FUTURE_PROVIDER_SECRET")
        environment = dict(os.environ)
        environment.update({name: "synthetic-regression-sentinel" for name in credentials})
        environment.update(LANG="zh_CN.UTF-8", LC_ALL="C.UTF-8", TZ="UTC",
                           HOME="/synthetic-inherited-home", TMPDIR="/synthetic-inherited-tmp")
        argv = ["--headless", "--norestore", "--nologo", "--nolockcheck",
                "-env:UserInstallation=" + (self.root / "profile").as_uri(),
                "--convert-to", "pdf", "--outdir", str(self.work),
                str(self.work / "source ; $(not-a-shell).docx")]
        result = self.run_launcher(argv, environment)
        self.assertEqual(0, result.returncode)
        report = json.loads(result.stdout)
        self.assertEqual(argv, report["argv"])
        self.assertTrue(report["fixedPath"])
        self.assertTrue(report["privateDirectories"])
        self.assertTrue(report["localePreserved"])
        self.assertEqual({"PATH", "LANG", "LC_ALL", "TZ", "HOME", "TMPDIR", "TMP", "TEMP"}, set(report["names"]))
        self.assertTrue(set(credentials).isdisjoint(report["names"]))
        self.assertNotIn("synthetic-regression-sentinel", result.stdout)

    def test_writable_directory_is_refused_before_the_converter_runs(self):
        for mode in (0o770, 0o707, 0o777):
            with self.subTest(mode=mode):
                self.work.chmod(mode)
                result = self.run_launcher()
                self.assertEqual(78, result.returncode)
                self.assertEqual("", result.stdout)
                self.assertEqual("UTEN_PREVIEW_PRIVATE_DIRECTORY_REQUIRED\n", result.stderr)
        self.work.chmod(0o700)

    def test_group_or_world_read_or_traverse_permissions_are_refused(self):
        for mode in (0o755, 0o750, 0o705, 0o740, 0o704):
            with self.subTest(mode=mode):
                self.work.chmod(mode)
                result = self.run_launcher()
                self.assertEqual(78, result.returncode)
                self.assertEqual("", result.stdout)
                self.assertEqual("UTEN_PREVIEW_PRIVATE_DIRECTORY_REQUIRED\n", result.stderr)
        self.work.chmod(0o700)

    @unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0, "ownership mismatch requires root in an isolated test environment")
    def test_another_users_directory_is_refused(self):
        os.chown(self.work, 65534, -1)
        result = self.run_launcher()
        self.assertEqual(78, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("UTEN_PREVIEW_PRIVATE_DIRECTORY_REQUIRED\n", result.stderr)

    def test_nonisolated_python_is_refused_without_echoing_inputs(self):
        result = self.run_launcher(["PRIVATE_ARG_SENTINEL"], isolated=False)
        self.assertEqual(78, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("UTEN_PREVIEW_ISOLATED_PYTHON_REQUIRED\n", result.stderr)

    def test_missing_fixed_converter_reports_only_a_safe_error_code(self):
        self.fake.unlink()
        result = self.run_launcher(["PRIVATE_ARG_SENTINEL"])
        self.assertEqual(127, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("UTEN_PREVIEW_SYSTEM_CONVERTER_UNAVAILABLE\n", result.stderr)

    def test_production_shebang_ignores_python_environment_before_directory_checks(self):
        executable = self.root / "launcher"
        shutil.copyfile(LAUNCHER, executable)
        executable.chmod(0o700)
        self.work.chmod(0o777)
        environment = dict(os.environ, PYTHONPATH="/invalid-synthetic-pythonpath",
                           PYTHONHOME="/invalid-synthetic-pythonhome")
        result = subprocess.run([str(executable)], cwd=self.work, env=environment,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(78, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertEqual("UTEN_PREVIEW_PRIVATE_DIRECTORY_REQUIRED\n", result.stderr)


if __name__ == "__main__":
    unittest.main()
