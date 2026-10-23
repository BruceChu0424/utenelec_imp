#!/usr/bin/env python3
"""Create an in-app Windows update ZIP from a Flutter release bundle.

The bootstrap distribution must contain client_updater/client_updater.ps1.
Update ZIPs deliberately exclude that trusted installed updater and all files
outside the Flutter runtime. No signing secrets or user settings are included.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import tempfile
import zipfile

MANIFEST_NAME = "uten-client-manifest.json"
MAX_FILES = 20_000
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_EXPANDED_BYTES = 2 * 1024 * 1024 * 1024
REQUIRED_FILES = {"uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat"}


def inspect_executable(path: Path) -> tuple[str, int]:
    """Read actual PE machine and RT_VERSION, without trusting release metadata."""
    size = path.stat().st_size
    with path.open("rb") as stream:
        def read_at(offset: int, length: int) -> bytes:
            if offset < 0 or length < 0 or length > 16 * 1024 * 1024 or offset + length > size:
                raise ValueError("Executable contains an invalid PE/resource range")
            stream.seek(offset)
            result = stream.read(length)
            if len(result) != length:
                raise ValueError("Executable is truncated")
            return result

        dos = read_at(0, 64)
        if dos[:2] != b"MZ":
            raise ValueError("uten_imp.exe must be a Windows PE executable")
        pe_offset = struct.unpack_from("<I", dos, 60)[0]
        header = read_at(pe_offset, 24)
        if header[:4] != b"PE\0\0":
            raise ValueError("Executable PE header is invalid")
        machine, sections = struct.unpack_from("<HH", header, 4)
        architecture = {0x8664: "x64", 0xAA64: "arm64", 0x14C: "x86"}.get(machine)
        optional_size = struct.unpack_from("<H", header, 20)[0]
        if architecture is None or not 1 <= sections <= 96:
            raise ValueError("Executable machine is unsupported")
        optional = read_at(pe_offset + 24, optional_size)
        magic = struct.unpack_from("<H", optional)[0]
        directories = {0x10B: 96, 0x20B: 112}.get(magic)
        if directories is None or len(optional) < directories + 24:
            raise ValueError("Executable resource header is invalid")
        resource_rva, resource_size = struct.unpack_from("<II", optional, directories + 16)
        section_table = read_at(pe_offset + 24 + optional_size, sections * 40)

        def file_offset(rva: int, length: int) -> int:
            for index in range(sections):
                virtual_size, virtual_address, raw_size, raw_address = struct.unpack_from("<IIII", section_table, index * 40 + 8)
                if virtual_address <= rva and rva + length <= virtual_address + min(virtual_size, raw_size):
                    return raw_address + rva - virtual_address
            raise ValueError("Executable resource RVA is invalid")

        if resource_size <= 0 or resource_size > 16 * 1024 * 1024:
            raise ValueError("Executable version resources are missing or too large")
        resources = read_at(file_offset(resource_rva, resource_size), resource_size)

        def resource_entries(offset: int) -> list[tuple[int, int]]:
            if offset < 0 or offset + 16 > len(resources):
                raise ValueError("Executable resource directory is invalid")
            named, numbered = struct.unpack_from("<HH", resources, offset + 12)
            count = named + numbered
            if count > 4096 or offset + 16 + count * 8 > len(resources):
                raise ValueError("Executable resource directory entries are invalid")
            return [struct.unpack_from("<II", resources, offset + 16 + index * 8) for index in range(count)]

        versions = []
        for kind, directory in resource_entries(0):
            if kind != 16 or not directory & 0x80000000:
                continue
            for _, language_directory in resource_entries(directory & 0x7FFFFFFF):
                if not language_directory & 0x80000000:
                    raise ValueError("Executable version resource name is invalid")
                for _, data_offset in resource_entries(language_directory & 0x7FFFFFFF):
                    if data_offset & 0x80000000 or data_offset + 16 > len(resources):
                        raise ValueError("Executable version resource data is invalid")
                    data_rva, data_size = struct.unpack_from("<II", resources, data_offset)
                    value = read_at(file_offset(data_rva, data_size), data_size)
                    key = "VS_VERSION_INFO\0".encode("utf-16le")
                    fixed_offset = (6 + len(key) + 3) & ~3
                    if len(value) < fixed_offset + 52 or value[6:6 + len(key)] != key:
                        raise ValueError("Executable VS_VERSION_INFO is invalid")
                    fixed = struct.unpack_from("<13I", value, fixed_offset)
                    if fixed[:2] != (0xFEEF04BD, 0x00010000):
                        raise ValueError("Executable VS_FIXEDFILEINFO is invalid")
                    versions.append(fixed[3] & 0xFFFF)
        if not versions or len(set(versions)) != 1:
            raise ValueError("Executable version resources are absent or inconsistent")
        return architecture, versions[0]


def validate_release_path(relative: str) -> None:
    if not relative or len(relative) > 230 or "\\" in relative or relative.startswith("/"):
        raise ValueError("Unsafe release file path")
    if re.search(r'[\x00-\x1f<>:"|?*]', relative):
        raise ValueError("Unsafe release file path")
    for segment in relative.split("/"):
        if segment in {"", ".", ".."} or segment.endswith((".", " ")):
            raise ValueError("Unsafe release path segment")
        if re.match(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)", segment, re.I):
            raise ValueError("Reserved Windows path")
    if relative != "uten_imp.exe" and not relative.startswith("data/") and not re.fullmatch(r"[^/]+\.dll", relative):
        raise ValueError("File is outside the Flutter runtime")


def package_release(bundle: Path, output: Path, *, build_number: int, architecture: str) -> dict:
    bundle = bundle.resolve(strict=True)
    output = output.resolve()
    if build_number <= 0 or build_number > 65535:
        raise ValueError("Windows build number must be in 1..65535 (PE version limit)")
    if architecture not in {"x64", "arm64", "x86"}:
        raise ValueError("Unsupported Windows architecture")
    actual_architecture, actual_build = inspect_executable(bundle / "uten_imp.exe")
    if (actual_architecture, actual_build) != (architecture, build_number):
        raise ValueError("Actual executable architecture/build differs from release metadata")
    if output == bundle or bundle in output.parents:
        raise ValueError("Output ZIP must be outside the input bundle")
    sources: list[tuple[str, Path]] = []
    for source in sorted(bundle.rglob("*")):
        relative = source.relative_to(bundle).as_posix()
        # Never ship credentials, debug symbols, the executing updater or any
        # unknown root file as an application update.
        if source.is_symlink() or source.is_junction():
            raise ValueError(f"Links are forbidden: {relative}")
        if not source.is_file():
            continue
        if relative == MANIFEST_NAME or relative.startswith("client_updater/"):
            continue
        if relative.endswith(".pdb"):
            continue
        validate_release_path(relative)
        sources.append((relative, source))
    if not REQUIRED_FILES.issubset({relative for relative, _ in sources}):
        raise ValueError("Bundle is missing a required Flutter release file")
    if not any(relative.startswith("data/flutter_assets/") for relative, _ in sources):
        raise ValueError("Bundle is missing Flutter assets")
    if len(sources) > MAX_FILES:
        raise ValueError("Too many runtime files")
    seen: set[str] = set()
    files = []
    expanded_bytes = 0
    for relative, source in sources:
        key = relative.casefold()
        if key in seen:
            raise ValueError("Case-insensitive duplicate release path")
        seen.add(key)
        size = source.stat().st_size
        if size > MAX_FILE_BYTES:
            raise ValueError("A runtime file exceeds 512 MiB")
        expanded_bytes += size
        if expanded_bytes > MAX_EXPANDED_BYTES:
            raise ValueError("Expanded release exceeds 2 GiB")
        with source.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        files.append({"path": relative, "size": size, "sha256": digest})
    manifest = {"schemaVersion": 1, "platform": "windows", "architecture": architecture,
                "buildNumber": build_number, "executable": "uten_imp.exe", "files": files}
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive temporary output and atomic replace leave an existing package
    # intact if reading/compression fails.
    descriptor, temporary_name = tempfile.mkstemp(prefix=".uten-client-", suffix=".zip", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for relative, source in sources:
                archive.write(source, relative)
            archive.writestr(MANIFEST_NAME, json.dumps(manifest, ensure_ascii=False, separators=(",", ":")))
        validate_package(temporary, build_number=build_number, architecture=architecture)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    with output.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"package": str(output), "sha256": digest, "sizeBytes": output.stat().st_size,
            "buildNumber": build_number, "architecture": architecture, "mode": "windows_archive"}


def validate_package(path: Path, *, build_number: int, architecture: str) -> dict:
    """Independently re-read the finished ZIP before making it publishable."""
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_FILES + 1:
            raise ValueError("Too many archive entries")
        manifests = [entry for entry in entries if entry.filename == MANIFEST_NAME]
        if len(manifests) != 1 or manifests[0].file_size > 8 * 1024 * 1024:
            raise ValueError("Missing or oversized manifest")
        manifest = json.loads(archive.read(manifests[0]))
        if (manifest.get("schemaVersion"), manifest.get("platform"), manifest.get("architecture"),
            manifest.get("buildNumber"), manifest.get("executable")) != (1, "windows", architecture, build_number, "uten_imp.exe"):
            raise ValueError("Manifest target does not match")
        records = manifest["files"]
        expected = {record["path"]: record for record in records}
        if len(expected) != len(records) or not REQUIRED_FILES.issubset(expected):
            raise ValueError("Missing or duplicate runtime records")
        seen: set[str] = set()
        total = 0
        for entry in entries:
            key = entry.filename.casefold()
            if key in seen or stat.S_ISLNK(entry.external_attr >> 16) or entry.external_attr & 1024:
                raise ValueError("Duplicate or linked archive entry")
            seen.add(key)
            if entry.filename == MANIFEST_NAME:
                continue
            validate_release_path(entry.filename)
            record = expected.get(entry.filename)
            if record is None or entry.file_size != record["size"] or entry.file_size > MAX_FILE_BYTES:
                raise ValueError("Archive does not match manifest")
            total += entry.file_size
            if total > MAX_EXPANDED_BYTES:
                raise ValueError("Expanded archive too large")
            with archive.open(entry) as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != record["sha256"]:
                    raise ValueError("Runtime SHA-256 mismatch")
        if len(seen) != len(expected) + 1:
            raise ValueError("Archive omits release files")
        return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--architecture", choices=("x64", "arm64", "x86"), default="x64")
    args = parser.parse_args()
    print(json.dumps(package_release(args.bundle, args.output, build_number=args.build_number,
                                     architecture=args.architecture), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
