import os
from pathlib import Path
import tempfile
import unittest

import remote_recovery_catalog as catalog
import sealed_paired_export as sealed


class RemoteRecoveryCatalogTest(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='uten-keyset-test-');self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name);self.root.chmod(0o700)
        self.names=set(catalog.FIXED)
        self.account=catalog.LE+'accounts/acme-v02.api.letsencrypt.org/directory/'+'a'*32+'/'
        self.names.update(self.account+name+'.json' for name in ('private_key','regr','meta'))
        self.names.update(catalog.LE+'archive/uten-erp-employee/'+name+'1.pem' for name in ('privkey','cert','chain','fullchain'))
        for name in self.names:
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b'SYNTHETIC KEYSET INPUT');path.chmod(0o600)
        live=self.root/catalog.LIVE;live.mkdir(parents=True)
        for name in catalog.LINK_NAMES:
            (live/name).symlink_to('../../archive/uten-erp-employee/'+Path(name).stem+'1.pem')

    def test_collects_exact_physical_scope_and_controlled_link_map(self):
        (self.root/(catalog.BASE+'employee-commissioning-ca.key')).write_text('EXCLUDE TEST KEY')
        entries,metadata=catalog.collect(self.root,sealed.safe_path)
        self.assertEqual({'recovery/'+name for name in self.names},{name for _,name in entries})
        self.assertEqual(4,len(metadata['controlledSymlinks']))
        self.assertTrue(all(not path.is_symlink() for path,_ in entries))

    def test_any_escape_or_wrong_certificate_identity_is_rejected(self):
        path=self.root/(catalog.LIVE+'privkey.pem');path.unlink();path.symlink_to('/etc/passwd')
        with self.assertRaises(ValueError):catalog.collect(self.root,sealed.safe_path)

    def test_missing_account_private_key_cannot_claim_complete_recovery(self):
        (self.root/(self.account+'private_key.json')).unlink()
        with self.assertRaises(FileNotFoundError):catalog.collect(self.root,sealed.safe_path)

    def test_loose_private_key_permissions_are_rejected(self):
        (self.root/(catalog.BASE+'dns01.json')).chmod(0o644)
        with self.assertRaises(ValueError):catalog.collect(self.root,sealed.safe_path)

    def test_partial_certificate_version_and_unknown_paths_fail(self):
        path=self.root/(catalog.LE+'archive/uten-erp-employee/privkey2.pem');path.write_bytes(b'PARTIAL');path.chmod(0o600)
        with self.assertRaises(ValueError):catalog.collect(self.root,sealed.safe_path)
        for name in ['etc/shadow',catalog.BASE+'employee-commissioning-ca.key',catalog.LE+'archive/uten-erp-employee/../other.key']:
            self.assertFalse(catalog.allowed(name))

    def test_live_links_must_select_one_coherent_certificate_version(self):
        for name in ('privkey','cert','chain','fullchain'):
            path=self.root/(catalog.LE+'archive/uten-erp-employee/'+name+'2.pem');path.write_bytes(b'ROTATED');path.chmod(0o600)
        path=self.root/(catalog.LIVE+'privkey.pem');path.unlink();path.symlink_to('../../archive/uten-erp-employee/privkey2.pem')
        with self.assertRaises(ValueError):catalog.collect(self.root,sealed.safe_path)


if __name__=='__main__':unittest.main()
