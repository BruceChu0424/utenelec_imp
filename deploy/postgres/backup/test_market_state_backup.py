"""Real temporary state/OS-lock tests; no business database or network access."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import market_state_backup as market

MODULE = Path(__file__).resolve().parent
REPO = MODULE.parents[2]


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")


def wait_file(path, timeout=10):
    end = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= end:
            raise AssertionError("Child process did not reach its test barrier")
        time.sleep(.02)


class MarketStateBackupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-market-backup-test-")
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "live"
        self.source.mkdir()
        self.destination = self.root / "exported"
        self.target = self.root / "restored"
        self.children = []
        payload = {"o_trade_day": "100", "data": [{"price": "80000.25", "unit": "吨"}]}
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False,
                                           separators=(",", ":")).encode()).hexdigest()
        self.raw = self.source / ".auto-feed/raw/2026-10-20" / (digest + ".json")
        write(self.raw, {"sha256": digest, "payload": payload,
                         "firstObservedAt": "2026-10-20T08:00:00Z", "fetchedAt": "2026-10-20T08:00:00Z"})
        write(self.source / ".auto-feed/daily/2026-10-20.json",
              {"date": "2026-10-20", "sha256": digest, "rows": payload["data"]})
        snapshot = {"seriesId": "shfe_cu_main_daily", "schemaVersion": 2,
                    "latestPrice": "80000.25", "status": "RESEARCH_ONLY",
                    "dataAsOf": "2026-10-20", "generatedAt": "2026-10-20T08:00:00Z"}
        write(self.source / "shfe_cu_main_daily.json", snapshot)
        write(self.source / ".auto-feed/issued/shfe_cu_main_daily/prior.json", snapshot)
        write(self.source / ".auto-feed/state.json", {"models": {"shfe_cu_main_daily": {"digest": digest}}})
        write(self.source / "shfe_cu_main_daily.quote.json", {"price": "80001.5", "unit": "吨"})
        write(self.source / ".auto-feed/metadata/download-manifest.json", {"payload": {"version": 1}})
        write(self.source / "auto-feed-health.json", {
            "schemaVersion": 1, "workerVersion": "test", "generatedAt": "2026-10-20T08:00:00Z",
            "autoUpdateEnabled": True, "configRevision": "a" * 64,
            "runId": "01234567-0123-4123-8123-0123456789ab",
            "series": [{"seriesId": "shfe_cu_main_daily", "status": "MODEL",
                        "lastAttemptAt": "2026-10-20T08:00:00Z", "lastSuccessAt": "2026-10-20T08:00:00Z",
                        "nextSyncAt": "2026-10-20T08:15:00Z", "errorCode": None}],
        })

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=10)
        self.temporary.cleanup()

    def child(self, body):
        code = "import sys\nfrom pathlib import Path\nsys.path.insert(0," + repr(str(MODULE)) + ")\nimport market_state_backup as market\n" + body
        child = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, encoding="utf-8")
        self.children.append(child)
        return child

    def exported(self):
        return market.export_market_state(self.source, self.destination)

    def test_complete_hidden_raw_issued_state_and_quotes_round_trip(self):
        summary = self.exported()
        self.assertEqual(summary, market.verify_market_state(self.destination))
        before = {name: (self.source / name).read_bytes()
                  for name, _ in market._inventory(self.source, source=True)}
        result = market.restore_market_state(self.destination, self.target)
        self.assertFalse(result["healthReset"])
        self.assertEqual(summary["manifestSha256"], result["manifestSha256"])
        for name, raw in before.items():
            self.assertEqual(raw, (self.target / name).read_bytes(), name)
        self.assertFalse((self.destination / "auto-feed-health.json").exists())
        self.assertFalse((self.target / "auto-feed-health.json").exists())
        self.assertEqual(b"0", (self.target / ".market-write.lock").read_bytes())

    def test_legacy_v1_health_is_verified_unchanged_and_reset_only_on_restore(self):
        self.exported()
        # Recreate the historical v1 inventory, whose independently trusted hash
        # already binds the heartbeat. Verification must not rewrite that set.
        original_health = (self.source / "auto-feed-health.json").read_bytes()
        (self.destination / "auto-feed-health.json").write_bytes(original_health)
        manifest_path = self.destination / market.MANIFEST
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["records"] = [row for row in manifest["records"] if row["path"] != "auto-feed-health.json"]
        manifest["records"].append({"path": "auto-feed-health.json", "size": len(original_health),
                                    "sha256": hashlib.sha256(original_health).hexdigest()})
        manifest["files"] = len(manifest["records"])
        manifest["bytes"] = sum(row["size"] for row in manifest["records"])
        write(manifest_path, manifest)
        manifest_bytes = manifest_path.read_bytes()
        trusted_digest = hashlib.sha256(manifest_bytes).hexdigest()
        summary = market.verify_market_state(self.destination)
        self.assertEqual(trusted_digest, summary["manifestSha256"])
        result = market.restore_market_state(self.destination, self.target)
        self.assertTrue(result["healthReset"])
        self.assertEqual(trusted_digest, result["manifestSha256"])
        self.assertEqual(manifest_bytes, manifest_path.read_bytes())
        self.assertEqual(original_health, (self.destination / "auto-feed-health.json").read_bytes())
        self.assertEqual(original_health,
                         (self.target / "restore-evidence/auto-feed-health.json").read_bytes())
        restored = json.loads((self.target / "auto-feed-health.json").read_text(encoding="utf-8"))
        self.assertFalse(restored["autoUpdateEnabled"])
        self.assertNotIn("runId", restored)
        self.assertNotIn("configRevision", restored)
        self.assertEqual("IDLE", restored["series"][0]["status"])
        self.assertIsNone(restored["series"][0]["nextSyncAt"])
        self.assertEqual(b"0", (self.target / ".market-write.lock").read_bytes())

    def test_disabled_restore_has_a_fresh_unlocked_barrier_for_the_next_backup(self):
        (self.source / ".market-write.lock").write_bytes(b"old-process-lease")
        self.exported()
        market.restore_market_state(self.destination, self.target)
        barrier = self.target / ".market-write.lock"
        self.assertEqual(b"0", barrier.read_bytes())
        with market.market_state_lock(self.target, timeout=.1): pass
        self.assertFalse((self.target / "auto-feed-health.json").exists())
        second = self.root / "next-backup"
        result = market.export_market_state(self.target, second)
        self.assertEqual(result, market.verify_market_state(second))
        self.assertFalse((second / ".market-write.lock").exists())

    def test_source_inventory_ignores_volatile_files_before_reading_their_metadata(self):
        temporary = self.source / ".auto-feed-health.json.disappeared.tmp"
        temporary.write_bytes(b"in-flight heartbeat")
        original = Path.lstat

        def disappearing(path, *args, **kwargs):
            if path.parent == self.source and path.name in {"auto-feed-health.json", temporary.name}:
                raise FileNotFoundError("volatile heartbeat replaced after directory listing")
            return original(path, *args, **kwargs)

        with patch.object(Path, "lstat", new=disappearing):
            summary = self.exported()
        self.assertEqual(summary, market.verify_market_state(self.destination))
        self.assertFalse((self.destination / "auto-feed-health.json").exists())

    def test_runtime_venv_locks_and_partial_files_are_excluded(self):
        for name in (".venv/Scripts/python.exe", "runtime/secret.env", "wheelhouse/runtime.whl",
                     "__pycache__/worker.pyc", ".auto-feed/collector.lock", "worker.pid", ".snapshot.tmp"):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"never-portable")
        self.exported()
        self.assertFalse(any(b"never-portable" == path.read_bytes() for path in self.destination.rglob("*") if path.is_file()))
        self.assertTrue((self.destination / ".auto-feed/state.json").is_file())

    def test_missing_referenced_raw_revision_cannot_publish_a_success(self):
        self.raw.unlink()
        with self.assertRaisesRegex(ValueError, "missing revision"):
            self.exported()
        self.assertFalse(self.destination.exists())

    def test_missing_model_snapshot_cannot_publish_a_success(self):
        (self.source / "shfe_cu_main_daily.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing snapshot"):
            self.exported()

    def test_raw_revision_digest_is_independently_verified(self):
        revision = json.loads(self.raw.read_text(encoding="utf-8"))
        revision["payload"]["data"][0]["price"] = "1"
        write(self.raw, revision)
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.exported()

    def test_tampering_extra_files_and_missing_files_are_rejected(self):
        self.exported()
        file = self.destination / "shfe_cu_main_daily.quote.json"
        original = file.read_bytes()
        file.write_bytes(original + b" ")
        with self.assertRaises(ValueError): market.verify_market_state(self.destination)
        file.write_bytes(original)
        extra = self.destination / "unlisted.json"
        extra.write_text("{}")
        with self.assertRaises(ValueError): market.verify_market_state(self.destination)
        extra.unlink(); file.unlink()
        with self.assertRaises((ValueError, OSError)): market.verify_market_state(self.destination)

    def test_manifest_paths_cannot_escape_or_alias_a_windows_file(self):
        self.exported()
        manifest = self.destination / market.MANIFEST
        original = json.loads(manifest.read_text(encoding="utf-8"))
        for unsafe in ("../outside", "/outside", "C:/outside", "a\\..\\outside", "a:stream", "NUL.json", "trailing."):
            broken = json.loads(json.dumps(original))
            broken["records"][0]["path"] = unsafe
            write(manifest, broken)
            with self.assertRaises(ValueError, msg=unsafe): market.verify_market_state(self.destination)

    def test_hardlinked_source_is_not_a_secret_export_channel(self):
        private = self.root / "private.bin"
        private.write_bytes(b"not market data")
        os.link(private, self.source / "linked.bin")
        with self.assertRaises(ValueError): self.exported()
        self.assertEqual(b"not market data", private.read_bytes())

    def test_symlinked_source_is_rejected_when_the_os_allows_creating_links(self):
        private = self.root / "outside.bin"
        private.write_bytes(b"outside")
        try:
            os.symlink(private, self.source / "linked.bin")
        except OSError as error:
            self.skipTest("OS did not permit a test symlink: " + str(error.errno))
        with self.assertRaises(ValueError): self.exported()

    def test_export_budget_and_copy_failure_leave_existing_siblings_untouched(self):
        sibling = self.root / "unrelated.txt"
        sibling.write_bytes(b"keep")
        for kwargs in ({"max_files": 1}, {"max_bytes": 1}):
            with self.assertRaises(ValueError):
                market.export_market_state(self.source, self.destination, **kwargs)
        def fail(size):
            if size: raise RuntimeError("test cancellation")
        with self.assertRaises(RuntimeError):
            market.export_market_state(self.source, self.destination, copy_budget=fail)
        self.assertFalse(self.destination.exists())
        self.assertEqual([], list(self.root.glob(".market-state-*")))
        self.assertEqual(b"keep", sibling.read_bytes())

    def test_existing_nonempty_restore_target_and_export_are_never_overwritten(self):
        self.exported()
        self.target.mkdir(); (self.target / "unrelated").write_bytes(b"keep")
        with self.assertRaises(FileExistsError): market.restore_market_state(self.destination, self.target)
        with self.assertRaises(FileExistsError): self.exported()
        self.assertEqual(b"keep", (self.target / "unrelated").read_bytes())
        market.verify_market_state(self.destination)

    def test_failed_restore_does_not_publish_partial_state(self):
        self.exported()
        original = market._copy
        def fail(source, name, target, **kwargs):
            if name.endswith("state.json"): raise OSError("test disk failure")
            return original(source, name, target, **kwargs)
        with patch.object(market, "_copy", side_effect=fail):
            with self.assertRaises(OSError): market.restore_market_state(self.destination, self.target)
        self.assertFalse(self.target.exists())
        self.assertEqual([], list(self.root.glob(".market-state-*")))

    def test_an_existing_empty_target_is_supported(self):
        self.exported(); self.target.mkdir()
        market.restore_market_state(self.destination, self.target)
        self.assertTrue((self.target / "shfe_cu_main_daily.json").exists())

    def test_os_lock_releases_after_the_holding_process_crashes(self):
        ready = self.root / "lock-held"
        child = self.child(f"import time\nwith market.market_state_lock(Path({str(self.source)!r})):\n Path({str(ready)!r}).write_text('ready')\n time.sleep(60)\n")
        wait_file(ready)
        with self.assertRaises(BlockingIOError):
            with market.market_state_lock(self.source, timeout=.1): pass
        child.kill(); child.communicate(timeout=10)
        with market.market_state_lock(self.source, timeout=1): pass

    def test_real_worker_writer_waits_for_a_stable_export_in_another_process(self):
        started, release, writer_started, writer_done = [self.root / name for name in
                                                        ("export-started", "export-release", "writer-started", "writer-done")]
        exporter = self.child(f"""
import time
def gate(size):
 if size and not Path({str(started)!r}).exists():
  Path({str(started)!r}).write_text('ready')
  while not Path({str(release)!r}).exists(): time.sleep(.02)
market.export_market_state(Path({str(self.source)!r}),Path({str(self.destination)!r}),copy_budget=gate)
""")
        wait_file(started)
        writer = self.child(f"""
sys.path.insert(0,{str(REPO / 'services/material_forecast')!r})
from forecast_worker.locking import register_write_barrier, write_barrier
root=Path({str(self.source)!r})
register_write_barrier(root)
Path({str(writer_started)!r}).write_text('waiting')
with write_barrier(root/'new.json'):
 (root/'new.json').write_text('{{"generation":2}}')
Path({str(writer_done)!r}).write_text('done')
""")
        wait_file(writer_started)
        time.sleep(.15)
        self.assertIsNone(writer.poll())
        self.assertFalse(writer_done.exists())
        release.write_text("continue")
        out, error = exporter.communicate(timeout=15)
        self.assertEqual(0, exporter.returncode, error)
        out, error = writer.communicate(timeout=15)
        self.assertEqual(0, writer.returncode, error)
        self.assertTrue((self.source / "new.json").exists())
        self.assertFalse((self.destination / "new.json").exists())
        market.verify_market_state(self.destination)

    @unittest.skipUnless(os.name == "posix", "POSIX ownership and read-only-open contract")
    def test_export_opens_an_existing_barrier_readonly(self):
        self.exported()
        market.restore_market_state(self.destination, self.target)
        original = os.open
        modes = []
        def observe(path, flags, *args, **kwargs):
            if Path(path).name == ".market-write.lock": modes.append(flags)
            return original(path, flags, *args, **kwargs)
        with patch.object(os, "open", side_effect=observe):
            market.export_market_state(self.target, self.root / "readonly-backup")
        self.assertTrue(any((mode & os.O_ACCMODE) == os.O_RDONLY for mode in modes))

    @unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "root POSIX ownership handoff")
    def test_new_barrier_and_restored_tree_inherit_application_owner(self):
        os.chown(self.source, 65534, 65534)
        self.exported()
        info = (self.source / ".market-write.lock").stat()
        self.assertEqual((65534, 65534), (info.st_uid, info.st_gid))
        parent = self.root / "application-storage"; parent.mkdir(); os.chown(parent, 65534, 65534)
        target = parent / "material-forecast"
        market.restore_market_state(self.destination, target)
        for path in [target, *target.rglob("*")]:
            info = path.stat()
            self.assertEqual((65534, 65534), (info.st_uid, info.st_gid), str(path))


if __name__ == "__main__":
    unittest.main()
