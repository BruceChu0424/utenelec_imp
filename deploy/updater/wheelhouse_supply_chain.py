#!/usr/bin/env python3
"""Build-time and commissioning checks for the offline updater wheelhouse.

The verifier intentionally uses only the Python standard library so that it can
run before any third-party wheel is installed.  It binds five views of the same
dependency set: the hash lock, wheel archives, SHA256SUMS, CycloneDX BOM, and
the installed ``*.dist-info`` inventory.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import csv
import datetime as dt
import email.parser
import hashlib
import io
import json
import os
import re
import stat
import sys
import urllib.parse
import urllib.request
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn


TARGET_OS = "ubuntu-24.04"
TARGET_ARCH = "x86_64"
TARGET_IMPLEMENTATION = "cpython"
TARGET_PYTHON = "3.12"
TOP_LEVEL_REQUIREMENT = ("oss2", "2.19.1")
SOURCE_DISTRIBUTIONS = {
    "aliyun-python-sdk-core": "aliyun-python-sdk-core-2.16.0.tar.gz",
    "crcmod": "crcmod-1.7.tar.gz",
    "oss2": "oss2-2.19.1.tar.gz",
}
IN_TOTO_STATEMENT = "https://in-toto.io/Statement/v1"
CYCLONEDX_PREDICATE = "https://cyclonedx.org/bom"
BUILD_TYPE = "https://uten.cn/supply-chain/updater-wheelhouse/v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.!+_-]*$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
WHEEL_FILE_RE = re.compile(
    r"^(?P<distribution>[A-Za-z0-9][A-Za-z0-9_.]*)-"
    r"(?P<version>[A-Za-z0-9][A-Za-z0-9.!+_]*)-"
    r"(?P<python>[A-Za-z0-9.]+)-(?P<abi>[A-Za-z0-9.]+)-"
    r"(?P<platform>[A-Za-z0-9_.]+)\.whl$"
)
MANYLINUX_RE = re.compile(r"^manylinux(?:2014|_[0-9]+_[0-9]+)_x86_64$")
MAX_LOCK_BYTES = 512 * 1024
MAX_WHEEL_BYTES = 128 * 1024 * 1024
MAX_WHEEL_MEMBERS = 50_000
MAX_WHEEL_EXPANDED_BYTES = 512 * 1024 * 1024
MAX_JSON_BYTES = 16 * 1024 * 1024
RUNTIME_LOCK_HEADER = (
    "# CPython 3.12 / Ubuntu 24.04 x86_64 updater runtime.\n"
    "# Exactly one reviewed wheel is allowed for every direct/transitive dependency.\n"
)


class WheelhouseError(ValueError):
    """Raised when the wheelhouse supply-chain contract is violated."""


def fail(message: str) -> NoReturn:
    raise WheelhouseError(message)


def normalize_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def write_exclusive(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        fail(f"refusing to replace generated output: {path}")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
    finally:
        os.close(descriptor)


def require_regular_file(path: Path, label: str, maximum: int) -> None:
    try:
        details = path.lstat()
    except FileNotFoundError as exc:
        raise WheelhouseError(f"{label} is missing: {path}") from exc
    if not stat.S_ISREG(details.st_mode) or stat.S_ISLNK(details.st_mode):
        fail(f"{label} must be a regular non-symlink file: {path}")
    if details.st_size < 1 or details.st_size > maximum:
        fail(f"{label} size is outside the allowed range: {path}")


@dataclass(frozen=True)
class LockedRequirement:
    name: str
    version: str
    hashes: tuple[str, ...]


def parse_requirements_lock(
    path: Path,
    *,
    one_hash_per_package: bool = True,
    require_runtime_root: bool = True,
) -> dict[str, LockedRequirement]:
    require_regular_file(path, "requirements lock", MAX_LOCK_BYTES)
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except UnicodeDecodeError as exc:
        raise WheelhouseError("requirements lock must be ASCII") from exc
    logical: list[tuple[int, str]] = []
    pending = ""
    for number, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "#" in stripped or ";" in stripped or stripped.startswith("-"):
            fail(f"requirements lock line {number} contains a directive or marker")
        continued = stripped.endswith("\\")
        fragment = stripped[:-1].strip() if continued else stripped
        pending = f"{pending} {fragment}".strip()
        if not continued:
            logical.append((number, pending))
            pending = ""
    if pending:
        fail("requirements lock ends with an unfinished continuation")

    result: dict[str, LockedRequirement] = {}
    entry_re = re.compile(
        r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)=="
        r"(?P<version>[A-Za-z0-9][A-Za-z0-9.!+_-]*)"
        r"(?P<hashes>(?:\s+--hash=sha256:[0-9a-f]{64})+)"
    )
    for number, logical_line in logical:
        match = entry_re.fullmatch(logical_line)
        if match is None:
            fail(f"requirements lock entry ending at line {number} is not an exact SHA-256 pin")
        name = normalize_name(match.group("name"))
        version = match.group("version")
        hashes = tuple(re.findall(r"--hash=sha256:([0-9a-f]{64})", match.group("hashes")))
        if name in result:
            fail(f"duplicate requirements lock package: {name}")
        if len(set(hashes)) != len(hashes) or (one_hash_per_package and len(hashes) != 1):
            fail(f"requirements lock hashes are duplicate or ambiguous for {name}")
        result[name] = LockedRequirement(name, version, hashes)
    if not result:
        fail("requirements lock contains no packages")
    if require_runtime_root:
        top_level = result.get(TOP_LEVEL_REQUIREMENT[0])
        if top_level is None or top_level.version != TOP_LEVEL_REQUIREMENT[1]:
            fail("requirements lock must pin oss2==2.19.1")
    return result


def validate_requirements_input(path: Path) -> None:
    require_regular_file(path, "requirements input", 4096)
    try:
        lines = [
            line.strip()
            for line in path.read_text(encoding="ascii").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    except UnicodeDecodeError as exc:
        raise WheelhouseError("requirements input must be ASCII") from exc
    if lines != ["oss2==2.19.1"]:
        fail("requirements input must contain only oss2==2.19.1")


@dataclass(frozen=True)
class WheelInfo:
    filename: str
    name: str
    display_name: str
    version: str
    sha256: str
    requires_dist: tuple[str, ...]


def _parse_wheel_filename(filename: str) -> re.Match[str]:
    match = WHEEL_FILE_RE.fullmatch(filename)
    if match is None:
        fail(f"wheel filename is not canonical or has an unsupported build tag: {filename}")
    python_tags = match.group("python").split(".")
    abi_tags = match.group("abi").split(".")
    platform_tags = match.group("platform").split(".")
    if platform_tags == ["any"]:
        if abi_tags != ["none"] or "py3" not in python_tags:
            fail(f"universal wheel is not Python 3 compatible: {filename}")
    else:
        if not platform_tags or any(MANYLINUX_RE.fullmatch(tag) is None for tag in platform_tags):
            fail(f"binary wheel is not x86_64 manylinux: {filename}")
        for abi in abi_tags:
            if abi == "cp312":
                if python_tags != ["cp312"]:
                    fail(f"CPython 3.12 ABI wheel has a mismatched Python tag: {filename}")
            elif abi == "abi3":
                if not all(re.fullmatch(r"cp3[0-9]+", tag) for tag in python_tags):
                    fail(f"abi3 wheel has a non-CPython tag: {filename}")
                if any(int(tag[3:]) > 12 for tag in python_tags):
                    fail(f"abi3 wheel requires a newer CPython than 3.12: {filename}")
            else:
                fail(f"binary wheel has an unsupported ABI for CPython 3.12: {filename}")
    return match


def _safe_zip_member(name: str) -> PurePosixPath:
    if not name or "\\" in name or any(ord(char) < 0x20 or ord(char) == 0x7F for char in name):
        fail(f"wheel contains an unsafe member name: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail(f"wheel contains path traversal: {name!r}")
    return path


def inspect_wheel(path: Path) -> WheelInfo:
    require_regular_file(path, "wheel", MAX_WHEEL_BYTES)
    match = _parse_wheel_filename(path.name)
    filename_name = normalize_name(match.group("distribution"))
    filename_version = match.group("version")
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            if not infos or len(infos) > MAX_WHEEL_MEMBERS:
                fail(f"wheel member count is outside the allowed range: {path.name}")
            names: set[str] = set()
            expanded = 0
            metadata_members: list[zipfile.ZipInfo] = []
            wheel_members: list[zipfile.ZipInfo] = []
            record_members: list[zipfile.ZipInfo] = []
            for info in infos:
                member = _safe_zip_member(info.filename)
                if info.filename in names:
                    fail(f"wheel contains a duplicate member: {path.name}:{info.filename}")
                names.add(info.filename)
                mode = info.external_attr >> 16
                file_type = stat.S_IFMT(mode)
                if stat.S_ISLNK(mode) or (
                    file_type and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))
                ):
                    fail(f"wheel contains a forbidden file type: {path.name}:{info.filename}")
                expanded += info.file_size
                if expanded > MAX_WHEEL_EXPANDED_BYTES:
                    fail(f"wheel expands beyond the allowed limit: {path.name}")
                if member.name.lower().endswith(".pth"):
                    fail(f"wheel contains executable .pth content: {path.name}:{info.filename}")
                if len(member.parts) == 2 and member.parts[0].endswith(".dist-info"):
                    if member.name == "METADATA":
                        metadata_members.append(info)
                    elif member.name == "WHEEL":
                        wheel_members.append(info)
                    elif member.name == "RECORD":
                        record_members.append(info)
            if len(metadata_members) != 1 or len(wheel_members) != 1 or len(record_members) != 1:
                fail(f"wheel must contain exactly one METADATA, WHEEL, and RECORD: {path.name}")
            metadata_root = PurePosixPath(metadata_members[0].filename).parts[0]
            if any(PurePosixPath(item.filename).parts[0] != metadata_root for item in wheel_members + record_members):
                fail(f"wheel dist-info control files do not share one root: {path.name}")
            raw_metadata = archive.read(metadata_members[0])
            if len(raw_metadata) > 4 * 1024 * 1024:
                fail(f"wheel metadata is unexpectedly large: {path.name}")
            raw_wheel = archive.read(wheel_members[0])
            if len(raw_wheel) > 1024 * 1024:
                fail(f"wheel control metadata is unexpectedly large: {path.name}")
            try:
                metadata = email.parser.BytesParser().parsebytes(raw_metadata)
                wheel_metadata = email.parser.BytesParser().parsebytes(raw_wheel)
            except Exception as exc:
                raise WheelhouseError(f"cannot parse wheel metadata: {path.name}") from exc
            expected_tags = {
                f"{python_tag}-{abi_tag}-{platform_tag}"
                for python_tag in match.group("python").split(".")
                for abi_tag in match.group("abi").split(".")
                for platform_tag in match.group("platform").split(".")
            }
            wheel_tags = wheel_metadata.get_all("Tag", [])
            pure = match.group("platform") == "any" and match.group("abi") == "none"
            if (
                wheel_metadata.get("Wheel-Version") != "1.0"
                or wheel_metadata.get("Root-Is-Purelib", "").lower()
                != ("true" if pure else "false")
                or len(wheel_tags) != len(set(wheel_tags))
                or set(wheel_tags) != expected_tags
            ):
                fail(f"wheel WHEEL metadata differs from its filename tags: {path.name}")
            display_name = metadata.get("Name", "")
            version = metadata.get("Version", "")
            name = normalize_name(display_name)
            if not NAME_RE.fullmatch(display_name) or not VERSION_RE.fullmatch(version):
                fail(f"wheel metadata name/version is invalid: {path.name}")
            if name != filename_name or version != filename_version:
                fail(f"wheel filename and METADATA identity differ: {path.name}")
            expected_dist_info = normalize_name(metadata_root[:-10])
            if expected_dist_info != f"{name}-{normalize_name(version)}":
                fail(f"wheel dist-info root differs from its identity: {path.name}")
            requires = tuple(metadata.get_all("Requires-Dist", []))
    except zipfile.BadZipFile as exc:
        raise WheelhouseError(f"invalid wheel ZIP: {path.name}") from exc
    return WheelInfo(path.name, name, display_name, version, sha256_file(path), requires)


def load_wheelhouse(wheelhouse: Path) -> dict[str, WheelInfo]:
    if not wheelhouse.is_dir() or wheelhouse.is_symlink():
        fail("wheelhouse must be a real directory")
    entries = list(wheelhouse.iterdir())
    if not entries:
        fail("wheelhouse is empty")
    result: dict[str, WheelInfo] = {}
    for path in entries:
        if path.suffix != ".whl":
            fail(f"wheelhouse must be flat and wheel-only: {path.name}")
        info = inspect_wheel(path)
        if info.name in result:
            fail(f"wheelhouse contains duplicate distributions: {info.name}")
        result[info.name] = info
    return result


def parse_sha256s(path: Path) -> dict[str, str]:
    require_regular_file(path, "wheel SHA256SUMS", MAX_LOCK_BYTES)
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except UnicodeDecodeError as exc:
        raise WheelhouseError("wheel SHA256SUMS must be ASCII") from exc
    result: dict[str, str] = {}
    previous = ""
    for number, line in enumerate(lines, 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+!-]*\.whl)", line)
        if match is None or match.group(2) in result:
            fail(f"invalid wheel SHA256SUMS line {number}")
        filename = match.group(2)
        if previous and filename.encode("ascii") <= previous.encode("ascii"):
            fail("wheel SHA256SUMS is not bytewise sorted")
        previous = filename
        result[filename] = match.group(1)
    if not result:
        fail("wheel SHA256SUMS is empty")
    return result


def _dependency_names(info: WheelInfo, locked_names: set[str]) -> list[str]:
    dependencies: set[str] = set()
    for requirement in info.requires_dist:
        match = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", requirement)
        if match is None:
            fail(f"wheel has an invalid Requires-Dist entry: {info.filename}")
        name = normalize_name(match.group(1))
        if name in locked_names:
            dependencies.add(name)
    return sorted(dependencies)


def _purl(name: str, version: str) -> str:
    return f"pkg:pypi/{urllib.parse.quote(name, safe='')}@{urllib.parse.quote(version, safe='.!+-_')}"


def build_sbom(
    wheels: dict[str, WheelInfo],
    lock_path: Path,
    requirements_input: Path,
    source_lock: Path,
    build_lock: Path,
    builder_script: Path,
    verifier_source: Path,
    commit: str,
    timestamp: str,
    builder_image: str,
) -> dict[str, Any]:
    source_requirements = parse_requirements_lock(source_lock)
    source_by_identity = {
        (item.name, item.version): item.hashes[0] for item in source_requirements.values()
    }
    refs = {name: _purl(name, wheel.version) for name, wheel in wheels.items()}
    components: list[dict[str, Any]] = []
    for name in sorted(wheels):
        wheel = wheels[name]
        properties = [
            {"name": "uten:python:wheel-file", "value": wheel.filename},
            {"name": "uten:python:wheel-target", "value": f"{TARGET_OS}-{TARGET_ARCH}-{TARGET_IMPLEMENTATION}-{TARGET_PYTHON}"},
        ]
        source_digest = source_by_identity.get((name, wheel.version))
        if source_digest:
            properties.append({"name": "uten:python:source-distribution-sha256", "value": source_digest})
        components.append(
            {
                "bom-ref": refs[name],
                "hashes": [{"alg": "SHA-256", "content": wheel.sha256}],
                "name": name,
                "properties": properties,
                "purl": refs[name],
                "type": "library",
                "version": wheel.version,
            }
        )
    dependencies = [
        {
            "ref": "urn:uten:updater-wheelhouse",
            "dependsOn": [refs[TOP_LEVEL_REQUIREMENT[0]]],
        },
        *[
            {
                "ref": refs[name],
                "dependsOn": [
                    refs[dependency]
                    for dependency in _dependency_names(wheels[name], set(wheels))
                ],
            }
            for name in sorted(wheels)
        ],
    ]
    seed = f"uten-imp-updater:{commit}:{sha256_file(lock_path)}"
    return {
        "bomFormat": "CycloneDX",
        "components": components,
        "dependencies": dependencies,
        "metadata": {
            "component": {
                "bom-ref": "urn:uten:updater-wheelhouse",
                "name": "uten-imp-updater-wheelhouse",
                "type": "application",
                "version": commit,
            },
            "properties": [
                {"name": "uten:build:type", "value": BUILD_TYPE},
                {"name": "uten:builder:image", "value": builder_image},
                {"name": "uten:builder:script-sha256", "value": sha256_file(builder_script)},
                {"name": "uten:builder:verifier-sha256", "value": sha256_file(verifier_source)},
                {"name": "uten:git:commit", "value": commit},
                {"name": "uten:python:requirements-in-sha256", "value": sha256_file(requirements_input)},
                {"name": "uten:python:requirements-lock-sha256", "value": sha256_file(lock_path)},
                {"name": "uten:python:source-lock-sha256", "value": sha256_file(source_lock)},
                {"name": "uten:python:build-lock-sha256", "value": sha256_file(build_lock)},
                {"name": "uten:target:architecture", "value": TARGET_ARCH},
                {"name": "uten:target:os", "value": TARGET_OS},
                {"name": "uten:target:python", "value": f"{TARGET_IMPLEMENTATION}-{TARGET_PYTHON}"},
            ],
            "timestamp": timestamp,
        },
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, seed)}",
        "specVersion": "1.6",
        "version": 1,
    }


def build_attestation(
    wheels: dict[str, WheelInfo], lock_path: Path, sums_path: Path, sbom: dict[str, Any]
) -> dict[str, Any]:
    subjects = [
        {"digest": {"sha256": sha256_file(lock_path)}, "name": "updater-requirements.lock"},
        {"digest": {"sha256": sha256_file(sums_path)}, "name": "updater-wheelhouse.SHA256SUMS"},
    ]
    subjects.extend(
        {"digest": {"sha256": wheel.sha256}, "name": f"wheelhouse/{wheel.filename}"}
        for wheel in sorted(wheels.values(), key=lambda item: item.filename.encode("ascii"))
    )
    return {
        "_type": IN_TOTO_STATEMENT,
        "predicate": sbom,
        "predicateType": CYCLONEDX_PREDICATE,
        "subject": subjects,
    }


def load_canonical_json(path: Path, label: str) -> dict[str, Any]:
    require_regular_file(path, label, MAX_JSON_BYTES)
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise WheelhouseError(f"{label} is not valid UTF-8 JSON") from exc
    if not isinstance(value, dict) or canonical_json_bytes(value) != raw:
        fail(f"{label} is not canonical JSON")
    return value


def _parse_timestamp(value: str) -> None:
    if not isinstance(value, str) or not value.endswith("Z"):
        fail("SBOM timestamp is not canonical UTC")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise WheelhouseError("SBOM timestamp is invalid") from exc
    if parsed.tzinfo is None or parsed.microsecond or parsed.utcoffset() != dt.timedelta(0):
        fail("SBOM timestamp must be second-precision UTC")


def validate_sbom(sbom: dict[str, Any], wheels: dict[str, WheelInfo], lock: dict[str, LockedRequirement]) -> None:
    expected_top = {"bomFormat", "components", "dependencies", "metadata", "serialNumber", "specVersion", "version"}
    if set(sbom) != expected_top or sbom.get("bomFormat") != "CycloneDX" or sbom.get("specVersion") != "1.6" or sbom.get("version") != 1:
        fail("wheelhouse SBOM top-level contract is invalid")
    if not re.fullmatch(r"urn:uuid:[0-9a-f-]{36}", sbom.get("serialNumber", "")):
        fail("wheelhouse SBOM serial number is invalid")
    metadata = sbom.get("metadata")
    if not isinstance(metadata, dict) or set(metadata) != {"component", "properties", "timestamp"}:
        fail("wheelhouse SBOM metadata contract is invalid")
    _parse_timestamp(metadata["timestamp"])
    component = metadata["component"]
    if component != {
        "bom-ref": "urn:uten:updater-wheelhouse",
        "name": "uten-imp-updater-wheelhouse",
        "type": "application",
        "version": component.get("version") if isinstance(component, dict) else None,
    } or not COMMIT_RE.fullmatch(component.get("version", "")):
        fail("wheelhouse SBOM application identity is invalid")
    properties = metadata["properties"]
    if not isinstance(properties, list) or any(not isinstance(item, dict) or set(item) != {"name", "value"} for item in properties):
        fail("wheelhouse SBOM properties are invalid")
    property_map = {item["name"]: item["value"] for item in properties}
    if len(property_map) != len(properties):
        fail("wheelhouse SBOM contains duplicate metadata properties")
    required_properties = {
        "uten:build:type": BUILD_TYPE,
        "uten:target:architecture": TARGET_ARCH,
        "uten:target:os": TARGET_OS,
        "uten:target:python": f"{TARGET_IMPLEMENTATION}-{TARGET_PYTHON}",
    }
    expected_property_names = {
        *required_properties,
        "uten:builder:image",
        "uten:builder:script-sha256",
        "uten:builder:verifier-sha256",
        "uten:git:commit",
        "uten:python:requirements-in-sha256",
        "uten:python:requirements-lock-sha256",
        "uten:python:source-lock-sha256",
        "uten:python:build-lock-sha256",
    }
    if set(property_map) != expected_property_names:
        fail("wheelhouse SBOM metadata property set is invalid")
    if any(property_map.get(key) != value for key, value in required_properties.items()):
        fail("wheelhouse SBOM target/build properties are invalid")
    for digest_property in (
        "uten:python:requirements-in-sha256",
        "uten:python:requirements-lock-sha256",
        "uten:python:source-lock-sha256",
        "uten:python:build-lock-sha256",
        "uten:builder:script-sha256",
        "uten:builder:verifier-sha256",
    ):
        if SHA256_RE.fullmatch(property_map.get(digest_property, "")) is None:
            fail(f"wheelhouse SBOM property is not a SHA-256: {digest_property}")
    if not isinstance(property_map.get("uten:builder:image"), str) or "@sha256:" not in property_map["uten:builder:image"]:
        fail("wheelhouse SBOM builder image is not digest-pinned")

    components = sbom.get("components")
    if not isinstance(components, list) or len(components) != len(wheels):
        fail("wheelhouse SBOM component count differs from wheelhouse")
    parsed_components: dict[str, dict[str, Any]] = {}
    for item in components:
        if not isinstance(item, dict) or set(item) != {"bom-ref", "hashes", "name", "properties", "purl", "type", "version"}:
            fail("wheelhouse SBOM component contract is invalid")
        name = normalize_name(item.get("name", ""))
        if name in parsed_components or name not in wheels:
            fail("wheelhouse SBOM contains an extra or duplicate component")
        wheel = wheels[name]
        if (
            item["type"] != "library"
            or item["version"] != wheel.version
            or item["purl"] != _purl(name, wheel.version)
            or item["bom-ref"] != item["purl"]
            or item["hashes"] != [{"alg": "SHA-256", "content": wheel.sha256}]
        ):
            fail(f"wheelhouse SBOM component differs from wheel bytes: {name}")
        component_properties = item["properties"]
        if not isinstance(component_properties, list):
            fail(f"wheelhouse SBOM component properties are invalid: {name}")
        component_map = {
            entry.get("name"): entry.get("value")
            for entry in component_properties
            if isinstance(entry, dict) and set(entry) == {"name", "value"}
        }
        if len(component_map) != len(component_properties) or component_map.get("uten:python:wheel-file") != wheel.filename:
            fail(f"wheelhouse SBOM component does not bind its wheel filename: {name}")
        if component_map.get("uten:python:wheel-target") != f"{TARGET_OS}-{TARGET_ARCH}-{TARGET_IMPLEMENTATION}-{TARGET_PYTHON}":
            fail(f"wheelhouse SBOM component target differs: {name}")
        parsed_components[name] = item
    if set(parsed_components) != set(wheels) or set(lock) != set(wheels):
        fail("lock, wheelhouse, and SBOM package sets differ")

    refs = {name: _purl(name, wheel.version) for name, wheel in wheels.items()}
    expected_dependencies = {
        "urn:uten:updater-wheelhouse": (refs[TOP_LEVEL_REQUIREMENT[0]],),
        **{
            refs[name]: tuple(
                refs[dependency]
                for dependency in _dependency_names(wheels[name], set(wheels))
            )
            for name in wheels
        },
    }
    dependencies = sbom.get("dependencies")
    if not isinstance(dependencies, list) or len(dependencies) != len(wheels) + 1:
        fail("wheelhouse SBOM dependency graph count differs")
    actual_dependencies: dict[str, tuple[str, ...]] = {}
    for entry in dependencies:
        if not isinstance(entry, dict) or set(entry) != {"ref", "dependsOn"} or not isinstance(entry["dependsOn"], list):
            fail("wheelhouse SBOM dependency graph is malformed")
        if entry["ref"] in actual_dependencies or entry["dependsOn"] != sorted(set(entry["dependsOn"])):
            fail("wheelhouse SBOM dependency graph is duplicate or non-canonical")
        actual_dependencies[entry["ref"]] = tuple(entry["dependsOn"])
    if actual_dependencies != expected_dependencies:
        fail("wheelhouse SBOM dependency graph differs from wheel metadata")


def validate_attestation(
    statement: dict[str, Any], sbom: dict[str, Any], wheels: dict[str, WheelInfo], lock_path: Path, sums_path: Path
) -> None:
    if set(statement) != {"_type", "predicate", "predicateType", "subject"}:
        fail("wheelhouse attestation statement shape is invalid")
    if statement["_type"] != IN_TOTO_STATEMENT or statement["predicateType"] != CYCLONEDX_PREDICATE:
        fail("wheelhouse attestation type is invalid")
    if statement["predicate"] != sbom:
        fail("wheelhouse attestation predicate differs from the SBOM")
    expected = {
        "updater-requirements.lock": sha256_file(lock_path),
        "updater-wheelhouse.SHA256SUMS": sha256_file(sums_path),
    }
    expected.update({f"wheelhouse/{wheel.filename}": wheel.sha256 for wheel in wheels.values()})
    subjects = statement["subject"]
    if not isinstance(subjects, list) or len(subjects) != len(expected):
        fail("wheelhouse attestation subject count differs")
    actual: dict[str, str] = {}
    for subject in subjects:
        if not isinstance(subject, dict) or set(subject) != {"digest", "name"}:
            fail("wheelhouse attestation subject is malformed")
        digest = subject["digest"]
        if not isinstance(digest, dict) or set(digest) != {"sha256"} or SHA256_RE.fullmatch(digest["sha256"]) is None:
            fail("wheelhouse attestation subject digest is malformed")
        if subject["name"] in actual:
            fail("wheelhouse attestation contains duplicate subjects")
        actual[subject["name"]] = digest["sha256"]
    if actual != expected:
        fail("wheelhouse attestation subjects differ from supplied artifacts")


def verify_bundle(
    wheelhouse: Path,
    lock_path: Path,
    sums_path: Path,
    sbom_path: Path,
    attestation_path: Path,
) -> tuple[dict[str, LockedRequirement], dict[str, WheelInfo]]:
    lock = parse_requirements_lock(lock_path)
    wheels = load_wheelhouse(wheelhouse)
    if set(lock) != set(wheels):
        fail("requirements lock and wheelhouse package sets differ")
    for name, requirement in lock.items():
        wheel = wheels[name]
        if wheel.version != requirement.version or wheel.sha256 not in requirement.hashes:
            fail(f"wheel identity or digest differs from requirements lock: {name}")
    sums = parse_sha256s(sums_path)
    expected_sums = {wheel.filename: wheel.sha256 for wheel in wheels.values()}
    if sums != expected_sums:
        fail("wheel SHA256SUMS inventory differs from wheelhouse")
    sbom = load_canonical_json(sbom_path, "wheelhouse SBOM")
    validate_sbom(sbom, wheels, lock)
    attestation = load_canonical_json(attestation_path, "wheelhouse attestation")
    validate_attestation(attestation, sbom, wheels, lock_path, sums_path)
    return lock, wheels


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def verify_installed(venv: Path, lock: dict[str, LockedRequirement]) -> None:
    if not venv.is_dir() or venv.is_symlink():
        fail("installed venv must be a real directory")
    for path in (venv, *venv.rglob("*")):
        details = path.lstat()
        if details.st_uid != 0 or details.st_gid != 0:
            fail(f"installed venv path is not root-owned: {path.relative_to(venv)}")
        if stat.S_ISLNK(details.st_mode):
            continue
        if details.st_mode & 0o022:
            fail(f"installed venv path is group/world-writable: {path.relative_to(venv)}")
        if stat.S_ISREG(details.st_mode) and details.st_nlink != 1:
            fail(f"installed venv path is multiply linked: {path.relative_to(venv)}")
        if not (stat.S_ISREG(details.st_mode) or stat.S_ISDIR(details.st_mode)):
            fail(f"installed venv path has an unsafe type: {path.relative_to(venv)}")
    venv_root = venv.resolve()
    site_roots = list(venv.glob("lib/python*/site-packages"))
    if len(site_roots) != 1 or not site_roots[0].is_dir() or site_roots[0].is_symlink():
        fail("installed venv has an unexpected site-packages layout")
    site = site_roots[0]
    expected_site = venv_root / "lib" / site.parent.name / "site-packages"
    if site.resolve() != expected_site:
        fail("installed site-packages path contains an unsafe indirection")
    for path in site.rglob("*"):
        details = path.lstat()
        if stat.S_ISLNK(details.st_mode) or not (stat.S_ISREG(details.st_mode) or stat.S_ISDIR(details.st_mode)):
            fail(f"installed site-packages contains an unsafe file type: {path.relative_to(site)}")
        if stat.S_ISREG(details.st_mode) and details.st_nlink != 1:
            fail(f"installed site-packages contains a multiply linked file: {path.relative_to(site)}")
        if path.is_file() and path.name.lower().endswith(".pth"):
            fail(f"installed site-packages contains executable .pth content: {path.relative_to(site)}")

    installed: dict[str, tuple[str, Path]] = {}
    covered: dict[Path, str] = {}
    for dist_info in sorted(site.glob("*.dist-info")):
        metadata_path = dist_info / "METADATA"
        record_path = dist_info / "RECORD"
        require_regular_file(metadata_path, "installed METADATA", 4 * 1024 * 1024)
        require_regular_file(record_path, "installed RECORD", 16 * 1024 * 1024)
        with metadata_path.open("r", encoding="utf-8") as handle:
            metadata = email.parser.Parser().parse(handle)
        name = normalize_name(metadata.get("Name", ""))
        version = metadata.get("Version", "")
        if name in installed or name not in lock or lock[name].version != version:
            fail(f"installed distribution is extra, duplicate, or has the wrong version: {name}")
        installed[name] = (version, dist_info)
        with record_path.open("r", encoding="utf-8", newline="") as handle:
            rows = list(csv.reader(handle))
        if not rows:
            fail(f"installed RECORD is empty: {name}")
        unhashed = 0
        for row in rows:
            if len(row) != 3 or not row[0]:
                fail(f"installed RECORD row is malformed: {name}")
            relative = PurePosixPath(row[0])
            if (
                relative.is_absolute()
                or relative.as_posix() != row[0]
                or "\\" in row[0]
                or any(part in ("", ".") for part in relative.parts)
            ):
                fail(f"installed RECORD path is unsafe: {name}:{row[0]}")
            cursor = site.resolve()
            left_site = False
            for part in relative.parts:
                if part == "..":
                    if left_site:
                        fail(f"installed RECORD parent traversal is non-canonical: {name}:{row[0]}")
                    cursor = cursor.parent
                    continue
                left_site = True
                cursor /= part
                if cursor.is_symlink():
                    fail(f"installed RECORD path contains a symlink: {name}:{row[0]}")
            target = cursor.resolve(strict=False)
            if not _inside(target, venv_root):
                fail(f"installed RECORD escapes the venv: {name}:{row[0]}")
            if any(part == ".." for part in relative.parts):
                expected_bin = venv_root / "bin"
                if target.parent != expected_bin or not re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9._+-]*", target.name
                ):
                    fail(f"installed RECORD outside site-packages is not a venv script: {name}:{row[0]}")
            if not target.is_file() or target.is_symlink() or target.stat().st_nlink != 1:
                fail(f"installed RECORD target is missing or unsafe: {name}:{row[0]}")
            if target in covered:
                fail(f"installed file is claimed by multiple distributions: {target}")
            covered[target] = name
            if not row[1] and not row[2]:
                if target != record_path.resolve():
                    fail(f"only RECORD itself may omit hash and size: {name}:{row[0]}")
                unhashed += 1
                continue
            if not row[1].startswith("sha256=") or not row[2].isdigit():
                fail(f"installed RECORD lacks a SHA-256 or size: {name}:{row[0]}")
            encoded = row[1][7:]
            try:
                expected_digest = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).hex()
            except (ValueError, binascii.Error) as exc:
                raise WheelhouseError(f"installed RECORD hash is invalid: {name}:{row[0]}") from exc
            if expected_digest != sha256_file(target) or int(row[2]) != target.stat().st_size:
                fail(f"installed file differs from RECORD: {name}:{row[0]}")
        if unhashed != 1:
            fail(f"installed RECORD must contain exactly one unhashed self-row: {name}")
    if set(installed) != set(lock):
        fail("installed dist-info package set differs from the requirements lock")
    actual_site_files = {path.resolve() for path in site.rglob("*") if path.is_file()}
    if actual_site_files != {path for path in covered if _inside(path, site.resolve())}:
        fail("installed site-packages contains an unrecorded or missing file")
    bin_directory = venv_root / "bin"
    if bin_directory.exists():
        if not bin_directory.is_dir() or bin_directory.is_symlink():
            fail("installed venv bin path is unsafe")
        base_venv_files = {"activate", "activate.csh", "activate.fish", "Activate.ps1"}
        for path in bin_directory.iterdir():
            details = path.lstat()
            if stat.S_ISLNK(details.st_mode):
                if re.fullmatch(r"python(?:3(?:\.[0-9]+)?)?", path.name) is None:
                    fail(f"installed venv bin contains an unexpected symlink: {path.name}")
                continue
            if not stat.S_ISREG(details.st_mode) or details.st_nlink != 1:
                fail(f"installed venv bin contains an unsafe file: {path.name}")
            if path.name not in base_venv_files and path.resolve() not in covered:
                fail(f"installed venv bin contains an unrecorded script: {path.name}")


def command_generate(args: argparse.Namespace) -> None:
    validate_requirements_input(args.requirements_input)
    lock = parse_requirements_lock(args.lock)
    wheels = load_wheelhouse(args.wheelhouse)
    if set(lock) != set(wheels):
        fail("cannot generate evidence: lock and wheelhouse package sets differ")
    for name, requirement in lock.items():
        wheel = wheels[name]
        if requirement.version != wheel.version or requirement.hashes != (wheel.sha256,):
            fail(f"cannot generate evidence: lock does not bind exact wheel bytes for {name}")
    _parse_timestamp(args.timestamp)
    if COMMIT_RE.fullmatch(args.commit) is None:
        fail("generation commit must be a full lowercase Git SHA-1")
    if not re.fullmatch(r"[A-Za-z0-9._/+:~-]+@sha256:[0-9a-f]{64}", args.builder_image):
        fail("builder image must be name@sha256:digest")
    source_requirements = parse_requirements_lock(args.source_lock)
    if set(source_requirements) != set(SOURCE_DISTRIBUTIONS):
        fail("source lock must contain exactly the three reviewed PyPI sdists")
    build_requirements = parse_requirements_lock(
        args.build_lock, require_runtime_root=False
    )
    if {
        name: requirement.version for name, requirement in build_requirements.items()
    } != {"setuptools": "80.9.0", "wheel": "0.45.1"}:
        fail("build requirements lock must contain exactly setuptools 80.9.0 and wheel 0.45.1")
    require_regular_file(args.builder_script, "wheelhouse builder script", 1024 * 1024)
    require_regular_file(args.verifier_source, "wheelhouse verifier source", 4 * 1024 * 1024)
    sums_lines = "".join(
        f"{wheel.sha256}  {wheel.filename}\n"
        for wheel in sorted(wheels.values(), key=lambda item: item.filename.encode("ascii"))
    ).encode("ascii")
    write_exclusive(args.sums, sums_lines)
    sbom = build_sbom(
        wheels,
        args.lock,
        args.requirements_input,
        args.source_lock,
        args.build_lock,
        args.builder_script,
        args.verifier_source,
        args.commit,
        args.timestamp,
        args.builder_image,
    )
    write_exclusive(args.sbom, canonical_json_bytes(sbom))
    statement = build_attestation(wheels, args.lock, args.sums, sbom)
    write_exclusive(args.attestation, canonical_json_bytes(statement))
    validate_sbom(sbom, wheels, lock)
    validate_attestation(statement, sbom, wheels, args.lock, args.sums)
    print(f"GENERATED updater wheelhouse evidence for {len(wheels)} locked distributions")


def command_render_binary_lock(args: argparse.Namespace) -> None:
    runtime = parse_requirements_lock(args.lock)
    sources = parse_requirements_lock(args.source_lock)
    if set(sources) != set(SOURCE_DISTRIBUTIONS):
        fail("source lock must contain exactly the three reviewed PyPI sdists")
    for name, source in sources.items():
        runtime_requirement = runtime.get(name)
        if runtime_requirement is None or runtime_requirement.version != source.version:
            fail(f"source and runtime locks disagree for {name}")
    content = "".join(
        f"{item.name}=={item.version} --hash=sha256:{item.hashes[0]}\n"
        for item in sorted(runtime.values(), key=lambda value: value.name)
        if item.name not in sources
    ).encode("ascii")
    write_exclusive(args.output, content)
    print(f"GENERATED binary-only lock for {len(runtime) - len(sources)} distributions")


def command_render_runtime_lock(args: argparse.Namespace) -> None:
    wheels = load_wheelhouse(args.wheelhouse)
    content = (
        RUNTIME_LOCK_HEADER
        + "".join(
            f"{wheel.name}=={wheel.version} --hash=sha256:{wheel.sha256}\n"
            for wheel in sorted(wheels.values(), key=lambda item: item.name)
        )
    ).encode("ascii")
    write_exclusive(args.output, content)
    print(f"GENERATED canonical runtime lock for {len(wheels)} distributions")


def command_download_sources(args: argparse.Namespace) -> None:
    sources = parse_requirements_lock(args.source_lock)
    if set(sources) != set(SOURCE_DISTRIBUTIONS):
        fail("source lock must contain exactly the three reviewed PyPI sdists")
    if args.destination.exists() or args.destination.is_symlink():
        fail("source download destination must not already exist")
    args.destination.mkdir(parents=True, mode=0o700)
    try:
        for name in sorted(SOURCE_DISTRIBUTIONS):
            requirement = sources[name]
            filename = SOURCE_DISTRIBUTIONS[name]
            if f"-{requirement.version}.tar.gz" not in filename:
                fail(f"source filename and lock version disagree for {name}")
            url = (
                "https://files.pythonhosted.org/packages/source/"
                f"{name[0]}/{name}/{filename}"
            )
            request = urllib.request.Request(
                url,
                headers={"User-Agent": "uten-imp-wheelhouse-builder/1"},
                method="GET",
            )
            target = args.destination / filename
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            digest = hashlib.sha256()
            total = 0
            try:
                with urllib.request.urlopen(request, timeout=60) as response, os.fdopen(
                    descriptor, "wb", closefd=False
                ) as output:
                    final_url = urllib.parse.urlparse(response.geturl())
                    if (
                        final_url.scheme != "https"
                        or final_url.hostname != "files.pythonhosted.org"
                    ):
                        fail(f"source distribution download redirected unexpectedly: {name}")
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        total += len(block)
                        if total > MAX_WHEEL_BYTES:
                            fail(f"source distribution exceeds the size limit: {name}")
                        digest.update(block)
                        output.write(block)
                    output.flush()
                    os.fsync(output.fileno())
            finally:
                os.close(descriptor)
            if total < 1 or digest.hexdigest() != requirement.hashes[0]:
                fail(f"source distribution digest differs from source lock: {name}")
            os.chmod(target, 0o600)
    except Exception:
        for child in args.destination.iterdir():
            if child.is_file() and not child.is_symlink():
                child.unlink()
        args.destination.rmdir()
        raise
    print(f"DOWNLOADED {len(sources)} hash-verified source distributions without executing metadata")


def command_verify(args: argparse.Namespace) -> None:
    lock, _ = verify_bundle(args.wheelhouse, args.lock, args.sums, args.sbom, args.attestation)
    if args.venv is not None:
        verify_installed(args.venv, lock)
    print(f"VERIFIED updater wheelhouse supply chain for {len(lock)} locked distributions")


def command_verify_installed(args: argparse.Namespace) -> None:
    """Verify an installed updater venv without importing anything from it."""

    lock = parse_requirements_lock(args.lock)
    verify_installed(args.venv, lock)
    print(f"VERIFIED installed updater venv for {len(lock)} locked distributions")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    generate = commands.add_parser("generate", help="create canonical checksums, SBOM, and attestation")
    generate.add_argument("--requirements-input", required=True, type=Path)
    generate.add_argument("--source-lock", required=True, type=Path)
    generate.add_argument("--build-lock", required=True, type=Path)
    generate.add_argument("--builder-script", required=True, type=Path)
    generate.add_argument("--verifier-source", required=True, type=Path)
    generate.add_argument("--lock", required=True, type=Path)
    generate.add_argument("--wheelhouse", required=True, type=Path)
    generate.add_argument("--sums", required=True, type=Path)
    generate.add_argument("--sbom", required=True, type=Path)
    generate.add_argument("--attestation", required=True, type=Path)
    generate.add_argument("--commit", required=True)
    generate.add_argument("--timestamp", required=True)
    generate.add_argument("--builder-image", required=True)
    generate.set_defaults(handler=command_generate)

    binary_lock = commands.add_parser(
        "render-binary-lock", help="derive the PyPI wheel-only subset from reviewed locks"
    )
    binary_lock.add_argument("--lock", required=True, type=Path)
    binary_lock.add_argument("--source-lock", required=True, type=Path)
    binary_lock.add_argument("--output", required=True, type=Path)
    binary_lock.set_defaults(handler=command_render_binary_lock)

    runtime_lock = commands.add_parser(
        "render-runtime-lock", help="derive the canonical target lock from exact wheel bytes"
    )
    runtime_lock.add_argument("--wheelhouse", required=True, type=Path)
    runtime_lock.add_argument("--output", required=True, type=Path)
    runtime_lock.set_defaults(handler=command_render_runtime_lock)

    download_sources = commands.add_parser(
        "download-sources", help="download the three exact PyPI sdists without executing them"
    )
    download_sources.add_argument("--source-lock", required=True, type=Path)
    download_sources.add_argument("--destination", required=True, type=Path)
    download_sources.set_defaults(handler=command_download_sources)

    verify = commands.add_parser("verify", help="verify the full offline wheelhouse and optionally a venv")
    verify.add_argument("--lock", required=True, type=Path)
    verify.add_argument("--wheelhouse", required=True, type=Path)
    verify.add_argument("--sums", required=True, type=Path)
    verify.add_argument("--sbom", required=True, type=Path)
    verify.add_argument("--attestation", required=True, type=Path)
    verify.add_argument("--venv", type=Path)
    verify.set_defaults(handler=command_verify)

    verify_installed_command = commands.add_parser(
        "verify-installed",
        help="verify the installed updater venv against the reviewed runtime lock",
    )
    verify_installed_command.add_argument("--lock", required=True, type=Path)
    verify_installed_command.add_argument("--venv", required=True, type=Path)
    verify_installed_command.set_defaults(handler=command_verify_installed)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
        return 0
    except (OSError, WheelhouseError) as exc:
        print(f"WHEELHOUSE_REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
