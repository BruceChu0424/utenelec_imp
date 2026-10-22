"""Real Linux filesystem, Java lock interoperability, and paired cold restore."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

import client_release_state_backup as client
import paired_internal_backup as paired

ID = "12345678-1234-1234-1234-123456789abc"
OTHER = "22345678-1234-1234-1234-123456789abc"


@unittest.skipUnless(os.name == "posix", "the paired host uses Linux POSIX record locks")
class ClientReleaseStateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "catalog"
        self.source.mkdir()
        (self.source / ".catalog.lock").touch()
        self.destination = self.root / "export"
        self.target = self.root / "restored"

    def release(self, identifier=ID, *, state="PUBLISHED", mode="windows_archive", data=b"real package bytes", uploaded=True):
        folder = self.source / identifier
        folder.mkdir(exist_ok=True)
        digest = hashlib.sha256(data).hexdigest() if mode != "store" else None
        value = {"id": identifier, "platform": "windows", "architecture": "x64", "version": "2.5.28",
                 "buildNumber": 2528, "state": state, "installMode": mode,
                 "expectedSha256": digest, "sha256": digest if uploaded else None,
                 "sizeBytes": len(data) if uploaded and mode != "store" else 0,
                 "releaseNotes": "Recover metadata and its exact package together"}
        if uploaded and mode != "store":
            (folder / "package.bin").write_bytes(data)
        (folder / "release.json").write_text(json.dumps(value), encoding="utf-8")
        return value

    def test_committed_package_and_metadata_round_trip_and_ignore_upload_work(self):
        self.release()
        folder = self.source / ID
        (folder / ".upload-12345678-1234-1234-1234-123456789abc.tmp").write_bytes(b"incomplete upload")
        (folder / ".metadata-12345678-1234-1234-1234-123456789abc.tmp").write_bytes(b"not committed")
        raw = (folder / "release.json").read_bytes()
        summary = client.export_client_releases(self.source, self.destination)
        self.assertEqual((1, 2), (summary["releases"], summary["files"]))
        self.assertEqual(summary, client.verify_client_releases(self.destination))
        self.assertEqual(summary, client.restore_client_releases(self.destination, self.target))
        self.assertEqual(raw, (self.target / ID / "release.json").read_bytes())
        self.assertEqual(b"real package bytes", (self.target / ID / "package.bin").read_bytes())
        self.assertEqual({ID, ".catalog.lock"}, {p.name for p in self.target.iterdir()})
        self.assertEqual({"release.json", "package.bin"}, {p.name for p in (self.target / ID).iterdir()})
        self.assertEqual(0, (self.target / ".catalog.lock").stat().st_size)
        self.assertEqual(0o600, (self.target / ID / "release.json").stat().st_mode & 0o777)
        self.assertEqual(summary["files"], client.export_client_releases(self.target, self.root / "cold-reexport")["files"])

    def test_draft_and_store_and_withdrawn_records_keep_their_distinct_contracts(self):
        self.release(state="DRAFT", uploaded=False)
        self.release(OTHER, state="WITHDRAWN")
        store = "32345678-1234-1234-1234-123456789abc"
        self.release(store, mode="store")
        summary = client.export_client_releases(self.source, self.destination)
        self.assertEqual((3, 4), (summary["releases"], summary["files"]))
        client.restore_client_releases(self.destination, self.target)
        self.assertFalse((self.target / ID / "package.bin").exists())
        self.assertFalse((self.target / store / "package.bin").exists())
        self.assertEqual("WITHDRAWN", json.loads((self.target / OTHER / "release.json").read_text())["state"])

    def test_uncommitted_draft_binary_does_not_become_an_uploaded_restored_pair(self):
        self.release(state="DRAFT", uploaded=False)
        (self.source / ID / "package.bin").write_bytes(b"crash before metadata commit")
        self.assertEqual(1, client.export_client_releases(self.source, self.destination)["files"])
        client.restore_client_releases(self.destination, self.target)
        self.assertFalse((self.target / ID / "package.bin").exists())

    def test_published_missing_package_or_wrong_digest_fails_without_publishing_backup(self):
        self.release()
        package = self.source / ID / "package.bin"
        for data in [None, b"corrupt package bytes"]:
            with self.subTest(data=data):
                if data is None:package.unlink()
                else:package.write_bytes(data)
                with self.assertRaisesRegex(ValueError, "missing|integrity"):
                    client.export_client_releases(self.source, self.destination)
                self.assertFalse(self.destination.exists())
                self.assertEqual([], list(self.root.glob(".market-state-*")))

    def test_published_metadata_without_commit_hash_is_not_a_recoverable_release(self):
        self.release(uploaded=False)
        with self.assertRaisesRegex(ValueError, "no committed package"):
            client.export_client_releases(self.source, self.destination)

    def test_duplicate_json_identity_and_oversized_metadata_are_rejected(self):
        self.release()
        metadata = self.source / ID / "release.json"
        for payload in [b'{"id":"one","id":"two"}', b" " * (client.MAX_METADATA_BYTES + 1)]:
            with self.subTest(size=len(payload)):
                metadata.write_bytes(payload)
                with self.assertRaises(ValueError):client.export_client_releases(self.source, self.destination)

    def test_links_and_hardlinks_cannot_escape_the_catalog(self):
        self.release()
        package = self.source / ID / "package.bin"
        outside = self.root / "private-outside.bin"
        outside.write_bytes(package.read_bytes())
        for hard in [False, True]:
            with self.subTest(hard=hard):
                package.unlink()
                os.link(outside, package) if hard else package.symlink_to(outside)
                with self.assertRaises(ValueError):client.export_client_releases(self.source, self.destination)

    def test_missing_or_linked_writer_barrier_fails_closed(self):
        self.release()
        barrier = self.source / ".catalog.lock"
        barrier.unlink()
        with self.assertRaises(FileNotFoundError):client.export_client_releases(self.source, self.destination)
        other = self.root / "foreign-lock"
        other.touch()
        barrier.symlink_to(other)
        with self.assertRaises(ValueError):client.export_client_releases(self.source, self.destination)

    def test_budget_failure_keeps_previous_destination_and_cleans_private_stage(self):
        self.release()
        calls = []
        def exhausted(count):
            calls.append(count)
            if count:raise TimeoutError("isolated byte/time budget exhausted")
        with self.assertRaises(TimeoutError):client.export_client_releases(self.source, self.destination, copy_budget=exhausted)
        self.assertTrue(calls)
        self.assertFalse(self.destination.exists())
        self.assertEqual([], list(self.root.glob(".market-state-*")))

    def test_tamper_extra_inventory_and_traversal_never_verify(self):
        self.release()
        client.export_client_releases(self.source, self.destination)
        package = self.destination / ID / "package.bin"
        original = package.read_bytes()
        package.write_bytes(b"tampered")
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)
        package.write_bytes(original)
        extra = self.destination / ID / "unexpected.bin"
        extra.write_bytes(b"must not disappear from verification")
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)
        extra.unlink()
        empty = self.destination / OTHER
        empty.mkdir()
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)
        empty.rmdir()
        path = self.destination / client.MANIFEST
        manifest = json.loads(path.read_text())
        manifest["records"][0]["path"] = "../outside"
        path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):client.verify_client_releases(self.destination)

    def test_restore_refuses_existing_data_and_preserves_it(self):
        self.release()
        client.export_client_releases(self.source, self.destination)
        self.target.mkdir()
        (self.target / "keep.bin").write_bytes(b"preserve")
        with self.assertRaises(FileExistsError):client.restore_client_releases(self.destination, self.target)
        self.assertEqual(b"preserve", (self.target / "keep.bin").read_bytes())

    @unittest.skipUnless(shutil.which("java"), "Java launcher required for cross-language lock proof")
    def test_java_filechannel_exclusive_lock_blocks_shared_backup_lock(self):
        self.release()
        source = self.root / "CatalogWriter.java"
        source.write_text('''import java.nio.channels.*; import java.nio.file.*;
class CatalogWriter { public static void main(String[] a) throws Exception {
try (var c=FileChannel.open(Path.of(a[0]),StandardOpenOption.WRITE); var l=c.lock()) {
Files.writeString(Path.of(a[1]),"ready");
while(!Files.exists(Path.of(a[2]))) Thread.sleep(20);
}}}''')
        ready, release = self.root / "java-ready", self.root / "java-release"
        writer = subprocess.Popen([shutil.which("java"), str(source), str(self.source / ".catalog.lock"), str(ready), str(release)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 20
            while not ready.exists():
                if writer.poll() is not None or time.monotonic() > deadline:
                    self.fail("Isolated Java writer did not acquire its FileChannel lock")
                time.sleep(.05)
            with self.assertRaises(BlockingIOError):
                with client.catalog_lock(self.source, timeout=.15):self.fail("Java lock was bypassed")
            release.touch()
            stdout, stderr = writer.communicate(timeout=10)
            self.assertEqual(0, writer.returncode, stderr.decode(errors="replace"))
            self.assertEqual(2, client.export_client_releases(self.source, self.destination)["files"])
        finally:
            if writer.poll() is None:writer.kill(); writer.communicate(timeout=5)

    def make_pair(self, *, configured=False):
        self.release()
        media = self.root / "media"
        media.mkdir()
        if not configured:
            self.source.rename(media / "client-releases")
        work = self.root / "paired"
        work.mkdir()
        config = paired.Config(media_root=str(media), backup_root=str(self.root),
                               client_releases_root=str(self.source) if configured else None,
                               min_free_bytes=0, min_free_percent=0, bytes_per_second=10**9)
        scope = paired.export_client_release_states(config, work, paired.Budget(config, self.root))
        for name, raw in [("database.dump", b"isolated logical dump fixture"), ("objects.jsonl", b""), ("references.jsonl", b"")]:
            (work / name).write_bytes(raw)
        summary = {"format": "uten-paired-internal-v2", "client_release_state": scope,
                   "clean_objects": 0, "private_document_references": 0, "media_objects": 0, "stored_bytes": 0, "original_bytes": 0,
                   "database_dump_sha256": paired.digest_file(work / "database.dump"),
                   "objects_manifest_sha256": paired.digest_file(work / "objects.jsonl"),
                   "references_manifest_sha256": paired.digest_file(work / "references.jsonl")}
        (work / "manifest.json").write_text(json.dumps(summary))
        return work, summary

    def test_full_pair_verifies_and_cold_restores_bound_catalog_namespace(self):
        work, summary = self.make_pair()
        self.assertEqual(summary, paired.verify_set(work))
        target = self.root / "empty-new-media"
        target.mkdir()
        report = paired.restore_client_release_states(work, target)
        self.assertEqual(summary["client_release_state"]["internal"], report["internal"])
        self.assertEqual(b"real package bytes", (target / "client-releases" / ID / "package.bin").read_bytes())
        summary["client_release_state"]["internal"]["manifestSha256"] = "f" * 64
        (work / "manifest.json").write_text(json.dumps(summary))
        with self.assertRaisesRegex(ValueError, "manifest digest/count/bytes"):
            paired.verify_set(work)

    def test_custom_directory_requires_explicit_restore_target(self):
        work, _ = self.make_pair(configured=True)
        target = self.root / "new-media"
        target.mkdir()
        with self.assertRaisesRegex(ValueError, "explicit target"):
            paired.restore_client_release_states(work, target)
        restored = self.root / "configured-restored"
        paired.restore_client_release_states(work, target, client_releases_root=restored)
        self.assertTrue((restored / ID / "release.json").exists())

    def test_legacy_database_format_cannot_bypass_client_catalog_verification(self):
        work, summary = self.make_pair()
        (work / "media" / "final").mkdir(parents=True)
        summary["format"] = "uten-paired-internal-v1"
        (work / "manifest.json").write_text(json.dumps(summary))
        self.assertEqual("uten-paired-internal-v1", paired.verify_set(work)["format"])
        (work / "client-release-state" / "internal" / ID / "package.bin").write_bytes(b"corrupt legacy-labelled set")
        with self.assertRaisesRegex(ValueError, "integrity"):
            paired.verify_set(work)

    def test_old_paired_sets_remain_valid_but_unbound_client_bytes_are_rejected(self):
        paired.verify_client_release_states(self.root, {})
        (self.root / "client-release-state").mkdir()
        with self.assertRaisesRegex(ValueError, "Unbound"):
            paired.verify_client_release_states(self.root, {})


if __name__ == "__main__":unittest.main()
