from __future__ import annotations

import hashlib
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = PROJECT_ROOT / "deploy/setup/launch-install-release-retention.py"
SPEC = importlib.util.spec_from_file_location("release_retention_install_launcher", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
launcher = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = launcher
SPEC.loader.exec_module(launcher)


@unittest.skipUnless(os.name == "posix", "launcher requires Linux no-follow APIs")
class ReleaseRetentionInstallLauncherTest(unittest.TestCase):
    def test_reviewed_installer_pin_matches_the_exact_source_bytes(self) -> None:
        installer = PROJECT_ROOT / "deploy/setup/install-release-retention.py"
        self.assertEqual(
            launcher.REVIEWED_INSTALLER_SHA256,
            hashlib.sha256(installer.read_bytes()).hexdigest(),
        )

    def test_installer_is_read_from_one_pinned_no_follow_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "installer.py"
            raw = b"VALUE = 1\n"
            source.write_bytes(raw)
            digest = hashlib.sha256(raw).hexdigest()
            verified = launcher.read_verified_installer(
                expected_sha256=digest,
                require_root_control=False,
                path=source,
            )
            self.assertEqual(verified.payload, raw)
            with self.assertRaisesRegex(launcher.LauncherError, "differs"):
                launcher.read_verified_installer(
                    expected_sha256="0" * 64,
                    require_root_control=False,
                    path=source,
                )
            link = root / "link.py"
            link.symlink_to(source)
            with self.assertRaises(launcher.LauncherError):
                launcher.read_verified_installer(
                    expected_sha256=digest,
                    require_root_control=False,
                    path=link,
                )

    def test_argument_boundary_is_mandatory(self) -> None:
        self.assertEqual(launcher.parse_arguments(["--", "assess"]), ["assess"])
        for invalid in ([], ["assess"], ["--"], ["--", "bad\nargument"]):
            with self.assertRaises(launcher.LauncherError):
                launcher.parse_arguments(invalid)

    def test_deprecated_shell_has_no_mutating_install_path(self) -> None:
        shell = (PROJECT_ROOT / "deploy/setup/install-release-retention.sh").read_text(
            encoding="utf-8"
        )
        for forbidden in (
            "install -d",
            "disable --now",
            "systemctl start",
            "systemctl stop",
            "systemctl enable",
            "systemctl disable",
        ):
            self.assertNotIn(forbidden, shell)
        self.assertIn("uten-imp-release-retention-installer", shell)


if __name__ == "__main__":
    unittest.main()
