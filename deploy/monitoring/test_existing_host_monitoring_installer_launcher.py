from __future__ import annotations

import hashlib
import importlib.util
import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_existing_host_monitoring_launcher_module",
    ROOT / "launch-existing-host-monitoring-installer.py",
)
assert SPEC is not None and SPEC.loader is not None
launcher = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = launcher
SPEC.loader.exec_module(launcher)


class _RootOwnedStat:
    """Present fixture metadata as root-owned without changing other fields."""

    def __init__(self, details):
        self._details = details

    def __getattr__(self, name):
        if name in {"st_uid", "st_gid"}:
            return 0
        return getattr(self._details, name)


class MonitoringInstallerLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.bundle = self.root / "bundle"
        for relative in launcher.SOURCE_BUNDLE_RELATIVE_FILES:
            target = self.bundle / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            source = ROOT.parent.parent / relative
            shutil.copyfile(source, target)
            os.chmod(target, 0o400)
        for directory in sorted(
            [path for path in self.bundle.rglob("*") if path.is_dir()] + [self.bundle],
            key=lambda path: len(path.parts),
            reverse=True,
        ):
            os.chmod(directory, 0o500)
        self.installed_launcher = self.root / "launcher"
        shutil.copyfile(ROOT / "launch-existing-host-monitoring-installer.py", self.installed_launcher)
        os.chmod(self.installed_launcher, 0o500)
        self.addCleanup(self._make_writable)
        original_lstat = pathlib.Path.lstat
        original_fstat = os.fstat
        self.patches = [
            mock.patch.object(launcher, "SOURCE_BUNDLE_ROOT", self.bundle),
            mock.patch.object(
                launcher,
                "INSTALLED_INSTALLER",
                self.bundle / "deploy/monitoring/existing_host_monitoring_installer.py",
            ),
            mock.patch.object(launcher, "INSTALLED_LAUNCHER", self.installed_launcher),
            mock.patch.object(launcher, "__file__", str(self.installed_launcher)),
            mock.patch.object(
                launcher,
                "_root_parent_chain",
                side_effect=lambda path: ((str(path.parent), launcher._fingerprint(path.parent.stat())),),
            ),
            mock.patch.object(
                pathlib.Path,
                "lstat",
                autospec=True,
                side_effect=lambda path, *args, **kwargs: _RootOwnedStat(
                    original_lstat(path, *args, **kwargs)
                ),
            ),
            mock.patch.object(
                os,
                "fstat",
                side_effect=lambda descriptor: _RootOwnedStat(original_fstat(descriptor)),
            ),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def _make_writable(self):
        if self.bundle.exists():
            for path in [self.bundle, *self.bundle.rglob("*")]:
                if path.is_dir():
                    os.chmod(path, 0o700)

    def test_embedded_bundle_digests_match_every_source(self):
        self.assertEqual(
            set(launcher.SOURCE_BUNDLE_RELATIVE_FILES),
            set(launcher.REVIEWED_SOURCE_SHA256),
        )
        for relative, expected in launcher.REVIEWED_SOURCE_SHA256.items():
            actual = hashlib.sha256((ROOT.parent.parent / relative).read_bytes()).hexdigest()
            self.assertEqual(actual, expected, relative)
        verified = launcher.read_verified_bundle()
        self.assertEqual(verified.sha256, launcher.REVIEWED_INSTALLER_SHA256)

    def test_exact_bundle_inventory_and_stable_capture(self):
        before = launcher.validate_bundle_inventory()
        verified = launcher.read_verified_bundle()
        after = launcher.validate_bundle_inventory()
        self.assertEqual(before, after)
        self.assertGreater(verified.size, 1)

    def test_preexisting_same_size_source_drift_fails_before_execution(self):
        victim = self.bundle / "deploy/monitoring/README.zh-CN.md"
        original = victim.read_bytes()
        replacement = bytes([original[0] ^ 1]) + original[1:]
        self.assertEqual(len(replacement), len(original))
        os.chmod(victim, 0o600)
        victim.write_bytes(replacement)
        os.chmod(victim, 0o400)
        with self.assertRaisesRegex(launcher.LauncherError, "embedded reviewed SHA-256"):
            launcher.read_verified_bundle()

    def test_extra_object_and_symlink_fail_closed(self):
        os.chmod(self.bundle, 0o700)
        (self.bundle / "extra").write_text("x", encoding="utf-8")
        os.chmod(self.bundle, 0o500)
        with self.assertRaisesRegex(launcher.LauncherError, "missing or unexpected"):
            launcher.validate_bundle_inventory()

    def test_inventory_replacement_between_checks_blocks_execution(self):
        original_read = launcher.read_verified_bundle

        def replace_after_read():
            value = original_read()
            victim = self.bundle / "deploy/monitoring/README.zh-CN.md"
            os.chmod(victim.parent, 0o700)
            try:
                replacement = victim.parent / "replacement"
                replacement.write_bytes(victim.read_bytes())
                os.chmod(replacement, 0o400)
                os.replace(replacement, victim)
            finally:
                os.chmod(victim.parent, 0o500)
            return value

        with mock.patch.object(launcher, "validate_environment"), mock.patch.object(
            launcher, "validate_installed_launcher"
        ), mock.patch.object(
            launcher, "read_verified_bundle", side_effect=replace_after_read
        ), mock.patch.object(launcher, "execute") as execute:
            self.assertEqual(launcher.main(["--", "assess"]), 78)
            execute.assert_not_called()

    def test_argument_boundary_rejects_ambiguous_input(self):
        for arguments in ([], ["assess"], ["--"], ["--", ""]):
            with self.assertRaises(launcher.LauncherError):
                launcher.parse_arguments(arguments)
        self.assertEqual(launcher.parse_arguments(["--", "assess"]), ["assess"])


if __name__ == "__main__":
    unittest.main()
