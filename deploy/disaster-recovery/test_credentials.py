import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import control_plane as cp


@unittest.skipUnless(os.name == "posix", "POSIX credential permission contract")
class CredentialTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "totp-master"
        self.path.write_text("ab" * 32)

    def test_private_regular_file_accepted_but_ordinary_group_readable_file_rejected(self):
        self.path.chmod(0o600)
        self.assertEqual(bytes.fromhex("ab" * 32), cp.read_master_credential(self.path))
        self.path.chmod(0o440)
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ValueError):
            cp.read_master_credential(self.path)

    def test_symlink_master_is_never_followed(self):
        self.path.chmod(0o600)
        link = Path(self.temp.name) / "link"
        link.symlink_to(self.path)
        with self.assertRaises(ValueError):
            cp.read_master_credential(link)

    @unittest.skipUnless(getattr(os, "geteuid", lambda: 1)() == 0, "isolated root mount fixture")
    def test_systemd_0440_exception_requires_actual_readonly_root_credential_mount(self):
        credential = Path(self.temp.name) / "credentials"
        credential.mkdir(mode=0o550)
        result = subprocess.run(["mount", "-t", "tmpfs", "-o", "size=64k,mode=0550", "tmpfs", str(credential)],
                                capture_output=True)
        if result.returncode:
            self.skipTest("fixture needs CAP_SYS_ADMIN; live systemd255 mount is separately verified")
        try:
            master = credential / "totp-master"
            master.write_text("cd" * 32)
            master.chmod(0o440)
            with patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": str(credential)}):
                with self.assertRaises(ValueError):
                    cp.read_master_credential(master)  # Writable tmpfs is not sufficient.
                subprocess.run(["mount", "-o", "remount,ro", str(credential)], check=True, capture_output=True)
                self.assertTrue(os.statvfs(credential).f_flag & os.ST_RDONLY)
                self.assertEqual(bytes.fromhex("cd" * 32), cp.read_master_credential(master))
                with patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": str(credential / "wrong-unit")}):
                    with self.assertRaises(ValueError):
                        cp.read_master_credential(master)
        finally:
            subprocess.run(["umount", str(credential)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
