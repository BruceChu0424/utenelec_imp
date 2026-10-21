"""Exercise the developer entry point without starting Maven, Java or a database."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")
LAUNCHER = Path(__file__).resolve().parents[1] / "dev.ps1"


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "Windows PowerShell launcher")
class DevLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="uten dev launcher ")
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.server = self.root / "server with spaces"
        self.server.mkdir()
        shutil.copyfile(LAUNCHER, self.server / "dev.ps1")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "mvn.cmd").write_text(
            '@echo off\r\n'
            'cd > "%UTEN_TEST_CAPTURE_DIRECTORY%\\cwd.txt"\r\n'
            'echo %* > "%UTEN_TEST_CAPTURE_DIRECTORY%\\arguments.txt"\r\n'
            'exit /b %UTEN_TEST_MAVEN_EXIT_CODE%\r\n',
            encoding="utf-8",
        )

    def run_launcher(self, *arguments, exit_code=0):
        environment = dict(os.environ)
        environment["PATH"] = str(self.bin) + os.pathsep + environment["PATH"]
        environment["UTEN_TEST_CAPTURE_DIRECTORY"] = str(self.root)
        environment["UTEN_TEST_MAVEN_EXIT_CODE"] = str(exit_code)
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(self.server / "dev.ps1"), *arguments],
            cwd=self.root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def captured_arguments(self):
        return (self.root / "arguments.txt").read_text().strip()

    def test_default_startup_uses_server_working_directory_and_isolated_build(self):
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "cwd.txt").read_text().strip(), str(self.server))
        self.assertEqual(
            self.captured_arguments(),
            "-Pdev-run -Duten.build.directory=target-dev spring-boot:run",
        )

    def test_secondary_instance_forwards_port_and_own_build_directory(self):
        result = self.run_launcher("-BuildDirectory", "target-dev-secondary", "-Port", "8081")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.captured_arguments(),
            "-Pdev-run -Duten.build.directory=target-dev-secondary "
            "-Dspring-boot.run.arguments=--server.port=8081 spring-boot:run",
        )

    def test_maven_failure_is_returned_to_caller(self):
        result = self.run_launcher(exit_code=17)
        self.assertEqual(result.returncode, 17, result.stderr)

    def test_build_directory_cannot_reuse_ordinary_target_or_escape_server(self):
        for directory in ("target", "../target-dev", "target-dev/../target", "C:\\target-dev"):
            with self.subTest(directory=directory):
                result = self.run_launcher("-BuildDirectory", directory)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "arguments.txt").exists())

    def test_invalid_port_does_not_invoke_maven(self):
        result = self.run_launcher("-Port", "65536")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "arguments.txt").exists())


if __name__ == "__main__":
    unittest.main()
