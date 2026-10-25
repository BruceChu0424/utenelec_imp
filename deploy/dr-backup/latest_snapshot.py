"""Explicit cloud-only single recovery root policy; history remains the default.

All mutations here run under the existing receiver mutex. An upload lease protects
already existing opaque ciphertext as well as new objects; only a complete signed
point can become a root. Commissioning is a separate local administrator action.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import timedelta
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import tarfile
import time
import uuid

MODE = 'latest_snapshot'
LEASE_SECONDS = 900
ORPHAN_GRACE_SECONDS = 120
LEASE_FORMAT = 'uten-dr-snapshot-upload-v1'
STAGE_FORMAT = 'uten-dr-receiver-stage-v1'
PROOF_FORMAT = 'uten-dr-latest-commissioning-v1'
FULL_LEASE_FORMAT = 'uten-dr-archive-export-v1'
BINDINGS = ('snapshotId', 'nonce', 'sourceSetId', 'sourceSnapshotAt',
            'sourceManifestSha256', 'recipientFingerprint', 'configurationVersion')
PROOF_BINDINGS = ('snapshotId', 'sourceSetId', 'sourceManifestSha256',
                  'manifestCipherSha256', 'referenceListSha256', 'configurationVersion')


def enabled(config):
    mode = config.get('retention_mode', 'history')
    if mode not in {'history', MODE}:
        raise ValueError('Unknown cloud retention mode')
    return mode == MODE


def profile(config, base):
    fingerprint = config.get('recipient_fingerprint')
    if not isinstance(fingerprint, str) or not base.FINGERPRINT.fullmatch(fingerprint):
        raise ValueError('Invalid commissioning recipient profile')
    signers = base.private_path(config['allowed_signers_file'])
    if signers.stat().st_size > 65536:
        raise ValueError('Oversized commissioning signer profile')
    return {'recipientFingerprint': fingerprint, 'allowedSignersSha256': base.digest(signers),
            'signingPrincipal': 'uten-backup-source', 'signingNamespace': 'uten-dr-snapshot-v1',
            'recoverySchema': 'uten-dr-chunked-snapshot-v1/uten-paired-internal-v1+v2/configuration-identity-v1'}


def commissioning(config, base):
    root = base.private_path(config['storage_root'], directory=True)
    path = root / '.latest-commissioning.json'
    if not path.exists():
        return None, 'AWAITING_RESTORE_ACCEPTANCE'
    with base.private_path(path).open('rb') as stream:
        raw = stream.read(16385)
    if len(raw) > 16384:
        raise ValueError('Oversized local commissioning evidence')
    proof = base.decode_json(raw)
    proof_sha = hashlib.sha256(raw).hexdigest()
    expected = {'format', 'profile', 'acceptedAt', 'restoreReportSha256',
                'pairedRecoveryInputBindingSha256', 'legacyExportsDrained', 'credentialReviewSha256',
                'configurationFileSha256', 'expiresAt', *PROOF_BINDINGS}
    if (not isinstance(proof, dict) or set(proof) != expected or proof['format'] != PROOF_FORMAT
            or proof['legacyExportsDrained'] is not True
            or not base.HASH.fullmatch(proof['restoreReportSha256'])
            or not base.HASH.fullmatch(proof['pairedRecoveryInputBindingSha256'])):
        raise ValueError('Invalid local commissioning evidence')
    expiry = root / '.latest-proof-expired.json'
    if expiry.exists():
        marker = base.read_json(base.private_path(expiry), maximum=4096)
        if set(marker) != {'format', 'proofSha256'} or marker['format'] != 'uten-dr-proof-expiry-v1':
            raise ValueError('Malformed commissioning expiry evidence')
        if marker['proofSha256'] == proof_sha:
            return None, 'COMMISSIONING_EXPIRED'
    if base.instant(proof['expiresAt']) <= base.now():
        # A later wall-clock rollback must not resurrect a proof already observed
        # expired. A newly registered proof has a different immutable digest.
        base.atomic_json(expiry, {'format': 'uten-dr-proof-expiry-v1', 'proofSha256': proof_sha})
        return None, 'COMMISSIONING_EXPIRED'
    if (not all(isinstance(proof.get(key), str) and base.HASH.fullmatch(proof[key]) for key in
            ('configurationVersion', 'sourceManifestSha256', 'manifestCipherSha256', 'referenceListSha256',
             'configurationFileSha256', 'credentialReviewSha256'))
            or not re.fullmatch(r'snapshot-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}', proof['snapshotId'])
            or not base.SET.fullmatch(proof['sourceSetId'])):
        raise ValueError('Commissioning point and configuration identity are malformed')
    if base.instant(proof['acceptedAt']) > base.now() + timedelta(seconds=5):
        return None, 'COMMISSIONING_CLOCK_MOVED_BACKWARDS'
    if not 0 < (base.instant(proof['expiresAt']) - base.instant(proof['acceptedAt'])).total_seconds() <= 30 * 86400:
        raise ValueError('Invalid commissioning validity bound')
    if proof['profile'] != profile(config, base):
        return None, 'COMMISSIONING_PROFILE_CHANGED'
    return proof, 'ACTIVE'


def credential_review(path, report, report_sha, receipt, config, base):
    """Consume root-owned evidence, not a caller's `cleared=true` assertion.

    The real clone result proves ancillary decryption/issuer roundtrips. Local
    operational checks remain a separately attributable root review with artifact
    hashes, exact restored-config binding and a bounded validity period.
    """
    review_file = base.private_path(path)
    if review_file.stat().st_uid != 0:
        raise ValueError('Credential review must be root-owned')
    review = base.read_json(review_file, maximum=65536)
    candidate = report.get('integrityCandidate', {})
    after = candidate.get('after', {})
    configuration_sha = candidate.get('plan', {}).get('configSha256')
    if (candidate.get('state') != 'ISOLATED_CLONE_INTEGRITY_CANDIDATE_VERIFIED'
            or candidate.get('productionMutated') is not False or candidate.get('companyHmacChanged') is not False
            or candidate.get('aiPlaintextPreserved') is not True or candidate.get('aiCurrentCompanyIssuerVerified') is not True
            or not isinstance(after.get('blockers'), dict) or not after['blockers'] or any(after['blockers'].values())
            or type(after.get('aiCredentialsToRewrap')) is not int or after['aiCredentialsToRewrap'] != 0 or after.get('configSha256') != configuration_sha
            or not isinstance(configuration_sha, str) or not base.HASH.fullmatch(configuration_sha)):
        raise ValueError('Real isolated ancillary credential decryption and issuer evidence is required')
    expected = {'format', 'restoreReportSha256', 'pairedRecoveryInputBindingSha256', 'configurationVersion',
        'configurationFileSha256', 'profile', 'reviewedAt', 'expiresAt', 'checks'}
    if (not isinstance(review, dict) or set(review) != expected or review['format'] != 'uten-dr-credential-review-v1'
            or review['restoreReportSha256'] != report_sha
            or review['pairedRecoveryInputBindingSha256'] != report['pairedRecoveryInputBindingSha256']
            or review['configurationVersion'] != receipt['configurationVersion']
            or review['configurationFileSha256'] != configuration_sha or review['profile'] != profile(config, base)):
        raise ValueError('Credential review is not bound to the actual point, restore and configuration')
    reviewed, expires = base.instant(review['reviewedAt']), base.instant(review['expiresAt'])
    if reviewed > base.now() or expires <= base.now() or not 0 < (expires - reviewed).total_seconds() <= 30 * 86400:
        raise ValueError('Credential review must be current and valid for at most thirty days')
    scopes = {'applicationConfiguration', 'signingAndRecipientRecovery', 'externalCredentials'}
    checks = review['checks']
    if (not isinstance(checks, list) or len(checks) != len(scopes)
            or any(not isinstance(row, dict) or set(row) != {'scope', 'evidenceFile', 'evidenceSha256'} for row in checks)
            or {row['scope'] for row in checks} != scopes):
        raise ValueError('A full credential review needs every bounded evidence scope')
    for row in checks:
        evidence_file = base.private_path(row['evidenceFile'])
        if evidence_file.stat().st_uid != 0 or base.digest(evidence_file) != row['evidenceSha256']:
            raise ValueError('Credential evidence identity or ownership differs')
        evidence = base.read_json(evidence_file, maximum=16384)
        keys = {'format', 'scope', 'method', 'state', 'restoreReportSha256', 'configurationFileSha256',
                'pairedRecoveryInputBindingSha256', 'observedAt'}
        methods = {'applicationConfiguration': 'RESTORED_CONFIGURATION_AUDIT',
                   'signingAndRecipientRecovery': 'OFFLINE_PRIVATE_KEY_RECOVERY',
                   'externalCredentials': 'RESTORED_CREDENTIAL_INVENTORY_AUDIT'}
        if (not isinstance(evidence, dict) or set(evidence) != keys
                or evidence['format'] != 'uten-dr-credential-evidence-v1' or evidence['scope'] != row['scope']
                or evidence['method'] != methods[row['scope']] or evidence['state'] != 'VERIFIED'
                or evidence['restoreReportSha256'] != report_sha or evidence['configurationFileSha256'] != configuration_sha
                or evidence['pairedRecoveryInputBindingSha256'] != report['pairedRecoveryInputBindingSha256']
                or not reviewed - timedelta(days=1) <= base.instant(evidence['observedAt']) <= reviewed):
            raise ValueError('Credential evidence is stale, incomplete or bound to another recovery input')
    return review, base.digest(review_file)


def commission(config, base, chunks, snapshot_id, report_path, *, credential_review_path=None, legacy_exports_drained=False):
    """Root-only local CLI: never available to the upload identity/RPC."""
    if os.geteuid() != 0 or not enabled(config) or legacy_exports_drained is not True:
        raise ValueError('Root commissioning requires drained legacy unleased exports')
    root, objects, points = chunks.directories(config, base)
    if not isinstance(snapshot_id, str) or not chunks.SNAPSHOT.fullmatch(snapshot_id):
        raise ValueError('Invalid commissioning point identity')
    with base.lock(root / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
        receipt, refs = chunks.snapshot_record(points / snapshot_id, config, base, verify=True)
        if receipt.get('sourceSignatureVerified') is not True:
            raise ValueError('Commissioning needs an independently signed complete point')
        for row in refs:
            known = chunks.object_record(objects, row['opaqueId'], base, verify=True)
            if known is None or any(known[key] != row[key] for key in ('cipherSha256', 'cipherBytes')):
                raise ValueError('Commissioning dependency closure failed')
        report_file = base.private_path(report_path)
        report = base.read_json(report_file, maximum=2 * 1024**2)
        required = ('databaseRestored', 'attachmentsVerified', 'corePgpAndHmacVerified',
                    'keysVerified', 'sourceSignatureVerified', 'isolated', 'sideEffectsDisabled')
        if (report.get('state') != 'ISOLATED_DATABASE_AND_ORIGINALS_RESTORED'
                or any(report.get(key) is not True for key in required)
                or any(report.get(key) != receipt[key] for key in PROOF_BINDINGS)
                or not isinstance(report.get('pairedRecoveryInputBindingSha256'), str)
                or not base.HASH.fullmatch(report['pairedRecoveryInputBindingSha256'])):
            raise ValueError('A complete isolated restore with cleared credential gaps is required')
        review, review_sha = credential_review(credential_review_path, report, base.digest(report_file), receipt, config, base)
        proof = {'format': PROOF_FORMAT, 'profile': profile(config, base), 'acceptedAt': base.now().isoformat(),
                 'restoreReportSha256': base.digest(report_file), 'credentialReviewSha256': review_sha,
                 'configurationFileSha256': review['configurationFileSha256'], 'expiresAt': review['expiresAt'],
                 'pairedRecoveryInputBindingSha256': report['pairedRecoveryInputBindingSha256'],
                 'legacyExportsDrained': True, **{key: receipt[key] for key in PROOF_BINDINGS}}
        base.atomic_json(root / '.latest-commissioning.json', proof)
        return {'state': 'LATEST_PROFILE_COMMISSIONED', 'snapshotId': snapshot_id,
                'restoreReportSha256': proof['restoreReportSha256'], 'rotated': False}


def upload_state(config, base, chunks, *, require=False):
    root = base.private_path(config['storage_root'], directory=True)
    path = root / '.snapshot-upload.json'
    if not path.exists():
        if require:
            raise ValueError('An active bounded snapshot upload lease is required')
        return None
    value = base.read_json(base.private_path(path), maximum=base.HEADER_LIMIT)
    keys = {'format', 'leaseId', 'issuedAt', 'expiresAt', 'opaqueIds',
            'bootId', 'issuedUptime', 'expiresUptime', *BINDINGS}
    if (not isinstance(value, dict) or set(value) != keys or value['format'] != LEASE_FORMAT
            or not re.fullmatch(r'[a-f0-9]{32}', value['leaseId'])):
        raise ValueError('Invalid upload lease blocks mutation and cleanup')
    validate_binding(value, config, base, chunks)
    started, expires = base.instant(value['issuedAt']), base.instant(value['expiresAt'])
    if expires - started != timedelta(seconds=LEASE_SECONDS) or started > base.now() + timedelta(seconds=5):
        raise ValueError('Invalid server-owned upload lease duration')
    boot, uptime = server_clock()
    if (not isinstance(value['bootId'], str) or not re.fullmatch(r'[a-f0-9-]{36}', value['bootId'])
            or type(value['issuedUptime']) not in {int, float} or type(value['expiresUptime']) not in {int, float}
            or not 0 <= value['issuedUptime'] < value['expiresUptime']
            or abs(value['expiresUptime'] - value['issuedUptime'] - LEASE_SECONDS) > .001):
        raise ValueError('Invalid bounded upload monotonic identity')
    if expires <= base.now() or value['bootId'] != boot or uptime >= value['expiresUptime']:
        if require:
            raise ValueError('Snapshot upload lease expired')
        return None
    if uptime < value['issuedUptime']:
        raise ValueError('Upload monotonic clock moved backwards')
    return value


def server_clock():
    # CLOCK_BOOTTIME includes suspend and is common across processes. Boot ID
    # makes a restart invalidate leases instead of reusing an old uptime epoch.
    boot = Path('/proc/sys/kernel/random/boot_id').read_text(encoding='ascii').strip()
    if not re.fullmatch(r'[a-f0-9-]{36}', boot):
        raise ValueError('Server boot identity is unavailable')
    return boot, time.clock_gettime(time.CLOCK_BOOTTIME)


def validate_binding(value, config, base, chunks):
    ids = value.get('opaqueIds')
    if (not isinstance(ids, list) or not 1 <= len(ids) <= chunks.MAX_REFERENCES
            or any(not isinstance(name, str) or not chunks.OPAQUE.fullmatch(name) for name in ids)
            or ids != sorted(set(ids)) or not isinstance(value.get('snapshotId'), str)
            or not chunks.SNAPSHOT.fullmatch(value['snapshotId'])
            or not isinstance(value.get('nonce'), str) or not re.fullmatch(r'[a-f0-9]{32}', value['nonce'])
            or not isinstance(value.get('sourceSetId'), str) or not base.SET.fullmatch(value['sourceSetId'])
            or not isinstance(value.get('sourceManifestSha256'), str)
            or not base.HASH.fullmatch(value['sourceManifestSha256'])
            or not isinstance(value.get('configurationVersion'), str) or not base.HASH.fullmatch(value['configurationVersion'])
            or value.get('recipientFingerprint') != config['recipient_fingerprint']):
        raise ValueError('Invalid bounded upload plan')
    from datetime import datetime, timezone
    named = datetime.strptime(value['sourceSetId'].split('-')[0], '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
    timestamp = base.instant(value['sourceSnapshotAt'])
    if abs((timestamp - named).total_seconds()) >= 1 or timestamp > base.now() + timedelta(minutes=5):
        raise ValueError('Upload source identity and time differ')


def begin(header, config, base, chunks):
    if set(header) != {'format', 'operation', 'opaqueIds', *BINDINGS}:
        raise ValueError('Invalid snapshot lease request')
    validate_binding(header, config, base, chunks)
    root, _, _ = chunks.directories(config, base)
    cleanup_stages(root, base)
    current = upload_state(config, base, chunks)
    if current:
        if any(current[key] != header[key] for key in (*BINDINGS, 'opaqueIds')):
            raise ValueError('Another snapshot upload is active')
        retain_locked(config, base, chunks)
        return current  # Idempotent recovery of the same lease, never extend expiry.
    proof, _ = commissioning(config, base)
    seed_path = root / '.latest-seed.json'
    seed = base.read_json(base.private_path(seed_path), maximum=4096) if seed_path.exists() else None
    ready = bool(proof and proof.get('configurationVersion') == header['configurationVersion'])
    if not ready and seed and (not proof or seed.get('configurationVersion') != proof.get('configurationVersion')):
        raise ValueError('The complete seed requires real restore commissioning before another upload')
    existing = chunks.snapshots(config, base, include_references=False)
    if existing and base.instant(header['sourceSnapshotAt']) < max(base.instant(row[1]['sourceSnapshotAt']) for row in existing):
        raise ValueError('An older source snapshot cannot replace the current recovery root')
    boot, uptime = server_clock()
    value = {'format': LEASE_FORMAT, 'leaseId': uuid.uuid4().hex,
             'bootId': boot, 'issuedUptime': uptime, 'expiresUptime': uptime + LEASE_SECONDS,
             'issuedAt': base.now().isoformat(), **{key: header[key] for key in (*BINDINGS, 'opaqueIds')}}
    value['expiresAt'] = (base.instant(value['issuedAt']) + timedelta(seconds=LEASE_SECONDS)).isoformat()
    base.atomic_json(root / '.snapshot-upload.json', value)
    try:
        # The fixed proposed closure already has its lease when GC runs, so old
        # unreferenced ciphertext can be reused without a probe/GC race.
        retain_locked(config, base, chunks)
    except BaseException:
        (root / '.snapshot-upload.json').unlink(missing_ok=True)
        base.sync_directory(root)
        raise
    return value


def require_upload(header, config, base, chunks):
    value = upload_state(config, base, chunks, require=True)
    if header.get('uploadLease') != value['leaseId']:
        raise ValueError('Snapshot upload lease identity differs')
    operation = header['operation']
    if operation == 'probeChunks':
        if header.get('opaqueIds') != value['opaqueIds']:
            raise ValueError('Probe differs from the leased fixed closure')
    elif operation == 'putChunk':
        if header.get('opaqueId') not in value['opaqueIds']:
            raise ValueError('Object is outside the leased closure')
    elif operation == 'commitSnapshot':
        receipt = header.get('snapshotReceipt', {})
        if (any(receipt.get(key) != value[key] for key in BINDINGS)
                or [row.get('opaqueId') for row in header.get('references', [])] != value['opaqueIds']):
            raise ValueError('Committed point differs from its fixed upload lease')
    return value


@contextmanager
def bounded_upload(value, base):
    """A blocked stdin cannot outlive the nonrenewable server lease."""
    remaining = min((base.instant(value['expiresAt']) - base.now()).total_seconds(),
                    value['expiresUptime'] - server_clock()[1])
    if remaining <= 0:
        raise ValueError('Snapshot upload lease expired')
    old_handler = signal.getsignal(signal.SIGALRM)
    old_timer = signal.getitimer(signal.ITIMER_REAL)
    started = base.time.monotonic()
    def expired(*_):
        raise base.TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
    try:
        signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, min(remaining, old_timer[0]) if old_timer[0] else remaining)
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old_handler)
        if old_timer[0]:
            signal.setitimer(signal.ITIMER_REAL, max(.000001, old_timer[0] - (base.time.monotonic() - started)), old_timer[1])


def create_stage(parent, base):
    """Only the common mutex owner creates/writes/collects receiver stages."""
    stage = parent / ('.incoming-' + uuid.uuid4().hex)
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT, signal.SIGALRM})
    try:
        stage.mkdir(mode=0o700)
        info = stage.lstat()
        base.atomic_json(stage / '.upload-stage.json', {'format': STAGE_FORMAT, 'device': info.st_dev,
            'inode': info.st_ino, 'createdAt': base.now().isoformat()})
        base.sync_directory(parent)
    except BaseException as original_error:
        # If publication failed, only the directory inode allocated by this call
        # may be removed; an unknown replacement is never recursively deleted.
        try:
            if stage.exists() and 'info' in locals() and (stage.lstat().st_dev, stage.lstat().st_ino) == (info.st_dev, info.st_ino):
                for path in stage.iterdir():
                    if not (path.name == '.upload-stage.json' or re.fullmatch(r'\.\.upload-stage\.json\.[a-f0-9]{32}\.tmp', path.name)):
                        raise ValueError('Unrecognized creation stage requires operator review')
                    base.private_path(path).unlink()
                stage.rmdir()
        except (OSError, ValueError):
            original_error.cleanup_required = True
            original_error.add_note('Receiver creation cleanup requires identity review')
        raise
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    return stage


def checked_stage(stage, base):
    base.private_path(stage, directory=True)
    marker = base.read_json(base.private_path(stage / '.upload-stage.json'), maximum=4096)
    info = stage.lstat()
    if (set(marker) != {'format', 'device', 'inode', 'createdAt'} or marker['format'] != STAGE_FORMAT
            or (marker['device'], marker['inode']) != (info.st_dev, info.st_ino)):
        raise ValueError('Receiver stage identity requires operator review')
    allowed = {'.upload-stage.json', 'cipher.gpg', 'receipt.json', 'source-signature.sshsig',
               'manifest.gpg', 'references.json', 'source-receipt.json', 'target-receipt.json'}
    for path in stage.iterdir():
        if path.name not in allowed and not re.fullmatch(r'\.(?:receipt|references|source-receipt|target-receipt)\.json\.[a-f0-9]{32}\.tmp', path.name):
            raise ValueError('Unknown receiver stage contents require operator review')
        base.private_path(path)


def discard_stage(stage, base):
    checked_stage(stage, base)
    shutil.rmtree(stage)
    base.sync_directory(stage.parent)


def cleanup_stages(root, base):
    stages = []
    for parent in (root / 'objects', root / 'snapshots'):
        if not parent.exists():
            continue
        for path in parent.iterdir():
            if path.name.startswith('.incoming-'):
                if len(stages) >= 4 or not re.fullmatch(r'\.incoming-[a-f0-9]{32}', path.name):
                    raise ValueError('Receiver staging bound requires operator review')
                checked_stage(path, base)
                stages.append(path)
    # Entire staging set is proven before the first deletion. The receiver lock
    # proves no old receiver writer is still using any of these private stages.
    for path in stages:
        shutil.rmtree(path)
        base.sync_directory(path.parent)


def full_export_leases(root, base):
    directory = root / '.archive-leases'
    if not directory.exists():
        return [], []
    base.private_path(directory, directory=True)
    active, stale = [], []
    for count, path in enumerate(directory.iterdir(), 1):
        if count > 256 or not re.fullmatch(r'[a-f0-9]{32}\.json', path.name):
            raise ValueError('Archive export lease bound or identity failed')
        marker = base.read_json(base.private_path(path), maximum=4096)
        if (set(marker) != {'format', 'exportId', 'ciphertextSha256'} or marker['format'] != FULL_LEASE_FORMAT
                or not base.EXPORT.fullmatch(marker['exportId']) or not base.HASH.fullmatch(marker['ciphertextSha256'])):
            raise ValueError('Malformed archive export lease blocks cleanup')
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                stale.append(path)
            except BlockingIOError:
                active.append(marker)
        finally:
            os.close(fd)
    return active, stale


def cleanup_retired(root, base):
    """Resume deletion of already detached inputs, never replay a stale delete plan.

    A crash can interrupt rmtree. Moving each obsolete immutable directory into
    an inode-bound private slot first prevents partial deletion from damaging the
    live catalog. A slot without payload never authorizes deleting its old source.
    """
    directory = root / '.latest-retired'
    if not directory.exists():
        return
    base.private_path(directory, directory=True)
    for count, slot in enumerate(directory.iterdir(), 1):
        if count > 4 or not re.fullmatch(r'[a-f0-9]{32}', slot.name):
            raise ValueError('Retired input bound or identity requires review')
        base.private_path(slot, directory=True)
        if not any(slot.iterdir()):
            slot.rmdir()
            base.sync_directory(directory)
            continue
        marker = base.read_json(base.private_path(slot / 'retired.json'), maximum=4096)
        if (set(marker) != {'format', 'kind', 'sourceName', 'device', 'inode'}
                or marker['format'] != 'uten-dr-retired-input-v1'
                or marker['kind'] not in {'archive', 'snapshot', 'object'}):
            raise ValueError('Unknown retired input requires review')
        pattern = {'archive': base.EXPORT, 'snapshot': re.compile(r'snapshot-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}\Z'),
                   'object': re.compile(r'[a-f0-9]{64}\Z')}[marker['kind']]
        if not isinstance(marker['sourceName'], str) or not pattern.fullmatch(marker['sourceName']):
            raise ValueError('Retired source identity is invalid')
        if {path.name for path in slot.iterdir()} - {'retired.json', 'payload'}:
            raise ValueError('Unknown retired slot contents require review')
        payload = slot / 'payload'
        if payload.exists():
            base.private_path(payload, directory=True)
            info = payload.lstat()
            if (info.st_dev, info.st_ino) != (marker['device'], marker['inode']):
                raise ValueError('Retired input inode changed')
            allowed = {'archive': {'archive.gpg', 'source-receipt.json', 'target-receipt.json'},
                       'snapshot': {'manifest.gpg', 'references.json', 'source-receipt.json',
                                    'target-receipt.json', 'source-signature.sshsig', '.upload-stage.json'},
                       'object': {'cipher.gpg', 'receipt.json', '.upload-stage.json'}}[marker['kind']]
            for path in payload.iterdir():
                if path.name not in allowed:
                    raise ValueError('Unknown retired payload contents require review')
                base.private_path(path)
            shutil.rmtree(payload)
            base.sync_directory(slot)
        (slot / 'retired.json').unlink()
        slot.rmdir()
        base.sync_directory(directory)


def retire_delete(path, kind, root, base):
    directory = root / '.latest-retired'
    directory.mkdir(mode=0o700, exist_ok=True)
    base.private_path(directory, directory=True)
    if any(directory.iterdir()):
        raise ValueError('Prior retired input cleanup must complete before another detach')
    slot = directory / uuid.uuid4().hex
    slot.mkdir(mode=0o700)
    info = base.private_path(path, directory=True).lstat()
    base.atomic_json(slot / 'retired.json', {'format': 'uten-dr-retired-input-v1', 'kind': kind,
        'sourceName': path.name, 'device': info.st_dev, 'inode': info.st_ino})
    base.sync_directory(directory)
    os.rename(path, slot / 'payload')
    base.sync_directory(path.parent)
    base.sync_directory(slot)
    cleanup_retired(root, base)


def retain_locked(config, base, chunks):
    root, objects, points = chunks.directories(config, base)
    cleanup_retired(root, base)
    cleanup_stages(root, base)
    archives = base.completed(config)
    rows = chunks.snapshots(config, base, include_references=False)
    proof, activation = commissioning(config, base)
    signed = [row for row in rows if row[1].get('sourceSignatureVerified') is True]
    anchor = max(signed, key=lambda row: (base.instant(row[1]['sourceSnapshotAt']),
                 base.instant(row[1]['receivedAt']), row[0].name)) if signed else None
    active_full, stale_full = full_export_leases(root, base)
    by_archive = {path.name: (path, source) for path, source, _ in archives}
    full_keep = set()
    for marker in active_full:
        row = by_archive.get(marker['exportId'])
        if row is None or row[1]['ciphertextSha256'] != marker['ciphertextSha256']:
            raise ValueError('Active archive lease lost its immutable input')
        if base.digest(row[0] / 'archive.gpg') != marker['ciphertextSha256']:
            raise ValueError('Active archive ciphertext is damaged')
        full_keep.add(row[0])
    rotating = bool(proof and anchor and proof.get('configurationVersion') == anchor[1].get('configurationVersion'))
    if proof and anchor and not rotating:
        activation = 'COMMISSIONING_CONFIGURATION_CHANGED'
    keep = {anchor[0]} if rotating else {row[0] for row in rows}
    if not rotating:
        full_keep.update(row[0] for row in archives)
    lease = upload_state(config, base, chunks)
    protect = []
    if lease:
        for name in lease['opaqueIds']:
            known = chunks.object_record(objects, name, base)
            if known:
                protect.append({key: known[key] for key in ('opaqueId', 'cipherSha256', 'cipherBytes')})
    obsolete = []
    for path, _, _ in archives:
        if path in full_keep:
            continue
        if (path.parent != root or path != path.resolve()
                or {p.name for p in path.iterdir()} != {'archive.gpg', 'source-receipt.json', 'target-receipt.json'}):
            raise ValueError('Unexpected archive contents block single-root rotation')
        obsolete.append(path)
    # Shared immutable closure preflight covers the retained root, every active
    # export and every already present object promised to an active upload.
    plan = chunks.retention_plan_locked(config, base, keep_override=keep,
        protected_rows=protect, orphan_grace_seconds=ORPHAN_GRACE_SECONDS, verify=True)
    for path in obsolete:
        retire_delete(path, 'archive', root, base)
    for path in plan['snapshots']:
        retire_delete(path, 'snapshot', root, base)
    for path in plan['objects']:
        retire_delete(path, 'object', root, base)
    for path in plan['staleLeases']:
        path.unlink()
    base.sync_directory(points)
    base.sync_directory(objects)
    result = {'deletedSnapshots': len(plan['snapshots']), 'deletedUnreferencedChunks': len(plan['objects'])}
    for path in stale_full:
        path.unlink()
    if not lease:
        (root / '.snapshot-upload.json').unlink(missing_ok=True)
    base.sync_directory(root)
    result.update({'mode': MODE, 'activationState': activation if anchor else 'AWAITING_COMPLETE_SNAPSHOT',
        'deletedSets': len(obsolete), 'cleanupState': 'COMPLETE' if rotating else 'BLOCKED_COMMISSIONING',
        'anchorSnapshotId': anchor[0].name if anchor else None})
    base.atomic_json(root / '.latest-cleanup.json', {**result, 'observedAt': base.now().isoformat()})
    return result


def after_publish(config, base, chunks, result):
    root = Path(config['storage_root'])
    # Commissioning permits one controlled seed only. A failed/partial upload
    # never creates this marker and can be retried after its bounded lease.
    current_proof = commissioning(config, base)[0]
    if not current_proof or current_proof.get('configurationVersion') != result.get('configurationVersion'):
        base.atomic_json(root / '.latest-seed.json', {'snapshotId': result['snapshotId'],
            'sourceManifestSha256': result['sourceManifestSha256'], 'configurationVersion': result['configurationVersion']})
    (root / '.snapshot-upload.json').unlink(missing_ok=True)
    base.sync_directory(root)
    try:
        cleanup = retain_locked(config, base, chunks)
        result['cleanupState'] = cleanup['cleanupState']
    except Exception as error:
        # Publication has succeeded; report a distinct cleanup failure instead
        # of pretending the new recovery point or the one-root invariant failed
        # at the same stage. The next begin must repair cleanup before allocating.
        failure = {'mode': MODE, 'cleanupState': 'FAILED', 'observedAt': base.now().isoformat(),
                   'errorCode': base.failure_record(error)['errorCode']}
        base.atomic_json(root / '.latest-cleanup.json', failure)
        result.update(cleanupState='FAILED', cleanupErrorCode=failure['errorCode'])
    return result


def status(config, base, chunks):
    proof, activation = commissioning(config, base)
    root = Path(config['storage_root'])
    lease = upload_state(config, base, chunks)
    active_full, _ = full_export_leases(root, base)
    active_snapshots, _ = chunks.bundle_lease_state(root, base)
    cleanup = base.read_json(base.private_path(root / '.latest-cleanup.json'), maximum=16384) if (root / '.latest-cleanup.json').exists() else {}
    activation = cleanup.get('activationState', activation) if activation == 'ACTIVE' else activation
    referenced = set()
    for _, _, refs in chunks.iter_snapshots(config, base):
        for row in refs:
            referenced.add(row['opaqueId'])
            if len(referenced) > chunks.MAX_CATALOG_UNIQUE_CHUNKS:
                raise base.TransferFailure('CATALOG_RESOURCE_LIMIT')
    orphan_bytes = orphan_count = object_count = 0
    objects = root / 'objects'
    if objects.exists():
        for directory in objects.iterdir():
            if directory.name.startswith('.incoming-'):
                continue
            object_count += 1
            if object_count > chunks.MAX_CATALOG_UNIQUE_CHUNKS:
                raise base.TransferFailure('CATALOG_RESOURCE_LIMIT')
            row = chunks.object_record(objects, directory.name, base)
            if directory.name not in referenced:
                orphan_count += 1
                orphan_bytes += row['cipherBytes']
    return {'retentionMode': MODE, 'latestRotationActivationState': activation,
            'latestRotationCommissioned': bool(proof) and activation == 'ACTIVE', 'latestRotationCleanupState': cleanup.get('cleanupState', 'NOT_RUN'),
            'latestRotationProtectedExportCount': len(active_full) + len(active_snapshots),
            'latestRotationActiveUploadExpiresAt': lease['expiresAt'] if lease else None,
            'latestRotationOrphanGraceSeconds': ORPHAN_GRACE_SECONDS,
            'latestRotationUploadLeaseSeconds': LEASE_SECONDS,
            'latestRotationUnreferencedObjectCount': orphan_count, 'latestRotationUnreferencedCipherBytes': orphan_bytes}


def archive_bundle(config, base, chunks, export_id, outgoing):
    """Local management export with a live FD lease; never a source RPC."""
    if os.geteuid() != 0 or not isinstance(export_id, str) or not base.EXPORT.fullmatch(export_id):
        raise ValueError('Root registered archive identity is required')
    root = base.private_path(config['storage_root'], directory=True)
    lease = None
    descriptor = None
    budget = config.get('bundle_budget_seconds', 600)
    if type(budget) is not int or not 30 <= budget <= 3600:
        raise ValueError('Invalid bounded archive bundle budget')
    deadline = base.time.monotonic() + budget
    try:
        with base.lock(root / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
            row = next((row for row in base.completed(config) if row[0].name == export_id), None)
            if row is None or base.digest(row[0] / 'archive.gpg') != row[1]['ciphertextSha256']:
                raise ValueError('Registered archive ciphertext failed verification')
            lease_root = root / '.archive-leases'
            lease_root.mkdir(mode=0o700, exist_ok=True)
            base.private_path(lease_root, directory=True)
            # Enforce the existing lease bound before creating another marker.
            active, stale = full_export_leases(root, base)
            if len(active) >= 256:
                raise ValueError('Too many active archive exports')
            for path in stale:
                path.unlink()
            lease = lease_root / (uuid.uuid4().hex + '.json')
            base.atomic_json(lease, {'format': FULL_LEASE_FORMAT, 'exportId': export_id,
                                     'ciphertextSha256': row[1]['ciphertextSha256']})
            descriptor = os.open(lease, os.O_RDWR | os.O_NOFOLLOW)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with chunks.bounded_bundle_output(outgoing, deadline, base) as writer, tarfile.open(fileobj=writer, mode='w|') as archive:
            for name in ('archive.gpg', 'source-receipt.json', 'target-receipt.json'):
                path = base.private_path(row[0] / name)
                with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
                    member = tarfile.TarInfo(name)
                    member.size = os.fstat(stream.fileno()).st_size
                    member.mode = 0o600
                    archive.addfile(member, stream)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if lease is not None:
            try:
                with base.lock(root / '.receiver.lock'):
                    lease.unlink(missing_ok=True)
            except base.TransferBusy:
                pass
