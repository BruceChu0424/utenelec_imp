#!/usr/bin/python3
"""Namespaced, append-only ciphertext transfer. No restore, shell or source deletion RPC."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid

FORMAT = "uten-dr-ciphertext-transfer-v1"
EXPORT = re.compile(r"sealed-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}\Z")
SET = re.compile(r"[0-9]{8}T[0-9]{6}Z-[a-f0-9]{12}\Z")
HASH = re.compile(r"[a-f0-9]{64}\Z")
FINGERPRINT = re.compile(r"[A-F0-9]{40}\Z")
CHUNK = 1024 * 1024
HEADER_LIMIT = 2 * 1024 * 1024
SOURCE_CAPTURE_WAIT_SECONDS = 60
RECEIVER_WAIT_SECONDS = 30
TRANSFER_IDLE_SECONDS = 60
ARCHIVE_JOB_SECONDS = 35 * 60
SNAPSHOT_JOB_SECONDS = 4 * 60
FAILURE_CODES = frozenset({'LOCK_BUSY', 'SOURCE_BUSY', 'RECEIVER_BUSY',
    'RECEIVER_CAPACITY_LIMIT', 'RECEIVER_PROCESS_FAILED', 'RECEIVER_REJECTED',
    'TRANSFER_PIPE_CLOSED', 'TRANSFER_IO_ERROR', 'TRANSFER_IDLE_TIMEOUT',
    'TRANSFER_DEADLINE_EXCEEDED', 'INVALID_TRANSFER'})
SOURCE_FIELDS = {"format", "exportId", "state", "sourceSetId", "sourceManifestSha256",
    "recipientFingerprint", "ciphertextFile", "ciphertextBytes", "ciphertextSha256",
    "cryptoRecoveryIncluded", "completedAt", "targetCopyVerified", "restoreVerified",
    "marketStateIncluded", "clientReleaseStateIncluded"}


class TransferFailure(OSError):
    """A fixed public failure code, never raw SSH stderr or private configuration."""
    def __init__(self, code):
        if not isinstance(code, str) or code not in FAILURE_CODES:
            code = 'RECEIVER_REJECTED'
        self.code = code
        super().__init__(code)


class TransferBusy(BlockingIOError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def failure_record(error):
    code = getattr(error, 'code', None)
    if not isinstance(code, str) or code not in FAILURE_CODES:
        code = ('TRANSFER_PIPE_CLOSED' if isinstance(error, BrokenPipeError) else
                'TRANSFER_IO_ERROR' if isinstance(error, OSError) else 'INVALID_TRANSFER')
    return {'format': FORMAT, 'state': 'FAILED', 'errorType': type(error).__name__, 'errorCode': code}


def now():
    return datetime.now(timezone.utc)


def instant(value):
    if not isinstance(value, str):
        raise ValueError("Invalid timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Timestamp requires timezone")
    return result.astimezone(timezone.utc)


def private_path(path, directory=False):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("Expected absolute private path")
    for parent in (path, *path.parents):
        info = parent.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("Links are forbidden")
    info = path.lstat()
    if (not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            or info.st_uid != os.geteuid() or info.st_mode & 0o077):
        raise ValueError("Private ownership or permissions are unsafe")
    return path


def read_json(path, maximum=HEADER_LIMIT):
    with Path(path).open("rb") as stream:
        raw = stream.read(maximum + 1)
    if len(raw) > maximum:
        raise ValueError("Oversized JSON")
    return decode_json(raw)


def decode_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while block := stream.read(CHUNK):
            result.update(block)
    return result.hexdigest()


@contextmanager
def lock(path, *, timeout=0, busy_code='LOCK_BUSY'):
    if not isinstance(timeout, (int, float)) or not 0 <= timeout <= 600 or busy_code not in FAILURE_CODES:
        raise ValueError('Invalid transfer barrier budget')
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or info.st_nlink != 1 or not stat.S_ISREG(info.st_mode):
            raise ValueError("Unsafe transfer barrier")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError as error:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TransferBusy(busy_code) from error
                time.sleep(min(.05, remaining))
        yield
    finally:
        os.close(fd)


def source_receipt(value, config):
    if (not isinstance(value, dict) or set(value) != SOURCE_FIELDS
            or value["format"] != "uten-sealed-paired-v1" or value["state"] != "CIPHERTEXT_CREATED"
            or not EXPORT.fullmatch(value["exportId"]) or not SET.fullmatch(value["sourceSetId"])
            or not HASH.fullmatch(value["sourceManifestSha256"])
            or not HASH.fullmatch(value["ciphertextSha256"])
            or not FINGERPRINT.fullmatch(value["recipientFingerprint"])
            or value["recipientFingerprint"] != config["recipient_fingerprint"]
            or value["ciphertextFile"] != "archive.gpg"
            or type(value["ciphertextBytes"]) is not int
            or not 100 <= value["ciphertextBytes"] <= config["max_archive_bytes"]):
        raise ValueError("Invalid source receipt")
    for key in ("cryptoRecoveryIncluded", "targetCopyVerified", "restoreVerified",
                "marketStateIncluded", "clientReleaseStateIncluded"):
        if type(value[key]) is not bool:
            raise ValueError("Invalid source receipt flag")
    if not value["cryptoRecoveryIncluded"] or value["targetCopyVerified"] or value["restoreVerified"]:
        raise ValueError("Invalid source evidence state")
    if instant(value["completedAt"]) > now() + timedelta(minutes=5):
        raise ValueError("Source clock is ahead")
    return value


def completed(config):
    root = private_path(config["storage_root"], directory=True)
    result = []
    for directory in root.iterdir():
        if not EXPORT.fullmatch(directory.name):
            continue
        private_path(directory, directory=True)
        target = read_json(private_path(directory / "target-receipt.json"))
        source = source_receipt(read_json(private_path(directory / "source-receipt.json")), config)
        archive = private_path(directory / "archive.gpg")
        if (target.get("format") != FORMAT or target.get("state") != "TARGET_BYTES_VERIFIED"
                or target.get("exportId") != directory.name or source["exportId"] != directory.name
                or target.get("ciphertextSha256") != source["ciphertextSha256"]
                or target.get("ciphertextBytes") != archive.stat().st_size
                or source["ciphertextBytes"] != archive.stat().st_size):
            raise ValueError("Completed archive evidence is damaged")
        result.append((directory, source, target))
    return sorted(result, key=lambda item: instant(item[2]["receivedAt"]))


def storage_bytes(root):
    total = 0
    for parent, directories, files in os.walk(root, followlinks=False):
        for name in directories:
            if (Path(parent) / name).is_symlink():
                raise ValueError("Linked receiver directory")
        for name in files:
            path = Path(parent) / name
            if path.is_symlink():
                raise ValueError("Linked receiver file")
            try:
                total += path.stat().st_size
            except FileNotFoundError:
                continue
    return total


def chunks_module():
    path = Path(__file__).with_name("snapshot_chunks.py")
    private_path(path)
    spec = importlib.util.spec_from_file_location("uten_dr_snapshot_chunks", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_status(config):
    rows = completed(config)
    usage = shutil.disk_usage(config["storage_root"])
    total = sum(row[1]["ciphertextBytes"] for row in rows)
    latest = rows[-1][2] if rows else None
    result = {"format": FORMAT, "targetId": "cloud-archive", "observedAt": now().isoformat(),
        "health": "HEALTHY" if rows and usage.free >= config["min_free_bytes"]
                  and total <= config["max_storage_bytes"]
                  and (now() - instant(latest["receivedAt"])).total_seconds() <= config.get("max_age_seconds", 7200)
                  else "DEGRADED",
        "evidenceTier": "CIPHERTEXT_BYTES_VERIFIED", "completedSets": len(rows),
        "storedCiphertextBytes": total, "freeBytes": usage.free,
        "maxStorageBytes": config["max_storage_bytes"], "minFreeBytes": config["min_free_bytes"],
        "latest": latest, "hourlyRetentionDays": config["hourly_retention_days"],
        "dailyRetentionDays": config["daily_retention_days"],
        "rpo15MinutesSatisfied": False, "continuousWalProtected": False,
        "originalHistoryContinuous": False, "immutableStorageVerified": False,
        "restoreVerified": False,
        "recoveryPoints": [{"id": source["sourceSetId"], "exportId": source["exportId"],
            "storageTargetId": "cloud-archive", "recoverableUntil": target["sourceSnapshotAt"],
            "manifestSha256": source["sourceManifestSha256"], "cipherSha256": source["ciphertextSha256"],
            "complete": True, "cipherVerified": True, "keysCovered": False, "verified": False,
            "reasonCode": "CIPHERTEXT_VERIFIED_RESTORE_PENDING"} for _, source, target in rows]}
    if Path(__file__).with_name("snapshot_chunks.py").exists():
        snapshot_status = chunks_module().status(config, sys.modules[__name__])
        result.update(snapshot_status)
        result["recoveryPoints"].extend(snapshot_status["snapshotRecoveryPoints"])
        result["storedCiphertextBytes"] = storage_bytes(Path(config["storage_root"]))
        if (snapshot_status["snapshotRpo15MinutesFresh"] and usage.free >= config["min_free_bytes"]
                and result["storedCiphertextBytes"] <= config["max_storage_bytes"]):
            result["health"] = "HEALTHY"
        elif snapshot_status["completedSnapshots"]:
            result["health"] = "DEGRADED"
    return result


def receive(config, incoming, outgoing):
    root = private_path(config["storage_root"], directory=True)
    if os.environ.get("SSH_ORIGINAL_COMMAND", ""):
        raise ValueError("Remote commands are forbidden")
    raw = incoming.readline(HEADER_LIMIT + 1)
    if not raw.endswith(b"\n") or len(raw) > HEADER_LIMIT:
        raise ValueError("Invalid protocol header")
    header = decode_json(raw)
    if not isinstance(header, dict) or header.get("format") != FORMAT:
        raise ValueError("Invalid transfer protocol")
    if header.get("operation") in {"probeChunks", "putChunk", "commitSnapshot"}:
        chunks_module().receive(header, incoming, outgoing, config, sys.modules[__name__])
        return
    if header.get("operation") == "status" and set(header) == {"format", "operation"}:
        outgoing.write((json.dumps(build_status(config)) + "\n").encode())
        return
    if set(header) != {"format", "operation", "sourceReceipt", "sourceSnapshotAt"} or header["operation"] != "submit":
        raise ValueError("Unsupported transfer operation")
    receipt = source_receipt(header["sourceReceipt"], config)
    snapshot = instant(header["sourceSnapshotAt"])
    named = datetime.strptime(receipt["sourceSetId"].split("-")[0], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    if abs((snapshot - named).total_seconds()) >= 1 or snapshot > instant(receipt["completedAt"]):
        raise ValueError("Snapshot timestamp does not match its fixed source identity")
    with lock(root / ".receiver.lock", timeout=RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
        rows = completed(config)
        final = root / receipt["exportId"]
        duplicate = next((row for row in rows if row[0] == final), None)
        if duplicate and duplicate[1] != receipt:
            raise ValueError("Export identity collision")
        usage = shutil.disk_usage(root)
        if not duplicate and (usage.free - receipt["ciphertextBytes"] < config["min_free_bytes"]
                or storage_bytes(root) + receipt["ciphertextBytes"] > config["max_storage_bytes"]):
            raise TransferFailure('RECEIVER_CAPACITY_LIMIT')
        stage = root / (".incoming-" + uuid.uuid4().hex)
        stage.mkdir(mode=0o700)
        try:
            remaining = receipt["ciphertextBytes"]
            checksum = hashlib.sha256()
            fd = os.open(stage / "archive.gpg", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                while remaining:
                    block = incoming.read(min(CHUNK, remaining))
                    if not block:
                        raise ValueError("Incomplete ciphertext upload")
                    stream.write(block)
                    checksum.update(block)
                    remaining -= len(block)
                if incoming.read(1) or checksum.hexdigest() != receipt["ciphertextSha256"]:
                    raise ValueError("Ciphertext digest or length failed")
                stream.flush()
                os.fsync(stream.fileno())
            if duplicate:
                shutil.rmtree(stage)
                result = duplicate[2]
            else:
                result = {"format": FORMAT, "state": "TARGET_BYTES_VERIFIED", "targetId": "cloud-archive",
                    "exportId": receipt["exportId"], "sourceSetId": receipt["sourceSetId"],
                    "sourceSnapshotAt": snapshot.isoformat(), "sourceManifestSha256": receipt["sourceManifestSha256"],
                    "ciphertextSha256": receipt["ciphertextSha256"], "ciphertextBytes": receipt["ciphertextBytes"],
                    "receivedAt": now().isoformat(), "restoreVerified": False}
                atomic_json(stage / "source-receipt.json", receipt)
                atomic_json(stage / "target-receipt.json", result)
                sync_directory(stage)
                os.rename(stage, final)
                sync_directory(root)
            atomic_json(Path(config["status_file"]), build_status(config))
            outgoing.write((json.dumps(result) + "\n").encode())
        except BaseException:
            # The path is this invocation's exact new root-owned directory, never a history path.
            if stage.exists():
                shutil.rmtree(stage)
            raise


def retain(config):
    root = private_path(config["storage_root"], directory=True)
    with lock(root / ".receiver.lock", timeout=RECEIVER_WAIT_SECONDS, busy_code='RECEIVER_BUSY'):
        rows = completed(config)
        keep = {path for path, _, _ in rows[-config["minimum_complete_sets"]:]}
        daily = {}
        moment = now()
        for path, _, receipt in rows:
            timestamp = instant(receipt["receivedAt"])
            if timestamp > moment + timedelta(minutes=5):
                raise ValueError("Receiver clock moved backwards")
            if timestamp >= moment - timedelta(days=config["hourly_retention_days"]):
                keep.add(path)
            if timestamp >= moment - timedelta(days=config["daily_retention_days"]):
                daily[timestamp.date()] = path
        keep.update(daily.values())
        obsolete = []
        for path, _, _ in rows:
            if path in keep:
                continue
            if path.parent != root or not EXPORT.fullmatch(path.name) or path != path.resolve():
                raise ValueError("Retention target escaped its root")
            if {item.name for item in path.iterdir()} != {"archive.gpg", "source-receipt.json", "target-receipt.json"}:
                raise ValueError("Unexpected archive contents block retention")
            obsolete.append(path)
        # Both independent recovery formats and all retained dependencies must
        # pass preflight before removing even an expired full archive. Reuse
        # the unique-object validation plan under this same receiver mutex.
        chunks = chunks_module() if Path(__file__).with_name('snapshot_chunks.py').exists() else None
        chunk_plan = chunks.retention_plan_locked(config, sys.modules[__name__]) if chunks else None
        for path in obsolete:
            # Only the target's independent root timer invokes this function. It is absent from the RPC.
            shutil.rmtree(path)
        sync_directory(root)
        chunk_retention = chunks.apply_retention_plan_locked(chunk_plan, sys.modules[__name__]) if chunks else {}
        status = build_status(config)
        status["lastRetention"] = {"at": now().isoformat(), "deletedSets": len(obsolete)}
        status["lastRetention"].update(chunk_retention)
        atomic_json(Path(config["status_file"]), status)
        return status


def ssh_command(config):
    for key in ("identity_file", "known_hosts_file"):
        private_path(config[key])
    if not re.fullmatch(r"[A-Za-z0-9_.@:-]+", config["ssh_target"]):
        raise ValueError("Invalid fixed receiver address")
    return ["/usr/bin/ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=" + config["known_hosts_file"],
        "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
        "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
        "-i", config["identity_file"], config["ssh_target"]]


def transfer_exchange(process, header, payload, maximum, *, deadline):
    """Stream with finite idle time and the caller's remaining whole-job budget."""
    idle_deadline = time.monotonic() + TRANSFER_IDLE_SECONDS
    source = Path(payload).open('rb') if payload is not None else None
    pending = memoryview(header)
    response = bytearray()
    input_complete = False
    try:
        with selectors.DefaultSelector() as poller:
            for pipe, event in ((process.stdin, selectors.EVENT_WRITE), (process.stdout, selectors.EVENT_READ)):
                os.set_blocking(pipe.fileno(), False)
                poller.register(pipe, event)

            def close_input():
                if not process.stdin.closed:
                    poller.unregister(process.stdin)
                    process.stdin.close()

            def remaining_budget():
                current = time.monotonic()
                if current >= deadline:
                    raise TransferFailure('TRANSFER_DEADLINE_EXCEEDED')
                if current >= idle_deadline:
                    raise TransferFailure('TRANSFER_IDLE_TIMEOUT')
                return min(deadline, idle_deadline) - current

            while not process.stdout.closed:
                for selected, _ in poller.select(remaining_budget()):
                    pipe = selected.fileobj
                    if pipe.closed:
                        continue
                    if pipe is process.stdin:
                        if not pending:
                            block = source.read(CHUNK) if source is not None else b''
                            if not block:
                                input_complete = True
                                close_input()
                                continue
                            pending = memoryview(block)
                        try:
                            written = os.write(pipe.fileno(), pending)
                            pending = pending[written:]
                            if written:
                                idle_deadline = time.monotonic() + TRANSFER_IDLE_SECONDS
                        except BlockingIOError:
                            continue
                        except BrokenPipeError:
                            # EOF must reach a rejecting receiver before waiting
                            # for its failure record or its process to finish.
                            close_input()
                    else:
                        try:
                            block = os.read(pipe.fileno(), min(CHUNK, maximum + 1 - len(response)))
                        except BlockingIOError:
                            continue
                        if not block:
                            poller.unregister(pipe)
                            pipe.close()
                            close_input()
                            break
                        response.extend(block)
                        idle_deadline = time.monotonic() + TRANSFER_IDLE_SECONDS
                        if len(response) > maximum:
                            raise TransferFailure('RECEIVER_REJECTED')
                        if response.endswith(b'\n'):
                            try:
                                early = decode_json(response)
                            except (ValueError, UnicodeError):
                                early = None
                            if isinstance(early, dict) and early.get('format') == FORMAT and early.get('state') == 'FAILED':
                                close_input()
            try:
                returncode = process.wait(timeout=remaining_budget())
            except subprocess.TimeoutExpired:
                remaining_budget()
                raise TransferFailure('TRANSFER_IDLE_TIMEOUT') from None
        try:
            value = decode_json(response)
        except (ValueError, UnicodeError):
            raise TransferFailure('RECEIVER_PROCESS_FAILED') from None
        if not isinstance(value, dict):
            raise TransferFailure('RECEIVER_REJECTED')
        if value.get('format') == FORMAT and value.get('state') == 'FAILED':
            raise TransferFailure(value.get('errorCode'))
        if returncode:
            raise TransferFailure('RECEIVER_PROCESS_FAILED')
        if not input_complete:
            raise TransferFailure('TRANSFER_PIPE_CLOSED')
        return value
    finally:
        if source is not None:
            source.close()


def upload(config, directory, source_snapshot, *, deadline=None):
    receipt = read_json(directory / "receipt.json")
    header = {"format": FORMAT, "operation": "submit", "sourceReceipt": receipt,
              "sourceSnapshotAt": source_snapshot}
    # The receiver consumes a finite bounded file, then verifies EOF and hash before publishing.
    process = subprocess.Popen(ssh_command(config), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, env={"PATH": "/usr/bin:/bin", "LANG": "C"})
    try:
        result = transfer_exchange(process, (json.dumps(header, separators=(",", ":")) + "\n").encode(),
                                   directory / 'archive.gpg', HEADER_LIMIT,
                                   deadline=deadline if deadline is not None else time.monotonic() + ARCHIVE_JOB_SECONDS)
        if (result.get("state") != "TARGET_BYTES_VERIFIED" or result.get("exportId") != receipt["exportId"]
                or result.get("ciphertextSha256") != receipt["ciphertextSha256"]
                or result.get("ciphertextBytes") != receipt["ciphertextBytes"]):
            raise ValueError("Receiver receipt binding failed")
        return result
    finally:
        try:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
        finally:
            close_transfer_pipes(process)


def close_transfer_pipes(process):
    # Reaping the child does not close our pipe descriptors. A failed transfer
    # may bypass the normal closes; flushing its dead stdin can fail again.
    # Keep the original transfer/input exception and release both descriptors.
    for stream in (process.stdin, process.stdout):
        if stream is not None and not stream.closed:
            try:
                stream.close()
            except OSError:
                pass


def capture_archive(config, state):
    # The shared source mutex protects consistent input creation and capture.
    # A complete private ciphertext archive no longer depends on live inputs;
    # network backpressure must not block the five-minute capture pipeline.
    with lock(state / '.source.lock', timeout=SOURCE_CAPTURE_WAIT_SECONDS, busy_code='SOURCE_BUSY'):
        environment = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8",
                       "PYTHONDONTWRITEBYTECODE": "1"}
        result = subprocess.run(["/usr/bin/python3", "-I", config["paired_helper"], "--config",
            config["paired_config"]], capture_output=True, env=environment, timeout=1800)
        if result.returncode:
            raise RuntimeError("PAIRED_BACKUP_FAILED")
        paired_config = read_json(config["paired_config"])
        root = Path(paired_config["backup_root"])
        spec = importlib.util.spec_from_file_location("uten_dr_sealed_export", config["sealed_helper"])
        sealed = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = sealed
        spec.loader.exec_module(sealed)
        directory, receipt = sealed.export(root, Path(config["source_export_directory"]),
            private_path(config["recipient_file"]).read_bytes(), config["recipient_fingerprint"],
            config["recovery_files"], helper=Path(config["paired_helper"]),
            include_remote_recovery=config.get('include_remote_recovery',False))
        manifest = read_json(root / receipt["sourceSetId"] / "manifest.json")
        return directory, receipt, manifest['started_at']


def run_source(config):
    deadline = time.monotonic() + ARCHIVE_JOB_SECONDS
    state = private_path(config["state_directory"], directory=True)
    with lock(state / ".archive-source.lock"):
        status_path = state / "status.json"
        previous = read_json(status_path) if status_path.exists() else None
        try:
            directory, receipt, source_snapshot = capture_archive(config, state)
            target = upload(config, directory, source_snapshot, deadline=deadline)
            atomic_json(directory / "target-receipt.json", target)
            status = {"format": FORMAT, "state": "TARGET_BYTES_VERIFIED", "observedAt": now().isoformat(),
                "health": "HEALTHY", "targetId": "cloud-archive", "latest": target,
                "sourceExportDirectory": str(directory), "configuredIntervalSeconds": 3600,
                "rpo15MinutesSatisfied": False, "continuousWalProtected": False,
                "originalHistoryContinuous": False, "restoreVerified": False,
                "marketStateIncluded": receipt["marketStateIncluded"],
                "clientReleaseStateIncluded": receipt["clientReleaseStateIncluded"]}
            atomic_json(status_path, status)
            prune_source_exports(config, directory)
            return status
        except Exception as error:
            status = {"format": FORMAT, "state": "FAILED", "health": "DEGRADED", "observedAt": now().isoformat(),
                **failure_record(error), "latest": previous.get("latest") if previous else None,
                "rpo15MinutesSatisfied": False, "continuousWalProtected": False,
                "originalHistoryContinuous": False, "restoreVerified": False}
            if isinstance(error, TransferBusy) and error.code == 'SOURCE_BUSY':
                status.update(state='DEFERRED', retryPolicy='NEXT_TIMER')
                atomic_json(status_path, status)
                return status
            atomic_json(status_path, status)
            raise


def prune_source_exports(config, newest):
    """Only newly commissioned namespace; retain acknowledged ciphertext for two days."""
    root = private_path(config["source_export_directory"], directory=True)
    for directory in root.iterdir():
        if not EXPORT.fullmatch(directory.name) or directory == newest:
            continue
        private_path(directory, directory=True)
        if {item.name for item in directory.iterdir()} != {"archive.gpg", "receipt.json", "target-receipt.json"}:
            continue
        source = read_json(directory / "receipt.json")
        target = read_json(directory / "target-receipt.json")
        if (target.get("state") != "TARGET_BYTES_VERIFIED"
                or target.get("ciphertextSha256") != source.get("ciphertextSha256")
                or instant(target["receivedAt"]) >= now() - timedelta(days=2)):
            continue
        if directory.parent != root or directory != directory.resolve():
            raise ValueError("Source export cleanup escaped namespace")
        shutil.rmtree(directory)
    sync_directory(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("receive", "retain", "status", "source", "snapshot", "bundle"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--snapshot-id")
    args = parser.parse_args()
    os.umask(0o077)
    # A peer cannot hold a receiver indefinitely or stream unbounded input.
    signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("Operation deadline")))
    signal.alarm(2100)
    try:
        config = read_json(private_path(args.config))
        if args.mode == "receive":
            receive(config, sys.stdin.buffer, sys.stdout.buffer)
        elif args.mode == "bundle":
            chunks_module().bundle(config, args.snapshot_id, sys.stdout.buffer, sys.modules[__name__])
        else:
            value = (run_source(config) if args.mode == "source" else
                     chunks_module().run_source(config, sys.modules[__name__]) if args.mode == "snapshot" else
                     retain(config) if args.mode == "retain" else build_status(config))
            print(json.dumps(value))
        return 0
    except Exception as error:
        failure = failure_record(error)
        if args.mode == 'receive':
            # SSH transports stdout back to the sender even if the finite input
            # is rejected early. Never include traceback, paths or raw stderr.
            print(json.dumps(failure), flush=True)
        print(json.dumps(failure), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
