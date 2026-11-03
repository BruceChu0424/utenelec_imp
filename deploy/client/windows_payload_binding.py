"""Whole-runtime inventory carried inside the main PE's bounded overlay.

This module parses/binds bytes; windows_authenticode separately establishes
publisher identity when signing is configured/required. An unsigned inventory
proves byte consistency, not publisher authenticity.
No JSON/manifest declaration can substitute for the actual file hashes.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import struct
import time

MAGIC = b"UTEN-PAYLOAD-BINDING-V1\0"
FOOTER_BYTES = 4 + len(MAGIC)
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_FILES = 20000
MAX_CERTIFICATE_BYTES = 16 * 1024 * 1024
MAX_CERTIFICATE_RECORDS = 16
MANIFEST = "uten-client-manifest.json"
FIELDS = {"schemaVersion", "runtimeFamily", "version", "buildNumber", "architecture", "executable", "files"}


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Payload binding contains duplicate JSON keys")
        result[key] = value
    return result


def _path(value):
    try:
        encoded = value.encode("utf-8") if isinstance(value, str) else b""
    except UnicodeError as error:
        raise ValueError("Payload binding runtime path is not valid UTF-8") from error
    if (not isinstance(value, str) or not value or len(value) > 230 or len(encoded) > 920
            or any(ord(character) < 32 for character in value) or any(character in value for character in '\\:<>"|?*')
            or any(part in {"", ".", ".."} or part.endswith((".", " ")) for part in value.split("/"))):
        raise ValueError("Payload binding contains an unsafe runtime path")


def _included(path: str, executable: str) -> bool:
    return path != executable and path != MANIFEST and not path.startswith("client_updater/")


def inventory(metadata: dict, records: list[dict]) -> dict:
    result = {key: metadata[key] for key in FIELDS - {"schemaVersion", "files"}}
    result.update({"schemaVersion": 1, "files": sorted((dict(record) for record in records
                  if _included(record["path"], result["executable"])), key=lambda item: item["path"].encode("utf-8"))})
    validate(result)
    return result


def validate(value: dict) -> None:
    if not isinstance(value, dict) or set(value) != FIELDS or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ValueError("Payload binding schema fields differ")
    if (not isinstance(value["runtimeFamily"], str) or value["runtimeFamily"] not in {"flutter", "wpf_legacy"}
            or not isinstance(value["architecture"], str) or value["architecture"] not in {"x86", "x64", "arm64"}
            or not isinstance(value["version"], str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value["version"])
            or type(value["buildNumber"]) is not int or not 1 <= value["buildNumber"] <= 65535):
        raise ValueError("Payload binding runtime/version/architecture is invalid")
    _path(value["executable"])
    records = value["files"]
    if not isinstance(records, list) or not 1 <= len(records) <= MAX_FILES:
        raise ValueError("Payload binding file count is invalid")
    seen = set()
    previous = None
    for record in records:
        if not isinstance(record, dict) or set(record) != {"path", "size", "sha256"}:
            raise ValueError("Payload binding file record fields differ")
        path = record["path"]
        _path(path)
        encoded = path.encode("utf-8")
        if (not _included(path, value["executable"]) or path.casefold() in seen
                or previous is not None and encoded <= previous):
            raise ValueError("Payload binding file paths are duplicate, excluded or unordered")
        if type(record["size"]) is not int or not 0 <= record["size"] <= 512 * 1024 * 1024:
            raise ValueError("Payload binding file size is invalid")
        if not isinstance(record["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"]):
            raise ValueError("Payload binding file SHA-256 is invalid")
        seen.add(path.casefold())
        previous = encoded


def _layout(stream, size: int):
    from package_windows import _PeReader
    reader = _PeReader(stream, size)
    mapped_end = max([reader.header_size, *(raw + length for _, _, length, raw in reader.sections if length)])
    certificate, certificate_size = reader.directory(4)
    return mapped_end, certificate, certificate_size


def _certificates(stream, offset: int, length: int, size: int):
    if offset % 8 or not 8 <= length <= MAX_CERTIFICATE_BYTES or offset + length != size:
        raise ValueError("Payload binding requires a terminal aligned PE certificate table")
    position = offset
    count = 0
    while position < size:
        count += 1
        if count > MAX_CERTIFICATE_RECORDS:
            raise ValueError("Payload binding PE certificate record count exceeds its bound")
        stream.seek(position)
        header = stream.read(8)
        if len(header) != 8:
            raise ValueError("Payload binding PE certificate record is truncated")
        record_size, revision, kind = struct.unpack("<IHH", header)
        if record_size < 8 or revision != 0x200 or kind != 2 or position + record_size > size:
            raise ValueError("Payload binding PE certificate record is invalid")
        following = position + ((record_size + 7) & ~7)
        if following > size:
            raise ValueError("Payload binding PE certificate padding leaves the table")
        stream.seek(position + record_size)
        if any(stream.read(following - position - record_size)):
            raise ValueError("Payload binding PE certificate padding is not zero")
        position = following


def read(stream, size: int, *, require_signed: bool = True) -> dict:
    mapped_end, certificate, certificate_size = _layout(stream, size)
    if certificate or certificate_size:
        _certificates(stream, certificate, certificate_size, size)
    elif require_signed:
        raise ValueError("Payload binding requires a terminal aligned PE certificate table")
    boundary = certificate if certificate else size
    if boundary < mapped_end + FOOTER_BYTES:
        raise ValueError("Signed main executable is missing its payload binding")
    stream.seek(boundary - FOOTER_BYTES)
    footer = stream.read(FOOTER_BYTES)
    if len(footer) != FOOTER_BYTES or footer[4:] != MAGIC:
        raise ValueError("Signed main executable is missing its payload binding")
    length = struct.unpack_from("<I", footer)[0]
    start = boundary - FOOTER_BYTES - length
    if not 1 <= length <= MAX_JSON_BYTES or not mapped_end <= start <= mapped_end + 7 or boundary % 8:
        raise ValueError("Payload binding envelope is oversized, ambiguous or outside signed PE overlay")
    stream.seek(mapped_end)
    if any(stream.read(start - mapped_end)):
        raise ValueError("Payload binding overlay padding is not zero")
    raw = stream.read(length)
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
    except (UnicodeError, ValueError, TypeError) as error:
        raise ValueError("Payload binding is not strict UTF-8 JSON") from error
    validate(value)
    return value


def write(path: Path, value: dict) -> None:
    """Seal a reviewed private staging main, before its final Authenticode sign."""
    validate(value)
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError("Payload binding exceeds 8 MiB")
    with path.open("r+b") as stream:
        size = path.stat().st_size
        mapped_end, certificate, certificate_size = _layout(stream, size)
        if size != mapped_end:
            # Only a previously well-formed binding may be replaced. Unknown
            # overlays/certificate padding never become a new signed payload.
            read(stream, size, require_signed=bool(certificate))
        if certificate or certificate_size:
            stream.seek(60)
            pe = struct.unpack("<I", stream.read(4))[0]
            stream.seek(pe + 24)
            magic = struct.unpack("<H", stream.read(2))[0]
            stream.seek(pe + 24 + (96 if magic == 0x10b else 112) + 32)
            stream.write(b"\0" * 8)
        stream.truncate(mapped_end)
        stream.seek(mapped_end)
        stream.write(b"\0" * (-(mapped_end + len(raw) + FOOTER_BYTES) % 8))
        stream.write(raw)
        stream.write(struct.pack("<I", len(raw)) + MAGIC)


def verify(stream, size: int, *, metadata: dict, records: list[dict], require_signed: bool = True) -> dict:
    actual = read(stream, size, require_signed=require_signed)
    expected = inventory(metadata, records)
    if actual != expected:
        raise ValueError("Signed executable payload binding differs from the actual complete runtime bytes")
    return {"contract": "uten-windows-payload-binding-v1", "verified": True, "files": len(actual["files"])}


def _hash(stream, deadline: float) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(65536), b""):
        if time.monotonic() >= deadline:
            raise ValueError("Windows payload binding exceeded its whole-package verification deadline")
        digest.update(chunk)
    return digest.hexdigest()


def file_records(files: list[tuple[str, Path]], *, deadline: float | None = None) -> list[dict]:
    deadline = deadline if deadline is not None else time.monotonic() + 120
    result = []
    for relative, path in files:
        with path.open("rb") as stream:
            digest = _hash(stream, deadline)
        result.append({"path": relative, "size": path.stat().st_size, "sha256": digest})
    return result


def verify_sources(files: list[tuple[str, Path]], *, metadata: dict, deadline: float | None = None,
                   require_signed: bool | None = None) -> dict:
    if require_signed is None:
        from windows_authenticode import signing_enabled
        require_signed = signing_enabled()
    deadline = deadline if deadline is not None else time.monotonic() + 120
    main = dict(files)[metadata["executable"]]
    with main.open("rb") as stream:
        return verify(stream, main.stat().st_size, metadata=metadata, records=file_records(files, deadline=deadline),
                      require_signed=require_signed)


def verify_archive(archive, *, metadata: dict, deadline: float | None = None,
                   require_signed: bool | None = None) -> dict:
    if require_signed is None:
        from windows_authenticode import signing_enabled
        require_signed = signing_enabled()
    deadline = deadline if deadline is not None else time.monotonic() + 120
    records = []
    main = None
    for entry in archive.infolist():
        if entry.filename == metadata["executable"]:
            main = entry
        with archive.open(entry) as stream:
            records.append({"path": entry.filename, "size": entry.file_size,
                            "sha256": _hash(stream, deadline)})
    if main is None:
        raise ValueError("Payload binding main executable is missing")
    with archive.open(main) as stream:
        return verify(stream, main.file_size, metadata=metadata, records=records, require_signed=require_signed)
