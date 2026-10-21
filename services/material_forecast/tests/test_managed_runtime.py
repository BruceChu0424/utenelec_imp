"""Managed payload integrity, crash recovery, and acknowledgement contracts."""

import hashlib
import importlib.util
import json
import os
import signal
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from forecast_worker.locking import os_file_lock
from forecast_worker.autofeed import AutoFeed

PREPARE = Path(__file__).resolve().parents[1] / "prepare_runtime.py"
spec = importlib.util.spec_from_file_location("market_runtime_prepare", PREPARE)
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
spec = importlib.util.spec_from_file_location("market_runtime_builder", PREPARE.with_name("build_payload.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ManagedRuntimeTests(unittest.TestCase):
    def test_isolated_python_runs_payload_entry_from_untrusted_working_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "payload"
            payload.mkdir()
            source = PREPARE.parent
            shutil.copyfile(source / "worker.py", payload / "worker.py")
            shutil.copytree(source / "forecast_worker", payload / "forecast_worker", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
            untrusted = root / "untrusted"
            (untrusted / "forecast_worker").mkdir(parents=True)
            (untrusted / "forecast_worker/__init__.py").write_text("raise AssertionError('untrusted package imported')")
            env = dict(os.environ, PYTHONPATH=str(untrusted))
            result = subprocess.run([sys.executable, "-I", str(payload / "worker.py"), "--help"],
                                    cwd=untrusted, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--auto", result.stdout)
            self.assertFalse((payload / "forecast_worker/__pycache__").exists())

    def test_dependency_candidate_requires_matching_closure_and_both_platform_locks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "runtime-locks").mkdir()
            (root / "requirements.txt").write_text("example==1.0\n")
            (root / "requirements.runtime.txt").write_text("example==1.0\ntransitive==2.0\n")
            for target in builder.TARGETS:
                (root / "runtime-locks" / (target + ".lock")).write_text(
                    "example==1.0 --hash=sha256:" + "a" * 64 + "\ntransitive==2.0 --hash=sha256:" + "b" * 64 + "\n")
            builder.validate_requirement_versions(root)
            (root / "requirements.txt").write_text("example==1.1\n")
            with self.assertRaisesRegex(ValueError, "direct requirements differ"):
                builder.validate_requirement_versions(root)
            (root / "requirements.runtime.txt").write_text("example==1.1\ntransitive==2.0\n")
            with self.assertRaisesRegex(ValueError, "both platform locks"):
                builder.validate_requirement_versions(root)
            builder.validate_requirement_versions(root, refresh_lock=True)

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell 5.1 host contract")
    def test_windows_powershell_51_wrapper_accepts_real_python312(self):
        shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        wrapper = PREPARE.with_suffix(".ps1")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copyfile(wrapper, root / wrapper.name)
            # Exercise the real PS5 native-argument boundary and interpreter;
            # only replace the expensive already-covered installation body.
            (root / PREPARE.name).write_text(
                "import json,sys; print(json.dumps({'schemaVersion':1,'state':'PROBE_OK','arguments':sys.argv[1:]}))",
                encoding="utf-8")
            result = subprocess.run([str(shell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                     "-File", str(root / wrapper.name), "-Payload", str(root / "payload with spaces"),
                                     "-Cache", str(root / "cache with spaces"), "-BasePython", str(Path(sys._base_executable))],
                                    capture_output=True, text=True, timeout=30, env=prepare.child_environment())
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            message = json.loads(result.stdout.strip())
            self.assertEqual(message["state"], "PROBE_OK")
            self.assertEqual(message["arguments"], ["--payload", str(root / "payload with spaces"), "--cache", str(root / "cache with spaces")])

    def test_empty_interrupted_cache_key_is_recovered_but_unknown_content_is_preserved(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = {"platform": "windows-x86_64" if os.name == "nt" else "linux-x86_64",
                        "lockDigest": "a" * 64, "workerVersion": "2.0.0"}
            key = root / (("w-" if os.name == "nt" else "l-") + "a" * 24)
            key.mkdir()
            with patch.object(prepare, "validate", return_value=manifest), patch.object(prepare.venv.EnvBuilder, "create", side_effect=RuntimeError("interrupted-after-marker")):
                with self.assertRaisesRegex(RuntimeError, "interrupted-after-marker"):
                    prepare.prepare(root, root)
            self.assertTrue((key / "managed.json").is_file())
            (key / "managed.json").unlink()
            (key / "unknown-user-file").write_text("preserve", encoding="utf-8")
            with patch.object(prepare, "validate", return_value=manifest):
                with self.assertRaisesRegex(ValueError, "unrecognized incomplete"):
                    prepare.prepare(root, root)
            self.assertEqual((key / "unknown-user-file").read_text(), "preserve")

    def test_collector_lock_is_busy_while_alive_and_released_after_kill(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "collector.lock"
            # A stale marker from the former O_EXCL implementation is harmless.
            path.write_text("12345", encoding="ascii")
            source = str(Path(__file__).resolve().parents[1])
            script = ("import sys,time,os;from pathlib import Path;sys.path.insert(0,sys.argv[1]);"
                      "from forecast_worker.locking import os_file_lock;"
                      "guard=os_file_lock(Path(sys.argv[2]));guard.__enter__();print('LOCKED '+str(os.getpid()),flush=True);time.sleep(60)")
            child = subprocess.Popen([sys.executable, "-c", script, source, str(path)], stdout=subprocess.PIPE, text=True)
            holder = None
            try:
                proof = child.stdout.readline().strip().split()
                self.assertEqual(proof[0], "LOCKED")
                holder = int(proof[1])
                with self.assertRaises(BlockingIOError):
                    with os_file_lock(path):
                        self.fail("another live process owns the range")
            finally:
                # On Windows venv python.exe may redirect to an owned base-Python
                # descendant. Kill the actual holder proven by our own script.
                if holder is not None:
                    os.kill(holder, signal.SIGTERM)
                else:
                    child.kill()
                child.wait(timeout=10)
                child.stdout.close()
            with os_file_lock(path):
                self.assertTrue(path.exists())

    def test_health_echo_and_cooperative_stop_are_current_run_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            worker = AutoFeed(Path(temporary), continuous=True, config_revision="a" * 64,
                              run_id="12345678-1234-1234-1234-123456789abc")
            worker.heartbeat(status="IDLE")
            health = json.loads((Path(temporary) / "auto-feed-health.json").read_text(encoding="utf-8"))
            self.assertEqual(health["configRevision"], "a" * 64)
            self.assertEqual(health["runId"], worker.run_id)
            self.assertTrue(health["autoUpdateEnabled"])
            import io
            from unittest.mock import patch
            fake_input = type("Input", (), {"buffer": io.BytesIO(b"STOP wrong\nSTOP 12345678-1234-1234-1234-123456789abc\n")})()
            with patch("sys.stdin", fake_input):
                worker._managed_stop_loop()
            self.assertTrue(worker.stop.is_set())
            worker.heartbeat()
            self.assertFalse(json.loads((Path(temporary) / "auto-feed-health.json").read_text(encoding="utf-8"))["autoUpdateEnabled"])

    def test_installer_does_not_inherit_credentials_or_pip_sources(self):
        from unittest.mock import patch
        with patch.dict(os.environ, {"DB_PASSWORD": "never-export", "JWT_SECRET": "never-export",
                                    "PIP_EXTRA_INDEX_URL": "https://invalid.example"}):
            env = prepare.child_environment()
        self.assertNotIn("DB_PASSWORD", env)
        self.assertNotIn("JWT_SECRET", env)
        self.assertNotIn("PIP_EXTRA_INDEX_URL", env)
        if os.name == "nt":
            self.assertEqual(env["SystemDrive"], Path(os.environ["SystemRoot"]).drive)

    def test_payload_inventory_detects_tamper_extra_file_and_network_lock_directive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = {"worker.py", "prepare_runtime.py", "prepare_runtime.ps1", "requirements.lock", "material-benchmarks.json",
                     "forecast_worker/__init__.py", "forecast_worker/cli.py", "forecast_worker/a.py", "forecast_worker/b.py", "wheelhouse/test.whl"}
            for name in names:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("test", encoding="utf-8")
            (root / "requirements.lock").write_text("test==1.0 --hash=sha256:" + "a" * 64 + "\n", encoding="utf-8")
            def manifest():
                inventory = {name: {"bytes": (root / name).stat().st_size, "sha256": hashlib.sha256((root / name).read_bytes()).hexdigest()} for name in names}
                (root / "runtime-manifest.json").write_text(json.dumps({"schemaVersion": 1,
                    "platform": "windows-x86_64" if os.name == "nt" else "linux-x86_64", "pythonVersion": "3.12",
                    "workerVersion": "2.0.0", "lockDigest": prepare.digest(root / "requirements.lock"), "files": inventory}), encoding="utf-8")
            manifest()
            self.assertEqual(prepare.validate(root)["schemaVersion"], 1)
            (root / "worker.py").write_text("tampered", encoding="utf-8")
            with self.assertRaises(ValueError):
                prepare.validate(root)
            manifest()
            (root / "extra.py").write_text("extra", encoding="utf-8")
            with self.assertRaises(ValueError):
                prepare.validate(root)
            (root / "extra.py").unlink()
            (root / "requirements.lock").write_text("--find-links https://invalid.example\n", encoding="utf-8")
            manifest()
            with self.assertRaises(ValueError):
                prepare.validate(root)


if __name__ == "__main__":
    unittest.main()
