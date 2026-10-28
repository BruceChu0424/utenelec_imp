"""Cross-process regressions for source/retention contention and receiver rejection."""
import json
import itertools
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import continuous_backup as backup
import snapshot_chunks

REAL_POPEN = subprocess.Popen
REAL_WRITE = os.write

class TransferContentionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='uten-dr-contention-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        mounted = patch.object(snapshot_chunks.os.path, 'ismount', return_value=True)
        mounted.start()
        self.addCleanup(mounted.stop)

    def holder(self, path=None):
        path = path or self.root / 'barrier'
        code = ('import fcntl,sys; f=open(sys.argv[1],"wb"); '
                'fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); '
                'sys.stdin.buffer.read(1)')
        process = subprocess.Popen([sys.executable, '-I', '-c', code, str(path)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(b'locked\n', process.stdout.readline())
        def close():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
        self.addCleanup(close)
        return path, process

    def test_live_owner_is_serialized_then_waiter_acquires_after_release(self):
        path, process = self.holder()
        def release_owner():
            process.stdin.write(b'x')
            process.stdin.flush()
        release = threading.Timer(.1, release_owner)
        release.start()
        self.addCleanup(release.join)
        started = time.monotonic()
        with backup.lock(path, timeout=1, busy_code='RECEIVER_BUSY'):
            self.assertGreaterEqual(time.monotonic() - started, .07)
            process.wait(timeout=5)

    def test_busy_deadline_fails_with_reason_and_leaves_owner_and_barrier_intact(self):
        path, process = self.holder()
        original = path.stat().st_ino
        started = time.monotonic()
        with self.assertRaises(BlockingIOError) as caught:
            with backup.lock(path, timeout=.1, busy_code='SOURCE_BUSY'):
                self.fail('Concurrent owner was admitted')
        self.assertEqual('SOURCE_BUSY', getattr(caught.exception, 'code', None))
        self.assertLess(time.monotonic() - started, .75)
        self.assertIsNone(process.poll())
        self.assertEqual(original, path.stat().st_ino)

    def test_archive_and_chunk_sender_preserve_fixed_receiver_failure_in_real_pipe(self):
        cipher = self.root / 'archive.gpg'
        cipher.write_bytes(b'x' * (2 * backup.CHUNK))
        receipt = {'exportId': 'synthetic', 'ciphertextBytes': cipher.stat().st_size,
                   'ciphertextSha256': 'a' * 64}
        (self.root / 'receipt.json').write_text(json.dumps(receipt))
        code = ('import json,sys; sys.stdin.buffer.readline(); '
                'print(json.dumps({"format":"uten-dr-ciphertext-transfer-v1",'
                '"state":"FAILED","errorCode":"RECEIVER_BUSY"}),flush=True); sys.exit(1)')
        for operation in ('archive', 'chunk'):
            with self.subTest(operation=operation), patch.object(backup, 'ssh_command',
                    return_value=[sys.executable, '-I', '-c', code]):
                with self.assertRaises(Exception) as caught:
                    if operation == 'archive':
                        backup.upload({}, self.root, '2026-10-25T07:00:00Z')
                    else:
                        snapshot_chunks.rpc({}, {'format': backup.FORMAT, 'operation': 'putChunk'},
                            backup, payload=cipher)
                self.assertEqual('RECEIVER_BUSY', getattr(caught.exception, 'code', None))

    def test_receiver_failure_record_does_not_include_private_exception_text(self):
        record = backup.failure_record(ValueError('PRIVATE-KEY-DATA-MUST-NOT-LEAK'))
        self.assertEqual('FAILED', record['state'])
        self.assertEqual('INVALID_TRANSFER', record['errorCode'])
        self.assertNotIn('PRIVATE', json.dumps(record))

    def source_fixture(self):
        state = self.root / 'state'
        state.mkdir(mode=0o700)
        paired_root = self.root / 'paired'
        paired_root.mkdir(mode=0o700)
        set_id = '20261025T070000Z-000000000001'
        source = paired_root / set_id
        source.mkdir(mode=0o700)
        (source / 'manifest.json').write_text(json.dumps({'started_at': '2026-10-25T07:00:00Z'}))
        (source / 'data').write_bytes(b'CONSISTENT-SYNTHETIC-SNAPSHOT')
        config_file = self.root / 'paired.json'
        config_file.write_text(json.dumps({'backup_root': str(paired_root)}))
        helper = self.root / 'paired_helper.py'
        helper.write_text('import fcntl,sys\n'
            f'f=open({str(state / ".source.lock")!r},"rb")\n'
            'try:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n'
            'except BlockingIOError:\n sys.exit(0)\n'
            'sys.exit(43)\n')
        sealed = self.root / 'sealed_helper.py'
        sealed.write_text('from pathlib import Path\nfrom contextlib import nullcontext\n'
            f'SET_ID={set_id!r}\n'
            'def export(root,destination,*args,**kwargs):\n'
            ' destination.mkdir(mode=0o700,exist_ok=True)\n'
            ' (destination/"archive.gpg").write_bytes(b"SYNTHETIC")\n'
            ' return destination,{"sourceSetId":SET_ID,"marketStateIncluded":False,"clientReleaseStateIncluded":False}\n'
            'def load_paired(path): return None\n'
            'def check_recipient(*args): pass\n'
            'def shared_backup_lock(root): return nullcontext()\n'
            'def collect_files(root,*args,**kwargs): return SET_ID,"a"*64,[(root/SET_ID/"data","data")],{}\n'
            'def safe_path(path): return path.stat()\n')
        recipient = self.root / 'recipient'
        recipient.write_bytes(b'SYNTHETIC-PUBLIC-RECIPIENT')
        recipient.chmod(0o600)
        chunk_key = self.root / 'chunk-key'
        chunk_key.write_bytes(b'x' * 32)
        chunk_key.chmod(0o600)
        (self.root / 'exports').mkdir(mode=0o700)
        return {'state_directory': str(state), 'paired_helper': str(helper),
                'snapshot_spool_mountpoint': str(self.root),
                'paired_config': str(config_file), 'sealed_helper': str(sealed),
                'source_export_directory': str(self.root / 'exports'),
                'recipient_file': str(recipient), 'recipient_fingerprint': 'A' * 40,
                'recovery_files': [], 'chunk_identity_file': str(chunk_key),
                'signing_key_file': str(self.root / 'unused-signing-key')}

    def assert_barrier_free(self, state):
        code = ('import fcntl,sys; f=open(sys.argv[1],"rb"); '
                'fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)')
        result = subprocess.run([sys.executable, '-I', '-c', code, str(Path(state) / '.source.lock')],
            capture_output=True, timeout=5)
        self.assertEqual(0, result.returncode, 'Network stage retained the source capture mutex')

    def test_hourly_upload_releases_source_capture_mutex_and_preserves_job_exclusion(self):
        config = self.source_fixture()
        def upload(*args, **kwargs):
            self.assert_barrier_free(config['state_directory'])
            with self.assertRaises(BlockingIOError):
                with backup.lock(Path(config['state_directory']) / '.archive-source.lock'):
                    self.fail('Duplicate archive job was admitted')
            return {'state': 'TARGET_BYTES_VERIFIED'}
        with patch.object(backup, 'upload', side_effect=upload), patch.object(backup, 'prune_source_exports',
                return_value={'status': 'APPLIED', 'removedSets': 0, 'removedCipherBytes': 0, 'retainedSets': 0}):
            result = backup.run_source(config)
        self.assertEqual('TARGET_BYTES_VERIFIED', result['state'])

    def test_chunk_network_releases_source_capture_mutex_and_preserves_job_exclusion(self):
        config = self.source_fixture()
        def rpc(_config, header, _base, *args, **kwargs):
            self.assert_barrier_free(config['state_directory'])
            with self.assertRaises(BlockingIOError):
                with backup.lock(Path(config['state_directory']) / '.snapshot-source.lock'):
                    self.fail('Duplicate snapshot job was admitted')
            if header['operation'] == 'probeChunks':
                return {'objects': []}
            if header['operation'] == 'putChunk':
                return {key: header[key] for key in ('opaqueId', 'cipherSha256', 'cipherBytes')}
            return header['snapshotReceipt']
        def encrypt(raw, destination, *args):
            destination.write_bytes(b'SYNTHETIC-CIPHERTEXT' * 10)
        with patch.object(snapshot_chunks, 'rpc', side_effect=rpc), \
                patch.object(snapshot_chunks, 'encrypt_bytes', side_effect=encrypt), \
                patch.object(snapshot_chunks, 'sign_receipt', return_value='synthetic-signature'):
            result = snapshot_chunks.run_source(config, backup)
        self.assertEqual('SNAPSHOT_CIPHERTEXT_COMPLETE', result['state'])
        self.assertFalse(any(path.is_dir() for path in Path(config['state_directory']).glob('.snapshot-*')))

    def test_receiver_rejection_records_degraded_state_without_claiming_a_new_recovery_point(self):
        config = self.source_fixture()
        status_path = Path(config['state_directory']) / 'status.json'
        backup.atomic_json(status_path, {'latest': {'exportId': 'previous-verified'}})
        with patch.object(backup, 'upload', side_effect=backup.TransferFailure('RECEIVER_BUSY')):
            with self.assertRaises(backup.TransferFailure):
                backup.run_source(config)
        failed = backup.read_json(status_path)
        self.assertEqual('FAILED', failed['state'])
        self.assertEqual('DEGRADED', failed['health'])
        self.assertEqual('RECEIVER_BUSY', failed['errorCode'])
        self.assertEqual({'exportId': 'previous-verified'}, failed['latest'])

    def test_capture_busy_beyond_sixty_seconds_defers_to_timer_without_losing_failure_freshness(self):
        config = self.source_fixture()
        _, owner = self.holder(Path(config['state_directory']) / '.source.lock')
        for mode, status_name in ((backup.run_source, 'status.json'),
                                  (lambda value: snapshot_chunks.run_source(value, backup), 'snapshot-status.json')):
            status_path = Path(config['state_directory']) / status_name
            backup.atomic_json(status_path, {'latest': {'sourceSnapshotAt': '2026-10-25T07:00:00Z'}})
            # A real foreign process owns the mutex; advance only this module's
            # monotonic clock to exhaust >60s without making the test sleep.
            clock = itertools.count(0, 61)
            with patch.object(backup, 'time', SimpleNamespace(monotonic=lambda: next(clock), sleep=lambda _: None)):
                for _ in range(4):
                    result = mode(config)
                    self.assertEqual('DEFERRED', result['state'])
                    self.assertEqual('SOURCE_BUSY', result['errorCode'])
                    self.assertEqual('NEXT_TIMER', result['retryPolicy'])
                    self.assertEqual('DEGRADED', result['health'])
                    self.assertEqual({'sourceSnapshotAt': '2026-10-25T07:00:00Z'}, result['latest'])
        self.assertIsNone(owner.poll())

    def transfer_fixture(self, operation, code, *, deadline=None, payload_bytes=65536):
        cipher = self.root / 'archive.gpg'
        cipher.write_bytes(b'x' * payload_bytes)
        (self.root / 'receipt.json').write_text(json.dumps({'exportId': 'synthetic',
            'ciphertextBytes': cipher.stat().st_size, 'ciphertextSha256': 'a' * 64}))
        spawned = []
        def spawn(*args, **kwargs):
            process = REAL_POPEN(*args, **kwargs)
            spawned.append(process)
            return process
        try:
            with patch.object(backup, 'ssh_command', return_value=[sys.executable, '-I', '-c', code]), \
                    patch.object(backup.subprocess, 'Popen', side_effect=spawn):
                if operation == 'archive':
                    return backup.upload({}, self.root, '2026-10-25T07:00:00Z', deadline=deadline)
                return snapshot_chunks.rpc({}, {'format': backup.FORMAT, 'operation': 'synthetic'}, backup,
                                           payload=cipher, deadline=deadline)
        finally:
            for process in spawned:
                self.assertIsNotNone(process.poll(), 'Transfer must reap its actual child')
                self.assertTrue(process.stdin.closed)
                self.assertTrue(process.stdout.closed)

    def test_slow_continuous_progress_is_allowed_beyond_idle_budget(self):
        code = ('import json,sys,time; h=json.loads(sys.stdin.buffer.readline()); size=0\n'
                'while True:\n b=sys.stdin.buffer.read(8192)\n if not b: break\n size+=len(b)\n time.sleep(.005)\n'
                'r=h.get("sourceReceipt"); print(json.dumps({"state":"TARGET_BYTES_VERIFIED",**r} if r else {"bytes":size}))')
        for operation in ('archive', 'chunk'):
            started = time.monotonic()
            with self.subTest(operation=operation), patch.object(backup, 'TRANSFER_IDLE_SECONDS', .3):
                self.transfer_fixture(operation, code, payload_bytes=2 * backup.CHUNK)
            self.assertGreater(time.monotonic() - started, .3)

    def test_no_progress_and_total_deadline_are_both_finite_and_reap_child(self):
        stalled = 'import sys,time; sys.stdin.buffer.read(); time.sleep(30)'
        progressing = ('import sys,time; sys.stdin.buffer.readline()\n'
                       'while sys.stdin.buffer.read(2048): time.sleep(.04)')
        for operation in ('archive', 'chunk'):
            for code, reason, deadline, idle in ((stalled, 'TRANSFER_IDLE_TIMEOUT', None, .1),
                    (progressing, 'TRANSFER_DEADLINE_EXCEEDED', time.monotonic() + .2, 2)):
                started = time.monotonic()
                with self.subTest(operation=operation, reason=reason), \
                        patch.object(backup, 'TRANSFER_IDLE_SECONDS', idle), self.assertRaises(backup.TransferFailure) as caught:
                    self.transfer_fixture(operation, code, deadline=deadline)
                self.assertEqual(reason, caught.exception.code)
                self.assertLess(time.monotonic() - started, 2)

    def test_write_failure_closes_input_before_receiver_waiting_for_eof_is_reaped(self):
        for operation in ('archive', 'chunk'):
            marker = self.root / ('failed-write-' + operation)
            code = ('import json,sys,time; from pathlib import Path; sys.stdin.buffer.readline()\n'
                    f'while not Path({str(marker)!r}).exists(): time.sleep(.001)\n'
                    'print(json.dumps({"format":"uten-dr-ciphertext-transfer-v1","state":"FAILED",'
                    '"errorCode":"RECEIVER_BUSY"}),flush=True); sys.stdin.buffer.read()')
            writes = 0
            def write(descriptor, value):
                nonlocal writes
                writes += 1
                if writes == 2:
                    marker.write_text('closed')
                    raise BrokenPipeError('synthetic half-closed transport')
                return REAL_WRITE(descriptor, value)
            started = time.monotonic()
            with self.subTest(operation=operation), patch.object(backup.os, 'write', side_effect=write), \
                    patch.object(backup, 'TRANSFER_IDLE_SECONDS', .5), self.assertRaises(backup.TransferFailure) as caught:
                self.transfer_fixture(operation, code)
            self.assertEqual('RECEIVER_BUSY', caught.exception.code)
            self.assertLess(time.monotonic() - started, 2)


if __name__ == '__main__':
    unittest.main()
