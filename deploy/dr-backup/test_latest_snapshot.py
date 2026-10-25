"""Synthetic ciphertext, generated signing keys and local files only; no real DB."""
import copy
from datetime import timedelta
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tarfile
import unittest
from unittest.mock import patch

import continuous_backup as base
import latest_snapshot as latest
import snapshot_chunks as chunks
import test_snapshot_chunks as snapshot_fixtures
import test_continuous_backup as archive_fixtures


class LatestSnapshotPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        snapshot_fixtures.EncryptedChunkSnapshotTest.setUpClass()

    @classmethod
    def tearDownClass(cls):
        snapshot_fixtures.EncryptedChunkSnapshotTest.tearDownClass()

    def setUp(self):
        self.fixture = snapshot_fixtures.EncryptedChunkSnapshotTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.addCleanup(self.fixture.tearDown)
        self.config = self.fixture.config
        self.storage = self.fixture.storage
        self.root = self.fixture.root
        self.send = self.fixture.send
        patcher = patch.object(base, 'latest_module', return_value=latest)
        patcher.start()
        self.addCleanup(patcher.stop)

    def old_point(self, *, age=2, opaque='a'*64):
        obj = self.fixture.object(opaque)
        return obj, self.send(self.fixture.point([obj], age=age), self.fixture.manifest)

    def enable(self):
        self.config['retention_mode'] = latest.MODE

    def header(self, objects, *, age=0, version='c'*64):
        header = self.fixture.point(objects, age=age)
        header['snapshotReceipt']['configurationVersion'] = version
        header['sourceSignature'] = chunks.sign_receipt(header['snapshotReceipt'], self.fixture.signing_key, base)
        return header

    def lease(self, header):
        receipt = header['snapshotReceipt']
        response = self.send({'format': base.FORMAT, 'operation': 'beginSnapshotUpload',
            **{key: receipt[key] for key in latest.BINDINGS},
            'opaqueIds': [row['opaqueId'] for row in header['references']]})
        header['uploadLease'] = response['leaseId']
        return response

    def seed(self, obj):
        self.enable()
        header = self.header([obj])
        self.lease(header)
        return self.send(header, self.fixture.manifest)

    def evidence(self, receipt):
        # Tests generate a bound *synthetic* report. Production requires the
        # actual isolated PG/GPG/attachment/credential reports and root review.
        report = {key: receipt[key] for key in latest.PROOF_BINDINGS}
        report.update(state='ISOLATED_DATABASE_AND_ORIGINALS_RESTORED', databaseRestored=True,
            attachmentsVerified=True, corePgpAndHmacVerified=True, keysVerified=True,
            sourceSignatureVerified=True, isolated=True, sideEffectsDisabled=True,
            knownAncillaryCredentialIssuesCleared=False, pairedRecoveryInputBindingSha256='d'*64,
            integrityCandidate={'state': 'ISOLATED_CLONE_INTEGRITY_CANDIDATE_VERIFIED',
                'productionMutated': False, 'companyHmacChanged': False, 'aiPlaintextPreserved': True,
                'aiCurrentCompanyIssuerVerified': True, 'plan': {'configSha256': 'e'*64},
                'after': {'configSha256': 'e'*64, 'blockers': {'providerPlaceholderOrLast4Mismatch': 0},
                          'aiCredentialsToRewrap': 0}})
        report_path = self.root / 'real-restore-test-report.json'
        base.atomic_json(report_path, report)
        report_sha = base.digest(report_path)
        moment = base.now() - timedelta(seconds=1)
        review = {'format': 'uten-dr-credential-review-v1', 'restoreReportSha256': report_sha,
            'pairedRecoveryInputBindingSha256': 'd'*64, 'configurationVersion': receipt['configurationVersion'],
            'configurationFileSha256': 'e'*64, 'profile': latest.profile(self.config, base),
            'reviewedAt': moment.isoformat(), 'expiresAt': (moment + timedelta(days=7)).isoformat(), 'checks': []}
        methods = {'applicationConfiguration': 'RESTORED_CONFIGURATION_AUDIT',
                   'signingAndRecipientRecovery': 'OFFLINE_PRIVATE_KEY_RECOVERY',
                   'externalCredentials': 'RESTORED_CREDENTIAL_INVENTORY_AUDIT'}
        for scope, method in methods.items():
            path = self.root / (scope + '.json')
            base.atomic_json(path, {'format': 'uten-dr-credential-evidence-v1', 'scope': scope,
                'method': method, 'state': 'VERIFIED', 'restoreReportSha256': report_sha,
                'configurationFileSha256': 'e'*64, 'pairedRecoveryInputBindingSha256': 'd'*64,
                'observedAt': moment.isoformat()})
            review['checks'].append({'scope': scope, 'evidenceFile': str(path), 'evidenceSha256': base.digest(path)})
        review_path = self.root / 'root-credential-review.json'
        base.atomic_json(review_path, review)
        return report_path, review_path

    def commission(self, receipt):
        report, review = self.evidence(receipt)
        return latest.commission(self.config, base, chunks, receipt['snapshotId'], report,
            credential_review_path=review, legacy_exports_drained=True)

    def archive(self):
        fixture = archive_fixtures.CiphertextReceiverTest()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.addCleanup(fixture.tearDown)
        fixture.storage, fixture.config = self.storage, self.config
        return fixture.send(fixture.header(10))

    def test_default_history_and_two_day_orphans_are_unchanged(self):
        obj, old = self.old_point()
        for _ in range(3):
            self.send(self.fixture.point([obj]), self.fixture.manifest)
        result = base.retain(self.config)
        self.assertEqual(4, result['completedSnapshots'])
        self.assertNotIn('retentionMode', result)
        self.assertTrue((self.storage/'snapshots'/old['snapshotId']).exists())
        with self.assertRaises(ValueError):
            base.latest_enabled({'retention_mode': 'typo'})

    def test_uncommissioned_seed_keeps_old_chain_and_blocks_more_seeds(self):
        obj, old = self.old_point()
        archive = self.archive()
        seed = self.seed(obj)
        self.assertEqual('BLOCKED_COMMISSIONING', seed['cleanupState'])
        self.assertTrue((self.storage/archive['exportId']).exists())
        self.assertTrue((self.storage/'snapshots'/old['snapshotId']).exists())
        with self.assertRaises(ValueError):
            self.lease(self.header([obj]))
        # Changing a proposed config version cannot evade the one seed bound.
        with self.assertRaises(ValueError):
            self.lease(self.header([obj], version='f'*64))
        self.assertEqual(2, chunks.status(self.config, base)['completedSnapshots'])
        self.assertEqual('DEGRADED', base.build_status(self.config)['health'])

    def test_commissioning_requires_real_bound_restore_and_credential_evidence(self):
        obj, _ = self.old_point()
        seed = self.seed(obj)
        report, review = self.evidence(seed)
        raw = base.read_json(report)
        raw['knownAncillaryCredentialIssuesCleared'] = True
        raw.pop('integrityCandidate')
        base.atomic_json(report, raw)
        with self.assertRaises(ValueError):
            latest.commission(self.config, base, chunks, seed['snapshotId'], report,
                credential_review_path=review, legacy_exports_drained=True)
        self.assertFalse((self.storage/'.latest-commissioning.json').exists())
        report, review = self.evidence(seed)
        evidence = base.read_json(review)
        evidence['checks'][0]['evidenceSha256'] = '0'*64
        base.atomic_json(review, evidence)
        with self.assertRaises(ValueError):
            latest.commission(self.config, base, chunks, seed['snapshotId'], report,
                credential_review_path=review, legacy_exports_drained=True)
        report, review = self.evidence(seed)
        with self.assertRaises(ValueError):
            latest.commission(self.config, base, chunks, seed['snapshotId'], report,
                credential_review_path=review, legacy_exports_drained=False)
        self.commission(seed)
        self.assertEqual('ACTIVE', latest.commissioning(self.config, base)[1])

    def test_cross_format_rotation_keeps_one_complete_signed_root_and_is_idempotent(self):
        obj, old = self.old_point()
        archive = self.archive()
        seed = self.seed(obj)
        self.commission(seed)
        result = base.retain(self.config)
        self.assertEqual(1, result['completedSnapshots'])
        self.assertEqual(0, result['completedSets'])
        self.assertFalse((self.storage/archive['exportId']).exists())
        self.assertFalse((self.storage/'snapshots'/old['snapshotId']).exists())
        self.assertTrue((self.storage/'snapshots'/seed['snapshotId']).exists())
        again = base.retain(self.config)
        self.assertEqual(0, again['lastRetention']['deletedSnapshots'])
        self.assertFalse(again['restoreVerified'])
        self.assertFalse(again['snapshotRecoveryPoints'][0]['verified'])

    def test_new_complete_publish_precedes_deletion_and_failed_upload_keeps_old(self):
        obj, _ = self.old_point()
        seed = self.seed(obj)
        self.commission(seed)
        base.retain(self.config)
        header = self.header([obj])
        self.lease(header)
        with self.assertRaises(ValueError):
            self.send(header, b'x'*len(self.fixture.manifest))
        self.assertTrue((self.storage/'snapshots'/seed['snapshotId']).exists())
        self.assertEqual(1, chunks.status(self.config, base)['completedSnapshots'])
        original = latest.retire_delete
        def check_before_delete(path, kind, root, module):
            self.assertTrue((self.storage/'snapshots'/header['snapshotReceipt']['snapshotId']/'target-receipt.json').is_file())
            return original(path, kind, root, module)
        with patch.object(latest, 'retire_delete', side_effect=check_before_delete):
            target = self.send(header, self.fixture.manifest)
        self.assertEqual('COMPLETE', target['cleanupState'])
        self.assertFalse((self.storage/'snapshots'/seed['snapshotId']).exists())

    def test_old_arrival_cannot_replace_new_source_time(self):
        obj, _ = self.old_point()
        seed = self.seed(obj)
        self.commission(seed)
        with self.assertRaises(ValueError):
            self.lease(self.header([obj], age=1))
        self.assertTrue((self.storage/'snapshots'/seed['snapshotId']).exists())

    def test_nonrenewable_lease_protects_preexisting_orphan_and_expires(self):
        obj, _ = self.old_point()
        orphan = self.fixture.object('f'*64)
        seed = self.seed(obj)
        self.commission(seed)
        orphan['receivedAt'] = (base.now()-timedelta(days=3)).isoformat()
        base.atomic_json(self.storage/'objects'/orphan['opaqueId']/'receipt.json', orphan)
        # Its lease must be registered before GC first becomes eligible to remove it.
        header = self.header([obj, orphan])
        lease = self.lease(header)
        self.assertTrue((self.storage/'objects'/orphan['opaqueId']).exists())
        again = self.lease(header)
        self.assertEqual(lease, again)
        base.retain(self.config)
        self.assertTrue((self.storage/'objects'/orphan['opaqueId']).exists())
        with patch.object(base, 'now', return_value=base.instant(lease['expiresAt'])+timedelta(seconds=1)):
            with self.assertRaises(ValueError):
                self.send(header, self.fixture.manifest)
            base.retain(self.config)
        self.assertFalse((self.storage/'objects'/orphan['opaqueId']).exists())

    def test_upload_membership_and_unleased_legacy_mutations_are_rejected(self):
        obj, _ = self.old_point()
        self.enable()
        with self.assertRaises(ValueError):
            self.fixture.object()
        header = self.header([obj])
        lease = self.lease(header)
        with self.assertRaises(ValueError):
            self.send({'format': base.FORMAT, 'operation': 'probeChunks', 'opaqueIds': ['f'*64], 'uploadLease': lease['leaseId']})
        header['snapshotReceipt']['nonce'] = 'f'*32
        with self.assertRaises(ValueError):
            self.send(header, self.fixture.manifest)
        with self.assertRaises(ValueError):
            self.lease(self.header([obj]))

    def test_configuration_and_profile_change_preserve_old_and_need_new_acceptance(self):
        obj, _ = self.old_point()
        seed = self.seed(obj)
        self.commission(seed)
        base.retain(self.config)
        header = self.header([obj], version='f'*64)
        self.lease(header)
        newer = self.send(header, self.fixture.manifest)
        self.assertEqual('BLOCKED_COMMISSIONING', newer['cleanupState'])
        self.assertTrue((self.storage/'snapshots'/seed['snapshotId']).exists())
        with self.assertRaises(ValueError):
            self.lease(self.header([obj], version='e'*64))
        self.assertEqual('COMMISSIONING_CONFIGURATION_CHANGED', base.build_status(self.config)['latestRotationActivationState'])
        self.commission(newer)
        base.retain(self.config)
        self.assertFalse((self.storage/'snapshots'/seed['snapshotId']).exists())
        allowed = Path(self.config['allowed_signers_file'])
        allowed.write_bytes(allowed.read_bytes()+b'\n')
        self.assertEqual('COMMISSIONING_PROFILE_CHANGED', latest.commissioning(self.config, base)[1])
        self.assertEqual('DEGRADED', base.build_status(self.config)['health'])

    def test_expired_commissioning_cannot_delete_or_allocate_more_roots(self):
        obj, _ = self.old_point()
        seed = self.seed(obj)
        self.commission(seed)
        proof, _ = latest.commissioning(self.config, base)
        with patch.object(base, 'now', return_value=base.instant(proof['expiresAt'])+timedelta(seconds=1)):
            result = base.retain(self.config)
            self.assertEqual('COMMISSIONING_EXPIRED', result['latestRotationActivationState'])
            self.assertEqual(2, result['completedSnapshots'])
            with self.assertRaises(ValueError):
                self.lease(self.header([obj]))

    def test_known_crashed_stage_is_cleaned_but_unknown_stage_blocks_without_deletion(self):
        obj, _ = self.old_point()
        self.enable()
        root, objects, _ = chunks.directories(self.config, base)
        with base.lock(root/'.receiver.lock'):
            stage = latest.create_stage(objects, base)
            (stage/'cipher.gpg').write_bytes(b'SYNTHETIC PARTIAL')
            (stage/'cipher.gpg').chmod(0o600)
        self.lease(self.header([obj]))
        self.assertFalse(stage.exists())
        unknown = objects/('.incoming-'+'f'*32)
        unknown.mkdir(mode=0o700)
        (unknown/'unknown').write_bytes(b'KEEP')
        before = set(self.storage.rglob('*'))
        with self.assertRaises((ValueError, OSError)):
            base.retain(self.config)
        self.assertEqual(before, set(self.storage.rglob('*')))

    def test_active_full_and_snapshot_export_leases_keep_inputs_until_release(self):
        obj, old = self.old_point()
        archive = self.archive()
        seed = self.seed(obj)
        self.commission(seed)
        leases = []
        for dirname, marker in (('.archive-leases', {'format': latest.FULL_LEASE_FORMAT,
                'exportId': archive['exportId'], 'ciphertextSha256': archive['ciphertextSha256']}),
                ('.bundle-leases', {'format': chunks.BUNDLE_LEASE_FORMAT, 'snapshotId': old['snapshotId'],
                'manifestCipherSha256': old['manifestCipherSha256'], 'referenceListSha256': old['referenceListSha256']})):
            directory = self.storage/dirname
            directory.mkdir(mode=0o700)
            path = directory/('f'*32+'.json')
            base.atomic_json(path, marker)
            descriptor = os.open(path, os.O_RDWR)
            fcntl.flock(descriptor, fcntl.LOCK_EX|fcntl.LOCK_NB)
            leases.append(descriptor)
        try:
            result = base.retain(self.config)
            self.assertEqual(2, result['latestRotationProtectedExportCount'])
            self.assertEqual(2, result['completedSnapshots'])
            self.assertEqual(1, result['completedSets'])
        finally:
            for descriptor in leases:
                os.close(descriptor)
        result = base.retain(self.config)
        self.assertEqual(1, result['completedSnapshots'])
        self.assertEqual(0, result['completedSets'])

    def test_cleanup_failure_is_visible_and_next_begin_cannot_accumulate_another_point(self):
        obj, old = self.old_point()
        seed = self.seed(obj)
        self.commission(seed)
        header = self.header([obj])
        self.lease(header)
        with patch.object(latest.shutil, 'rmtree', side_effect=OSError('SYNTHETIC DELETE FAILURE')):
            result = self.send(header, self.fixture.manifest)
            self.assertEqual('FAILED', result['cleanupState'])
            self.assertEqual('DEGRADED', base.build_status(self.config)['health'])
            with self.assertRaises(OSError):
                self.lease(self.header([obj]))
        self.assertTrue((self.storage/'snapshots'/header['snapshotReceipt']['snapshotId']).exists())
        base.retain(self.config)
        self.assertEqual(1, chunks.status(self.config, base)['completedSnapshots'])

    def test_retained_cipher_corruption_blocks_all_deletions(self):
        obj, old = self.old_point()
        archive = self.archive()
        seed = self.seed(obj)
        self.commission(seed)
        path = self.storage/'objects'/obj['opaqueId']/'cipher.gpg'
        path.write_bytes(b'x'*len(self.fixture.cipher))
        before = set(self.storage.rglob('*'))
        with self.assertRaises(ValueError):
            base.retain(self.config)
        self.assertEqual(before, set(self.storage.rglob('*')))
        self.assertTrue((self.storage/archive['exportId']).exists())

    def test_full_submit_is_rejected_and_admin_export_is_ciphertext_only(self):
        archive = self.archive()
        self.enable()
        with self.assertRaises(ValueError):
            self.archive()
        output = io.BytesIO()
        latest.archive_bundle(self.config, base, chunks, archive['exportId'], output)
        output.seek(0)
        with tarfile.open(fileobj=output) as stream:
            self.assertEqual({'archive.gpg', 'source-receipt.json', 'target-receipt.json'}, set(stream.getnames()))
        self.assertEqual([], list((self.storage/'.archive-leases').iterdir()))
        with self.assertRaises(ValueError):
            self.send({'format': base.FORMAT, 'operation': 'commission-latest'})

    def test_interrupted_recursive_delete_resumes_only_detached_known_payload(self):
        obj, _ = self.old_point()
        seed = self.seed(obj)
        self.commission(seed)
        base.retain(self.config)
        header = self.header([obj])
        self.lease(header)
        original = latest.shutil.rmtree
        failed = False
        def partial_delete(path, *args, **kwargs):
            nonlocal failed
            if Path(path).name == 'payload' and not failed:
                failed = True
                (Path(path)/'target-receipt.json').unlink()
                raise OSError('SYNTHETIC INTERRUPTION AFTER ONE FILE')
            return original(path, *args, **kwargs)
        with patch.object(latest.shutil, 'rmtree', side_effect=partial_delete):
            target = self.send(header, self.fixture.manifest)
        self.assertEqual('FAILED', target['cleanupState'])
        self.assertTrue((self.storage/'snapshots'/target['snapshotId']).exists())
        self.assertEqual(1, chunks.status(self.config, base)['completedSnapshots'])
        self.assertTrue(any((self.storage/'.latest-retired').iterdir()))
        result = base.retain(self.config)
        self.assertEqual('COMPLETE', result['latestRotationCleanupState'])
        self.assertFalse(any((self.storage/'.latest-retired').iterdir()))

    def test_real_cli_loads_private_modules_and_uses_old_cipher_objects(self):
        obj, _ = self.old_point()
        self.enable()
        private = self.root/'installed'
        private.mkdir(mode=0o700)
        for name in ('continuous_backup.py', 'snapshot_chunks.py', 'latest_snapshot.py'):
            path = private/name
            shutil.copyfile(Path(__file__).with_name(name), path)
            path.chmod(0o600)
        settings = self.root/'receiver.json'
        base.atomic_json(settings, self.config)
        def cli(header, payload=b''):
            result = subprocess.run([sys.executable, '-I', str(private/'continuous_backup.py'),
                'receive', '--config', str(settings)], input=chunks.canonical(header)+b'\n'+payload,
                capture_output=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            return json.loads(result.stdout)
        header = self.header([obj])
        receipt = header['snapshotReceipt']
        leased = cli({'format': base.FORMAT, 'operation': 'beginSnapshotUpload',
            **{key: receipt[key] for key in latest.BINDINGS}, 'opaqueIds': [obj['opaqueId']]})
        original = (self.storage/'objects'/obj['opaqueId']/'cipher.gpg').read_bytes()
        probe = cli({'format': base.FORMAT, 'operation': 'probeChunks',
            'opaqueIds': [obj['opaqueId']], 'uploadLease': leased['leaseId']})
        self.assertEqual(obj, probe['objects'][0])
        header['uploadLease'] = leased['leaseId']
        target = cli(header, self.fixture.manifest)
        self.assertEqual('SNAPSHOT_CIPHERTEXT_COMPLETE', target['state'])
        self.assertEqual(original, (self.storage/'objects'/obj['opaqueId']/'cipher.gpg').read_bytes())
        self.assertEqual(2, chunks.status(self.config, base)['completedSnapshots'])

    def test_configuration_binding_is_opaque_and_decoder_preserves_old_v1(self):
        import test_restore_snapshot as restore_fixtures
        import restore_snapshot as restore
        fixture = restore_fixtures.ReconstructSnapshotTest()
        fixture.setUp()
        self.assertEqual(fixture.plain, fixture.reconstruct())
        version = chunks.recovery_configuration_identity(fixture.manifest['files'], fixture.secret)
        self.assertNotEqual(version, fixture.manifest['files'][-1]['sha256'])
        fixture.manifest['configurationVersion'] = version
        fixture.receipt['configurationVersion'] = version
        self.assertEqual(fixture.plain, fixture.reconstruct())
        fixture.receipt['configurationVersion'] = '0'*64
        with self.assertRaises(ValueError):
            fixture.reconstruct()

        fixture.receipt['configurationVersion'] = version
        fixture.manifest['files'][-1]['sha256'] = 'f'*64
        with self.assertRaises(ValueError):
            fixture.reconstruct()

    def test_wall_clock_rollback_and_reboot_never_resurrect_expired_upload_lease(self):
        obj, _ = self.old_point()
        self.enable()
        header = self.header([obj])
        lease = self.lease(header)
        with patch.object(latest, 'server_clock', return_value=(lease['bootId'], lease['expiresUptime']+1)):
            self.assertIsNone(latest.upload_state(self.config, base, chunks))
            with self.assertRaises(ValueError):
                self.send(header, self.fixture.manifest)
        with patch.object(latest, 'server_clock', return_value=('f'*8+'-'+ 'f'*4+'-'+'f'*4+'-'+'f'*4+'-'+'f'*12, 1)):
            self.assertIsNone(latest.upload_state(self.config, base, chunks))
            with self.assertRaises(ValueError):
                self.send(header, self.fixture.manifest)

    def test_observed_expired_commissioning_stays_expired_after_clock_rollback(self):
        obj, _ = self.old_point()
        seed = self.seed(obj)
        self.commission(seed)
        proof, _ = latest.commissioning(self.config, base)
        with patch.object(base, 'now', return_value=base.instant(proof['expiresAt'])+timedelta(seconds=1)):
            self.assertEqual('COMMISSIONING_EXPIRED', latest.commissioning(self.config, base)[1])
        self.assertEqual('COMMISSIONING_EXPIRED', latest.commissioning(self.config, base)[1])

    def test_real_gpg_and_signature_decode_optional_configuration_binding(self):
        import test_restore_snapshot as restore_fixtures
        import test_streamed_restore as resources
        import restore_snapshot as restore
        original_setup = restore_fixtures.ReconstructSnapshotTest.setUp
        original_sign = restore.chunks.sign_receipt
        original_restore = restore.restore_bundle
        version = None
        def setup_bound_fixture(fixture):
            nonlocal version
            original_setup(fixture)
            version = chunks.recovery_configuration_identity(fixture.manifest['files'], fixture.secret)
            fixture.manifest['configurationVersion'] = version
            fixture.receipt['configurationVersion'] = version
        def sign_bound_receipt(receipt, *args):
            receipt['configurationVersion'] = version
            return original_sign(receipt, *args)
        def decode_and_check(*args, **kwargs):
            report = original_restore(*args, **kwargs)
            self.assertEqual(version, report['configurationVersion'])
            return report
        # Reuse the real generated GPG/Ed25519 fixture, changing the bound input
        # protocol rather than duplicating its archive construction. The PG
        # consumer remains synthetic; this test never claims real DB recovery.
        runner = resources.StreamedRecoveryResourcesTest()
        with patch.object(restore_fixtures.ReconstructSnapshotTest, 'setUp', setup_bound_fixture), \
                patch.object(restore.chunks, 'sign_receipt', side_effect=sign_bound_receipt), \
                patch.object(restore, 'restore_bundle', side_effect=decode_and_check):
            runner.test_real_v1_signature_and_gpg_bundle_uses_disk_inputs_and_cleans_all_spools()


if __name__ == '__main__':
    unittest.main()
