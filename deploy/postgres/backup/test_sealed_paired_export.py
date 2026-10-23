"""Synthetic-file export tests, including real GPG encrypt/decrypt; no production access."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import uuid
from unittest.mock import patch

import sealed_paired_export as sealed


@unittest.skipUnless(os.name == "posix" and hasattr(os, "memfd_create") and Path(sealed.GPG).is_file(),
                     "Real export verification needs Linux/GnuPG")
class SealedPairedExportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory(prefix="uten-test-export-keys-")
        cls.home = Path(cls.keys.name)
        cls.home.chmod(0o700)
        subprocess.run([sealed.GPG, "--no-options", "--batch", "--homedir", str(cls.home),
            "--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key",
            "Synthetic Uten Export Test", "rsa2048", "encr", "1d"], check=True, capture_output=True)
        listing = subprocess.check_output([sealed.GPG, "--batch", "--homedir", str(cls.home),
                                            "--with-colons", "--list-keys"], stderr=subprocess.DEVNULL)
        cls.fingerprint = next(line.split(":")[9] for line in listing.decode().splitlines()
                               if line.startswith("fpr:"))
        cls.public = subprocess.check_output([sealed.GPG, "--batch", "--homedir", str(cls.home),
                                              "--armor", "--export", cls.fingerprint])

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--homedir", str(cls.home), "--kill", "gpg-agent"],
                       capture_output=True)
        cls.keys.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-test-sealed-")
        self.base = Path(self.temporary.name)
        self.base.chmod(0o700)
        self.root, self.output, self.recovery = (self.base / x for x in ("paired", "output", "recovery"))
        for directory in (self.root, self.output, self.recovery):
            directory.mkdir(mode=0o700)
        (self.root / ".backup.lock").touch(mode=0o600)
        self.set_id = "20261023T010203Z-123456789abc"
        self.set = self.root / self.set_id
        self.set.mkdir(mode=0o700)
        for name, value in (("database.dump", b"SYNTHETIC DATABASE BYTES"),
                            ("objects.jsonl", b""), ("references.jsonl", b"")):
            (self.set / name).write_bytes(value)
        self.manifest = {"format": "uten-paired-internal-v2", "set_id": self.set_id,
            "database_dump_sha256": sealed.sha256(self.set / "database.dump"),
            "objects_manifest_sha256": sealed.sha256(self.set / "objects.jsonl"),
            "references_manifest_sha256": sealed.sha256(self.set / "references.jsonl"),
            "clean_objects": 0, "private_document_references": 0, "media_objects": 0,
            "stored_bytes": 0, "original_bytes": 0}
        self.write_manifest()
        self.secret = self.recovery / sealed.REQUIRED_RECOVERY
        self.secret.parent.mkdir(parents=True, mode=0o700)
        self.secret.write_bytes(b"UTEN_PII_KEY=SYNTHETIC_RECOVERY_SECRET\n")
        self.secret.chmod(0o640)
        self.tools = self.base / "tools"
        self.tools.mkdir(mode=0o700)
        for name in sealed.HELPERS:
            shutil.copyfile(Path(__file__).with_name(name), self.tools / name)
            (self.tools / name).chmod(0o600)
        self.helper = self.tools / sealed.HELPERS[0]

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self):
        (self.set / "manifest.json").write_text(json.dumps(self.manifest))
        (self.root / "latest-success.json").write_text(json.dumps({"set_id": self.set_id,
            "manifest_sha256": sealed.sha256(self.set / "manifest.json")}))

    def run_export(self, **overrides):
        arguments = dict(root=self.root, output=self.output, public_key=self.public,
            fingerprint=self.fingerprint, recovery_names=[sealed.REQUIRED_RECOVERY],
            helper=self.helper, recovery_root=self.recovery)
        arguments.update(overrides)
        return sealed.export(**arguments)

    def decrypt(self, path):
        return subprocess.check_output([sealed.GPG, "--batch", "--homedir", str(self.home),
                                        "--decrypt", str(path)], stderr=subprocess.DEVNULL)

    def assert_no_published_export(self):
        self.assertEqual([], list(self.output.iterdir()))

    def test_real_ciphertext_round_trip_contains_verified_allowlist_and_crypto_recovery(self):
        final, receipt = self.run_export()
        self.assertEqual({"archive.gpg", "receipt.json"}, {p.name for p in final.iterdir()})
        cipher = (final / "archive.gpg").read_bytes()
        self.assertNotIn(b"SYNTHETIC DATABASE", cipher)
        self.assertNotIn(b"SYNTHETIC_RECOVERY_SECRET", cipher)
        self.assertEqual(hashlib.sha256(cipher).hexdigest(), receipt["ciphertextSha256"])
        self.assertFalse(receipt["targetCopyVerified"])
        self.assertFalse(receipt["restoreVerified"])
        self.assertFalse(receipt["marketStateIncluded"])
        with tarfile.open(fileobj=io.BytesIO(self.decrypt(final / "archive.gpg"))) as archive:
            contents = {p.name: archive.extractfile(p).read() for p in archive.getmembers()}
        self.assertEqual(self.secret.read_bytes(), contents["recovery/" + sealed.REQUIRED_RECOVERY])
        inventory = json.loads(contents["export-manifest.json"])
        self.assertTrue(inventory["cryptoRecoveryIncluded"])
        for record in inventory["files"]:
            self.assertEqual(record["sha256"], hashlib.sha256(contents[record["path"]]).hexdigest())
        self.assertNotIn(b"SYNTHETIC_RECOVERY_SECRET", (final / "receipt.json").read_bytes())
        verified = sealed.verify_plaintext_tar(io.BytesIO(self.decrypt(final / "archive.gpg")), receipt)
        self.assertEqual(len(inventory["files"]), verified["filesVerified"])
        self.assertTrue(verified["cryptoRecoveryIncluded"])
        self.assertFalse(verified["databaseRestored"])

    def test_decrypted_inventory_binding_and_missing_member_are_rejected(self):
        final, receipt = self.run_export()
        plain = self.decrypt(final / "archive.gpg")
        wrong = dict(receipt, sourceManifestSha256="0" * 64)
        with self.assertRaises(ValueError):
            sealed.verify_plaintext_tar(io.BytesIO(plain), wrong)
        with self.assertRaises((ValueError, tarfile.ReadError)):
            sealed.verify_plaintext_tar(io.BytesIO(plain[:2048]), receipt)

    def test_unreferenced_extra_secret_files_never_enter_archive(self):
        (self.set / "accidental.env").write_bytes(b"UNRELATED_SECRET")
        (self.set / "media").mkdir()
        (self.set / "media" / "secret.txt").write_bytes(b"UNRELATED_MEDIA_SECRET")
        (self.set / "database.stderr").write_bytes(b"UNRELATED_ERROR_SECRET")
        final, _ = self.run_export()
        plain = self.decrypt(final / "archive.gpg")
        self.assertNotIn(b"UNRELATED", plain)
        self.assertNotIn(b"accidental.env", plain)
        self.assertNotIn(b"database.stderr", plain)

    def test_referenced_local_original_is_included_with_its_database_binding(self):
        paired = sealed.load_paired(self.helper)
        live = self.base / "live"
        live.mkdir(mode=0o700)
        original = b"SYNTHETIC REFERENCED ORIGINAL"
        key = uuid.uuid4().hex + ".xlsx"
        (live / key).write_bytes(original)
        row = {"source_table": "goods_cost_imports", "id": str(uuid.uuid4()),
               "storage_provider": "local", "storage_key": key, "storage_version": None,
               "sha256": hashlib.sha256(original).hexdigest(), "size_bytes": len(original)}
        destination = self.set / "media/local/final"
        destination.mkdir(parents=True, mode=0o700)
        budget = paired.Budget(paired.Config(min_free_bytes=0, min_free_percent=0,
                                             bytes_per_second=1024**3), self.root)
        record = paired.copy_object(live, destination, row, budget)
        (self.set / "objects.jsonl").write_text(json.dumps(record) + "\n")
        (self.set / "references.jsonl").write_text(json.dumps(row) + "\n")
        self.manifest.update(objects_manifest_sha256=sealed.sha256(self.set / "objects.jsonl"),
            references_manifest_sha256=sealed.sha256(self.set / "references.jsonl"),
            private_document_references=1, media_objects=1,
            stored_bytes=len(original), original_bytes=len(original))
        self.write_manifest()
        final, _ = self.run_export()
        with tarfile.open(fileobj=io.BytesIO(self.decrypt(final / "archive.gpg"))) as archive:
            self.assertEqual(original, archive.extractfile(
                f"paired/{self.set_id}/media/local/final/{key}").read())

    def test_changed_dump_fails_without_success_or_partial(self):
        (self.set / "database.dump").write_bytes(b"CORRUPTED")
        with self.assertRaises(ValueError):
            self.run_export()
        self.assert_no_published_export()

    def test_wrong_full_fingerprint_fails_without_publication(self):
        with self.assertRaises(ValueError):
            self.run_export(fingerprint="0" * 40)
        self.assert_no_published_export()

    def test_secret_recipient_key_is_rejected(self):
        with self.assertRaises(ValueError):
            self.run_export(public_key=b"-----BEGIN PGP PRIVATE KEY BLOCK-----")
        self.assert_no_published_export()

    def test_missing_crypto_recovery_and_non_allowlist_inputs_are_rejected(self):
        for names in ([], ["etc/shadow"], [sealed.REQUIRED_RECOVERY, sealed.REQUIRED_RECOVERY]):
            with self.subTest(names=names), self.assertRaises(ValueError):
                self.run_export(recovery_names=names)
            self.assert_no_published_export()

    def test_symlinked_crypto_recovery_is_rejected(self):
        original = self.secret.with_name("original")
        self.secret.rename(original)
        self.secret.symlink_to(original)
        with self.assertRaises(ValueError):
            self.run_export()
        self.assert_no_published_export()

    def test_publicly_readable_crypto_recovery_is_rejected(self):
        self.secret.chmod(0o644)
        with self.assertRaises(ValueError):
            self.run_export()
        self.assert_no_published_export()

    def test_backup_lock_is_respected_without_disabling_producer(self):
        import fcntl
        with (self.root / ".backup.lock").open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(TimeoutError):
                self.run_export(lock_timeout=.05)
        self.assert_no_published_export()

    def test_encryption_process_failure_has_no_success_or_partial(self):
        original = subprocess.Popen
        def fail_encryption(arguments, *args, **kwargs):
            if "--encrypt" in arguments:
                arguments = ["/usr/bin/false"]
            return original(arguments, *args, **kwargs)
        with patch.object(sealed.subprocess, "Popen", side_effect=fail_encryption):
            with self.assertRaises((ValueError, BrokenPipeError)):
                self.run_export()
        self.assert_no_published_export()

    def test_successive_exports_preserve_previous_ciphertext(self):
        first, first_receipt = self.run_export()
        second, second_receipt = self.run_export()
        self.assertNotEqual(first, second)
        self.assertEqual(first_receipt["ciphertextSha256"], sealed.sha256(first / "archive.gpg"))
        self.assertEqual(second_receipt["ciphertextSha256"], sealed.sha256(second / "archive.gpg"))


if __name__ == "__main__":
    unittest.main()
