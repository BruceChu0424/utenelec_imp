#!/usr/bin/env python3
"""Create a Windows update or complete first-install ZIP from a release bundle.

The bootstrap distribution must contain client_updater/client_updater.ps1.
Update ZIPs deliberately exclude that trusted installed updater and all files
outside the Flutter runtime. Installer ZIPs include that fixed updater and mark
their manifest with packageKind=installer. No secrets or user settings are shipped.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
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
UPDATER_PATH = "client_updater/client_updater.ps1"
PACKAGE_KINDS = {"update", "installer"}
VC_RUNTIME_CORE = {"msvcp140.dll", "vcruntime140.dll"}
# These are Windows 10+ OS contracts, not libraries found on the build machine.
# In particular, a development machine's System32 VC++ installation never makes
# msvcp/vcruntime/concrt application dependencies available on employee devices.
WINDOWS_OS_MODULES = set("""
advapi32.dll avrt.dll bcrypt.dll bcryptprimitives.dll cfgmgr32.dll clbcatq.dll
combase.dll comctl32.dll comdlg32.dll coremessaging.dll crypt32.dll cryptbase.dll
cryptnet.dll cryptsp.dll d2d1.dll d3d9.dll d3d11.dll d3d12.dll d3dcompiler_47.dll
dcomp.dll devobj.dll dhcpcsvc.dll dnsapi.dll dsound.dll dwmapi.dll dwrite.dll
dxcore.dll dxgi.dll dxva2.dll gdi32.dll gdi32full.dll glu32.dll hid.dll imagehlp.dll
imm32.dll iphlpapi.dll kernel32.dll kernelbase.dll mpr.dll msacm32.dll msasn1.dll
msctf.dll mscoree.dll msimg32.dll msvcrt.dll ncrypt.dll netapi32.dll ntdll.dll ole32.dll
oleacc.dll oleaut32.dll opengl32.dll powrprof.dll propsys.dll psapi.dll rpcrt4.dll
secur32.dll setupapi.dll shcore.dll shell32.dll shlwapi.dll sspicli.dll ucrtbase.dll
user32.dll userenv.dll usp10.dll uxtheme.dll version.dll wer.dll winhttp.dll
uiautomationcore.dll wininet.dll winmm.dll winscard.dll winspool.drv wintrust.dll
wldap32.dll ws2_32.dll wtsapi32.dll mf.dll mfplat.dll mfreadwrite.dll mfuuid.dll
mmdevapi.dll audioclient.dll mswsock.dll normaliz.dll srvcli.dll netutils.dll
windowscodecs.dll dbghelp.dll profapi.dll winrnr.dll davclnt.dll winsta.dll
windows.storage.dll
""".split())
DEBUG_RUNTIME = re.compile(
    r"^(?:(?:msvcp|msvcr|vcruntime|concrt|vcomp|mfc|mfcm)\d+(?:_\d+)?u?d(?:_[^.]+)?|ucrtbased)\.dll$", re.I)


class _PeReader:
    """One bounded PE header/RVA reader shared by version and import checks."""

    def __init__(self, stream, size: int):
        self.stream, self.size = stream, size
        dos = self.read_at(0, 64)
        if dos[:2] != b"MZ":
            raise ValueError("Runtime module must be a Windows PE executable")
        pe = struct.unpack_from("<I", dos, 60)[0]
        header = self.read_at(pe, 24)
        if header[:4] != b"PE\0\0":
            raise ValueError("Executable PE header is invalid")
        machine, sections = struct.unpack_from("<HH", header, 4)
        self.architecture = {0x8664: "x64", 0xAA64: "arm64", 0x14C: "x86"}.get(machine)
        optional_size = struct.unpack_from("<H", header, 20)[0]
        if self.architecture is None or not 1 <= sections <= 96:
            raise ValueError("Executable machine is unsupported")
        optional = self.read_at(pe + 24, optional_size)
        if len(optional) < 64:
            raise ValueError("Executable optional header is truncated")
        self.magic = struct.unpack_from("<H", optional)[0]
        self.directory_offset = {0x10B: 96, 0x20B: 112}.get(self.magic)
        if self.directory_offset is None or len(optional) < self.directory_offset:
            raise ValueError("Executable data-directory header is invalid")
        if (self.architecture == "x86") != (self.magic == 0x10B):
            raise ValueError("Executable machine and optional header disagree")
        self.directory_count = min(struct.unpack_from("<I", optional, self.directory_offset - 4)[0], 16)
        if self.directory_offset + self.directory_count * 8 > len(optional):
            raise ValueError("Executable directories leave the optional header")
        self.optional = optional
        self.header_size = struct.unpack_from("<I", optional, 60)[0]
        self.image_base = struct.unpack_from("<I" if self.magic == 0x10B else "<Q", optional,
                                             28 if self.magic == 0x10B else 24)[0]
        self.sections = []
        table = self.read_at(pe + 24 + optional_size, sections * 40)
        for index in range(sections):
            virtual_size, address, raw_size, raw_address = struct.unpack_from("<IIII", table, index * 40 + 8)
            if raw_size and raw_address + raw_size > size:
                raise ValueError("Executable section leaves the file")
            self.sections.append((address, max(virtual_size, raw_size), raw_size, raw_address))

    def read_at(self, offset: int, length: int) -> bytes:
        if offset < 0 or length < 0 or length > 16 * 1024 * 1024 or offset + length > self.size:
            raise ValueError("Executable contains an invalid PE/resource range")
        self.stream.seek(offset)
        value = self.stream.read(length)
        if len(value) != length:
            raise ValueError("Executable is truncated")
        return value

    def directory(self, number: int) -> tuple[int, int]:
        if number >= self.directory_count:
            return 0, 0
        return struct.unpack_from("<II", self.optional, self.directory_offset + number * 8)

    def file_offset(self, rva: int, length: int) -> int:
        if 0 <= rva and rva + length <= self.header_size:
            self.read_at(rva, length)
            return rva
        for address, span, raw_size, raw_address in self.sections:
            if address <= rva and rva + length <= address + span:
                delta = rva - address
                if delta + length > raw_size:
                    raise ValueError("Executable RVA leaves raw section data")
                self.read_at(raw_address + delta, length)
                return raw_address + delta
        raise ValueError("Executable RVA is unmapped")

    def module_name(self, rva: int) -> str:
        value = bytearray()
        for index in range(256):
            character = self.read_at(self.file_offset(rva + index, 1), 1)
            if character == b"\0":
                break
            value.extend(character)
        else:
            raise ValueError("Executable import name is unterminated or oversized")
        try:
            name = value.decode("ascii").casefold()
        except UnicodeDecodeError as error:
            raise ValueError("Executable import name is not ASCII") from error
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,254}", name):
            raise ValueError("Executable import name is unsafe")
        return name

    def imports(self) -> list[dict]:
        imports = []
        for kind, directory, width, name_index in (("normal", 1, 20, 3), ("delay", 13, 32, 1)):
            rva, size = self.directory(directory)
            if not rva and not size:
                continue
            if not rva or size < width or size > 4096 * width:
                raise ValueError("Executable import-directory range is invalid")
            for index in range(min(size // width, 4096)):
                descriptor = self.read_at(self.file_offset(rva + index * width, width), width)
                values = struct.unpack("<" + "I" * (width // 4), descriptor)
                if not any(values):
                    break
                name_rva = values[name_index]
                if kind == "delay":
                    if values[0] not in (0, 1):
                        raise ValueError("Executable delay-import attributes are unsupported")
                    if not values[0] & 1:
                        name_rva -= self.image_base
                imports.append({"module": self.module_name(name_rva), "kind": kind})
            else:
                raise ValueError("Executable import list has no terminator")
        return imports


def inspect_pe_imports(path: Path) -> dict:
    """Read normal and delay imports without loading a module on the build PC."""
    with path.open("rb") as stream:
        reader = _PeReader(stream, path.stat().st_size)
        return {"architecture": reader.architecture, "peMagic": reader.magic,
                "imports": reader.imports()}


def required_vc_runtime(architecture: str) -> set[str]:
    if architecture not in {"x64", "arm64", "x86"}:
        raise ValueError("Unsupported Windows architecture")
    return VC_RUNTIME_CORE | ({"vcruntime140_1.dll"} if architecture != "x86" else set())


def validate_runtime_dependencies(modules: dict[str, dict], *, architecture: str) -> dict:
    """Require app-local VC++ and module closure; never consult PATH/System32."""
    names = {name.casefold(): name for name in modules}
    if len(names) != len(modules):
        raise ValueError("Case-insensitive duplicate native module path")
    missing_core = required_vc_runtime(architecture) - names.keys()
    if missing_core:
        raise ValueError("Missing required app-local Visual C++ runtime: " + ", ".join(sorted(missing_core)))
    edges = 0
    for relative, info in modules.items():
        if info["architecture"] != architecture:
            raise ValueError(f"Runtime module architecture differs: {relative}")
        if DEBUG_RUNTIME.fullmatch(PurePosixPath(relative).name):
            raise ValueError(f"Debug runtime cannot be distributed: {relative}")
        for imported in info["imports"]:
            module = imported["module"]
            if DEBUG_RUNTIME.fullmatch(module):
                raise ValueError(f"Debug runtime import cannot be distributed: {relative} -> {module}")
            parent = PurePosixPath(relative.casefold()).parent
            local = (parent / module).as_posix()
            if local in names or module in names:
                edges += 1
                continue
            if module.startswith(("api-ms-win-", "ext-ms-win-")) or module in WINDOWS_OS_MODULES:
                continue
            raise ValueError(f"Unresolved non-OS {imported['kind']} import: {relative} -> {module}")
    return {"peModuleCount": len(modules), "normalImportEdges": sum(
                item["kind"] == "normal" for value in modules.values() for item in value["imports"]),
            "delayImportEdges": sum(item["kind"] == "delay" for value in modules.values() for item in value["imports"]),
            "packagedModuleEdges": edges, "requiredVcRuntime": sorted(required_vc_runtime(architecture)),
            "systemBoundary": "Explicit Windows 10+ OS/API-set contracts; build-machine libraries never satisfy dependencies"}


def _unused_jni_proof(bundle: Path, sources: dict[str, Path], modules: dict[str, dict],
                      source_root: Path | None) -> dict | None:
    """Omit only the known transitive JNI artifact when every usage gate agrees."""
    candidate = next((name for name in sources if name.casefold() == "dartjni.dll"), None)
    if candidate is None or any(imported["module"] == "dartjni.dll"
                                 for name, info in modules.items() if name != candidate
                                 for imported in info["imports"]):
        return None
    if source_root is None:
        source_root = next((parent for parent in (bundle, *bundle.parents)
                            if (parent / "pubspec.yaml").is_file() and (parent / "lib").is_dir()), None)
    if source_root is None:
        return None
    source_root = source_root.resolve(strict=True)
    if not (source_root / "pubspec.yaml").is_file() or not (source_root / "lib").is_dir():
        return None
    native_assets = sources.get("data/flutter_assets/NativeAssetsManifest.json")
    if native_assets is None or native_assets.stat().st_size > 1024 * 1024:
        return None
    try:
        native_bytes = native_assets.read_bytes()
        native = json.loads(native_bytes)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(native, dict) or native.get("format-version") != [1, 0, 0] or native.get("native-assets") != {}:
        return None
    dart_files = []
    for current, directories, files in os.walk(source_root / "lib", followlinks=False):
        parent = Path(current)
        if any((parent / name).is_symlink() or (parent / name).is_junction()
               for name in directories):
            return None
        dart_files.extend(parent / name for name in files if name.endswith(".dart"))
    if not dart_files or len(dart_files) > MAX_FILES:
        return None
    source_digest = hashlib.sha256()
    for path in sorted(dart_files):
        if path.is_symlink() or path.is_junction() or path.stat().st_size > 16 * 1024 * 1024:
            return None
        data = path.read_bytes()
        source_digest.update(path.relative_to(source_root).as_posix().encode("utf-8") + b"\0" + hashlib.sha256(data).digest())
        if re.search(r"package:jni(?:_flutter)?(?:/|['\"])|dartjni|\bJni\s*\.", data.decode("utf-8"), re.I):
            return None
    aot = sources["data/app.so"].read_bytes()
    if any(marker.encode(encoding) in aot for marker in ("dartjni", "jvm.dll", "package:jni")
           for encoding in ("utf-8", "utf-16le")):
        return None
    with sources[candidate].open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": candidate, "sha256": digest, "sourceRoot": str(source_root),
            "dartFilesChecked": len(dart_files), "nativeAssetsEmpty": True,
            "noPeReferrers": True, "noAotMarkers": True,
            "aotSha256": hashlib.sha256(aot).hexdigest(),
            "nativeAssetsSha256": hashlib.sha256(native_bytes).hexdigest(),
            "dartSourceInventorySha256": source_digest.hexdigest(),
            "reason": "Unused transitive JNI build artifact; original bundle is not modified"}


def required_files(kind: str) -> set[str]:
    if kind not in PACKAGE_KINDS:
        raise ValueError("Unsupported Windows package kind")
    return REQUIRED_FILES | ({UPDATER_PATH} if kind == "installer" else set())


def _required_paths_present(required: set[str], paths) -> bool:
    actual = set(paths)
    folded = {name.casefold() for name in actual}
    return all(name.casefold() in folded if name.endswith(".dll") else name in actual
               for name in required)


def _version_block(data: bytes, offset: int, limit: int) -> tuple[str, bytes, int, int]:
    if offset < 0 or offset + 6 > limit:
        raise ValueError("Executable version block is truncated")
    length, value_length, kind = struct.unpack_from("<HHH", data, offset)
    end = offset + length
    if length < 8 or end > limit or kind not in {0, 1}:
        raise ValueError("Executable version block range is invalid")
    cursor = offset + 6
    key_start = cursor
    while cursor + 2 <= end and data[cursor:cursor + 2] != b"\0\0":
        cursor += 2
    if cursor + 2 > end:
        raise ValueError("Executable version block key is unterminated")
    key = data[key_start:cursor].decode("utf-16le")
    value_start = (cursor + 5) & ~3
    value_end = value_start + value_length * (2 if kind == 1 else 1)
    if value_end > end:
        raise ValueError("Executable version block value leaves its range")
    return key, data[value_start:value_end], (value_end + 3) & ~3, end


def _version_children(data: bytes, start: int, end: int):
    count = 0
    while start + 6 <= end:
        if not any(data[start:end]):
            break
        count += 1
        if count > 4096:
            raise ValueError("Executable version tree is too large")
        child = _version_block(data, start, end)
        yield child
        start = (child[3] + 3) & ~3


def _version_strings(value: bytes) -> dict[str, str]:
    root_key, _, children, root_end = _version_block(value, 0, len(value))
    if root_key != "VS_VERSION_INFO":
        raise ValueError("Executable version root is invalid")
    result: dict[str, str] = {}
    for key, _, tables, info_end in _version_children(value, children, root_end):
        if key != "StringFileInfo":
            continue
        for _, _, strings, table_end in _version_children(value, tables, info_end):
            table_keys: set[str] = set()
            for key, raw, _, _ in _version_children(value, strings, table_end):
                key = key.casefold()
                if key in table_keys:
                    raise ValueError("Executable has duplicate version string keys")
                table_keys.add(key)
                text = raw.decode("utf-16le").rstrip("\0")
                if key in result and result[key] != text:
                    raise ValueError("Executable has conflicting localized product resources")
                result[key] = text
    return result


def inspect_executable_info(path: Path) -> dict:
    """Read bounded PE/version resources, without executing the executable."""
    size = path.stat().st_size
    with path.open("rb") as stream:
        reader = _PeReader(stream, size)
        read_at, file_offset = reader.read_at, reader.file_offset
        resource_rva, resource_size = reader.directory(2)

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
                    file_version = (fixed[2] >> 16, fixed[2] & 0xFFFF, fixed[3] >> 16, fixed[3] & 0xFFFF)
                    product_version = (fixed[4] >> 16, fixed[4] & 0xFFFF, fixed[5] >> 16, fixed[5] & 0xFFFF)
                    versions.append({"fileVersion": file_version, "productVersion": product_version,
                                     "strings": _version_strings(value)})
        if not versions or any(version != versions[0] for version in versions[1:]):
            raise ValueError("Executable version resources are absent or inconsistent")
        return {"architecture": reader.architecture, "peMagic": reader.magic, **versions[0]}


def inspect_executable(path: Path) -> tuple[str, int]:
    """Compatibility entry for runtime/update package target validation."""
    info = inspect_executable_info(path)
    return info["architecture"], info["fileVersion"][3]


def validate_release_path(relative: str, *, kind: str = "update") -> None:
    required_files(kind)
    if not relative or len(relative) > 230 or "\\" in relative or relative.startswith("/"):
        raise ValueError("Unsafe release file path")
    if re.search(r'[\x00-\x1f<>:"|?*]', relative):
        raise ValueError("Unsafe release file path")
    for segment in relative.split("/"):
        if segment in {"", ".", ".."} or segment.endswith((".", " ")):
            raise ValueError("Unsafe release path segment")
        if re.match(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)", segment, re.I):
            raise ValueError("Reserved Windows path")
    if kind == "installer" and relative == UPDATER_PATH:
        return
    if relative != "uten_imp.exe" and not relative.startswith("data/") and not re.fullmatch(r"[^/]+\.dll", relative, re.I):
        raise ValueError("File is outside the Flutter runtime")


def package_release(bundle: Path, output: Path, *, build_number: int, architecture: str,
                    kind: str = "update", source_root: Path | None = None) -> dict:
    required = required_files(kind)
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
        # Both kinds use the same runtime allowlist. Only a complete first-install
        # archive may include the fixed updater, never arbitrary installer scripts.
        if source.is_symlink() or source.is_junction():
            raise ValueError(f"Links are forbidden: {relative}")
        if not source.is_file():
            continue
        if relative == MANIFEST_NAME or kind == "update" and relative.startswith("client_updater/"):
            continue
        if relative.endswith(".pdb"):
            continue
        validate_release_path(relative, kind=kind)
        if source.stat().st_size > MAX_FILE_BYTES:
            raise ValueError("A runtime file exceeds 512 MiB")
        sources.append((relative, source))
    if not _required_paths_present(required, (relative for relative, _ in sources)):
        raise ValueError("Bundle is missing a required Flutter release file")
    if not any(relative.startswith("data/flutter_assets/") for relative, _ in sources):
        raise ValueError("Bundle is missing Flutter assets")
    if len(sources) > MAX_FILES:
        raise ValueError("Too many runtime files")
    source_paths = dict(sources)
    modules = {relative: inspect_pe_imports(source) for relative, source in sources
               if source.suffix.casefold() in {".exe", ".dll"}}
    aot = source_paths["data/app.so"]
    with aot.open("rb") as stream:
        if stream.read(2) == b"MZ":
            modules["data/app.so"] = inspect_pe_imports(aot)
    proof = _unused_jni_proof(bundle, source_paths, modules, source_root)
    if proof is not None:
        sources = [(relative, source) for relative, source in sources if relative != proof["path"]]
        del modules[proof["path"]]
    runtime_validation = validate_runtime_dependencies(modules, architecture=architecture)
    seen: set[str] = set()
    files = []
    expanded_bytes = 0
    for relative, source in sources:
        key = relative.casefold()
        if key in seen:
            raise ValueError("Case-insensitive duplicate release path")
        seen.add(key)
        size = source.stat().st_size
        if relative == UPDATER_PATH and size == 0:
            raise ValueError("The fixed first-install updater cannot be empty")
        if size > MAX_FILE_BYTES:
            raise ValueError("A runtime file exceeds 512 MiB")
        expanded_bytes += size
        if expanded_bytes > MAX_EXPANDED_BYTES:
            raise ValueError("Expanded release exceeds 2 GiB")
        with source.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if proof is not None:
            frozen = {"data/app.so": proof["aotSha256"],
                      "data/flutter_assets/NativeAssetsManifest.json": proof["nativeAssetsSha256"]}
            if relative in frozen and digest != frozen[relative]:
                raise ValueError("JNI omission proof invalidated by changed native assets/AOT")
        files.append({"path": relative, "size": size, "sha256": digest})
    manifest = {"schemaVersion": 1, "platform": "windows", "architecture": architecture,
                "buildNumber": build_number, "executable": "uten_imp.exe", "files": files}
    if kind == "installer":
        manifest["packageKind"] = "installer"
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
        validate_package(temporary, build_number=build_number, architecture=architecture, kind=kind)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    with output.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"package": str(output), "sha256": digest, "sizeBytes": output.stat().st_size,
            "buildNumber": build_number, "architecture": architecture,
            "mode": "windows_archive" if kind == "update" else "windows_bundle",
            "runtimeValidation": runtime_validation,
            "omittedUnusedNativeArtifacts": [proof] if proof is not None else []}


def validate_package(path: Path, *, build_number: int, architecture: str,
                     kind: str = "update") -> dict:
    """Independently re-read the finished ZIP before making it publishable."""
    required = required_files(kind)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_FILES + 1:
            raise ValueError("Too many archive entries")
        manifests = [entry for entry in entries if entry.filename == MANIFEST_NAME]
        if len(manifests) != 1 or manifests[0].file_size > 8 * 1024 * 1024:
            raise ValueError("Missing or oversized manifest")
        manifest = json.loads(archive.read(manifests[0]))
        if manifest.get("packageKind", "update") != kind:
            raise ValueError("Manifest package kind does not match")
        if (manifest.get("schemaVersion"), manifest.get("platform"), manifest.get("architecture"),
            manifest.get("buildNumber"), manifest.get("executable")) != (1, "windows", architecture, build_number, "uten_imp.exe"):
            raise ValueError("Manifest target does not match")
        records = manifest["files"]
        expected = {record["path"]: record for record in records}
        if len(expected) != len(records) or not _required_paths_present(required, expected):
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
            validate_release_path(entry.filename, kind=kind)
            record = expected.get(entry.filename)
            if record is None or entry.file_size != record["size"] or entry.file_size > MAX_FILE_BYTES:
                raise ValueError("Archive does not match manifest")
            if entry.filename == UPDATER_PATH and entry.file_size == 0:
                raise ValueError("The fixed first-install updater cannot be empty")
            total += entry.file_size
            if total > MAX_EXPANDED_BYTES:
                raise ValueError("Expanded archive too large")
            with archive.open(entry) as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != record["sha256"]:
                    raise ValueError("Runtime SHA-256 mismatch")
        if len(seen) != len(expected) + 1:
            raise ValueError("Archive omits release files")
        modules = {}
        for entry in entries:
            is_native = PurePosixPath(entry.filename).suffix.casefold() in {".exe", ".dll"}
            if not is_native and entry.filename != "data/app.so":
                continue
            # ZIP seeks would repeatedly decompress a large DLL. Bound memory
            # and re-read each complete entry once into a private seekable spool.
            with tempfile.SpooledTemporaryFile(max_size=16 * 1024 * 1024) as native:
                with archive.open(entry) as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        native.write(chunk)
                native.seek(0)
                if not is_native and native.read(2) != b"MZ":
                    continue
                reader = _PeReader(native, entry.file_size)
                modules[entry.filename] = {"architecture": reader.architecture, "peMagic": reader.magic,
                                           "imports": reader.imports()}
        validate_runtime_dependencies(modules, architecture=architecture)
        return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--architecture", choices=("x64", "arm64", "x86"), default="x64")
    parser.add_argument("--kind", choices=("update", "installer"), default="update",
                        help="installer includes the fixed updater for a complete first installation")
    parser.add_argument("--source-root", type=Path,
                        help="reviewed source tree for proving an unused transitive JNI artifact; otherwise inferred from bundle ancestors")
    args = parser.parse_args()
    print(json.dumps(package_release(args.bundle, args.output, build_number=args.build_number,
                                     architecture=args.architecture, kind=args.kind,
                                     source_root=args.source_root), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
