"""Private-volume capture limits and real constrained-process payload regressions."""
import hashlib
import json
import os
import signal
import resource
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import continuous_backup as base
import snapshot_chunks as chunks


class SnapshotSpoolTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='uten-snapshot-spool-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.exports = self.root / 'exports'
        self.exports.mkdir(mode=0o700)
        self.config = {'source_export_directory': str(self.exports),
                       'snapshot_spool_mountpoint': str(self.root),
                       'max_snapshot_plain_bytes': chunks.MAX_SNAPSHOT_PLAIN_BYTES,
                       'snapshot_spool_min_free_bytes': 0}
        self.source = self.root / 'data'
        self.source.write_bytes(b'ONE-CONSISTENT-SOURCE' * 100)
        self.sealed = SimpleNamespace(safe_path=lambda path: path.lstat())
        mounted = patch.object(chunks.os.path, 'ismount', return_value=True)
        mounted.start()
        self.addCleanup(mounted.stop)

    def capture(self, stage):
        return chunks.capture_files([(self.source, 'paired/test/database.dump')], stage,
                                    b'x' * 32, self.sealed, self.config, base)

    def test_capture_is_private_file_backed_and_does_not_depend_on_later_source_bytes(self):
        stage = chunks.create_source_spool(self.config, base)
        captured, files, total = self.capture(stage)
        original = self.source.read_bytes()
        self.source.write_bytes(b'CHANGED-AFTER-CAPTURE')
        self.assertEqual(total, len(original))
        self.assertEqual(files[0]['sha256'], hashlib.sha256(original).hexdigest())
        for record in captured.values():
            self.assertIsInstance(record['path'], Path)
            self.assertEqual(original, record['path'].read_bytes())
            self.assertEqual(0, record['path'].stat().st_mode & 0o077)
        self.assertEqual(0, stage.stat().st_mode & 0o077)
        chunks.remove_spool(stage, base)
        self.assertFalse(stage.exists())

    def test_plaintext_limit_and_disk_reserve_fail_before_partial_payload_capture(self):
        for kind in ('limit', 'space'):
            with self.subTest(kind=kind):
                stage = chunks.create_source_spool(self.config, base)
                if kind == 'limit':
                    self.config['max_snapshot_plain_bytes'] = 100
                    with self.assertRaises(base.TransferFailure) as failure:
                        self.capture(stage)
                    self.assertEqual('SOURCE_SNAPSHOT_LIMIT', failure.exception.code)
                else:
                    self.config['max_snapshot_plain_bytes'] = chunks.MAX_SNAPSHOT_PLAIN_BYTES
                    with patch.object(chunks.shutil, 'disk_usage', return_value=SimpleNamespace(free=100)):
                        with self.assertRaises(base.TransferFailure) as failure:
                            self.capture(stage)
                    self.assertEqual('SOURCE_SPOOL_CAPACITY', failure.exception.code)
                self.assertFalse((stage / 'plain').exists())
                chunks.remove_spool(stage, base)

    def test_previous_crashed_owned_capture_is_removed_but_unknown_lease_is_retained(self):
        abandoned = chunks.create_source_spool(self.config, base)
        self.capture(abandoned)
        next_stage = chunks.create_source_spool(self.config, base)
        self.assertFalse(abandoned.exists())
        marker = next_stage / 'capture-lease.json'
        value = base.read_json(marker)
        value['inode'] += 1
        base.atomic_json(marker, value)
        with self.assertRaises(ValueError):
            chunks.create_source_spool(self.config, base)
        self.assertTrue(next_stage.exists())

    def test_backup_root_or_spool_symlink_never_becomes_an_arbitrary_cleanup_target(self):
        outside = self.root / 'outside'
        outside.mkdir(mode=0o700)
        sentinel = outside / 'keep'
        sentinel.write_bytes(b'KEEP')
        (self.exports / '.snapshot-spool').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            chunks.create_source_spool(self.config, base)
        self.assertEqual(b'KEEP', sentinel.read_bytes())

    def test_absent_backup_mount_fails_without_creating_any_spool(self):
        with patch.object(chunks.os.path, 'ismount', return_value=False):
            with self.assertRaises(base.TransferFailure) as failure:
                chunks.create_source_spool(self.config, base)
        self.assertEqual('SOURCE_SPOOL_UNMOUNTED', failure.exception.code)
        self.assertFalse((self.exports / '.snapshot-spool').exists())

    def test_capture_deadline_is_bounded_without_enlarging_the_service_budget(self):
        stage = chunks.create_source_spool(self.config, base)
        with self.assertRaises(base.TransferFailure) as failure:
            chunks.capture_files([(self.source, 'paired/test/database.dump')], stage,
                b'x' * 32, self.sealed, self.config, base, deadline=base.time.monotonic() - 1)
        self.assertEqual('TRANSFER_DEADLINE_EXCEEDED', failure.exception.code)
        chunks.remove_spool(stage, base)

    def test_explicit_budgets_match_reviewed_unit_with_cleanup_margin_and_reject_unknown_fields(self):
        self.assertEqual((210, 240), base.run_budget({}, 'snapshot'))
        self.assertEqual((2070, 2100), base.run_budget({}, 'archive'))
        self.assertEqual((870, 900), base.run_budget({'snapshot_budget_seconds': 870,
                         'snapshot_unit_timeout_seconds': 900}, 'snapshot'))
        for invalid in ({'snapshot_budget_seconds': 240}, {'snapshot_budget_seconds': True},
                        {'snapshot_unit_timeout_seconds': 901}, {'network_budget_seconds': 900}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                base.run_budget(invalid, 'snapshot')

    def test_archive_generation_limit_is_inherited_by_real_writer_and_parent_is_restored(self):
        previous = resource.getrlimit(resource.RLIMIT_FSIZE)
        output = self.root / 'synthetic-cipher.gpg'
        with base.bounded_archive_files(1024 * 1024), output.open('wb') as stream:
            result = subprocess.run([sys.executable, '-I', '-c',
                'import os; raw=b"SYNTHETIC"*8192\nwhile True: os.write(1,raw)'],
                stdout=stream, stderr=subprocess.DEVNULL, timeout=5)
        self.assertNotEqual(0, result.returncode)
        self.assertLessEqual(output.stat().st_size, 1024 * 1024)
        self.assertEqual(previous, resource.getrlimit(resource.RLIMIT_FSIZE))
        for invalid in (True, 0, base.MAX_ARCHIVE_BYTES + 1):
            with self.assertRaises(ValueError):
                base.archive_limit({'max_archive_bytes': invalid})

    def test_cli_sigterm_cleans_owned_spool_and_records_cancellation(self):
        state = self.root / 'state'
        state.mkdir(mode=0o700)
        helper = self.root / 'slow_helper.py'
        helper.write_text('import time\ntime.sleep(30)\n')
        config = {**self.config, 'state_directory': str(state), 'paired_helper': str(helper),
                  'paired_config': str(self.root / 'unused-paired.json')}
        settings = self.root / 'source.json'
        settings.write_text(json.dumps(config))
        settings.chmod(0o600)
        program = ('import sys; sys.path.insert(0,sys.argv[1]); '
                   'import continuous_backup as base,snapshot_chunks as chunks; '
                   'chunks.os.path.ismount=lambda _:True; '
                   'base.chunks_module=lambda:chunks; sys.argv=["backup","snapshot","--config",sys.argv[2]]; '
                   'raise SystemExit(base.main())')
        child = subprocess.Popen([sys.executable, '-I', '-B', '-c', program,
            str(Path(__file__).parent), str(settings)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            import time
            end = time.monotonic() + 5
            while not list(self.exports.glob('.snapshot-spool/.snapshot-*/capture-lease.json')):
                self.assertIsNone(child.poll())
                if time.monotonic() >= end:
                    self.fail('Synthetic CLI did not create its owned spool')
                time.sleep(.01)
            child.send_signal(signal.SIGTERM)
            _, error = child.communicate(timeout=5)
            self.assertEqual(1, child.returncode, error)
            status = base.read_json(state / 'snapshot-status.json')
            self.assertEqual('TRANSFER_CANCELLED', status['errorCode'])
            self.assertEqual('FAILED', status['state'])
            self.assertFalse(any((self.exports / '.snapshot-spool').iterdir()))
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)

    def test_sigterm_after_atomic_marker_publication_cleans_creation_window(self):
        publish = base.atomic_json
        def publish_then_terminate(path, value):
            publish(path, value)
            os.kill(os.getpid(), signal.SIGTERM)
        previous_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
        with base.bounded_archive_files(1024 * 1024), base.bounded_source_job({}, 'snapshot'), \
                patch.object(base, 'atomic_json', side_effect=publish_then_terminate):
            with self.assertRaises(base.TransferFailure) as failure:
                chunks.create_source_spool(self.config, base)
        self.assertEqual('TRANSFER_CANCELLED', failure.exception.code)
        self.assertFalse(any((self.exports / '.snapshot-spool').iterdir()))
        self.assertEqual(previous_limit, resource.getrlimit(resource.RLIMIT_FSIZE))

    def test_creation_failure_never_deletes_replacement_directory_or_masks_original_error(self):
        publish = base.atomic_json
        def publish_then_replace(path, value):
            publish(path, value)
            original = path.parent
            original.rename(original.with_name(original.name + '-retained'))
            original.mkdir(mode=0o700)
            (original / 'unknown-content').write_bytes(b'KEEP-UNKNOWN')
            raise base.TransferFailure('TRANSFER_CANCELLED')
        with patch.object(base, 'atomic_json', side_effect=publish_then_replace):
            with self.assertRaises(base.TransferFailure) as failure:
                chunks.create_source_spool(self.config, base)
        self.assertEqual('TRANSFER_CANCELLED', failure.exception.code)
        unknown = list((self.exports / '.snapshot-spool').glob('.snapshot-*/unknown-content'))
        self.assertEqual(1, len(unknown))
        self.assertEqual(b'KEEP-UNKNOWN', unknown[0].read_bytes())
        self.assertTrue(base.failure_record(failure.exception)['cleanupRequired'])

    def test_cancellation_after_create_returns_before_caller_assignment_still_cleans_spool(self):
        state = self.root / 'handoff-state'
        state.mkdir(mode=0o700)
        create = chunks.create_source_spool
        def created_then_terminate(*args, **kwargs):
            create(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGTERM)
        with base.bounded_source_job({}, 'snapshot'), patch.object(chunks, 'create_source_spool', side_effect=created_then_terminate):
            with self.assertRaises(base.TransferFailure) as failure:
                chunks.run_source({**self.config, 'state_directory': str(state)}, base)
        self.assertEqual('TRANSFER_CANCELLED', failure.exception.code)
        self.assertFalse(any((self.exports / '.snapshot-spool').iterdir()))

    @unittest.skipUnless(sys.platform == 'linux', 'Real Linux address-space and spool contract')
    def test_six_hundred_mib_unique_payload_captures_below_160_mib_address_space(self):
        # All bytes are generated from deterministic synthetic seeds. No real
        # dump, environment, keys, database or network is opened by this child.
        program = textwrap.dedent('''
            import hashlib,json,resource,sys,tempfile,time
            from pathlib import Path
            from types import SimpleNamespace
            sys.path.insert(0,sys.argv[1])
            import continuous_backup as base
            import snapshot_chunks as chunks
            chunks.os.path.ismount=lambda _:True
            resource.setrlimit(resource.RLIMIT_AS,(160*1024**2,160*1024**2))
            with tempfile.TemporaryDirectory(prefix='uten-synthetic-large-capture-') as temporary:
                root=Path(temporary);root.chmod(0o700)
                exports=root/'exports';exports.mkdir(mode=0o700)
                source=root/'synthetic.dump';whole=hashlib.sha256()
                with source.open('wb') as stream:
                    for index in range(1200):
                        raw=hashlib.shake_256(('SYNTHETIC-'+str(index)).encode()).digest(chunks.CHUNK_BYTES)
                        stream.write(raw);whole.update(raw)
                config={'source_export_directory':str(exports),'snapshot_spool_mountpoint':str(root),
                        'max_snapshot_plain_bytes':chunks.MAX_SNAPSHOT_PLAIN_BYTES,
                        'snapshot_spool_min_free_bytes':0}
                stage=chunks.create_source_spool(config,base)
                started=time.monotonic()
                captured,files,total=chunks.capture_files([(source,'paired/synthetic/database.dump')],stage,
                    b'x'*32,SimpleNamespace(safe_path=lambda path:path.lstat()),config,base)
                assert total==600*1024**2 and len(captured)==1200
                assert files[0]['sha256']==whole.hexdigest()
                assert sum(record['path'].stat().st_size for record in captured.values())==total
                report={'state':'BOUNDED_SYNTHETIC_CAPTURE_PASSED','plaintextBytes':total,
                    'uniqueChunks':len(captured),'maxAddressSpaceBytes':160*1024**2,
                    'peakRssKiB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                    'captureSeconds':round(time.monotonic()-started,3)}
                chunks.remove_spool(stage,base)
                assert not stage.exists()
                print(json.dumps(report))
        ''')
        result = subprocess.run([sys.executable, '-I', '-B', '-c', program, str(Path(__file__).parent)],
            capture_output=True, text=True, timeout=180)
        self.assertEqual(0, result.returncode, result.stderr[-1500:])
        report = json.loads(result.stdout)
        self.assertEqual('BOUNDED_SYNTHETIC_CAPTURE_PASSED', report['state'])
        self.assertLess(report['peakRssKiB'], 128 * 1024)
        print(json.dumps(report))


if __name__ == '__main__':
    unittest.main()
