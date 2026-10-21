"""Real filesystem coverage of market-state binding to paired backup manifests."""

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

if os.name == "posix":
    import paired_internal_backup as paired


@unittest.skipUnless(os.name == "posix", "paired host backup runs on Linux")
class PairedMarketIntegrationTest(unittest.TestCase):
    def test_derived_state_round_trip_is_bound_to_parent_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            media = root / "media"
            state = media / "material-forecast"
            state.mkdir(parents=True)
            original = b'{"schemaVersion":2,"seriesId":"shfe_cu_main_daily"}'
            (state / "shfe_cu_main_daily.json").write_bytes(original)
            (state / "auto-feed-health.json").write_text(json.dumps({"schemaVersion": 1,
                "workerVersion": "2.0.0", "generatedAt": "2026-10-21T00:00:00Z", "autoUpdateEnabled": True,
                "runId": "12345678-1234-1234-1234-123456789abc", "configRevision": "a" * 64, "series": []}))
            work = root / "paired-set"
            work.mkdir()
            config = paired.Config(media_root=str(media), backup_root=str(root), min_free_bytes=0, min_free_percent=0,
                                   bytes_per_second=1000000000)
            scope = paired.export_market_states(config, work, paired.Budget(config, root))
            self.assertEqual(set(scope), {"internal"})
            for name, value in (("database.dump", b"synthetic-dump-for-integrity-test"), ("objects.jsonl", b""), ("references.jsonl", b"")):
                (work / name).write_bytes(value)
            summary = {"format": "uten-paired-internal-v2", "market_state": scope,
                       "clean_objects": 0, "private_document_references": 0, "media_objects": 0,
                       "stored_bytes": 0, "original_bytes": 0,
                       "database_dump_sha256": paired.digest_file(work / "database.dump"),
                       "objects_manifest_sha256": paired.digest_file(work / "objects.jsonl"),
                       "references_manifest_sha256": paired.digest_file(work / "references.jsonl")}
            (work / "manifest.json").write_text(json.dumps(summary))
            self.assertEqual(paired.verify_set(work)["market_state"], scope)
            restored_media = root / "new-host-media"
            restored_media.mkdir()
            report = paired.restore_market_states(work, restored_media)
            self.assertTrue(report["internal"]["healthReset"])
            restored = restored_media / "material-forecast"
            self.assertEqual((restored / "shfe_cu_main_daily.json").read_bytes(), original)
            health = json.loads((restored / "auto-feed-health.json").read_text())
            self.assertFalse(health["autoUpdateEnabled"])
            self.assertNotIn("runId", health)
            summary["market_state"]["internal"]["manifestSha256"] = "f" * 64
            (work / "manifest.json").write_text(json.dumps(summary))
            with self.assertRaisesRegex(ValueError, "manifest digest/count/bytes"):
                paired.verify_set(work)

    def test_existing_paired_sets_without_market_state_remain_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            paired.verify_market_states(root, {})
            (root / "market-state").mkdir()
            with self.assertRaisesRegex(ValueError, "Unbound"):
                paired.verify_market_states(root, {})


if __name__ == "__main__":
    unittest.main()
