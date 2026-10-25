"""Real filesystem coverage of market-state binding to paired backup manifests."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
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
            # New exports exclude the independently replaced live heartbeat.
            # False means no historical heartbeat needed rewriting; the fresh
            # target must not inherit an old process's apparent liveness.
            self.assertFalse(report["internal"]["healthReset"])
            restored = restored_media / "material-forecast"
            self.assertEqual((restored / "shfe_cu_main_daily.json").read_bytes(), original)
            self.assertFalse((work / "market-state/internal/auto-feed-health.json").exists())
            self.assertFalse((restored / "auto-feed-health.json").exists())
            self.assertFalse((restored / "restore-evidence").exists())
            self.assertEqual(b"0", (restored / ".market-write.lock").read_bytes())
            summary["market_state"]["internal"]["manifestSha256"] = "f" * 64
            (work / "manifest.json").write_text(json.dumps(summary))
            with self.assertRaisesRegex(ValueError, "manifest digest/count/bytes"):
                paired.verify_set(work)

    def legacy_set(self, root):
        """Historical v1 inventory, bound to an independently signed parent SHA.

        The generated Ed25519 fixture authenticates the parent manifest anchor;
        no production key, real database or external network is used.
        """
        source = root / "media/material-forecast"
        source.mkdir(parents=True)
        (source / "shfe_cu_main_daily.json").write_text('{"schemaVersion":2,"seriesId":"shfe_cu_main_daily"}')
        health = json.dumps({"schemaVersion": 1, "workerVersion": "test", "autoUpdateEnabled": True,
            "generatedAt": "2026-10-21T00:00:00Z", "runId": "12345678-1234-1234-1234-123456789abc",
            "configRevision": "a" * 64, "pid": 123, "processId": 456,
            "series": [{"seriesId": "shfe_cu_main_daily", "status": "MODEL", "nextSyncAt": "2026-10-21T00:15:00Z"}]}).encode()
        (source / "auto-feed-health.json").write_bytes(health)
        work = root / "paired-set"
        work.mkdir()
        config = paired.Config(media_root=str(source.parent), backup_root=str(root),
            min_free_bytes=0, min_free_percent=0, bytes_per_second=1000000000)
        scope = paired.export_market_states(config, work, paired.Budget(config, root))
        market = paired.market_backup_module()
        exported = work / "market-state/internal"
        # Recreate bytes that the old exporter actually included. The trusted
        # child/parent hashes are fixed before any restore/tamper operation.
        (exported / "auto-feed-health.json").write_bytes(health)
        manifest_path = exported / market.MANIFEST
        manifest = json.loads(manifest_path.read_bytes())
        manifest["records"].append({"path": "auto-feed-health.json", "size": len(health),
            "sha256": hashlib.sha256(health).hexdigest()})
        manifest["records"].sort(key=lambda row: row["path"])
        manifest["files"] = len(manifest["records"])
        manifest["bytes"] = sum(row["size"] for row in manifest["records"])
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        scope["internal"] = market.verify_market_state(exported)
        for name, raw in (("database.dump", b"synthetic-dump"), ("objects.jsonl", b""), ("references.jsonl", b"")):
            (work / name).write_bytes(raw)
        summary = {"format": "uten-paired-internal-v2", "market_state": scope,
            "clean_objects": 0, "private_document_references": 0, "media_objects": 0,
            "stored_bytes": 0, "original_bytes": 0,
            "database_dump_sha256": paired.digest_file(work / "database.dump"),
            "objects_manifest_sha256": paired.digest_file(work / "objects.jsonl"),
            "references_manifest_sha256": paired.digest_file(work / "references.jsonl")}
        (work / "manifest.json").write_text(json.dumps(summary), encoding="utf-8")
        anchor = json.dumps({"sourceManifestSha256": paired.digest_file(work / "manifest.json")},
            sort_keys=True, separators=(",", ":")).encode()
        (root / "parent-anchor.json").write_bytes(anchor)
        key = root / "synthetic-signing-key"
        subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
            check=True, capture_output=True, timeout=15)
        allowed = root / "allowed-signers"
        allowed.write_text('uten-backup-source namespaces="uten-dr-snapshot-v1" ' + key.with_suffix(".pub").read_text())
        signature = subprocess.run(["/usr/bin/ssh-keygen", "-Y", "sign", "-n", "uten-dr-snapshot-v1", "-f", str(key)],
            input=anchor, check=True, capture_output=True, timeout=15)
        (root / "parent-anchor.sshsig").write_bytes(signature.stdout)
        return work, health, scope

    def verify_parent_anchor(self, root, work):
        anchor = (root / "parent-anchor.json").read_bytes()
        self.assertEqual(json.loads(anchor)["sourceManifestSha256"], paired.digest_file(work / "manifest.json"))
        subprocess.run(["/usr/bin/ssh-keygen", "-Y", "verify", "-f", str(root / "allowed-signers"),
            "-I", "uten-backup-source", "-n", "uten-dr-snapshot-v1", "-s", str(root / "parent-anchor.sshsig")],
            input=anchor, check=True, capture_output=True, timeout=15)

    def test_signed_legacy_health_keeps_trusted_bytes_and_resets_only_restored_live_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            work, original_health, scope = self.legacy_set(root)
            exported = work / "market-state/internal"
            market = paired.market_backup_module()
            parent_bytes = (work / "manifest.json").read_bytes()
            child_bytes = (exported / market.MANIFEST).read_bytes()
            self.verify_parent_anchor(root, work)
            self.assertEqual(scope, paired.verify_set(work)["market_state"])
            target = root / "restored-media"
            target.mkdir()
            report = paired.restore_market_states(work, target)
            self.assertTrue(report["internal"]["healthReset"])
            restored = target / "material-forecast"
            self.assertEqual(original_health, (restored / "restore-evidence/auto-feed-health.json").read_bytes())
            health = json.loads((restored / "auto-feed-health.json").read_bytes())
            self.assertFalse(health["autoUpdateEnabled"])
            for field in ("runId", "configRevision", "pid", "processId"):
                self.assertNotIn(field, health)
            self.assertEqual("IDLE", health["series"][0]["status"])
            self.assertIsNone(health["series"][0]["nextSyncAt"])
            self.assertEqual(b"0", (restored / ".market-write.lock").read_bytes())
            with market.market_state_lock(restored, timeout=.1):
                pass
            self.assertEqual(original_health, (exported / "auto-feed-health.json").read_bytes())
            self.assertEqual(child_bytes, (exported / market.MANIFEST).read_bytes())
            self.assertEqual(parent_bytes, (work / "manifest.json").read_bytes())
            self.verify_parent_anchor(root, work)

    def test_signed_legacy_health_tamper_or_missing_file_blocks_before_target_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            work, original_health, _ = self.legacy_set(root)
            target = root / "target-media"
            restored = target / "material-forecast"
            restored.mkdir(parents=True)
            (restored / "keep-existing").write_bytes(b"KEEP TARGET")
            health = work / "market-state/internal/auto-feed-health.json"
            for missing in (False, True):
                with self.subTest(missing=missing):
                    if missing:
                        health.unlink()
                    else:
                        changed = original_health.replace(b'"workerVersion": "test"', b'"workerVersion": "evil"')
                        self.assertEqual(len(original_health), len(changed))
                        self.assertNotEqual(original_health, changed)
                        health.write_bytes(changed)
                    self.verify_parent_anchor(root, work)  # Signature still binds the unchanged parent.
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        paired.verify_set(work)
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        paired.restore_market_states(work, target)
                    self.assertEqual(["keep-existing"], [path.name for path in restored.iterdir()])
                    self.assertEqual(b"KEEP TARGET", (restored / "keep-existing").read_bytes())
                    health.write_bytes(original_health)

    def test_existing_paired_sets_without_market_state_remain_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            paired.verify_market_states(root, {})
            (root / "market-state").mkdir()
            with self.assertRaisesRegex(ValueError, "Unbound"):
                paired.verify_market_states(root, {})


if __name__ == "__main__":
    unittest.main()
