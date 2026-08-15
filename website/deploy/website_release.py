#!/usr/bin/env python3
"""Build and verify the website's signed, immutable release contract.

This module deliberately uses only the Python standard library and OpenSSH.
It is installed root-owned on the website host; neither a switchable release
nor downloaded Python code is ever executed to decide whether a release is
trusted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


PRODUCT = "uten-corporate-website"
SCHEMA_VERSION = 2
SIGNATURE_NAMESPACE = "uten-website-release-v2"
DATABASE_SCHEMA_FORMAT = "uten-website-sqlite-schema-v1"
INSTALLED_EVIDENCE_DIRECTORY = ".release-evidence"
SIGNER_IDENTITY = "uten-website-release"
MAX_ARTIFACT_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBER_BYTES = 512 * 1024 * 1024
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
MIGRATION_RE = re.compile(r"[0-9]{14}_[a-z0-9_]+")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class ReleaseError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def read_canonical_json(path: Path) -> Any:
    raw = path.read_bytes()
    if len(raw) > 2 * 1024 * 1024 or b"\x00" in raw:
        raise ReleaseError(f"unsafe JSON size/content: {path.name}")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReleaseError(f"invalid JSON: {path.name}") from exc
    if raw != canonical_json(value):
        raise ReleaseError(f"JSON is not canonical: {path.name}")
    return value


def exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ReleaseError(f"{label} key set differs from contract")
    return value


def checked_regular_file(path: Path, *, maximum: int = MAX_ARTIFACT_BYTES) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ReleaseError(f"not a single-link regular file: {path}")
    if info.st_size <= 0 or info.st_size > maximum:
        raise ReleaseError(f"file size outside contract: {path}")


def migration_inventory(schema_path: Path, migrations_path: Path) -> dict[str, Any]:
    checked_regular_file(schema_path, maximum=4 * 1024 * 1024)
    lock_path = migrations_path / "migration_lock.toml"
    checked_regular_file(lock_path, maximum=64 * 1024)
    lock_lines = [
        line for line in lock_path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    ]
    if lock_lines != ['provider = "sqlite"']:
        raise ReleaseError("migration_lock.toml is not the canonical SQLite provider lock")

    entries: list[dict[str, Any]] = []
    for child in sorted(migrations_path.iterdir(), key=lambda item: item.name):
        if child.name == "migration_lock.toml":
            continue
        if child.is_symlink() or not child.is_dir() or not MIGRATION_RE.fullmatch(child.name):
            raise ReleaseError(f"unexpected Prisma migration entry: {child.name}")
        members = list(child.iterdir())
        if len(members) != 1 or members[0].name != "migration.sql":
            raise ReleaseError(f"migration must contain exactly migration.sql: {child.name}")
        script = members[0]
        checked_regular_file(script, maximum=32 * 1024 * 1024)
        entries.append({
            "name": child.name,
            "sha256": sha256_file(script),
            "sizeBytes": script.stat().st_size,
        })
    if not entries:
        raise ReleaseError("at least one Prisma migration is required")
    return {
        "count": len(entries),
        "entries": entries,
        "lockSha256": sha256_file(lock_path),
        "schemaSha256": sha256_file(schema_path),
    }


def validate_database_schema_contract(value: Any) -> dict[str, Any]:
    contract = exact_keys(value, {"entries", "format", "objectCount", "sha256"}, "database schema")
    entries = contract.get("entries")
    if contract.get("format") != DATABASE_SCHEMA_FORMAT or not isinstance(entries, list) or not entries:
        raise ReleaseError("database schema contract identity differs")
    normalized: list[dict[str, str]] = []
    for entry in entries:
        entry = exact_keys(entry, {"name", "sql", "tableName", "type"}, "database schema entry")
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
            or not isinstance(sql, str)
            or not sql
            or "\x00" in sql
            or sql != sql.replace("\r\n", "\n").replace("\r", "\n").strip()
        ):
            raise ReleaseError("database schema entry value differs")
        normalized.append(entry)
    if normalized != sorted(normalized, key=lambda item: (item["type"], item["name"], item["tableName"])):
        raise ReleaseError("database schema entries are unordered")
    if len({(item["type"], item["name"], item["tableName"]) for item in normalized}) != len(normalized):
        raise ReleaseError("database schema entries are duplicate")
    digest = hashlib.sha256(canonical_json(normalized)).hexdigest()
    if contract.get("objectCount") != len(normalized) or contract.get("sha256") != digest:
        raise ReleaseError("database schema digest/count differs")
    return contract


def read_database_schema_contract(path: Path) -> dict[str, Any]:
    checked_regular_file(path, maximum=2 * 1024 * 1024)
    return validate_database_schema_contract(read_canonical_json(path))


def validate_sbom(path: Path) -> dict[str, Any]:
    checked_regular_file(path, maximum=64 * 1024 * 1024)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReleaseError("website SBOM is invalid JSON") from exc
    if not isinstance(document, dict) or document.get("bomFormat") != "CycloneDX":
        raise ReleaseError("website SBOM must be CycloneDX")
    if not isinstance(document.get("components"), list):
        raise ReleaseError("website SBOM has no component inventory")
    return {
        "fileName": path.name,
        "format": "CycloneDX",
        "sha256": sha256_file(path),
        "sizeBytes": path.stat().st_size,
    }


def command_manifest(arguments: argparse.Namespace) -> None:
    artifact = arguments.artifact.resolve(strict=True)
    sbom = arguments.sbom.resolve(strict=True)
    schema = arguments.schema.resolve(strict=True)
    migrations = arguments.migrations.resolve(strict=True)
    database_schema = arguments.database_schema.resolve(strict=True)
    if not VERSION_RE.fullmatch(arguments.version):
        raise ReleaseError("version is not canonical SemVer")
    if not COMMIT_RE.fullmatch(arguments.commit):
        raise ReleaseError("commit must be a lowercase 40-character SHA")
    if arguments.source_ref != f"refs/tags/website-v{arguments.version}":
        raise ReleaseError("source ref must be the exact website release tag")
    checked_regular_file(artifact)
    if artifact.name != f"uten-website-{arguments.version}-{arguments.commit[:12]}.tar.gz":
        raise ReleaseError("artifact filename differs from release identity")
    validate_tar(artifact)

    value = {
        "artifact": {
            "fileName": artifact.name,
            "objectKey": f"website/releases/{arguments.version}/{artifact.name}",
            "sha256": sha256_file(artifact),
            "sizeBytes": artifact.stat().st_size,
        },
        "commitSha": arguments.commit,
        "databaseSchema": read_database_schema_contract(database_schema),
        "migrations": migration_inventory(schema, migrations),
        "product": PRODUCT,
        "schemaVersion": SCHEMA_VERSION,
        "sbom": validate_sbom(sbom),
        "signingKeyId": "__WEBSITE_SIGNING_KEY_ID__",
        "sourceRef": arguments.source_ref,
        "version": arguments.version,
    }
    arguments.output.write_bytes(canonical_json(value))


def normalize_tar_name(name: str) -> PurePosixPath:
    while name.startswith("./"):
        name = name[2:]
    path = PurePosixPath(name)
    if not name or path.is_absolute() or ".." in path.parts or "" in path.parts:
        raise ReleaseError(f"unsafe artifact member path: {name!r}")
    return path


def validate_tar(path: Path) -> list[tarfile.TarInfo]:
    checked_regular_file(path)
    seen: set[str] = set()
    total = 0
    required = {"server.js", "prisma-runtime/prisma/schema.prisma", "prisma-runtime/prisma/sqlite-schema-contract.json", "prisma-runtime/prisma/migrations/migration_lock.toml", "prisma-runtime/node_modules/prisma/build/index.js"}
    present: set[str] = set()
    try:
        with tarfile.open(path, mode="r:gz") as archive:
            members = archive.getmembers()
            if not members or len(members) > 250_000:
                raise ReleaseError("artifact member count outside contract")
            for member in members:
                normalized = str(normalize_tar_name(member.name))
                if normalized in seen:
                    raise ReleaseError(f"duplicate artifact member: {normalized}")
                seen.add(normalized)
                present.add(normalized)
                if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                    raise ReleaseError(f"artifact contains link/device entry: {normalized}")
                if not (member.isfile() or member.isdir()):
                    raise ReleaseError(f"unsupported artifact entry: {normalized}")
                if member.isfile():
                    if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                        raise ReleaseError(f"artifact member size outside contract: {normalized}")
                    total += member.size
                    if total > 4 * MAX_ARTIFACT_BYTES:
                        raise ReleaseError("artifact expanded size outside contract")
    except (tarfile.TarError, OSError) as exc:
        if isinstance(exc, ReleaseError):
            raise
        raise ReleaseError("artifact is not a readable gzip tar") from exc
    missing = required - present
    if missing:
        raise ReleaseError(f"artifact misses required runtime members: {sorted(missing)}")
    if any(name.startswith("public/uploads/") or name == "public/uploads" for name in present):
        raise ReleaseError("artifact contains mutable uploads")
    if any(re.search(r"(?:^|/)(?:\.env(?:\..*)?|[^/]+\.(?:db|sqlite|sqlite3)(?:-(?:wal|shm|journal))?)$", name, re.I) for name in present):
        raise ReleaseError("artifact contains a secret/environment or SQLite file")
    return members


def artifact_migration_inventory(path: Path) -> dict[str, Any]:
    prefix = "prisma-runtime/prisma/migrations/"
    entries: list[dict[str, Any]] = []
    schema_bytes: bytes | None = None
    lock_bytes: bytes | None = None
    seen_scripts: set[str] = set()
    with tarfile.open(path, mode="r:gz") as archive:
        for member in archive.getmembers():
            name = str(normalize_tar_name(member.name))
            if not member.isfile():
                continue
            if name == "prisma-runtime/prisma/schema.prisma":
                source = archive.extractfile(member)
                schema_bytes = source.read() if source else None
                continue
            if name == prefix + "migration_lock.toml":
                source = archive.extractfile(member)
                lock_bytes = source.read() if source else None
                continue
            if name.startswith(prefix):
                relative = name[len(prefix):]
                parts = PurePosixPath(relative).parts
                if len(parts) != 2 or not MIGRATION_RE.fullmatch(parts[0]) or parts[1] != "migration.sql":
                    raise ReleaseError(f"artifact contains unexpected Prisma migration member: {relative}")
                if parts[0] in seen_scripts:
                    raise ReleaseError(f"artifact contains duplicate Prisma migration: {parts[0]}")
                seen_scripts.add(parts[0])
                source = archive.extractfile(member)
                if source is None:
                    raise ReleaseError(f"cannot read artifact migration: {parts[0]}")
                raw = source.read()
                entries.append({
                    "name": parts[0],
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "sizeBytes": len(raw),
                })
    if schema_bytes is None or lock_bytes is None or not entries:
        raise ReleaseError("artifact Prisma runtime inventory is incomplete")
    return {
        "count": len(entries),
        "entries": sorted(entries, key=lambda item: item["name"]),
        "lockSha256": hashlib.sha256(lock_bytes).hexdigest(),
        "schemaSha256": hashlib.sha256(schema_bytes).hexdigest(),
    }


def artifact_database_schema_contract(path: Path) -> dict[str, Any]:
    member_name = "prisma-runtime/prisma/sqlite-schema-contract.json"
    with tarfile.open(path, mode="r:gz") as archive:
        matches = [member for member in archive.getmembers() if str(normalize_tar_name(member.name)) == member_name]
        if len(matches) != 1 or not matches[0].isfile():
            raise ReleaseError("artifact database schema contract inventory differs")
        source = archive.extractfile(matches[0])
        if source is None:
            raise ReleaseError("artifact database schema contract is unreadable")
        raw = source.read()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReleaseError("artifact database schema contract is invalid JSON") from exc
    if raw != canonical_json(value):
        raise ReleaseError("artifact database schema contract is not canonical JSON")
    return validate_database_schema_contract(value)


def allowed_signer_fingerprint(path: Path) -> str:
    checked_regular_file(path, maximum=64 * 1024)
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line and not line.startswith("#")]
    if len(lines) != 1:
        raise ReleaseError("website allowed-signers must contain exactly one active key")
    fields = lines[0].split()
    if len(fields) < 3 or fields[0] != SIGNER_IDENTITY or not fields[1].startswith("ssh-ed25519"):
        raise ReleaseError("website allowed-signers identity/key type is invalid")
    result = subprocess.run(
        ["ssh-keygen", "-lf", "-", "-E", "sha256"],
        input=(" ".join(fields[1:3]) + "\n").encode("ascii"),
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise ReleaseError("cannot fingerprint website signing key")
    match = re.search(rb"\b(SHA256:[A-Za-z0-9+/]+)\b", result.stdout)
    if not match:
        raise ReleaseError("website signing key fingerprint is missing")
    return match.group(1).decode("ascii")


def verify_signature(data: Path, signature: Path, allowed_signers: Path) -> None:
    checked_regular_file(signature, maximum=64 * 1024)
    with data.open("rb") as input_file:
        result = subprocess.run(
            ["ssh-keygen", "-Y", "verify", "-f", str(allowed_signers), "-I", SIGNER_IDENTITY, "-n", SIGNATURE_NAMESPACE, "-s", str(signature)],
            stdin=input_file,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    if result.returncode != 0:
        raise ReleaseError(f"OpenSSH signature verification failed for {data.name}")


def verify_publication(directory: Path, allowed_signers: Path) -> dict[str, Any]:
    directory = directory.resolve(strict=True)
    if directory.is_symlink() or not directory.is_dir():
        raise ReleaseError("publication must be a real directory")
    expected_static = {"manifest.json", "manifest.sig", "channel.json", "channel.sig", "website-sbom.cdx.json"}
    manifest_path = directory / "manifest.json"
    manifest = exact_keys(
        read_canonical_json(manifest_path),
        {"artifact", "commitSha", "databaseSchema", "migrations", "product", "schemaVersion", "sbom", "signingKeyId", "sourceRef", "version"},
        "manifest",
    )
    version = manifest.get("version")
    commit = manifest.get("commitSha")
    if manifest.get("product") != PRODUCT or manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise ReleaseError("manifest product/schema identity differs")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise ReleaseError("manifest version is invalid")
    if not isinstance(commit, str) or not COMMIT_RE.fullmatch(commit):
        raise ReleaseError("manifest commit is invalid")
    if manifest.get("sourceRef") != f"refs/tags/website-v{version}":
        raise ReleaseError("manifest source ref differs")
    if manifest.get("signingKeyId") != allowed_signer_fingerprint(allowed_signers):
        raise ReleaseError("manifest signer fingerprint differs from website trust root")
    verify_signature(manifest_path, directory / "manifest.sig", allowed_signers)

    artifact_info = exact_keys(manifest.get("artifact"), {"fileName", "objectKey", "sha256", "sizeBytes"}, "artifact")
    artifact_name = f"uten-website-{version}-{commit[:12]}.tar.gz"
    if artifact_info.get("fileName") != artifact_name or artifact_info.get("objectKey") != f"website/releases/{version}/{artifact_name}":
        raise ReleaseError("manifest artifact path differs")
    artifact_path = directory / artifact_name
    checked_regular_file(artifact_path)
    if artifact_info.get("sha256") != sha256_file(artifact_path) or artifact_info.get("sizeBytes") != artifact_path.stat().st_size:
        raise ReleaseError("artifact bytes differ from signed manifest")
    checksum_path = directory / f"{artifact_name}.sha256"
    checked_regular_file(checksum_path, maximum=512)
    if checksum_path.read_text(encoding="ascii") != f"{artifact_info['sha256']}  {artifact_name}\n":
        raise ReleaseError("artifact checksum sidecar is not canonical")

    sbom_info = exact_keys(manifest.get("sbom"), {"fileName", "format", "sha256", "sizeBytes"}, "SBOM")
    sbom_path = directory / "website-sbom.cdx.json"
    actual_sbom = validate_sbom(sbom_path)
    if sbom_info != actual_sbom:
        raise ReleaseError("SBOM bytes differ from signed manifest")
    migrations = exact_keys(manifest.get("migrations"), {"count", "entries", "lockSha256", "schemaSha256"}, "migrations")
    if not isinstance(migrations.get("entries"), list) or migrations.get("count") != len(migrations["entries"]):
        raise ReleaseError("signed Prisma migration inventory is invalid")
    if migrations != artifact_migration_inventory(artifact_path):
        raise ReleaseError("artifact Prisma schema/migrations differ from signed inventory")
    database_schema = validate_database_schema_contract(manifest.get("databaseSchema"))
    if database_schema != artifact_database_schema_contract(artifact_path):
        raise ReleaseError("artifact SQLite schema contract differs from signed manifest")

    channel_path = directory / "channel.json"
    channel = exact_keys(read_canonical_json(channel_path), {"artifactObjectKey", "manifestObjectKey", "manifestSha256", "product", "schemaVersion", "version"}, "channel")
    if channel != {
        "artifactObjectKey": artifact_info["objectKey"],
        "manifestObjectKey": f"website/releases/{version}/manifest.json",
        "manifestSha256": sha256_file(manifest_path),
        "product": PRODUCT,
        "schemaVersion": SCHEMA_VERSION,
        "version": version,
    }:
        raise ReleaseError("channel does not bind the signed manifest")
    verify_signature(channel_path, directory / "channel.sig", allowed_signers)

    expected = expected_static | {artifact_name, f"{artifact_name}.sha256"}
    actual = {entry.name for entry in directory.iterdir()}
    if actual != expected or any(entry.is_symlink() for entry in directory.iterdir()):
        raise ReleaseError("publication file inventory differs from contract")
    validate_tar(artifact_path)
    return manifest


def safe_extract(artifact: Path, destination: Path) -> None:
    if destination.exists():
        raise ReleaseError("release extraction destination already exists")
    parent = destination.parent.resolve(strict=True)
    if parent.is_symlink():
        raise ReleaseError("release destination parent must be a real directory")
    destination.mkdir(mode=0o750)
    try:
        with tarfile.open(artifact, mode="r:gz") as archive:
            for member in archive.getmembers():
                relative = normalize_tar_name(member.name)
                target = destination.joinpath(*relative.parts)
                resolved_parent = target.parent.resolve(strict=False)
                if destination.resolve() not in (resolved_parent, *resolved_parent.parents):
                    raise ReleaseError("artifact extraction escaped destination")
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True, mode=0o750)
                    os.chmod(target, 0o750)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
                source = archive.extractfile(member)
                if source is None:
                    raise ReleaseError(f"cannot read artifact member: {relative}")
                with target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                    output.flush()
                    os.fsync(output.fileno())
                os.chmod(target, 0o750 if member.mode & 0o111 else 0o640)
        if os.name != "nt":
            directory_fd = os.open(destination, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            parent_fd = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
    except Exception:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def install_publication_evidence(publication: Path, destination: Path) -> None:
    evidence = destination / INSTALLED_EVIDENCE_DIRECTORY
    if evidence.exists() or evidence.is_symlink():
        raise ReleaseError("release unexpectedly contains installed publication evidence")
    evidence.mkdir(mode=0o700)
    try:
        for source in sorted(publication.iterdir(), key=lambda item: item.name):
            checked_regular_file(source, maximum=MAX_ARTIFACT_BYTES)
            target = evidence / source.name
            with source.open("rb") as input_file, target.open("xb") as output_file:
                shutil.copyfileobj(input_file, output_file, length=1024 * 1024)
                output_file.flush()
                os.fsync(output_file.fileno())
            os.chmod(target, 0o600)
        if os.name != "nt":
            for path in (evidence, destination):
                descriptor = os.open(path, os.O_RDONLY)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
    except Exception:
        shutil.rmtree(evidence, ignore_errors=True)
        raise


def verify_installed_release(
    release: Path,
    allowed_signers: Path,
    *,
    expected_cache: Path = Path("/var/cache/uten-website"),
) -> dict[str, Any]:
    release = release.resolve(strict=True)
    if release.is_symlink() or not release.is_dir():
        raise ReleaseError("installed release must be one real directory")
    evidence = release / INSTALLED_EVIDENCE_DIRECTORY
    manifest = verify_publication(evidence, allowed_signers)
    if release.name != f"{manifest['version']}-{manifest['commitSha'][:12]}":
        raise ReleaseError("installed release directory identity differs from signed publication")
    artifact = evidence / manifest["artifact"]["fileName"]

    expected_files: set[str] = set()
    expected_directories: set[str] = set()
    with tarfile.open(artifact, mode="r:gz") as archive:
        for member in archive.getmembers():
            relative = normalize_tar_name(member.name)
            relative_name = relative.as_posix()
            for parent in relative.parents:
                if str(parent) != ".":
                    expected_directories.add(parent.as_posix())
            target = release.joinpath(*relative.parts)
            if member.isdir():
                expected_directories.add(relative_name)
                if target.is_symlink() or not target.is_dir():
                    raise ReleaseError(f"installed release directory differs: {relative_name}")
                continue
            expected_files.add(relative_name)
            checked_regular_file(target, maximum=MAX_ARTIFACT_BYTES)
            if target.stat().st_size != member.size:
                raise ReleaseError(f"installed release file size differs: {relative_name}")
            source = archive.extractfile(member)
            if source is None:
                raise ReleaseError(f"cannot read signed artifact member: {relative_name}")
            artifact_digest = hashlib.sha256()
            installed_digest = hashlib.sha256()
            with target.open("rb") as installed:
                while True:
                    source_chunk = source.read(1024 * 1024)
                    installed_chunk = installed.read(1024 * 1024)
                    if not source_chunk and not installed_chunk:
                        break
                    artifact_digest.update(source_chunk)
                    installed_digest.update(installed_chunk)
            if artifact_digest.digest() != installed_digest.digest():
                raise ReleaseError(f"installed release file bytes differ: {relative_name}")

    actual_files: set[str] = set()
    actual_directories: set[str] = set()
    for current, directory_names, file_names in os.walk(release, topdown=True, followlinks=False):
        current_path = Path(current)
        if current_path == release:
            directory_names[:] = [name for name in directory_names if name != INSTALLED_EVIDENCE_DIRECTORY]
        directory_names.sort()
        file_names.sort()
        for name in list(directory_names):
            path = current_path / name
            relative = path.relative_to(release).as_posix()
            if relative == ".next/cache":
                if not path.is_symlink() or path.resolve(strict=True) != expected_cache.resolve(strict=True):
                    raise ReleaseError("installed runtime cache link differs")
                directory_names.remove(name)
                continue
            if path.is_symlink():
                raise ReleaseError(f"installed release contains an unexpected symlink: {relative}")
            actual_directories.add(relative)
        for name in file_names:
            path = current_path / name
            relative = path.relative_to(release).as_posix()
            if path.is_symlink():
                raise ReleaseError(f"installed release contains an unexpected file symlink: {relative}")
            actual_files.add(relative)
    if actual_files != expected_files or actual_directories != expected_directories:
        raise ReleaseError("installed release inventory differs from signed artifact")
    return manifest


def command_verify(arguments: argparse.Namespace) -> None:
    manifest = verify_publication(arguments.publication, arguments.allowed_signers)
    if arguments.expected_version and manifest["version"] != arguments.expected_version:
        raise ReleaseError("publication version differs from requested version")
    print(f"WEBSITE_RELEASE_VERIFIED version={manifest['version']} commit={manifest['commitSha']}")


def command_extract(arguments: argparse.Namespace) -> None:
    manifest = verify_publication(arguments.publication, arguments.allowed_signers)
    if manifest["version"] != arguments.expected_version:
        raise ReleaseError("publication version differs from extraction request")
    artifact = arguments.publication / manifest["artifact"]["fileName"]
    safe_extract(artifact, arguments.destination)
    try:
        install_publication_evidence(arguments.publication, arguments.destination)
    except Exception:
        shutil.rmtree(arguments.destination, ignore_errors=True)
        raise
    print(f"WEBSITE_RELEASE_EXTRACTED version={manifest['version']} destination={arguments.destination}")


def command_verify_installed(arguments: argparse.Namespace) -> None:
    manifest = verify_installed_release(arguments.release, arguments.allowed_signers)
    print(f"WEBSITE_INSTALLED_RELEASE_VERIFIED version={manifest['version']} commit={manifest['commitSha']}")


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    subcommands = value.add_subparsers(dest="command", required=True)
    manifest = subcommands.add_parser("manifest")
    manifest.add_argument("--artifact", type=Path, required=True)
    manifest.add_argument("--sbom", type=Path, required=True)
    manifest.add_argument("--schema", type=Path, required=True)
    manifest.add_argument("--migrations", type=Path, required=True)
    manifest.add_argument("--database-schema", type=Path, required=True)
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--commit", required=True)
    manifest.add_argument("--source-ref", required=True)
    manifest.add_argument("--output", type=Path, required=True)
    manifest.set_defaults(handler=command_manifest)
    verify = subcommands.add_parser("verify")
    verify.add_argument("--publication", type=Path, required=True)
    verify.add_argument("--allowed-signers", type=Path, required=True)
    verify.add_argument("--expected-version")
    verify.set_defaults(handler=command_verify)
    extract = subcommands.add_parser("extract")
    extract.add_argument("--publication", type=Path, required=True)
    extract.add_argument("--allowed-signers", type=Path, required=True)
    extract.add_argument("--expected-version", required=True)
    extract.add_argument("--destination", type=Path, required=True)
    extract.set_defaults(handler=command_extract)
    installed = subcommands.add_parser("verify-installed")
    installed.add_argument("--release", type=Path, required=True)
    installed.add_argument("--allowed-signers", type=Path, required=True)
    installed.set_defaults(handler=command_verify_installed)
    return value


def main() -> int:
    try:
        arguments = parser().parse_args()
        arguments.handler(arguments)
        return 0
    except (ReleaseError, FileNotFoundError, OSError, subprocess.SubprocessError) as exc:
        print(f"WEBSITE_RELEASE_REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
