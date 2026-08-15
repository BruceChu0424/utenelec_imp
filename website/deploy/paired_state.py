#!/usr/bin/env python3
"""Create, verify and restore one SQLite + uploads website recovery point.

The production wrapper must stop website writes and close ingress before calling
``snapshot``.  This tool then copies both state domains into one checksummed,
fsynced directory.  It intentionally never mutates the live state paths.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SNAPSHOT_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}")
MEDIA_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
MEDIA_EXTENSIONS = {".gif", ".jpg", ".jpeg", ".png", ".webp"}
AUTHORITY_UUID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
UPLOAD_PUBLIC_PREFIX = "/uploads/"
SCHEMA_CONTRACT_FORMAT = "uten-website-sqlite-schema-v1"
AUTHORITY_RECEIPT_FORMAT = "uten-website-database-authority-v1"
MAX_FILES = 500_000
MAX_TOTAL_BYTES = 500 * 1024 * 1024 * 1024
LIVE_BOOT_SAMPLE_ENTRIES = 2_048
LIVE_BOOT_SAMPLE_SECONDS = 2.0
LIVE_FULL_VERIFY_SECONDS = 240.0
MAX_PENDING_MEDIA = 64
MAX_PENDING_BYTES = 512 * 1024 * 1024
MAX_PENDING_AGE_SECONDS = 15 * 60
MAX_UNREFERENCED_MEDIA = 128
MAX_UNREFERENCED_BYTES = 1024 * 1024 * 1024
MAX_UNREFERENCED_AGE_SECONDS = 24 * 60 * 60
MEDIA_VERIFY_RETRIES = 3


class StateError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def normalize_schema_sql(value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise StateError("SQLite schema object has no SQL definition")
    normalized = value.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not normalized or "\x00" in normalized:
        raise StateError("SQLite schema SQL is empty or unsafe")
    return normalized


def sqlite_schema_contract(connection: sqlite3.Connection) -> dict[str, Any]:
    rows = connection.execute(
        "SELECT type, name, tbl_name, sql FROM main.sqlite_schema "
        "WHERE type IN ('table', 'index', 'trigger', 'view') "
        "AND name NOT GLOB 'sqlite_*' "
        "AND name <> '_prisma_migrations' "
        "ORDER BY type, name, tbl_name"
    ).fetchall()
    entries = [
        {
            "name": str(name),
            "sql": normalize_schema_sql(sql),
            "tableName": str(table_name),
            "type": str(object_type),
        }
        for object_type, name, table_name, sql in rows
    ]
    if not entries:
        raise StateError("SQLite application schema is empty")
    return {
        "entries": entries,
        "format": SCHEMA_CONTRACT_FORMAT,
        "objectCount": len(entries),
        "sha256": hashlib.sha256(canonical_json(entries)).hexdigest(),
    }


def validate_schema_contract(value: Any) -> dict[str, Any]:
    expected_keys = {"entries", "format", "objectCount", "sha256"}
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise StateError("signed SQLite schema contract key set differs")
    entries = value.get("entries")
    if value.get("format") != SCHEMA_CONTRACT_FORMAT or not isinstance(entries, list) or not entries:
        raise StateError("signed SQLite schema contract identity differs")
    normalized_entries: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"name", "sql", "tableName", "type"}:
            raise StateError("signed SQLite schema entry shape differs")
        object_type = entry.get("type")
        name = entry.get("name")
        table_name = entry.get("tableName")
        sql = entry.get("sql")
        if (
            object_type not in {"table", "index", "trigger", "view"}
            or not isinstance(name, str)
            or not name
            or name.startswith("sqlite_")
            or name == "_prisma_migrations"
            or not isinstance(table_name, str)
            or not table_name
            or table_name == "_prisma_migrations"
        ):
            raise StateError("signed SQLite schema entry identity differs")
        normalized_entries.append({
            "name": name,
            "sql": normalize_schema_sql(sql),
            "tableName": table_name,
            "type": object_type,
        })
    if normalized_entries != sorted(
        normalized_entries, key=lambda item: (item["type"], item["name"], item["tableName"])
    ) or len({(item["type"], item["name"], item["tableName"]) for item in normalized_entries}) != len(normalized_entries):
        raise StateError("signed SQLite schema entries are duplicate or unordered")
    digest = hashlib.sha256(canonical_json(normalized_entries)).hexdigest()
    if value.get("objectCount") != len(normalized_entries) or value.get("sha256") != digest:
        raise StateError("signed SQLite schema digest/count differs")
    return value


def read_signed_manifest(path: Path) -> dict[str, Any]:
    regular_file(path)
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateError("signed manifest is invalid JSON") from exc
    if raw != canonical_json(value) or not isinstance(value, dict):
        raise StateError("signed manifest is not canonical JSON")
    return value


def sha256_file(path: Path, *, deadline: float | None = None) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            if deadline is not None and time.monotonic() >= deadline:
                raise StateError("file byte verification exceeded the reviewed time limit")
            digest.update(chunk)
    return digest.hexdigest()


def regular_file(path: Path, *, nonempty: bool = True) -> os.stat_result:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise StateError(f"not a single-link regular file: {path}")
    if nonempty and info.st_size <= 0:
        raise StateError(f"empty file is not accepted: {path}")
    return info


def real_directory(path: Path) -> os.stat_result:
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or path.is_symlink():
        raise StateError(f"not a real directory: {path}")
    return info


def fsync_directory(path: Path) -> None:
    if os.name == "nt":
        # Windows does not allow opening a directory through os.open. The
        # production runtime is Linux; file-level flushes remain tested here.
        return
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sqlite_evidence(path: Path) -> dict[str, Any]:
    regular_file(path)
    uri = f"file:{path.as_posix()}?mode=ro&immutable=1"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=5)
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        if integrity != [("ok",)]:
            raise StateError("SQLite integrity_check did not return ok")
        application_id = int(connection.execute("PRAGMA application_id").fetchone()[0])
        user_version = int(connection.execute("PRAGMA user_version").fetchone()[0])
        has_history = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='_prisma_migrations'"
        ).fetchone() is not None
        if not has_history:
            raise StateError("SQLite database has no Prisma migration history")
        migrations = connection.execute(
            "SELECT migration_name, checksum FROM _prisma_migrations "
            "WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL ORDER BY migration_name"
        ).fetchall()
        if not migrations:
            raise StateError("SQLite database has no successfully applied Prisma migration")
        connection.close()
    except sqlite3.Error as exc:
        raise StateError(f"cannot validate SQLite database: {exc}") from exc
    migration_lines = "".join(f"{name}\t{checksum}\n" for name, checksum in migrations).encode("utf-8")
    return {
        "applicationId": application_id,
        "prismaMigrationCount": len(migrations),
        "prismaMigrationHistorySha256": hashlib.sha256(migration_lines).hexdigest(),
        "sha256": sha256_file(path),
        "sizeBytes": path.stat().st_size,
        "userVersion": user_version,
    }


def signed_migration_entries(path: Path) -> list[tuple[str, str]]:
    value = read_signed_manifest(path)
    migrations = value.get("migrations")
    entries = migrations.get("entries") if isinstance(migrations, dict) else None
    if not isinstance(entries, list) or migrations.get("count") != len(entries) or not entries:
        raise StateError("signed Prisma migration inventory is invalid")
    result: list[tuple[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"name", "sha256", "sizeBytes"}:
            raise StateError("signed Prisma migration entry shape differs")
        name, checksum, size = entry["name"], entry["sha256"], entry["sizeBytes"]
        if (
            not isinstance(name, str)
            or not re.fullmatch(r"[0-9]{14}_[A-Za-z0-9_]+", name)
            or not isinstance(checksum, str)
            or not re.fullmatch(r"[0-9a-f]{64}", checksum)
            or not isinstance(size, int)
            or size <= 0
        ):
            raise StateError("signed Prisma migration entry value differs")
        result.append((name, checksum))
    if result != sorted(set(result)):
        raise StateError("signed Prisma migration inventory is duplicate or unordered")
    return result


def signed_database_schema(path: Path) -> dict[str, Any]:
    return validate_schema_contract(read_signed_manifest(path).get("databaseSchema"))


def verify_live_database(path: Path, signed_manifest: Path | None = None) -> dict[str, Any]:
    """Exercise SQLite's normal crash recovery path, then verify live schema.

    Unlike recovery-point verification this deliberately does not use
    ``immutable=1``: a clean reboot after an unexpected process or host exit may
    have a hot journal/WAL that SQLite must reconcile as the application user.
    No Prisma migration or application write is performed here.
    """
    regular_file(path)
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(f"file:{path.as_posix()}?mode=rw", uri=True, timeout=30)
        connection.execute("PRAGMA busy_timeout=30000")
        quick = connection.execute("PRAGMA quick_check").fetchall()
        if quick != [("ok",)]:
            raise StateError("live SQLite quick_check did not return ok")
        foreign_keys = connection.execute("PRAGMA foreign_key_check").fetchmany(1)
        if foreign_keys:
            raise StateError("live SQLite foreign_key_check found a violation")
        has_history = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='_prisma_migrations'"
        ).fetchone() is not None
        if not has_history:
            raise StateError("live SQLite database has no Prisma migration history")
        history = connection.execute(
            "SELECT migration_name, checksum, finished_at IS NOT NULL, rolled_back_at IS NOT NULL "
            "FROM _prisma_migrations ORDER BY migration_name, id"
        ).fetchall()
        successful = sum(1 for _, _, finished, rolled_back in history if finished and not rolled_back)
        incomplete = sum(1 for _, _, finished, rolled_back in history if not finished or rolled_back)
        if successful < 1 or incomplete:
            raise StateError("live SQLite Prisma history is empty or incomplete")
        actual_entries = [(str(name), str(checksum)) for name, checksum, _, _ in history]
        if len(actual_entries) != len(set(actual_entries)):
            raise StateError("live SQLite Prisma history contains duplicate rows")
        schema_contract = sqlite_schema_contract(connection)
        if signed_manifest is not None:
            if actual_entries != signed_migration_entries(signed_manifest):
                raise StateError("live SQLite Prisma history differs from signed migration inventory")
            if schema_contract != signed_database_schema(signed_manifest):
                raise StateError("live SQLite application schema differs from signed sqlite_schema contract")
        journal_mode = str(connection.execute("PRAGMA journal_mode").fetchone()[0]).lower()
        if journal_mode != "delete":
            raise StateError("production SQLite journal_mode must be delete so durable evidence is one main file")
    except sqlite3.Error as exc:
        raise StateError(f"cannot recover/validate live SQLite database: {exc}") from exc
    finally:
        if connection is not None:
            connection.close()
    for suffix in ("-journal", "-shm", "-wal"):
        sidecar = Path(str(path) + suffix)
        if sidecar.exists() or sidecar.is_symlink():
            raise StateError(f"live SQLite sidecar remains after recovery/verification: {sidecar}")
    return {
        "journalMode": journal_mode,
        "prismaMigrationCount": successful,
        "prismaMigrationHistorySha256": hashlib.sha256(
            "".join(f"{name}\t{checksum}\n" for name, checksum in actual_entries).encode("utf-8")
        ).hexdigest(),
        "quickCheck": "ok",
        "schemaObjectCount": schema_contract["objectCount"],
        "schemaSha256": schema_contract["sha256"],
    }


def upload_inventory(root: Path, *, deadline: float | None = None) -> tuple[list[dict[str, Any]], int]:
    real_directory(root)
    inventory: list[dict[str, Any]] = []
    total = 0
    for current, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        if deadline is not None and time.monotonic() >= deadline:
            raise StateError("uploads byte verification exceeded the reviewed time limit")
        directory_names.sort()
        file_names.sort()
        for name in list(directory_names):
            if not MEDIA_NAME_RE.fullmatch(name):
                raise StateError(f"unsafe uploads directory name: {name}")
            real_directory(current_path / name)
        for name in file_names:
            if not MEDIA_NAME_RE.fullmatch(name) or Path(name).suffix.lower() not in MEDIA_EXTENSIONS:
                raise StateError(f"unsafe uploads file name/type: {name}")
            source = current_path / name
            info = regular_file(source)
            relative = source.relative_to(root).as_posix()
            total += info.st_size
            if len(inventory) >= MAX_FILES or total > MAX_TOTAL_BYTES:
                raise StateError("uploads inventory exceeds reviewed limits")
            inventory.append({
                "path": relative,
                "sha256": sha256_file(source, deadline=deadline),
                "sizeBytes": info.st_size,
            })
    return inventory, total


def canonical_upload_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) > 500 or not value.startswith(UPLOAD_PUBLIC_PREFIX):
        raise StateError(f"{label} is not a canonical /uploads reference")
    tail = value[len(UPLOAD_PUBLIC_PREFIX):]
    parts = tail.split("/")
    if not tail or len(parts) > 8 or any(not MEDIA_NAME_RE.fullmatch(part) for part in parts):
        raise StateError(f"{label} contains an unsafe uploads path segment")
    if Path(parts[-1]).suffix.lower() not in MEDIA_EXTENSIONS:
        raise StateError(f"{label} has an unsupported uploads media type")
    return value


def _append_media_reference(
    references: list[dict[str, str]], source_type: str, source_id: Any, source_field: str, value: Any
) -> None:
    if value is None or value == "":
        return
    if not isinstance(value, str):
        raise StateError(f"{source_type}.{source_field} is not text")
    if not value.startswith(UPLOAD_PUBLIC_PREFIX):
        return
    references.append({
        "publicPath": canonical_upload_path(value, f"{source_type}.{source_field}"),
        "sourceField": source_field,
        "sourceId": str(source_id),
        "sourceType": source_type,
    })


def _walk_setting_media(value: Any, location: str, result: list[tuple[str, str]]) -> None:
    if isinstance(value, dict):
        for key in sorted(value):
            _walk_setting_media(value[key], f"{location}.{key}", result)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _walk_setting_media(item, f"{location}[{index}]", result)
    elif isinstance(value, str) and value.startswith(UPLOAD_PUBLIC_PREFIX):
        result.append((location, canonical_upload_path(value, location)))


def extract_media_references(connection: sqlite3.Connection) -> list[dict[str, str]]:
    references: list[dict[str, str]] = []
    scalar_fields = [
        ("Series", "coverImage"),
        ("SeriesMedia", "image"),
        ("Product", "image"),
        ("ProductVariant", "image"),
        ("ScenePreset", "backgroundImage"),
        ("LegacyMediaAsset", "publicPath"),
        ("News", "coverImage"),
        ("CaseItem", "coverImage"),
    ]
    for table, field in scalar_fields:
        for source_id, value in connection.execute(f'SELECT "id", "{field}" FROM "{table}"'):
            _append_media_reference(references, table, source_id, field, value)

    for table in ("Product", "ProductVariant"):
        for source_id, raw in connection.execute(f'SELECT "id", "gallery" FROM "{table}"'):
            if raw in (None, ""):
                continue
            try:
                values = json.loads(str(raw))
            except json.JSONDecodeError as exc:
                raise StateError(f"{table}.gallery is invalid JSON") from exc
            if not isinstance(values, list) or any(not isinstance(item, str) for item in values):
                raise StateError(f"{table}.gallery must be a JSON string array")
            for index, item in enumerate(values):
                _append_media_reference(references, table, source_id, f"gallery[{index}]", item)

    for source_id, key, raw in connection.execute('SELECT "id", "key", "i18n" FROM "Setting"'):
        try:
            value = json.loads(str(raw))
        except json.JSONDecodeError as exc:
            raise StateError("Setting.i18n is invalid JSON") from exc
        discovered: list[tuple[str, str]] = []
        _walk_setting_media(value, f"Setting[{key}]", discovered)
        for location, public_path in discovered:
            references.append({
                "publicPath": public_path,
                "sourceField": location,
                "sourceId": str(source_id),
                "sourceType": "Setting",
            })

    references.sort(key=lambda item: (
        item["sourceType"], item["sourceId"], item["sourceField"], item["publicPath"]
    ))
    return references


def read_authority_receipt(path: Path) -> dict[str, Any]:
    regular_file(path)
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateError("database authority receipt is invalid JSON") from exc
    expected = {"authorityUuid", "format", "schemaVersion"}
    if raw != canonical_json(value) or not isinstance(value, dict) or set(value) != expected:
        raise StateError("database authority receipt is non-canonical or has unexpected keys")
    if (
        value.get("format") != AUTHORITY_RECEIPT_FORMAT
        or value.get("schemaVersion") != 1
        or not AUTHORITY_UUID_RE.fullmatch(str(value.get("authorityUuid", "")))
    ):
        raise StateError("database authority receipt identity differs")
    return value


def database_authority(connection: sqlite3.Connection) -> tuple[str, int]:
    rows = connection.execute(
        'SELECT "id", "authorityUuid", "mediaGeneration" FROM "WebsiteStateAuthority" ORDER BY "id"'
    ).fetchall()
    if len(rows) != 1 or rows[0][0] != "production":
        raise StateError("website database authority must contain exactly the production singleton")
    authority_uuid = str(rows[0][1])
    generation = rows[0][2]
    if not AUTHORITY_UUID_RE.fullmatch(authority_uuid) or not isinstance(generation, int) or generation < 0:
        raise StateError("website database authority is unbound or malformed")
    return authority_uuid, generation


def parse_sqlite_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str):
        raise StateError(f"{label} timestamp is invalid")
    candidate = value.replace(" ", "T", 1)
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError as exc:
        raise StateError(f"{label} timestamp is invalid") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def live_media_inventory(
    root: Path,
    pending_paths: set[str],
    *,
    expected_uid: int | None,
    expected_gid: int | None,
    deadline: float,
    hash_bytes: bool,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]], int]:
    real_directory(root)
    committed: list[dict[str, Any]] = []
    pending: dict[str, dict[str, Any]] = {}
    total = 0
    count = 0
    for current, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        if time.monotonic() >= deadline:
            raise StateError("live media verification exceeded the reviewed time limit")
        current_path = Path(current)
        directory_names.sort()
        file_names.sort()
        for name in list(directory_names):
            if not MEDIA_NAME_RE.fullmatch(name):
                raise StateError(f"unsafe uploads directory name: {name}")
            info = real_directory(current_path / name)
            if expected_uid is not None and (
                info.st_uid != expected_uid or info.st_gid != expected_gid or stat.S_IMODE(info.st_mode) != 0o2750
            ):
                raise StateError(f"unsafe live uploads directory ownership/mode: {current_path / name}")
        for name in file_names:
            if not MEDIA_NAME_RE.fullmatch(name) or Path(name).suffix.lower() not in MEDIA_EXTENSIONS:
                raise StateError(f"unsafe uploads file name/type: {name}")
            source = current_path / name
            info = source.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise StateError(f"not a single-link regular media file: {source}")
            if expected_uid is not None and (
                info.st_uid != expected_uid or info.st_gid != expected_gid or stat.S_IMODE(info.st_mode) != 0o640
            ):
                raise StateError(f"unsafe live uploads file ownership/mode: {source}")
            public_path = UPLOAD_PUBLIC_PREFIX + source.relative_to(root).as_posix()
            canonical_upload_path(public_path, "filesystem media")
            count += 1
            total += info.st_size
            if count > MAX_FILES or total > MAX_TOTAL_BYTES:
                raise StateError("uploads inventory exceeds reviewed limits")
            if public_path in pending_paths:
                pending[public_path] = {"sizeBytes": info.st_size}
                continue
            if info.st_size <= 0:
                raise StateError(f"committed media file is empty: {source}")
            committed.append({
                "path": source.relative_to(root).as_posix(),
                "sha256": sha256_file(source, deadline=deadline) if hash_bytes else None,
                "sizeBytes": info.st_size,
            })
    return committed, pending, total


def verify_media_state(
    connection: sqlite3.Connection,
    root: Path,
    expected_authority_uuid: str,
    *,
    allow_inflight: bool,
    expected_uid: int | None,
    expected_gid: int | None,
    metadata_only: bool = False,
) -> dict[str, Any]:
    started = time.monotonic()
    for attempt in range(MEDIA_VERIFY_RETRIES):
        authority_uuid, generation_before = database_authority(connection)
        if authority_uuid != expected_authority_uuid:
            raise StateError("live database authority UUID differs from root-owned approval")
        references = extract_media_references(connection)
        reference_paths = {entry["publicPath"] for entry in references}
        rows = connection.execute(
            'SELECT "publicPath", "authorityId", "sha256", "sizeBytes", "state", "createdAt" '
            'FROM "WebsiteMediaObject" ORDER BY "publicPath"'
        ).fetchall()
        ledger: dict[str, dict[str, Any]] = {}
        pending_paths: set[str] = set()
        now = datetime.now(timezone.utc)
        pending_bytes = 0
        for public_path, authority_id, checksum, size_bytes, state_value, created_at in rows:
            public_path = canonical_upload_path(public_path, "media ledger publicPath")
            if public_path in ledger:
                raise StateError("media ledger contains a duplicate path")
            if authority_id != "production" or not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
                raise StateError("media ledger authority/hash differs")
            if not isinstance(size_bytes, int) or size_bytes <= 0 or state_value not in {"PENDING", "COMMITTED"}:
                raise StateError("media ledger size/state differs")
            age = max(0.0, (now - parse_sqlite_timestamp(created_at, "media ledger")).total_seconds())
            ledger[public_path] = {
                "ageSeconds": age,
                "sha256": checksum,
                "sizeBytes": size_bytes,
                "state": state_value,
            }
            if state_value == "PENDING":
                pending_paths.add(public_path)
                pending_bytes += size_bytes

        if pending_paths and not allow_inflight:
            raise StateError("interrupted PENDING media reservation requires evidence-driven recovery")
        if pending_paths and (
            len(pending_paths) > MAX_PENDING_MEDIA
            or pending_bytes > MAX_PENDING_BYTES
            or any(ledger[path]["ageSeconds"] > MAX_PENDING_AGE_SECONDS for path in pending_paths)
        ):
            raise StateError("PENDING media reservations exceed the active-operation quota/age")
        if reference_paths & pending_paths:
            raise StateError("business data references media that has not reached COMMITTED")

        committed_inventory, pending_files, total_bytes = live_media_inventory(
            root,
            pending_paths,
            expected_uid=expected_uid,
            expected_gid=expected_gid,
            deadline=started + LIVE_FULL_VERIFY_SECONDS,
            hash_bytes=not metadata_only,
        )
        committed_files = {
            UPLOAD_PUBLIC_PREFIX + entry["path"]: entry for entry in committed_inventory
        }
        actual_paths = set(committed_files) | set(pending_files)
        if actual_paths - set(ledger):
            raise StateError("uploads contains a file with no database ledger reservation")
        committed_ledger_paths = {path for path, entry in ledger.items() if entry["state"] == "COMMITTED"}
        if committed_ledger_paths != set(committed_files):
            raise StateError("COMMITTED media ledger and uploads file inventory differ")
        for public_path, file_entry in committed_files.items():
            ledger_entry = ledger[public_path]
            if file_entry["sizeBytes"] != ledger_entry["sizeBytes"] or (
                not metadata_only and file_entry["sha256"] != ledger_entry["sha256"]
            ):
                raise StateError(f"COMMITTED media bytes differ from ledger: {public_path}")
        missing_references = reference_paths - committed_ledger_paths
        if missing_references:
            raise StateError("business media reference has no exact COMMITTED ledger/file")

        unreferenced = sorted(committed_ledger_paths - reference_paths)
        unreferenced_bytes = sum(ledger[path]["sizeBytes"] for path in unreferenced)
        if (
            len(unreferenced) > MAX_UNREFERENCED_MEDIA
            or unreferenced_bytes > MAX_UNREFERENCED_BYTES
        ):
            raise StateError("unreferenced COMMITTED media exceeds the recovery count/byte quota")

        _, generation_after = database_authority(connection)
        if generation_before != generation_after:
            if attempt + 1 == MEDIA_VERIFY_RETRIES:
                raise StateError("media generation changed throughout all bounded verification retries")
            continue
        ledger_evidence = [
            {
                "publicPath": path,
                "sha256": entry["sha256"],
                "sizeBytes": entry["sizeBytes"],
                "state": entry["state"],
            }
            for path, entry in sorted(ledger.items())
        ]
        return {
            "authorityUuid": authority_uuid,
            "fileCount": len(actual_paths),
            "generation": generation_after,
            "ledgerSha256": hashlib.sha256(canonical_json(ledger_evidence)).hexdigest(),
            "pendingCount": len(pending_paths),
            "referenceCount": len(references),
            "referencesSha256": hashlib.sha256(canonical_json(references)).hexdigest(),
            "totalBytes": total_bytes,
            "unreferencedBytes": unreferenced_bytes,
            "unreferencedCount": len(unreferenced),
            "uploadsSha256": (
                None if metadata_only else hashlib.sha256(canonical_json(committed_inventory)).hexdigest()
            ),
            "verificationMode": "metadata" if metadata_only else "full-bytes",
        }
    raise StateError("media verification did not converge")


def bounded_live_upload_check(
    root: Path,
    *,
    max_entries: int = LIVE_BOOT_SAMPLE_ENTRIES,
    max_seconds: float = LIVE_BOOT_SAMPLE_SECONDS,
    expected_uid: int | None = None,
    expected_gid: int | None = None,
) -> dict[str, Any]:
    """Check a fixed boot-time metadata budget without hashing media bytes.

    Full byte inventories belong to paired backup/restore and recovery
    evidence.  Hashing an arbitrarily large media tree from ExecStartPost would
    turn a healthy reboot into a start-limit storm, so the live boot gate checks
    the root plus at most ``max_entries`` entries within ``max_seconds``.
    """
    real_directory(root)
    if max_entries < 1 or max_seconds <= 0:
        raise StateError("live upload sampling budget must be positive")
    deadline = time.monotonic() + max_seconds
    pending = [root]
    sampled = 0
    complete = True
    while pending:
        if sampled >= max_entries or time.monotonic() >= deadline:
            complete = False
            break
        current = pending.pop()
        try:
            iterator = os.scandir(current)
            with iterator:
                for entry in iterator:
                    if sampled >= max_entries or time.monotonic() >= deadline:
                        complete = False
                        break
                    sampled += 1
                    if not MEDIA_NAME_RE.fullmatch(entry.name):
                        raise StateError(f"unsafe live uploads entry name: {entry.name}")
                    # pathlib's lstat is consistent on Windows and POSIX;
                    # some Windows DirEntry implementations report st_nlink=0.
                    info = Path(entry.path).lstat()
                    if stat.S_ISLNK(info.st_mode):
                        raise StateError(f"live uploads contains a symlink: {entry.path}")
                    if stat.S_ISDIR(info.st_mode):
                        if expected_uid is not None and (
                            info.st_uid != expected_uid
                            or info.st_gid != expected_gid
                            or stat.S_IMODE(info.st_mode) != 0o2750
                        ):
                            raise StateError(f"unsafe live uploads directory ownership/mode: {entry.path}")
                        pending.append(Path(entry.path))
                    elif stat.S_ISREG(info.st_mode):
                        if Path(entry.name).suffix.lower() not in MEDIA_EXTENSIONS or info.st_nlink != 1 or info.st_size <= 0:
                            raise StateError(f"unsafe live uploads file metadata: {entry.path}")
                        if expected_uid is not None and (
                            info.st_uid != expected_uid
                            or info.st_gid != expected_gid
                            or stat.S_IMODE(info.st_mode) != 0o640
                        ):
                            raise StateError(f"unsafe live uploads file ownership/mode: {entry.path}")
                    else:
                        raise StateError(f"live uploads contains a special file: {entry.path}")
        except OSError as exc:
            raise StateError(f"cannot sample live uploads: {exc}") from exc
    return {
        "completeInventory": complete,
        "sampledEntries": sampled,
    }


def copy_uploads(source: Path, destination: Path) -> None:
    inventory, _ = upload_inventory(source)
    destination.mkdir(mode=0o750)
    for entry in inventory:
        relative = Path(entry["path"])
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
        with (source / relative).open("rb") as input_file, target.open("xb") as output_file:
            shutil.copyfileobj(input_file, output_file, length=1024 * 1024)
            output_file.flush()
            os.fsync(output_file.fileno())
        os.chmod(target, 0o640)
    for directory, _, _ in os.walk(destination, topdown=False):
        os.chmod(directory, 0o750)
        fsync_directory(Path(directory))


def read_quiescence_receipt(path: Path, database: Path, uploads: Path) -> tuple[dict[str, Any], str]:
    regular_file(path)
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateError("quiescence receipt is invalid JSON") from exc
    if raw != canonical_json(value):
        raise StateError("quiescence receipt is not canonical JSON")
    expected_keys = {"database", "gateClosed", "nonce", "serviceStopped", "uploads"}
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise StateError("quiescence receipt key set differs")
    if value != {
        "database": str(database),
        "gateClosed": True,
        "nonce": value.get("nonce"),
        "serviceStopped": True,
        "uploads": str(uploads),
    } or not isinstance(value.get("nonce"), str) or not re.fullmatch(r"[0-9a-f]{32}", value["nonce"]):
        raise StateError("quiescence receipt does not bind stopped website state")
    return value, hashlib.sha256(raw).hexdigest()


def snapshot(arguments: argparse.Namespace) -> None:
    database = arguments.database.resolve(strict=True)
    uploads = arguments.uploads.resolve(strict=True)
    output = arguments.output.absolute()
    if not SNAPSHOT_RE.fullmatch(arguments.snapshot_id):
        raise StateError("snapshot ID is not canonical")
    if output.exists():
        raise StateError("snapshot output already exists")
    output_parent = output.parent.resolve(strict=True)
    if output_parent.is_symlink() or output_parent in (database.parent, uploads) or output_parent.is_relative_to(uploads):
        raise StateError("snapshot output overlaps live state")
    regular_file(database)
    real_directory(uploads)
    _, quiescence_sha = read_quiescence_receipt(arguments.quiescence_receipt, database, uploads)

    temporary = output_parent / f".{output.name}.partial-{os.getpid()}"
    if temporary.exists():
        raise StateError("snapshot temporary path already exists")
    temporary.mkdir(mode=0o700)
    try:
        database_copy = temporary / "website.db"
        source = sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True, timeout=5)
        destination = sqlite3.connect(database_copy)
        try:
            source.backup(destination)
            destination.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            destination.commit()
        finally:
            destination.close()
            source.close()
        os.chmod(database_copy, 0o600)
        with database_copy.open("r+b") as handle:
            os.fsync(handle.fileno())

        uploads_copy = temporary / "uploads"
        copy_uploads(uploads, uploads_copy)
        inventory, total = upload_inventory(uploads_copy)
        manifest = {
            "createdAtUtc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "database": sqlite_evidence(database_copy),
            "format": "uten-website-paired-state-v1",
            "quiescenceReceiptSha256": quiescence_sha,
            "snapshotId": arguments.snapshot_id,
            "uploads": {
                "fileCount": len(inventory),
                "files": inventory,
                "totalBytes": total,
            },
        }
        manifest_path = temporary / "manifest.json"
        with manifest_path.open("xb") as handle:
            handle.write(canonical_json(manifest))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(manifest_path, 0o600)
        fsync_directory(temporary)
        os.replace(temporary, output)
        fsync_directory(output_parent)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    print(f"WEBSITE_PAIRED_SNAPSHOT_OK id={arguments.snapshot_id} path={output}")


def read_manifest(snapshot_root: Path) -> dict[str, Any]:
    real_directory(snapshot_root)
    actual_top = {entry.name for entry in snapshot_root.iterdir()}
    if actual_top != {"manifest.json", "uploads", "website.db"} or any(entry.is_symlink() for entry in snapshot_root.iterdir()):
        raise StateError("snapshot top-level inventory differs")
    manifest_path = snapshot_root / "manifest.json"
    regular_file(manifest_path)
    raw = manifest_path.read_bytes()
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateError("snapshot manifest is invalid JSON") from exc
    if raw != canonical_json(manifest):
        raise StateError("snapshot manifest is not canonical JSON")
    if not isinstance(manifest, dict) or set(manifest) != {"createdAtUtc", "database", "format", "quiescenceReceiptSha256", "snapshotId", "uploads"}:
        raise StateError("snapshot manifest key set differs")
    if manifest.get("format") != "uten-website-paired-state-v1" or not SNAPSHOT_RE.fullmatch(str(manifest.get("snapshotId", ""))):
        raise StateError("snapshot identity differs")
    if not isinstance(manifest.get("quiescenceReceiptSha256"), str) or not re.fullmatch(
        r"[0-9a-f]{64}", manifest["quiescenceReceiptSha256"]
    ):
        raise StateError("snapshot quiescence receipt digest is invalid")
    return manifest


def verify_snapshot(snapshot_root: Path) -> dict[str, Any]:
    snapshot_root = snapshot_root.resolve(strict=True)
    manifest = read_manifest(snapshot_root)
    database_evidence = sqlite_evidence(snapshot_root / "website.db")
    if manifest.get("database") != database_evidence:
        raise StateError("snapshot database evidence differs from bytes")
    inventory, total = upload_inventory(snapshot_root / "uploads")
    if manifest.get("uploads") != {"fileCount": len(inventory), "files": inventory, "totalBytes": total}:
        raise StateError("snapshot uploads evidence differs from bytes")
    return manifest


def verify_command(arguments: argparse.Namespace) -> None:
    manifest = verify_snapshot(arguments.snapshot)
    print(f"WEBSITE_PAIRED_SNAPSHOT_VERIFIED id={manifest['snapshotId']}")


def schema_contract_command(arguments: argparse.Namespace) -> None:
    database = arguments.database.resolve(strict=True)
    regular_file(database)
    connection = sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True, timeout=30)
    try:
        contract = sqlite_schema_contract(connection)
    finally:
        connection.close()
    output = arguments.output.absolute()
    if output.exists() or output.is_symlink():
        raise StateError("SQLite schema contract output already exists")
    parent = output.parent.resolve(strict=True)
    if parent.is_symlink():
        raise StateError("SQLite schema contract output parent is unsafe")
    with output.open("xb") as handle:
        handle.write(canonical_json(contract))
        handle.flush()
        os.fsync(handle.fileno())
    print(f"WEBSITE_SQLITE_SCHEMA_CONTRACT_OK sha256={contract['sha256']} objects={contract['objectCount']}")


def initialize_authority_command(arguments: argparse.Namespace) -> None:
    database = arguments.database.resolve(strict=True)
    uploads = arguments.uploads.resolve(strict=True)
    authority_receipt = read_authority_receipt(arguments.authority_receipt.resolve(strict=True))
    signed_manifest = arguments.signed_manifest.resolve(strict=True)
    signed_manifest_sha = sha256_file(signed_manifest)
    activation_plan = arguments.activation_plan.resolve(strict=True)
    activation_marker = arguments.activation_marker.resolve(strict=True)
    regular_file(activation_plan)
    regular_file(activation_marker)
    plan_raw = activation_plan.read_bytes()
    marker_raw = activation_marker.read_bytes()
    try:
        plan_value = json.loads(plan_raw.decode("utf-8"))
        marker_value = json.loads(marker_raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateError("activation authority context is invalid JSON") from exc
    plan_sha = hashlib.sha256(plan_raw).hexdigest()
    if (
        plan_raw != canonical_json(plan_value)
        or marker_raw != canonical_json(marker_value)
        or marker_value.get("planSha256") != plan_sha
    ):
        raise StateError("activation authority context is non-canonical or cross-binding differs")
    paired_snapshot = arguments.paired_snapshot.resolve(strict=True)
    snapshot_value = verify_snapshot(paired_snapshot)
    snapshot_manifest = paired_snapshot / "manifest.json"
    snapshot_raw = snapshot_manifest.read_bytes()
    snapshot_connection = sqlite3.connect(
        f"file:{(paired_snapshot / 'website.db').as_posix()}?mode=ro&immutable=1", uri=True, timeout=30
    )
    try:
        snapshot_references = extract_media_references(snapshot_connection)
        snapshot_history = snapshot_connection.execute(
            "SELECT migration_name, checksum FROM _prisma_migrations "
            "WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL ORDER BY migration_name"
        ).fetchall()
    finally:
        snapshot_connection.close()

    if arguments.drop_to_user:
        if os.name == "nt" or os.geteuid() != 0:
            raise StateError("authority initializer privilege drop requires root on POSIX")
        import pwd
        account = pwd.getpwnam(arguments.drop_to_user)
        os.setgroups([])
        os.setgid(account.pw_gid)
        os.setuid(account.pw_uid)
        if os.geteuid() != account.pw_uid or os.getegid() != account.pw_gid:
            raise StateError("authority initializer could not drop to the application identity")

    database_evidence = verify_live_database(database, signed_manifest)
    inventory, total_bytes = upload_inventory(
        uploads, deadline=time.monotonic() + LIVE_FULL_VERIFY_SECONDS
    )
    if snapshot_value["uploads"] != {
        "fileCount": len(inventory),
        "files": inventory,
        "totalBytes": total_bytes,
    }:
        raise StateError("authority binding live uploads differ from the fully verified paired source snapshot")
    files = {UPLOAD_PUBLIC_PREFIX + entry["path"]: entry for entry in inventory}
    expected_uuid = authority_receipt["authorityUuid"]
    connection = sqlite3.connect(f"file:{database.as_posix()}?mode=rw", uri=True, timeout=30)
    try:
        connection.execute("PRAGMA busy_timeout=30000")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("BEGIN IMMEDIATE")
        rows = connection.execute(
            'SELECT "id", "authorityUuid" FROM "WebsiteStateAuthority" ORDER BY "id"'
        ).fetchall()
        if len(rows) != 1 or rows[0][0] != "production" or rows[0][1] not in {"UNBOUND", expected_uuid}:
            raise StateError("database authority cannot be initialized from the approved UUID")
        first_binding = rows[0][1] == "UNBOUND"
        references = extract_media_references(connection)
        if references != snapshot_references:
            raise StateError("authority binding business media references differ from paired source snapshot")
        signed_history = signed_migration_entries(signed_manifest)
        snapshot_history = [(str(name), str(checksum)) for name, checksum in snapshot_history]
        if not snapshot_history or signed_history[:len(snapshot_history)] != snapshot_history:
            raise StateError("paired source Prisma history is not an exact prefix of signed migrations")
        reference_paths = {entry["publicPath"] for entry in references}
        if set(files) != reference_paths:
            raise StateError("initial authority binding requires every upload file to have an exact business reference and no missing reference")
        existing_rows = connection.execute(
            'SELECT "publicPath", "sha256", "sizeBytes", "state" FROM "WebsiteMediaObject" ORDER BY "publicPath"'
        ).fetchall()
        existing = {
            canonical_upload_path(path, "initial media ledger"): {
                "sha256": checksum, "sizeBytes": size, "state": state_value
            }
            for path, checksum, size, state_value in existing_rows
        }
        if set(existing) - set(files):
            raise StateError("initial media ledger contains a path outside the approved paired uploads")
        for public_path, file_entry in sorted(files.items()):
            current = existing.get(public_path)
            expected = {
                "sha256": file_entry["sha256"],
                "sizeBytes": file_entry["sizeBytes"],
                "state": "COMMITTED",
            }
            if current is None:
                if not first_binding:
                    raise StateError("bound database is missing a media ledger row")
                connection.execute(
                    'INSERT INTO "WebsiteMediaObject" '
                    '("publicPath", "authorityId", "sha256", "sizeBytes", "state", "createdAt", "updatedAt") '
                    "VALUES (?, 'production', ?, ?, 'COMMITTED', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
                    (public_path, file_entry["sha256"], file_entry["sizeBytes"]),
                )
            elif current != expected:
                raise StateError(f"initial media ledger bytes/state differ: {public_path}")
        if first_binding:
            connection.execute(
                'UPDATE "WebsiteStateAuthority" SET "authorityUuid"=?, "initializedAt"=CURRENT_TIMESTAMP, '
                '"updatedAt"=CURRENT_TIMESTAMP WHERE "id"=\'production\' AND "authorityUuid"=\'UNBOUND\'',
                (expected_uuid,),
            )
            if connection.execute("SELECT changes()").fetchone()[0] != 1:
                raise StateError("database authority one-time binding lost its compare-and-set")
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    connection = sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True, timeout=30)
    try:
        media_evidence = verify_media_state(
            connection,
            uploads,
            expected_uuid,
            allow_inflight=False,
            expected_uid=None,
            expected_gid=None,
        )
    finally:
        connection.close()
    result = {
        "authorityUuid": expected_uuid,
        "databaseSchemaSha256": database_evidence["schemaSha256"],
        "liveDatabaseSha256": sha256_file(database),
        "firstBinding": first_binding,
        "format": "uten-website-authority-binding-evidence-v1",
        "activationMarkerSha256": hashlib.sha256(marker_raw).hexdigest(),
        "activationPlanSha256": plan_sha,
        "media": media_evidence,
        "pairedSnapshotId": snapshot_value.get("snapshotId"),
        "pairedSnapshotManifestSha256": hashlib.sha256(snapshot_raw).hexdigest(),
        "signedManifestSha256": signed_manifest_sha,
        "toolSha256": sha256_file(Path(__file__).resolve()),
        "totalBytes": total_bytes,
    }
    print(canonical_json(result).decode("utf-8"), end="")


def verify_live_command(arguments: argparse.Namespace) -> None:
    database = arguments.database.resolve(strict=True)
    uploads = arguments.uploads.resolve(strict=True)
    signed_manifest = arguments.signed_manifest.resolve(strict=True)
    authority_receipt = read_authority_receipt(arguments.authority_receipt.resolve(strict=True))
    evidence = verify_live_database(database, signed_manifest)
    try:
        import grp
        media_gid = grp.getgrnam("uten-website-media").gr_gid
    except (ImportError, KeyError) as exc:
        raise StateError("uten-website-media group is unavailable") from exc
    connection = sqlite3.connect(f"file:{database.as_posix()}?mode=ro", uri=True, timeout=30)
    try:
        media_evidence = verify_media_state(
            connection,
            uploads,
            authority_receipt["authorityUuid"],
            allow_inflight=arguments.allow_inflight,
            expected_uid=os.getuid(),
            expected_gid=media_gid,
            metadata_only=arguments.metadata_only,
        )
    finally:
        connection.close()
    value = {
        "database": evidence,
        "format": "uten-website-live-state-v2",
        "media": media_evidence,
    }
    print(canonical_json(value).decode("utf-8"), end="")


def verify_restored_live_command(arguments: argparse.Namespace) -> None:
    database = arguments.database.resolve(strict=True)
    uploads = arguments.uploads.resolve(strict=True)
    for suffix in ("-journal", "-shm", "-wal"):
        sidecar = Path(str(database) + suffix)
        if sidecar.exists() or sidecar.is_symlink():
            raise StateError(f"restored SQLite sidecar must be absent: {sidecar}")
    manifest = verify_snapshot(arguments.snapshot)
    if sqlite_evidence(database) != manifest["database"]:
        raise StateError("restored live database differs from paired snapshot")
    inventory, total = upload_inventory(uploads)
    if manifest["uploads"] != {
        "fileCount": len(inventory),
        "files": inventory,
        "totalBytes": total,
    }:
        raise StateError("restored live uploads differ from paired snapshot")
    print(f"WEBSITE_RESTORED_LIVE_VERIFIED id={manifest['snapshotId']}")


def restore(arguments: argparse.Namespace) -> None:
    snapshot_root = arguments.snapshot.resolve(strict=True)
    manifest = verify_snapshot(snapshot_root)
    destination = arguments.destination.absolute()
    if destination.exists():
        raise StateError("restore destination already exists")
    parent = destination.parent.resolve(strict=True)
    if parent.is_symlink() or parent == snapshot_root or parent.is_relative_to(snapshot_root):
        raise StateError("restore destination overlaps snapshot")
    destination.mkdir(mode=0o700)
    try:
        database_target = destination / "website.db"
        with (snapshot_root / "website.db").open("rb") as source, database_target.open("xb") as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
            target.flush()
            os.fsync(target.fileno())
        os.chmod(database_target, 0o600)
        copy_uploads(snapshot_root / "uploads", destination / "uploads")
        if sqlite_evidence(database_target) != manifest["database"]:
            raise StateError("restored database evidence differs")
        restored_inventory, restored_total = upload_inventory(destination / "uploads")
        if manifest["uploads"] != {"fileCount": len(restored_inventory), "files": restored_inventory, "totalBytes": restored_total}:
            raise StateError("restored uploads evidence differs")
        receipt = {
            "databaseSha256": manifest["database"]["sha256"],
            "format": "uten-website-restore-drill-v1",
            "snapshotId": manifest["snapshotId"],
            "uploadsFileCount": manifest["uploads"]["fileCount"],
        }
        receipt_path = destination / "restore-receipt.json"
        with receipt_path.open("xb") as handle:
            handle.write(canonical_json(receipt))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(receipt_path, 0o600)
        fsync_directory(destination)
        fsync_directory(parent)
    except Exception:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    print(f"WEBSITE_PAIRED_RESTORE_OK id={manifest['snapshotId']} destination={destination}")


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    commands = value.add_subparsers(dest="command", required=True)
    create = commands.add_parser("snapshot")
    create.add_argument("--database", type=Path, required=True)
    create.add_argument("--uploads", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--snapshot-id", required=True)
    create.add_argument("--quiescence-receipt", type=Path, required=True)
    create.set_defaults(handler=snapshot)
    verify = commands.add_parser("verify")
    verify.add_argument("--snapshot", type=Path, required=True)
    verify.set_defaults(handler=verify_command)
    schema_contract = commands.add_parser("schema-contract")
    schema_contract.add_argument("--database", type=Path, required=True)
    schema_contract.add_argument("--output", type=Path, required=True)
    schema_contract.set_defaults(handler=schema_contract_command)
    initialize = commands.add_parser("initialize-authority")
    initialize.add_argument("--database", type=Path, required=True)
    initialize.add_argument("--uploads", type=Path, required=True)
    initialize.add_argument("--authority-receipt", type=Path, required=True)
    initialize.add_argument("--signed-manifest", type=Path, required=True)
    initialize.add_argument("--paired-snapshot", type=Path, required=True)
    initialize.add_argument("--activation-plan", type=Path, required=True)
    initialize.add_argument("--activation-marker", type=Path, required=True)
    initialize.add_argument("--drop-to-user")
    initialize.set_defaults(handler=initialize_authority_command)
    live = commands.add_parser("verify-live")
    live.add_argument("--database", type=Path, required=True)
    live.add_argument("--uploads", type=Path, required=True)
    live.add_argument("--signed-manifest", type=Path, required=True)
    live.add_argument("--authority-receipt", type=Path, required=True)
    live.add_argument("--allow-inflight", action="store_true")
    live.add_argument("--metadata-only", action="store_true")
    live.set_defaults(handler=verify_live_command)
    restored = commands.add_parser("verify-restored-live")
    restored.add_argument("--snapshot", type=Path, required=True)
    restored.add_argument("--database", type=Path, required=True)
    restored.add_argument("--uploads", type=Path, required=True)
    restored.set_defaults(handler=verify_restored_live_command)
    restore_parser = commands.add_parser("restore")
    restore_parser.add_argument("--snapshot", type=Path, required=True)
    restore_parser.add_argument("--destination", type=Path, required=True)
    restore_parser.set_defaults(handler=restore)
    return value


def main() -> int:
    try:
        arguments = parser().parse_args()
        arguments.handler(arguments)
        return 0
    except (StateError, FileNotFoundError, OSError, sqlite3.Error) as exc:
        print(f"WEBSITE_PAIRED_STATE_REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
