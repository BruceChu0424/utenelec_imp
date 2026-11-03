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
import shutil
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
RUNTIME_PROFILE_PATH = "data/uten-runtime-profile.json"
MAX_PROFILE_BYTES = 16384
RUNTIME_PROFILES = {
    "formal": {"schemaVersion": 1, "buildProfile": "formal", "applicationId": "com.uten.uten_imp",
               "nativeProductName": "优腾综合管理平台", "displayName": "UTEN", "runtimeFamily": "flutter",
               "networkScope": "trusted-configured", "selfUpdatesAllowed": True},
    "local_test": {"schemaVersion": 1, "buildProfile": "local_test", "applicationId": "com.uten.uten_imp.local_test",
                   "nativeProductName": "UTEN Local Test", "displayName": "UTEN 本地测试", "runtimeFamily": "flutter",
                   "networkScope": "loopback-only", "selfUpdatesAllowed": False},
}
VC_RUNTIME_CORE = {"msvcp140.dll", "vcruntime140.dll"}
ENGINE_SAFETY_CONTRACT = Path(__file__).resolve().parents[2] / "contracts/windows-engine-safety/v1.json"
_ENGINE_POLICY = json.loads(ENGINE_SAFETY_CONTRACT.read_text(encoding="utf-8"))
# The cross-language contract owns the source-built admission/denial facts.
KNOWN_CRASHING_ENGINE_DIGESTS = {entry["rawSha256"]: entry["reason"] for entry in _ENGINE_POLICY["engines"]
                                if entry["classification"] == "confirmed-crashing"}
KNOWN_UNREPAIRED_ENGINE_DIGESTS = {entry["rawSha256"]: entry["reason"] for entry in _ENGINE_POLICY["engines"]
                                 if entry["classification"] == "source-confirmed-unrepaired"}
APPROVED_ENGINE_IMAGES = {entry["peImageSha256"]: entry for entry in _ENGINE_POLICY["reviewedEngines"]}
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


def reject_known_unsafe_engine(relative: str, digest: str, *, stream=None, size: int | None = None,
                               require_approved: bool = False) -> None:
    if relative.casefold() == "flutter_windows.dll":
        reason = KNOWN_CRASHING_ENGINE_DIGESTS.get(digest.lower())
        if reason is not None:
            raise ValueError(f"Known crashing Flutter Windows engine cannot be packaged: {reason}; "
                             "use the reviewed runtime and complete native window/UIA regression")
        reason = KNOWN_UNREPAIRED_ENGINE_DIGESTS.get(digest.lower())
        if reason is not None:
            raise ValueError(f"Known unrepaired Flutter Windows engine cannot be packaged: {reason}; "
                             "rebuild with a repaired, matching runtime and complete native acceptance")
        if stream is not None:
            image_digest = pe_image_sha256(stream, size)
            for identity in _ENGINE_POLICY["engines"]:
                if image_digest == identity["peImageSha256"]:
                    classification = "crashing" if identity["classification"] == "confirmed-crashing" else "unrepaired"
                    raise ValueError(f"Known {classification} Flutter Windows engine cannot be packaged: "
                                     f"{identity['reason']}; signature-independent PE identity matched")
            if require_approved and image_digest not in APPROVED_ENGINE_IMAGES:
                raise ValueError("Unreviewed Flutter Windows engine cannot enter formal distribution; "
                                 "review the matching source-built Release runtime and native acceptance")
        elif require_approved:
            raise ValueError("Formal engine approval requires the actual bounded PE content")


def pe_image_sha256(stream, size: int | None = None) -> str:
    """Shared bounded parser for the signature-independent engine deny policy."""
    if size is None:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
    return _PeReader(stream, size).image_sha256()


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
        self.optional_offset = pe + 24
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
        self.section_table_end = pe + 24 + optional_size + sections * 40
        table = self.read_at(pe + 24 + optional_size, sections * 40)
        for index in range(sections):
            virtual_size, address, raw_size, raw_address = struct.unpack_from("<IIII", table, index * 40 + 8)
            if raw_size and raw_address + raw_size > size:
                raise ValueError("Executable section leaves the file")
            self.sections.append((address, max(virtual_size, raw_size), raw_size, raw_address))

    def image_sha256(self) -> str:
        """PE image identity, invariant under Authenticode signing/checksum changes.

        Hash headers except CheckSum/Certificate Table directory, followed by
        complete raw sections in file order. Certificate/overlay bytes outside
        sections are excluded. This is a deny-list identity, never a trust or
        signature validation result. See contracts/windows-engine-safety/v1.json.
        """
        checksum = self.optional_offset + 64
        security = self.optional_offset + self.directory_offset + 4 * 8
        if (self.directory_count < 5 or self.header_size < max(security + 8, self.section_table_end)
                or self.header_size > self.size):
            raise ValueError("Engine PE identity requires complete bounded headers")
        certificate, certificate_size = self.directory(4)
        if bool(certificate) != bool(certificate_size):
            raise ValueError("Engine PE certificate table is incomplete")
        if certificate and (certificate % 8 or certificate_size < 8 or
                            certificate < self.header_size or certificate + certificate_size > self.size):
            raise ValueError("Engine PE certificate table leaves the file")
        digest = hashlib.sha256()
        def feed(offset: int, length: int) -> None:
            self.stream.seek(offset)
            while length:
                block = self.stream.read(min(length, 1024 * 1024))
                if not block:
                    raise ValueError("Engine PE identity stream is truncated")
                digest.update(block)
                length -= len(block)
        feed(0, checksum)
        feed(checksum + 4, security - checksum - 4)
        feed(security + 8, self.header_size - security - 8)
        end = self.header_size
        for _, _, raw_size, raw_address in sorted(self.sections, key=lambda section: section[3]):
            if not raw_size:
                continue
            if raw_address < end or (certificate and raw_address + raw_size > certificate):
                raise ValueError("Engine PE sections overlap headers, certificates or each other")
            feed(raw_address, raw_size)
            end = raw_address + raw_size
        return digest.hexdigest()

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
                                     "debugBuild": bool(fixed[6] & fixed[7] & 1),
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


def release_version_number(version: str) -> tuple[int, int, int]:
    """Numeric prefix of a display version, matching the server's paired-contract parser."""
    parts = version.split("-", 2)[0].split(".", -1)
    if len(parts) != 3 or not all(re.fullmatch(r"0|[1-9][0-9]*", part) for part in parts):
        raise ValueError("Release version must be three numeric version components")
    numbers = tuple(int(part) for part in parts)
    if any(number > 65535 for number in numbers):
        raise ValueError("Release version components must fit Windows version resource fields")
    return numbers


def _unique_json(data: bytes) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON field in the package contract")
            result[key] = value
        return result
    value = json.loads(data, object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("Package JSON contract must be an object")
    return value


def validate_runtime_profile(data: bytes | None, executable: dict, *, allow_local_test: bool = False) -> dict | None:
    """Validate actual generated metadata and actual PE identity at one shared entry."""
    strings = {key.casefold(): value for key, value in executable.get("strings", {}).items()}
    marker = strings.get("utenbuildprofile")
    if data is None:
        if marker is not None or executable["productVersion"][:3] >= (2, 5, 44) or allow_local_test:
            raise ValueError("Actual profiled program requires its generated runtime metadata")
        if strings.get("productname") == "UTEN Local Test":
            raise ValueError("LocalTest runtime cannot be packaged as formal")
        return None
    if not data or len(data) > MAX_PROFILE_BYTES:
        raise ValueError("Runtime profile metadata exceeds its bounded contract")
    profile = _unique_json(data)
    name = profile.get("buildProfile")
    if not isinstance(name, str):
        raise ValueError("Runtime buildProfile must be textual")
    expected = RUNTIME_PROFILES.get(name)
    if expected is None or set(profile) != set(expected) or any(
            type(profile[key]) is not type(value) or profile[key] != value for key, value in expected.items()):
        raise ValueError("Runtime profile must exactly match the generated schema1 eight-field identity")
    if profile["buildProfile"] == "local_test" and not allow_local_test:
        raise ValueError("LocalTest runtime cannot enter the formal distribution")
    if (marker != profile["buildProfile"] or strings.get("productname") != profile["nativeProductName"]
            or strings.get("companyname") != "Uten" or strings.get("internalname") != "uten_imp"
            or strings.get("originalfilename") != "uten_imp.exe"):
        raise ValueError("Actual PE identity differs from the generated runtime profile")
    if profile["buildProfile"] == "formal" and executable.get("debugBuild"):
        raise ValueError("Debug runtime cannot enter the formal distribution")
    return profile


def _installer_binding(kind: str, profile: dict | None, value: str | None, *, allow_local_test: bool) -> None:
    if kind == "installer" and value is not None:
        raise ValueError("Bootstrap installer manifest cannot contain its own Setup hash")
    if value is not None and (not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None):
        raise ValueError("installer_sha256 must be the actual lower-case SHA-256 of Setup.exe")
    if kind == "update" and profile is not None and profile["buildProfile"] == "formal" and value is None:
        raise ValueError("New formal update runtime requires its actual installer_sha256 binding")


def collect_runtime_sources(bundle: Path, *, architecture: str, kind: str,
                            source_root: Path | None = None) -> tuple[list[tuple[str, Path]], dict | None, dict]:
    """One allowlist/dependency/JNI-selection entry for signing and packaging."""
    required = required_files(kind)
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
        # Flutter can drop a root native_assets.json next to the executable as
        # build metadata; the engine reads data/flutter_assets/NativeAssetsManifest.json
        # at runtime, and previously shipped bundles never carried the root file.
        if relative == "native_assets.json":
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
    return sources, proof, runtime_validation


def package_release(bundle: Path, output: Path, *, build_number: int, architecture: str,
                    kind: str = "update", version: str | None = None,
                    source_root: Path | None = None, installer_sha256: str | None = None,
                    allow_local_test: bool = False) -> dict:
    required_files(kind)
    bundle = bundle.resolve(strict=True)
    output = output.resolve()
    if build_number <= 0 or build_number > 65535:
        raise ValueError("Windows build number must be in 1..65535 (PE version limit)")
    if architecture not in {"x64", "arm64", "x86"}:
        raise ValueError("Unsupported Windows architecture")
    executable_info = inspect_executable_info(bundle / "uten_imp.exe")
    profile_path = bundle / RUNTIME_PROFILE_PATH
    if profile_path.is_symlink() or profile_path.parent.is_symlink() or profile_path.parent.is_junction():
        raise ValueError("Runtime profile cannot be read through a link")
    if profile_path.is_file() and profile_path.stat().st_size > MAX_PROFILE_BYTES:
        raise ValueError("Runtime profile metadata exceeds its bounded contract")
    runtime_profile = validate_runtime_profile(profile_path.read_bytes() if profile_path.is_file() else None,
                                               executable_info, allow_local_test=allow_local_test)
    _installer_binding(kind, runtime_profile, installer_sha256, allow_local_test=allow_local_test)
    if (executable_info["architecture"], executable_info["fileVersion"][3]) != (architecture, build_number):
        raise ValueError("Actual executable architecture/build differs from release metadata")
    executable_version = executable_info["productVersion"][:3]
    if executable_info["fileVersion"][:3] != executable_version:
        raise ValueError("Executable file and product versions disagree")
    if version is None:
        version = ".".join(str(number) for number in executable_version)
    elif release_version_number(version) != executable_version:
        raise ValueError("Requested version differs from the executable version resources")
    if output == bundle or bundle in output.parents:
        raise ValueError("Output ZIP must be outside the runtime bundle")
    sources, proof, runtime_validation = collect_runtime_sources(bundle, architecture=architecture, kind=kind, source_root=source_root)
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
            reject_known_unsafe_engine(relative, digest, stream=stream, size=size,
                                       require_approved=(runtime_profile or {}).get("buildProfile") != "local_test")
        if proof is not None:
            frozen = {"data/app.so": proof["aotSha256"],
                      "data/flutter_assets/NativeAssetsManifest.json": proof["nativeAssetsSha256"]}
            if relative in frozen and digest != frozen[relative]:
                raise ValueError("JNI omission proof invalidated by changed native assets/AOT")
        files.append({"path": relative, "size": size, "sha256": digest})
    # Hash manifests are transport integrity, not a Windows publisher identity.
    # Verify the exact source leaves before producing any formal archive.
    if (runtime_profile or {}).get("buildProfile") != "local_test":
        import windows_authenticode
        import time
        deadline = time.monotonic() + windows_authenticode.VERIFY_SECONDS
        windows_authenticode.verify_files([(relative, source) for relative, source in sources
                                           if windows_authenticode.is_signable(source)], deadline=deadline)
        import windows_payload_binding
        windows_payload_binding.verify_sources(sources, metadata={"runtimeFamily": "flutter", "version": version,
            "buildNumber": build_number, "architecture": architecture, "executable": "uten_imp.exe"}, deadline=deadline)
    manifest = {"schemaVersion": 1, "platform": "windows", "architecture": architecture,
                "version": version, "buildNumber": build_number, "executable": "uten_imp.exe",
                "packageKind": kind, "files": files}
    if installer_sha256 is not None:
        manifest["installerSha256"] = installer_sha256
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
        validate_package(temporary, build_number=build_number, architecture=architecture, kind=kind,
                         version=version, allow_local_test=allow_local_test)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    with output.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"package": str(output), "sha256": digest, "sizeBytes": output.stat().st_size,
            "version": version,
            "buildNumber": build_number, "architecture": architecture,
            "mode": "windows_archive" if kind == "update" else "windows_bundle",
            "runtimeValidation": runtime_validation,
            "runtimeProfile": runtime_profile,
            "omittedUnusedNativeArtifacts": [proof] if proof is not None else []}


def validate_package(path: Path, *, build_number: int, architecture: str,
                     kind: str = "update", version: str | None = None, allow_local_test: bool = False) -> dict:
    """Independently re-read the finished ZIP before making it publishable."""
    required = required_files(kind)
    from zip_directory import require_bounded_directory
    require_bounded_directory(path, max_entries=MAX_FILES + 1, max_central_bytes=16 * 1024 * 1024)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_FILES + 1:
            raise ValueError("Too many archive entries")
        manifests = [entry for entry in entries if entry.filename == MANIFEST_NAME]
        if len(manifests) != 1 or manifests[0].file_size > 8 * 1024 * 1024:
            raise ValueError("Missing or oversized manifest")
        manifest = _unique_json(archive.read(manifests[0]))
        if manifest.get("packageKind", "update") != kind:
            raise ValueError("Manifest package kind does not match")
        if (manifest.get("schemaVersion"), manifest.get("platform"), manifest.get("architecture"),
                manifest.get("buildNumber"), manifest.get("executable")) != (1, "windows", architecture, build_number, "uten_imp.exe"):
            raise ValueError("Manifest target does not match")
        recorded_version = manifest.get("version")
        if not isinstance(recorded_version, str):
            raise ValueError("Manifest version is missing")
        release_version_number(recorded_version)
        if version is not None and recorded_version != version:
            raise ValueError("Manifest version does not match")
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
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
                if digest != record["sha256"]:
                    raise ValueError("Runtime SHA-256 mismatch")
                reject_known_unsafe_engine(entry.filename, digest, stream=stream, size=entry.file_size)
        if len(seen) != len(expected) + 1:
            raise ValueError("Archive omits release files")
        modules = {}
        executable_info = None
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
                if entry.filename == "uten_imp.exe":
                    native.seek(0)
                    with tempfile.TemporaryDirectory(prefix="uten-runtime-pe-") as temporary:
                        image = Path(temporary) / "uten_imp.exe"
                        with image.open("xb") as target:
                            shutil.copyfileobj(native, target, 65536)
                        executable_info = inspect_executable_info(image)
        validate_runtime_dependencies(modules, architecture=architecture)
        if executable_info is None:
            raise ValueError("Actual runtime executable is missing")
        expected_version = (*release_version_number(recorded_version), build_number)
        if (executable_info["architecture"] != architecture or executable_info["fileVersion"] != expected_version
                or executable_info["productVersion"] != expected_version):
            raise ValueError("Actual archived executable version/architecture differs from its manifest")
        profile_entry = next((entry for entry in entries if entry.filename == RUNTIME_PROFILE_PATH), None)
        if profile_entry is not None and profile_entry.file_size > MAX_PROFILE_BYTES:
            raise ValueError("Runtime profile metadata exceeds its bounded contract")
        profile = validate_runtime_profile(archive.read(profile_entry) if profile_entry is not None else None,
                                           executable_info, allow_local_test=allow_local_test)
        engine = next(entry for entry in entries if entry.filename.casefold() == "flutter_windows.dll")
        with archive.open(engine) as stream:
            reject_known_unsafe_engine(engine.filename, expected[engine.filename]["sha256"],
                                       stream=stream, size=engine.file_size,
                                       require_approved=(profile or {}).get("buildProfile") != "local_test")
        _installer_binding(kind, profile, manifest.get("installerSha256"), allow_local_test=allow_local_test)
        if (profile or {}).get("buildProfile") != "local_test":
            import windows_authenticode
            import time
            deadline = time.monotonic() + windows_authenticode.VERIFY_SECONDS
            windows_authenticode.verify_archive(archive, deadline=deadline)
            import windows_payload_binding
            windows_payload_binding.verify_archive(archive, metadata={"runtimeFamily": "flutter", "version": recorded_version,
                "buildNumber": build_number, "architecture": architecture, "executable": "uten_imp.exe"}, deadline=deadline)
        return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--version",
                        help="display version to stamp into the manifest; defaults to the executable's own version resources")
    parser.add_argument("--architecture", choices=("x64", "arm64", "x86"), default="x64")
    parser.add_argument("--kind", choices=("update", "installer"), default="update",
                        help="installer includes the fixed updater for a complete first installation")
    parser.add_argument("--source-root", type=Path,
                        help="reviewed source tree for proving an unused transitive JNI artifact; otherwise inferred from bundle ancestors")
    parser.add_argument("--installer-sha256", help="actual completed Setup.exe SHA-256, required for new formal update payloads")
    args = parser.parse_args()
    print(json.dumps(package_release(args.bundle, args.output, build_number=args.build_number,
                                     architecture=args.architecture, kind=args.kind, version=args.version,
                                     source_root=args.source_root, installer_sha256=args.installer_sha256), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
