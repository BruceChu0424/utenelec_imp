"""Bounded real pipes and typed proof/expiry/publisher tests; no production keys."""
from contextlib import contextmanager
import copy
from datetime import timedelta
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import continuous_backup as base
import latest_snapshot as latest
import publish_status
import snapshot_chunks as chunks
import verification_runner as runner
import test_latest_snapshot as fixtures


@contextmanager
def pipe_channel(code, seconds=3):
    process = subprocess.Popen([sys.executable, '-I', '-c', code], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    channel = runner.Channel(process, time.monotonic() + seconds)
    try:yield channel
    finally:
        channel.close()
        process.stdin.close(); process.stdout.close()
        if process.poll() is None:process.terminate()
        try:process.wait(timeout=2)
        except subprocess.TimeoutExpired:process.kill(); process.wait(timeout=2)


class VerificationTransportTest(unittest.TestCase):
    def test_slow_progress_is_streamed_without_a_short_fixed_transfer_timeout(self):
        code = """import os,struct,time
for raw in [b'a'*65536,b'b'*65536,b'c'*65536]:
 frame=struct.pack('!I',len(raw))+raw
 for offset in range(0,len(frame),8192):os.write(1,frame[offset:offset+8192]);time.sleep(.003)
os.write(1,struct.pack('!I',0))
"""
        with tempfile.TemporaryDirectory() as directory, pipe_channel(code) as channel:
            target = Path(directory) / 'bundle.tar'
            result = channel.download(target, 1024**2, 2)
            raw = b'a'*65536+b'b'*65536+b'c'*65536
            self.assertEqual(raw, target.read_bytes()); self.assertEqual(len(raw), result['bundleBytes'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(), result['bundleSha256'])

    def test_no_progress_and_early_eof_fail_with_real_processes(self):
        with pipe_channel('import time;time.sleep(60)', seconds=.05) as channel, self.assertRaises(TimeoutError):channel.line()
        with pipe_channel('pass') as channel, self.assertRaises(EOFError):channel.line()

    def test_malicious_frame_and_total_bytes_never_cross_local_limit(self):
        for code in ("import os,struct;os.write(1,struct.pack('!I',1048577))",
                     "import os,struct;os.write(1,struct.pack('!I',32)+b'x'*32)"):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory, pipe_channel(code) as channel:
                target = Path(directory) / 'cipher.tar'
                with self.assertRaises(ValueError):channel.download(target, 16, 1)
                self.assertLessEqual(target.stat().st_size, 16)

    def test_blocked_large_request_is_bounded_and_metadata_is_not_unbounded(self):
        with pipe_channel('import time;time.sleep(60)', seconds=.05) as channel, self.assertRaises(TimeoutError):
            channel.send({'format': runner.session.FORMAT, 'body': 'x'*(2*1024**2)})
        with pipe_channel("import os;os.write(1,b'x'*70000)") as channel, self.assertRaises(ValueError):channel.line()


class RealEvidenceContractTest(unittest.TestCase):
    def report(self):
        report = {'state': 'ISOLATED_DATABASE_AND_ORIGINALS_RESTORED', 'piiVerified': 3, 'hmacIndexesVerified': 3,
            'knownAncillaryCredentialIssuesCleared': False, 'pairedRecoveryInputBindingSha256': 'd'*64,
            'restoredConfigurationAudit': {'state': 'VERIFIED', 'invalidNames': [], 'externalApiCallsPerformed': False},
            'integrityCandidate': {'state': 'ISOLATED_CLONE_INTEGRITY_CANDIDATE_VERIFIED',
                'aiPlaintextPreserved': True, 'aiCurrentCompanyIssuerVerified': True, 'plan': {'configSha256': 'e'*64},
                'after': {'blockers': {'providerPlaceholderOrLast4Mismatch': 0}}}}
        for key in ('databaseRestored', 'attachmentsVerified', 'corePgpAndHmacVerified', 'keysVerified',
                    'sourceSignatureVerified', 'isolated', 'sideEffectsDisabled', 'ownedContainerRemoved'):report[key] = True
        return report

    def test_base_drill_false_is_not_flipped_and_review_binds_actual_report_bytes(self):
        report = self.report(); before = copy.deepcopy(report)
        review, evidence = runner.credential_evidence(report, {'configurationVersion': 'c'*64}, {'recipientFingerprint': 'A'*40}, 28)
        self.assertEqual(before, report); self.assertFalse(report['knownAncillaryCredentialIssuesCleared'])
        expected = hashlib.sha256(runner.chunks.canonical(report)+b'\n').hexdigest()
        self.assertEqual(expected, review['restoreReportSha256'])
        self.assertEqual({'applicationConfiguration', 'signingAndRecipientRecovery', 'externalCredentials'}, set(evidence))
        self.assertTrue(all(value['restoreReportSha256'] == expected for value in evidence.values()))
        self.assertNotIn('checks', review, 'receiver constructs protected evidence paths itself')

    def test_true_flags_alone_wrong_issuer_zero_rows_or_incomplete_cleanup_cannot_renew(self):
        cases = []
        value = self.report(); del value['integrityCandidate']; cases.append(value)
        value = self.report(); value['integrityCandidate']['aiCurrentCompanyIssuerVerified'] = False; cases.append(value)
        value = self.report(); value['hmacIndexesVerified'] = 0; cases.append(value)
        value = self.report(); value['ownedContainerRemoved'] = False; cases.append(value)
        value = self.report(); value['corePgpAndHmacVerified'] = False; cases.append(value)
        value = self.report(); value['restoredConfigurationAudit']['invalidNames'] = ['UTEN_JWT_SECRET']; cases.append(value)
        value = self.report(); value['restoredConfigurationAudit']['externalApiCallsPerformed'] = True; cases.append(value)
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):runner.credential_evidence(value, {}, {}, 28)
        for days in (0, 31, True):
            with self.subTest(days=days), self.assertRaises(ValueError):runner.credential_evidence(self.report(), {}, {}, days)


class VerifierConfigurationTest(unittest.TestCase):
    def test_exact_schema_budgets_and_health_without_live_keyring_directory(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory(dir='/run') as runtime:
            root = Path(directory); root.chmod(0o700); volume = root/'volume'; volume.mkdir(mode=0o700)
            spool = volume/'spool'; spool.mkdir(mode=0o700); state = root/'state'; state.mkdir(mode=0o700)
            known, signers, program = root/'known', root/'signers', root/'runtime'
            for path in (known, signers):path.write_text('SYNTHETIC PUBLIC TRUST ONLY'); path.chmod(0o600)
            program.write_text('#!/bin/sh\nexit 1\n'); program.chmod(0o700)
            config = {'format': runner.CONFIG_FORMAT, 'instance_id': '00000000-0000-0000-0000-000000000001',
                'ssh_target': 'root@cloud.example.invalid', 'known_hosts_file': str(known), 'allowed_signers_file': str(signers),
                'recipient_fingerprint': 'A'*40, 'spool_mountpoint': str(volume), 'spool_directory': str(spool),
                'runtime_directory': runtime, 'state_directory': str(state), 'docker': str(program), 'node': str(program),
                'runtime': 'podman', 'restore_profile': 'large-memory', 'postgres_image': 'docker.io/library/postgres:16.15',
                'expected_image_id': '1'*64, 'download_budget_seconds': 10800, 'session_budget_seconds': 14400,
                'restore_budget_seconds': 3300, 'proof_valid_days': 28}
            path = root/'config.json'; base.atomic_json(path, config)
            with patch.object(Path, 'is_mount', lambda p: p in {volume, Path('/run')}):
                self.assertEqual(config, runner.load_config(path))
                for key, value in (('shell', 'evil'), ('download_budget_seconds', 10801), ('session_budget_seconds', True),
                                   ('session_budget_seconds', 14401), ('restore_budget_seconds', 3601), ('proof_valid_days', 31)):
                    base.atomic_json(path, {**config, key: value})
                    with self.subTest(key=key), self.assertRaises(ValueError):runner.load_config(path)
                missing = {**config, 'runtime_directory': runtime+'/not-running'}; base.atomic_json(path, missing)
                self.assertEqual(missing, runner.load_config(path, needs_recovery_runtime=False))
                with self.assertRaises(FileNotFoundError):runner.load_config(path)


class HealthFailurePersistenceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name); self.root.chmod(0o700)
        self.config = {'docker': '/unused-oci', 'instance_id': '00000000-0000-0000-0000-000000000001',
                       'state_directory': str(self.root), 'runtime': 'podman'}
        self.old = {'state': 'CURRENT', 'observedAt': '2001-01-01T00:00:00+00:00'}
        base.atomic_json(self.root/'health.json', self.old)
        self.proof = self.root/'last-restore-report.json'; self.proof.write_bytes(b'previous real proof must remain unchanged')

    def child_command(self, response, *, fail_notification=False):
        acknowledgement = json.dumps({'format': runner.session.FORMAT, 'operation': 'failureRecorded'}).encode()+b'\n'
        code = "import json,sys\nrequest=json.loads(sys.stdin.buffer.readline())\n"
        code += "if request['operation']=='failure':\n assert request['reasonCode']=='HEALTH_FAILED'\n"
        if fail_notification:code += " raise SystemExit(255)\n"
        else:code += ' sys.stdout.buffer.write('+repr(acknowledgement)+');sys.stdout.buffer.flush()\n'
        code += 'else:\n sys.stdout.buffer.write('+repr(response)+');sys.stdout.buffer.flush()\n'
        return [sys.executable, '-I', '-c', code]

    def assert_fresh_degraded(self, result):
        saved = base.read_json(self.root/'health.json')
        self.assertEqual(result, saved); self.assertEqual('DEGRADED', saved['state'])
        self.assertGreater(base.instant(saved['observedAt']), base.instant(self.old['observedAt']))
        self.assertEqual(b'previous real proof must remain unchanged', self.proof.read_bytes())
        self.assertNotIn('PRIVATE_PEER_BODY', json.dumps(saved))

    def test_real_failed_ssh_process_replaces_old_current_even_when_notification_also_fails(self):
        command = [sys.executable, '-I', '-c', 'import sys;sys.stdin.buffer.readline();raise SystemExit(255)']
        with patch.object(runner.drill, 'cleanup_owned_containers'), patch.object(runner, 'ssh_command', return_value=command):
            result = runner.health(self.config)
        self.assert_fresh_degraded(result)
        self.assertEqual('EOFError', result['errorType']); self.assertFalse(result['failureReportedToReceiver'])
        self.assertEqual('EOFError', result['failureNotificationErrorType'])

    def test_bad_peer_status_and_json_are_redacted_and_report_health_failed_on_live_role(self):
        malformed = [b'PRIVATE_PEER_BODY not json\n',
            json.dumps({'format': runner.session.FORMAT, 'operation': 'status',
                        'status': {'health': 'BROKEN', 'secret': 'PRIVATE_PEER_BODY'}}).encode()+b'\n']
        for response in malformed:
            with self.subTest(response=response), patch.object(runner.drill, 'cleanup_owned_containers'), \
                    patch.object(runner, 'ssh_command', return_value=self.child_command(response)):
                result = runner.health(self.config)
            self.assert_fresh_degraded(result); self.assertTrue(result['failureReportedToReceiver'])
            self.assertIn(result['errorType'], {'JSONDecodeError', 'ValueError'})

    def test_original_parse_error_and_secondary_notification_error_remain_separate(self):
        response = json.dumps({'format': runner.session.FORMAT, 'operation': 'wrong',
                               'status': 'PRIVATE_PEER_BODY'}).encode()+b'\n'
        with patch.object(runner.drill, 'cleanup_owned_containers'), \
                patch.object(runner, 'ssh_command', return_value=self.child_command(response, fail_notification=True)):
            result = runner.health(self.config)
        self.assert_fresh_degraded(result)
        self.assertEqual('ValueError', result['errorType']); self.assertFalse(result['failureReportedToReceiver'])
        self.assertEqual('EOFError', result['failureNotificationErrorType'])

    def test_cleanup_exception_is_also_fresh_degraded_without_touching_proof(self):
        with patch.object(runner.drill, 'cleanup_owned_containers', side_effect=RuntimeError('PRIVATE_PEER_BODY')), \
                patch.object(runner, 'ssh_command', return_value=self.child_command(b'')):
            result = runner.health(self.config)
        self.assert_fresh_degraded(result); self.assertEqual('RuntimeError', result['errorType'])
        self.assertTrue(result['failureReportedToReceiver'])

    def test_normal_current_path_stays_successful_without_failure_notification(self):
        response = json.dumps({'format': runner.session.FORMAT, 'operation': 'status',
                               'status': {'health': 'HEALTHY'}}).encode()+b'\n'
        with patch.object(runner.drill, 'cleanup_owned_containers'), patch.object(runner, 'report_failure') as notify, \
                patch.object(runner, 'ssh_command', return_value=self.child_command(response)):
            result = runner.health(self.config)
        self.assertEqual('CURRENT', result['state']); self.assertNotIn('errorType', result); notify.assert_not_called()


class ProofHealthPublisherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):fixtures.LatestSnapshotPolicyTest.setUpClass()

    @classmethod
    def tearDownClass(cls):fixtures.LatestSnapshotPolicyTest.tearDownClass()

    def setUp(self):
        self.fixture = fixtures.LatestSnapshotPolicyTest(); self.fixture.setUp(); self.addCleanup(self.fixture.doCleanups)
        self.config, self.storage = self.fixture.config, self.fixture.storage
        self.obj = self.fixture.fixture.object(); self.receipt = self.fixture.seed(self.obj)
        report, review = self.fixture.evidence(self.receipt)
        value = base.read_json(review); value['expiresAt'] = (base.now()+timedelta(days=28)).isoformat(); base.atomic_json(review, value)
        latest.commission(self.config, base, chunks,
            self.receipt['snapshotId'], report, credential_review_path=review, legacy_exports_drained=True)
        base.retain(self.config)

    def test_expiry_thresholds_and_weekly_miss_are_visible_without_changing_expiry(self):
        original = (self.storage / '.latest-commissioning.json').read_bytes()
        moment = base.now()
        for days, severity in ((22, 'WARNING'), (26, 'HIGH'), (27.5, 'CRITICAL'), (29, 'EXPIRED')):
            with self.subTest(days=days), patch.object(base, 'now', return_value=moment+timedelta(days=days)):
                value = latest.status(self.config, base, chunks)
                self.assertEqual(severity, value['latestRotationProofExpirySeverity'])
                self.assertNotEqual('CURRENT', value['latestRotationProofHealth'])
        self.assertEqual(original, (self.storage / '.latest-commissioning.json').read_bytes())

    def test_publisher_only_health_still_conveys_warning_and_never_claims_restore_flags(self):
        future = base.now()+timedelta(days=22)
        with patch.object(base, 'now', return_value=future):
            header = self.fixture.header([self.obj]); self.fixture.lease(header)
            self.fixture.send(header, self.fixture.fixture.manifest)
            status = base.build_status(self.config)
            self.assertTrue(status['snapshotRpo15MinutesFresh']); self.assertEqual('DEGRADED', status['health'])
            cfg = self.fixture.root / 'publisher-config.json'; token = self.fixture.root / 'publisher.token'
            base.atomic_json(cfg, self.config); token.write_text(os.urandom(32).hex()); token.chmod(0o600)
            captured = []
            class Response:
                def __enter__(self):return self
                def __exit__(self, *_):pass
                def read(self, *_):return b'{"accepted":true}'
            class Opener:
                def open(self, request, **_):captured.append(request.data); return Response()
            with patch.object(publish_status.urllib.request, 'build_opener', return_value=Opener()):
                result = publish_status.publish(base, cfg, token, self.fixture.root/'published.json',
                    'http://127.0.0.1:9087/v1/agent/snapshot')
            body = json.loads(captured[0]); self.assertEqual('DEGRADED', result['health']); self.assertEqual('DEGRADED', body['health'])
            self.assertLess(len(captured[0]), 131072); self.assertLessEqual(len(body['recoveryPoints']), 100)
            self.assertTrue(all(not row['keysCovered'] and not row['verified'] for row in body['recoveryPoints']))


if __name__ == '__main__':unittest.main()
