#!/usr/bin/python3
"""Local, fail-closed PostgreSQL snapshot + immutable internal-media backup.

Run from the root-owned systemd unit. No cloud upload, SQL data mutation, or
automatic restore is performed by this program. After a run has been published
and recorded as successful, it removes only its own expired sets inside
backup_root (see prune_expired_sets) and records the counts-only cleanup state in
last-attempt.json; there is no separate deletion entry point.
"""
from __future__ import annotations

import argparse
import dataclasses
import gzip
import hashlib
import json
import os
from pathlib import Path
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

if os.name == "posix":
    import fcntl
    import pwd

CHUNK = 1024 * 1024
MAGIC = b"UTENINT\x01"
KEY = re.compile(r"i1_([A-Z][A-Z0-9_]{0,63})_([0-9]{4}(?:0[1-9]|1[0-2]))_([a-f0-9]{32}(?:\.[a-z0-9]{1,8})?)\Z")
LEGACY_KEY = re.compile(r"[a-f0-9]{32}(?:\.[a-z0-9]{1,8})?\Z")
FIELDS = ("id", "owner_type", "owner_id", "storage_key", "storage_version", "sha256",
          "size_bytes", "stored_size_bytes", "storage_encoding", "storage_provider")
PRIVATE_TABLES = ("sales_quote_template_candidates", "sales_quote_template_versions", "goods_cost_imports",
                  "sales_quote_template_candidate_history", "ai_input_originals")
IDENTITY_FIELDS = ("storage_provider", "storage_key", "storage_version", "sha256", "size_bytes")
# Retention only ever recognizes names this program creates itself.
SET_NAME = re.compile(r"([0-9]{8}T[0-9]{6}Z)-[a-f0-9]{12}\Z")
UNPUBLISHED_NAME = re.compile(r"\.(incomplete|expired)-(([0-9]{8}T[0-9]{6}Z)-[a-f0-9]{12})\Z")
SET_FORMATS = ("uten-paired-internal-v1", "uten-paired-internal-v2")
CONSISTENCY_SQL = """
SELECT EXISTS (
  SELECT 1 FROM attachments a JOIN attachment_object_outbox o
    ON o.storage_key = a.storage_key
   AND (o.storage_provider = a.storage_provider OR o.storage_provider = 'legacy_unknown')
   AND (o.storage_version IS NOT DISTINCT FROM a.storage_version OR o.storage_version IS NULL)
  WHERE a.lifecycle_state IN ('CLEAN','RETAINED_HISTORY','DELETE_PENDING','DELETE_FAILED') AND o.operation = 'DELETE_FINAL' AND o.status NOT IN ('SUCCEEDED','RETAINED_HISTORY')
)
"""


@dataclasses.dataclass(frozen=True)
class Config:
    database: str = "uten_imp"
    socket_directory: str = "/run/postgresql"
    port: int = 5432
    postgres_user: str = "postgres"
    media_root: str = "/var/lib/uten-imp-media/attachments"
    local_media_root: str | None = None
    backup_root: str = "/data/uten-imp-backups/paired"
    pg_dump: str = "/usr/lib/postgresql/16/bin/pg_dump"
    min_free_bytes: int = 10 * 1024**3
    min_free_percent: int = 15
    bytes_per_second: int = 20 * 1024**2
    max_seconds: int = 1800
    max_object_bytes: int = 1024**3
    # 2026-10-06 owner decision: every server backup keeps 3 days (pgBackRest repos, paired sets,
    # pre-activation dumps). With two runs a day that is up to 6 sets, never fewer than 3.
    retention_days: int = 3


def check_retention_days(value) -> int:
    # bool is an int subclass; "3" or 3.0 are typos that must never silently change deletion.
    if type(value) is not int or not 1 <= value <= 365:
        raise ValueError("retention_days must be an integer from 1 to 365")
    return value


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
    if relative.is_absolute() or not relative.parts or any(p in (".", "..") for p in relative.parts):
        raise ValueError("Invalid relative object path")
    if os.name != "posix":
        # Source capture on Windows uses a private, access-controlled directory.
        # Reject junctions as well as symlinks; compare the opened file identity.
        real_directory(root)
        current = root
        for part in relative.parts:
            current /= part
            info = current.lstat()
            if info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError("Reparse point in media path")
        before = current.stat()
        stream = current.open("rb")
        if not stat.S_ISREG(before.st_mode) or not os.path.samestat(before, os.fstat(stream.fileno())):
            stream.close()
            raise ValueError("Media file identity changed")
        return stream
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
        required = ("sha256", "size_bytes", "storage_version")
        if any(metadata.get(key) != expected[key] for key in required) or any(
                metadata.get(key) is not None and metadata[key] != expected[key]
                for key in ("stored_size_bytes", "storage_encoding")):
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


def normalize_reference(row: dict) -> dict:
    row = dict(row)
    if row.get("source_table") not in ("attachments", *PRIVATE_TABLES):
        raise ValueError("Unknown media reference producer")
    try:
        logical_id = str(row["id"])
        if row["source_table"] == "sales_quote_template_versions":
            template_id, version = logical_id.split(":")
            uuid.UUID(template_id)
            if not re.fullmatch(r"[1-9][0-9]{0,9}", version) or int(version) > 2147483647:
                raise ValueError("invalid template version")
        elif row["source_table"] == "sales_quote_template_candidate_history":
            if not re.fullmatch(r"[1-9][0-9]{0,18}", logical_id) or int(logical_id) > 9223372036854775807:
                raise ValueError("invalid history sequence")
        else:
            uuid.UUID(logical_id)
    except (ValueError, KeyError, TypeError):
        raise ValueError("Invalid logical media reference identity") from None
    if (row.get("storage_provider") not in ("internal", "local")
            or not isinstance(row.get("sha256"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", row["sha256"])
            or type(row.get("size_bytes")) is not int or not 0 < row["size_bytes"] <= 1024**3):
        raise ValueError("Unresolved media reference identity")
    relative_key(row["storage_key"])
    if row["storage_provider"] == "local":
        if not LEGACY_KEY.fullmatch(row["storage_key"]) or row.get("storage_version") is not None:
            raise ValueError("Invalid local object key/version")
        if (row.get("stored_size_bytes") not in (None, row["size_bytes"])
                or row.get("storage_encoding") not in (None, "IDENTITY")):
            raise ValueError("Conflicting local physical metadata")
        row["stored_size_bytes"], row["storage_encoding"] = row["size_bytes"], "IDENTITY"
    elif row.get("storage_version") != "internal-v1:" + row["sha256"]:
        raise ValueError("Internal reference version differs from original digest")
    elif row["source_table"] == "attachments" and (
            type(row.get("stored_size_bytes")) is not int or row["stored_size_bytes"] <= 57
            or row.get("storage_encoding") not in ("IDENTITY", "GZIP")):
        raise ValueError("CLEAN attachment storage metadata is unresolved")
    for field in ("id", "owner_id"):
        if row.get(field) is not None:
            row[field] = str(row[field])
    return row


def collect_references(cursor, lock=True) -> list[dict]:
    """Only metadata; never select workbook content, names, previews or business payloads."""
    suffix = " FOR SHARE" if lock else ""
    cursor.execute("SELECT " + ",".join(FIELDS) + " FROM attachments "
                   "WHERE lifecycle_state IN ('CLEAN','RETAINED_HISTORY','DELETE_PENDING','DELETE_FAILED') ORDER BY id" + suffix)
    references = [normalize_reference({**dict(zip(FIELDS, values)), "source_table": "attachments"})
                  for values in cursor.fetchall()]
    fields = ("id", "storage_provider", "storage_key", "storage_version", "size_bytes", "sha256")
    for table in PRIVATE_TABLES:
        cursor.execute("SELECT to_regclass(%s)", ("public." + table,))
        if cursor.fetchone()[0] is None:
            continue  # Backward compatible with pre-V747/V755 databases.
        if table != "goods_cost_imports":
            cursor.execute("SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' "
                           "AND table_name=%s AND column_name='storage_provider')", (table,))
            if not cursor.fetchone()[0]:
                continue  # Pre-V747 workbooks are bytea columns already included in pg_dump.
        # Exact immutable logical identities from the actual schemas, never guessed id columns.
        identity, order = "id", "id"
        size, digest = "storage_size", "storage_sha256"
        if table in ("sales_quote_template_candidates", "ai_input_originals"):
            identity = order = "job_id"
        elif table == "sales_quote_template_versions":
            identity, order = "template_id::text||':'||version::text", "template_id,version"
        elif table == "sales_quote_template_candidate_history":
            # Extract only the archived object's two metadata fields, never select its full original payload.
            size, digest = "(payload->>'storage_size')::bigint", "payload->>'storage_sha256'"
        predicate = "storage_provider IS NOT NULL"
        if table == "ai_input_originals":
            predicate += " AND availability='AVAILABLE' AND lifecycle_state='AVAILABLE'"
        cursor.execute("SELECT " + identity + ",storage_provider,storage_key,storage_version," + size + "," + digest
                       + " FROM public." + table + " WHERE " + predicate + " ORDER BY " + order + suffix)
        references.extend(normalize_reference({**dict(zip(fields, values)), "source_table": table})
                          for values in cursor.fetchall())
    # The canonical view is an independent inventory guard against missing a producer.
    cursor.execute("SELECT to_regclass('public.v_private_document_storage_references')")
    if cursor.fetchone()[0] is not None:
        cursor.execute("SELECT storage_provider,storage_key,storage_version FROM v_private_document_storage_references")
        inventory = set(cursor.fetchall())
        actual = {tuple(row[key] for key in IDENTITY_FIELDS[:3]) for row in references
                  if row["source_table"] != "attachments"}
        if inventory != actual:
            raise ValueError("Private reference inventory is not completely covered")
    unique_references(references)
    return references


def unique_references(references: list[dict]) -> list[dict]:
    objects, identities = {}, set()
    for row in references:
        identity = (row["source_table"], row["id"])
        if identity in identities:
            raise ValueError("Duplicate logical media reference")
        identities.add(identity)
        physical = (row["storage_provider"], relative_key(row["storage_key"]).as_posix())
        previous = objects.get(physical)
        if previous is not None and any(previous.get(key) != row.get(key) for key in IDENTITY_FIELDS):
            raise ValueError("Conflicting identities share one physical object path")
        if previous is not None:
            for key in ("stored_size_bytes", "storage_encoding"):
                if previous.get(key) is not None and row.get(key) is not None and previous[key] != row[key]:
                    raise ValueError("Conflicting storage metadata for one physical object")
        else:
            objects[physical] = row
    return list(objects.values())


def media_final(root: Path, provider: str) -> Path:
    if provider == "internal":
        return root / "final"
    if provider == "local":
        return root / "local" / "final"
    raise ValueError("Unsupported media provider")


def check_object(path: Path, row: dict, max_original: int = 1024**3) -> dict:
    normalize_reference(row)
    if row["storage_provider"] == "internal":
        return check_envelope(path, row, max_original)
    digest, count = hashlib.sha256(), 0
    with open_original(path.parent, Path(path.name)) as stream:
        while chunk := stream.read(CHUNK):
            count += len(chunk)
            if count > min(max_original, row["size_bytes"]):
                raise ValueError("Local object exceeds confirmed original size")
            digest.update(chunk)
    if count != row["size_bytes"] or digest.hexdigest() != row["sha256"]:
        raise ValueError("Local object original digest or size mismatch")
    return {"storage_sha256": digest.hexdigest(), "sha256": digest.hexdigest(), "size_bytes": count,
            "stored_size_bytes": count, "storage_encoding": "IDENTITY", "storage_version": None}


def copy_object(source_root: Path, target_root: Path, row: dict, budget: Budget) -> dict:
    relative = relative_key(row["storage_key"])
    real_directory((source_root / relative).parent)
    confirmed = check_object(source_root / relative, row, budget.config.max_object_bytes)
    row = {**row, **confirmed}
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
            **check_object(target, row, budget.config.max_object_bytes)}


def assert_reference_consistency(cursor, references):
    for row in unique_references(references):
        cursor.execute("SELECT EXISTS (SELECT 1 FROM attachment_object_outbox WHERE operation='DELETE_FINAL' "
                       "AND status NOT IN ('SUCCEEDED','RETAINED_HISTORY') AND storage_key=%s "
                       "AND (storage_provider=%s OR storage_provider='legacy_unknown') "
                       "AND (storage_version IS NOT DISTINCT FROM %s OR storage_version IS NULL))",
                       (row["storage_key"], row["storage_provider"], row["storage_version"]))
        if cursor.fetchone()[0]:
            raise ValueError("Referenced media has a pending physical-delete intent")


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
    check_retention_days(config.retention_days)
    if (not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,62}", config.database)
            or config.postgres_user != "postgres" or not 1 <= config.port <= 65535
            or not 1 <= config.bytes_per_second <= 100 * 1024**2
            or not 5 <= config.max_seconds <= 7200
            or config.min_free_bytes < 0 or not 1 <= config.min_free_percent <= 90
            or not 1 <= config.max_object_bytes <= 1024**3):
        raise ValueError("Invalid backup resource or database configuration")
    source = real_directory(Path(config.media_root))
    real_directory(source / "final")
    if config.local_media_root is not None:
        local = real_directory(Path(config.local_media_root))
        real_directory(local / "final")
        if local == source or local in source.parents or source in local.parents:
            raise ValueError("Local and internal roots must be physically separate")
    destination = real_directory(Path(config.backup_root))
    real_directory(Path(config.socket_directory))
    if (source == destination or source in destination.parents or destination in source.parents
            or destination.stat().st_uid != 0 or destination.stat().st_mode & 0o077):
        raise ValueError("Backup root must be separate and root-only (0700)")
    if config.local_media_root and (local == destination or local in destination.parents or destination in local.parents):
        raise ValueError("Local media and backup roots must be separate")
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
    stored_bytes = original_bytes = 0
    started_at = now()
    try:
        connection.set_session(isolation_level="REPEATABLE READ", readonly=False)
        with connection.cursor() as cursor:
            cursor.execute("SET LOCAL lock_timeout = '5s'")
            cursor.execute("SET LOCAL statement_timeout = '120s'")
            cursor.execute("SET LOCAL idle_in_transaction_session_timeout = %s", (str(config.max_seconds + 60) + "s",))
            assert_consistent(cursor)
            references = collect_references(cursor)
            assert_reference_consistency(cursor, references)
            objects = unique_references(references)
            cursor.execute("SELECT pg_database_size(current_database())")
            budget.check(int(cursor.fetchone()[0]) + sum(row.get("stored_size_bytes") or row["size_bytes"] + 57 for row in objects))
        with (work / "references.jsonl").open("x", encoding="utf-8") as manifest:
            for row in references:
                manifest.write(json.dumps(row, ensure_ascii=False) + "\n")
            manifest.flush()
            os.fsync(manifest.fileno())
        with (work / "objects.jsonl").open("x", encoding="utf-8") as manifest:
            for row in objects:
                provider = row["storage_provider"]
                source = config.media_root if provider == "internal" else config.local_media_root
                if source is None:
                    raise ValueError("Referenced local files require an explicit local_media_root")
                target = media_final(work / "media", provider)
                target.mkdir(parents=True, mode=0o700, exist_ok=True)
                record = copy_object(Path(source) / "final", target, row, budget)
                manifest.write(json.dumps(record, ensure_ascii=False) + "\n")
                stored_bytes += record["stored_size_bytes"]
                original_bytes += record["size_bytes"]
            manifest.flush()
            os.fsync(manifest.fileno())
        with connection.cursor() as cursor:
            assert_consistent(cursor)
            assert_reference_consistency(cursor, references)
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
    summary = {"format": "uten-paired-internal-v2", "set_id": set_id, "database": config.database,
               "started_at": started_at, "completed_at": now(),
               "duration_seconds": round(time.monotonic() - budget.started, 3),
               "postgres_version": server_version, "transaction_snapshot": transaction_snapshot,
               "clean_objects": sum(row["source_table"] == "attachments" for row in references),
               "private_document_references": sum(row["source_table"] != "attachments" for row in references),
               "media_objects": len(objects), "original_bytes": original_bytes, "stored_bytes": stored_bytes,
               "database_dump_bytes": dump_size, "data_bytes": dump_size + stored_bytes,
               "database_dump_sha256": digest_file(work / "database.dump"),
               "objects_manifest_sha256": digest_file(work / "objects.jsonl"),
               "references_manifest_sha256": digest_file(work / "references.jsonl"),
               "resource_limits": dataclasses.asdict(config),
               "retention": ("Automatic after each successful run: keep complete sets dated within the last "
                             + str(config.retention_days) + " server-local calendar days (today included) and "
                             "always at least the " + str(config.retention_days) + " newest complete sets; "
                             "older complete sets beyond both limits and stale unpublished work are removed; "
                             "the success-pointer set and the newest complete set are always kept"),
               "scope": "Database snapshot, CLEAN attachments and all immutable private document references; unfinished uploads must be retried"}
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


def record_attempt(root: Path, status: str, started: str, completed: str | None,
                   retention: dict | None = None) -> None:
    # No set id, database name, object key, path, credentials or exception text; retention is counts only.
    value = {"format": "uten-paired-backup-attempt-v1", "status": status,
             "startedAt": started, "completedAt": completed,
             "lastSuccessAt": last_success_time(root)}
    if retention is not None:
        value["retention"] = retention
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


def log_event(event: str, **fields) -> None:
    # Root-only journal line: set names and byte counts, never business names or file contents.
    print(json.dumps({"event": event, **fields}, ensure_ascii=False, sort_keys=True), file=sys.stderr, flush=True)


def name_time(stamp: str) -> datetime | None:
    """The UTC creation time embedded in a set name; a set's age never comes from mtime."""
    try:
        moment = datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return moment if moment.strftime("%Y%m%dT%H%M%SZ") == stamp else None


def is_link(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def own_real_directory(root: Path, name: str, owner: int) -> bool:
    """A real directory directly in root, owned like root; links and junctions never qualify."""
    try:
        info = os.lstat(root / name)
    except OSError:
        return False
    return not is_link(info) and stat.S_ISDIR(info.st_mode) and info.st_uid == owner


def complete_set_time(root: Path, name: str, owner: int) -> datetime | None:
    """Same publication proof as a normal run: a strict set name whose own manifest names it."""
    match = SET_NAME.fullmatch(name)
    created = name_time(match[1]) if match else None
    if created is None or not own_real_directory(root, name, owner):
        return None
    try:
        with open_original(root, Path(name, "manifest.json")) as stream:
            raw = stream.read(65537)
        summary = json.loads(raw) if len(raw) <= 65536 else None
        if (not isinstance(summary, dict) or summary.get("format") not in SET_FORMATS
                or summary.get("set_id") != name or not isinstance(summary.get("completed_at"), str)
                or datetime.fromisoformat(summary["completed_at"]).tzinfo is None):
            return None
    except (OSError, ValueError):
        return None
    return created


def success_pointer_set(root: Path) -> str | None:
    try:
        with open_original(root, Path("latest-success.json")) as stream:
            raw = stream.read(8193)
        value = json.loads(raw) if len(raw) <= 8192 else None
    except (OSError, ValueError):
        return None
    set_id = value.get("set_id") if isinstance(value, dict) else None
    return set_id if isinstance(set_id, str) and SET_NAME.fullmatch(set_id) else None


def tree_bytes(path: Path) -> int:
    """Apparent size of regular files, never descending through links or junctions."""
    total, pending = 0, [path]
    while pending:
        with os.scandir(pending.pop()) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if is_link(info):
                    continue
                if stat.S_ISDIR(info.st_mode):
                    pending.append(Path(entry.path))
                elif stat.S_ISREG(info.st_mode):
                    total += info.st_size
    return total


def remove_owned_directory(root: Path, name: str, owner: int) -> int:
    """Delete one recognized directory directly inside root; returns the bytes it held."""
    set_match, other = SET_NAME.fullmatch(name), UNPUBLISHED_NAME.fullmatch(name)
    if not (set_match or other):
        raise ValueError("Refusing to delete an unrecognized backup entry")
    target = root / name
    resolved = Path(os.path.realpath(target))
    if (resolved.parent != Path(os.path.realpath(root)) or resolved.name != name
            or not own_real_directory(root, name, owner)):
        raise ValueError("Refusing to delete outside the backup root or through a link")
    if os.name == "posix" and not shutil.rmtree.avoids_symlink_attacks:
        raise OSError("This platform cannot delete a tree without following links")
    size = tree_bytes(target)
    # Leave the published namespace atomically first: an interrupted delete can never look
    # like a valid set, and the next successful run finishes the leftover .expired-* tree.
    doomed = root / (".expired-" + (name if set_match else other[2]))
    if doomed != target:
        os.rename(target, doomed)
    shutil.rmtree(doomed)
    return size


def prune_expired_sets(root: Path, retention_days: int, current: str, moment: datetime | None = None) -> dict:
    """Remove complete sets that are both outside the window and beyond the count floor.

    A complete set is removed only when it is dated retention_days or more local calendar days
    ago AND it is not one of the retention_days newest complete sets. The count floor keeps a
    failure gap or a forward clock jump from collapsing history to a single set (pgBackRest keeps
    by count for the same reason). Only strict set names with their own manifest are candidates.
    The set just published, the success-pointer set and the newest complete set are always kept;
    nothing is deleted unless the new set and the pointer are both recognized as complete. Stale
    .incomplete-* work older than the window and leftover .expired-* trees are removed. Unknown
    names are never touched.
    """
    check_retention_days(retention_days)
    real_directory(root)
    owner = os.lstat(root).st_uid
    moment = moment or datetime.now(timezone.utc).astimezone()
    if moment.tzinfo is None:
        raise ValueError("Retention reference time must be timezone-aware")
    def expired(created: datetime) -> bool:
        return (moment.date() - created.astimezone(moment.tzinfo).date()).days >= retention_days
    complete, stale, unrecognized = {}, [], []
    for name in sorted(os.listdir(root)):
        if SET_NAME.fullmatch(name):
            created = complete_set_time(root, name, owner)
            if created is None:
                unrecognized.append(name)
            else:
                complete[name] = created
            continue
        match = UNPUBLISHED_NAME.fullmatch(name)
        if match is None:
            continue
        created = name_time(match[3])
        if created is None or not own_real_directory(root, name, owner):
            unrecognized.append(name)
        elif match[1] == "expired" or expired(created):
            stale.append(name)
    pointer = success_pointer_set(root)
    if current not in complete or pointer not in complete:
        log_event("paired_backup_retention_skipped", reason="new set or success pointer is not a complete set",
                  retention_days=retention_days, unrecognized=unrecognized)
        return {"removed": [], "failed": [], "freed_bytes": 0, "skipped": True,
                "complete_sets": len(complete), "unrecognized": unrecognized}
    ranked = sorted(complete, key=lambda name: (complete[name], name), reverse=True)
    newest, floor = ranked[0], ranked[:retention_days]
    keep = {current, pointer, *floor}
    expire = [name for name in sorted(complete) if name not in keep and expired(complete[name])]
    log_event("paired_backup_retention_plan", retention_days=retention_days, current=current, pointer=pointer,
              newest=newest, complete_sets=len(complete), kept_by_count=sorted(
                  name for name in floor if expired(complete[name])),
              expire=expire, stale_unpublished=stale, unrecognized=unrecognized)
    removed, failed, freed = [], [], 0
    for name in stale + expire:  # Finish interrupted deletes first; they can never be rescued.
        try:
            size = remove_owned_directory(root, name, owner)
        except InterruptedError:
            raise
        except (OSError, ValueError) as error:
            failed.append({"name": name, "error": type(error).__name__})
            continue
        removed.append({"name": name, "bytes": size})
        freed += size
    result = {"removed": removed, "failed": failed, "freed_bytes": freed, "skipped": False}
    # A failed delete may already have moved its set out of the published namespace.
    remaining = sum(os.path.lexists(root / name) for name in complete)
    log_event("paired_backup_retention_done", remaining_sets=remaining, **result)
    return {**result, "complete_sets": remaining, "unrecognized": unrecognized}


def retain_after_success(root: Path, config: Config, published: Path) -> dict:
    """Runs only after the success state is durable; problems never turn it into a failure.

    Returns the counts-only retention state recorded in last-attempt.json for monitoring, so a
    skipped or failing cleanup is visible instead of silently accumulating sets.
    """
    state = {"status": "FAILED", "retentionDays": config.retention_days}
    try:
        result = prune_expired_sets(root, config.retention_days, published.name)
        state.update(
            status="SKIPPED" if result["skipped"] else ("FAILED" if result["failed"] else "APPLIED"),
            completeSets=result["complete_sets"],
            removedSets=sum(bool(SET_NAME.fullmatch(item["name"])) for item in result["removed"]),
            removedUnpublished=sum(not SET_NAME.fullmatch(item["name"]) for item in result["removed"]),
            failedDeletes=len(result["failed"]), unrecognizedEntries=len(result["unrecognized"]),
            freedBytes=result["freed_bytes"])
    except Exception as error:
        try:
            log_event("paired_backup_retention_failed", error=type(error).__name__, detail=str(error)[:300])
        except Exception:
            pass  # A broken log channel must not turn the recorded success into a failure either.
    return state


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
            completed = now()
            # PENDING until cleanup reports back: a run killed in between stays visible to monitoring.
            record_attempt(root, "SUCCESS", started, completed,
                           {"status": "PENDING", "retentionDays": config.retention_days})
        except BaseException:
            try:
                record_attempt(root, "FAILED", started, now())
            except Exception:
                # A non-writable target cannot promise durable failure status.
                # Keep the previously written RUNNING/unknown state, never forge success.
                print("Paired backup attempt state could not be persisted", file=sys.stderr)
            raise
        # Still under the run lock, so no concurrent run can own an unpublished directory.
        retention = retain_after_success(root, config, published)
        try:
            record_attempt(root, "SUCCESS", started, completed, retention)
        except Exception as error:
            # The durable record keeps PENDING, which monitoring reports once its grace period ends.
            try:
                log_event("paired_backup_retention_state_unwritten", error=type(error).__name__)
            except Exception:
                pass
        return published
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        os.umask(previous_mask)


def read_records(path: Path) -> list[dict]:
    records = []
    with open_original(path.parent, Path(path.name)) as stream:
        while line := stream.readline(16385):
            if len(line) > 16384:
                raise ValueError("Oversized media manifest entry")
            records.append(json.loads(line))
    return records


def verify_media(directory: Path, summary: dict, database_references=None) -> list[dict]:
    """Verify v2 inventory and bytes; optionally prove the restored DB has exactly these references."""
    real_directory(directory)
    if (digest_file(directory / "objects.jsonl") != summary["objects_manifest_sha256"]
            or digest_file(directory / "references.jsonl") != summary["references_manifest_sha256"]):
        raise ValueError("Media inventory digest changed")
    references = [normalize_reference(row) for row in read_records(directory / "references.jsonl")]
    expected = unique_references(references)
    if database_references is not None:
        canonical = lambda rows: sorted(json.dumps(normalize_reference(row), sort_keys=True) for row in rows)
        if canonical(references) != canonical(database_references):
            raise ValueError("Restored database media references differ from the paired inventory")
    objects = read_records(directory / "objects.jsonl")
    unique_references(objects)
    identity = lambda row: tuple(row.get(key) for key in IDENTITY_FIELDS)
    if len(objects) != len(expected) or {identity(row) for row in objects} != {identity(row) for row in expected}:
        raise ValueError("Physical object inventory does not cover all logical references")
    stored = original = 0
    for row in objects:
        relative = relative_key(row["storage_key"])
        if row["relative_path"] != relative.as_posix():
            raise ValueError("Media manifest path differs from its storage key")
        path = media_final(directory / "media", row["storage_provider"]) / relative
        real_directory(path.parent)
        value = check_object(path, row)
        if any(value[key] != row.get(key) for key in value):
            raise ValueError("Stored backup metadata or digest changed")
        stored += value["stored_size_bytes"]
        original += value["size_bytes"]
    counts = (sum(row["source_table"] == "attachments" for row in references),
              sum(row["source_table"] != "attachments" for row in references), len(objects), stored, original)
    if counts != tuple(summary[key] for key in ("clean_objects", "private_document_references", "media_objects", "stored_bytes", "original_bytes")):
        raise ValueError("Paired media reference/object totals differ")
    return objects


def verify_set(directory: Path) -> dict:
    real_directory(directory)
    if (directory / "manifest.json").stat().st_size > 65536:
        raise ValueError("Oversized backup manifest")
    summary = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if (summary["format"] not in ("uten-paired-internal-v1", "uten-paired-internal-v2")
            or digest_file(directory / "database.dump") != summary["database_dump_sha256"]
            or digest_file(directory / "objects.jsonl") != summary["objects_manifest_sha256"]):
        raise ValueError("Backup set manifest/dump integrity failed")
    if summary["format"] == "uten-paired-internal-v2":
        verify_media(directory, summary)
        return summary
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
