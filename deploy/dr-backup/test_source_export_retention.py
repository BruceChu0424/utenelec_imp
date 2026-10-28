"""Source cache rotation against private synthetic files; no live backups/network."""
from datetime import timedelta
import hashlib
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

import continuous_backup as backup


class SourceExportRetentionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='uten-source-retention-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.config = {'source_export_directory': str(self.root)}
        self.counter = 0

    def archive(self, days=3, *, acknowledged=True, changes=None):
        self.counter += 1
        moment = backup.now() - timedelta(days=days)
        stamp = moment.strftime('%Y%m%dT%H%M%SZ')
        name = f'sealed-{stamp}-{self.counter:012x}'
        directory = self.root / name
        directory.mkdir(mode=0o700)
        payload = b'SYNTHETIC CIPHERTEXT ' + str(self.counter).encode()
        archive = directory / 'archive.gpg'
        archive.write_bytes(payload)
        archive.chmod(0o600)
        source = {'format': 'uten-sealed-paired-v1', 'exportId': name,
                  'state': 'CIPHERTEXT_CREATED', 'sourceSetId': f'{stamp}-{self.counter:012x}',
                  'sourceManifestSha256': 'a' * 64,
                  'ciphertextSha256': hashlib.sha256(payload).hexdigest(), 'ciphertextBytes': len(payload)}
        target = {**source, 'format': backup.FORMAT, 'state': 'TARGET_BYTES_VERIFIED',
                  'receivedAt': moment.isoformat()}
        target.update(changes or {})
        backup.atomic_json(directory / 'receipt.json', source)
        if acknowledged:
            backup.atomic_json(directory / 'target-receipt.json', target)
        return directory

    def test_removes_only_old_fully_bound_acknowledged_copies_and_preserves_newest(self):
        expired = self.archive()
        newest = self.archive()
        recent = self.archive(days=1)
        unacknowledged = self.archive(acknowledged=False)
        unknown = self.archive()
        (unknown / 'manual-evidence').write_bytes(b'KEEP')
        result = backup.prune_source_exports(self.config, newest)
        self.assertEqual('APPLIED', result['status'])
        self.assertEqual(1, result['removedSets'])
        self.assertFalse(expired.exists())
        for protected in (newest, recent, unacknowledged, unknown):
            self.assertTrue(protected.exists())

    def test_mismatched_receipts_never_authorize_source_deletion(self):
        for changes in ({'exportId': 'another-export'}, {'sourceSetId': 'bad'},
                        {'sourceManifestSha256': 'b' * 64}, {'ciphertextSha256': 'c' * 64},
                        {'ciphertextBytes': 1}, {'ciphertextSha256': None}, {'ciphertextBytes': True},
                        {'format': 'untrusted'}, {'state': 'FAILED'}):
            with self.subTest(changes=changes):
                candidate = self.archive(changes=changes)
                backup.prune_source_exports(self.config)
                self.assertTrue(candidate.exists())

    def test_invalid_evidence_aborts_plan_before_any_deletion(self):
        valid = self.archive()
        damaged = self.archive()
        (damaged / 'target-receipt.json').write_text('{bad')
        with self.assertRaises(ValueError):
            backup.prune_source_exports(self.config)
        self.assertTrue(valid.exists())
        self.assertTrue(damaged.exists())

    def test_symlinked_source_copy_never_deletes_its_target(self):
        outside = self.root / 'outside'
        outside.mkdir(mode=0o700)
        (outside / 'keep').write_bytes(b'KEEP')
        linked = self.root / 'sealed-20200101T010000Z-000000000001'
        linked.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            backup.prune_source_exports(self.config)
        self.assertEqual(b'KEEP', (outside / 'keep').read_bytes())

    def test_latest_mode_pending_commissioning_keeps_all_old_archives(self):
        candidate = self.archive()
        for state in ('BLOCKED_COMMISSIONING', 'FAILED', None):
            with self.subTest(state=state):
                status = {'cleanupState': state, 'latest': {'snapshotId': 'new-point'}, 'health': 'DEGRADED'}
                backup.finish_source_export_retention({**self.config, 'retention_mode': 'latest_snapshot'}, status)
                self.assertEqual('PROTECTED_PENDING_COMMISSIONING', status['sourceExportCleanup']['status'])
                self.assertTrue(candidate.exists())

    def test_successful_commissioned_snapshot_path_runs_the_shared_source_policy(self):
        candidate = self.archive()
        status = {'cleanupState': 'COMPLETE', 'latest': {'snapshotId': 'new-point'}, 'health': 'HEALTHY'}
        backup.finish_source_export_retention({**self.config, 'retention_mode': 'latest_snapshot'}, status)
        self.assertFalse(candidate.exists())
        self.assertEqual(1, status['sourceExportCleanup']['removedSets'])
        self.assertEqual({'snapshotId': 'new-point'}, status['latest'])

    def test_source_cleanup_failure_is_visible_without_losing_acknowledged_snapshot(self):
        status = {'cleanupState': 'COMPLETE', 'latest': {'snapshotId': 'new-point'}, 'health': 'HEALTHY'}
        with patch.object(backup, 'prune_source_exports', side_effect=OSError('PRIVATE HOST DETAILS')):
            backup.finish_source_export_retention(self.config, status)
        self.assertEqual('DEGRADED', status['health'])
        self.assertEqual({'status': 'FAILED'}, status['sourceExportCleanup'])
        self.assertEqual({'snapshotId': 'new-point'}, status['latest'])
        self.assertNotIn('PRIVATE', json.dumps(status))

    def test_parallel_archive_and_snapshot_gc_share_one_mutex_and_retry_cleanly(self):
        candidate = self.archive()
        entered, release = threading.Event(), threading.Event()
        original = backup._prune_source_exports_locked
        results, failures = [], []

        def paused(root, newest):
            entered.set()
            if not release.wait(5):
                raise TimeoutError('fixture synchronization')
            return original(root, newest)

        def first_upload():
            try:
                results.append(backup.prune_source_exports(self.config))
            except BaseException as error:
                failures.append(error)

        with patch.object(backup, '_prune_source_exports_locked', side_effect=paused):
            thread = threading.Thread(target=first_upload)
            thread.start()
            try:
                self.assertTrue(entered.wait(5))
                status = {'health': 'HEALTHY', 'latest': {'snapshotId': 'new-point'}}
                backup.finish_source_export_retention(self.config, status)
                self.assertEqual('DEFERRED', status['sourceExportCleanup']['status'])
                self.assertEqual('HEALTHY', status['health'])
                self.assertTrue(candidate.exists())
            finally:
                release.set()
                thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual([], failures)
        self.assertEqual(1, results[0]['removedSets'])
        self.assertFalse(candidate.exists())
        self.assertEqual(0, backup.prune_source_exports(self.config)['removedSets'])


if __name__ == '__main__':
    unittest.main()
