#!/usr/bin/env python3
"""Build deterministic Uten IMP release metadata without third-party modules."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import stat
import sys
import urllib.parse
import uuid
import zipfile
from pathlib import Path
from typing import Any, Iterable, NoReturn


PRODUCT = "uten-imp"
MANIFEST_SCHEMA_VERSION = 1
VERSION_RE = re.compile(
    r"^v(?P<year>[0-9]{4})\.(?P<month>[0-9]{2})\.(?P<day>[0-9]{2})-(?P<counter>[0-9]{1,3})$"
)
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
MIGRATION_RE = re.compile(r"^V(?P<version>[0-9]+)__(?P<description>.+)\.sql$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_PAYLOAD_ROOTS = frozenset({"server", "web", "sbom"})
MAX_CHECKSUMS_BYTES = 16 * 1024 * 1024
INDEX_VERSION_TOKEN = "__UTEN_RELEASE_VERSION__"
INDEX_VERSION_META = (
    '<meta name="uten-release-version" content="__UTEN_RELEASE_VERSION__">'
)
FLUTTER_WEB_GENERATOR_VERSION = "3.44.2"
FLUTTER_WEB_PACKAGE_METADATA = {
    "app_name": "uten_imp",
    "version": "0.1.0",
    "build_number": "1",
    "package_name": "uten_imp",
}
# Flutter 3.44.2's WebReleaseBundle writes jsonEncode(getVersionInfo()) without
# whitespace or a trailing newline, preserving the literal map insertion order.
# Pinning the complete bytes prevents a pre-existing arbitrary version.json from
# being laundered into signed release metadata.
FLUTTER_WEB_PACKAGE_METADATA_BYTES = (
    b'{"app_name":"uten_imp","version":"0.1.0","build_number":"1",'
    b'"package_name":"uten_imp"}'
)
MAX_WEB_INDEX_BYTES = 16 * 1024 * 1024
MAX_FLUTTER_VERSION_BYTES = 4 * 1024
WEB_STAMP_TRANSACTION_FILE = ".uten-web-release-stamp-in-progress.json"
MAX_WEB_STAMP_TRANSACTION_BYTES = 16 * 1024
FLYWAY_CHECKSUM_HEADER = "# uten-imp-flyway-checksums-v1"
MIGRATOR_APPLICATION_CLASSES = frozenset(
    {
        "com/uten/imp/migration/UtenImpMigrator.class",
        "com/uten/imp/migration/UtenImpMigrator$1.class",
        "com/uten/imp/migration/UtenImpMigrator$MigrationActions.class",
        "com/uten/imp/migration/UtenImpMigrator$MigrationActionsFactory.class",
        "com/uten/imp/migration/AppliedMigrationCompatibilityCallback.class",
        "com/uten/imp/migration/AuditFreshStartGuardCallback.class",
    }
)
MIGRATOR_FORBIDDEN_CLASS_PREFIXES = (
    "org/springframework/",
    "jakarta/servlet/",
    "org/apache/tomcat/",
)


class ReleaseMetadataError(ValueError):
    """Raised for malformed or unsafe release metadata."""


def fail(message: str) -> NoReturn:
    raise ReleaseMetadataError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_version(version: str) -> int:
    match = VERSION_RE.fullmatch(version)
    if not match:
        fail("version must match vYYYY.MM.DD-N (counter 1..999)")
    counter = int(match.group("counter"))
    if counter < 1 or match.group("counter") != str(counter):
        fail("release counter must be canonical and at least 1")
    try:
        calendar_day = dt.date(
            int(match.group("year")),
            int(match.group("month")),
            int(match.group("day")),
        )
    except ValueError as exc:
        raise ReleaseMetadataError(f"invalid release date: {exc}") from exc
    return int(calendar_day.strftime("%Y%m%d")) * 1000 + counter


def validate_commit(commit_sha: str) -> str:
    normalized = commit_sha.lower()
    if not COMMIT_RE.fullmatch(normalized):
        fail("commit SHA must contain exactly 40 hexadecimal characters")
    return normalized


def validate_timestamp(value: str) -> str:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ReleaseMetadataError(f"invalid ISO-8601 timestamp: {value}") from exc
    if parsed.tzinfo is None:
        fail("timestamp must include a timezone")
    return parsed.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = canonical_json_bytes(value)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("xb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _file_identity(details: os.stat_result) -> tuple[int, ...]:
    return (
        details.st_dev,
        details.st_ino,
        details.st_mode,
        details.st_nlink,
        details.st_uid,
        details.st_gid,
        details.st_size,
        details.st_mtime_ns,
        details.st_ctime_ns,
    )


def _directory_identity(details: os.stat_result) -> tuple[int, ...]:
    return (
        details.st_dev,
        details.st_ino,
        details.st_mode,
        details.st_uid,
        details.st_gid,
    )


def _open_stable_web_root(web_root: Path) -> tuple[int, tuple[int, ...]]:
    if os.name != "posix" or not hasattr(os, "O_NOFOLLOW"):
        fail("web release stamping requires the reviewed POSIX build environment")
    try:
        before = os.lstat(web_root)
    except OSError as exc:
        raise ReleaseMetadataError("web output root is missing or cannot be inspected") from exc
    if not stat.S_ISDIR(before.st_mode) or before.st_mode & 0o022:
        fail("web output root must be a real non-group/world-writable directory")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | os.O_NOFOLLOW
    )
    try:
        descriptor = os.open(web_root, flags)
    except OSError as exc:
        raise ReleaseMetadataError("web output root cannot be captured safely") from exc
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or _directory_identity(opened) != _directory_identity(before)
    ):
        os.close(descriptor)
        fail("web output root changed while it was being captured")
    return descriptor, _directory_identity(opened)


def _read_stable_web_file(
    directory_fd: int,
    name: str,
    *,
    label: str,
    maximum_bytes: int,
    exact_mode: int = 0o644,
) -> tuple[bytes, tuple[int, ...]]:
    try:
        before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as exc:
        raise ReleaseMetadataError(f"{label} is missing or cannot be inspected") from exc
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or stat.S_IMODE(before.st_mode) != exact_mode
        or before.st_size < 1
        or before.st_size > maximum_bytes
    ):
        fail(
            f"{label} must be a stable single-link mode {exact_mode:04o} regular file "
            "within the reviewed size limit"
        )
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=directory_fd)
    except OSError as exc:
        raise ReleaseMetadataError(f"{label} cannot be opened without following links") from exc
    try:
        opened = os.fstat(descriptor)
        if _file_identity(opened) != _file_identity(before):
            fail(f"{label} changed while it was being opened")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum_bytes:
                fail(f"{label} exceeds the reviewed size limit")
        after = os.fstat(descriptor)
        if _file_identity(after) != _file_identity(opened):
            fail(f"{label} changed while its bytes were being captured")
    finally:
        os.close(descriptor)
    try:
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as exc:
        raise ReleaseMetadataError(f"{label} disappeared after capture") from exc
    identity = _file_identity(opened)
    if _file_identity(current) != identity:
        fail(f"{label} path changed after its bytes were captured")
    return b"".join(chunks), identity


def _write_new_web_file(
    directory_fd: int,
    name: str,
    *,
    encoded: bytes,
    mode: int,
    label: str,
) -> tuple[int, ...]:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | os.O_NOFOLLOW
    )
    try:
        descriptor = os.open(name, flags, mode, dir_fd=directory_fd)
    except OSError as exc:
        raise ReleaseMetadataError(f"{label} cannot be created exclusively") from exc
    try:
        view = memoryview(encoded)
        written = 0
        while written < len(view):
            count = os.write(descriptor, view[written:])
            if count <= 0:
                fail(f"{label} write did not make progress")
            written += count
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        identity = _file_identity(os.fstat(descriptor))
    finally:
        os.close(descriptor)
    os.fsync(directory_fd)
    observed, observed_identity = _read_stable_web_file(
        directory_fd,
        name,
        label=label,
        maximum_bytes=max(len(encoded), 1),
        exact_mode=mode,
    )
    if observed != encoded or observed_identity != identity:
        fail(f"{label} differs after durable publication")
    return observed_identity


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _strict_canonical_json_object(raw: bytes, label: str) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                fail(f"{label} contains a duplicate JSON key")
            result[key] = value
        return result

    def reject_constant(value: str) -> NoReturn:
        fail(f"{label} contains a non-finite JSON number: {value}")

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReleaseMetadataError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict) or canonical_json_bytes(value) != raw:
        fail(f"{label} is not one canonical JSON object")
    return value


def _web_entry_exists(directory_fd: int, name: str, label: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise ReleaseMetadataError(f"{label} cannot be inspected") from exc
    return True


def _stamped_index_from_preimage(index_bytes: bytes, version: str) -> bytes:
    try:
        source = index_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ReleaseMetadataError("built web index.html is not UTF-8 text") from exc
    if source.count(INDEX_VERSION_TOKEN) != 1 or source.count(INDEX_VERSION_META) != 1:
        fail("built web index must contain the exact release-version meta token once")
    stamped_meta = INDEX_VERSION_META.replace(INDEX_VERSION_TOKEN, version)
    stamped = source.replace(INDEX_VERSION_META, stamped_meta)
    if INDEX_VERSION_TOKEN in stamped or stamped.count(stamped_meta) != 1:
        fail("web release-version meta stamping was not canonical")
    return stamped.encode("utf-8")


def _validate_stamped_index(index_bytes: bytes, version: str) -> None:
    expected_meta = INDEX_VERSION_META.replace(INDEX_VERSION_TOKEN, version).encode(
        "ascii"
    )
    if index_bytes.count(expected_meta) != 1 or INDEX_VERSION_TOKEN.encode("ascii") in index_bytes:
        fail("rewritten web index.html release identity is not canonical")


def _web_stamp_transaction_value(
    *,
    version: str,
    commit_sha: str,
    sequence: int,
    index_preimage: bytes,
    index_final: bytes,
    version_final: bytes,
) -> dict[str, Any]:
    return {
        "commitSha": commit_sha,
        "flutterGeneratorVersion": FLUTTER_WEB_GENERATOR_VERSION,
        "flutterVersionPreimageSha256": _sha256_bytes(
            FLUTTER_WEB_PACKAGE_METADATA_BYTES
        ),
        "indexFinalSha256": _sha256_bytes(index_final),
        "indexPreimageSha256": _sha256_bytes(index_preimage),
        "releaseSequence": sequence,
        "schemaVersion": 1,
        "status": "STAMPING_WEB_RELEASE_METADATA",
        "version": version,
        "versionFinalSha256": _sha256_bytes(version_final),
    }


def _validate_web_stamp_transaction(
    value: dict[str, Any],
    *,
    version: str,
    commit_sha: str,
    sequence: int,
    version_final: bytes,
) -> None:
    expected_keys = {
        "commitSha",
        "flutterGeneratorVersion",
        "flutterVersionPreimageSha256",
        "indexFinalSha256",
        "indexPreimageSha256",
        "releaseSequence",
        "schemaVersion",
        "status",
        "version",
        "versionFinalSha256",
    }
    if set(value) != expected_keys:
        fail("web stamp transaction schema is not exact")
    if (
        type(value.get("schemaVersion")) is not int
        or value.get("schemaVersion") != 1
        or type(value.get("releaseSequence")) is not int
        or value.get("status") != "STAMPING_WEB_RELEASE_METADATA"
        or value.get("flutterGeneratorVersion") != FLUTTER_WEB_GENERATOR_VERSION
        or value.get("version") != version
        or value.get("commitSha") != commit_sha
        or value.get("releaseSequence") != sequence
        or value.get("flutterVersionPreimageSha256")
        != _sha256_bytes(FLUTTER_WEB_PACKAGE_METADATA_BYTES)
        or value.get("versionFinalSha256") != _sha256_bytes(version_final)
    ):
        fail("web stamp transaction differs from the requested release")
    for key in (
        "flutterVersionPreimageSha256",
        "indexFinalSha256",
        "indexPreimageSha256",
        "versionFinalSha256",
    ):
        if not isinstance(value.get(key), str) or not SHA256_RE.fullmatch(value[key]):
            fail(f"web stamp transaction {key} is not a canonical SHA-256")
    if value["indexFinalSha256"] == value["indexPreimageSha256"]:
        fail("web stamp transaction does not describe an index transition")


def _verify_terminal_web_stamp(
    directory_fd: int,
    *,
    transaction: dict[str, Any],
    version: str,
    version_final: bytes,
) -> None:
    index_bytes, index_identity = _read_stable_web_file(
        directory_fd,
        "index.html",
        label="terminal web index.html",
        maximum_bytes=MAX_WEB_INDEX_BYTES,
    )
    version_bytes, version_identity = _read_stable_web_file(
        directory_fd,
        "version.json",
        label="terminal web version.json",
        maximum_bytes=MAX_FLUTTER_VERSION_BYTES,
    )
    _validate_stamped_index(index_bytes, version)
    if _sha256_bytes(index_bytes) != transaction["indexFinalSha256"]:
        fail("terminal web index.html differs from the stamp transaction")
    if version_bytes != version_final:
        fail("terminal web version.json differs from the requested release")
    for name, label, expected_identity in (
        ("index.html", "terminal web index.html", index_identity),
        ("version.json", "terminal web version.json", version_identity),
    ):
        try:
            current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError as exc:
            raise ReleaseMetadataError(
                f"{label} disappeared during joint terminal verification"
            ) from exc
        if _file_identity(current) != expected_identity:
            fail(f"{label} changed during joint terminal verification")


def _durable_remove_web_stamp_transaction(
    directory_fd: int, expected_identity: tuple[int, ...]
) -> None:
    try:
        current = os.stat(
            WEB_STAMP_TRANSACTION_FILE,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
    except OSError as exc:
        raise ReleaseMetadataError("web stamp transaction disappeared before commit") from exc
    if _file_identity(current) != expected_identity:
        fail("web stamp transaction path changed before commit")
    os.unlink(WEB_STAMP_TRANSACTION_FILE, dir_fd=directory_fd)
    os.fsync(directory_fd)
    if _web_entry_exists(
        directory_fd, WEB_STAMP_TRANSACTION_FILE, "web stamp transaction"
    ):
        fail("web stamp transaction reappeared after durable commit")


def _atomic_replace_captured_web_file(
    directory_fd: int,
    name: str,
    *,
    expected_identity: tuple[int, ...],
    encoded: bytes,
    label: str,
) -> None:
    temporary_name = f".{name}.stamp-{os.getpid()}"
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | os.O_NOFOLLOW
    )
    created = False
    try:
        try:
            descriptor = os.open(temporary_name, flags, 0o600, dir_fd=directory_fd)
            created = True
        except OSError as exc:
            raise ReleaseMetadataError(f"{label} temporary output cannot be created safely") from exc
        try:
            view = memoryview(encoded)
            written = 0
            while written < len(view):
                count = os.write(descriptor, view[written:])
                if count <= 0:
                    fail(f"{label} temporary output write did not make progress")
                written += count
            os.fchmod(descriptor, 0o644)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError as exc:
            raise ReleaseMetadataError(f"{label} disappeared before replacement") from exc
        if _file_identity(current) != expected_identity:
            fail(f"{label} path changed before replacement")
        os.replace(
            temporary_name,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        created = False
        os.fsync(directory_fd)
        observed, _identity = _read_stable_web_file(
            directory_fd,
            name,
            label=f"rewritten {label}",
            maximum_bytes=max(len(encoded), 1),
        )
        if observed != encoded:
            fail(f"rewritten {label} bytes differ from the signed release metadata")
    finally:
        if created:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
                os.fsync(directory_fd)
            except FileNotFoundError:
                pass


def safe_relative_path(path: Path, root: Path) -> str:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError as exc:
        raise ReleaseMetadataError(f"payload path escapes the release root: {path}") from exc
    if not relative or relative.startswith("/"):
        fail(f"invalid payload path: {relative!r}")
    if any(part in ("", ".", "..") for part in relative.split("/")):
        fail(f"unsafe payload path: {relative!r}")
    if "\\" in relative or any(
        ord(character) < 0x20 or ord(character) == 0x7F for character in relative
    ):
        fail(f"unsupported payload path characters: {relative!r}")
    if relative.split("/", 1)[0] not in ALLOWED_PAYLOAD_ROOTS:
        fail(f"unexpected payload root: {relative!r}")
    return relative


def iter_payload_files(root: Path) -> Iterable[tuple[str, Path]]:
    if not root.is_dir() or root.is_symlink():
        fail(f"payload root is not a real directory: {root}")
    for path in root.rglob("*"):
        if path.is_symlink():
            fail(f"payload must not contain symbolic links: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            fail(f"payload contains a non-regular file: {path}")
        if path.name == "SHA256SUMS" and path.parent == root:
            continue
        yield safe_relative_path(path, root), path


def require_payload_shape(root: Path, files: list[tuple[str, Path]]) -> None:
    names = {name for name, _ in files}
    jars = sorted(name for name in names if name.startswith("server/") and name.endswith(".jar"))
    if jars != ["server/uten-imp-migrator.jar", "server/uten-imp-server.jar"]:
        fail(
            "payload must contain exactly server/uten-imp-server.jar and "
            "server/uten-imp-migrator.jar"
        )
    for required in (
        "web/index.html",
        "web/version.json",
        "sbom/backend.cdx.json",
        "sbom/flutter.cdx.json",
    ):
        if required not in names:
            fail(f"payload is missing {required}")
    if any(name.startswith("deploy/") for name in names):
        fail("deployment scripts must never be shipped in the application payload")


def write_checksums(root: Path, output: Path) -> None:
    files = sorted(iter_payload_files(root), key=lambda item: item[0].encode("utf-8"))
    require_payload_shape(root, files)
    lines = [f"{sha256_file(path)}  {name}\n" for name, path in files]
    temporary = output.with_name(f".{output.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as handle:
            handle.writelines(lines)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def read_checksums(root: Path) -> list[dict[str, Any]]:
    checksums_path = root / "SHA256SUMS"
    if not checksums_path.is_file() or checksums_path.is_symlink():
        fail("payload SHA256SUMS is missing or unsafe")
    if checksums_path.stat().st_size > MAX_CHECKSUMS_BYTES:
        fail("payload SHA256SUMS exceeds the allowed size")
    entries: list[dict[str, Any]] = []
    seen: set[str] = set()
    try:
        checksum_lines = checksums_path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ReleaseMetadataError("payload SHA256SUMS is not UTF-8 text") from exc
    for line_number, raw_line in enumerate(checksum_lines, start=1):
        if len(raw_line) < 67 or raw_line[64:66] != "  ":
            fail(f"malformed SHA256SUMS line {line_number}")
        digest = raw_line[:64]
        name = raw_line[66:]
        if not SHA256_RE.fullmatch(digest):
            fail(f"invalid SHA-256 on line {line_number}")
        path = root / Path(name)
        normalized = safe_relative_path(path, root)
        if normalized != name or name in seen:
            fail(f"duplicate or non-canonical checksum path: {name!r}")
        if not path.is_file() or path.is_symlink():
            fail(f"checksummed payload file is missing or unsafe: {name}")
        if sha256_file(path) != digest:
            fail(f"payload checksum mismatch while building manifest: {name}")
        seen.add(name)
        entries.append({"path": name, "sha256": digest, "sizeBytes": path.stat().st_size})
    actual_files = {name for name, _ in iter_payload_files(root)}
    if seen != actual_files:
        missing = sorted(actual_files - seen)
        extra = sorted(seen - actual_files)
        fail(f"SHA256SUMS coverage mismatch; missing={missing}, extra={extra}")
    return entries


def build_flutter_sbom(args: argparse.Namespace) -> None:
    source = json.loads(args.input.read_text(encoding="utf-8"))
    packages = source.get("packages")
    if not isinstance(packages, list) or not packages:
        fail("dart pub deps JSON does not contain packages")
    components: list[dict[str, Any]] = []
    dependencies: list[dict[str, Any]] = []
    refs: dict[str, str] = {}
    package_by_name: dict[str, dict[str, Any]] = {}
    for package in packages:
        if not isinstance(package, dict):
            fail("dart pub deps package entry is not an object")
        name = package.get("name")
        version = package.get("version")
        if not isinstance(name, str) or not name or not isinstance(version, str) or not version:
            fail("dart pub deps package is missing name/version")
        if name in package_by_name:
            fail(f"duplicate Dart package in dependency graph: {name}")
        package_by_name[name] = package
        ref = f"pkg:pub/{urllib.parse.quote(name, safe='')}@{urllib.parse.quote(version, safe='')}"
        refs[name] = ref
        if package.get("kind") != "root":
            component: dict[str, Any] = {
                "bom-ref": ref,
                "name": name,
                "purl": ref,
                "type": "library",
                "version": version,
            }
            source_kind = package.get("source")
            if isinstance(source_kind, str) and source_kind:
                component["properties"] = [
                    {"name": "uten:dart:source", "value": source_kind}
                ]
            components.append(component)
    for name, package in package_by_name.items():
        dependency_names = package.get("dependencies", [])
        if not isinstance(dependency_names, list) or not all(
            isinstance(value, str) for value in dependency_names
        ):
            fail(f"invalid dependency list for Dart package {name}")
        dependencies.append(
            {
                "ref": refs[name],
                "dependsOn": sorted(
                    refs[value] for value in dependency_names if value in refs
                ),
            }
        )
    version = args.version
    commit_sha = validate_commit(args.commit)
    timestamp = validate_timestamp(args.timestamp)
    serial_seed = f"{PRODUCT}:{version}:{commit_sha}:flutter"
    sbom = {
        "bomFormat": "CycloneDX",
        "components": sorted(components, key=lambda item: item["bom-ref"]),
        "dependencies": sorted(dependencies, key=lambda item: item["ref"]),
        "metadata": {
            "component": {
                "bom-ref": refs.get(source.get("root", ""), f"urn:uten:{PRODUCT}:flutter"),
                "name": "uten-imp-flutter-web",
                "type": "application",
                "version": version,
            },
            "properties": [
                {"name": "uten:git:commit", "value": commit_sha},
            ],
            "timestamp": timestamp,
        },
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, serial_seed)}",
        "specVersion": "1.6",
        "version": 1,
    }
    write_json(args.output, sbom)


def stamp_web_release(args: argparse.Namespace) -> None:
    version = args.version
    sequence = validate_version(version)
    commit_sha = validate_commit(args.commit)
    release_version_bytes = canonical_json_bytes(
        {
            "commitSha": commit_sha,
            "product": PRODUCT,
            "releaseSequence": sequence,
            "schemaVersion": 1,
            "version": version,
        }
    )
    web_root = args.web_root
    directory_fd, root_identity = _open_stable_web_root(web_root)
    try:
        index_bytes, index_identity = _read_stable_web_file(
            directory_fd,
            "index.html",
            label="built web index.html",
            maximum_bytes=MAX_WEB_INDEX_BYTES,
        )
        flutter_version_bytes, flutter_version_identity = _read_stable_web_file(
            directory_fd,
            "version.json",
            label="Flutter-generated web version.json",
            maximum_bytes=MAX_FLUTTER_VERSION_BYTES,
        )
        transaction_exists = _web_entry_exists(
            directory_fd,
            WEB_STAMP_TRANSACTION_FILE,
            "web stamp transaction",
        )
        if transaction_exists:
            transaction_bytes, transaction_identity = _read_stable_web_file(
                directory_fd,
                WEB_STAMP_TRANSACTION_FILE,
                label="web stamp transaction",
                maximum_bytes=MAX_WEB_STAMP_TRANSACTION_BYTES,
                exact_mode=0o600,
            )
            transaction = _strict_canonical_json_object(
                transaction_bytes, "web stamp transaction"
            )
            _validate_web_stamp_transaction(
                transaction,
                version=version,
                commit_sha=commit_sha,
                sequence=sequence,
                version_final=release_version_bytes,
            )

            index_digest = _sha256_bytes(index_bytes)
            if index_digest == transaction["indexPreimageSha256"]:
                stamped_index_bytes = _stamped_index_from_preimage(index_bytes, version)
                if _sha256_bytes(stamped_index_bytes) != transaction["indexFinalSha256"]:
                    fail("web index preimage does not produce the recorded transaction output")
                replace_index = True
            elif index_digest == transaction["indexFinalSha256"]:
                _validate_stamped_index(index_bytes, version)
                stamped_index_bytes = index_bytes
                replace_index = False
            else:
                fail("web index differs from both states bound by the stamp transaction")

            if flutter_version_bytes == FLUTTER_WEB_PACKAGE_METADATA_BYTES:
                replace_version = True
            elif flutter_version_bytes == release_version_bytes:
                replace_version = False
            else:
                fail("web version differs from both states bound by the stamp transaction")
        else:
            if flutter_version_bytes != FLUTTER_WEB_PACKAGE_METADATA_BYTES:
                fail(
                    "Flutter-generated web version.json differs from the reviewed "
                    f"Flutter {FLUTTER_WEB_GENERATOR_VERSION} package metadata bytes"
                )
            stamped_index_bytes = _stamped_index_from_preimage(index_bytes, version)
            transaction = _web_stamp_transaction_value(
                version=version,
                commit_sha=commit_sha,
                sequence=sequence,
                index_preimage=index_bytes,
                index_final=stamped_index_bytes,
                version_final=release_version_bytes,
            )
            transaction_identity = _write_new_web_file(
                directory_fd,
                WEB_STAMP_TRANSACTION_FILE,
                encoded=canonical_json_bytes(transaction),
                mode=0o600,
                label="web stamp transaction",
            )
            replace_index = True
            replace_version = True

        if replace_index:
            _atomic_replace_captured_web_file(
                directory_fd,
                "index.html",
                expected_identity=index_identity,
                encoded=stamped_index_bytes,
                label="built web index.html",
            )
        if replace_version:
            _atomic_replace_captured_web_file(
                directory_fd,
                "version.json",
                expected_identity=flutter_version_identity,
                encoded=release_version_bytes,
                label="Flutter-generated web version.json",
            )
        _verify_terminal_web_stamp(
            directory_fd,
            transaction=transaction,
            version=version,
            version_final=release_version_bytes,
        )
        _durable_remove_web_stamp_transaction(directory_fd, transaction_identity)
        _verify_terminal_web_stamp(
            directory_fd,
            transaction=transaction,
            version=version,
            version_final=release_version_bytes,
        )
        try:
            current_root = os.lstat(web_root)
        except OSError as exc:
            raise ReleaseMetadataError("web output root disappeared after stamping") from exc
        if _directory_identity(current_root) != root_identity:
            fail("web output root path changed while release metadata was stamped")
    finally:
        os.close(directory_fd)


def read_flyway_checksums(path: Path) -> dict[int, tuple[str, int]]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 4 * 1024 * 1024:
        fail("Flyway checksum export is missing, unsafe, or too large")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ReleaseMetadataError("Flyway checksum export is not UTF-8 text") from exc
    if not lines or lines[0] != FLYWAY_CHECKSUM_HEADER:
        fail("Flyway checksum export is missing the canonical v1 header")
    result: dict[int, tuple[str, int]] = {}
    seen_files: set[str] = set()
    last_version = 0
    for line_number, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != 3:
            fail(f"Flyway checksum export line {line_number} must contain three TSV fields")
        version_text, filename, checksum_text = fields
        if not version_text.isdigit() or version_text != str(int(version_text)):
            fail(f"Flyway checksum export has a non-canonical version on line {line_number}")
        version = int(version_text)
        if version <= last_version:
            fail(f"Flyway checksum versions are not strictly increasing on line {line_number}")
        match = MIGRATION_RE.fullmatch(filename)
        if not match or int(match.group("version")) != version:
            fail(f"Flyway checksum filename/version mismatch on line {line_number}")
        try:
            checksum = int(checksum_text)
        except ValueError as exc:
            raise ReleaseMetadataError(
                f"Flyway checksum is not an integer on line {line_number}"
            ) from exc
        if checksum_text != str(checksum) or checksum < -(2**31) or checksum > 2**31 - 1:
            fail(f"Flyway checksum is outside canonical int32 range on line {line_number}")
        if version in result or filename in seen_files:
            fail(f"duplicate Flyway checksum version/file on line {line_number}")
        result[version] = (filename, checksum)
        seen_files.add(filename)
        last_version = version
    if not result:
        fail("Flyway checksum export is empty")
    return result


def migration_metadata(
    migration_dir: Path, flyway_checksum_file: Path
) -> dict[str, Any]:
    flyway_checksums = read_flyway_checksums(flyway_checksum_file)
    migrations: list[dict[str, Any]] = []
    versions: set[int] = set()
    for path in migration_dir.iterdir():
        if not path.is_file() or path.is_symlink():
            continue
        match = MIGRATION_RE.fullmatch(path.name)
        if not match:
            if path.suffix.lower() == ".sql":
                fail(f"unexpected Flyway migration filename: {path.name}")
            continue
        version = int(match.group("version"))
        if version in versions:
            fail(f"duplicate Flyway version V{version}")
        versions.add(version)
        checksum_entry = flyway_checksums.get(version)
        if checksum_entry is None or checksum_entry[0] != path.name:
            fail(f"Flyway checksum export is missing or mismatched for {path.name}")
        migrations.append(
            {
                "description": match.group("description"),
                "file": path.name,
                "flywayChecksum": checksum_entry[1],
                "sha256": sha256_file(path),
                "version": str(version),
            }
        )
    if not migrations:
        fail("no Flyway migrations found")
    if versions != set(flyway_checksums):
        fail("Flyway checksum export contains versions absent from source migrations")
    migrations.sort(key=lambda item: int(item["version"]))
    set_digest = hashlib.sha256()
    for migration in migrations:
        set_digest.update(migration["file"].encode("utf-8"))
        set_digest.update(b"\0")
        set_digest.update(migration["sha256"].encode("ascii"))
        set_digest.update(b"\0")
        set_digest.update(str(migration["flywayChecksum"]).encode("ascii"))
        set_digest.update(b"\n")
    return {
        "digestAlgorithm": "sha256-filename-nul-source-sha256-nul-flyway-int-v2",
        "headVersion": migrations[-1]["version"],
        "migrationCount": len(migrations),
        "migrationSetSha256": set_digest.hexdigest(),
        "migrations": migrations,
    }


def verify_jar_migrations(jar_path: Path, flyway: dict[str, Any]) -> None:
    expected = {migration["file"]: migration["sha256"] for migration in flyway["migrations"]}
    actual: dict[str, str] = {}
    expected_prefixes = {
        "uten-imp-server.jar": "BOOT-INF/classes/db/migration/",
        "uten-imp-migrator.jar": "db/migration/",
    }
    prefix = expected_prefixes.get(jar_path.name)
    if prefix is None:
        fail(f"unexpected executable JAR name: {jar_path.name}")
    try:
        with zipfile.ZipFile(jar_path) as archive:
            if jar_path.name == "uten-imp-migrator.jar":
                archive_names = [info.filename for info in archive.infolist()]
                if archive_names.count("META-INF/MANIFEST.MF") != 1:
                    fail("migrator JAR must contain exactly one executable manifest")
                try:
                    manifest_text = archive.read("META-INF/MANIFEST.MF").decode("utf-8")
                except (KeyError, UnicodeDecodeError) as exc:
                    raise ReleaseMetadataError(
                        "migrator JAR has no canonical executable manifest"
                    ) from exc
                main_class_lines = [
                    line
                    for line in manifest_text.replace("\r\n", "\n").splitlines()
                    if line.startswith("Main-Class:")
                ]
                if main_class_lines != [
                    "Main-Class: com.uten.imp.migration.UtenImpMigrator"
                ]:
                    fail("migrator JAR Main-Class differs from the release contract")
                application_classes = [
                    name
                    for name in archive_names
                    if name.endswith(".class")
                    and (
                        name.startswith("com/uten/imp/")
                        or "/com/uten/imp/" in name
                    )
                ]
                if set(application_classes) != MIGRATOR_APPLICATION_CLASSES or len(
                    application_classes
                ) != len(MIGRATOR_APPLICATION_CLASSES):
                    fail("migrator JAR contains application classes outside the migration runner")
                for name in archive_names:
                    if not name.endswith(".class"):
                        continue
                    if "\\" in name or any(
                        name.startswith(prefix) or f"/{prefix}" in name
                        for prefix in MIGRATOR_FORBIDDEN_CLASS_PREFIXES
                    ):
                        fail(f"migrator JAR contains a forbidden runtime class: {name}")
            for info in archive.infolist():
                if (
                    "db/migration/" in info.filename
                    and info.filename.endswith(".sql")
                    and not info.filename.startswith(prefix)
                ):
                    fail(
                        "executable JAR contains a Flyway migration outside its "
                        f"canonical location: {info.filename}"
                    )
                if not info.filename.startswith(prefix) or not info.filename.endswith(".sql"):
                    continue
                name = info.filename[len(prefix) :]
                if "/" in name or not MIGRATION_RE.fullmatch(name) or name in actual:
                    fail(f"executable JAR contains an unsafe or duplicate Flyway entry: {info.filename}")
                if info.file_size > 16 * 1024 * 1024:
                    fail(f"executable JAR Flyway entry is unexpectedly large: {name}")
                with archive.open(info) as handle:
                    actual[name] = hashlib.sha256(handle.read()).hexdigest()
    except zipfile.BadZipFile as exc:
        raise ReleaseMetadataError("release artifact is not a valid executable JAR") from exc
    if actual != expected:
        fail("executable JAR Flyway migrations differ from signed source metadata")


def build_manifest(args: argparse.Namespace) -> None:
    version = args.version
    sequence = validate_version(version)
    commit_sha = validate_commit(args.commit)
    built_at = validate_timestamp(args.built_at)
    if args.payload_root.name != version:
        fail("payload root directory name must equal the release version")
    checksums = read_checksums(args.payload_root)
    require_payload_shape(
        args.payload_root,
        [(entry["path"], args.payload_root / entry["path"]) for entry in checksums],
    )
    if not args.artifact.is_file() or args.artifact.is_symlink():
        fail("release archive is missing or unsafe")
    if not re.fullmatch(r"uten-imp-v[0-9A-Za-z._-]+-[0-9a-f]{12}\.tar\.gz", args.artifact.name):
        fail("release archive filename is not canonical")
    backend_sbom = args.payload_root / "sbom/backend.cdx.json"
    flutter_sbom = args.payload_root / "sbom/flutter.cdx.json"
    for sbom_path in (backend_sbom, flutter_sbom):
        parsed = json.loads(sbom_path.read_text(encoding="utf-8"))
        if parsed.get("bomFormat") != "CycloneDX":
            fail(f"SBOM is not CycloneDX: {sbom_path}")
    checksums_path = args.payload_root / "SHA256SUMS"
    flyway = migration_metadata(args.flyway_dir, args.flyway_checksums)
    for executable in (
        args.payload_root / "server/uten-imp-server.jar",
        args.payload_root / "server/uten-imp-migrator.jar",
    ):
        verify_jar_migrations(executable, flyway)
    checksum_by_path = {entry["path"]: entry for entry in checksums}
    manifest = {
        "artifact": {
            "fileName": args.artifact.name,
            "objectKey": args.artifact_object_key,
            "sha256": sha256_file(args.artifact),
            "sizeBytes": args.artifact.stat().st_size,
        },
        "builtAtUtc": built_at,
        "commitSha": commit_sha,
        "databaseChangePolicy": {
            "migrationApproval": "required-on-change",
            "onFailedHealthAfterChange": "fail-closed",
            "rollbackCompatible": False,
        },
        "executables": {
            "backend": {
                "path": "server/uten-imp-server.jar",
                "sha256": checksum_by_path["server/uten-imp-server.jar"]["sha256"],
                "sizeBytes": checksum_by_path["server/uten-imp-server.jar"]["sizeBytes"],
            },
            "migrator": {
                "path": "server/uten-imp-migrator.jar",
                "sha256": checksum_by_path["server/uten-imp-migrator.jar"]["sha256"],
                "sizeBytes": checksum_by_path["server/uten-imp-migrator.jar"]["sizeBytes"],
            },
        },
        "flyway": flyway,
        "payload": {
            "allowedRoots": sorted(ALLOWED_PAYLOAD_ROOTS),
            "checksumsFile": "SHA256SUMS",
            "checksumsSha256": sha256_file(checksums_path),
            "fileCount": len(checksums),
            "rootDirectory": version,
            "uncompressedBytes": sum(entry["sizeBytes"] for entry in checksums)
            + checksums_path.stat().st_size,
        },
        "product": PRODUCT,
        "releaseSequence": sequence,
        "sbom": {
            "backend": {
                "path": "sbom/backend.cdx.json",
                "sha256": sha256_file(backend_sbom),
            },
            "flutter": {
                "path": "sbom/flutter.cdx.json",
                "sha256": sha256_file(flutter_sbom),
            },
            "format": "CycloneDX",
        },
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "signingKeyId": args.signing_key_id,
        "sourceRef": args.source_ref,
        "version": version,
    }
    write_json(args.output, manifest)


def build_channel(args: argparse.Namespace) -> None:
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    manifest_sha = sha256_file(args.manifest)
    version = manifest.get("version")
    sequence = manifest.get("releaseSequence")
    commit_sha = manifest.get("commitSha")
    if not isinstance(version, str) or validate_version(version) != sequence:
        fail("manifest version/sequence is invalid")
    validate_commit(commit_sha)
    channel = {
        "channel": args.channel,
        "commitSha": commit_sha,
        "manifest": {
            "objectKey": args.manifest_object_key,
            "sha256": manifest_sha,
            "signatureObjectKey": args.manifest_signature_object_key,
        },
        "product": PRODUCT,
        "publishedAtUtc": validate_timestamp(args.published_at),
        "releaseSequence": sequence,
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "signingKeyId": manifest.get("signingKeyId"),
        "version": version,
    }
    write_json(args.output, channel)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)

    validate = subcommands.add_parser("validate-version")
    validate.add_argument("--version", required=True)

    flutter = subcommands.add_parser("flutter-sbom")
    flutter.add_argument("--input", required=True, type=Path)
    flutter.add_argument("--output", required=True, type=Path)
    flutter.add_argument("--version", required=True)
    flutter.add_argument("--commit", required=True)
    flutter.add_argument("--timestamp", required=True)

    stamp_web = subcommands.add_parser("stamp-web")
    stamp_web.add_argument("--web-root", required=True, type=Path)
    stamp_web.add_argument("--version", required=True)
    stamp_web.add_argument("--commit", required=True)

    checksums = subcommands.add_parser("checksums")
    checksums.add_argument("--root", required=True, type=Path)
    checksums.add_argument("--output", required=True, type=Path)

    manifest = subcommands.add_parser("manifest")
    manifest.add_argument("--payload-root", required=True, type=Path)
    manifest.add_argument("--artifact", required=True, type=Path)
    manifest.add_argument("--artifact-object-key", required=True)
    manifest.add_argument("--flyway-dir", required=True, type=Path)
    manifest.add_argument("--flyway-checksums", required=True, type=Path)
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--commit", required=True)
    manifest.add_argument("--source-ref", required=True)
    manifest.add_argument("--built-at", required=True)
    manifest.add_argument("--signing-key-id", required=True)
    manifest.add_argument("--output", required=True, type=Path)

    channel = subcommands.add_parser("channel")
    channel.add_argument("--manifest", required=True, type=Path)
    channel.add_argument("--manifest-object-key", required=True)
    channel.add_argument("--manifest-signature-object-key", required=True)
    channel.add_argument("--channel", default="candidate")
    channel.add_argument("--published-at", required=True)
    channel.add_argument("--output", required=True, type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "validate-version":
            print(validate_version(args.version))
        elif args.command == "flutter-sbom":
            validate_version(args.version)
            build_flutter_sbom(args)
        elif args.command == "stamp-web":
            args.web_root = args.web_root.resolve()
            stamp_web_release(args)
        elif args.command == "checksums":
            write_checksums(args.root.resolve(), args.output.resolve())
        elif args.command == "manifest":
            args.payload_root = args.payload_root.resolve()
            args.artifact = args.artifact.resolve()
            args.flyway_dir = args.flyway_dir.resolve()
            args.flyway_checksums = args.flyway_checksums.resolve()
            build_manifest(args)
        elif args.command == "channel":
            build_channel(args)
        else:
            fail(f"unsupported command: {args.command}")
        return 0
    except (OSError, json.JSONDecodeError, ReleaseMetadataError) as exc:
        print(f"release metadata error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
