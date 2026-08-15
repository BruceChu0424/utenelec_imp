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
    "test_monitor_runtime_launcher_module", ROOT / "monitor_runtime_launcher.py"
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


class RuntimeLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = pathlib.Path(self.temporary.name) / "runtime"
        self.directory.mkdir(mode=0o700)
        self.installed_launcher = self.directory / "monitor_runtime_launcher.py"
        shutil.copyfile(ROOT / "monitor_runtime_launcher.py", self.installed_launcher)
        os.chmod(self.installed_launcher, 0o500)
        self.runtime_hashes = {}
        for filename in launcher.RUNTIME_FILES:
            target = self.directory / filename
            shutil.copyfile(ROOT / filename, target)
            os.chmod(target, 0o400)
            self.runtime_hashes[filename] = hashlib.sha256(target.read_bytes()).hexdigest()
        os.chmod(self.directory, 0o500)
        self.addCleanup(lambda: os.chmod(self.directory, 0o700) if self.directory.exists() else None)
        original_lstat = pathlib.Path.lstat
        original_fstat = os.fstat
        self.patches = [
            mock.patch.object(launcher, "INSTALLED_DIRECTORY", self.directory),
            mock.patch.object(launcher, "INSTALLED_LAUNCHER", self.installed_launcher),
            mock.patch.object(launcher, "RUNTIME_FILES", self.runtime_hashes),
            mock.patch.object(launcher, "__file__", str(self.installed_launcher)),
            mock.patch.object(
                launcher,
                "_parent_chain",
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

    def test_compiled_runtime_digests_match_repository_bytes(self):
        source = (ROOT / "monitor_runtime_launcher.py").read_text(encoding="utf-8")
        for filename, digest in self.runtime_hashes.items():
            self.assertIn(digest, source, filename)

    def test_capture_preloads_all_modules_from_authenticated_bytes(self):
        captured = launcher.capture_runtime()
        self.assertEqual(set(captured), set(launcher.RUNTIME_FILES))
        modules = launcher.preload_modules(captured)
        self.assertTrue(callable(modules["host_monitor.py"].main))
        self.assertTrue(callable(modules["external_probe.py"].main))

    def test_hash_drift_rejected_before_module_execution(self):
        victim = self.directory / "external_probe.py"
        os.chmod(victim, 0o600)
        victim.write_bytes(victim.read_bytes() + b"\n# drift\n")
        os.chmod(victim, 0o400)
        with mock.patch.object(launcher, "preload_modules") as preload:
            with self.assertRaisesRegex(launcher.RuntimeTrustError, "digest differs"):
                launcher.execute(["external"])
            preload.assert_not_called()

    def test_path_replacement_rejected_before_selected_action(self):
        victim = self.directory / "host_monitor.py"
        original_capture = launcher._capture

        def capture(path, digest):
            if path.name == "host_monitor.py":
                os.chmod(path.parent, 0o700)
                try:
                    replacement = path.parent / "replacement"
                    replacement.write_bytes(path.read_bytes())
                    os.chmod(replacement, 0o400)
                    os.replace(replacement, path)
                finally:
                    os.chmod(path.parent, 0o500)
            return original_capture(path, digest)

        with mock.patch.object(launcher, "_capture", side_effect=capture), mock.patch.object(
            launcher, "preload_modules"
        ) as preload:
            with self.assertRaises(launcher.RuntimeTrustError):
                launcher.execute(["host"])
            preload.assert_not_called()

    def test_action_allowlist_rejects_arbitrary_arguments(self):
        for arguments in ([], ["host", "--policy", "/tmp/x"], ["failure", "nginx.service"]):
            with self.assertRaises(launcher.RuntimeTrustError):
                launcher._selected_action(arguments)

    def test_runtime_sources_have_no_sibling_path_loader(self):
        for filename in ("alert_spool.py", "host_monitor.py", "external_probe.py"):
            text = (ROOT / filename).read_text(encoding="utf-8")
            self.assertNotIn("spec_from_file_location", text)
            self.assertNotIn("importlib.util", text)
            self.assertIn('sys.modules["uten_imp_monitoring_', text)


if __name__ == "__main__":
    unittest.main()
