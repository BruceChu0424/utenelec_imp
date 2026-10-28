"""Storage protocol regressions. All mutations are inside owned temporary roots."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid

import operations_storage as storage


class StorageTest(unittest.TestCase):
    def setUp(self):
        # A secure ancestor chain is deliberately part of the implementation.
        self.temp = tempfile.TemporaryDirectory(prefix='uten-storage-test-', dir=Path.home())
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.now = dt.datetime(2026, 10, 15, 18, tzinfo=dt.timezone.utc)
        self.config = {}
        for key in {v[0] for v in storage.KINDS.values()}:
            path = self.root / key
            path.mkdir(mode=0o700)
            self.config[key] = str(path)
        self.actor, self.request = str(uuid.uuid4()), str(uuid.uuid4())
        self.context = {'config': self.config, 'host_state_dir': self.state,
                        'actor_id': self.actor, 'request_id': self.request,
                        'lock_held': True, 'active_jobs': [], 'now': lambda: self.now}
        storage._CACHE.clear()

    def path(self, key, name):
        return Path(self.config[key]) / name

    def old(self, path, days=40):
        when = (self.now - dt.timedelta(days=days)).timestamp()
        os.utime(path, (when, when), follow_symlinks=False)
        return path

    def stage(self, name='.stage-v2.5.17.ABCDEF'):
        path = self.path('releases_root', name)
        path.mkdir(mode=0o700)
        (path / 'payload').write_bytes(b'public release data')
        self.old(path / 'payload')
        return self.old(path)

    def log(self, name='server.log.1.gz'):
        path = self.path('logs_root', name)
        path.write_bytes(b'closed compressed log')
        return self.old(path)

    def rows(self, kind):
        storage._CACHE.clear()
        return storage.dispatch('STORAGE_LIST', {'kind': kind}, self.context)['items']

    def preview(self, kind):
        rows = self.rows(kind)
        selected = [r['id'] for r in rows if r['canDelete']]
        return storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': selected}, self.context)

    def execute(self, preview):
        return storage.dispatch('STORAGE_DELETE', {'previewId': preview['previewId'], 'requestId': self.request}, self.context)

    def paired(self, index):
        name = f'202608{index:02d}T010000Z-0000000000{index:02d}'
        path = self.path('paired_backup_root', name)
        path.mkdir(mode=0o700)
        dump = b'PGDMP actual fixture ' + str(index).encode()
        (path / 'database.dump').write_bytes(dump)
        (path / 'database.dump').chmod(0o600)
        manifest = {'format': 'uten-paired-internal-v2', 'set_id': name,
                    'database_dump_bytes': len(dump), 'database_dump_sha256': hashlib.sha256(dump).hexdigest()}
        storage._write(path / 'manifest.json', manifest)
        self.old(path)
        return name, path

    def registry(self, entries, required=()):
        proofs = []
        for index, (name, path) in enumerate(entries):
            proofs.append({'kind': 'PAIRED_BACKUPS', 'resourceName': name,
                           'manifestSha256': hashlib.sha256((path / 'manifest.json').read_bytes()).hexdigest(),
                           'dumpSha256': hashlib.sha256((path / 'database.dump').read_bytes()).hexdigest(),
                           'verifiedAt': (self.now - dt.timedelta(days=20-index)).isoformat(),
                           'restoreExitCode': 0, 'sourceVersion': 'v2.5.16', 'flywayVersion': '864', 'flywayCount': 790,
                           'verificationMethod': 'ISOLATED_POSTGRES_RESTORE', 'restoreReceiptSha256': 'b' * 64,
                           'restoredFlywayVersion': '864', 'restoredFlywayCount': 790, 'restoredFlywayFailed': 0})
        value = {'format': 'uten-operations-recovery-proofs-v1', 'proofs': proofs,
                 'requiredReleaseVersions': ['v2.5.16'],
                 'requiredRollbackResources': [{'kind': 'PAIRED_BACKUPS', 'resourceName': name} for name in required]}
        storage._write(self.state / 'recovery-proofs.json', value)
        return value

    def pointer(self, entry):
        name, path = entry
        storage._write(Path(self.config['paired_backup_root']) / 'latest-success.json',
                       {'set_id': name, 'manifest_sha256': hashlib.sha256((path / 'manifest.json').read_bytes()).hexdigest()})
        lock = Path(self.config['paired_backup_root']) / '.backup.lock'
        lock.touch(mode=0o600)

    def test_no_request_can_supply_a_path_or_unrecognized_operation(self):
        for operation, payload in [('STORAGE_SUMMARY', {'path': '/'}), ('SHELL', {}),
                                   ('STORAGE_LIST', {'kind': '../DATABASE'}),
                                   ('STORAGE_LIST', {'kind': 'LOGS', 'limit': True})]:
            with self.subTest(operation=operation, payload=payload), self.assertRaises(storage.StorageError):
                storage.dispatch(operation, payload, self.context)

    def test_unknown_roots_are_null_and_not_zero(self):
        self.context['config'] = {}
        result = storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        self.assertEqual(result['status'], 'UNKNOWN')
        self.assertTrue(all(r['logicalBytes'] is None and not r['canList'] for r in result['categories']))

    def test_uploads_database_and_caches_are_always_protected(self):
        for kind, key in [('UPLOADS', 'uploads_root'), ('LEGACY_UPLOADS', 'legacy_uploads_root'),
                          ('DATABASE', 'database_root'), ('CACHE', 'cache_root')]:
            self.path(key, 'retained-history.dat').write_bytes(b'private original')
            row = self.rows(kind)[0]
            self.assertFalse(row['canDelete'])
            with self.assertRaises(storage.StorageError):
                storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [row['id']]}, self.context)

    def test_client_installers_and_updates_cannot_be_selected_for_ordinary_storage_cleanup(self):
        catalog = self.path('uploads_root', 'client-releases')
        catalog.mkdir(mode=0o700)
        (catalog / '.catalog.lock').touch(mode=0o600)
        for name in ('installer-package.bin', 'update-package.bin', 'withdrawn-release.json'):
            (catalog / name).write_bytes(b'private retained catalog fixture')
        rows = self.rows('UPLOADS')
        row = next(value for value in rows if value['label'] == 'client-releases')
        self.assertFalse(row['canDelete'])
        with self.assertRaises(storage.StorageError):
            storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [row['id']]}, self.context)
        self.assertEqual(4, len(list(catalog.iterdir())))

    def test_optional_legacy_root_is_separate_readonly_inventory_not_all_uploads_or_a_second_volume(self):
        self.path('uploads_root', 'current-original').write_bytes(b'new')
        self.path('legacy_uploads_root', 'legacy-original').write_bytes(b'old original')
        result = storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        current = next(c for c in result['categories'] if c['kind'] == 'UPLOADS')
        legacy = next(c for c in result['categories'] if c['kind'] == 'LEGACY_UPLOADS')
        self.assertEqual(current['logicalBytes'], 3)
        self.assertEqual(legacy['logicalBytes'], 12)
        self.assertEqual(current['count'], 1)
        self.assertEqual(legacy['count'], 1)
        self.assertIn('不包含兼容旧', current['detail'])
        self.assertIn('永不提供文件级清理', legacy['detail'])
        self.assertEqual(current['volumeId'], legacy['volumeId'])
        self.assertEqual(len(result['volumes']), 1 if hasattr(os, 'statvfs') else 0)
        resource = self.rows('LEGACY_UPLOADS')[0]
        self.assertEqual(resource['label'], 'legacy-original')
        self.assertFalse(resource['canDelete'])
        self.assertEqual(resource['reclaimableBytes'], 0)
        self.assertTrue(any('永不提供' in reason for reason in resource['protectionReasons']))
        self.assertTrue(self.path('legacy_uploads_root', 'legacy-original').is_file())

    def test_optional_legacy_root_absence_is_omitted_but_configured_missing_root_is_unknown(self):
        self.context['config'] = {k: v for k, v in self.config.items() if k != 'legacy_uploads_root'}
        absent = storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        self.assertFalse(any(c['kind'] == 'LEGACY_UPLOADS' for c in absent['categories']))
        storage._CACHE.clear()
        self.context['config']['legacy_uploads_root'] = str(self.root / 'missing-old-originals')
        present = storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        legacy = next(c for c in present['categories'] if c['kind'] == 'LEGACY_UPLOADS')
        self.assertEqual(legacy['status'], 'UNKNOWN')
        self.assertIsNone(legacy['logicalBytes'])
        self.assertFalse(legacy['canList'])

    @unittest.skipUnless(os.name == 'posix', 'requires Linux safe-delete primitives')
    def test_stale_stage_is_deleted_and_duplicate_request_is_same_receipt(self):
        path = self.stage()
        preview = self.preview('RELEASE_STAGING')
        result = self.execute(preview)
        self.assertEqual(result['status'], 'SUCCEEDED')
        self.assertFalse(path.exists())
        self.assertEqual(self.execute(preview), result)

    @unittest.skipUnless(os.name == 'posix', 'requires Linux safe-delete primitives')
    def test_closed_log_can_delete_but_current_uncompressed_and_recent_are_protected(self):
        target = self.log()
        self.log('server.log')
        self.log('server.log.2.gz')
        os.utime(self.path('logs_root', 'server.log.2.gz'), (self.now.timestamp(), self.now.timestamp()))
        rows = self.rows('LOGS')
        self.assertEqual([r['label'] for r in rows if r['canDelete']], ['server.log.1.gz'])
        self.assertEqual(self.execute(self.preview('LOGS'))['status'], 'SUCCEEDED')
        self.assertFalse(target.exists())
        self.assertTrue(self.path('logs_root', 'server.log').exists())

    @unittest.skipUnless(os.name == 'posix', 'requires Linux safe-delete primitives')
    def test_open_file_blocks_preview_and_close_allows_it(self):
        target = self.log()
        with target.open('rb'):
            with self.assertRaises(storage.StorageError) as error:
                self.preview('LOGS')
            self.assertEqual(error.exception.code, 'BUSY')
        self.assertIn('previewId', self.preview('LOGS'))

    @unittest.skipUnless(os.name == 'posix', 'requires Linux safe-delete primitives')
    def test_actor_expiry_and_content_changes_reject_before_delete(self):
        path = self.stage()
        preview = self.preview('RELEASE_STAGING')
        self.context['actor_id'] = str(uuid.uuid4())
        with self.assertRaises(storage.StorageError): self.execute(preview)
        self.context['actor_id'] = self.actor
        self.context['now'] = lambda: self.now + dt.timedelta(seconds=301)
        with self.assertRaises(storage.StorageError): self.execute(preview)
        self.context['now'] = lambda: self.now
        (path / 'payload').write_bytes(b'changed')
        self.assertEqual(self.execute(preview)['status'], 'FAILED')
        self.assertTrue(path.exists())

    @unittest.skipUnless(os.name == 'posix', 'requires Linux safe-delete primitives')
    def test_lock_and_live_job_are_authoritative(self):
        self.stage()
        preview = self.preview('RELEASE_STAGING')
        self.context['lock_held'] = False
        with self.assertRaises(storage.StorageError): self.execute(preview)
        self.context['lock_held'] = True
        self.context['active_jobs'] = [{'id': 'currently-updating'}]
        with self.assertRaises(storage.StorageError): self.execute(preview)

    @unittest.skipUnless(os.name == 'posix', 'requires symlinks')
    def test_symlinks_and_hardlinks_do_not_escape_cleanup(self):
        outside = self.root / 'important'
        outside.write_bytes(b'keep')
        stage = self.stage()
        (stage / 'link').symlink_to(outside)
        self.assertFalse(self.rows('RELEASE_STAGING')[0]['canDelete'])
        log = self.log()
        os.link(outside, log.with_name('server.log.2.gz'))
        self.assertFalse(next(r for r in self.rows('LOGS') if r['label'] == 'server.log.2.gz')['canDelete'])
        self.assertEqual(outside.read_bytes(), b'keep')

    @unittest.skipUnless(os.name == 'posix', 'requires Linux ownership and blocks')
    def test_hardlinks_measure_logical_allocation_and_reclaim_separately(self):
        folder = self.root / 'hardlinks'
        folder.mkdir()
        (folder / 'one').write_bytes(b'x' * 8192)
        os.link(folder / 'one', folder / 'two')
        one = storage._measure(folder / 'one')
        together = storage._measure(folder)
        self.assertEqual(one['reclaimableBytes'], 0)
        self.assertEqual(together['logicalBytes'], 16384)
        self.assertEqual(together['allocatedBytes'], one['allocatedBytes'] + together['directoryAllocatedBytes'])
        self.assertEqual(together['reclaimableBytes'], together['allocatedBytes'])

    def test_bounded_scan_is_unknown_not_a_partial_total(self):
        self.stage()
        with patch.object(storage, 'MAX_ENTRIES', 1):
            result = storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        row = next(c for c in result['categories'] if c['kind'] == 'RELEASE_STAGING')
        self.assertEqual(row['status'], 'UNKNOWN')
        self.assertIsNone(row['logicalBytes'])

    @unittest.skipUnless(os.name == 'posix', 'requires private backup permissions')
    def test_backups_without_actual_restore_proof_cannot_delete(self):
        entries = [self.paired(i) for i in range(1, 6)]
        self.pointer(entries[-1])
        self.assertTrue(all(not r['canDelete'] for r in self.rows('PAIRED_BACKUPS')))

    @unittest.skipUnless(os.name == 'posix', 'requires safe backup deletion')
    def test_verified_latest_floor_and_explicit_rollback_are_protected_old_excess_can_delete(self):
        entries = [self.paired(i) for i in range(1, 7)]
        self.pointer(entries[-1])
        self.registry([entries[0], entries[-1]], required=[entries[0][0]])
        rows = self.rows('PAIRED_BACKUPS')
        self.assertEqual([r['label'] for r in rows if r['canDelete']], [entries[1][0], entries[2][0]])
        preview = storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [rows[1]['id']]}, self.context)
        result = self.execute(preview)
        self.assertEqual(result['status'], 'SUCCEEDED')
        self.assertFalse(entries[1][1].exists())
        self.assertTrue(entries[0][1].exists())
        self.assertTrue(entries[-1][1].exists())

    @unittest.skipUnless(os.name == 'posix', 'requires private backup permissions')
    def test_corrupt_exact_proof_or_missing_latest_success_disables_backup_deletion(self):
        entries = [self.paired(i) for i in range(1, 6)]
        self.pointer(entries[-1])
        self.registry([entries[-1]])
        (entries[-1][1] / 'database.dump').write_bytes(b'corrupted')
        self.assertTrue(all(not r['canDelete'] for r in self.rows('PAIRED_BACKUPS')))

    @unittest.skipUnless(os.name == 'posix', 'requires formal backup lock')
    def test_formal_backup_lock_blocks_deletion_without_starting_a_second_backup(self):
        import fcntl
        entries = [self.paired(i) for i in range(1, 6)]
        self.pointer(entries[-1])
        self.registry([entries[-1]])
        preview = self.preview('PAIRED_BACKUPS')
        with (Path(self.config['paired_backup_root']) / '.backup.lock').open('r+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.execute(preview)['status'], 'FAILED')
        self.assertTrue(entries[0][1].exists())

    @unittest.skipUnless(os.name == 'posix', 'requires controlled deletion')
    def test_durable_intent_prevents_retry_after_interrupted_unlink(self):
        self.stage()
        preview = self.preview('RELEASE_STAGING')
        with patch.object(storage, '_delete_one', side_effect=OSError('private path not returned')) as delete:
            first = self.execute(preview)
            second = self.execute(preview)
        self.assertEqual(first, second)
        self.assertEqual(first['status'], 'FAILED')
        delete.assert_called_once()
        self.assertNotIn('private', json.dumps(first))
        rows = self.rows('RELEASE_STAGING')
        self.assertEqual(rows[0]['label'], '未完成清理隔离项')
        self.assertFalse(rows[0]['canDelete'])
        summary = storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        self.assertEqual(next(c for c in summary['categories'] if c['kind'] == 'RELEASE_STAGING')['status'], 'WARNING')

    def test_summary_polling_reuses_bounded_inventory(self):
        with patch.object(storage, '_inventory', wraps=storage._inventory) as inventory:
            storage.dispatch('STORAGE_SUMMARY', {}, self.context)
            storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        self.assertEqual(inventory.call_count, 1)

    @unittest.skipUnless(os.name == 'posix', 'requires controlled cleanup')
    def test_old_stage_with_recently_overwritten_child_is_not_abandoned(self):
        path = self.stage()
        os.utime(path / 'payload', (self.now.timestamp(), self.now.timestamp()))
        self.assertFalse(self.rows('RELEASE_STAGING')[0]['canDelete'])

    @unittest.skipUnless(os.name == 'posix', 'requires symlinks')
    def test_configured_symlink_root_is_unknown_and_never_enumerated(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'private-name').write_bytes(b'private')
        link = self.root / 'unsafe-root'
        link.symlink_to(outside)
        self.context['config'] = {**self.config, 'logs_root': str(link)}
        summary = storage.dispatch('STORAGE_SUMMARY', {}, self.context)
        self.assertIsNone(next(c for c in summary['categories'] if c['kind'] == 'LOGS')['logicalBytes'])
        self.assertNotIn('private-name', json.dumps(summary))

    @unittest.skipUnless(os.name == 'posix', 'requires controlled cleanup')
    def test_two_excess_backup_sets_with_shared_hardlinks_can_be_cleaned_as_one_batch(self):
        entries = [self.paired(i) for i in range(1, 7)]
        shared = entries[0][1] / 'shared-object'
        shared.write_bytes(b'x' * 8192)
        os.link(shared, entries[1][1] / 'shared-object')
        self.old(entries[0][1])
        self.old(entries[1][1])
        self.pointer(entries[-1])
        self.registry([entries[-1]])
        rows = self.rows('PAIRED_BACKUPS')
        preview = storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [r['id'] for r in rows[:2]]}, self.context)
        self.assertGreater(preview['totalReclaimableBytes'], sum(r['reclaimableBytes'] for r in rows[:2]))
        result = self.execute(preview)
        self.assertEqual(result['status'], 'SUCCEEDED')
        self.assertEqual(result['deletedCount'], 2)
        self.assertEqual(result['reclaimedBytes'], preview['totalReclaimableBytes'])
        self.assertTrue(entries[-1][1].exists())

    @unittest.skipUnless(os.name == 'posix', 'requires private backup permissions')
    def test_preactivation_dump_uses_restore_proof_newest_three_and_name_time(self):
        entries = []
        for index in range(1, 6):
            path = self.path('preactivation_backup_root', f'uten_imp-v2.5.16-202608{index:02d}-010000.ABCDEF.dump')
            path.write_bytes(b'dump ' + str(index).encode())
            path.chmod(0o600)
            self.old(path)
            entries.append(path)
        proof = {'kind': 'PREACTIVATION_BACKUPS', 'resourceName': entries[-1].name,
                 'dumpSha256': hashlib.sha256(entries[-1].read_bytes()).hexdigest(),
                 'verifiedAt': self.now.isoformat(), 'restoreExitCode': 0, 'sourceVersion': 'v2.5.16',
                 'flywayVersion': '864', 'flywayCount': 790, 'verificationMethod': 'ISOLATED_POSTGRES_RESTORE',
                 'restoreReceiptSha256': 'b' * 64, 'restoredFlywayVersion': '864', 'restoredFlywayCount': 790, 'restoredFlywayFailed': 0}
        storage._write(self.state / 'recovery-proofs.json', {'format': 'uten-operations-recovery-proofs-v1',
                       'proofs': [proof], 'requiredReleaseVersions': ['v2.5.16'], 'requiredRollbackResources': []})
        rows = self.rows('PREACTIVATION_BACKUPS')
        self.assertEqual([r['label'] for r in rows if r['canDelete']], [p.name for p in entries[:2]])
        preview = storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [rows[0]['id']]}, self.context)
        self.assertEqual(self.execute(preview)['status'], 'SUCCEEDED')
        self.assertFalse(entries[0].exists())
        self.assertTrue(entries[-1].exists())

    def _preactivation_fixture(self, count=6, rollback=False):
        entries = []
        for index in range(count):
            created = dt.date(2026, 8, 1) + dt.timedelta(days=index)
            path = self.path('preactivation_backup_root', f'uten_imp-v2.5.16-{created:%Y%m%d}-010000.ABCDEF.dump')
            path.write_bytes(b'backup ' + str(index).encode())
            path.chmod(0o600)
            self.old(path)
            entries.append(path)
        proofs = []
        for index, path in enumerate([entries[0], entries[-1]] if rollback else [entries[-1]]):
            proofs.append({'kind': 'PREACTIVATION_BACKUPS', 'resourceName': path.name,
                           'dumpSha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                           'verifiedAt': (self.now - dt.timedelta(minutes=2-index)).isoformat(),
                           'restoreExitCode': 0, 'sourceVersion': 'v2.5.16',
                           'flywayVersion': '864', 'flywayCount': 790, 'verificationMethod': 'ISOLATED_POSTGRES_RESTORE',
                           'restoreReceiptSha256': 'b' * 64, 'restoredFlywayVersion': '864',
                           'restoredFlywayCount': 790, 'restoredFlywayFailed': 0})
        registry = {'format': 'uten-operations-recovery-proofs-v1', 'proofs': proofs,
                    'requiredReleaseVersions': ['v2.5.16'],
                    'requiredRollbackResources': [{'kind': 'PREACTIVATION_BACKUPS', 'resourceName': entries[0].name}] if rollback else []}
        storage._write(self.state / 'recovery-proofs.json', registry)
        return entries, registry

    @unittest.skipUnless(os.name == 'posix', 'requires protected filesystem deletion')
    def test_automatic_preactivation_prune_reuses_proof_floor_and_rollback_without_touching_other_kinds(self):
        paired = [self.paired(i) for i in range(1, 6)]
        self.pointer(paired[-1])
        paired_registry = self.registry([paired[-1]])
        entries, registry = self._preactivation_fixture(rollback=True)
        registry['proofs'].extend(paired_registry['proofs'])
        storage._write(self.state / 'recovery-proofs.json', registry)
        stage, log = self.stage(), self.log()
        result = storage.prune_preactivation_backups(self.context)
        self.assertEqual('SUCCEEDED', result['status'])
        self.assertEqual(2, result['deletedCount'])
        self.assertEqual(0, result['deferredCount'])
        self.assertTrue(entries[0].exists(), 'explicit rollback point remains protected')
        self.assertTrue(all(p.exists() for p in entries[-3:]), 'newest three complete dumps remain')
        self.assertTrue(all(not p.exists() for p in entries[1:3]))
        self.assertTrue(all(p.exists() for _, p in paired))
        self.assertTrue(stage.exists())
        self.assertTrue(log.exists())
        receipt = json.loads((self.state / ('storage-result-' + self.request + '.json')).read_text())
        self.assertEqual(result['previewId'], receipt['previewId'])
        self.assertEqual('SUCCEEDED', receipt['result']['status'])

    @unittest.skipUnless(os.name == 'posix', 'requires private backup inventory')
    def test_automatic_preactivation_prune_without_actual_restore_proof_deletes_nothing(self):
        entries, _ = self._preactivation_fixture()
        (self.state / 'recovery-proofs.json').unlink()
        result = storage.prune_preactivation_backups(self.context)
        self.assertEqual('SKIPPED', result['status'])
        self.assertEqual(0, result['deletedCount'])
        self.assertTrue(all(p.exists() for p in entries))
        self.assertFalse(list(self.state.glob('storage-result-*.json')))

    def test_automatic_preactivation_prune_requires_mutation_locks_and_no_active_job(self):
        for extra in ({'lock_held': False}, {'active_jobs': [{'state': 'RUNNING'}]}):
            with self.subTest(extra=extra), self.assertRaises(storage.StorageError) as caught:
                storage.prune_preactivation_backups({**self.context, **extra})
            self.assertEqual('BUSY', caught.exception.code)

    @unittest.skipUnless(os.name == 'posix', 'requires protected filesystem deletion')
    def test_automatic_preactivation_prune_respects_batch_limit_and_reports_deferred_candidates(self):
        entries, _ = self._preactivation_fixture(count=60)
        result = storage.prune_preactivation_backups(self.context)
        self.assertEqual(('SUCCEEDED', 50, 7), (result['status'], result['deletedCount'], result['deferredCount']))
        self.assertEqual(10, sum(p.exists() for p in entries))
        self.assertTrue(all(p.exists() for p in entries[-3:]))

    @unittest.skipUnless(os.name == 'posix', 'requires protected filesystem deletion')
    def test_automatic_preactivation_prune_revalidates_restore_proof_before_deleting(self):
        entries, _ = self._preactivation_fixture()
        dispatch = storage.dispatch
        def change_proof(operation, payload, context):
            if operation == 'STORAGE_DELETE':
                (self.state / 'recovery-proofs.json').unlink()
            return dispatch(operation, payload, context)
        with patch.object(storage, 'dispatch', side_effect=change_proof):
            result = storage.prune_preactivation_backups(self.context)
        self.assertEqual('FAILED', result['status'])
        self.assertEqual(0, result['deletedCount'])
        self.assertTrue(all(p.exists() for p in entries))

    @unittest.skipUnless(os.name == 'posix', 'requires controlled release cleanup')
    def test_installed_release_protects_current_rollback_and_latest_three_but_cleans_old_excess(self):
        entry = self.paired(1)
        self.pointer(entry)
        value = self.registry([entry])
        value['requiredReleaseVersions'] = ['v2.5.16']
        value['proofs'][0]['sourceVersion'] = 'v2.5.10'
        storage._write(self.state / 'recovery-proofs.json', value)
        root = Path(self.config['releases_root'])
        for patch_number in range(10, 17):
            path = root / f'v2.5.{patch_number}'
            path.mkdir(mode=0o700)
            (path / 'public-program').write_bytes(b'jar bytes')
            self.old(path / 'public-program')
            self.old(path)
        current = root.parent / 'current'
        current.symlink_to(root / 'v2.5.16')
        rows = self.rows('RELEASES')
        self.assertEqual([r['label'] for r in rows if r['canDelete']], ['v2.5.11', 'v2.5.12', 'v2.5.13'])
        target = next(r for r in rows if r['label'] == 'v2.5.12')
        preview = storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [target['id']]}, self.context)
        current.unlink()
        current.symlink_to(root / 'v2.5.12')
        self.assertEqual(self.execute(preview)['status'], 'FAILED')
        self.assertTrue((root / 'v2.5.12').exists())
        current.unlink()
        current.symlink_to(root / 'v2.5.16')
        self.request = str(uuid.uuid4())
        self.context['request_id'] = self.request
        preview = storage.dispatch('STORAGE_PREVIEW_DELETE', {'resourceIds': [target['id']]}, self.context)
        self.assertEqual(self.execute(preview)['status'], 'SUCCEEDED')
        self.assertTrue((root / 'v2.5.10').exists())
        self.assertTrue((root / 'v2.5.16').exists())

    @unittest.skipUnless(os.name == 'posix', 'requires shared lock observation')
    def test_receipt_poll_is_actor_bound_and_marks_abandoned_intent_without_replaying_delete(self):
        import fcntl
        path = self.state / ('storage-result-' + self.request + '.json')
        receipt = {'actorId': self.actor, 'previewId': str(uuid.uuid4()), 'result': {
            'requestId': self.request, 'status': 'RUNNING', 'deletedCount': 1, 'reclaimedBytes': 4096, 'detail': 'running'}}
        storage._write(path, receipt)
        lock_path = self.state / 'operations.lock'
        lock_path.touch(mode=0o600)
        with lock_path.open('r+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = storage.dispatch('STORAGE_RESULT', {'requestId': self.request}, self.context)
            self.assertEqual(result['status'], 'RUNNING')
        with patch.object(storage, '_delete_one') as delete:
            result = storage.dispatch('STORAGE_RESULT', {'requestId': self.request}, self.context)
            self.assertEqual(result['status'], 'RECOVERY_REQUIRED')
            self.assertEqual(result['deletedCount'], 1)
            delete.assert_not_called()
        self.context['actor_id'] = str(uuid.uuid4())
        with self.assertRaises(storage.StorageError) as error:
            storage.dispatch('STORAGE_RESULT', {'requestId': self.request}, self.context)
        self.assertEqual(error.exception.code, 'FORBIDDEN')

    def test_missing_receipt_is_not_found_and_never_claims_no_execution(self):
        with self.assertRaises(storage.StorageError) as error:
            storage.dispatch('STORAGE_RESULT', {'requestId': self.request}, self.context)
        self.assertEqual(error.exception.code, 'NOT_FOUND')

    def test_incomplete_backups_are_visible_for_footprint_but_never_deletable(self):
        path = self.path('paired_backup_root', '.incomplete-20260801T010000Z-000000000001')
        path.mkdir(mode=0o700)
        (path / 'database.dump').write_bytes(b'incomplete bytes')
        self.old(path)
        rows = self.rows('PAIRED_BACKUPS')
        self.assertEqual(len(rows), 1)
        self.assertGreater(rows[0]['logicalBytes'], 0)
        self.assertFalse(rows[0]['canDelete'])

    @unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0, 'root-only restore proof registry')
    def test_root_registration_binds_real_restore_metadata_to_exact_backup_and_current_version(self):
        entries = [self.paired(i) for i in range(1, 5)]
        self.pointer(entries[-1])
        value = self.registry([entries[-1]])
        (self.state / 'recovery-proofs.json').unlink()
        (Path(self.config['releases_root']) / 'v2.5.16').mkdir(mode=0o700)
        (Path(self.config['releases_root']).parent / 'current').symlink_to(Path(self.config['releases_root']) / 'v2.5.16')
        payload = {'proof': value['proofs'][0], 'requiredReleaseVersions': ['v2.5.16'], 'requiredRollbackResources': []}
        self.assertTrue(storage.record_restore_proof(payload, self.context)['recorded'])
        proof = json.loads((self.state / 'recovery-proofs.json').read_text())['proofs'][0]
        self.assertEqual(proof['dumpSha256'], value['proofs'][0]['dumpSha256'])
        payload['proof'] = {**payload['proof'], 'verificationMethod': 'VERIFY_SET'}
        with self.assertRaises(storage.StorageError): storage.record_restore_proof(payload, self.context)
        self.assertEqual(json.loads((self.state / 'recovery-proofs.json').read_text())['proofs'][0], proof)

    @unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0, 'root-only restore proof registry')
    def test_registry_rejects_catalog_mismatch_and_changed_dump_without_overwriting_evidence(self):
        entry = self.paired(1)
        self.pointer(entry)
        value = self.registry([entry])
        (Path(self.config['releases_root']) / 'v2.5.16').mkdir(mode=0o700)
        (Path(self.config['releases_root']).parent / 'current').symlink_to(Path(self.config['releases_root']) / 'v2.5.16')
        original = (self.state / 'recovery-proofs.json').read_bytes()
        payload = {'proof': {**value['proofs'][0], 'restoredFlywayCount': 789},
                   'requiredReleaseVersions': ['v2.5.16'], 'requiredRollbackResources': []}
        with self.assertRaises(storage.StorageError): storage.record_restore_proof(payload, self.context)
        payload['proof'] = value['proofs'][0]
        (entry[1] / 'database.dump').write_bytes(b'changed')
        with self.assertRaises(storage.StorageError): storage.record_restore_proof(payload, self.context)
        self.assertEqual((self.state / 'recovery-proofs.json').read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
