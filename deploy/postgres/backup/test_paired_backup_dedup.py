"""Real-file deduplication and independent-set verification; no server or database writes."""
import contextlib
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
import uuid
from datetime import datetime, timezone
from unittest.mock import patch

import paired_internal_backup as paired


class PairedBackupDedupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-paired-dedup-")
        base = Path(os.path.realpath(self.temporary.name))
        self.live, self.root = base / "live", base / "backups"
        self.live.mkdir()
        self.root.mkdir()
        self.data = b"confirmed original workbook bytes" * 20
        self.row = {"source_table": "goods_cost_imports", "id": str(uuid.uuid4()),
                    "storage_provider": "local", "storage_key": uuid.uuid4().hex + ".xlsx",
                    "storage_version": None, "sha256": hashlib.sha256(self.data).hexdigest(),
                    "size_bytes": len(self.data)}
        self.source = self.live / self.row["storage_key"]
        self.source.write_bytes(self.data)
        self.budget = paired.Budget(paired.Config(min_free_bytes=0, min_free_percent=0,
                                                  bytes_per_second=1024**3), self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def make_set(self, day, previous=None, point=True):
        name = f"202610{day:02d}T120000Z-{uuid.uuid4().hex[:12]}"
        directory = self.root / name
        target = paired.media_final(directory / "media", self.row["storage_provider"])
        target.mkdir(parents=True)
        record = paired.copy_object(self.live, target, self.row, self.budget, previous)
        dump = directory / "database.dump"
        dump.write_bytes(b"synthetic dump digest evidence")
        (directory / "objects.jsonl").write_text(json.dumps(record) + "\n", encoding="utf-8")
        (directory / "references.jsonl").write_text(json.dumps(self.row) + "\n", encoding="utf-8")
        summary = {"format": "uten-paired-internal-v2", "set_id": name,
                   "completed_at": f"2026-10-{day:02d}T12:01:00+00:00",
                   "database_dump_sha256": paired.digest_file(dump),
                   "objects_manifest_sha256": paired.digest_file(directory / "objects.jsonl"),
                   "references_manifest_sha256": paired.digest_file(directory / "references.jsonl"),
                   "clean_objects": 0, "private_document_references": 1, "media_objects": 1,
                   "stored_bytes": record["stored_size_bytes"], "original_bytes": len(self.data)}
        (directory / "manifest.json").write_text(json.dumps(summary), encoding="utf-8")
        if point:
            (self.root / "latest-success.json").write_text(json.dumps({"set_id": name,
                "manifest_sha256": paired.digest_file(directory / "manifest.json")}), encoding="utf-8")
        return directory, target / paired.relative_key(self.row["storage_key"]), record

    def previous(self):
        return paired.reusable_objects(self.root, self.budget)[paired.object_identity(self.row)]

    def test_unchanged_objects_share_only_backup_inodes_and_restore_after_old_set_removal(self):
        old, first, _ = self.make_set(3)
        new, second, record = self.make_set(7, self.previous())
        self.assertEqual("HARDLINK", record["backup_copy_mode"])
        self.assertTrue(os.path.samefile(first, second))
        self.assertFalse(os.path.samefile(self.source, second))
        self.assertEqual(1, paired.verify_set(new)["media_objects"])
        shutil.rmtree(old)
        self.assertEqual(self.data, second.read_bytes())
        self.assertEqual(1, paired.verify_set(new)["media_objects"])

    def test_changed_identity_and_corrupt_previous_bytes_are_copied_from_live(self):
        _, first, _ = self.make_set(3)
        previous = self.previous()
        original = paired.object_identity(self.row)
        self.assertNotEqual(original, paired.object_identity({**self.row, "storage_key": uuid.uuid4().hex}))
        self.assertNotEqual(original, paired.object_identity({**self.row, "storage_version": "changed"}))
        self.assertNotEqual(original, paired.object_identity({**self.row, "sha256": "0" * 64}))
        first.write_bytes(b"damaged old set")
        new, second, record = self.make_set(7, previous)
        self.assertEqual("COPY", record["backup_copy_mode"])
        self.assertEqual(self.data, second.read_bytes())
        self.assertFalse(os.path.samefile(first, second))
        paired.verify_set(new)

    def test_corrupt_live_object_cannot_be_hidden_by_a_good_old_backup(self):
        self.make_set(3)
        previous = self.previous()
        self.source.write_bytes(b"damaged live object")
        with self.assertRaises(ValueError):
            self.make_set(7, previous)

    def test_same_internal_key_with_a_new_version_keeps_both_independent_originals(self):
        self.row["storage_provider"] = "internal"
        self.row["storage_key"] = "i1_GOODS_COST_202610_" + uuid.uuid4().hex + ".xlsx"
        self.source = self.live / paired.relative_key(self.row["storage_key"])
        self.source.parent.mkdir(parents=True)

        def write_envelope():
            digest = hashlib.sha256(self.data).hexdigest()
            self.row.update(sha256=digest, size_bytes=len(self.data), storage_version="internal-v1:" + digest)
            self.source.write_bytes(struct.pack(">8sBqq32s", paired.MAGIC, 0, len(self.data), len(self.data),
                                                bytes.fromhex(digest)) + self.data)

        write_envelope()
        old, first, _ = self.make_set(3)
        candidates = paired.reusable_objects(self.root, self.budget)
        old_bytes = first.read_bytes()
        self.data = b"new immutable version of the workbook"
        write_envelope()
        previous = candidates.get(paired.object_identity(self.row))
        self.assertIsNone(previous)
        new, second, record = self.make_set(7, previous)
        self.assertEqual("COPY", record["backup_copy_mode"])
        self.assertEqual(old_bytes, first.read_bytes())
        self.assertFalse(os.path.samefile(first, second))
        paired.verify_set(old)
        paired.verify_set(new)

    def test_a_prior_file_linked_to_live_media_is_never_reused(self):
        _, first, _ = self.make_set(3)
        previous = self.previous()
        first.unlink()
        os.link(self.source, first)
        _, second, record = self.make_set(7, previous)
        self.assertEqual("COPY", record["backup_copy_mode"])
        self.assertFalse(os.path.samefile(self.source, second))

    def test_unsupported_cross_device_link_falls_back_to_an_independent_copy(self):
        _, first, _ = self.make_set(3)
        previous = self.previous()
        with patch.object(paired.os, "link", side_effect=OSError(errno.EXDEV, "different device")):
            new, second, record = self.make_set(7, previous)
        self.assertEqual("COPY", record["backup_copy_mode"])
        self.assertFalse(os.path.samefile(first, second))
        paired.verify_set(new)

    @unittest.skipUnless(os.name == "posix", "POSIX no-follow object links")
    def test_linked_old_object_is_not_followed_and_a_new_independent_copy_is_made(self):
        _, first, _ = self.make_set(3)
        previous = self.previous()
        first.unlink()
        first.symlink_to(self.source)
        new, second, record = self.make_set(7, previous)
        self.assertEqual("COPY", record["backup_copy_mode"])
        self.assertFalse(second.is_symlink())
        self.assertFalse(os.path.samefile(second, self.source))
        self.assertEqual(self.data, self.source.read_bytes())
        paired.verify_set(new)

    def test_unverified_or_changed_manifest_never_supplies_a_reuse_candidate(self):
        old, _, _ = self.make_set(3)
        (old / "objects.jsonl").write_text("{}\n", encoding="utf-8")
        self.assertEqual({}, paired.reusable_objects(self.root, self.budget))
        (self.root / "latest-success.json").write_text(json.dumps({"set_id": "../../live"}), encoding="utf-8")
        self.assertEqual({}, paired.reusable_objects(self.root, self.budget))

    def test_oversized_success_pointer_is_rejected_even_when_its_prefix_is_valid_json(self):
        self.make_set(3)
        pointer = self.root / "latest-success.json"
        pointer.write_bytes(pointer.read_bytes() + b" " * 8192)
        self.assertEqual({}, paired.reusable_objects(self.root, self.budget))

    def test_retention_preserves_linked_new_sets_and_does_not_claim_shared_bytes_freed(self):
        old, first, _ = self.make_set(1)
        previous = self.previous()
        self.make_set(5)
        self.make_set(6)
        new, second, _ = self.make_set(7, previous)
        expected_reclaimed = paired.tree_bytes(old) - len(self.data)
        with contextlib.redirect_stderr(io.StringIO()):
            result = paired.prune_expired_sets(self.root, 3, new.name,
                    datetime(2026, 10, 7, 18, tzinfo=timezone.utc))
        self.assertFalse(old.exists())
        self.assertEqual(expected_reclaimed, result["freed_bytes"])
        self.assertEqual(self.data, second.read_bytes())
        paired.verify_set(new)


if __name__ == "__main__":
    unittest.main()
