"""Install-time dependency closure and cold-boot shared lock directory regression."""
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


SIMPLE = Path(__file__).resolve().parent
BACKUP = SIMPLE.parent / "postgres/backup"
TMPFILES = SIMPLE / "uten-imp-updater.tmpfiles.conf"
INSTALLER = SIMPLE / "install-server-operations.sh"


class HostInstallationContractTest(unittest.TestCase):
    def test_shared_lock_directory_is_created_before_both_service_sandboxes(self):
        entries = [line.split() for line in TMPFILES.read_text().splitlines()
                   if line.strip() and not line.startswith("#")]
        self.assertEqual([["d", "/run/uten-imp-updater", "0700", "root", "root", "-"],
                          ["d", "/var/lib/uten-imp-public", "0755", "root", "root", "-"]], entries)
        for name in ("uten-imp-operations.service", "uten-imp-update-job.service"):
            unit = (SIMPLE / "units" / name).read_text()
            after = " ".join(line.split("=", 1)[1] for line in unit.splitlines()
                             if line.startswith("After="))
            self.assertIn("systemd-tmpfiles-setup.service", after.split(), name)
            requires = " ".join(line.split("=", 1)[1] for line in unit.splitlines()
                                if line.startswith("Requires="))
            self.assertIn("systemd-tmpfiles-setup.service", requires.split(), name)
            self.assertNotIn("ExecStartPre=+/usr/bin/install", unit, name)
            # This shared lock must survive either service stopping or restarting.
            runtime = " ".join(line.split("=", 1)[1] for line in unit.splitlines()
                               if line.startswith("RuntimeDirectory="))
            self.assertNotIn("uten-imp-updater", runtime.split(), name)
        installer = INSTALLER.read_text()
        self.assertIn('atomic_install "$SRC/uten-imp-updater.tmpfiles.conf" '
                      '/etc/tmpfiles.d/uten-imp-updater.conf 0644', installer)
        self.assertIn('safe_lock_file /etc/tmpfiles.d/uten-imp-updater.conf', installer)
        create = installer.index("/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/uten-imp-updater.conf")
        self.assertLess(create, installer.index("systemctl restart uten-imp-operations.service"))

    def test_installed_backup_dependency_closure_loads_all_three_reviewed_helpers(self):
        installer = INSTALLER.read_text()
        for variable, name in (("MARKET_BACKUP_SOURCE", "market_state_backup.py"),
                               ("CLIENT_BACKUP_SOURCE", "client_release_state_backup.py"),
                               ("PAIRED_SOURCE", "paired_internal_backup.py")):
            self.assertIn(f'atomic_install "${variable}" /usr/local/lib/uten-imp/{name} 0644', installer)
            self.assertIn(f"/usr/local/lib/uten-imp/{name} \\", installer)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("paired_internal_backup.py", "market_state_backup.py", "client_release_state_backup.py"):
                shutil.copyfile(BACKUP / name, root / name)
            spec = importlib.util.spec_from_file_location("installed_paired_backup", root / "paired_internal_backup.py")
            module = importlib.util.module_from_spec(spec)
            # dataclasses resolves the defining module through sys.modules.
            import sys
            sys.modules[spec.name] = module
            try:
                spec.loader.exec_module(module)
                self.assertEqual(root / "market_state_backup.py", Path(module.market_backup_module().__file__))
                self.assertEqual(root / "client_release_state_backup.py", Path(module.client_backup_module().__file__))
            finally:
                sys.modules.pop(spec.name, None)


@unittest.skipUnless(os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
                     "host installation regressions require Linux root as in deployment CI")
class LinuxHostInstallationTest(unittest.TestCase):
    def test_native_systemd_accepts_both_units_with_their_installation_modes(self):
        executable = shutil.which("systemd-analyze")
        if executable is None:
            self.skipTest("systemd-analyze is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("uten-imp-operations.service", "uten-imp-update-job.service", "uten-alert@.service"):
                target = root / name
                shutil.copyfile(SIMPLE / "units" / name, target)
                target.chmod(0o644)
            result = subprocess.run([executable, "verify", "--man=no",
                                     str(root / "uten-imp-operations.service"),
                                     str(root / "uten-imp-update-job.service")],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("", result.stderr)

    def test_cold_boot_tmpfiles_creates_private_directory_and_preserves_live_lock(self):
        executable = shutil.which("systemd-tmpfiles")
        if executable is None:
            self.skipTest("systemd-tmpfiles is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "etc/tmpfiles.d/uten-imp-updater.conf"
            config.parent.mkdir(parents=True)
            shutil.copyfile(TMPFILES, config)
            target = root / "run/uten-imp-updater"
            self.assertFalse(target.exists())
            command = [executable, "--create", "--root=" + str(root), "uten-imp-updater.conf"]
            for cold_boot in range(2):
                result = subprocess.run(command, capture_output=True, text=True, check=False)
                self.assertEqual(0, result.returncode, result.stderr)
                info = target.stat()
                self.assertEqual((0, 0, 0o700), (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)))
                lock = target / "lock"
                lock.write_bytes(b"existing operation")
                inode = lock.stat().st_ino
                result = subprocess.run(command, capture_output=True, text=True, check=False)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(inode, lock.stat().st_ino)
                self.assertEqual(b"existing operation", lock.read_bytes())
                if cold_boot == 0:
                    # Only this test's private /run is cleared to model reboot.
                    shutil.rmtree(root / "run")

    def test_missing_client_backup_helper_rejects_source_before_any_host_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "deploy/simple"
            shutil.copytree(SIMPLE, source)
            backup = source.parent / "postgres/backup"
            backup.mkdir(parents=True)
            for name in ("paired_internal_backup.py", "market_state_backup.py"):
                shutil.copyfile(BACKUP / name, backup / name)
            result = subprocess.run(["/bin/bash", str(INSTALLER), str(source)],
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual("", result.stdout)
            self.assertIn("Missing reviewed client-release backup helper", result.stderr)


if __name__ == "__main__":
    unittest.main()
