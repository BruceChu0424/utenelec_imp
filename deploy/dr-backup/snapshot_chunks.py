"""Five-minute consistent paired snapshots with opaque, encrypted deduplicated chunks.

This is discrete snapshot protection, not arbitrary-time physical PITR. Chunk
identities are HMACs under a new backup-only source secret. Plaintext hashes and
file paths are present only inside the recipient-encrypted manifest.
"""
from __future__ import annotations

import base64
import fcntl
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import heapq
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import signal
import shutil
import stat
import subprocess
import sys
import tarfile
import uuid

FORMAT = "uten-dr-chunked-snapshot-v1"
SNAPSHOT = re.compile(r"snapshot-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}\Z")
OPAQUE = re.compile(r"[a-f0-9]{64}\Z")
CHUNK_BYTES = 512 * 1024
MAX_REFERENCES = 8192
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_CIPHER_BYTES = CHUNK_BYTES + 64 * 1024
MAX_SNAPSHOT_PLAIN_BYTES = 2 * 1024**3
MAX_ARCHIVE_CIPHER_BYTES = 3 * 1024**3
# Every short file may add a chunk, so include the existing 8192-object closure
# overhead, not merely ceil(total plaintext / chunk size).
MAX_BUNDLE_BYTES = MAX_SNAPSHOT_PLAIN_BYTES + MAX_REFERENCES * 64 * 1024 + 2 * MAX_MANIFEST_BYTES + 16 * 1024**2
DEFAULT_SPOOL_RESERVE_BYTES = 1024**3
SPOOL_LEASE_FORMAT = 'uten-dr-snapshot-spool-v1'
BUNDLE_LEASE_FORMAT = 'uten-dr-bundle-lease-v1'
CATALOG_WINDOW = 100
MAX_CATALOG_POINTS = 10000
MAX_CATALOG_UNIQUE_CHUNKS = 100000
SIGNING_NAMESPACE = "uten-dr-snapshot-v1"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def identity(secret, raw):
    if len(secret) != 32:
        raise ValueError("Backup identity secret must contain 32 random bytes")
    return hmac.new(secret, b"uten-dr-chunk-v1\0" + raw, hashlib.sha256).hexdigest()


def recovery_configuration_identity(files, secret):
    rows = [{'path': row['path'], 'sha256': row['sha256']} for row in files if row['path'].startswith('recovery/')]
    if not rows or len(secret) != 32:
        raise ValueError('Recovery configuration inventory is required')
    return hmac.new(secret, b'uten-dr-configuration-v1\0' + canonical(sorted(rows, key=lambda row: row['path'])), hashlib.sha256).hexdigest()


def sign_receipt(receipt, signing_key, base):
    result = subprocess.run(["/usr/bin/ssh-keygen", "-Y", "sign", "-n", SIGNING_NAMESPACE,
                             "-f", str(base.private_path(signing_key))], input=canonical(receipt),
        capture_output=True, timeout=15, env={"PATH": "/usr/bin:/bin", "LANG": "C"})
    if result.returncode or not result.stdout.startswith(b"-----BEGIN SSH SIGNATURE-----"):
        raise ValueError("Source snapshot signature failed")
    return result.stdout.decode("ascii")


def verify_source_signature(receipt, signature_file, allowed_signers_file, base):
    result = subprocess.run(["/usr/bin/ssh-keygen", "-Y", "verify", "-f", str(base.private_path(allowed_signers_file)),
        "-I", "uten-backup-source", "-n", SIGNING_NAMESPACE, "-s", str(signature_file)],
        input=canonical(receipt), capture_output=True, timeout=15,
        env={"PATH": "/usr/bin:/bin", "LANG": "C"})
    if result.returncode:
        raise ValueError("Independent source signature validation failed")


def directories(config, base):
    root = base.private_path(config["storage_root"], directory=True)
    for name in ("objects", "snapshots"):
        path = root / name
        if not path.exists():
            path.mkdir(mode=0o700)
            base.sync_directory(root)
        base.private_path(path, directory=True)
    return root, root / "objects", root / "snapshots"


def object_record(objects, name, base, verify=False):
    if not OPAQUE.fullmatch(name):
        raise ValueError("Invalid opaque chunk identity")
    directory = objects / name
    if not directory.exists():
        return None
    base.private_path(directory, directory=True)
    value = base.read_json(base.private_path(directory / "receipt.json"))
    path = base.private_path(directory / "cipher.gpg")
    if (set(value) != {"format", "opaqueId", "cipherSha256", "cipherBytes", "receivedAt"}
            or value["format"] != FORMAT or value["opaqueId"] != name
            or not base.HASH.fullmatch(value["cipherSha256"])
            or type(value["cipherBytes"]) is not int or not 100 <= value["cipherBytes"] <= MAX_CIPHER_BYTES
            or path.stat().st_size != value["cipherBytes"]
            or verify and base.digest(path) != value["cipherSha256"]):
        raise ValueError("Committed chunk evidence is damaged")
    return value


def reference_list(value, base):
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_REFERENCES:
        raise ValueError("Snapshot chunk closure is out of bounds")
    observed = set()
    for row in value:
        if (not isinstance(row, dict) or set(row) != {"opaqueId", "cipherSha256", "cipherBytes"}
                or not OPAQUE.fullmatch(row["opaqueId"]) or row["opaqueId"] in observed
                or not base.HASH.fullmatch(row["cipherSha256"])
                or type(row["cipherBytes"]) is not int or not 100 <= row["cipherBytes"] <= MAX_CIPHER_BYTES):
            raise ValueError("Invalid snapshot chunk closure row")
        observed.add(row["opaqueId"])
    if [row["opaqueId"] for row in value] != sorted(observed):
        raise ValueError("Snapshot chunk closure is not canonical")
    return value


def snapshot_record(directory, config, base, verify=False):
    base.private_path(directory, directory=True)
    receipt = base.read_json(base.private_path(directory / "target-receipt.json"))
    refs = reference_list(base.read_json(base.private_path(directory / "references.json"), 2 * 1024**2), base)
    cipher = base.private_path(directory / "manifest.gpg")
    if (receipt.get("format") != FORMAT or receipt.get("state") != "SNAPSHOT_CIPHERTEXT_COMPLETE"
            or receipt.get("snapshotId") != directory.name or not SNAPSHOT.fullmatch(directory.name)
            or receipt.get("referenceListSha256") != hashlib.sha256(canonical(refs)).hexdigest()
            or cipher.stat().st_size != receipt.get("manifestCipherBytes")
            or verify and base.digest(cipher) != receipt.get("manifestCipherSha256")):
        raise ValueError("Snapshot completion evidence is damaged")
    if receipt.get("sourceSignatureVerified") is True:
        source = base.read_json(base.private_path(directory / "source-receipt.json"))
        signature = base.private_path(directory / "source-signature.sshsig")
        if any(receipt.get(key) != value for key, value in source.items()):
            raise ValueError("Published source signature binding differs")
        if verify:
            verify_source_signature(source, signature, config["allowed_signers_file"], base)
    return receipt, refs


def iter_snapshots(config, base):
    _, objects, points = directories(config, base)
    count = 0
    for directory in points.iterdir():
        if directory.name.startswith(".incoming-"):
            continue
        if not SNAPSHOT.fullmatch(directory.name):
            raise ValueError("Unknown snapshot entry blocks retention")
        count += 1
        if count > MAX_CATALOG_POINTS:
            raise base.TransferFailure('CATALOG_RESOURCE_LIMIT')
        receipt, refs = snapshot_record(directory, config, base)
        yield directory, receipt, refs


def snapshots(config, base, *, include_references=True):
    result = [(directory, receipt, refs if include_references else None)
              for directory, receipt, refs in iter_snapshots(config, base)]
    return sorted(result, key=lambda row: base.instant(row[1]["receivedAt"]))


def status(config, base):
    # Validate each point's references, then release that list. Publishing one
    # metadata row must not retain every historical chunk reference in RAM.
    window, count = [], 0
    for directory, receipt, _ in iter_snapshots(config, base):
        count += 1
        row = (base.instant(receipt['receivedAt']), directory.name, receipt)
        if len(window) < CATALOG_WINDOW:
            heapq.heappush(window, row)
        elif row[:2] > window[0][:2]:
            heapq.heapreplace(window, row)
    rows = sorted(window, key=lambda row: row[:2])
    latest = rows[-1][2] if rows else None
    age = max(0, (base.now() - base.instant(latest["sourceSnapshotAt"])).total_seconds()) if latest else None
    return {"snapshotFormat": FORMAT, "completedSnapshots": count, "latestSnapshot": latest,
        'snapshotCatalogReturnedPoints': len(rows), 'snapshotCatalogTruncated': count > len(rows),
        "latestCompleteSnapshotAgeSeconds": round(age, 3) if age is not None else None,
        "snapshotRpo15MinutesFresh": age is not None and age <= 900,
        "snapshotIntervalSeconds": 300, "continuousWalProtected": False,
        "arbitraryPitrOriginalHistoryProtected": False,
        "snapshotRecoveryPoints": [{"id": row[2]["sourceSetId"], "snapshotId": row[2]["snapshotId"],
            "storageTargetId": "cloud-archive", "recoverableUntil": row[2]["sourceSnapshotAt"],
            "manifestSha256": row[2]["sourceManifestSha256"], "cipherSha256": row[2]["manifestCipherSha256"],
            "complete": True, "cipherVerified": True, "keysCovered": False, "verified": False,
            "reasonCode": ("SIGNED_CHUNK_CLOSURE_VERIFIED_RESTORE_PENDING" if row[2].get("sourceSignatureVerified")
                           else "UNSIGNED_SNAPSHOT_REQUIRES_INDEPENDENT_PIN")} for row in rows]}


def copy_cipher(incoming, path, size, expected, maximum, base):
    if type(size) is not int or not 100 <= size <= maximum or not base.HASH.fullmatch(expected):
        raise ValueError("Ciphertext size or digest is invalid")
    digest = hashlib.sha256()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        remaining = size
        while remaining:
            data = incoming.read(min(base.CHUNK, remaining))
            if not data:
                raise ValueError("Ciphertext transfer was interrupted")
            stream.write(data); digest.update(data); remaining -= len(data)
        if incoming.read(1) or digest.hexdigest() != expected:
            raise ValueError("Ciphertext transfer binding failed")
        stream.flush(); os.fsync(stream.fileno())


def capacity(config, additional, base):
    root = Path(config["storage_root"])
    if (shutil.disk_usage(root).free - additional < config["min_free_bytes"]
            or base.storage_bytes(root) + additional > config["max_storage_bytes"]):
        raise OSError("Independent receiver capacity budget exceeded")


def receive(header, incoming, outgoing, config, base):
    latest = base.latest_module() if base.latest_enabled(config) else None
    root, _, _ = directories(config, base)
    if latest is None:
        if header.get('operation') == 'probeChunks':
            return _receive(header, incoming, outgoing, config, base)
        with base.lock(root / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
            return _receive(header, incoming, outgoing, config, base)
    with base.lock(root / '.receiver.lock', timeout=base.RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
        if header.get('operation') == 'beginSnapshotUpload':
            result = latest.begin(header, config, base, sys.modules[__name__])
            outgoing.write(canonical(result) + b'\n')
            return
        latest.cleanup_stages(root, base)
        lease = latest.require_upload(header, config, base, sys.modules[__name__])
        clean_header = {key: value for key, value in header.items() if key != 'uploadLease'}
        with latest.bounded_upload(lease, base):
            return _receive(clean_header, incoming, outgoing, config, base, latest=latest)


def _receive(header, incoming, outgoing, config, base, *, latest=None):
    root, objects, points = directories(config, base)
    operation = header.get("operation")
    if operation == "probeChunks":
        if (set(header) != {"format", "operation", "opaqueIds"} or not isinstance(header["opaqueIds"], list)
                or len(header["opaqueIds"]) > MAX_REFERENCES or len(set(header["opaqueIds"])) != len(header["opaqueIds"])):
            raise ValueError("Invalid chunk probe")
        existing = [value for name in header["opaqueIds"] if (value := object_record(objects, name, base))]
        outgoing.write(canonical({"format": FORMAT, "objects": existing}) + b"\n")
        return
    if operation == "putChunk":
        if set(header) != {"format", "operation", "opaqueId", "cipherSha256", "cipherBytes"}:
            raise ValueError("Invalid chunk upload header")
        name = header["opaqueId"]
        if not OPAQUE.fullmatch(name):
            raise ValueError("Invalid opaque chunk identity")
        old = object_record(objects, name, base)
        if old and (old["cipherSha256"] != header["cipherSha256"] or old["cipherBytes"] != header["cipherBytes"]):
            raise ValueError("Existing chunk cannot be overwritten")
        capacity(config, header["cipherBytes"] + (16384 if latest else 0), base)
        stage = latest.create_stage(objects, base) if latest else objects / (".incoming-" + uuid.uuid4().hex)
        if not latest:stage.mkdir(mode=0o700)
        try:
            copy_cipher(incoming, stage / "cipher.gpg", header["cipherBytes"], header["cipherSha256"], MAX_CIPHER_BYTES, base)
            result = old or {"format": FORMAT, "opaqueId": name, "cipherSha256": header["cipherSha256"],
                             "cipherBytes": header["cipherBytes"], "receivedAt": base.now().isoformat()}
            if old:
                shutil.rmtree(stage)
            else:
                base.atomic_json(stage / "receipt.json", result); base.sync_directory(stage)
                os.rename(stage, objects / name); base.sync_directory(objects)
            outgoing.write(canonical(result) + b"\n")
            return
        except BaseException as error:
            if stage.exists():
                try:
                    latest.discard_stage(stage, base) if latest else shutil.rmtree(stage)
                except (OSError, ValueError):
                    error.cleanup_required = True
                    error.add_note('Receiver cleanup requires identity review')
            raise
    if operation != "commitSnapshot" or set(header) != {"format", "operation", "snapshotReceipt", "references", "sourceSignature"}:
        raise ValueError("Unsupported chunk protocol operation")
    receipt = header["snapshotReceipt"]
    expected = {"format", "snapshotId", "nonce", "sourceSetId", "sourceSnapshotAt", "sourceManifestSha256",
                "recipientFingerprint", "manifestCipherSha256", "manifestCipherBytes", "referenceListSha256",
                "marketStateIncluded", "clientReleaseStateIncluded"}
    if latest:
        expected.add('configurationVersion')
    refs = reference_list(header["references"], base)
    if (not isinstance(receipt, dict) or set(receipt) != expected or receipt["format"] != FORMAT
            or not SNAPSHOT.fullmatch(receipt["snapshotId"]) or not base.SET.fullmatch(receipt["sourceSetId"])
            or not re.fullmatch(r"[a-f0-9]{32}", receipt["nonce"])
            or receipt["recipientFingerprint"] != config["recipient_fingerprint"]
            or not base.HASH.fullmatch(receipt["sourceManifestSha256"])
            or receipt["referenceListSha256"] != hashlib.sha256(canonical(refs)).hexdigest()
            or type(receipt["marketStateIncluded"]) is not bool
            or type(receipt["clientReleaseStateIncluded"]) is not bool
            or base.instant(receipt["sourceSnapshotAt"]) > base.now() + timedelta(minutes=5)):
        raise ValueError("Snapshot manifest binding failed")
    named = datetime.strptime(receipt["sourceSetId"].split("-")[0], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    if abs((base.instant(receipt["sourceSnapshotAt"]) - named).total_seconds()) >= 1:
        raise ValueError("Snapshot time differs from its source identity")
    if (points / receipt["snapshotId"]).exists():
        raise ValueError("A published snapshot cannot be overwritten")
    for row in refs:
        known = object_record(objects, row["opaqueId"], base, verify=True)
        if known is None or any(known[key] != row[key] for key in ("cipherSha256", "cipherBytes")):
            raise ValueError("Snapshot dependencies are incomplete")
    capacity(config, receipt["manifestCipherBytes"] + len(canonical(refs)) + 32768, base)
    stage = latest.create_stage(points, base) if latest else points / (".incoming-" + uuid.uuid4().hex)
    if not latest:stage.mkdir(mode=0o700)
    try:
        signature = header["sourceSignature"]
        if (not isinstance(signature, str) or len(signature) > 8192
                or not signature.startswith("-----BEGIN SSH SIGNATURE-----")):
            raise ValueError("Invalid source snapshot signature")
        signature_path = stage / "source-signature.sshsig"
        fd = os.open(signature_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            stream.write(signature);stream.flush();os.fsync(stream.fileno())
        verify_source_signature(receipt, signature_path, config["allowed_signers_file"], base)
        copy_cipher(incoming, stage / "manifest.gpg", receipt["manifestCipherBytes"],
                    receipt["manifestCipherSha256"], MAX_MANIFEST_BYTES, base)
        result = {**receipt, "state": "SNAPSHOT_CIPHERTEXT_COMPLETE", "targetId": "cloud-archive",
                  "receivedAt": base.now().isoformat(), "chunkCount": len(refs), "restoreVerified": False,
                  "sourceSignatureVerified": True}
        base.atomic_json(stage / "references.json", refs)
        base.atomic_json(stage / "source-receipt.json", receipt)
        base.atomic_json(stage / "target-receipt.json", result)
        base.sync_directory(stage)
        os.rename(stage, points / receipt["snapshotId"]); base.sync_directory(points)
        if latest:
            result = latest.after_publish(config, base, sys.modules[__name__], result)
            base.atomic_json(points / receipt["snapshotId"] / "target-receipt.json", result)
        base.atomic_json(Path(config["status_file"]), base.build_status(config))
        outgoing.write(canonical(result) + b"\n")
    except BaseException as error:
        if stage.exists():
            try:
                latest.discard_stage(stage, base) if latest else shutil.rmtree(stage)
            except (OSError, ValueError):
                error.cleanup_required = True
                error.add_note('Receiver cleanup requires identity review')
        raise


def retention_plan_locked(config, base, *, keep_override=None, protected_rows=(), orphan_grace_seconds=2*86400, verify=False):
    """Prove the complete snapshot/object plan before either format is deleted."""
    _, objects, points = directories(config, base)
    rows = snapshots(config, base, include_references=False)  # Malformed points abort all GC.
    keep = {row[0] for row in rows[-config["minimum_complete_sets"]:]}
    daily = {}
    moment = base.now()
    for directory, receipt, _ in rows:
        timestamp = base.instant(receipt["receivedAt"])
        if timestamp > moment + timedelta(minutes=5):raise ValueError("Receiver clock moved backwards")
        if timestamp >= moment - timedelta(days=config["hourly_retention_days"]):keep.add(directory)
        if timestamp >= moment - timedelta(days=config["daily_retention_days"]):daily[timestamp.date()] = directory
    keep.update(daily.values())
    if keep_override is not None:
        keep = set(keep_override)
    active, stale_leases = bundle_lease_state(objects.parent, base)
    by_name = {path.name: (path, receipt) for path, receipt, _ in rows}
    for marker in active:
        target = by_name.get(marker['snapshotId'])
        if target is None or any(target[1].get(key) != marker[key] for key in
                ('manifestCipherSha256', 'referenceListSha256')):
            raise ValueError('Active bundle lease no longer binds its recovery point')
        keep.add(target[0])
    retained = [row for row in rows if row[0] in keep]
    # Objects are immutable and this entire operation owns the receiver mutex.
    # Validate every reference, but open each shared object once rather than
    # once per snapshot (thousands of snapshots may reference the same chunk).
    # Prove the complete retained closure before removing any recovery point.
    needed = {}
    for directory, _, _ in retained:
        _, refs = snapshot_record(directory, config, base, verify=verify)
        for row in refs:
            if row['opaqueId'] not in needed and len(needed) >= MAX_CATALOG_UNIQUE_CHUNKS:
                raise base.TransferFailure('CATALOG_RESOURCE_LIMIT')
            previous = needed.setdefault(row['opaqueId'], row)
            if previous != row:
                raise ValueError('Retained references disagree about an immutable chunk')
    for row in protected_rows:
        if row['opaqueId'] not in needed and len(needed) >= MAX_CATALOG_UNIQUE_CHUNKS:
            raise base.TransferFailure('CATALOG_RESOURCE_LIMIT')
        if needed.setdefault(row['opaqueId'], row) != row:
            raise ValueError('Upload and retained closure disagree')
    for name, row in needed.items():
        known = object_record(objects, name, base, verify=verify)
        if known is None or any(known[key] != row[key] for key in ('cipherSha256', 'cipherBytes')):
            raise ValueError('Retained dependency closure blocks GC')
    obsolete_points = []
    for directory, receipt, _ in rows:
        if directory in keep:continue
        if directory.parent.name != "snapshots" or directory != directory.resolve():
            raise ValueError("Snapshot retention escaped its root")
        allowed = {"manifest.gpg", "references.json", "target-receipt.json"}
        if receipt.get("sourceSignatureVerified"):
            allowed |= {"source-receipt.json", "source-signature.sshsig"}
        if (directory / '.upload-stage.json').exists():
            base.latest_module().checked_stage(directory, base)
            allowed.add('.upload-stage.json')
        if {p.name for p in directory.iterdir()} != allowed:
            raise ValueError("Unknown snapshot contents block cleanup")
        obsolete_points.append(directory)
    obsolete_objects = []
    for directory in objects.iterdir():
        if directory.name.startswith(".incoming-"):continue
        if not OPAQUE.fullmatch(directory.name):raise ValueError("Unknown chunk entry blocks GC")
        if directory.name in needed:continue
        known = object_record(objects, directory.name, base)
        if base.instant(known["receivedAt"]) >= moment - timedelta(seconds=orphan_grace_seconds):continue
        if directory.parent != objects or directory != directory.resolve():raise ValueError("Chunk GC escaped its root")
        expected_files = {'cipher.gpg', 'receipt.json'}
        if (directory / '.upload-stage.json').exists():
            base.latest_module().checked_stage(directory, base)
            expected_files.add('.upload-stage.json')
        if {p.name for p in directory.iterdir()} != expected_files:raise ValueError("Unknown chunk files block GC")
        obsolete_objects.append(directory)
    return {'pointsRoot': points, 'objectsRoot': objects,
            'snapshots': tuple(obsolete_points), 'objects': tuple(obsolete_objects), 'staleLeases': tuple(stale_leases)}


def apply_retention_plan_locked(plan, base):
    """Only consume a preflight plan while its original receiver mutex is held."""
    for directory in (*plan['snapshots'], *plan['objects']):
        shutil.rmtree(directory)
    for lease in plan.get('staleLeases', ()):
        lease.unlink()
    base.sync_directory(plan['pointsRoot'])
    base.sync_directory(plan['objectsRoot'])
    return {'deletedSnapshots': len(plan['snapshots']), 'deletedUnreferencedChunks': len(plan['objects'])}


def retain_locked(config, base):
    return apply_retention_plan_locked(retention_plan_locked(config, base), base)


def bundle(config, snapshot_id, outgoing, base, *, verification_budget_seconds=None):
    """Root management CLI only: stream exact ciphertext closure, never an RPC capability."""
    if not isinstance(snapshot_id, str) or not SNAPSHOT.fullmatch(snapshot_id):
        raise ValueError("A fixed registered snapshot identity is required")
    root, objects, points = directories(config, base)
    budget = config.get('bundle_budget_seconds', 600) if verification_budget_seconds is None else verification_budget_seconds
    maximum_budget = 3600 if verification_budget_seconds is None else 10800
    if type(budget) is not int or not 30 <= budget <= maximum_budget:
        raise ValueError('Invalid bounded bundle budget')
    deadline = base.time.monotonic() + budget
    lease = None
    lease_fd = None
    try:
        with base.lock(root / ".receiver.lock", timeout=base.RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
            directory = points / snapshot_id
            receipt, refs = snapshot_record(directory, config, base, verify=True)
            if receipt.get("sourceSignatureVerified") is not True:
                raise ValueError("Unsigned legacy snapshot needs an independently pinned recovery procedure")
            files = [(directory/name,name) for name in ("manifest.gpg", "references.json", "target-receipt.json",
                                                       "source-receipt.json", "source-signature.sshsig")]
            for row in refs:
                known = object_record(objects, row["opaqueId"], base, verify=True)
                if known is None or any(known[key] != row[key] for key in ("cipherSha256", "cipherBytes")):
                    raise ValueError("Management bundle dependency closure failed")
                files.append((objects/row["opaqueId"]/"cipher.gpg", "objects/"+row["opaqueId"]+".gpg"))
            total = 0
            for path, name in files:
                base.private_path(path)
                total += path.stat().st_size
            if total > MAX_BUNDLE_BYTES:
                raise ValueError('Ciphertext bundle exceeds its bounded disk/decoder contract')
            lease_root = root / '.bundle-leases'
            lease_root.mkdir(mode=0o700, exist_ok=True)
            base.private_path(lease_root, directory=True)
            lease = lease_root / (uuid.uuid4().hex + '.json')
            base.atomic_json(lease, {'format': BUNDLE_LEASE_FORMAT, 'snapshotId': snapshot_id,
                'manifestCipherSha256': receipt['manifestCipherSha256'],
                'referenceListSha256': receipt['referenceListSha256']})
            lease_fd = os.open(lease, os.O_RDWR | os.O_NOFOLLOW)
            fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # A root-only live lease protects this point and its full closure during
        # GC. Stream one descriptor at a time, independent of the chunk count.
        with bounded_bundle_output(outgoing, deadline, base) as bounded, \
                tarfile.open(fileobj=bounded,mode="w|",format=tarfile.PAX_FORMAT) as archive:
            for path, name in files:
                if base.time.monotonic() >= deadline:
                    raise base.TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
                base.private_path(path)
                with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), 'rb') as stream:
                    member=tarfile.TarInfo(name);member.size=os.fstat(stream.fileno()).st_size;member.mode=0o600
                    archive.addfile(member,stream)
    finally:
        if lease_fd is not None:
            os.close(lease_fd)
        if lease is not None:
            try:
                with base.lock(root / '.receiver.lock'):
                    lease.unlink(missing_ok=True)
            except base.TransferBusy:
                pass  # The next locked GC removes this known inactive lease.


@contextmanager
def bounded_bundle_output(outgoing, deadline, base):
    class Writer:
        def write(self, raw):
            if base.time.monotonic() >= deadline:
                raise base.TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
            if poller is None:
                return outgoing.write(raw)
            pending = memoryview(raw)
            while pending:
                remaining = deadline - base.time.monotonic()
                if remaining <= 0:
                    raise base.TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
                if poller.select(remaining):
                    try:
                        pending = pending[os.write(descriptor, pending):]
                    except BlockingIOError:
                        pass
            return len(raw)
    poller = None
    descriptor = None
    previous = None
    try:
        try:
            descriptor = outgoing.fileno()
        except (AttributeError, OSError):
            descriptor = None
        if descriptor is not None and not stat.S_ISREG(os.fstat(descriptor).st_mode):
            previous = os.get_blocking(descriptor)
            os.set_blocking(descriptor, False)
            poller = selectors.DefaultSelector()
            poller.register(descriptor, selectors.EVENT_WRITE)
        yield Writer()
    finally:
        if poller is not None:
            poller.close()
        if previous is not None:
            os.set_blocking(descriptor, previous)


def bundle_lease_state(root, base):
    directory = root / '.bundle-leases'
    if not directory.exists():
        return [], []
    base.private_path(directory, directory=True)
    active, stale = [], []
    for lease_count, path in enumerate(directory.iterdir(), 1):
        if lease_count > 256:
            raise base.TransferFailure('CATALOG_RESOURCE_LIMIT')
        if not re.fullmatch(r'[a-f0-9]{32}\.json', path.name):
            raise ValueError('Unknown bundle lease requires review')
        marker = base.read_json(base.private_path(path), maximum=4096)
        if (set(marker) != {'format', 'snapshotId', 'manifestCipherSha256', 'referenceListSha256'}
                or marker['format'] != BUNDLE_LEASE_FORMAT or not SNAPSHOT.fullmatch(marker['snapshotId'])
                or not base.HASH.fullmatch(marker['manifestCipherSha256'])
                or not base.HASH.fullmatch(marker['referenceListSha256'])):
            raise ValueError('Malformed bundle lease blocks retention')
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


def rpc(config, header, base, payload=None, maximum=4 * 1024 * 1024, *, deadline=None):
    process = subprocess.Popen(base.ssh_command(config), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env={"PATH": "/usr/bin:/bin", "LANG": "C"})
    try:
        return base.transfer_exchange(process, canonical(header) + b'\n', payload, maximum,
            deadline=deadline if deadline is not None else base.time.monotonic() + base.run_budget(config, 'snapshot')[0])
    finally:
        try:
            if process.poll() is None:process.kill();process.wait(timeout=10)
        finally:
            base.close_transfer_pipes(process)


def encrypt_bytes(raw, destination, public_fd, home, sealed):
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        result = subprocess.run([sealed.GPG, "--no-options", "--batch", "--no-tty", "--no-autostart",
            "--homedir", str(home), "--compress-algo", "zlib", "--cipher-algo", "AES256",
            "--recipient-file", f"/proc/self/fd/{public_fd}", "--output", "-", "--encrypt"],
            input=raw, stdout=stream, stderr=subprocess.DEVNULL, pass_fds=(public_fd,),
            env={"PATH": "/usr/bin:/bin", "LANG": "C"}, timeout=60)
        if result.returncode:raise ValueError("Chunk public-key encryption failed")
        stream.flush();os.fsync(stream.fileno())


def snapshot_limit(config):
    limit = config.get('max_snapshot_plain_bytes', 512 * 1024**2)
    if type(limit) is not int or not 1 <= limit <= MAX_SNAPSHOT_PLAIN_BYTES:
        raise ValueError('Invalid bounded snapshot plaintext limit')
    return limit


def spool_reserve(config):
    reserve = config.get('snapshot_spool_min_free_bytes', DEFAULT_SPOOL_RESERVE_BYTES)
    if type(reserve) is not int or not 0 <= reserve <= 1024**4:
        raise ValueError('Invalid snapshot spool free-space reserve')
    return reserve


def source_spool_root(config, base):
    # The export directory is an existing reviewed backup-volume path. Never
    # fall back to /tmp or StateDirectory on the system partition.
    parent = base.private_path(config['source_export_directory'], directory=True)
    mount = Path(config.get('snapshot_spool_mountpoint', '/srv/uten-backup'))
    if (not mount.is_absolute() or mount == Path('/') or '..' in mount.parts
            or not parent.is_relative_to(mount) or not os.path.ismount(mount)
            or parent.stat().st_dev != mount.stat().st_dev):
        raise base.TransferFailure('SOURCE_SPOOL_UNMOUNTED')
    root = parent / '.snapshot-spool'
    try:
        root.mkdir(mode=0o700)
        base.sync_directory(parent)
    except FileExistsError:
        pass
    return base.private_path(root, directory=True)


def remove_spool(stage, base):
    base.private_path(stage, directory=True)
    marker = base.read_json(base.private_path(stage / 'capture-lease.json'), maximum=4096)
    info = stage.stat()
    if (set(marker) != {'format', 'device', 'inode'} or marker['format'] != SPOOL_LEASE_FORMAT
            or (marker['device'], marker['inode']) != (info.st_dev, info.st_ino)):
        raise ValueError('Unrecognized snapshot spool lease')
    shutil.rmtree(stage)
    base.sync_directory(stage.parent)


def create_source_spool(config, base, *, owner=None):
    root = source_spool_root(config, base)
    # The caller holds the snapshot job mutex. A prior crashed job cannot still
    # own a capture in this fixed private namespace. Unknown leases fail closed.
    for old in root.iterdir():
        if not re.fullmatch(r'\.snapshot-[a-f0-9]{32}', old.name):
            raise ValueError('Unknown snapshot spool entry requires review')
        base.private_path(old, directory=True)
        if not any(old.iterdir()):
            old.rmdir()  # Interrupted before the first private marker was saved.
        else:
            remove_spool(old, base)
    stage = root / ('.snapshot-' + uuid.uuid4().hex)
    root_info = root.stat()
    info = None
    try:
        # Record ownership before delivering a pending cancellation. A signal
        # between mkdir and stat would otherwise leave no safe inode proof.
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
            {signal.SIGTERM, signal.SIGINT, signal.SIGALRM})
        try:
            stage.mkdir(mode=0o700)
            info = stage.lstat()
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        base.atomic_json(stage / 'capture-lease.json', {'format': SPOOL_LEASE_FORMAT,
                         'device': info.st_dev, 'inode': info.st_ino})
        if owner is not None:
            # The caller can recover ownership even if cancellation lands
            # after return but before its local assignment finishes.
            owner['stage'] = stage
            owner['identity'] = (info.st_dev, info.st_ino)
    except BaseException as failure:
        if info is not None:
            try:
                base.private_path(root, directory=True)
                base.private_path(stage, directory=True)
                if not os.path.samestat(root_info, root.stat()) or not os.path.samestat(info, stage.lstat()):
                    raise ValueError('Created capture identity changed')
                # Only creation metadata can exist before this function hands
                # ownership to its caller. Unknown content is never removed.
                for entry in stage.iterdir():
                    if (entry.name != 'capture-lease.json' and not re.fullmatch(
                            r'\.capture-lease\.json\.[a-f0-9]{32}\.tmp', entry.name)):
                        raise ValueError('Unknown content appeared during capture creation')
                    base.private_path(entry)
                    if entry.stat().st_size > 4096:
                        raise ValueError('Capture creation metadata exceeds its budget')
                shutil.rmtree(stage)
                base.sync_directory(root)
            except (OSError, ValueError):
                failure.cleanup_required = True
                failure.add_note('Capture creation cleanup requires identity review; original failure preserved')
        raise
    return stage


def capture_files(entries, stage, secret, sealed, config, base, *, deadline=None):
    """Capture stable source bytes once; payload RAM is bounded by one chunk."""
    limit, reserve = snapshot_limit(config), spool_reserve(config)
    total = sum(path.stat().st_size for path, _ in entries)
    if total > limit:
        raise base.TransferFailure('SOURCE_SNAPSHOT_LIMIT')
    if shutil.disk_usage(stage).free - total - 2 * MAX_MANIFEST_BYTES - MAX_CIPHER_BYTES < reserve:
        raise base.TransferFailure('SOURCE_SPOOL_CAPACITY')
    plain = stage / 'plain'
    plain.mkdir(mode=0o700)
    captured, files, metadata_bytes = {}, [], 0
    for path, name in entries:
        if deadline is not None and base.time.monotonic() >= deadline:
            raise base.TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
        parts, whole, size = [], hashlib.sha256(), 0
        before = sealed.safe_path(path)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as source:
            if not os.path.samestat(before, os.fstat(source.fileno())):
                raise ValueError('Snapshot input identity changed')
            while raw := source.read(CHUNK_BYTES):
                if deadline is not None and base.time.monotonic() >= deadline:
                    raise base.TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
                if size + len(raw) > before.st_size:
                    raise ValueError('Snapshot source grew beyond its fixed capture size')
                opaque, checksum = identity(secret, raw), hashlib.sha256(raw).hexdigest()
                if opaque not in captured:
                    if len(captured) >= MAX_REFERENCES:
                        raise ValueError('Snapshot chunk closure exceeds budget')
                    if shutil.disk_usage(stage).free - len(raw) < reserve:
                        raise base.TransferFailure('SOURCE_SPOOL_CAPACITY')
                    destination = plain / opaque
                    output_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(output_fd, 'wb') as output:
                        output.write(raw)
                        output.flush()
                        os.fsync(output.fileno())
                    captured[opaque] = {'path': destination, 'size': len(raw), 'sha256': checksum}
                elif (captured[opaque]['size'], captured[opaque]['sha256']) != (len(raw), checksum):
                    raise ValueError('Opaque snapshot chunk collision')
                parts.append({'opaqueId': opaque, 'size': len(raw), 'sha256': checksum})
                whole.update(raw)
                size += len(raw)
            after = os.fstat(source.fileno())
        current = path.lstat()
        if (not os.path.samestat(before, current)
                or (before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                   (after.st_size, after.st_mtime_ns, after.st_ctime_ns) or size != before.st_size):
            raise ValueError('Snapshot file changed during capture')
        row = {'path': name, 'size': size, 'sha256': whole.hexdigest(), 'chunks': parts}
        metadata_bytes += len(canonical(row)) + 1
        if metadata_bytes > MAX_MANIFEST_BYTES - 128 * 1024:
            raise ValueError('Snapshot plaintext manifest exceeds decoder budget')
        files.append(row)
    base.sync_directory(plain)
    return captured, files, total


def run_source(config, base):
    latest_mode = base.latest_enabled(config)
    budget, unit = base.run_budget(config, 'snapshot')
    deadline = base.time.monotonic() + budget
    phases = {}
    state = base.private_path(config["state_directory"], directory=True)
    with base.lock(state / ".snapshot-source.lock"):
        status_path = state / "snapshot-status.json"
        previous = base.read_json(status_path) if status_path.exists() else None
        stage = None
        spool_owner = {}
        key_fd = None
        transfer_started = None
        try:
            stage = create_source_spool(config, base, owner=spool_owner)
            with base.timed_phase(phases, 'consistentCapture'), base.lock(state / '.source.lock', timeout=base.SOURCE_CAPTURE_WAIT_SECONDS, busy_code='SOURCE_BUSY'):
                remaining = deadline - base.time.monotonic()
                if remaining <= 0:
                    raise base.TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
                with base.timed_phase(phases, 'pairedSnapshot'):
                    result = subprocess.run(["/usr/bin/python3", "-I", config["paired_helper"], "--config", config["paired_config"]],
                        capture_output=True, timeout=remaining, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"})
                if result.returncode:raise RuntimeError("Consistent paired snapshot failed")
                spec = importlib.util.spec_from_file_location("uten_snapshot_sealed", config["sealed_helper"])
                sealed = importlib.util.module_from_spec(spec);sys.modules[spec.name] = sealed;spec.loader.exec_module(sealed)
                paired = sealed.load_paired(Path(config["paired_helper"]))
                root = Path(base.read_json(config["paired_config"])["backup_root"])
                with base.private_path(config['chunk_identity_file']).open('rb') as key:
                    secret = key.read(33)
                if len(secret) != 32:raise ValueError("Invalid opaque chunk identity secret")
                home = stage / "gnupg";home.mkdir(mode=0o700)
                with base.private_path(config['recipient_file']).open('rb') as key:
                    public = key.read(65537)
                sealed.check_recipient(public, config["recipient_fingerprint"], home)
                key_fd = os.memfd_create("uten-snapshot-recipient", os.MFD_CLOEXEC)
                os.write(key_fd, public);os.lseek(key_fd, 0, os.SEEK_SET)
                with sealed.shared_backup_lock(root):
                    set_id, manifest_digest, entries, summary = sealed.collect_files(root, paired,
                        Path(config["paired_helper"]), Path("/"), config["recovery_files"],
                        include_remote_recovery=config.get('include_remote_recovery',False))
                    with base.timed_phase(phases, 'spoolCapture'):
                        captured, files, total = capture_files(entries, stage, secret, sealed, config, base, deadline=deadline)
                    source_manifest = base.read_json(root / set_id / "manifest.json")
            # All source bytes and identities are privately spooled; release
            # the source mutex before encryption and receiver/GC backpressure.
            configuration_version = recovery_configuration_identity(files, secret) if latest_mode else None
            transfer_started = base.time.monotonic()
            point_id = "snapshot-" + base.now().strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
            nonce = uuid.uuid4().hex
            lease_header = {}
            if latest_mode:
                leased = rpc(config, {'format': base.FORMAT, 'operation': 'beginSnapshotUpload',
                    'snapshotId': point_id, 'nonce': nonce, 'sourceSetId': set_id,
                    'sourceSnapshotAt': source_manifest['started_at'], 'sourceManifestSha256': manifest_digest,
                    'recipientFingerprint': config['recipient_fingerprint'], 'configurationVersion': configuration_version,
                    'opaqueIds': sorted(captured)}, base, deadline=deadline)
                if (leased.get('format') != base.latest_module().LEASE_FORMAT
                        or not isinstance(leased.get('leaseId'), str) or not re.fullmatch(r'[a-f0-9]{32}', leased['leaseId'])):
                    raise ValueError('Invalid upload lease acknowledgment')
                lease_header = {'uploadLease': leased['leaseId']}
            probed = rpc(config, {"format": base.FORMAT, "operation": "probeChunks", "opaqueIds": sorted(captured), **lease_header}, base,
                         deadline=deadline)
            existing = {row["opaqueId"]: row for row in probed["objects"]}
            refs = [];new_bytes = new_count = 0
            for opaque, captured_chunk in sorted(captured.items()):
                known = existing.get(opaque)
                if known is None:
                    with base.private_path(captured_chunk['path']).open('rb') as source:
                        raw = source.read(CHUNK_BYTES + 1)
                    if len(raw) != captured_chunk['size'] or hashlib.sha256(raw).hexdigest() != captured_chunk['sha256']:
                        raise ValueError('Private snapshot capture changed before encryption')
                    cipher = stage / (opaque + ".gpg")
                    encrypt_bytes(raw, cipher, key_fd, home, sealed)
                    del raw
                    header = {"format": base.FORMAT, "operation": "putChunk", "opaqueId": opaque,
                              "cipherSha256": base.digest(cipher), "cipherBytes": cipher.stat().st_size, **lease_header}
                    known = rpc(config, header, base, cipher, deadline=deadline)
                    if any(known.get(key) != header[key] for key in ("opaqueId", "cipherSha256", "cipherBytes")):
                        raise ValueError("Chunk acknowledgment differs")
                    new_count += 1;new_bytes += known["cipherBytes"];cipher.unlink()
                refs.append({key: known[key] for key in ("opaqueId", "cipherSha256", "cipherBytes")})
                captured_chunk['path'].unlink()
            reference_list(refs, base)
            ref_digest = hashlib.sha256(canonical(refs)).hexdigest()
            manifest = {"format": FORMAT, "snapshotId": point_id, "nonce": nonce,
                "sourceSetId": set_id, "sourceSnapshotAt": source_manifest["started_at"],
                "sourceManifestSha256": manifest_digest, "recipientFingerprint": config["recipient_fingerprint"],
                "referenceListSha256": ref_digest, "chunkBytes": CHUNK_BYTES,
                "dedupIdentityKeyRecovery": base64.b64encode(secret).decode(), "files": files,
                "scope": {"database": True, "originals": True, "cryptoRecoveryIncluded": True,
                    "marketStateIncluded": bool(summary.get("market_state")),
                    "clientReleaseStateIncluded": bool(summary.get("client_release_state")),
                    "remoteGatewayRecovery": summary.get('remote_recovery'),
                    "arbitraryPitrOriginalHistoryProtected": False}}
            if latest_mode:
                manifest['configurationVersion'] = configuration_version
            manifest_bytes = canonical(manifest)
            if len(manifest_bytes) > MAX_MANIFEST_BYTES:
                raise ValueError('Snapshot manifest exceeds the existing decoder limit')
            cipher = stage / "manifest.gpg";encrypt_bytes(manifest_bytes, cipher, key_fd, home, sealed)
            receipt = {key: manifest[key] for key in ("format", "snapshotId", "nonce", "sourceSetId", "sourceSnapshotAt",
                "sourceManifestSha256", "recipientFingerprint", "referenceListSha256")}
            receipt.update(manifestCipherSha256=base.digest(cipher), manifestCipherBytes=cipher.stat().st_size,
                marketStateIncluded=bool(summary.get("market_state")), clientReleaseStateIncluded=bool(summary.get("client_release_state")))
            if latest_mode:
                receipt['configurationVersion'] = configuration_version
            signature = sign_receipt(receipt, config["signing_key_file"], base)
            target = rpc(config, {"format": base.FORMAT, "operation": "commitSnapshot", "snapshotReceipt": receipt,
                                   "references": refs, "sourceSignature": signature, **lease_header}, base, cipher, deadline=deadline)
            if target.get("snapshotId") != point_id or target.get("manifestCipherSha256") != receipt["manifestCipherSha256"]:
                raise ValueError("Snapshot commit acknowledgment differs")
            status_value = {"format": FORMAT, "state": "SNAPSHOT_CIPHERTEXT_COMPLETE", "observedAt": base.now().isoformat(),
                "health": "HEALTHY", "latest": target, "newChunks": new_count, "reusedChunks": len(refs)-new_count,
                "newCipherBytes": new_bytes+cipher.stat().st_size, "snapshotPlainBytes": total,
                "snapshotIntervalSeconds": 300, "continuousWalProtected": False,
                "arbitraryPitrOriginalHistoryProtected": False, "restoreVerified": False,
                'budgetSeconds': budget, 'reviewedUnitTimeoutSeconds': unit,
                'phaseSeconds': {**phases, 'encryptAndTransfer': round(max(0, base.time.monotonic() - transfer_started), 3)}}
            if latest_mode:
                status_value['cleanupState'] = target.get('cleanupState')
                if target.get('cleanupState') != 'COMPLETE':
                    status_value.update(health='DEGRADED', state=('SNAPSHOT_COMPLETE_CLEANUP_FAILED'
                        if target.get('cleanupState') == 'FAILED' else 'SNAPSHOT_COMPLETE_COMMISSIONING_PENDING'))
            base.finish_source_export_retention(config, status_value)
            base.atomic_json(status_path, status_value)
            return status_value
        except Exception as error:
            if transfer_started is not None:
                phases['encryptAndTransfer'] = round(max(0, base.time.monotonic() - transfer_started), 3)
            failure = {**base.failure_record(error), "format": FORMAT, "health": "DEGRADED",
                "observedAt": base.now().isoformat(),
                "latest": previous.get("latest") if previous else None,
                "continuousWalProtected": False, "arbitraryPitrOriginalHistoryProtected": False,
                'budgetSeconds': budget, 'reviewedUnitTimeoutSeconds': unit, 'phaseSeconds': phases}
            if isinstance(error, base.TransferBusy) and error.code == 'SOURCE_BUSY':
                failure.update(state='DEFERRED', retryPolicy='NEXT_TIMER')
                base.atomic_json(status_path, failure)
                return failure
            base.atomic_json(status_path, failure)
            raise
        finally:
            if key_fd is not None:os.close(key_fd)
            owned_stage = stage if stage is not None else spool_owner.get('stage')
            if owned_stage is not None and owned_stage.exists():
                original_failure = sys.exception()
                try:
                    current = owned_stage.lstat()
                    if spool_owner.get('identity') != (current.st_dev, current.st_ino):
                        raise ValueError('Capture handoff identity changed before cleanup')
                    remove_spool(owned_stage, base)
                except (OSError, ValueError):
                    if original_failure is None:
                        raise
                    original_failure.cleanup_required = True
                    original_failure.add_note('Capture cleanup requires identity review; original failure preserved')
