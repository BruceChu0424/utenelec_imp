"""Failure guards for the local read-only recovery rehearsal; no Docker or DB use."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('verify_local_recovery', Path(__file__).with_name('verify-local-recovery.py'))
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryOriginalGuardsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='uten-recovery-guards-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source'
        self.source.mkdir()
        self.destination = self.root / 'restored'
        self.original = b'original business evidence\x00\xff'
        (self.source / 'original.bin').write_bytes(self.original)
        self.ref = {'kind': 'private', 'storage_provider': 'local', 'storage_key': 'original.bin',
                    'storage_version': None, 'bytes': len(self.original),
                    'sha256': hashlib.sha256(self.original).hexdigest()}

    def test_repeated_ordinary_and_private_references_restore_identical_original_once(self):
        refs = [self.ref, {**self.ref, 'kind': 'ordinary'}]
        verified = recovery.restore_local_media(refs, self.source, self.destination)
        self.assertEqual(2, len(verified))
        self.assertEqual(self.original, (self.destination / 'original.bin').read_bytes())
        self.assertEqual(self.original, (self.source / 'original.bin').read_bytes())

    def test_escape_or_unrecognized_provider_never_writes_any_destination(self):
        variants = [dict(storage_key='../outside.bin'), dict(storage_key=str(self.root / 'outside.bin')),
                    dict(storage_provider='oss'), dict(storage_version='unverified-pinned-version')]
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                recovery.restore_local_media([{**self.ref, **variant}], self.source, self.destination)
            self.assertFalse(self.destination.exists())

    def test_tamper_and_size_conflict_preserve_the_previous_restore(self):
        recovery.restore_local_media([self.ref], self.source, self.destination)
        for bad in ({'sha256': '0' * 64}, {'bytes': len(self.original) + 1}):
            with self.subTest(field=list(bad)), self.assertRaises(ValueError):
                recovery.restore_local_media([{**self.ref, **bad}], self.source, self.destination)
            self.assertEqual(self.original, (self.destination / 'original.bin').read_bytes())

    def test_existing_different_destination_is_never_silently_overwritten(self):
        self.destination.mkdir()
        previous = b'previous independently restored original'
        (self.destination / 'original.bin').write_bytes(previous)
        with self.assertRaises(ValueError):
            recovery.restore_local_media([self.ref], self.source, self.destination)
        self.assertEqual(previous, (self.destination / 'original.bin').read_bytes())
        self.assertEqual(self.original, (self.source / 'original.bin').read_bytes())


if __name__ == '__main__':
    unittest.main()
