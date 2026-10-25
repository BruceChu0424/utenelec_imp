#!/usr/bin/python3
"""Root-only, fixed-command duplex verifier. No upload identity uses this API.

The root-owned verifier host is trusted to run the real restore, not merely to
present flags. Its independent restricted SSH key authenticates that role; this
is not hardware remote attestation. No private recovery material enters here.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import sys
import time
import uuid


def sibling(name):
    spec = importlib.util.spec_from_file_location('uten_verifier_' + name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module; spec.loader.exec_module(module)
    return module


base = sibling('continuous_backup')
chunks = sibling('snapshot_chunks')
latest = sibling('latest_snapshot')
FORMAT = 'uten-dr-verification-session-v1'
MAX_SESSION_SECONDS = 4 * 3600
MAX_DOWNLOAD_SECONDS = 3 * 3600
MAX_REQUEST_BYTES = 3 * 1024**2
FRAME_BYTES = 1024 * 1024
SOFTWARE_FILES = ('continuous_backup.py', 'snapshot_chunks.py', 'latest_snapshot.py', 'restore_drill.py',
                  'restore_snapshot.py', 'clone_integrity_candidate.py', 'credential_rewrap.cjs',
                  'prepare_ai_credential_candidate.cjs', 'verification_session.py', 'verification_runner.py')
SOFTWARE_FILES += ('uten-dr-recovery.apparmor',)
DEPENDENCY_FILES = {'remote_recovery_catalog.py': 'postgres/backup/remote_recovery_catalog.py'}


def dependency_path(name):
    adjacent = Path(__file__).with_name(name)
    return adjacent if adjacent.exists() else Path(__file__).resolve().parents[1] / DEPENDENCY_FILES[name]


def software_fingerprint():
    import hashlib
    values = {}
    for name in SOFTWARE_FILES:
        path = Path(__file__).with_name(name)
        before = path.lstat()
        if path.is_symlink() or not path.is_file() or before.st_size > 2 * 1024**2:
            raise ValueError('Untrusted verifier software inventory')
        raw = path.read_bytes(); after = path.lstat()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('Verifier software changed during hashing')
        values[name] = hashlib.sha256(raw).hexdigest()
    for name in DEPENDENCY_FILES:
        path = dependency_path(name)
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 2 * 1024**2:
            raise ValueError('Untrusted recovery validation dependency')
        values[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(chunks.canonical(values)).hexdigest()


@contextmanager
def deadline_guard(seconds):
    """Real process timer contains blocked input/output as well as Python work."""
    def expired(*_):raise TimeoutError('Verification session deadline')
    previous = {kind: signal.getsignal(kind) for kind in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT)}
    try:
        signal.signal(signal.SIGALRM, expired)
        signal.signal(signal.SIGTERM, expired)
        signal.signal(signal.SIGINT, expired)
        signal.setitimer(signal.ITIMER_REAL, seconds)
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        for kind, handler in previous.items():signal.signal(kind, handler)


def request(incoming):
    raw = incoming.readline(MAX_REQUEST_BYTES + 1)
    if not raw or not raw.endswith(b'\n') or len(raw) > MAX_REQUEST_BYTES:
        raise ValueError('Invalid bounded verifier request')
    value = base.decode_json(raw)
    if not isinstance(value, dict) or value.get('format') != FORMAT:raise ValueError('Invalid verifier protocol')
    return value


def emit(outgoing, value):
    outgoing.write(chunks.canonical(value) + b'\n'); outgoing.flush()


def current_point(config):
    signed = [row for row in chunks.snapshots(config, base, include_references=False)
              if row[1].get('sourceSignatureVerified') is True]
    if not signed:raise ValueError('No complete signed verification point')
    return max(signed, key=lambda row: (base.instant(row[1]['sourceSnapshotAt']),
               base.instant(row[1]['receivedAt']), row[0].name))


class PointLease:
    """Same immutable marker/actual FD lock already honored by both GC modes."""
    def __init__(self, config, snapshot_id=None):
        self.config, self.snapshot_id = config, snapshot_id
        self.fd = self.single_fd = None
        self.marker = None

    def __enter__(self):
        self.root, _, points = chunks.directories(self.config, base)
        try:
            single = self.root / '.verification-session.lock'
            self.single_fd = os.open(single, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            base.private_path(single)
            fcntl.flock(self.single_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with base.lock(self.root / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS):
                selected = current_point(self.config)
                if self.snapshot_id is not None and self.snapshot_id != selected[0].name:
                    raise ValueError('Only the fixed current complete point may start verification')
                self.snapshot_id = selected[0].name
                self.receipt, _ = chunks.snapshot_record(points / self.snapshot_id, self.config, base, verify=True)
                if self.receipt.get('sourceSignatureVerified') is not True:raise ValueError('Unsigned verification point')
                directory = self.root / '.bundle-leases'; directory.mkdir(mode=0o700, exist_ok=True)
                base.private_path(directory, directory=True)
                active, stale = chunks.bundle_lease_state(self.root, base)
                for path in stale:path.unlink()
                if len(active) >= 254:raise ValueError('Live point lease capacity reached')
                self.marker = directory / (uuid.uuid4().hex + '.json')
                base.atomic_json(self.marker, {'format': chunks.BUNDLE_LEASE_FORMAT, 'snapshotId': self.snapshot_id,
                    'manifestCipherSha256': self.receipt['manifestCipherSha256'],
                    'referenceListSha256': self.receipt['referenceListSha256']})
                self.fd = os.open(self.marker, os.O_RDWR | os.O_NOFOLLOW)
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self
        except BaseException:
            self.close(); raise

    def close(self):
        try:
            if self.fd is not None:os.close(self.fd); self.fd = None
            if self.marker is not None:
                try:
                    with base.lock(self.root / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS):
                        self.marker.unlink(missing_ok=True)
                except base.TransferBusy:
                    pass  # Existing locked GC recognizes the now-inactive, exact marker.
                self.marker = None
        finally:
            if self.single_fd is not None:os.close(self.single_fd); self.single_fd = None

    def __exit__(self, *_):self.close()


def cleanup_evidence(parent, root):
    """Keep the exact current proof's redacted evidence; remove only owned stale jobs."""
    proof_path = root / '.latest-commissioning.json'
    proof = base.read_json(base.private_path(proof_path), maximum=16384) if proof_path.exists() else {}
    entries = []
    for entry in parent.iterdir():
        if len(entries) == 2:raise ValueError('Verification evidence bound requires review')
        entries.append(entry)
    for directory in entries:
        if not re.fullmatch(r'[a-f0-9]{32}', directory.name):
            raise ValueError('Unknown verification evidence requires review')
        base.private_path(directory, directory=True)
        marker = base.read_json(base.private_path(directory / '.owned.json'), maximum=4096)
        info = directory.stat()
        if marker != {'format': FORMAT, 'device': info.st_dev, 'inode': info.st_ino}:
            raise ValueError('Verification evidence directory identity differs')
        allowed = {'.owned.json', 'restore.json', 'review.json', 'applicationConfiguration.json',
                   'signingAndRecipientRecovery.json', 'externalCredentials.json'}
        if any(path.name not in allowed for path in directory.iterdir()):
            raise ValueError('Unknown verification evidence content blocks cleanup')
        review = directory / 'review.json'
        if review.exists() and base.digest(base.private_path(review)) == proof.get('credentialReviewSha256'):
            continue
        shutil.rmtree(directory)


def receive_commission(value, lease, session_id, config, drained):
    expected = {'format', 'operation', 'sessionId', 'report', 'review', 'evidence'}
    if set(value) != expected or value['operation'] != 'commission' or value['sessionId'] != session_id:
        raise ValueError('Verification commission binding differs')
    report, review, evidence = value['report'], value['review'], value['evidence']
    if not isinstance(report, dict) or report.get('verificationSessionId') != session_id:
        raise ValueError('A new restore invocation for this live session is required')
    if report.get('verificationSoftwareSha256') != software_fingerprint():
        raise ValueError('Restore and receiver software inventories differ')
    if (not isinstance(report.get('restoredConfigurationAudit'), dict)
            or report['restoredConfigurationAudit'].get('state') != 'VERIFIED'
            or report.get('ownedContainerRemoved') is not True
            or type(report.get('piiVerified')) is not int or report['piiVerified'] < 1
            or type(report.get('hmacIndexesVerified')) is not int or report['hmacIndexesVerified'] < 1):
        raise ValueError('Actual recovered configuration and PGP/HMAC evidence is required')
    scopes = {'applicationConfiguration', 'signingAndRecipientRecovery', 'externalCredentials'}
    if not isinstance(evidence, dict) or set(evidence) != scopes or not isinstance(review, dict):
        raise ValueError('Every real credential evidence scope is required')
    parent = lease.root / '.verification-reports'; parent.mkdir(mode=0o700, exist_ok=True)
    base.private_path(parent, directory=True)
    with base.lock(lease.root / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS):
        cleanup_evidence(parent, lease.root)
        required = len(chunks.canonical(value)) + 65536
        if (shutil.disk_usage(lease.root).free - required < config['min_free_bytes']
                or base.storage_bytes(lease.root) + required > config['max_storage_bytes']):
            raise base.TransferFailure('RECEIVER_CAPACITY_LIMIT')
        stage = parent / uuid.uuid4().hex; stage.mkdir(mode=0o700)
    identity = stage.stat().st_dev, stage.stat().st_ino
    review_path = stage / 'review.json'
    try:
        base.atomic_json(stage / '.owned.json', {'format': FORMAT, 'device': identity[0], 'inode': identity[1]})
        report_path = stage / 'restore.json'; base.atomic_json(report_path, report)
        # Paths are constructed here, never accepted from the operator's JSON.
        checks = []
        for scope in sorted(scopes):
            path = stage / (scope + '.json'); base.atomic_json(path, evidence[scope])
            checks.append({'scope': scope, 'evidenceFile': str(path), 'evidenceSha256': base.digest(path)})
        if 'checks' in review:raise ValueError('Operator evidence paths are forbidden')
        base.atomic_json(review_path, {**review, 'checks': checks})
        return latest.commission(config, base, chunks, lease.snapshot_id, report_path,
            credential_review_path=review_path, legacy_exports_drained=drained)
    finally:
        if stage.exists():
            base.private_path(stage, directory=True)
            if (stage.stat().st_dev, stage.stat().st_ino) != identity:raise ValueError('Verification report stage changed')
            proof = lease.root / '.latest-commissioning.json'
            referenced = (proof.exists() and review_path.exists() and
                base.read_json(base.private_path(proof), maximum=16384).get('credentialReviewSha256') == base.digest(review_path))
            if not referenced:shutil.rmtree(stage)


def serve(config, incoming, outgoing, *, legacy_exports_drained=False):
    if os.geteuid() != 0 or os.environ.get('SSH_ORIGINAL_COMMAND', ''):
        raise ValueError('Only the fixed root verifier command is accepted')
    if not latest.enabled(config):raise ValueError('Verification rotation is explicitly latest-snapshot only')
    with deadline_guard(30):first = request(incoming)
    if (set(first) == {'format', 'operation', 'reasonCode'} and first['operation'] == 'failure'
            and first['reasonCode'] in {'RUN_FAILED', 'HEALTH_FAILED', 'PRECHECK_FAILED'}):
        base.atomic_json(Path(config['storage_root']) / '.verification-status.json',
            {'format': FORMAT, 'state': 'FAILED', 'observedAt': base.now().isoformat(),
             'reasonCode': first['reasonCode']})
        emit(outgoing, {'format': FORMAT, 'operation': 'failureRecorded'})
        return
    if first == {'format': FORMAT, 'operation': 'status'}:
        with deadline_guard(60), base.lock(Path(config['storage_root']) / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS):
            status = base.build_status(config)
            fields = {'health', 'observedAt', 'completedSnapshots', 'latestCompleteSnapshotAgeSeconds',
                      'snapshotRpo15MinutesFresh', 'storedCiphertextBytes', 'freeBytes', 'maxStorageBytes', 'minFreeBytes'}
            status = {key: value for key, value in status.items() if key in fields or key.startswith('latestRotation')}
            emit(outgoing, {'format': FORMAT, 'operation': 'status', 'observedAt': base.now().isoformat(),
                'status': status, 'profile': latest.profile(config, base)})
        return
    if set(first) != {'format', 'operation', 'snapshotId', 'budgetSeconds', 'downloadBudgetSeconds'} or first['operation'] != 'open':
        raise ValueError('A fixed verification session is required')
    budget, download = first['budgetSeconds'], first['downloadBudgetSeconds']
    if (type(budget) is not int or not 300 <= budget <= MAX_SESSION_SECONDS
            or type(download) is not int or not 30 <= download <= MAX_DOWNLOAD_SECONDS
            or download > budget - 300):raise ValueError('Invalid bounded verification/download budget')
    if first['snapshotId'] is not None and (not isinstance(first['snapshotId'], str) or not chunks.SNAPSHOT.fullmatch(first['snapshotId'])):
        raise ValueError('Invalid fixed snapshot identity')
    deadline = time.monotonic() + budget
    state = Path(config['storage_root']) / '.verification-status.json'
    lease = None
    try:
        with deadline_guard(budget), PointLease(config, first['snapshotId']) as lease:
            session_id = uuid.uuid4().hex
            emit(outgoing, {'format': FORMAT, 'operation': 'opened', 'sessionId': session_id,
                'leaseSeconds': budget, 'downloadBudgetSeconds': download, 'receipt': lease.receipt,
                'profile': latest.profile(config, base), 'maxBundleBytes': chunks.MAX_BUNDLE_BYTES + 16 * 1024**2,
                'softwareSha256': software_fingerprint()})
            expected = {'format': FORMAT, 'operation': 'bundle', 'sessionId': session_id}
            if request(incoming) != expected:raise ValueError('Only one bound bundle export is permitted')
            with chunks.bounded_bundle_output(outgoing, min(deadline, time.monotonic() + download), base) as bounded:
                class Framed:
                    def write(self, raw):
                        if len(raw) > FRAME_BYTES:raise ValueError('Oversized bundle frame')
                        bounded.write(struct.pack('!I', len(raw))); bounded.write(raw); return len(raw)
                chunks.bundle(config, lease.snapshot_id, Framed(), base, verification_budget_seconds=download)
                bounded.write(struct.pack('!I', 0))
            emit(outgoing, {'format': FORMAT, 'operation': 'bundleComplete', 'sessionId': session_id})
            # The same FD remains locked while the other endpoint restores and
            # audits credentials. There is no renew operation or lease extension.
            result = receive_commission(request(incoming), lease, session_id, config, legacy_exports_drained)
        # The restore/credential/commission phase is over. Only now release the
        # FD, run GC back to one root, and acknowledge the complete operation.
        with deadline_guard(max(.001, deadline - time.monotonic())):
            base.retain(config)
            base.atomic_json(state, {'format': FORMAT, 'state': 'VERIFIED', 'observedAt': base.now().isoformat(),
                                     'snapshotId': lease.snapshot_id, 'restoreReportSha256': result['restoreReportSha256']})
            emit(outgoing, {'format': FORMAT, 'operation': 'commissioned', 'sessionId': session_id, 'result': result})
    except BaseException as error:
        if not isinstance(error, BlockingIOError):
            base.atomic_json(state, {'format': FORMAT, 'state': 'FAILED', 'observedAt': base.now().isoformat(),
                'snapshotId': lease.snapshot_id if lease else None, 'errorType': type(error).__name__})
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--legacy-exports-drained', action='store_true')
    args = parser.parse_args(); os.umask(0o077)
    try:
        if os.geteuid() != 0:raise ValueError('The installed verifier entry point is root-only')
        for name in SOFTWARE_FILES:base.private_path(Path(__file__).with_name(name))
        for name in DEPENDENCY_FILES:base.private_path(dependency_path(name))
        serve(base.read_json(base.private_path(args.config)), sys.stdin.buffer, sys.stdout.buffer,
              legacy_exports_drained=args.legacy_exports_drained)
        return 0
    except Exception as error:
        print(json.dumps({'state': 'VERIFICATION_SESSION_FAILED', 'errorType': type(error).__name__}), file=sys.stderr)
        return 1


if __name__ == '__main__':raise SystemExit(main())
