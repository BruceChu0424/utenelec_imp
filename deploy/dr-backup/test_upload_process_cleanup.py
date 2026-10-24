"""Real pipe/process regressions; replaces only the SSH argv with local Python."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import continuous_backup as backup
import snapshot_chunks


REAL_POPEN=subprocess.Popen


class UploadProcessCleanupTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='uten-transfer-process-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.receipt={'exportId':'sealed-fixture','ciphertextSha256':'a'*64,'ciphertextBytes':2*backup.CHUNK}
        (self.directory/'receipt.json').write_text(json.dumps(self.receipt))
        self.payload=self.directory/'archive.gpg'
        self.payload.write_bytes(b'SYNTHETIC-CIPHERTEXT-'*(2*backup.CHUNK//21+1))

    def invoke(self,kind,payload=True):
        if kind=='upload':
            if not payload:self.payload.unlink()
            return backup.upload({},self.directory,'2026-10-23T00:00:00Z')
        return snapshot_chunks.rpc({}, {'format':backup.FORMAT,'operation':'probe'},backup,
                                   payload=self.payload if payload else self.directory/'missing.gpg')

    def assert_failed_process_cleaned(self,kind,*,payload=True,exited=True):
        spawned=[]
        def spawn(*args,**kwargs):
            value=REAL_POPEN(*args,**kwargs);spawned.append(value)
            if exited:value.wait(timeout=5)
            return value
        code='raise SystemExit(23)' if exited else 'import sys; sys.stdin.buffer.read()'
        try:
            with patch.object(backup,'ssh_command',return_value=[sys.executable,'-I','-c',code]), \
                 patch.object(backup.subprocess,'Popen',side_effect=spawn):
                with self.assertRaises(BrokenPipeError if payload else FileNotFoundError):
                    self.invoke(kind,payload=payload)
            self.assertEqual(len(spawned),1)
            child=spawned[0]
            self.assertIsNotNone(child.poll(),'The real child must be reaped')
            self.assertTrue(child.stdin.closed,'Sender pipe leaked on failed '+kind)
            self.assertTrue(child.stdout.closed,'Receiver pipe leaked on failed '+kind)
        finally:
            # Keep a baseline failure reproducible without leaking the test's
            # descriptors. The separate warning probe proves actual GC warnings.
            for child in spawned:
                if child.poll() is None:child.kill();child.wait(timeout=5)
                for stream in (child.stdin,child.stdout):
                    if stream is not None and not stream.closed:
                        try:stream.close()
                        except OSError:pass

    def test_archive_upload_early_receiver_exit_closes_real_pipes(self):
        self.assert_failed_process_cleaned('upload')

    def test_chunk_rpc_early_receiver_exit_closes_real_pipes(self):
        self.assert_failed_process_cleaned('rpc')

    def test_archive_missing_input_kills_and_reaps_blocked_real_receiver(self):
        self.assert_failed_process_cleaned('upload',payload=False,exited=False)

    def test_chunk_missing_input_kills_and_reaps_blocked_real_receiver(self):
        self.assert_failed_process_cleaned('rpc',payload=False,exited=False)

    def test_archive_cleanup_broken_pipe_does_not_mask_original_missing_input(self):
        self.assert_failed_process_cleaned('upload',payload=False)

    def test_chunk_cleanup_broken_pipe_does_not_mask_original_missing_input(self):
        self.assert_failed_process_cleaned('rpc',payload=False)

    def test_archive_success_keeps_original_receipt_binding_and_payload(self):
        self.receipt['ciphertextBytes']=self.payload.stat().st_size
        (self.directory/'receipt.json').write_text(json.dumps(self.receipt))
        expected={'state':'TARGET_BYTES_VERIFIED',**self.receipt}
        code=('import json,sys; h=json.loads(sys.stdin.buffer.readline()); d=sys.stdin.buffer.read(); '
              'r=h["sourceReceipt"]; assert len(d)==r["ciphertextBytes"]; '
              'print(json.dumps({"state":"TARGET_BYTES_VERIFIED",**r}))')
        with patch.object(backup,'ssh_command',return_value=[sys.executable,'-I','-c',code]):
            self.assertEqual(self.invoke('upload'),expected)

    def test_chunk_success_keeps_original_ack_and_payload(self):
        code=('import json,sys; h=json.loads(sys.stdin.buffer.readline()); d=sys.stdin.buffer.read(); '
              'print(json.dumps({"operation":h["operation"],"bytes":len(d)}))')
        with patch.object(backup,'ssh_command',return_value=[sys.executable,'-I','-c',code]):
            self.assertEqual(self.invoke('rpc'),{'operation':'probe','bytes':self.payload.stat().st_size})


if __name__=='__main__':unittest.main()
