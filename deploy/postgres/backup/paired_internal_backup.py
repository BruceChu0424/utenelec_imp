#!/usr/bin/python3
"""Local, fail-closed PostgreSQL snapshot + immutable internal-media backup.

Run from the root-owned systemd unit. No cloud upload, retention deletion, SQL
data mutation, or automatic restore is performed by this program.
"""
from __future__ import annotations

import argparse
import dataclasses
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

CHUNK = 1024 * 1024
MAGIC = b"UTENINT\x01"
KEY = re.compile(r"i1_([A-Z][A-Z0-9_]{0,63})_([0-9]{4}(?:0[1-9]|1[0-2]))_([a-f0-9]{32}(?:\.[a-z0-9]{1,8})?)\Z")
LEGACY_KEY = re.compile(r"[a-f0-9]{32}(?:\.[a-z0-9]{1,8})?\Z")
FIELDS = ("id", "owner_type", "owner_id", "storage_key", "storage_version", "sha256",
          "size_bytes", "stored_size_bytes", "storage_encoding", "storage_provider")
CONSISTENCY_SQL = """
SELECT EXISTS (
  SELECT 1 FROM attachments a JOIN attachment_object_outbox o
    ON o.storage_key = a.storage_key
   AND (o.storage_provider = a.storage_provider OR o.storage_provider = 'legacy_unknown')
   AND (o.storage_version IS NOT DISTINCT FROM a.storage_version OR o.storage_version IS NULL)
  WHERE a.lifecycle_state = 'CLEAN' AND o.operation = 'DELETE_FINAL' AND o.status <> 'SUCCEEDED'
)
"""


@dataclasses.dataclass(frozen=True)
class Config:
    database: str = "uten_imp"
    socket_directory: str = "/run/postgresql"
    port: int = 5432
    postgres_user: str = "postgres"
    media_root: str = "/var/lib/uten-imp-media/attachments"
    backup_root: str = "/data/uten-imp-backups/paired"
    pg_dump: str = "/usr/lib/postgresql/16/bin/pg_dump"
    min_free_bytes: int = 10 * 1024**3
    min_free_percent: int = 15
    bytes_per_second: int = 20 * 1024**2
    max_seconds: int = 1800
    max_object_bytes: int = 1024**3


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def real_directory(path: Path) -> Path:
    if not path.is_absolute() or path != path.resolve(strict=True) or not path.is_dir():
        raise ValueError("A real absolute directory is required")
    return path


def relative_key(key: str) -> Path:
    if LEGACY_KEY.fullmatch(key):
        return Path(key)
    match = KEY.fullmatch(key)
    if match:
        return Path(match[1], match[2], key)
    raise ValueError("Invalid internal storage key")


def open_original(root: Path, relative: Path):
    """Open every path component with NOFOLLOW, including the final file."""
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in relative.parts[:-1]:
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = following
        result = os.open(relative.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        if not stat.S_ISREG(os.fstat(result).st_mode):
            os.close(result)
            raise ValueError("Object is not a regular file")
        return os.fdopen(result, "rb")
    finally:
        os.close(fd)


def sync_directory(path: Path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_json(path: Path, content: dict):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(content, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


class Budget:
    def __init__(self, config: Config, root: Path):
        self.config, self.root = config, root
        self.started = time.monotonic()
        self.copied = 0

    def check(self, additional: int = 0):
        if time.monotonic() - self.started >= self.config.max_seconds:
            raise TimeoutError("Backup exceeded its time budget")
        usage = shutil.disk_usage(self.root)
        reserve = max(self.config.min_free_bytes, usage.total * self.config.min_free_percent // 100)
        if usage.free - additional < reserve:
            raise OSError("Backup destination has insufficient reserved free space")

    def written(self, count: int):
        self.copied += count
        # Wall-time cap complements systemd cgroup IO caps, including fast test/NVMe filesystems.
        delay = self.copied / self.config.bytes_per_second - (time.monotonic() - self.started)
        while delay > 0:
            self.check()
            time.sleep(min(delay, 0.25))
            delay = self.copied / self.config.bytes_per_second - (time.monotonic() - self.started)
        self.check()


def check_envelope(path: Path, metadata: dict, max_original: int) -> dict:
    original_hash = hashlib.sha256()
    storage_hash = hashlib.sha256()
    with open_original(path.parent, Path(path.name)) as source:
        header = source.read(57)
        if len(header) != 57:
            raise ValueError("Incomplete internal envelope")
        magic, codec, original_size, stored_size, digest = struct.unpack(">8sBqq32s", header)
        if (magic != MAGIC or codec not in (0, 1) or original_size <= 0
                or original_size > max_original or stored_size <= 0
                or os.fstat(source.fileno()).st_size != 57 + stored_size
                or (codec == 0 and original_size != stored_size)):
            raise ValueError("Invalid internal envelope")
        expected = {"sha256": digest.hex(), "size_bytes": original_size,
                    "stored_size_bytes": 57 + stored_size,
                    "storage_encoding": "GZIP" if codec else "IDENTITY",
                    "storage_version": "internal-v1:" + digest.hex()}
        if any(metadata.get(key) != value for key, value in expected.items()):
            raise ValueError("Envelope differs from confirmed database identity")
        storage_hash.update(header)
        while chunk := source.read(CHUNK):
            storage_hash.update(chunk)
        source.seek(57)
        decoded = gzip.GzipFile(fileobj=source) if codec else source
        count = 0
        while chunk := decoded.read(min(CHUNK, original_size - count + 1)):
            count += len(chunk)
            if count > original_size:
                raise ValueError("Decoded object exceeds original size")
            original_hash.update(chunk)
        if count != original_size or original_hash.hexdigest() != expected["sha256"]:
            raise ValueError("Restored original digest or size mismatch")
    return {"storage_sha256": storage_hash.hexdigest(), **expected}


def copy_object(source_root: Path, target_root: Path, row: dict, budget: Budget) -> dict:
    relative = relative_key(row["storage_key"])
    target = target_root / relative
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    budget.check(row["stored_size_bytes"])
    copied = 0
    with open_original(source_root, relative) as source, target.open("xb") as destination:
        while chunk := source.read(CHUNK):
            copied += len(chunk)
            if copied > row["stored_size_bytes"]:
                raise ValueError("Stored object grew beyond confirmed identity")
            destination.write(chunk)
            budget.written(len(chunk))
        destination.flush()
        os.fsync(destination.fileno())
    if copied != row["stored_size_bytes"]:
        raise ValueError("Stored object is incomplete")
    return {**row, "relative_path": relative.as_posix(),
            **check_envelope(target, row, budget.config.max_object_bytes)}


def connect_peer(config: Config):
    import psycopg2
    account = pwd.getpwnam(config.postgres_user)
    previous_uid = os.geteuid()
    try:
        os.seteuid(account.pw_uid)
        return psycopg2.connect(dbname=config.database, user=config.postgres_user,
                               host=config.socket_directory, port=config.port,
                               application_name="uten-paired-backup", connect_timeout=5)
    finally:
        os.seteuid(previous_uid)


def dump_snapshot(config: Config, snapshot: str, target: Path, budget: Budget):
    account = pwd.getpwnam(config.postgres_user)
    command = [config.pg_dump, "--format=custom", "--compress=1", "--snapshot=" + snapshot,
               "--host=" + config.socket_directory, "--port=" + str(config.port),
               "--username=" + config.postgres_user, "--dbname=" + config.database,
               "--no-password"]
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PGCONNECT_TIMEOUT": "5"}
    # The root process opens the private output. pg_dump uses the same peer actor/snapshot.
    with target.open("xb") as output, target.with_suffix(".stderr").open("xb") as errors:
        process = subprocess.Popen(command, stdout=output, stderr=errors, env=environment,
                                   user=account.pw_uid, group=account.pw_gid, extra_groups=[])
        try:
            while process.poll() is None:
                budget.check()
                time.sleep(0.25)
            if process.returncode:
                raise RuntimeError("pg_dump failed; inspect the private incomplete-set log")
            if output.tell() <= 0:
                raise RuntimeError("pg_dump produced no data")
            output.flush()
            os.fsync(output.fileno())
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def assert_consistent(cursor):
    cursor.execute(CONSISTENCY_SQL)
    if cursor.fetchone()[0]:
        raise ValueError("CLEAN attachment has a pending physical-delete intent")


def validate_config(config: Config):
    if os.geteuid() != 0:
        raise PermissionError("Paired backup requires the root-owned launcher")
    if (not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,62}", config.database)
            or config.postgres_user != "postgres" or not 1 <= config.port <= 65535
            or not 1 <= config.bytes_per_second <= 100 * 1024**2
            or not 5 <= config.max_seconds <= 7200
            or config.min_free_bytes < 0 or not 1 <= config.min_free_percent <= 90
            or not 1 <= config.max_object_bytes <= 1024**3):
        raise ValueError("Invalid backup resource or database configuration")
    source = real_directory(Path(config.media_root))
    real_directory(source / "final")
    destination = real_directory(Path(config.backup_root))
    real_directory(Path(config.socket_directory))
    if (source == destination or source in destination.parents or destination in source.parents
            or destination.stat().st_uid != 0 or destination.stat().st_mode & 0o077):
        raise ValueError("Backup root must be separate and root-only (0700)")
    executable = Path(config.pg_dump)
    if (not executable.is_absolute() or not executable.is_file()
            or executable.stat().st_uid != 0 or executable.stat().st_mode & 0o022):
        raise ValueError("pg_dump must be a trusted root-owned executable")


def _backup_locked(config: Config) -> Path:
    root = Path(config.backup_root)
    budget = Budget(config, root)
    budget.check()
    set_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
    work = root / (".incomplete-" + set_id)
    work.mkdir(mode=0o700)
    media = work / "media" / "final"
    media.mkdir(parents=True, mode=0o700)
    connection = connect_peer(config)
    count = stored_bytes = original_bytes = 0
    started_at = now()
    try:
        connection.set_session(isolation_level="REPEATABLE READ", readonly=False)
        with connection.cursor() as cursor:
            cursor.execute("SET LOCAL lock_timeout = '5s'")
            cursor.execute("SET LOCAL statement_timeout = '120s'")
            cursor.execute("SET LOCAL idle_in_transaction_session_timeout = %s", (str(config.max_seconds + 60) + "s",))
            assert_consistent(cursor)
            cursor.execute("SELECT COUNT(*), COALESCE(SUM(stored_size_bytes),0) FROM attachments "
                           "WHERE lifecycle_state='CLEAN' AND (storage_provider <> 'internal' "
                           "OR storage_provider IS NULL OR stored_size_bytes IS NULL)")
            if cursor.fetchone()[0]:
                raise ValueError("CLEAN non-internal or unresolved files require explicit reconciliation")
            cursor.execute("SELECT pg_database_size(current_database()), "
                           "(SELECT COALESCE(SUM(stored_size_bytes),0) FROM attachments WHERE lifecycle_state='CLEAN')")
            db_size, media_size = cursor.fetchone()
            budget.check(int(db_size) + int(media_size))
        with connection.cursor(name="paired_clean_objects") as objects, (work / "objects.jsonl").open("x", encoding="utf-8") as manifest:
            objects.itersize = 100
            objects.execute("SELECT " + ",".join(FIELDS) + " FROM attachments "
                            "WHERE lifecycle_state='CLEAN' ORDER BY id FOR SHARE")
            for values in objects:
                row = dict(zip(FIELDS, values))
                row["id"], row["owner_id"] = str(row["id"]), str(row["owner_id"])
                if row["storage_provider"] != "internal":
                    raise ValueError("Unexpected provider in locked snapshot")
                record = copy_object(Path(config.media_root) / "final", media, row, budget)
                manifest.write(json.dumps(record, ensure_ascii=False) + "\n")
                count += 1
                stored_bytes += row["stored_size_bytes"]
                original_bytes += row["size_bytes"]
            manifest.flush()
            os.fsync(manifest.fileno())
        with connection.cursor() as cursor:
            assert_consistent(cursor)
            cursor.execute("SELECT pg_export_snapshot(), current_setting('server_version'), txid_current_snapshot()::text")
            snapshot, server_version, transaction_snapshot = cursor.fetchone()
        dump_snapshot(config, snapshot, work / "database.dump", budget)
        # Commit is deliberately after pg_dump: it releases the CLEAN-row deletion guards.
        connection.commit()
    except BaseException:
        connection.rollback()
        raise
    finally:
        connection.close()
    budget.check()
    dump_size = (work / "database.dump").stat().st_size
    summary = {"format": "uten-paired-internal-v1", "set_id": set_id, "database": config.database,
               "started_at": started_at, "completed_at": now(),
               "duration_seconds": round(time.monotonic() - budget.started, 3),
               "postgres_version": server_version, "transaction_snapshot": transaction_snapshot,
               "clean_objects": count, "original_bytes": original_bytes, "stored_bytes": stored_bytes,
               "database_dump_bytes": dump_size, "data_bytes": dump_size + stored_bytes,
               "database_dump_sha256": digest_file(work / "database.dump"),
               "objects_manifest_sha256": digest_file(work / "objects.jsonl"),
               "resource_limits": dataclasses.asdict(config),
               "retention": "No automatic removal; preserve older sets until reviewed cleanup",
               "scope": "Database snapshot and its CLEAN internal final files; unfinished uploads must be retried"}
    write_json(work / "manifest.json", summary)
    for directory, _, _ in os.walk(work, topdown=False):
        sync_directory(Path(directory))
    published = root / set_id
    os.rename(work, published)
    sync_directory(root)
    # Updating success is last. Any failed/incomplete run leaves the previous pointer intact.
    temporary = root / (".latest-" + uuid.uuid4().hex)
    write_json(temporary, {"set_id": set_id, "completed_at": summary["completed_at"],
                           "manifest_sha256": digest_file(published / "manifest.json")})
    os.replace(temporary, root / "latest-success.json")
    sync_directory(root)
    return published


def last_success_time(root: Path) -> str | None:
    """Only the private durable success pointer is authoritative, not an attempt."""
    try:
        with open_original(root, Path("latest-success.json")) as stream:
            raw = stream.read(8193)
        if len(raw) > 8192:
            return None
        value = json.loads(raw)
        if not isinstance(value["completed_at"], str):
            return None
        completed = datetime.fromisoformat(value["completed_at"].replace("Z", "+00:00"))
        if completed.tzinfo is None or completed > datetime.now(timezone.utc):
            return None
        return completed.astimezone(timezone.utc).isoformat()
    except (OSError, ValueError, KeyError, TypeError):
        return None


def record_attempt(root: Path, status: str, started: str, completed: str | None) -> None:
    # No set id, database name, object key, path, credentials or exception text.
    value = {"format": "uten-paired-backup-attempt-v1", "status": status,
             "startedAt": started, "completedAt": completed,
             "lastSuccessAt": last_success_time(root)}
    temporary = root / (".attempt-" + uuid.uuid4().hex)
    try:
        write_json(temporary, value)
        temporary.chmod(0o600)
        os.replace(temporary, root / "last-attempt.json")
        sync_directory(root)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def backup(config: Config) -> Path:
    # The trusted status destination must be usable before validating source
    # files or reserved space, so those failures are visible to monitoring.
    if os.geteuid() != 0:
        raise PermissionError("Paired backup requires the root-owned launcher")
    root = real_directory(Path(config.backup_root))
    if root.stat().st_uid != 0 or root.stat().st_mode & 0o077:
        raise ValueError("Backup root must be root-only (0700)")
    previous_mask = os.umask(0o077)
    lock_fd = None
    try:
        lock_fd = os.open(root / ".backup.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        # A second invocation must not overwrite the active task's status.
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = now()
        record_attempt(root, "RUNNING", started, None)
        try:
            validate_config(config)
            published = _backup_locked(config)
            record_attempt(root, "SUCCESS", started, now())
            return published
        except BaseException:
            try:
                record_attempt(root, "FAILED", started, now())
            except Exception:
                # A non-writable target cannot promise durable failure status.
                # Keep the previously written RUNNING/unknown state, never forge success.
                print("Paired backup attempt state could not be persisted", file=sys.stderr)
            raise
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        os.umask(previous_mask)


def verify_set(directory: Path) -> dict:
    real_directory(directory)
    if (directory / "manifest.json").stat().st_size > 65536:
        raise ValueError("Oversized backup manifest")
    summary = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if (summary["format"] != "uten-paired-internal-v1"
            or digest_file(directory / "database.dump") != summary["database_dump_sha256"]
            or digest_file(directory / "objects.jsonl") != summary["objects_manifest_sha256"]):
        raise ValueError("Backup set manifest/dump integrity failed")
    count = stored = original = 0
    real_directory(directory / "media" / "final")
    with (directory / "objects.jsonl").open(encoding="utf-8") as stream:
        while line := stream.readline(16385):
            if len(line) > 16384:
                raise ValueError("Oversized object manifest entry")
            row = json.loads(line)
            relative = relative_key(row["storage_key"])
            if row["relative_path"] != relative.as_posix() or row["storage_provider"] != "internal":
                raise ValueError("Invalid object manifest path/provider")
            real_directory((directory / "media" / "final" / relative).parent)
            value = check_envelope(directory / "media" / "final" / relative, row, 1024**3)
            if value["storage_sha256"] != row["storage_sha256"]:
                raise ValueError("Stored backup digest changed")
            count += 1
            stored += row["stored_size_bytes"]
            original += row["size_bytes"]
    if (count, stored, original) != (summary["clean_objects"], summary["stored_bytes"], summary["original_bytes"]):
        raise ValueError("Backup set object totals differ")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    if args.verify:
        print(json.dumps({"verified": str(args.verify), "objects": verify_set(args.verify)["clean_objects"]}))
        return
    if args.config is None:
        parser.error("--config is required for backup")
    metadata = args.config.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077
            or metadata.st_size > 16384 or args.config != args.config.resolve()):
        raise PermissionError("Configuration must be a real root-only file")
    config = Config(**json.loads(args.config.read_text(encoding="utf-8")))
    def interrupted(signum, frame):
        raise InterruptedError("Backup interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    print(json.dumps({"published": str(backup(config))}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No original names, credentials, or SQL payloads in the system journal.
        print("Paired backup failed: " + type(error).__name__ + ": " + str(error), file=sys.stderr)
        sys.exit(1)
