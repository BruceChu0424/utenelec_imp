#!/usr/bin/python3
"""Off-cloud root verifier: real restore, current credential audit, bounded renewal.

Only encrypted systemd credentials supply the new-generation recovery key and
passphrase. SSH carries ciphertext and redacted evidence, never those secrets.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import timedelta
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import uuid


def sibling(name):
    spec = importlib.util.spec_from_file_location('uten_weekly_' + name, Path(__file__).with_name(name + '.py'))
    module = importlib.util.module_from_spec(spec); sys.modules[spec.name] = module; spec.loader.exec_module(module)
    return module


session = sibling('verification_session')
base, chunks, latest = session.base, session.chunks, session.latest
restore = sibling('restore_snapshot')
drill = restore.restore_drill
CONFIG_FORMAT = 'uten-dr-verifier-config-v1'
FIXED_ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8', 'HOME': '/root'}


def load_config(path, *, needs_recovery_runtime=True):
    config = base.read_json(base.private_path(path), maximum=65536)
    keys = {'format', 'instance_id', 'ssh_target', 'known_hosts_file', 'allowed_signers_file',
            'recipient_fingerprint', 'spool_mountpoint', 'spool_directory', 'runtime_directory', 'state_directory',
            'docker', 'node', 'restore_profile', 'download_budget_seconds', 'session_budget_seconds',
            'restore_budget_seconds', 'proof_valid_days', 'expected_image_id'}
    keys.update(('postgres_image', 'runtime'))
    if not isinstance(config, dict) or set(config) != keys or config['format'] != CONFIG_FORMAT:
        raise ValueError('Unknown or missing verifier configuration fields')
    if str(uuid.UUID(config['instance_id'])) != config['instance_id']:raise ValueError('Invalid verifier instance identity')
    if not isinstance(config['ssh_target'], str) or not re.fullmatch(r'[A-Za-z0-9_.@:-]+', config['ssh_target']):
        raise ValueError('Invalid fixed verifier SSH target')
    if not base.FINGERPRINT.fullmatch(config['recipient_fingerprint']):raise ValueError('Invalid pinned recipient')
    drill.runtime_image_identity(config['expected_image_id'])
    drill.official_postgres_image(config['postgres_image'])
    if config['runtime'] not in {'docker', 'podman'}:raise ValueError('Select the actual reviewed OCI runtime explicitly')
    limits = {'download_budget_seconds': (30, session.MAX_DOWNLOAD_SECONDS),
              'session_budget_seconds': (600, session.MAX_SESSION_SECONDS),
              'restore_budget_seconds': (60, 3600), 'proof_valid_days': (1, 30)}
    for key, (low, high) in limits.items():
        if type(config[key]) is not int or not low <= config[key] <= high:raise ValueError('Invalid bounded verifier budget')
    if config['download_budget_seconds'] + config['restore_budget_seconds'] + 300 > config['session_budget_seconds']:
        raise ValueError('Download, restore and cleanup do not fit the one nonrenewable lease')
    if config['restore_profile'] not in drill.RESOURCE_PROFILES:raise ValueError('Unknown fixed restore profile')
    for key in ('known_hosts_file', 'allowed_signers_file'):base.private_path(config[key])
    for key in ('spool_directory', 'state_directory'):base.private_path(config[key], directory=True)
    if needs_recovery_runtime:base.private_path(config['runtime_directory'], directory=True)
    mount, spool, runtime = (Path(config[key]) for key in ('spool_mountpoint', 'spool_directory', 'runtime_directory'))
    if (not mount.is_absolute() or mount.resolve() != mount or not mount.is_mount()
            or not spool.is_relative_to(mount) or spool == mount or spool.stat().st_dev != mount.stat().st_dev
            or mount.stat().st_uid != 0 or mount.stat().st_mode & 0o022):
        raise ValueError('Recovery spool must remain on the approved root-owned mounted backup volume')
    if (not runtime.is_absolute() or not runtime.is_relative_to('/run') or '..' in runtime.parts or not Path('/run').is_mount()
            or (needs_recovery_runtime and runtime.stat().st_dev != Path('/run').stat().st_dev)):
        raise ValueError('Private recovery keyring requires the real /run memory filesystem')
    for key in ('docker', 'node'):
        program = Path(config[key]); info = program.lstat()
        if not program.is_absolute() or program.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('Recovery runtimes must be reviewed root-owned executable files')
    return config


def credential(name, maximum):
    root = Path(os.environ.get('CREDENTIALS_DIRECTORY', ''))
    base.private_path(root, directory=True)
    path = base.private_path(root / name)
    if path.stat().st_size > maximum:raise ValueError('Oversized protected verifier credential')
    return path


def ssh_command(config):
    key = credential('verifier-ssh-key', 65536)
    return ['/usr/bin/ssh', '-F', '/dev/null', '-T', '-p', '22', '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'GlobalKnownHostsFile=/dev/null',
            '-o', 'UserKnownHostsFile=' + config['known_hosts_file'], '-o', 'IdentitiesOnly=yes',
            '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes', '-o', 'ControlMaster=no',
            '-o', 'ControlPath=none', '-o', 'ProxyCommand=none', '-o', 'ProxyJump=none',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', '-o', 'ConnectTimeout=15',
            '-i', str(key), config['ssh_target']]


class Channel:
    def __init__(self, process, deadline):
        self.process, self.deadline, self.pending = process, deadline, bytearray()
        self.reader = selectors.DefaultSelector(); self.writer = selectors.DefaultSelector()
        for stream in (process.stdout, process.stdin):os.set_blocking(stream.fileno(), False)
        self.reader.register(process.stdout.fileno(), selectors.EVENT_READ)
        self.writer.register(process.stdin.fileno(), selectors.EVENT_WRITE)

    def wait(self, selector):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0 or not selector.select(remaining):raise TimeoutError('Bounded verifier transport deadline')

    def send(self, value):
        pending = memoryview(chunks.canonical(value) + b'\n')
        if len(pending) > session.MAX_REQUEST_BYTES:raise ValueError('Oversized verifier request')
        while pending:
            self.wait(self.writer)
            try:pending = pending[os.write(self.process.stdin.fileno(), pending):]
            except BlockingIOError:pass

    def receive(self):
        self.wait(self.reader)
        try:raw = os.read(self.process.stdout.fileno(), 65536)
        except BlockingIOError:return
        if not raw:raise EOFError('Verifier session ended before completion')
        self.pending.extend(raw)

    def exact(self, length):
        if not 0 <= length <= session.FRAME_BYTES:raise ValueError('Oversized bounded verifier frame')
        while len(self.pending) < length:self.receive()
        value = bytes(self.pending[:length]); del self.pending[:length]; return value

    def line(self):
        while b'\n' not in self.pending:
            if len(self.pending) > 65536:raise ValueError('Oversized verifier response metadata')
            self.receive()
        index = self.pending.index(b'\n')
        if index > 65536:raise ValueError('Oversized verifier response metadata')
        value = base.decode_json(bytes(self.pending[:index])); del self.pending[:index + 1]
        if not isinstance(value, dict) or value.get('format') != session.FORMAT:raise ValueError('Invalid verifier response')
        return value

    def download(self, destination, maximum, seconds):
        previous = self.deadline; self.deadline = min(previous, time.monotonic() + seconds)
        total = 0; checksum = hashlib.sha256()
        try:
            fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as output:
                while True:
                    length = struct.unpack('!I', self.exact(4))[0]
                    if length == 0:break
                    if length > session.FRAME_BYTES or total + length > maximum:raise ValueError('Cipher bundle budget exceeded')
                    raw = self.exact(length); output.write(raw); checksum.update(raw); total += length
                output.flush(); os.fsync(output.fileno())
            return {'bundleBytes': total, 'bundleSha256': checksum.hexdigest()}
        finally:self.deadline = previous

    def close(self):self.reader.close(); self.writer.close()


@contextmanager
def connection(config, deadline):
    process = subprocess.Popen(ssh_command(config), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env=FIXED_ENV, start_new_session=True)
    channel = None
    try:
        channel = Channel(process, deadline); yield channel
    finally:
        if channel is not None:channel.close()
        for stream in (process.stdin, process.stdout):
            if stream is not None:stream.close()
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill(); process.wait(timeout=5)


@contextmanager
def recovered_keyring(config):
    private = credential('recovery-private-key', 1024**2)
    secret = credential('recovery-passphrase', 4096).read_bytes().rstrip(b'\n')
    if not secret or b'\n' in secret or b'\r' in secret or b'\0' in secret:raise ValueError('Invalid protected recovery passphrase')
    with tempfile.TemporaryDirectory(prefix='recovery-keyring-', dir=config['runtime_directory']) as directory:
        home = Path(directory); home.chmod(0o700)
        try:
            with private.open('rb') as stream:
                result = subprocess.run(['/usr/bin/gpg', '--no-options', '--homedir', str(home), '--batch', '--import'],
                    stdin=stream, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=FIXED_ENV, timeout=30)
            if result.returncode:raise ValueError('Protected recovery key import failed')
            result = subprocess.run(['/usr/bin/gpg', '--no-options', '--homedir', str(home), '--batch',
                '--with-colons', '--list-secret-keys'], capture_output=True, env=FIXED_ENV, timeout=15, check=True)
            primaries = []; need = False
            for line in result.stdout.decode().splitlines():
                columns = line.split(':')
                if columns[0] == 'sec':need = True
                elif columns[0] == 'fpr' and need:primaries.append(columns[9]); need = False
            if primaries != [config['recipient_fingerprint']]:raise ValueError('Recovered private key differs from the pinned generation')
            yield home, secret
        finally:
            subprocess.run(['/usr/bin/gpgconf', '--homedir', str(home), '--kill', 'gpg-agent'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=FIXED_ENV, timeout=10)


def credential_evidence(report, receipt, profile, days):
    candidate = report.get('integrityCandidate', {})
    audit = report.get('restoredConfigurationAudit', {})
    required = ('databaseRestored', 'attachmentsVerified', 'corePgpAndHmacVerified', 'keysVerified',
                'sourceSignatureVerified', 'isolated', 'sideEffectsDisabled', 'ownedContainerRemoved')
    if (type(days) is not int or not 1 <= days <= 30
            or report.get('state') != 'ISOLATED_DATABASE_AND_ORIGINALS_RESTORED'
            or any(report.get(key) is not True for key in required)
            or audit.get('state') != 'VERIFIED' or audit.get('invalidNames') or audit.get('externalApiCallsPerformed') is not False
            or candidate.get('state') != 'ISOLATED_CLONE_INTEGRITY_CANDIDATE_VERIFIED'
            or candidate.get('aiPlaintextPreserved') is not True or candidate.get('aiCurrentCompanyIssuerVerified') is not True
            or not candidate.get('after', {}).get('blockers') or any(candidate['after']['blockers'].values())
            or report.get('hmacIndexesVerified', 0) < 1 or report.get('piiVerified', 0) < 1):
        raise ValueError('Actual isolated crypto/configuration/AI evidence is incomplete')
    report_sha = hashlib.sha256(chunks.canonical(report) + b'\n').hexdigest()
    moment = base.now() - timedelta(seconds=1)
    common = {'format': 'uten-dr-credential-evidence-v1', 'state': 'VERIFIED',
              'restoreReportSha256': report_sha, 'configurationFileSha256': candidate['plan']['configSha256'],
              'pairedRecoveryInputBindingSha256': report['pairedRecoveryInputBindingSha256'], 'observedAt': moment.isoformat()}
    methods = {'applicationConfiguration': 'RESTORED_CONFIGURATION_AUDIT',
               'signingAndRecipientRecovery': 'OFFLINE_PRIVATE_KEY_RECOVERY',
               'externalCredentials': 'RESTORED_CREDENTIAL_INVENTORY_AUDIT'}
    evidence = {scope: {**common, 'scope': scope, 'method': method} for scope, method in methods.items()}
    review = {'format': 'uten-dr-credential-review-v1', 'restoreReportSha256': report_sha,
        'pairedRecoveryInputBindingSha256': report['pairedRecoveryInputBindingSha256'],
        'configurationVersion': receipt['configurationVersion'], 'configurationFileSha256': candidate['plan']['configSha256'],
        'profile': profile, 'reviewedAt': moment.isoformat(), 'expiresAt': (moment + timedelta(days=days)).isoformat()}
    return review, evidence


def runtime_preflight(config):
    """Exercise the exact isolated OCI arguments before any backup/key is loaded."""
    state = Path(config['state_directory']); name = 'uten-drill-' + uuid.uuid4().hex[:12]
    options = {'verification_owner_id': config['instance_id']}
    def command(arguments, timeout=30):
        return drill.run_isolated_command([config['docker'], *arguments], timeout=timeout, spool_directory=state)
    with drill.recovery_admission(config['docker'], config['restore_profile'], options, state, config['runtime']):
        resources = drill.resource_profile(config['restore_profile'])
        try:
            command(drill.container_run_arguments(name, config['restore_profile'], config['instance_id'],
                config['postgres_image'], config['runtime']), timeout=90)
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                ready = subprocess.run([config['docker'], 'exec', name, 'pg_isready', '-q', '-U', 'postgres', '-d', 'drill'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, env=FIXED_ENV)
                if ready.returncode == 0 and command(['exec', name, '/bin/cat', '/proc/1/comm']).decode().strip() == 'postgres':break
                time.sleep(.5)
            else:raise TimeoutError('Isolated OCI preflight database did not start')
            info = drill.inspected_isolation(command, name, resources, config['runtime'], config['expected_image_id'])
            version = int(command(['exec', name, 'psql', '-XqAt', '-U', 'postgres', '-d', 'drill',
                '-c', "SELECT current_setting('server_version_num')"]).strip())
            if not 160000 <= version < 170000:raise ValueError('The actual isolated server is not PostgreSQL 16')
            result = {'state': 'OCI_RUNTIME_PROFILE_VERIFIED', 'observedAt': base.now().isoformat(),
                'resources': resources, 'serverVersionNum': version, 'imageId': info['Image'], 'imageName': config['postgres_image'],
                'runtime': config['runtime'], 'verifiedKernelLimits': info['_verifiedKernelLimits'],
                'appArmorEvidence': info.get('_verifiedAppArmor'),
                'backendVersion': command(['--version']).decode().strip()[:256],
                'databaseRestored': False, 'productionDatabaseContacted': False, 'hostMounts': False, 'network': 'none'}
        finally:
            removed = drill.remove_owned_clone(config['docker'], name, primary_error=sys.exc_info()[0] is not None)
            if removed and 'result' in locals():
                result['ownedContainerRemoved'] = True
                base.atomic_json(state / 'runtime-preflight.json', result)
        return result


def report_failure(config, reason):
    """A failed local precheck also reaches the existing cloud health publisher."""
    try:
        with session.deadline_guard(30), connection(config, time.monotonic() + 25) as channel:
            channel.send({'format': session.FORMAT, 'operation': 'failure', 'reasonCode': reason})
            if channel.line() != {'format': session.FORMAT, 'operation': 'failureRecorded'}:
                raise ValueError('Failure notification was not acknowledged')
        return {'failureReportedToReceiver': True}
    except Exception as error:
        # Preserve the primary failure while making this second failure visible.
        return {'failureReportedToReceiver': False, 'failureNotificationErrorType': type(error).__name__}


def verify(config):
    started = time.monotonic(); deadline = started + config['session_budget_seconds']
    state = Path(config['state_directory']); status = state / 'status.json'
    try:
        with base.lock(state / 'runner.lock', timeout=0), session.deadline_guard(config['session_budget_seconds']):
            drill.cleanup_owned_containers(config['docker'], config['instance_id'], state, runtime=config['runtime'])
            drill.resource_profile(config['restore_profile'])
            reserve = 2 * (restore.bundle_limit() + 16 * 1024**2) + 2 * restore.plain_limit() + 9 * 1024**3
            if shutil.disk_usage(config['spool_directory']).free < reserve:
                raise ValueError('Backup volume reserve cannot fit complete bounded recovery copies')
            with drill.recovery_workspace(Path(config['spool_directory']), required_bytes=reserve - 1024**3) as workspace, \
                    recovered_keyring(config) as (home, secret), connection(config, deadline) as channel:
                channel.send({'format': session.FORMAT, 'operation': 'open', 'snapshotId': None,
                    'budgetSeconds': config['session_budget_seconds'], 'downloadBudgetSeconds': config['download_budget_seconds']})
                opened = channel.line()
                if (opened.get('operation') != 'opened' or opened.get('softwareSha256') != session.software_fingerprint()
                        or opened.get('downloadBudgetSeconds') != config['download_budget_seconds']
                        or opened.get('leaseSeconds') != config['session_budget_seconds']
                        or opened.get('profile', {}).get('recipientFingerprint') != config['recipient_fingerprint']
                        or opened.get('profile', {}).get('allowedSignersSha256') != base.digest(config['allowed_signers_file'])):
                    raise ValueError('Pinned verifier generation/software/trust profile differs')
                session_id, receipt = opened['sessionId'], opened['receipt']
                if not re.fullmatch(r'[a-f0-9]{32}', session_id):raise ValueError('Invalid verifier session identity')
                channel.send({'format': session.FORMAT, 'operation': 'bundle', 'sessionId': session_id})
                bundle = workspace / 'bundle.tar'
                transfer = channel.download(bundle, restore.bundle_limit() + 16 * 1024**2, config['download_budget_seconds'])
                if channel.line() != {'format': session.FORMAT, 'operation': 'bundleComplete', 'sessionId': session_id}:
                    raise ValueError('Bundle completion binding failed')
                remaining = int(deadline - time.monotonic()) - 120
                if remaining < 60:raise TimeoutError('No bounded time remains for real recovery')
                args = SimpleNamespace(bundle=bundle, spool_directory=workspace, gpg_home=home,
                    allowed_signers=Path(config['allowed_signers_file']), docker=Path(config['docker']),
                    expected_source_set_id=receipt['sourceSetId'], expected_manifest_sha=receipt['sourceManifestSha256'],
                    expected_snapshot_id=receipt['snapshotId'], expected_cipher_sha=receipt['manifestCipherSha256'],
                    expected_reference_sha=receipt['referenceListSha256'],
                    restore_profile=config['restore_profile'], image=config['postgres_image'],
                    runtime=config['runtime'], budget_seconds=min(config['restore_budget_seconds'], remaining))
                preimage = workspace / 'candidate-preimage.gpg'
                options = {'use_verified_restored_current_hmac': True, 'node': Path(config['node']),
                    'recipient': config['recipient_fingerprint'], 'preimage': preimage, 'gpg_home': home, 'ai_only': False,
                    'verification_owner_id': config['instance_id'], 'expected_image_id': config['expected_image_id']}
                report = restore.restore_bundle(args, secret, options)
                resources = report.get('recoveryResources', {})
                if drill.runtime_image_identity(resources.get('containerImageId')) != drill.runtime_image_identity(config['expected_image_id']):
                    raise ValueError('Actual restored OCI image differs from reviewed image')
                report.update(verificationSessionId=session_id, verificationSoftwareSha256=session.software_fingerprint(),
                              verificationElapsedSeconds=round(time.monotonic() - started, 3), **transfer)
                if report['verificationSoftwareSha256'] != opened['softwareSha256']:
                    raise ValueError('Verifier software changed during the run')
                review, evidence = credential_evidence(report, receipt, opened['profile'], config['proof_valid_days'])
                channel.send({'format': session.FORMAT, 'operation': 'commission', 'sessionId': session_id,
                              'report': report, 'review': review, 'evidence': evidence})
                accepted = channel.line()
                if (accepted.get('operation') != 'commissioned' or accepted.get('sessionId') != session_id
                        or accepted.get('result', {}).get('restoreReportSha256') != review['restoreReportSha256']):
                    raise ValueError('Commissioning acknowledgement differs from the actual restore')
                channel.process.stdin.close()
                if channel.process.wait(timeout=min(10, max(.001, deadline - time.monotonic()))) != 0:
                    raise ValueError('Verifier process did not finish its complete operation successfully')
                if preimage.stat().st_size > 4 * 1024**2:raise ValueError('Oversized encrypted recovery audit')
                # Only bounded redacted evidence and recipient-encrypted preimage persist.
                base.atomic_json(state / 'last-restore-report.json', report)
                base.atomic_json(state / 'last-credential-review.json', review)
                base.atomic_json(state / 'last-credential-evidence.json', evidence)
                destination = state / 'last-candidate-preimage.gpg'
                temporary = state / ('.preimage-' + uuid.uuid4().hex)
                try:
                    with temporary.open('xb') as stream:stream.write(preimage.read_bytes()); stream.flush(); os.fsync(stream.fileno())
                    os.replace(temporary, destination); base.sync_directory(state)
                finally:temporary.unlink(missing_ok=True)
                result = {'format': CONFIG_FORMAT, 'state': 'VERIFIED_AND_RENEWED', 'observedAt': base.now().isoformat(),
                          'snapshotId': receipt['snapshotId'], 'restoreReportSha256': review['restoreReportSha256'],
                          'expiresAt': review['expiresAt'], 'externalApiCallsPerformed': False, **transfer}
                base.atomic_json(status, result); return result
    except BaseException as error:
        notification = report_failure(config, 'RUN_FAILED')
        base.atomic_json(status, {'format': CONFIG_FORMAT, 'state': 'FAILED', 'observedAt': base.now().isoformat(),
                                 'errorType': type(error).__name__, 'lastSuccessfulEvidencePreserved': True,
                                 'ownedContainerCleanupFailed': bool(drill.SAFE_COUNTS.get('ownedContainerCleanupFailed')), **notification})
        raise


def health(config):
    try:
        with session.deadline_guard(120):
            deadline = time.monotonic() + 110
            drill.cleanup_owned_containers(config['docker'], config['instance_id'], config['state_directory'],
                                           require_idle=False, runtime=config['runtime'])
            with connection(config, deadline) as channel:
                channel.send({'format': session.FORMAT, 'operation': 'status'}); response = channel.line()
                status = response.get('status')
                if (response.get('operation') != 'status' or not isinstance(status, dict)
                        or status.get('health') not in {'HEALTHY', 'DEGRADED'}):
                    raise ValueError('Invalid health response')
                result = {'state': 'CURRENT' if status['health'] == 'HEALTHY' else 'DEGRADED',
                          'observedAt': base.now().isoformat(), 'receiver': status,
                          'alertRoute': 'CONTROL_PLANE_HEALTH_AND_SYSTEMD_JOURNAL', 'externalNotificationDelivered': False}
                local_status = Path(config['state_directory']) / 'status.json'
                if local_status.exists() and base.read_json(base.private_path(local_status)).get('state') == 'FAILED':
                    result['state'] = 'DEGRADED'
    except Exception as error:
        # A failed check must replace an old CURRENT receipt. Keep the original
        # error type separate from the bounded notification's outcome; never
        # persist an exception message or malformed peer body/credential value.
        notification = report_failure(config, 'HEALTH_FAILED')
        result = {'state': 'DEGRADED', 'observedAt': base.now().isoformat(),
                  'errorType': type(error).__name__, 'lastSuccessfulEvidencePreserved': True,
                  'alertRoute': 'CONTROL_PLANE_HEALTH_AND_SYSTEMD_JOURNAL',
                  'externalNotificationDelivered': False, **notification}
    base.atomic_json(Path(config['state_directory']) / 'health.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('run', 'check', 'preflight'))
    parser.add_argument('--config', required=True, type=Path)
    args = parser.parse_args(); os.umask(0o077)
    try:
        if os.geteuid() != 0:raise ValueError('The verifier requires its root-owned protected runtime')
        for name in session.SOFTWARE_FILES:base.private_path(Path(__file__).with_name(name))
        for name in session.DEPENDENCY_FILES:base.private_path(session.dependency_path(name))
        credentials = os.environ.get('CREDENTIALS_DIRECTORY', '')
        os.environ.clear(); os.environ.update(FIXED_ENV, CREDENTIALS_DIRECTORY=credentials)
        config = load_config(args.config, needs_recovery_runtime=args.mode != 'check')
        result = verify(config) if args.mode == 'run' else runtime_preflight(config) if args.mode == 'preflight' else health(config)
        print(json.dumps(result))
        return 0 if result['state'] in {'VERIFIED_AND_RENEWED', 'CURRENT', 'OCI_RUNTIME_PROFILE_VERIFIED'} else 1
    except Exception as error:
        print(json.dumps({'state': 'VERIFICATION_RUNNER_FAILED', 'errorType': type(error).__name__}), file=sys.stderr)
        return 1


if __name__ == '__main__':raise SystemExit(main())
