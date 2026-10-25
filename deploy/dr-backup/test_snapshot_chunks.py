import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import resource
import tarfile
from datetime import timedelta
from unittest.mock import patch

import continuous_backup as base
import snapshot_chunks as chunks
import test_continuous_backup as archive_fixtures


class EncryptedChunkSnapshotTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.signing = tempfile.TemporaryDirectory(prefix="uten-test-backup-signing-")
        cls.signing_key = Path(cls.signing.name) / "signing_ed25519"
        subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(cls.signing_key)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):cls.signing.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uten-dr-chunk-test-")
        self.root = Path(self.temp.name);self.root.chmod(0o700)
        self.storage = self.root / "storage";self.storage.mkdir(mode=0o700)
        self.config = {"storage_root": str(self.storage), "status_file": str(self.root / "status.json"),
            "recipient_fingerprint": "A"*40, "max_archive_bytes": 2**20, "max_storage_bytes": 10*2**20,
            "min_free_bytes": 0, "hourly_retention_days": 7, "daily_retention_days": 30,
            "minimum_complete_sets": 3}
        self.cipher = b"SYNTHETIC ENCRYPTED CHUNK ONLY"*100
        self.manifest = b"SYNTHETIC ENCRYPTED MANIFEST"*100
        self.counter = 0
        allowed = self.root / "allowed_signers"
        allowed.write_text('uten-backup-source namespaces="'+chunks.SIGNING_NAMESPACE+'" '+
                           self.signing_key.with_suffix('.pub').read_text())
        allowed.chmod(0o600)
        self.config['allowed_signers_file'] = str(allowed)
        patcher = patch.object(base, "chunks_module", return_value=chunks)
        patcher.start();self.addCleanup(patcher.stop)

    def tearDown(self):self.temp.cleanup()

    def send(self, header, data=b""):
        output = io.BytesIO()
        base.receive(self.config, io.BytesIO(chunks.canonical(header)+b"\n"+data), output)
        return json.loads(output.getvalue())

    def object(self, opaque="a"*64):
        header = {"format": base.FORMAT, "operation": "putChunk", "opaqueId": opaque,
                  "cipherBytes": len(self.cipher), "cipherSha256": hashlib.sha256(self.cipher).hexdigest()}
        return self.send(header, self.cipher)

    def point(self, objects, age=0):
        self.counter += 1
        moment = base.now()-timedelta(days=age);stamp = moment.strftime("%Y%m%dT%H%M%SZ")
        refs = [{k:obj[k] for k in ("opaqueId","cipherSha256","cipherBytes")} for obj in sorted(objects,key=lambda x:x['opaqueId'])]
        receipt = {"format": chunks.FORMAT, "snapshotId":f"snapshot-{stamp}-{self.counter:012x}",
            "nonce":f"{self.counter:032x}", "sourceSetId":f"{stamp}-{self.counter:012x}",
            "sourceSnapshotAt":moment.isoformat(), "sourceManifestSha256":"b"*64,
            "recipientFingerprint":"A"*40, "manifestCipherSha256":hashlib.sha256(self.manifest).hexdigest(),
            "manifestCipherBytes":len(self.manifest), "referenceListSha256":hashlib.sha256(chunks.canonical(refs)).hexdigest(),
            "marketStateIncluded":False,"clientReleaseStateIncluded":False}
        return {"format":base.FORMAT,"operation":"commitSnapshot","snapshotReceipt":receipt,"references":refs,
                "sourceSignature":chunks.sign_receipt(receipt,self.signing_key,base)}

    def test_opaque_ids_require_source_secret_and_do_not_expose_public_plaintext_hash(self):
        plain = b"predictable secret configuration value"
        first = chunks.identity(b"a"*32, plain)
        self.assertNotEqual(hashlib.sha256(plain).hexdigest(),first)
        self.assertNotEqual(first,chunks.identity(b"b"*32,plain))
        self.assertEqual(first,chunks.identity(b"a"*32,plain))

    def test_retention_validates_a_shared_chunk_once_for_all_retained_references(self):
        shared = self.object()
        for _ in range(8):
            self.send(self.point([shared]), self.manifest)
        with patch.object(chunks, 'object_record', wraps=chunks.object_record) as reads:
            result = base.retain(self.config)
        self.assertEqual(8, result['completedSnapshots'])
        visits = [call for call in reads.call_args_list if call.args[1] == shared['opaqueId']]
        self.assertEqual(1, len(visits), 'A shared immutable chunk must not be restatted for every point')

    def test_damaged_retained_dependency_aborts_before_removing_any_old_point(self):
        shared = self.object()
        old = self.send(self.point([shared], age=50), self.manifest)
        old_path = self.storage / 'snapshots' / old['snapshotId'] / 'target-receipt.json'
        old['receivedAt'] = (base.now() - timedelta(days=50)).isoformat()
        base.atomic_json(old_path, old)
        for _ in range(3):
            self.send(self.point([shared]), self.manifest)
        storage = self.storage / 'objects' / shared['opaqueId']
        (storage / 'cipher.gpg').unlink()
        with self.assertRaises((ValueError, OSError)):
            base.retain(self.config)
        self.assertTrue((self.storage / 'snapshots' / old['snapshotId']).is_dir(),
                        'Do not remove older recovery points before validating the retained closure')

    def test_global_preflight_keeps_archives_snapshots_and_objects_when_retained_chunk_is_missing(self):
        archive = archive_fixtures.CiphertextReceiverTest()
        archive.setUp()
        def close_archive():
            archive.tearDown()
            archive.doCleanups()
        self.addCleanup(close_archive)
        archive.storage, archive.config = self.storage, self.config
        for age in (50, 3, 2, 1):
            receipt = archive.send(archive.header(age))
            receipt['receivedAt'] = (base.now() - timedelta(days=age)).isoformat()
            base.atomic_json(self.storage / receipt['exportId'] / 'target-receipt.json', receipt)
        used = self.object()
        old = self.send(self.point([used], age=50), self.manifest)
        old['receivedAt'] = (base.now() - timedelta(days=50)).isoformat()
        base.atomic_json(self.storage / 'snapshots' / old['snapshotId'] / 'target-receipt.json', old)
        for _ in range(3):
            self.send(self.point([used]), self.manifest)
        unused = self.object('d' * 64)
        unused['receivedAt'] = (base.now() - timedelta(days=3)).isoformat()
        base.atomic_json(self.storage / 'objects' / unused['opaqueId'] / 'receipt.json', unused)
        (self.storage / 'objects' / used['opaqueId'] / 'cipher.gpg').unlink()
        before = {path.relative_to(self.storage) for path in self.storage.rglob('*')}
        with self.assertRaises((ValueError, OSError)):
            base.retain(self.config)
        self.assertEqual(before, {path.relative_to(self.storage) for path in self.storage.rglob('*')})
        self.assertEqual(4, len(base.completed(self.config)))

    def test_commits_only_after_every_ciphertext_dependency_is_durable(self):
        obj = self.object();header = self.point([obj])
        receipt = self.send(header,self.manifest)
        self.assertEqual("SNAPSHOT_CIPHERTEXT_COMPLETE",receipt["state"])
        status = chunks.status(self.config,base)
        self.assertTrue(status["snapshotRpo15MinutesFresh"])
        self.assertFalse(status["arbitraryPitrOriginalHistoryProtected"])
        self.assertFalse(status["snapshotRecoveryPoints"][0]["keysCovered"])
        self.assertFalse(status["snapshotRecoveryPoints"][0]["verified"])
        self.assertTrue(receipt['sourceSignatureVerified'])

    def test_unsigned_or_relabelled_source_manifest_is_rejected(self):
        obj=self.object();header=self.point([obj]);del header['sourceSignature']
        with self.assertRaises(ValueError):self.send(header,self.manifest)
        header=self.point([obj]);header['snapshotReceipt']['sourceManifestSha256']='c'*64
        with self.assertRaises(ValueError):self.send(header,self.manifest)
        self.assertEqual(0,chunks.status(self.config,base)['completedSnapshots'])

    def test_missing_dependency_and_bad_manifest_never_publish_a_snapshot(self):
        fake = {"opaqueId":"c"*64,"cipherSha256":"d"*64,"cipherBytes":1000}
        with self.assertRaises(ValueError):self.send(self.point([fake]),self.manifest)
        obj=self.object()
        with self.assertRaises(ValueError):self.send(self.point([obj]),b"x"*len(self.manifest))
        self.assertEqual(0,chunks.status(self.config,base)["completedSnapshots"])

    def test_chunk_identity_collision_cannot_overwrite_old_ciphertext(self):
        obj=self.object()
        header={"format":base.FORMAT,"operation":"putChunk","opaqueId":obj['opaqueId'],
                "cipherSha256":"e"*64,"cipherBytes":len(self.cipher)}
        with self.assertRaises(ValueError):self.send(header,self.cipher)
        self.assertEqual(obj,chunks.object_record(self.storage/'objects',obj['opaqueId'],base,verify=True))

    def test_traversal_extra_fields_and_unbounded_identity_probes_are_rejected(self):
        for value in ['../../etc/shadow','a'*63,'A'*64]:
            with self.assertRaises(ValueError):self.send({'format':base.FORMAT,'operation':'probeChunks','opaqueIds':[value]})
        header={'format':base.FORMAT,'operation':'probeChunks','opaqueIds':['a'*64],'secret':'NOT_ALLOWED'}
        with self.assertRaises(ValueError):self.send(header)

    def test_reference_order_nonce_and_snapshot_identity_are_bound(self):
        obj=self.object();header=self.point([obj]);header['snapshotReceipt']['nonce']='invalid'
        with self.assertRaises(ValueError):self.send(header,self.manifest)
        header=self.point([obj]);header['snapshotReceipt']['marketStateIncluded']='MUST_NOT_BE_PLAINTEXT'
        with self.assertRaises(ValueError):self.send(header,self.manifest)
        self.assertEqual(0,chunks.status(self.config,base)["completedSnapshots"])

    def test_gc_preserves_shared_chunks_and_two_day_unreferenced_grace(self):
        shared=self.object();orphan=self.object('f'*64)
        for age in [40,39,1,0]:
            receipt=self.send(self.point([shared],age),self.manifest)
            path=self.storage/'snapshots'/receipt['snapshotId']/'target-receipt.json'
            receipt['receivedAt']=(base.now()-timedelta(days=age)).isoformat();base.atomic_json(path,receipt)
        report=base.retain(self.config)
        self.assertEqual(1,report['lastRetention']['deletedSnapshots'])
        self.assertIsNotNone(chunks.object_record(self.storage/'objects',shared['opaqueId'],base))
        self.assertIsNotNone(chunks.object_record(self.storage/'objects',orphan['opaqueId'],base))
        orphan_path=self.storage/'objects'/orphan['opaqueId']/'receipt.json'
        orphan['receivedAt']=(base.now()-timedelta(days=3)).isoformat();base.atomic_json(orphan_path,orphan)
        report=base.retain(self.config)
        self.assertEqual(1,report['lastRetention']['deletedUnreferencedChunks'])
        self.assertIsNotNone(chunks.object_record(self.storage/'objects',shared['opaqueId'],base))

    def test_broken_retained_closure_blocks_gc(self):
        obj=self.object();receipt=self.send(self.point([obj]),self.manifest)
        orphan=self.object('f'*64);path=self.storage/'objects'/orphan['opaqueId']/'receipt.json'
        orphan['receivedAt']=(base.now()-timedelta(days=3)).isoformat();base.atomic_json(path,orphan)
        (self.storage/'objects'/obj['opaqueId']/'cipher.gpg').unlink()
        with self.assertRaises((ValueError,FileNotFoundError)):base.retain(self.config)
        self.assertTrue((self.storage/'objects'/orphan['opaqueId']).exists())

    def test_capacity_guard_accounts_for_chunk_pool_and_existing_snapshots(self):
        self.object();self.config['max_storage_bytes']=1
        with self.assertRaises(OSError):self.object('f'*64)
        self.assertFalse((self.storage/'objects'/('f'*64)).exists())

    def test_management_bundle_contains_only_signed_ciphertext_closure_and_is_not_rpc(self):
        obj=self.object();receipt=self.send(self.point([obj]),self.manifest)
        output=io.BytesIO();chunks.bundle(self.config,receipt['snapshotId'],output,base)
        with tarfile.open(fileobj=io.BytesIO(output.getvalue())) as archive:
            names={member.name for member in archive.getmembers()}
        self.assertEqual({'manifest.gpg','references.json','target-receipt.json','source-receipt.json',
            'source-signature.sshsig','objects/'+obj['opaqueId']+'.gpg'},names)
        with self.assertRaises(ValueError):self.send({'format':base.FORMAT,'operation':'bundle','snapshotId':receipt['snapshotId']})

    def test_more_than_five_hundred_chunks_export_under_sixty_four_descriptor_limit(self):
        objects = [self.object(f'{index:064x}') for index in range(501)]
        receipt = self.send(self.point(objects), self.manifest)
        previous = resource.getrlimit(resource.RLIMIT_NOFILE)
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (64, previous[1]))
            output = io.BytesIO()
            chunks.bundle(self.config, receipt['snapshotId'], output, base)
        finally:
            resource.setrlimit(resource.RLIMIT_NOFILE, previous)
        with tarfile.open(fileobj=io.BytesIO(output.getvalue()), mode='r:') as archive:
            self.assertEqual(506, len(archive.getmembers()))
        self.assertFalse(any((self.storage / '.bundle-leases').iterdir()))

    def test_active_bundle_lease_protects_old_point_and_closure_during_unlocked_stream(self):
        old_object = self.object('d' * 64)
        old = self.send(self.point([old_object], age=50), self.manifest)
        old['receivedAt'] = (base.now() - timedelta(days=50)).isoformat()
        old_path = self.storage / 'snapshots' / old['snapshotId']
        base.atomic_json(old_path / 'target-receipt.json', old)
        for _ in range(3):
            self.send(self.point([self.object()]), self.manifest)
        original = old_path / 'manifest.gpg'
        inspected = []
        class Output(io.BytesIO):
            def write(stream, raw):
                if not inspected:
                    inspected.append(base.retain(self.config))
                    self.assertTrue(original.exists())
                return super().write(raw)
        output = Output()
        chunks.bundle(self.config, old['snapshotId'], output, base)
        self.assertEqual(4, inspected[0]['completedSnapshots'])
        after = base.retain(self.config)
        self.assertEqual(3, after['completedSnapshots'])
        self.assertFalse(old_path.exists())

    def test_status_checks_outside_returned_window_and_catalog_cap_is_explicit(self):
        obj = self.object()
        oldest = self.send(self.point([obj], age=50), self.manifest)
        oldest['receivedAt'] = (base.now() - timedelta(days=50)).isoformat()
        old_path = self.storage / 'snapshots' / oldest['snapshotId']
        base.atomic_json(old_path / 'target-receipt.json', oldest)
        for _ in range(3):
            self.send(self.point([obj]), self.manifest)
        with patch.object(chunks, 'CATALOG_WINDOW', 2):
            status = chunks.status(self.config, base)
            self.assertEqual(4, status['completedSnapshots'])
            self.assertEqual(2, len(status['snapshotRecoveryPoints']))
            self.assertTrue(status['snapshotCatalogTruncated'])
            (old_path / 'references.json').write_bytes(b'[]')
            with self.assertRaises(ValueError):
                chunks.status(self.config, base)
        with patch.object(chunks, 'MAX_CATALOG_POINTS', 1):
            # Use the first valid points only; count overflow is a visible
            # resource rejection, never a silently truncated healthy catalog.
            (old_path / 'references.json').write_bytes(chunks.canonical([
                {key: obj[key] for key in ('opaqueId', 'cipherSha256', 'cipherBytes')}]))
            with self.assertRaises(base.TransferFailure) as failure:
                chunks.status(self.config, base)
            self.assertEqual('CATALOG_RESOURCE_LIMIT', failure.exception.code)


if __name__ == '__main__':unittest.main()
