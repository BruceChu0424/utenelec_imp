import base64
import copy
import hashlib
import unittest

import restore_snapshot as restore


class ReconstructSnapshotTest(unittest.TestCase):
    def setUp(self):
        self.secret=b'x'*32
        self.set_id='20261023T010203Z-123456789abc'
        self.prefix='paired/'+self.set_id+'/'
        self.source_manifest=b'{"set_id":"'+self.set_id.encode()+b'"}'
        self.plain={self.prefix+'database.dump':b'PGDMP SYNTHETIC DATABASE',
                    self.prefix+'manifest.json':self.source_manifest,
                    'recovery/etc/uten-imp/server.env':b'SYNTHETIC=RECOVERY_ONLY'}
        self.blocks={};files=[]
        for name,value in self.plain.items():
            opaque=restore.chunks.identity(self.secret,value);self.blocks[opaque]=value
            digest=hashlib.sha256(value).hexdigest()
            files.append({'path':name,'size':len(value),'sha256':digest,
                          'chunks':[{'opaqueId':opaque,'size':len(value),'sha256':digest}]})
        self.refs=[{'opaqueId':opaque,'cipherSha256':'d'*64,'cipherBytes':100} for opaque in sorted(self.blocks)]
        self.receipt={'format':restore.chunks.FORMAT,'snapshotId':'snapshot-'+self.set_id,'nonce':'a'*32,
            'sourceSetId':self.set_id,'sourceSnapshotAt':'2026-10-23T01:02:03+00:00',
            'sourceManifestSha256':hashlib.sha256(self.source_manifest).hexdigest(),'recipientFingerprint':'A'*40,
            'referenceListSha256':hashlib.sha256(restore.chunks.canonical(self.refs)).hexdigest()}
        self.manifest={**self.receipt,'chunkBytes':restore.chunks.CHUNK_BYTES,
            'dedupIdentityKeyRecovery':base64.b64encode(self.secret).decode(),'files':files,
            'scope':{'cryptoRecoveryIncluded':True}}

    def reconstruct(self,manifest=None,reader=None):
        return restore.reconstruct(manifest or self.manifest,self.refs,reader or self.blocks.__getitem__,self.receipt)

    def test_reconstructs_exact_files_from_secret_opaque_ids(self):
        self.assertEqual(self.plain,self.reconstruct())

    def test_nonce_source_identity_and_public_closure_are_bound(self):
        for key in ['nonce','sourceSetId','sourceManifestSha256','referenceListSha256']:
            value=copy.deepcopy(self.manifest);value[key]='changed'
            with self.subTest(key=key),self.assertRaises(ValueError):self.reconstruct(value)

    def test_wrong_plaintext_or_recovery_hmac_key_is_rejected(self):
        with self.assertRaises(ValueError):self.reconstruct(reader=lambda _:b'TAMPERED')
        value=copy.deepcopy(self.manifest);value['dedupIdentityKeyRecovery']=base64.b64encode(b'y'*32).decode()
        with self.assertRaises(ValueError):self.reconstruct(value)

    def test_paths_duplicate_files_and_unbounded_sizes_are_rejected(self):
        for transform in [lambda v:v['files'][0].update(path='../../etc/shadow'),
                          lambda v:v['files'].append(v['files'][0]),
                          lambda v:v['files'][0].update(size=1024**4)]:
            value=copy.deepcopy(self.manifest);transform(value)
            with self.assertRaises(ValueError):self.reconstruct(value)

    def test_ordered_file_digest_and_complete_reference_scope_are_required(self):
        value=copy.deepcopy(self.manifest);value['files'][0]['sha256']='0'*64
        with self.assertRaises(ValueError):self.reconstruct(value)
        value=copy.deepcopy(self.manifest);value['files']=value['files'][:-1]
        with self.assertRaises(ValueError):self.reconstruct(value)


if __name__=='__main__':unittest.main()
