from __future__ import annotations

import hashlib
import os
import tempfile
import unittest
from pathlib import Path

import retention_launcher


PROJECT_ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(os.name == "posix", "runtime trust requires Linux no-follow APIs")
class RetentionLauncherTest(unittest.TestCase):
    def test_stable_capture_accepts_exact_digest_and_rejects_digest_or_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "module.py"
            raw = b"VALUE = 1\n"
            source.write_bytes(raw)
            digest = hashlib.sha256(raw).hexdigest()
            verified = retention_launcher.capture_pinned_source(
                source, digest, require_root_control=False
            )
            self.assertEqual(verified.payload, raw)
            with self.assertRaisesRegex(
                retention_launcher.RuntimeTrustError, "digest differs"
            ):
                retention_launcher.capture_pinned_source(
                    source, "0" * 64, require_root_control=False
                )
            link = root / "link.py"
            link.symlink_to(source)
            with self.assertRaises(retention_launcher.RuntimeTrustError):
                retention_launcher.capture_pinned_source(
                    link, digest, require_root_control=False
                )

    def test_manager_is_loaded_only_with_injected_real_source_digests(self) -> None:
        updater = PROJECT_ROOT / "deploy/updater/release_updater.py"
        manager = PROJECT_ROOT / "deploy/updater/retention_manager.py"
        runtime = retention_launcher.load_runtime(
            release_updater_path=updater,
            retention_manager_path=manager,
            pins=retention_launcher.RuntimePins(
                hashlib.sha256(updater.read_bytes()).hexdigest(),
                hashlib.sha256(manager.read_bytes()).hexdigest(),
            ),
            require_root_control=False,
        )
        self.assertTrue(callable(runtime.require_runtime_trust))
        runtime.require_runtime_trust()

    def test_frozen_pins_match_reviewed_sources_and_manager_has_no_path_loader(self) -> None:
        launcher = (PROJECT_ROOT / "deploy/updater/retention_launcher.py").read_text(
            encoding="utf-8"
        )
        updater_path = PROJECT_ROOT / "deploy/updater/release_updater.py"
        updater_raw = updater_path.read_bytes()
        manager_path = PROJECT_ROOT / "deploy/updater/retention_manager.py"
        manager_raw = manager_path.read_bytes()
        manager = manager_raw.decode("utf-8")
        self.assertNotIn(
            "APPROVED_RELEASE_UPDATER_SHA256: str | None = None", launcher
        )
        self.assertEqual(
            retention_launcher.APPROVED_RELEASE_UPDATER_SHA256,
            hashlib.sha256(updater_raw).hexdigest(),
        )
        self.assertNotIn("importlib", manager)
        self.assertNotIn("Path(__file__)", manager)
        self.assertNotIn("spec_from_file_location", manager)
        self.assertIn("_UTEN_PREVERIFIED_RELEASE_UPDATER", manager)
        self.assertEqual(
            retention_launcher.APPROVED_RETENTION_MANAGER_SHA256,
            hashlib.sha256(manager_raw).hexdigest(),
        )


if __name__ == "__main__":
    unittest.main()
