#!/usr/bin/env python3
"""Strict validation and safe extraction for signed Uten IMP releases."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn


PRODUCT = "uten-imp"
SCHEMA_VERSION = 1
SIGNATURE_NAMESPACE = "uten-imp-release-v1"
SIGNING_IDENTITY = "uten-imp-release"
VERSION_RE = re.compile(
    r"^v(?P<year>[0-9]{4})\.(?P<month>[0-9]{2})\.(?P<day>[0-9]{2})-(?P<counter>[0-9]{1,3})$"
)
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
KEY_ID_RE = re.compile(r"^SHA256:[A-Za-z0-9+/]+$")
MIGRATION_FILE_RE = re.compile(r"^V(?P<version>[0-9]+)__(?P<description>.+)\.sql$")
ALLOWED_PAYLOAD_ROOTS = frozenset({"server", "web", "sbom"})
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_CHANNEL_BYTES = 64 * 1024
MAX_SIGNATURE_BYTES = 32 * 1024
MAX_CHECKSUMS_BYTES = 16 * 1024 * 1024
MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 4 * 1024 * 1024 * 1024
MAX_PAYLOAD_FILES = 50_000
MAX_ALLOWED_SIGNERS_BYTES = 64 * 1024
CANONICAL_JSON_FILENAMES = frozenset(
    {"channel.json", "manifest.json", "manifest.template.json", "version.json"}
)
_LOADED_CANONICAL_JSON_DIGESTS: dict[str, str] = {}
INSTALLED_GUARD_PATH = Path(
    "/usr/local/libexec/uten-imp-release/release_guard.py"
)
INSTALLED_RESTORE_ALLOWED_SIGNERS_PATH = Path(
    "/etc/uten-imp-release-trust/release-allowed-signers"
)
SSH_KEYGEN_PATH = Path("/usr/bin/ssh-keygen")
MIGRATOR_APPLICATION_CLASSES = frozenset(
    {
        "com/uten/imp/migration/UtenImpMigrator.class",
        "com/uten/imp/migration/UtenImpMigrator$1.class",
        "com/uten/imp/migration/UtenImpMigrator$MigrationActions.class",
        "com/uten/imp/migration/UtenImpMigrator$MigrationActionsFactory.class",
    }
)
MIGRATOR_FORBIDDEN_CLASS_PREFIXES = (
    "org/springframework/",
    "jakarta/servlet/",
    "org/apache/tomcat/",
)


class ReleaseGuardError(ValueError):
    """Raised when untrusted release input violates the release contract."""


def fail(message: str) -> NoReturn:
    raise ReleaseGuardError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_stable_regular_file(
    path: Path,
    maximum_bytes: int,
    *,
    label: str,
    minimum_bytes: int = 1,
) -> bytes:
    """Read one single-link regular inode without a pathname re-open."""

    if (
        not isinstance(maximum_bytes, int)
        or isinstance(maximum_bytes, bool)
        or maximum_bytes < minimum_bytes
    ):
        fail(f"{label} size limit is invalid")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ReleaseGuardError(f"{label} is missing or unsafe: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        try:
            live = path.lstat()
        except OSError as exc:
            raise ReleaseGuardError(f"{label} pathname is unavailable: {path}") from exc
        if (
            not stat.S_ISREG(opened.st_mode)
            or not stat.S_ISREG(live.st_mode)
            or stat.S_ISLNK(live.st_mode)
            or opened.st_nlink != 1
            or live.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (live.st_dev, live.st_ino)
            or opened.st_size < minimum_bytes
            or opened.st_size > maximum_bytes
        ):
            fail(f"{label} is not a bounded single-link regular file: {path}")

        payload = bytearray()
        while True:
            block = os.read(
                descriptor,
                min(1024 * 1024, maximum_bytes + 1 - len(payload)),
            )
            if not block:
                break
            payload.extend(block)
            if len(payload) > maximum_bytes:
                fail(f"{label} size is outside the allowed range: {path}")

        after = os.fstat(descriptor)
        try:
            live_after = path.lstat()
        except OSError as exc:
            raise ReleaseGuardError(f"{label} pathname changed while being read: {path}") from exc
        if (
            (opened.st_dev, opened.st_ino) != (after.st_dev, after.st_ino)
            or (after.st_dev, after.st_ino) != (live_after.st_dev, live_after.st_ino)
            or opened.st_size != after.st_size
            or after.st_size != live_after.st_size
            or len(payload) != after.st_size
            or opened.st_mtime_ns != after.st_mtime_ns
            or opened.st_ctime_ns != after.st_ctime_ns
            or live.st_mtime_ns != live_after.st_mtime_ns
            or live.st_ctime_ns != live_after.st_ctime_ns
            or after.st_nlink != 1
            or live_after.st_nlink != 1
            or not stat.S_ISREG(live_after.st_mode)
            or stat.S_ISLNK(live_after.st_mode)
        ):
            fail(f"{label} changed while being read: {path}")
        return bytes(payload)
    finally:
        os.close(descriptor)


def _strict_json_object(raw: bytes, label: str) -> dict[str, Any]:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                fail(f"{label} contains a duplicate JSON key: {key}")
            result[key] = item
        return result

    def invalid_constant(constant: str) -> NoReturn:
        fail(f"{label} contains a non-finite JSON value: {constant}")

    try:
        decoded = raw.decode("utf-8")
        value = json.loads(
            decoded,
            object_pairs_hook=object_pairs,
            parse_constant=invalid_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ReleaseGuardError(f"{label} is not strict UTF-8 JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} JSON root must be an object")
    return value


def _canonical_json_bytes(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")


def load_json(
    path: Path,
    maximum_bytes: int,
    *,
    require_canonical: bool | None = None,
) -> dict[str, Any]:
    """Load strict JSON; canonicalize only release objects with a fixed byte contract."""

    raw = _read_stable_regular_file(
        path,
        maximum_bytes,
        label="JSON input",
        minimum_bytes=2,
    )
    value = _strict_json_object(raw, f"JSON input {path}")
    if require_canonical is None:
        require_canonical = path.name in CANONICAL_JSON_FILENAMES
    if require_canonical and raw != _canonical_json_bytes(value):
        fail(f"JSON input is not canonical: {path}")
    if require_canonical:
        _LOADED_CANONICAL_JSON_DIGESTS[os.path.abspath(path)] = hashlib.sha256(
            raw
        ).hexdigest()
    return value


def require_root_owned_path_chain(path: Path, *, regular_file: bool = True) -> None:
    """Reject a privileged evidence/code path with a replaceable component."""
    if not path.is_absolute():
        fail(f"root-controlled path must be absolute: {path}")
    current = path
    first = True
    while True:
        try:
            details = current.lstat()
        except FileNotFoundError as exc:
            raise ReleaseGuardError(f"root-controlled path is missing: {current}") from exc
        expected_type = stat.S_ISREG(details.st_mode) if first and regular_file else stat.S_ISDIR(
            details.st_mode
        )
        if not expected_type or stat.S_ISLNK(details.st_mode):
            fail(f"root-controlled path has an unsafe type: {current}")
        if details.st_uid != 0 or details.st_mode & 0o022:
            fail(f"root-controlled path is writable by an untrusted account: {current}")
        parent = current.parent
        if parent == current:
            break
        current = parent
        first = False


def require_privileged_restore_paths(
    manifest: Path, signature: Path, allowed_signers: Path
) -> None:
    """Enforce the installed root trust boundary when the restore CLI runs as root."""
    get_euid = getattr(os, "geteuid", None)
    if get_euid is None or get_euid() != 0:
        return
    invoked_guard = Path(os.path.abspath(__file__))
    if invoked_guard != INSTALLED_GUARD_PATH:
        fail(f"root restore must use the installed guard at {INSTALLED_GUARD_PATH}")
    if Path(os.path.abspath(allowed_signers)) != INSTALLED_RESTORE_ALLOWED_SIGNERS_PATH:
        fail(
            "root restore must use the fixed trust policy at "
            f"{INSTALLED_RESTORE_ALLOWED_SIGNERS_PATH}"
        )
    for path in (invoked_guard, manifest, signature, allowed_signers):
        require_root_owned_path_chain(path)
    if (
        allowed_signers.lstat().st_gid != 0
        or allowed_signers.parent.lstat().st_gid != 0
    ):
        fail("root restore trust policy and its dedicated directory must be root:root")


def exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        fail(
            f"{label} keys differ from contract; missing={sorted(expected - actual)}, "
            f"unexpected={sorted(actual - expected)}"
        )


def require_string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    if pattern is not None and not pattern.fullmatch(value):
        fail(f"{label} has an invalid format")
    return value


def require_positive_int(value: Any, label: str, maximum: int | None = None) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        fail(f"{label} must be a positive integer")
    if maximum is not None and value > maximum:
        fail(f"{label} exceeds the allowed maximum")
    return value


def version_sequence(version: str) -> int:
    match = VERSION_RE.fullmatch(version)
    if not match:
        fail("version must match vYYYY.MM.DD-N")
    counter = int(match.group("counter"))
    if counter < 1 or match.group("counter") != str(counter):
        fail("release counter must be canonical and at least 1")
    try:
        day = dt.date(
            int(match.group("year")),
            int(match.group("month")),
            int(match.group("day")),
        )
    except ValueError as exc:
        raise ReleaseGuardError(f"invalid release calendar date: {exc}") from exc
    return int(day.strftime("%Y%m%d")) * 1000 + counter


def validate_channel(
    channel: dict[str, Any],
    *,
    expected_channel: str,
    expected_signing_key_id: str | None = None,
) -> dict[str, Any]:
    exact_keys(
        channel,
        {
            "channel",
            "commitSha",
            "manifest",
            "product",
            "publishedAtUtc",
            "releaseSequence",
            "schemaVersion",
            "signingKeyId",
            "version",
        },
        "channel",
    )
    if channel["schemaVersion"] != SCHEMA_VERSION or channel["product"] != PRODUCT:
        fail("channel schema/product mismatch")
    if channel["channel"] != expected_channel:
        fail("channel name mismatch")
    version = require_string(channel["version"], "channel.version", VERSION_RE)
    sequence = require_positive_int(channel["releaseSequence"], "channel.releaseSequence")
    if version_sequence(version) != sequence:
        fail("channel version and releaseSequence do not agree")
    commit_sha = require_string(channel["commitSha"], "channel.commitSha", COMMIT_RE)
    key_id = require_string(channel["signingKeyId"], "channel.signingKeyId", KEY_ID_RE)
    if expected_signing_key_id is not None and key_id != expected_signing_key_id:
        fail("channel signing key ID does not match the pinned key")
    require_string(channel["publishedAtUtc"], "channel.publishedAtUtc")
    manifest = channel["manifest"]
    if not isinstance(manifest, dict):
        fail("channel.manifest must be an object")
    exact_keys(manifest, {"objectKey", "sha256", "signatureObjectKey"}, "channel.manifest")
    expected_prefix = f"releases/{version}/"
    if manifest["objectKey"] != f"{expected_prefix}manifest.json":
        fail("channel manifest object key is not canonical")
    if manifest["signatureObjectKey"] != f"{expected_prefix}manifest.sig":
        fail("channel manifest signature object key is not canonical")
    require_string(manifest["sha256"], "channel.manifest.sha256", SHA256_RE)
    return {
        "commitSha": commit_sha,
        "manifestObjectKey": manifest["objectKey"],
        "manifestSha256": manifest["sha256"],
        "manifestSignatureObjectKey": manifest["signatureObjectKey"],
        "releaseSequence": sequence,
        "signingKeyId": key_id,
        "version": version,
    }


def validate_flyway(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("manifest.flyway must be an object")
    exact_keys(
        value,
        {
            "digestAlgorithm",
            "headVersion",
            "migrationCount",
            "migrationSetSha256",
            "migrations",
        },
        "manifest.flyway",
    )
    if (
        value["digestAlgorithm"]
        != "sha256-filename-nul-source-sha256-nul-flyway-int-v2"
    ):
        fail("unsupported Flyway digest algorithm")
    count = require_positive_int(value["migrationCount"], "flyway.migrationCount", 100_000)
    migrations = value["migrations"]
    if not isinstance(migrations, list) or len(migrations) != count:
        fail("Flyway migration count does not match the migration list")
    seen_versions: set[int] = set()
    digest = hashlib.sha256()
    last_version = -1
    for index, migration in enumerate(migrations):
        if not isinstance(migration, dict):
            fail(f"Flyway migration {index} is not an object")
        exact_keys(
            migration,
            {"description", "file", "flywayChecksum", "sha256", "version"},
            "Flyway migration",
        )
        version_text = require_string(migration["version"], "Flyway migration version")
        if not version_text.isdigit():
            fail("Flyway migration version must be numeric")
        version = int(version_text)
        if version in seen_versions or version <= last_version:
            fail("Flyway migrations must be unique and sorted by numeric version")
        seen_versions.add(version)
        last_version = version
        description = require_string(migration["description"], "Flyway migration description")
        filename = require_string(migration["file"], "Flyway migration filename")
        match = MIGRATION_FILE_RE.fullmatch(filename)
        if not match or int(match.group("version")) != version or match.group("description") != description:
            fail("Flyway migration filename/version/description mismatch")
        file_sha = require_string(migration["sha256"], "Flyway migration SHA-256", SHA256_RE)
        flyway_checksum = migration["flywayChecksum"]
        if (
            not isinstance(flyway_checksum, int)
            or isinstance(flyway_checksum, bool)
            or flyway_checksum < -(2**31)
            or flyway_checksum > 2**31 - 1
        ):
            fail("Flyway migration checksum must be a signed int32")
        digest.update(filename.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_sha.encode("ascii"))
        digest.update(b"\0")
        digest.update(str(flyway_checksum).encode("ascii"))
        digest.update(b"\n")
    if value["headVersion"] != str(last_version):
        fail("Flyway headVersion does not match the final migration")
    expected_set_digest = require_string(
        value["migrationSetSha256"], "flyway.migrationSetSha256", SHA256_RE
    )
    if digest.hexdigest() != expected_set_digest:
        fail("Flyway migration set digest mismatch")
    return {
        "headVersion": str(last_version),
        "migrationCount": count,
        "migrationSetSha256": expected_set_digest,
        "migrations": migrations,
    }


def validate_manifest(
    manifest: dict[str, Any],
    *,
    expected_version: str | None = None,
    expected_signing_key_id: str | None = None,
) -> dict[str, Any]:
    exact_keys(
        manifest,
        {
            "artifact",
            "builtAtUtc",
            "commitSha",
            "databaseChangePolicy",
            "executables",
            "flyway",
            "payload",
            "product",
            "releaseSequence",
            "sbom",
            "schemaVersion",
            "signingKeyId",
            "sourceRef",
            "version",
        },
        "manifest",
    )
    if manifest["schemaVersion"] != SCHEMA_VERSION or manifest["product"] != PRODUCT:
        fail("manifest schema/product mismatch")
    version = require_string(manifest["version"], "manifest.version", VERSION_RE)
    if expected_version is not None and version != expected_version:
        fail("manifest version differs from the signed channel")
    sequence = require_positive_int(manifest["releaseSequence"], "manifest.releaseSequence")
    if version_sequence(version) != sequence:
        fail("manifest version and releaseSequence do not agree")
    commit_sha = require_string(manifest["commitSha"], "manifest.commitSha", COMMIT_RE)
    if manifest["sourceRef"] != f"refs/tags/{version}":
        fail("manifest sourceRef must be the matching release tag")
    key_id = require_string(manifest["signingKeyId"], "manifest.signingKeyId", KEY_ID_RE)
    if expected_signing_key_id is not None and key_id != expected_signing_key_id:
        fail("manifest signing key ID does not match the signed channel")
    require_string(manifest["builtAtUtc"], "manifest.builtAtUtc")

    database_policy = manifest["databaseChangePolicy"]
    if not isinstance(database_policy, dict):
        fail("manifest.databaseChangePolicy must be an object")
    exact_keys(
        database_policy,
        {"migrationApproval", "onFailedHealthAfterChange", "rollbackCompatible"},
        "manifest.databaseChangePolicy",
    )
    if (
        database_policy["migrationApproval"] != "required-on-change"
        or database_policy["onFailedHealthAfterChange"] != "fail-closed"
        or database_policy["rollbackCompatible"] is not False
    ):
        fail("manifest database change policy is not fail-closed")

    executables = manifest["executables"]
    if not isinstance(executables, dict):
        fail("manifest.executables must be an object")
    exact_keys(executables, {"backend", "migrator"}, "manifest.executables")
    executable_sha256s: dict[str, str] = {}
    executable_sizes: dict[str, int] = {}
    for name, expected_path in (
        ("backend", "server/uten-imp-server.jar"),
        ("migrator", "server/uten-imp-migrator.jar"),
    ):
        entry = executables[name]
        if not isinstance(entry, dict):
            fail(f"manifest.executables.{name} must be an object")
        exact_keys(
            entry,
            {"path", "sha256", "sizeBytes"},
            f"manifest.executables.{name}",
        )
        if entry["path"] != expected_path:
            fail(f"manifest.executables.{name}.path is not canonical")
        executable_sha256s[expected_path] = require_string(
            entry["sha256"], f"manifest.executables.{name}.sha256", SHA256_RE
        )
        executable_sizes[expected_path] = require_positive_int(
            entry["sizeBytes"],
            f"manifest.executables.{name}.sizeBytes",
            MAX_UNCOMPRESSED_BYTES,
        )

    artifact = manifest["artifact"]
    if not isinstance(artifact, dict):
        fail("manifest.artifact must be an object")
    exact_keys(artifact, {"fileName", "objectKey", "sha256", "sizeBytes"}, "manifest.artifact")
    expected_name = f"uten-imp-{version}-{commit_sha[:12]}.tar.gz"
    if artifact["fileName"] != expected_name:
        fail("release archive filename is not canonical")
    if artifact["objectKey"] != f"releases/{version}/{expected_name}":
        fail("release archive object key is not canonical")
    artifact_sha = require_string(artifact["sha256"], "artifact.sha256", SHA256_RE)
    artifact_size = require_positive_int(artifact["sizeBytes"], "artifact.sizeBytes", MAX_ARCHIVE_BYTES)

    payload = manifest["payload"]
    if not isinstance(payload, dict):
        fail("manifest.payload must be an object")
    exact_keys(
        payload,
        {
            "allowedRoots",
            "checksumsFile",
            "checksumsSha256",
            "fileCount",
            "rootDirectory",
            "uncompressedBytes",
        },
        "manifest.payload",
    )
    if payload["allowedRoots"] != sorted(ALLOWED_PAYLOAD_ROOTS):
        fail("payload allowed roots differ from the updater contract")
    if payload["checksumsFile"] != "SHA256SUMS" or payload["rootDirectory"] != version:
        fail("payload root/checksum path mismatch")
    checksums_sha = require_string(payload["checksumsSha256"], "payload.checksumsSha256", SHA256_RE)
    file_count = require_positive_int(payload["fileCount"], "payload.fileCount", MAX_PAYLOAD_FILES)
    uncompressed_bytes = require_positive_int(
        payload["uncompressedBytes"], "payload.uncompressedBytes", MAX_UNCOMPRESSED_BYTES
    )

    sbom = manifest["sbom"]
    if not isinstance(sbom, dict):
        fail("manifest.sbom must be an object")
    exact_keys(sbom, {"backend", "flutter", "format"}, "manifest.sbom")
    if sbom["format"] != "CycloneDX":
        fail("unsupported SBOM format")
    for name, expected_path in (
        ("backend", "sbom/backend.cdx.json"),
        ("flutter", "sbom/flutter.cdx.json"),
    ):
        entry = sbom[name]
        if not isinstance(entry, dict):
            fail(f"manifest.sbom.{name} must be an object")
        exact_keys(entry, {"path", "sha256"}, f"manifest.sbom.{name}")
        if entry["path"] != expected_path:
            fail(f"manifest.sbom.{name}.path is not canonical")
        require_string(entry["sha256"], f"manifest.sbom.{name}.sha256", SHA256_RE)

    flyway = validate_flyway(manifest["flyway"])
    return {
        "artifactFileName": expected_name,
        "artifactObjectKey": artifact["objectKey"],
        "artifactSha256": artifact_sha,
        "artifactSizeBytes": artifact_size,
        "checksumsSha256": checksums_sha,
        "commitSha": commit_sha,
        "databaseRollbackCompatible": False,
        "executableSha256s": executable_sha256s,
        "executableSizes": executable_sizes,
        "fileCount": file_count,
        "flywayHeadVersion": flyway["headVersion"],
        "flywayMigrationSetSha256": flyway["migrationSetSha256"],
        "flywayMigrations": flyway["migrations"],
        "releaseSequence": sequence,
        "sbomSha256s": {
            "sbom/backend.cdx.json": sbom["backend"]["sha256"],
            "sbom/flutter.cdx.json": sbom["flutter"]["sha256"],
        },
        "signingKeyId": key_id,
        "uncompressedBytes": uncompressed_bytes,
        "version": version,
    }


def _anonymous_verification_file(parent: Path, payload: bytes, label: str) -> int:
    temporary_flag = getattr(os, "O_TMPFILE", 0)
    if not temporary_flag:
        fail(f"{label} requires Linux anonymous temporary file support")
    flags = os.O_RDWR | temporary_flag | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(parent, flags, 0o600)
    except OSError as exc:
        raise ReleaseGuardError(
            f"cannot create anonymous {label} verification snapshot"
        ) from exc
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                fail(f"anonymous {label} snapshot write made no progress")
            view = view[written:]
        os.fsync(descriptor)
        details = os.fstat(descriptor)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_nlink != 0
            or details.st_size != len(payload)
            or stat.S_IMODE(details.st_mode) != 0o600
        ):
            fail(f"anonymous {label} snapshot is not an immutable private inode")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def verify_ssh_signature(
    content_path: Path,
    signature_path: Path,
    allowed_signers_path: Path,
    *,
    identity: str = SIGNING_IDENTITY,
    namespace: str = SIGNATURE_NAMESPACE,
    expected_key_id: str | None = None,
) -> None:
    content_maximum = (
        MAX_CHANNEL_BYTES if content_path.name == "channel.json" else MAX_MANIFEST_BYTES
    )
    content = _read_stable_regular_file(
        content_path,
        content_maximum,
        label="signed content",
    )
    loaded_digest = _LOADED_CANONICAL_JSON_DIGESTS.get(os.path.abspath(content_path))
    if loaded_digest is not None and hashlib.sha256(content).hexdigest() != loaded_digest:
        fail("signed content changed after canonical JSON validation")
    signature = _read_stable_regular_file(
        signature_path,
        MAX_SIGNATURE_BYTES,
        label="detached signature",
    )
    entries = allowed_signer_entries(allowed_signers_path, identity)
    if expected_key_id is not None:
        require_string(expected_key_id, "expected signing key ID", KEY_ID_RE)
        selected = entries.get(expected_key_id)
        if not selected:
            fail("signed metadata claims a key that is not authorized")
        policy = (selected + "\n").encode("ascii")
    else:
        policy = ("\n".join(entries.values()) + "\n").encode("ascii")

    signer_descriptor = _anonymous_verification_file(
        content_path.parent,
        policy,
        "allowed_signers",
    )
    signature_descriptor = -1
    try:
        signature_descriptor = _anonymous_verification_file(
            content_path.parent,
            signature,
            "detached signature",
        )
        completed = subprocess.run(
            [
                str(SSH_KEYGEN_PATH),
                "-Y",
                "verify",
                "-f",
                f"/proc/self/fd/{signer_descriptor}",
                "-I",
                identity,
                "-n",
                namespace,
                "-s",
                f"/proc/self/fd/{signature_descriptor}",
            ],
            input=content,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            pass_fds=(signer_descriptor, signature_descriptor),
        )
    finally:
        if signature_descriptor >= 0:
            os.close(signature_descriptor)
        os.close(signer_descriptor)
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        fail(f"Ed25519 signature verification failed: {detail}")


def allowed_signer_entries(
    allowed_signers_path: Path, identity: str = SIGNING_IDENTITY
) -> dict[str, str]:
    """Return fingerprint -> canonical three-field line for the fixed identity."""

    if not identity or any(
        character.isspace() or character == "," for character in identity
    ):
        fail("release signing identity is not canonical")
    raw = _read_stable_regular_file(
        allowed_signers_path,
        MAX_ALLOWED_SIGNERS_BYTES,
        label="allowed_signers",
    )
    authorized: dict[str, str] = {}
    try:
        policy = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ReleaseGuardError("allowed_signers is not canonical ASCII text") from exc
    if not policy.endswith("\n") or "\r" in policy:
        fail("allowed_signers must end in one canonical LF newline")
    lines = policy[:-1].split("\n")
    if not lines or any(not line for line in lines):
        fail("allowed_signers contains an empty or comment-only line")
    for line in lines:
        fields = line.split(" ")
        if len(fields) != 3 or any(not field for field in fields):
            fail("allowed_signers lines must contain exactly three fields")
        principals, key_type, encoded_key = fields
        principal_values = principals.split(",")
        if len(principal_values) != len(set(principal_values)):
            fail("allowed_signers contains a duplicate principal")
        if principal_values != [identity]:
            fail("allowed_signers principal differs from the fixed release identity")
        if key_type != "ssh-ed25519":
            fail("release signing identity must use an Ed25519 key")
        try:
            public_blob = base64.b64decode(encoded_key, validate=True)
        except ValueError as exc:
            raise ReleaseGuardError("allowed_signers contains invalid base64") from exc
        if (
            base64.b64encode(public_blob).decode("ascii") != encoded_key
            or len(public_blob) != 51
            or public_blob[:19]
            != b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
        ):
            fail("allowed_signers contains a non-canonical Ed25519 public key")
        fingerprint = base64.b64encode(
            hashlib.sha256(public_blob).digest()
        ).decode("ascii")
        key_id = f"SHA256:{fingerprint.rstrip('=')}"
        if key_id in authorized:
            fail("allowed_signers contains a duplicate key fingerprint")
        authorized[key_id] = f"{identity} {key_type} {encoded_key}"
    if not authorized:
        fail(f"allowed_signers does not authorize identity {identity}")
    return authorized


def allowed_signing_key_ids(
    allowed_signers_path: Path, identity: str = SIGNING_IDENTITY
) -> set[str]:
    return set(allowed_signer_entries(allowed_signers_path, identity))


def normalized_member_name(name: str, expected_root: str) -> tuple[str, ...]:
    if (
        not name
        or "\\" in name
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in name)
    ):
        fail(f"archive member has unsupported characters: {name!r}")
    pure = PurePosixPath(name)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        fail(f"archive member path is unsafe: {name!r}")
    if not pure.parts or pure.parts[0] != expected_root:
        fail(f"archive member is outside the expected release root: {name!r}")
    if len(pure.parts) > 1:
        second = pure.parts[1]
        if second != "SHA256SUMS" and second not in ALLOWED_PAYLOAD_ROOTS:
            fail(f"archive member has an unexpected payload root: {name!r}")
        if second == "SHA256SUMS" and len(pure.parts) != 2:
            fail("SHA256SUMS must be at the release root")
    return pure.parts


def safe_extract(archive: Path, destination_parent: Path, manifest_info: dict[str, Any]) -> Path:
    if not archive.is_file() or archive.is_symlink():
        fail("release archive is missing or unsafe")
    if archive.stat().st_size != manifest_info["artifactSizeBytes"]:
        fail("release archive size differs from the signed manifest")
    if sha256_file(archive) != manifest_info["artifactSha256"]:
        fail("release archive SHA-256 differs from the signed manifest")
    expected_root = manifest_info["version"]
    destination_parent.mkdir(parents=True, exist_ok=True, mode=0o750)
    destination_root = destination_parent / expected_root
    if destination_root.exists() or destination_root.is_symlink():
        fail(f"safe extraction target already exists: {destination_root}")
    destination_root.mkdir(mode=0o755)
    seen: set[tuple[str, ...]] = set()
    regular_members = 0
    total_bytes = 0
    try:
        with tarfile.open(archive, mode="r:gz") as bundle:
            members = bundle.getmembers()
            if len(members) > manifest_info["fileCount"] * 4 + 128:
                fail("archive contains too many members")
            for member in members:
                parts = normalized_member_name(member.name, expected_root)
                if parts in seen:
                    fail(f"archive contains a duplicate member: {member.name}")
                seen.add(parts)
                if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                    fail(f"archive contains a forbidden non-regular member: {member.name}")
                if not member.isdir() and not member.isfile():
                    fail(f"archive contains an unsupported member: {member.name}")
                relative_parts = parts[1:]
                if not relative_parts:
                    if not member.isdir():
                        fail("release root archive member must be a directory")
                    continue
                target = destination_root.joinpath(*relative_parts)
                target_parent = target.parent
                target_parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                if member.isdir():
                    if target.exists() and not target.is_dir():
                        fail(f"archive directory collides with a file: {member.name}")
                    target.mkdir(exist_ok=True, mode=0o755)
                    os.chmod(target, 0o755)
                    continue
                regular_members += 1
                total_bytes += member.size
                if total_bytes > manifest_info["uncompressedBytes"]:
                    fail("archive expands beyond the signed byte count")
                source = bundle.extractfile(member)
                if source is None:
                    fail(f"cannot read archive member: {member.name}")
                flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(target, flags, 0o644)
                try:
                    with os.fdopen(descriptor, "wb", closefd=False) as output:
                        shutil.copyfileobj(source, output, length=1024 * 1024)
                        output.flush()
                        os.fsync(output.fileno())
                finally:
                    os.close(descriptor)
                if target.stat().st_size != member.size:
                    fail(f"archive member size changed during extraction: {member.name}")
                os.chmod(target, 0o644)
        if regular_members != manifest_info["fileCount"] + 1:
            fail("archive regular-file count differs from the signed manifest")
        if total_bytes != manifest_info["uncompressedBytes"]:
            fail("archive expanded byte count differs from the signed manifest")
        verify_payload(destination_root, manifest_info)
        return destination_root
    except Exception:
        shutil.rmtree(destination_root, ignore_errors=True)
        raise


def safe_payload_name(name: str) -> str:
    pure = PurePosixPath(name)
    if pure.is_absolute() or any(part in ("", ".", "..") for part in pure.parts):
        fail(f"unsafe checksum path: {name!r}")
    if "\\" in name or any(ord(character) < 0x20 or ord(character) == 0x7F for character in name):
        fail(f"unsupported checksum path characters: {name!r}")
    if not pure.parts or pure.parts[0] not in ALLOWED_PAYLOAD_ROOTS:
        fail(f"unexpected checksum payload root: {name!r}")
    return pure.as_posix()


def validate_static_entry_response(
    status: int, content_type: str, body: bytes, expected_version: str | None = None
) -> None:
    """Validate the loopback nginx index without accepting redirects or generic error pages."""
    media_type = content_type.split(";", 1)[0].strip().lower()
    if status != 200 or media_type != "text/html":
        fail("static entry returned unexpected HTTP metadata")
    if len(body) < 1 or len(body) > 2 * 1024 * 1024:
        fail("static entry response size is outside the allowed range")
    if b"flutter_bootstrap.js" not in body:
        fail("static entry is missing the Flutter bootstrap marker")
    if expected_version is not None:
        version_sequence(expected_version)
        expected_meta = (
            f'<meta name="uten-release-version" content="{expected_version}">'
        ).encode("ascii")
        if body.count(expected_meta) != 1:
            fail("static entry does not identify the activated release exactly once")


def validate_web_version_value(
    version_value: dict[str, Any], manifest_info: dict[str, Any]
) -> None:
    exact_keys(
        version_value,
        {"commitSha", "product", "releaseSequence", "schemaVersion", "version"},
        "web/version.json",
    )
    if (
        version_value["schemaVersion"] != 1
        or version_value["product"] != PRODUCT
        or version_value["version"] != manifest_info["version"]
        or version_value["commitSha"] != manifest_info["commitSha"]
        or version_value["releaseSequence"] != manifest_info["releaseSequence"]
    ):
        fail("web/version.json disagrees with the signed release manifest")


def validate_web_release_identity(root: Path, manifest_info: dict[str, Any]) -> None:
    version_path = root / "web/version.json"
    version_value = load_json(version_path, 64 * 1024)
    validate_web_version_value(version_value, manifest_info)
    try:
        index_body = (root / "web/index.html").read_bytes()
    except OSError as exc:
        raise ReleaseGuardError("cannot read stamped web/index.html") from exc
    expected_meta = (
        f'<meta name="uten-release-version" content="{manifest_info["version"]}">'
    ).encode("ascii")
    if index_body.count(expected_meta) != 1 or b"__UTEN_RELEASE_VERSION__" in index_body:
        fail("web/index.html release-version meta is missing or not canonical")


def verify_executable_jar(
    jar_path: Path,
    manifest_info: dict[str, Any],
    *,
    migration_prefix: str,
    migrator: bool,
) -> None:
    expected_migrations = {
        migration["file"]: migration["sha256"]
        for migration in manifest_info["flywayMigrations"]
    }
    actual_migrations: dict[str, str] = {}
    try:
        with zipfile.ZipFile(jar_path) as archive:
            archive_names = [info.filename for info in archive.infolist()]
            if migrator:
                if archive_names.count("META-INF/MANIFEST.MF") != 1:
                    fail("migrator JAR must contain exactly one executable manifest")
                manifest_entry = archive.getinfo("META-INF/MANIFEST.MF")
                if manifest_entry.file_size > 64 * 1024:
                    fail("migrator JAR executable manifest is unexpectedly large")
                try:
                    manifest_text = archive.read(manifest_entry).decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise ReleaseGuardError(
                        "migrator JAR executable manifest is not UTF-8"
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
                    and not info.filename.startswith(migration_prefix)
                ):
                    fail(
                        "executable JAR contains a Flyway migration outside its "
                        f"canonical location: {info.filename}"
                    )
                if not info.filename.startswith(migration_prefix) or not info.filename.endswith(
                    ".sql"
                ):
                    continue
                name = info.filename[len(migration_prefix) :]
                if (
                    "/" in name
                    or not MIGRATION_FILE_RE.fullmatch(name)
                    or name in actual_migrations
                ):
                    fail(
                        "executable JAR contains an unsafe or duplicate Flyway entry: "
                        f"{info.filename}"
                    )
                if info.file_size > 16 * 1024 * 1024:
                    fail(f"executable JAR Flyway entry is unexpectedly large: {name}")
                digest = hashlib.sha256()
                with archive.open(info) as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
                actual_migrations[name] = digest.hexdigest()
    except (OSError, zipfile.BadZipFile) as exc:
        raise ReleaseGuardError("release executable is not a valid JAR") from exc
    if actual_migrations != expected_migrations:
        fail("executable JAR Flyway migrations differ from the signed manifest")


def verify_payload(root: Path, manifest_info: dict[str, Any]) -> None:
    checksums_path = root / "SHA256SUMS"
    if not checksums_path.is_file() or checksums_path.is_symlink():
        fail("extracted SHA256SUMS is missing or unsafe")
    if checksums_path.stat().st_size > MAX_CHECKSUMS_BYTES:
        fail("extracted SHA256SUMS exceeds the allowed size")
    if sha256_file(checksums_path) != manifest_info["checksumsSha256"]:
        fail("SHA256SUMS digest differs from the signed manifest")
    expected: dict[str, str] = {}
    try:
        checksum_lines = checksums_path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ReleaseGuardError("SHA256SUMS is not UTF-8 text") from exc
    for line_number, line in enumerate(checksum_lines, start=1):
        if len(line) < 67 or line[64:66] != "  ":
            fail(f"malformed SHA256SUMS line {line_number}")
        digest = line[:64]
        name = safe_payload_name(line[66:])
        if not SHA256_RE.fullmatch(digest) or name in expected:
            fail(f"invalid or duplicate SHA256SUMS entry on line {line_number}")
        expected[name] = digest
    if len(expected) != manifest_info["fileCount"]:
        fail("SHA256SUMS file count differs from the signed manifest")
    actual: dict[str, Path] = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            fail(f"extracted payload contains a symbolic link: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            fail(f"extracted payload contains a non-regular file: {path}")
        relative = path.relative_to(root).as_posix()
        if relative == ".release" or relative.startswith(".release/"):
            continue
        if relative == "SHA256SUMS":
            continue
        safe_payload_name(relative)
        actual[relative] = path
    if set(actual) != set(expected):
        fail("extracted payload files differ from SHA256SUMS coverage")
    for name, digest in expected.items():
        if sha256_file(actual[name]) != digest:
            fail(f"extracted payload checksum mismatch: {name}")
    for name, digest in manifest_info["sbomSha256s"].items():
        if expected.get(name) != digest:
            fail(f"SBOM digest disagrees with the signed payload inventory: {name}")
    if set(name for name in actual if name.startswith("server/")) != {
        "server/uten-imp-migrator.jar",
        "server/uten-imp-server.jar",
    }:
        fail("extracted payload has an unexpected server executable set")
    for name, digest in manifest_info["executableSha256s"].items():
        if expected.get(name) != digest:
            fail(f"executable digest disagrees with signed payload inventory: {name}")
        if actual[name].stat().st_size != manifest_info["executableSizes"][name]:
            fail(f"executable size disagrees with signed manifest: {name}")
    verify_executable_jar(
        actual["server/uten-imp-server.jar"],
        manifest_info,
        migration_prefix="BOOT-INF/classes/db/migration/",
        migrator=False,
    )
    verify_executable_jar(
        actual["server/uten-imp-migrator.jar"],
        manifest_info,
        migration_prefix="db/migration/",
        migrator=True,
    )
    for required in (
        "web/index.html",
        "web/version.json",
        "sbom/backend.cdx.json",
        "sbom/flutter.cdx.json",
    ):
        if required not in actual:
            fail(f"extracted payload is missing {required}")
    validate_web_release_identity(root, manifest_info)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)
    manifest = subcommands.add_parser("validate-manifest")
    manifest.add_argument("--manifest", required=True, type=Path)
    manifest.add_argument("--expected-version")
    manifest.add_argument("--expected-signing-key-id")
    manifest.add_argument("--json", action="store_true")

    bundle = subcommands.add_parser("verify-bundle")
    bundle.add_argument("--manifest", required=True, type=Path)
    bundle.add_argument("--archive", required=True, type=Path)
    bundle.add_argument("--destination-parent", required=True, type=Path)
    flyway = subcommands.add_parser("verified-flyway-checksums")
    flyway.add_argument("--manifest", required=True, type=Path)
    flyway.add_argument("--signature", required=True, type=Path)
    flyway.add_argument("--allowed-signers", required=True, type=Path)
    flyway.add_argument("--expected-version", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "verified-flyway-checksums":
            require_privileged_restore_paths(
                args.manifest, args.signature, args.allowed_signers
            )
        manifest = load_json(
            args.manifest,
            MAX_MANIFEST_BYTES,
            require_canonical=True,
        )
        if args.command == "verified-flyway-checksums":
            claimed_key_id = require_string(
                manifest.get("signingKeyId"),
                "manifest.signingKeyId",
                KEY_ID_RE,
            )
            verify_ssh_signature(
                args.manifest,
                args.signature,
                args.allowed_signers,
                expected_key_id=claimed_key_id,
            )
        info = validate_manifest(
            manifest,
            expected_version=getattr(args, "expected_version", None),
            expected_signing_key_id=getattr(args, "expected_signing_key_id", None),
        )
        if args.command == "validate-manifest":
            if args.json:
                print(json.dumps(info, sort_keys=True, separators=(",", ":")))
            else:
                print(f"VALID {info['version']} {info['commitSha']}")
        elif args.command == "verify-bundle":
            extracted = safe_extract(args.archive, args.destination_parent, info)
            print(extracted)
        elif args.command == "verified-flyway-checksums":
            for migration in info["flywayMigrations"]:
                print(
                    f"{migration['version']}\t{migration['file']}\t"
                    f"{migration['flywayChecksum']}"
                )
        else:
            fail(f"unsupported command: {args.command}")
        return 0
    except (OSError, ReleaseGuardError) as exc:
        print(f"release guard error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
