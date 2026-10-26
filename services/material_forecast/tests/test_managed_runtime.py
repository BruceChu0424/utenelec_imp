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
import time
import unittest
from datetime import datetime, timedelta, timezone

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
    def test_idle_collector_does_not_load_forecasting_libraries(self):
        script = (
            "import json,sys;sys.path.insert(0,sys.argv[1]);"
            "import forecast_worker.autofeed;"
            "print(json.dumps([name for name in "
            "('forecast_worker.engine','statsforecast','pandas','numpy') if name in sys.modules]))")
        result = subprocess.run([sys.executable, "-I", "-c", script, str(PREPARE.parent)],
                                capture_output=True, text=True, timeout=60,
                                env=prepare.child_environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [],
                         "idle collection and heartbeat must not initialize model libraries")

    def test_empty_and_cached_history_do_not_initialize_the_model_engine(self):
        script = """
import hashlib, json, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from forecast_worker.autofeed import AutoFeed
with tempfile.TemporaryDirectory() as temporary:
    now = datetime(2026, 10, 25, tzinfo=timezone.utc)
    worker = AutoFeed(Path(temporary), now=lambda: now)
    assert worker.publish_models([]) == {}
    indices = [{'date': day, 'tradeSequence': index + 1, 'sha256': str(index) * 64,
        'rows': [{'contract': symbol + '2611', 'settlement': '100', 'open_interest': '100'}
                 for symbol in ('cu', 'al', 'ag')]}
        for index, day in enumerate(('2026-10-19', '2026-10-20'))]
    digest = hashlib.sha256(json.dumps([(item['date'], item['sha256']) for item in indices]).encode()).hexdigest()
    expected = {}
    for benchmark in worker.benchmarks:
        series = benchmark['seriesId']
        expected[series] = benchmark['symbol'] + '2611'
        worker.state.setdefault('models', {})[series] = {'digest': digest,
            'generatedAt': '2026-10-25T00:00:00Z'}
        (worker.output / (series + '.json')).write_text('{}')
    assert worker.publish_models(indices) == expected
    assert all((worker.output / (series + '.json')).read_text() == '{}' for series in expected)
    print(json.dumps([name for name in ('forecast_worker.automatic_engine',
        'forecast_worker.engine', 'statsforecast', 'pandas', 'numpy') if name in sys.modules]))
"""
        result = subprocess.run([sys.executable, "-I", "-c", script, str(PREPARE.parent)],
                                capture_output=True, text=True, timeout=60,
                                env=prepare.child_environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_heartbeat_remains_fresh_while_a_real_backup_blocks_persistent_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, exported = root / "live", root / "exported"
            source.mkdir()
            (source / "snapshot.json").write_text('{"generation":1}', encoding="utf-8")
            clock = [datetime(2026, 10, 25, tzinfo=timezone.utc)]
            worker = AutoFeed(source, now=lambda: clock[0], continuous=True,
                              config_revision="a" * 64,
                              run_id="12345678-1234-1234-1234-123456789abc")
            worker.heartbeat(status="IDLE")
            backup_module = PREPARE.parents[2] / "deploy/postgres/backup"
            started, release, writer_started, writer_done = [root / name for name in
                ("backup-started", "backup-release", "writer-started", "writer-done")]
            exporter_script = f"""
import json, sys, time
from pathlib import Path
sys.path.insert(0, {str(backup_module)!r})
import market_state_backup as market
def gate(size):
    if size and not Path({str(started)!r}).exists():
        Path({str(started)!r}).write_text('locked')
        deadline = time.monotonic() + 30
        while not Path({str(release)!r}).exists():
            if time.monotonic() >= deadline: raise TimeoutError('backup test barrier')
            time.sleep(.02)
print(json.dumps(market.export_market_state(Path({str(source)!r}), Path({str(exported)!r}), copy_budget=gate)))
"""
            writer_script = f"""
import sys
from pathlib import Path
sys.path.insert(0, {str(PREPARE.parent)!r})
from forecast_worker.cli import atomic_json
from forecast_worker.locking import register_write_barrier
root = Path({str(source)!r})
register_write_barrier(root)
Path({str(writer_started)!r}).write_text('waiting')
atomic_json(root / 'snapshot.json', {{'generation': 2}}, public=True)
Path({str(writer_done)!r}).write_text('done')
"""
            children = []
            heartbeat = None

            def start(script):
                child = subprocess.Popen([sys.executable, "-I", "-c", script],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                         text=True, encoding="utf-8", env=prepare.child_environment())
                children.append(child)
                return child

            def wait_for(path, child):
                deadline = time.monotonic() + 20
                while not path.exists():
                    if child.poll() is not None:
                        self.fail(child.communicate(timeout=5)[1])
                    if time.monotonic() >= deadline:
                        self.fail("child did not reach its real lock barrier")
                    time.sleep(.02)

            try:
                exporter = start(exporter_script)
                wait_for(started, exporter)
                writer = start(writer_script)
                wait_for(writer_started, writer)
                clock[0] += timedelta(seconds=30)
                heartbeat = threading.Thread(target=lambda: worker.heartbeat(status="MODEL"), daemon=True)
                heartbeat.start()
                heartbeat.join(timeout=2)
                self.assertFalse(heartbeat.is_alive(), "a durable backup barrier blocked the volatile heartbeat")
                health = json.loads((source / "auto-feed-health.json").read_text(encoding="utf-8"))
                self.assertEqual("2026-10-25T00:00:30Z", health["generatedAt"])
                self.assertEqual(worker.run_id, health["runId"])
                self.assertEqual(worker.config_revision, health["configRevision"])
                self.assertTrue(health["autoUpdateEnabled"])
                self.assertTrue(all(item["status"] == "MODEL" for item in health["series"]))
                self.assertIsNone(writer.poll())
                self.assertFalse(writer_done.exists(), "the persistent writer bypassed snapshot consistency")
                self.assertEqual({"generation": 1}, json.loads((source / "snapshot.json").read_text()))
                release.write_text("continue")
                output, error = exporter.communicate(timeout=15)
                self.assertEqual(0, exporter.returncode, error)
                _, error = writer.communicate(timeout=15)
                self.assertEqual(0, writer.returncode, error)
                summary = json.loads(output)
                spec = importlib.util.spec_from_file_location("heartbeat_backup_verifier", backup_module / "market_state_backup.py")
                backup = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(backup)
                self.assertEqual(summary, backup.verify_market_state(exported))
                self.assertEqual({"generation": 1}, json.loads((exported / "snapshot.json").read_text()))
                self.assertEqual({"generation": 2}, json.loads((source / "snapshot.json").read_text()))
                self.assertFalse((exported / "auto-feed-health.json").exists())
            finally:
                release.write_text("continue")
                if heartbeat is not None:
                    heartbeat.join(timeout=5)
                for child in children:
                    try:
                        child.communicate(timeout=15)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.communicate(timeout=10)

    def test_real_managed_process_stops_and_releases_lease_when_owner_pipe_closes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = (
                "import sys,os;from pathlib import Path;sys.path.insert(0,sys.argv[1]);"
                "from forecast_worker.autofeed import AutoFeed\n"
                "class Offline(AutoFeed):\n"
                " def run_cycle(self):\n"
                "  self.heartbeat(status='IDLE');print('READY '+str(os.getpid()),flush=True);return True\n"
                "worker=Offline(Path(sys.argv[2]),continuous=True,config_revision='a'*64,"
                "run_id='12345678-1234-1234-1234-123456789abc');sys.exit(worker.run())")
            child = subprocess.Popen([sys.executable,"-I","-c",script,str(PREPARE.parent),str(root)],
                                     stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                                     env=prepare.child_environment())
            holder = None
            try:
                ready = child.stdout.readline().strip().split()
                self.assertEqual(ready[0],"READY")
                holder = int(ready[1])
                with self.assertRaises(BlockingIOError):
                    with os_file_lock(root / ".auto-feed/collector.lock"):
                        self.fail("controlled cycle must own the real collector lease")
                child.stdin.close()
                child.stdin = None
                stdout,stderr = child.communicate(timeout=15)
                self.assertEqual(child.returncode,0,stderr)
                with os_file_lock(root / ".auto-feed/collector.lock"):
                    pass
                health=json.loads((root / "auto-feed-health.json").read_text(encoding="utf-8"))
                self.assertFalse(health["autoUpdateEnabled"])
            finally:
                if child.poll() is None:
                    if holder is not None:
                        os.kill(holder,signal.SIGTERM)
                    child.kill()
                    child.wait(timeout=10)
                for stream in (child.stdin,child.stdout,child.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()

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
            for name in ("requirements.txt", "requirements.runtime.txt"):
                shutil.copyfile(PREPARE.parent / name, root / name)
            for target in builder.TARGETS:
                shutil.copyfile(PREPARE.parent / "runtime-locks" / (target + ".lock"),
                                root / "runtime-locks" / (target + ".lock"))
            builder.validate_requirement_versions(root)
            exported = root / "requirements.runtime.txt"
            original = exported.read_text()
            exported.write_text(original.replace("numpy==2.2.6", "numpy==2.2.5"))
            with self.assertRaisesRegex(ValueError, "authoritative requirements.txt"):
                builder.validate_requirement_versions(root)
            exported.write_text(original)
            platform_lock = root / "runtime-locks/windows-x86_64.lock"
            platform_lock.write_text(platform_lock.read_text().replace("numpy==2.2.6", "numpy==2.2.5"))
            with self.assertRaisesRegex(ValueError, "differs from authority"):
                builder.validate_requirement_versions(root)
            with self.assertRaisesRegex(ValueError, "unhashed lock refresh is forbidden"):
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
            cache = root / "cache"
            cache.mkdir()
            key = cache / (("w-" if os.name == "nt" else "l-") + "a" * 24)
            key.mkdir()
            with patch.object(prepare, "validate", return_value=manifest), patch.object(prepare.venv.EnvBuilder, "create", side_effect=RuntimeError("interrupted-after-marker")):
                with self.assertRaisesRegex(RuntimeError, "interrupted-after-marker"):
                    prepare.prepare(root / "payload", cache)
            self.assertTrue((key / "managed.json").is_file())
            (key / "managed.json").unlink()
            (key / "unknown-user-file").write_text("preserve", encoding="utf-8")
            with patch.object(prepare, "validate", return_value=manifest):
                with self.assertRaisesRegex(ValueError, "unrecognized incomplete"):
                    prepare.prepare(root / "payload", cache)
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
        spec = importlib.util.spec_from_file_location("strict_runtime_fixtures",
            PREPARE.parents[2] / "deploy/release/test_material_forecast_payload.py")
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        target = "windows-x86_64" if os.name == "nt" else "linux-x86_64"
        with tempfile.TemporaryDirectory() as temporary:
            root = fixtures.build_fixture_payload(Path(temporary) / "payload", target=target)
            self.assertEqual(prepare.validate(root)["schemaVersion"], 1)
            source = root / "worker.py"
            original = source.read_bytes()
            source.write_bytes(original + b"tampered")
            with self.assertRaises(ValueError):
                prepare.validate(root)
            source.write_bytes(original)
            (root / "extra.py").write_text("extra", encoding="utf-8")
            with self.assertRaises(ValueError):
                prepare.validate(root)
            (root / "extra.py").unlink()
            (root / "runtime-requirements.txt").write_text("--find-links https://invalid.example\n")
            # Even an internally rehashed manifest cannot grant a network directive.
            manifest = json.loads((root / "release.json").read_text())
            for item in manifest["files"]:
                if item["path"] == "runtime-requirements.txt":
                    item.update(size=(root / item["path"]).stat().st_size,
                                sha256=prepare.digest(root / item["path"]))
            (root / "release.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "runtime requirements"):
                prepare.validate(root)
            (root / "release.json").write_text("[]")
            with self.assertRaisesRegex(ValueError, "manifest must be an object"):
                prepare.validate(root)

    def test_installer_refuses_payload_local_cache_and_linked_install_lock(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(prepare, "validate", return_value={}):
                with self.assertRaisesRegex(ValueError, "private directory"):
                    prepare.prepare(root, root / "cache")
            outside = root / "outside"
            outside.write_text("owned fixture")
            lock = root / "install.lock"
            os.link(outside, lock)
            with self.assertRaisesRegex(ValueError, "lock is unsafe"):
                with prepare.install_lock(lock):
                    self.fail("linked lock accepted")
            self.assertEqual(outside.read_text(), "owned fixture")


if __name__ == "__main__":
    unittest.main()
