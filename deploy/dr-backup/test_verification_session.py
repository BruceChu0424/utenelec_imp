"""Real signed synthetic ciphertext, live process FDs and GC; no production DB."""
import hashlib
import io
import json
import multiprocessing
import os
import signal
import socket
import struct
import time
import unittest
from unittest.mock import patch

import continuous_backup as base
import latest_snapshot as latest
import snapshot_chunks as chunks
import verification_session as session
import test_latest_snapshot as policy_fixtures


def server_process(descriptor, other, config):
    os.close(other)
    with socket.socket(fileno=descriptor) as peer, peer.makefile('rb') as incoming, peer.makefile('wb') as outgoing:
        try:session.serve(config, incoming, outgoing, legacy_exports_drained=True)
        except BaseException:raise SystemExit(17)


@unittest.skipUnless(os.name == 'posix' and os.geteuid() == 0, 'root-private Linux FD contract')
class VerificationSessionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):policy_fixtures.LatestSnapshotPolicyTest.setUpClass()

    @classmethod
    def tearDownClass(cls):policy_fixtures.LatestSnapshotPolicyTest.tearDownClass()

    def setUp(self):
        self.policy = policy_fixtures.LatestSnapshotPolicyTest(); self.policy.setUp()
        self.addCleanup(self.policy.doCleanups)
        for name, module in (('base', base), ('chunks', chunks), ('latest', latest)):
            changed = patch.object(session, name, module); changed.start(); self.addCleanup(changed.stop)
        self.config, self.root = self.policy.config, self.policy.storage
        self.obj = self.policy.fixture.object()
        self.old = self.policy.seed(self.obj); self.policy.commission(self.old)

    def next_point(self):
        header = self.policy.header([self.obj]); self.policy.lease(header)
        return self.policy.send(header, self.policy.fixture.manifest)

    def test_real_fd_survives_bundle_eof_and_protects_closure_until_restore_finishes(self):
        with session.PointLease(self.config) as lease:
            output = io.BytesIO(); chunks.bundle(self.config, lease.snapshot_id, output, base,
                                               verification_budget_seconds=10800)
            self.assertGreater(len(output.getvalue()), 10240)
            active, _ = chunks.bundle_lease_state(self.root, base)
            self.assertEqual(1, len(active), 'the full-flow FD must remain after download EOF')
            newer = self.next_point(); base.retain(self.config)
            self.assertTrue((self.root / 'snapshots' / self.old['snapshotId']).exists())
            self.assertTrue((self.root / 'snapshots' / newer['snapshotId']).exists())
        base.retain(self.config)
        self.assertEqual([newer['snapshotId']], [p.name for p in (self.root / 'snapshots').iterdir()])

    def test_only_one_operator_and_only_current_signed_point_can_start(self):
        with session.PointLease(self.config):
            with self.assertRaises(BlockingIOError):
                with session.PointLease(self.config):pass
        self.next_point()
        with self.assertRaises(ValueError):
            with session.PointLease(self.config, self.old['snapshotId']):pass

    def test_actual_nonrenewable_process_timer_releases_the_real_point_fd(self):
        with session.PointLease(self.config):
            with self.assertRaises(TimeoutError):
                with session.deadline_guard(.03):time.sleep(.2)
        active, _ = chunks.bundle_lease_state(self.root, base)
        self.assertEqual([], active)

    def test_explicit_7200_10800_and_four_hour_bounds_without_renewal(self):
        for budget, download in ((14401, 10800), (14400, 10801), (True, 600), (3600, 3600)):
            request = {'format': session.FORMAT, 'operation': 'open', 'snapshotId': None,
                       'budgetSeconds': budget, 'downloadBudgetSeconds': download}
            with self.subTest(budget=budget, download=download), self.assertRaises(ValueError):
                session.serve(self.config, io.BytesIO(chunks.canonical(request) + b'\n'), io.BytesIO())
        for download in (7200, 10800):
            output = io.BytesIO()
            chunks.bundle(self.config, self.old['snapshotId'], output, base, verification_budget_seconds=download)
            self.assertGreater(len(output.getvalue()), 10240)
        with patch.dict(os.environ, {'SSH_ORIGINAL_COMMAND': 'cat /etc/passwd'}), self.assertRaises(ValueError):
            session.serve(self.config, io.BytesIO(), io.BytesIO())

    def open_process(self):
        parent, child = socket.socketpair(); parent.settimeout(10)
        process = multiprocessing.get_context('fork').Process(target=server_process,
            args=(child.fileno(), parent.fileno(), self.config))
        process.start(); child.close()
        incoming, outgoing = parent.makefile('rb'), parent.makefile('wb')
        def cleanup():
            incoming.close(); outgoing.close(); parent.close()
            process.join(5)
            if process.is_alive():process.kill(); process.join(5)
        self.addCleanup(cleanup)
        request = {'format': session.FORMAT, 'operation': 'open', 'snapshotId': None,
                   'budgetSeconds': 14400, 'downloadBudgetSeconds': 10800}
        outgoing.write(chunks.canonical(request) + b'\n'); outgoing.flush()
        opened = json.loads(incoming.readline())
        self.assertEqual('opened', opened['operation'])
        outgoing.write(chunks.canonical({'format': session.FORMAT, 'operation': 'bundle',
            'sessionId': opened['sessionId']}) + b'\n'); outgoing.flush()
        transferred = 0
        while True:
            raw = incoming.read(4); self.assertEqual(4, len(raw))
            length = struct.unpack('!I', raw)[0]
            if length == 0:break
            self.assertLessEqual(length, session.FRAME_BYTES)
            data = incoming.read(length); self.assertEqual(length, len(data)); transferred += length
        self.assertGreater(transferred, 10240)
        self.assertEqual('bundleComplete', json.loads(incoming.readline())['operation'])
        return process, parent, incoming, outgoing, opened

    def test_real_process_sigterm_releases_fd_without_refreshing_any_proof(self):
        before = (self.root / '.latest-commissioning.json').read_bytes()
        process, _, _, _, _ = self.open_process()
        newer = self.next_point(); base.retain(self.config)
        self.assertTrue((self.root / 'snapshots' / self.old['snapshotId']).exists())
        os.kill(process.pid, signal.SIGTERM); process.join(5)
        self.assertFalse(process.is_alive()); self.assertEqual(before, (self.root / '.latest-commissioning.json').read_bytes())
        base.retain(self.config)
        self.assertTrue((self.root / 'snapshots' / newer['snapshotId']).exists())
        self.assertFalse((self.root / 'snapshots' / self.old['snapshotId']).exists())
        self.assertEqual('FAILED', base.read_json(self.root / '.verification-status.json')['state'])

    def test_real_process_complete_bound_review_then_returns_to_one_root(self):
        process, _, incoming, outgoing, opened = self.open_process()
        newer = self.next_point()
        report_path, review_path = self.policy.evidence(self.old)
        report, review = base.read_json(report_path), base.read_json(review_path)
        report.update(verificationSessionId=opened['sessionId'], verificationSoftwareSha256=session.software_fingerprint(),
                      piiVerified=1, hmacIndexesVerified=1, ownedContainerRemoved=True,
                      restoredConfigurationAudit={'state': 'VERIFIED', 'invalidNames': [], 'externalApiCallsPerformed': False})
        report_sha = hashlib.sha256(chunks.canonical(report) + b'\n').hexdigest()
        evidence = {}
        for row in review.pop('checks'):
            item = base.read_json(row['evidenceFile']); item['restoreReportSha256'] = report_sha
            evidence[row['scope']] = item
        review['restoreReportSha256'] = report_sha
        value = {'format': session.FORMAT, 'operation': 'commission', 'sessionId': opened['sessionId'],
                 'report': report, 'review': review, 'evidence': evidence}
        outgoing.write(chunks.canonical(value) + b'\n'); outgoing.flush()
        result = json.loads(incoming.readline()); self.assertEqual('commissioned', result['operation'])
        process.join(5); self.assertEqual(0, process.exitcode)
        self.assertEqual([newer['snapshotId']], [p.name for p in (self.root / 'snapshots').iterdir()])
        proof = base.read_json(self.root / '.latest-commissioning.json')
        self.assertEqual(report_sha, proof['restoreReportSha256'])
        retained = list((self.root / '.verification-reports').iterdir())
        self.assertEqual(1, len(retained)); self.assertEqual(proof['credentialReviewSha256'], base.digest(retained[0] / 'review.json'))

    def test_plain_drill_flags_never_commission_without_new_real_evidence(self):
        with session.PointLease(self.config) as lease:
            value = {'format': session.FORMAT, 'operation': 'commission', 'sessionId': 'a' * 32,
                'report': {'verificationSessionId': 'a' * 32, 'verificationSoftwareSha256': session.software_fingerprint(),
                    'databaseRestored': True, 'knownAncillaryCredentialIssuesCleared': True}, 'review': {}, 'evidence': {}}
            before = (self.root / '.latest-commissioning.json').read_bytes()
            with self.assertRaises(ValueError):session.receive_commission(value, lease, 'a' * 32, self.config, True)
            self.assertEqual(before, (self.root / '.latest-commissioning.json').read_bytes())

    def test_a_renew_message_cannot_extend_or_refresh_a_real_live_session(self):
        before = (self.root / '.latest-commissioning.json').read_bytes()
        process, _, incoming, outgoing, opened = self.open_process()
        outgoing.write(chunks.canonical({'format': session.FORMAT, 'operation': 'renew',
            'sessionId': opened['sessionId'], 'budgetSeconds': 14400})+b'\n'); outgoing.flush()
        self.assertEqual(b'', incoming.readline()); process.join(5)
        self.assertEqual(17, process.exitcode); self.assertEqual(before, (self.root / '.latest-commissioning.json').read_bytes())


if __name__ == '__main__':unittest.main()
