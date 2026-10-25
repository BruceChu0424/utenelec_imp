"""Five-minute consistent paired snapshots with opaque, encrypted deduplicated chunks.

This is discrete snapshot protection, not arbitrary-time physical PITR. Chunk
identities are HMACs under a new backup-only source secret. Plaintext hashes and
file paths are present only inside the recipient-encrypted manifest.
"""
from __future__ import annotations

import base64
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
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
SIGNING_NAMESPACE = "uten-dr-snapshot-v1"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def identity(secret, raw):
    if len(secret) != 32:
        raise ValueError("Backup identity secret must contain 32 random bytes")
    return hmac.new(secret, b"uten-dr-chunk-v1\0" + raw, hashlib.sha256).hexdigest()


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


def snapshots(config, base):
    _, objects, points = directories(config, base)
    result = []
    for directory in points.iterdir():
        if directory.name.startswith(".incoming-"):
            continue
        if not SNAPSHOT.fullmatch(directory.name):
            raise ValueError("Unknown snapshot entry blocks retention")
        receipt, refs = snapshot_record(directory, config, base)
        result.append((directory, receipt, refs))
    return sorted(result, key=lambda row: base.instant(row[1]["receivedAt"]))


def status(config, base):
    rows = snapshots(config, base)
    latest = rows[-1][1] if rows else None
    age = max(0, (base.now() - base.instant(latest["sourceSnapshotAt"])).total_seconds()) if latest else None
    return {"snapshotFormat": FORMAT, "completedSnapshots": len(rows), "latestSnapshot": latest,
        "latestCompleteSnapshotAgeSeconds": round(age, 3) if age is not None else None,
        "snapshotRpo15MinutesFresh": age is not None and age <= 900,
        "snapshotIntervalSeconds": 300, "continuousWalProtected": False,
        "arbitraryPitrOriginalHistoryProtected": False,
        "snapshotRecoveryPoints": [{"id": row[1]["sourceSetId"], "snapshotId": row[1]["snapshotId"],
            "storageTargetId": "cloud-archive", "recoverableUntil": row[1]["sourceSnapshotAt"],
            "manifestSha256": row[1]["sourceManifestSha256"], "cipherSha256": row[1]["manifestCipherSha256"],
            "complete": True, "cipherVerified": True, "keysCovered": False, "verified": False,
            "reasonCode": ("SIGNED_CHUNK_CLOSURE_VERIFIED_RESTORE_PENDING" if row[1].get("sourceSignatureVerified")
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
    root, objects, points = directories(config, base)
    operation = header.get("operation")
    if operation == "probeChunks":
        if (set(header) != {"format", "operation", "opaqueIds"} or not isinstance(header["opaqueIds"], list)
                or len(header["opaqueIds"]) > MAX_REFERENCES or len(set(header["opaqueIds"])) != len(header["opaqueIds"])):
            raise ValueError("Invalid chunk probe")
        existing = [value for name in header["opaqueIds"] if (value := object_record(objects, name, base))]
        outgoing.write(canonical({"format": FORMAT, "objects": existing}) + b"\n")
        return
    with base.lock(root / ".receiver.lock", timeout=base.RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
        if operation == "putChunk":
            if set(header) != {"format", "operation", "opaqueId", "cipherSha256", "cipherBytes"}:
                raise ValueError("Invalid chunk upload header")
            name = header["opaqueId"]
            if not OPAQUE.fullmatch(name):
                raise ValueError("Invalid opaque chunk identity")
            old = object_record(objects, name, base)
            if old and (old["cipherSha256"] != header["cipherSha256"] or old["cipherBytes"] != header["cipherBytes"]):
                raise ValueError("Existing chunk cannot be overwritten")
            capacity(config, header["cipherBytes"], base)
            stage = objects / (".incoming-" + uuid.uuid4().hex)
            stage.mkdir(mode=0o700)
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
            except BaseException:
                if stage.exists():shutil.rmtree(stage)
                raise
        if operation != "commitSnapshot" or set(header) != {"format", "operation", "snapshotReceipt", "references", "sourceSignature"}:
            raise ValueError("Unsupported chunk protocol operation")
        receipt = header["snapshotReceipt"]
        expected = {"format", "snapshotId", "nonce", "sourceSetId", "sourceSnapshotAt", "sourceManifestSha256",
                    "recipientFingerprint", "manifestCipherSha256", "manifestCipherBytes", "referenceListSha256",
                    "marketStateIncluded", "clientReleaseStateIncluded"}
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
        stage = points / (".incoming-" + uuid.uuid4().hex)
        stage.mkdir(mode=0o700)
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
            base.atomic_json(Path(config["status_file"]), base.build_status(config))
            outgoing.write(canonical(result) + b"\n")
        except BaseException:
            if stage.exists():shutil.rmtree(stage)
            raise


def retention_plan_locked(config, base):
    """Prove the complete snapshot/object plan before either format is deleted."""
    _, objects, points = directories(config, base)
    rows = snapshots(config, base)  # Any malformed point aborts all chunk GC.
    keep = {row[0] for row in rows[-config["minimum_complete_sets"]:]}
    daily = {}
    moment = base.now()
    for directory, receipt, _ in rows:
        timestamp = base.instant(receipt["receivedAt"])
        if timestamp > moment + timedelta(minutes=5):raise ValueError("Receiver clock moved backwards")
        if timestamp >= moment - timedelta(days=config["hourly_retention_days"]):keep.add(directory)
        if timestamp >= moment - timedelta(days=config["daily_retention_days"]):daily[timestamp.date()] = directory
    keep.update(daily.values())
    retained = [row for row in rows if row[0] in keep]
    # Objects are immutable and this entire operation owns the receiver mutex.
    # Validate every reference, but open each shared object once rather than
    # once per snapshot (thousands of snapshots may reference the same chunk).
    # Prove the complete retained closure before removing any recovery point.
    needed = {}
    for _, _, refs in retained:
        for row in refs:
            previous = needed.setdefault(row['opaqueId'], row)
            if previous != row:
                raise ValueError('Retained references disagree about an immutable chunk')
    for name, row in needed.items():
        known = object_record(objects, name, base)
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
        if {p.name for p in directory.iterdir()} != allowed:
            raise ValueError("Unknown snapshot contents block cleanup")
        obsolete_points.append(directory)
    obsolete_objects = []
    for directory in objects.iterdir():
        if directory.name.startswith(".incoming-"):continue
        if not OPAQUE.fullmatch(directory.name):raise ValueError("Unknown chunk entry blocks GC")
        if directory.name in needed:continue
        known = object_record(objects, directory.name, base)
        if base.instant(known["receivedAt"]) >= moment - timedelta(days=2):continue
        if directory.parent != objects or directory != directory.resolve():raise ValueError("Chunk GC escaped its root")
        if {p.name for p in directory.iterdir()} != {"cipher.gpg", "receipt.json"}:raise ValueError("Unknown chunk files block GC")
        obsolete_objects.append(directory)
    return {'pointsRoot': points, 'objectsRoot': objects,
            'snapshots': tuple(obsolete_points), 'objects': tuple(obsolete_objects)}


def apply_retention_plan_locked(plan, base):
    """Only consume a preflight plan while its original receiver mutex is held."""
    for directory in (*plan['snapshots'], *plan['objects']):
        shutil.rmtree(directory)
    base.sync_directory(plan['pointsRoot'])
    base.sync_directory(plan['objectsRoot'])
    return {'deletedSnapshots': len(plan['snapshots']), 'deletedUnreferencedChunks': len(plan['objects'])}


def retain_locked(config, base):
    return apply_retention_plan_locked(retention_plan_locked(config, base), base)


def bundle(config, snapshot_id, outgoing, base):
    """Root management CLI only: stream exact ciphertext closure, never an RPC capability."""
    if not isinstance(snapshot_id, str) or not SNAPSHOT.fullmatch(snapshot_id):
        raise ValueError("A fixed registered snapshot identity is required")
    root, objects, points = directories(config, base)
    with ExitStack() as opened:
        with base.lock(root / ".receiver.lock"):
            directory = points / snapshot_id
            receipt, refs = snapshot_record(directory, config, base, verify=True)
            if receipt.get("sourceSignatureVerified") is not True:
                raise ValueError("Unsigned legacy snapshot needs an independently pinned recovery procedure")
            if len(refs) > 500:
                raise ValueError("Management bundle descriptor budget exceeded")
            files = [(directory/name,name) for name in ("manifest.gpg", "references.json", "target-receipt.json",
                                                       "source-receipt.json", "source-signature.sshsig")]
            for row in refs:
                known = object_record(objects, row["opaqueId"], base, verify=True)
                if known is None or any(known[key] != row[key] for key in ("cipherSha256", "cipherBytes")):
                    raise ValueError("Management bundle dependency closure failed")
                files.append((objects/row["opaqueId"]/"cipher.gpg", "objects/"+row["opaqueId"]+".gpg"))
            streams = []
            for path, name in files:
                base.private_path(path)
                stream = opened.enter_context(os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW),"rb"))
                streams.append((stream,name,os.fstat(stream.fileno())))
        # File descriptors preserve these immutable bytes even if independent retention unlinks old paths.
        with tarfile.open(fileobj=outgoing,mode="w|",format=tarfile.PAX_FORMAT) as archive:
            for stream,name,info in streams:
                member=tarfile.TarInfo(name);member.size=info.st_size;member.mode=0o600
                archive.addfile(member,stream)


def rpc(config, header, base, payload=None, maximum=4 * 1024 * 1024, *, deadline=None):
    process = subprocess.Popen(base.ssh_command(config), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env={"PATH": "/usr/bin:/bin", "LANG": "C"})
    try:
        return base.transfer_exchange(process, canonical(header) + b'\n', payload, maximum,
            deadline=deadline if deadline is not None else base.time.monotonic() + base.SNAPSHOT_JOB_SECONDS)
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


def run_source(config, base):
    deadline = base.time.monotonic() + base.SNAPSHOT_JOB_SECONDS
    state = base.private_path(config["state_directory"], directory=True)
    with base.lock(state / ".snapshot-source.lock"):
        status_path = state / "snapshot-status.json"
        previous = base.read_json(status_path) if status_path.exists() else None
        stage = None
        key_fd = None
        try:
            with base.lock(state / '.source.lock', timeout=base.SOURCE_CAPTURE_WAIT_SECONDS, busy_code='SOURCE_BUSY'):
                result = subprocess.run(["/usr/bin/python3", "-I", config["paired_helper"], "--config", config["paired_config"]],
                    capture_output=True, timeout=180, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"})
                if result.returncode:raise RuntimeError("Consistent paired snapshot failed")
                spec = importlib.util.spec_from_file_location("uten_snapshot_sealed", config["sealed_helper"])
                sealed = importlib.util.module_from_spec(spec);sys.modules[spec.name] = sealed;spec.loader.exec_module(sealed)
                paired = sealed.load_paired(Path(config["paired_helper"]))
                root = Path(base.read_json(config["paired_config"])["backup_root"])
                secret = base.private_path(config["chunk_identity_file"]).read_bytes()
                if len(secret) != 32:raise ValueError("Invalid opaque chunk identity secret")
                stage = state / (".snapshot-" + uuid.uuid4().hex)
                stage.mkdir(mode=0o700);home = stage / "gnupg";home.mkdir(mode=0o700)
                public = base.private_path(config["recipient_file"]).read_bytes()
                sealed.check_recipient(public, config["recipient_fingerprint"], home)
                key_fd = os.memfd_create("uten-snapshot-recipient", os.MFD_CLOEXEC)
                os.write(key_fd, public);os.lseek(key_fd, 0, os.SEEK_SET)
                plaintext, files = {}, []
                with sealed.shared_backup_lock(root):
                    set_id, manifest_digest, entries, summary = sealed.collect_files(root, paired,
                        Path(config["paired_helper"]), Path("/"), config["recovery_files"],
                        include_remote_recovery=config.get('include_remote_recovery',False))
                    total = sum(path.stat().st_size for path, _ in entries)
                    if total > config.get("max_snapshot_plain_bytes", 512 * 1024**2):raise ValueError("Snapshot memory budget exceeded")
                    for path, name in entries:
                        ids = [];whole = hashlib.sha256();size = 0
                        before = sealed.safe_path(path)
                        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                        with os.fdopen(fd, "rb") as stream:
                            if not os.path.samestat(before, os.fstat(stream.fileno())):raise ValueError("Snapshot input changed")
                            while raw := stream.read(CHUNK_BYTES):
                                opaque = identity(secret, raw);plaintext.setdefault(opaque, raw)
                                ids.append({"opaqueId": opaque, "size": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})
                                whole.update(raw);size += len(raw)
                            after = os.fstat(stream.fileno())
                        if (before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_size,after.st_mtime_ns,after.st_ctime_ns):
                            raise ValueError("Snapshot file changed during read")
                        files.append({"path": name, "size": size, "sha256": whole.hexdigest(), "chunks": ids})
                    if len(plaintext) > MAX_REFERENCES:raise ValueError("Snapshot chunk closure exceeds budget")
                    source_manifest = base.read_json(root / set_id / "manifest.json")
            # All source bytes and identities are captured privately; release
            # the source mutex before encryption and receiver/GC backpressure.
            probed = rpc(config, {"format": base.FORMAT, "operation": "probeChunks", "opaqueIds": sorted(plaintext)}, base,
                         deadline=deadline)
            existing = {row["opaqueId"]: row for row in probed["objects"]}
            refs = [];new_bytes = new_count = 0
            for opaque, raw in sorted(plaintext.items()):
                known = existing.get(opaque)
                if known is None:
                    cipher = stage / (opaque + ".gpg")
                    encrypt_bytes(raw, cipher, key_fd, home, sealed)
                    header = {"format": base.FORMAT, "operation": "putChunk", "opaqueId": opaque,
                              "cipherSha256": base.digest(cipher), "cipherBytes": cipher.stat().st_size}
                    known = rpc(config, header, base, cipher, deadline=deadline)
                    if any(known.get(key) != header[key] for key in ("opaqueId", "cipherSha256", "cipherBytes")):
                        raise ValueError("Chunk acknowledgment differs")
                    new_count += 1;new_bytes += known["cipherBytes"];cipher.unlink()
                refs.append({key: known[key] for key in ("opaqueId", "cipherSha256", "cipherBytes")})
            reference_list(refs, base)
            point_id = "snapshot-" + base.now().strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
            nonce = uuid.uuid4().hex
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
            cipher = stage / "manifest.gpg";encrypt_bytes(canonical(manifest), cipher, key_fd, home, sealed)
            receipt = {key: manifest[key] for key in ("format", "snapshotId", "nonce", "sourceSetId", "sourceSnapshotAt",
                "sourceManifestSha256", "recipientFingerprint", "referenceListSha256")}
            receipt.update(manifestCipherSha256=base.digest(cipher), manifestCipherBytes=cipher.stat().st_size,
                marketStateIncluded=bool(summary.get("market_state")), clientReleaseStateIncluded=bool(summary.get("client_release_state")))
            signature = sign_receipt(receipt, config["signing_key_file"], base)
            target = rpc(config, {"format": base.FORMAT, "operation": "commitSnapshot", "snapshotReceipt": receipt,
                                   "references": refs, "sourceSignature": signature}, base, cipher, deadline=deadline)
            if target.get("snapshotId") != point_id or target.get("manifestCipherSha256") != receipt["manifestCipherSha256"]:
                raise ValueError("Snapshot commit acknowledgment differs")
            status_value = {"format": FORMAT, "state": "SNAPSHOT_CIPHERTEXT_COMPLETE", "observedAt": base.now().isoformat(),
                "health": "HEALTHY", "latest": target, "newChunks": new_count, "reusedChunks": len(refs)-new_count,
                "newCipherBytes": new_bytes+cipher.stat().st_size, "snapshotPlainBytes": total,
                "snapshotIntervalSeconds": 300, "continuousWalProtected": False,
                "arbitraryPitrOriginalHistoryProtected": False, "restoreVerified": False}
            base.atomic_json(status_path, status_value)
            return status_value
        except Exception as error:
            failure = {**base.failure_record(error), "format": FORMAT, "health": "DEGRADED",
                "observedAt": base.now().isoformat(),
                "latest": previous.get("latest") if previous else None,
                "continuousWalProtected": False, "arbitraryPitrOriginalHistoryProtected": False}
            if isinstance(error, base.TransferBusy) and error.code == 'SOURCE_BUSY':
                failure.update(state='DEFERRED', retryPolicy='NEXT_TIMER')
                base.atomic_json(status_path, failure)
                return failure
            base.atomic_json(status_path, failure)
            raise
        finally:
            if key_fd is not None:os.close(key_fd)
            if stage is not None and stage.exists():shutil.rmtree(stage)
