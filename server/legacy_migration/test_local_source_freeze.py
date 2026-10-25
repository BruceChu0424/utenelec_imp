import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import local_source_freeze as freeze


class LocalSourceFreezeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        self.loader = self.root / 'server/legacy_migration/loader.py'
        self.loader.parent.mkdir(parents=True)
        self.loader.write_text('first', encoding='utf-8')
        self.migration = self.root / 'server/src/main/resources/db/migration/V1__test.sql'
        self.migration.parent.mkdir(parents=True)
        self.migration.write_text('SELECT 1;', encoding='utf-8')
        self.output = Path(self.temp.name) / 'freeze.json'
        self.parent = patch.object(freeze, 'parent', return_value='a' * 40)
        self.parent.start()
        self.addCleanup(self.parent.stop)

    def capture(self):
        return freeze.capture(self.root, self.output, 'USER_LOCAL_NO_COMMIT')

    def test_verify_explicit_local_bytes(self):
        digest = self.capture()
        result = freeze.verify(self.root, self.output, digest)
        self.assertFalse(result['committedSource'])
        self.assertEqual(result['gitParent'], 'a' * 40)

    def test_changed_loader_fails(self):
        digest = self.capture()
        self.loader.write_text('changed', encoding='utf-8')
        with self.assertRaises(ValueError):
            freeze.verify(self.root, self.output, digest)

    def test_added_migration_fails(self):
        digest = self.capture()
        self.migration.with_name('V2__new.sql').write_text('SELECT 2;', encoding='utf-8')
        with self.assertRaises(ValueError):
            freeze.verify(self.root, self.output, digest)

    def test_wrong_external_digest_or_git_parent_fails(self):
        digest = self.capture()
        with self.assertRaises(ValueError):
            freeze.verify(self.root, self.output, '0' * 64)
        with patch.object(freeze, 'parent', return_value='b' * 40):
            with self.assertRaises(ValueError):
                freeze.verify(self.root, self.output, digest)

    def test_freeze_cannot_be_overwritten(self):
        self.capture()
        with self.assertRaises(ValueError):
            self.capture()


if __name__ == '__main__':
    unittest.main()
