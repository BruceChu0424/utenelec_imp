#!/usr/bin/env python3
"""Validate and freeze a native WPF *candidate* update ZIP; never publish it.

Use source-state before the Release/Company compilation, receipt afterwards,
then package (dry-run by default). No EXE/DLL is loaded or executed. A receipt
is local build provenance, not Authenticode or proof of complete ERP/Win7 UAT.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "deploy/client"))
from package_windows import _PeReader, inspect_executable_info

MANIFEST = "uten-client-manifest.json"
EXECUTABLE = "Uten.Legacy.Desktop.exe"
CORE = "Uten.Legacy.Core.dll"
BC = "BouncyCastle.Cryptography.dll"
LICENSE = "BouncyCastle-LICENSE.md"
APP_CONFIG = EXECUTABLE + ".config"
REQUIRED = {EXECUTABLE, CORE, BC, APP_CONFIG, LICENSE, "uten.client.json"}
ALLOWED = REQUIRED
DEPENDENCY_LOCK = HERE.parent / "dependencies.lock.json"
MARKER = "UTEN WPF candidate; Configuration=Release; Distribution=Company"
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_PACKAGE_BYTES = 512 * 1024 * 1024
MAX_TOTAL_BYTES = 1024 * 1024 * 1024 - 1
MAX_JSON_BYTES = 8 * 1024 * 1024
SOURCE_PATHS = ["clients/windows_legacy", "pubspec.yaml", "assets/security/uten-imp-root-ca.crt",
    "assets/fonts/NotoSansSC.ttf", "assets/images/logo_ip.png", "assets/images/logo_name.png",
    "windows/runner/resources/app_icon.ico", "lib/core/theme"]
SOURCE_REQUIRED = {"pubspec.yaml", "clients/windows_legacy/BuildVersion.targets",
    "clients/windows_legacy/dependencies.lock.json",
    "clients/windows_legacy/Uten.Legacy.Desktop/uten.client.json",
    "clients/windows_legacy/Uten.Legacy.Core/Uten.Legacy.Core.csproj",
    "clients/windows_legacy/Uten.Legacy.Desktop/Uten.Legacy.Desktop.csproj"}


def _plain(path: Path) -> Path:
    path = path.absolute()
    for parent in (path, *path.parents):
        if parent.is_symlink() or (hasattr(parent, "is_junction") and parent.is_junction()):
            raise ValueError("Symlinks and junctions are not approved package paths")
    return path.resolve()


def _digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _json(data: bytes) -> dict:
    if len(data) > MAX_JSON_BYTES:
        raise ValueError("JSON document exceeds the bounded inspection limit")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key")
            result[key] = value
        return result
    value = json.loads(data.decode("utf-8-sig"), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object")
    return value


def _read_json(path: Path) -> dict:
    path = _plain(path)
    if not path.is_file() or path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError("JSON input must be a bounded ordinary file")
    return _json(path.read_bytes())


def _version(source_root: Path) -> tuple[str, int]:
    text = (source_root / "pubspec.yaml").read_text(encoding="utf-8-sig")
    values = re.findall(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$", text, re.M)
    if len(values) != 1:
        raise ValueError("Source pubspec must contain exactly one numeric version/build")
    version, raw_build = values[0]
    parts, build = tuple(int(item) for item in version.split(".")), int(raw_build)
    if any(number > 65535 for number in parts) or not 1 <= build <= 65535:
        raise ValueError("Source version/build does not fit PE version fields")
    return version, build


def _git(root: Path, *arguments: str) -> str:
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, check=False)
    if result.returncode:
        raise ValueError("Cannot verify the reviewed Git source state")
    return result.stdout.decode("utf-8", errors="strict").strip()


def capture_source_state(source_root: Path) -> dict:
    source_root = _plain(source_root)
    if Path(_git(source_root, "rev-parse", "--show-toplevel")).resolve() != source_root:
        raise ValueError("Source root must identify the exact Git worktree")
    if _git(source_root, "status", "--porcelain=v1", "--untracked-files=normal"):
        raise ValueError("Candidate build source must be committed and clean")
    commit = _git(source_root, "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Cannot identify the reviewed source commit")
    names = [name for name in _git(source_root, "ls-files", "-z", "--", *SOURCE_PATHS).split("\0") if name]
    if not SOURCE_REQUIRED.issubset(names):
        raise ValueError("Reviewed source is missing required WPF inputs")
    files = []
    for name in sorted(names):
        if not name or name.startswith("/") or ".." in Path(name).parts or "\\" in name:
            raise ValueError("Unsafe tracked source path")
        path = _plain(source_root / name)
        if source_root not in path.parents or not path.is_file():
            raise ValueError("Tracked build input is missing or leaves the source tree")
        files.append({"path": name, "size": path.stat().st_size, "sha256": _digest(path)})
    version, build = _version(source_root)
    return {"schemaVersion": 1, "sourceCommit": commit, "sourceFiles": files,
            "version": version, "buildNumber": build}


def inspect_managed(path: Path, *, executable: bool) -> dict:
    """Use the existing bounded RVA reader for CLR flags and metadata version."""
    with path.open("rb") as stream:
        reader = _PeReader(stream, path.stat().st_size)
        dos = reader.read_at(0, 64)
        pe = struct.unpack_from("<I", dos, 60)[0]
        flags = struct.unpack("<H", reader.read_at(pe + 22, 2))[0]
        if not flags & 2 or bool(flags & 0x2000) == executable:
            raise ValueError("Managed application/DLL PE characteristics differ")
        rva, size = reader.directory(14)
        if not rva or size < 72:
            raise ValueError("Managed CLR header is missing")
        header = reader.read_at(reader.file_offset(rva, 72), 72)
        if struct.unpack_from("<I", header)[0] < 72:
            raise ValueError("Managed CLR header is invalid")
        metadata_rva, metadata_size, clr_flags = struct.unpack_from("<III", header, 8)
        if not clr_flags & 1 or clr_flags & 0x10:
            raise ValueError("Expected IL-only managed code, not a native CLR entry point")
        if metadata_size < 20 or metadata_size > 16 * 1024 * 1024:
            raise ValueError("Managed metadata is missing or oversized")
        metadata = reader.file_offset(metadata_rva, metadata_size)
        prefix = reader.read_at(metadata, 16)
        version_length = struct.unpack_from("<I", prefix, 12)[0]
        if prefix[:4] != b"BSJB" or not 1 <= version_length <= 256 or 16 + version_length > metadata_size:
            raise ValueError("Managed metadata root is invalid")
        version = reader.read_at(metadata + 16, version_length).rstrip(b"\0")
        if not version.startswith(b"v4."):
            raise ValueError("WPF payload requires CLR v4 metadata")
        if reader.architecture == "x64" and not clr_flags & (2 | 0x20000):
            architecture = "x64"
        elif reader.architecture == "x86" and clr_flags & 2 and not clr_flags & 0x20000:
            architecture = "x86"
        elif reader.architecture == "x86" and not clr_flags & (2 | 0x20000):
            architecture = "anycpu"
        else:
            raise ValueError("Managed architecture/CLR flags are inconsistent")
        return {"architecture": architecture, "clrFlags": clr_flags, "metadataVersion": version.decode("ascii")}


def _configuration(path: Path) -> None:
    if path.stat().st_size > 65536:
        raise ValueError("Company configuration exceeds the native client's 64 KiB limit")
    data = _read_json(path)
    if set(data) - {"endpoints", "selectedEndpointId", "requestTimeoutSeconds", "maxResponseBytes"}:
        raise ValueError("Company configuration contains unapproved or private settings")
    endpoints = data.get("endpoints")
    if not isinstance(endpoints, list) or not 1 <= len(endpoints) <= 8:
        raise ValueError("Company configuration requires reviewed nonempty endpoints")
    ids = set()
    for endpoint in endpoints:
        if not isinstance(endpoint, dict) or set(endpoint) != {"id", "name", "apiBaseUrl"}:
            raise ValueError("Unapproved endpoint fields")
        identifier, name, address = endpoint["id"], endpoint["name"], endpoint["apiBaseUrl"]
        if (not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", identifier)
                or identifier in ids or not isinstance(name, str) or not name.strip() or len(name) > 100
                or any(ord(char) < 32 for char in name) or not isinstance(address, str)
                or len(address) > 2048 or any(ord(char) <= 32 or ord(char) == 127 for char in address) or "\\" in address):
            raise ValueError("Invalid reviewed endpoint identity or HTTPS address")
        uri = urlsplit(address)
        host = (uri.hostname or "").lower().rstrip(".")
        if (uri.scheme != "https" or not host or uri.username is not None or uri.password is not None
                or uri.query or uri.fragment or uri.path not in {"/api", "/api/"}
                or uri.port is not None and not 1 <= uri.port <= 65535 or "%" in host
                or host == "localhost" or host.endswith(".localhost")):
            raise ValueError("Company endpoint must be a nonlocal HTTPS /api address")
        try:
            literal = ipaddress.ip_address(host)
        except ValueError:
            if (re.fullmatch(r"(?:0x[0-9a-f]+|[0-9]+)(?:\.(?:0x[0-9a-f]+|[0-9]+)){0,3}", host)
                    or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", host)):
                raise ValueError("Ambiguous numeric or invalid company host")
        else:
            mapped = getattr(literal, "ipv4_mapped", None)
            if literal.is_loopback or literal.is_unspecified or mapped and (mapped.is_loopback or mapped.is_unspecified):
                raise ValueError("LocalTest/localhost cannot enter a company candidate")
        ids.add(identifier)
    if data.get("selectedEndpointId") not in ids:
        raise ValueError("Default endpoint is not in the reviewed endpoint list")
    for key, minimum, maximum in (("requestTimeoutSeconds", 1, 120), ("maxResponseBytes", 1024, 8388608)):
        if key in data and (type(data[key]) is not int or not minimum <= data[key] <= maximum):
            raise ValueError("Invalid company network limit")


def _runtime_configuration(path: Path) -> None:
    data = path.read_bytes()
    if len(data) > 65536 or b"<!doctype" in data.lower() or b"<!entity" in data.lower():
        raise ValueError("Runtime configuration is oversized or contains a DTD/entity")
    try:
        document = ET.fromstring(data)
    except ET.ParseError as error:
        raise ValueError("Malformed runtime configuration") from error
    allowed = {"configuration", "startup", "supportedRuntime", "runtime", "AppContextSwitchOverrides",
               "assemblyBinding", "dependentAssembly", "assemblyIdentity", "bindingRedirect"}
    for element in document.iter():
        if element.tag.rsplit("}", 1)[-1] not in allowed:
            raise ValueError("Runtime configuration contains unapproved settings or remote assembly loading")
    runtimes = document.findall("./startup/supportedRuntime")
    if len(runtimes) != 1 or runtimes[0].attrib != {"version": "v4.0", "sku": ".NETFramework,Version=v4.8"}:
        raise ValueError("WPF requires the fixed .NET Framework 4.8 runtime configuration")
    startup = document.find("startup")
    if startup is not None and startup.get("useLegacyV2RuntimeActivationPolicy", "false").lower() != "false":
        raise ValueError("Legacy CLR activation cannot enter a .NET Framework 4.8 candidate")


def inspect_bundle(bundle: Path, *, architecture: str, version: str, build_number: int) -> list[dict]:
    if architecture not in {"x86", "x64"}:
        raise ValueError("WPF supports only x86 and x64")
    bundle = _plain(bundle)
    if not bundle.is_dir():
        raise ValueError("Approved WPF payload directory is missing")
    paths = {}
    total = 0
    for path in bundle.iterdir():
        checked = _plain(path)
        if path.name not in ALLOWED or not checked.is_file() or checked.parent != bundle:
            raise ValueError("Only the six approved app files may enter the WPF update payload")
        size = checked.stat().st_size
        if not 1 <= size <= MAX_FILE_BYTES:
            raise ValueError("WPF payload file is empty or oversized")
        total += size
        if total > MAX_TOTAL_BYTES:
            raise ValueError("Expanded WPF payload is oversized")
        paths[path.name] = checked
    if not REQUIRED.issubset(paths):
        raise ValueError("WPF payload is missing a required app file")
    main = inspect_managed(paths[EXECUTABLE], executable=True)
    core = inspect_managed(paths[CORE], executable=False)
    bc = inspect_managed(paths[BC], executable=False)
    if main["architecture"] != architecture or core["architecture"] not in {architecture, "anycpu"} or bc["architecture"] != "anycpu":
        raise ValueError("WPF main/Core/BC CLR architecture does not match the target")
    expected = (*[int(value) for value in version.split(".")], build_number)
    for name in (EXECUTABLE, CORE):
        info = inspect_executable_info(paths[name])
        if info["fileVersion"] != expected or info["productVersion"] != expected:
            raise ValueError("WPF app/Core file version differs from the reviewed pubspec version/build")
        if info["strings"].get("comments") != MARKER:
            raise ValueError("Only compiled Release/Company candidate markers are accepted; Debug/LocalTest is forbidden")
    lock = _read_json(DEPENDENCY_LOCK)
    pins = lock.get("files", {})
    if (lock.get("schemaVersion") != 1 or lock.get("package") != "BouncyCastle.Cryptography"
            or pins.get("lib/net461/BouncyCastle.Cryptography.dll") != _digest(paths[BC])
            or pins.get("LICENSE.md") != _digest(paths[LICENSE])):
        raise ValueError("BouncyCastle DLL/license differ from the fixed private dependency lock")
    _configuration(paths["uten.client.json"])
    _runtime_configuration(paths[APP_CONFIG])
    return [{"path": name, "size": paths[name].stat().st_size, "sha256": _digest(paths[name])} for name in sorted(paths)]


def _output(path: Path, bundle: Path, suffix: str) -> Path:
    path = _plain(path)
    if path.suffix.lower() != suffix or path == bundle or bundle in path.parents or path.exists() and not path.is_file():
        raise ValueError("Output must be a named ordinary file outside the approved payload")
    return path


def _write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".uten-wpf-receipt-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _same(value, expected) -> bool:
    # JSON distinguishes true from 1 and 1.0; Python's ordinary equality does not.
    return json.dumps(value, sort_keys=True, separators=(",", ":")) == json.dumps(expected, sort_keys=True, separators=(",", ":"))


def _source_configuration(bundle: Path, state: dict) -> None:
    approved = next(item for item in state["sourceFiles"]
                    if item["path"] == "clients/windows_legacy/Uten.Legacy.Desktop/uten.client.json")
    if _digest(bundle / "uten.client.json") != approved["sha256"]:
        raise ValueError("Payload endpoint configuration differs from the reviewed Company source")


def write_build_receipt(bundle: Path, output: Path, *, architecture: str, source_root: Path,
                        source_state: dict, configuration: str, distribution_profile: str) -> dict:
    if configuration != "Release" or distribution_profile != "Company":
        raise ValueError("Only an explicit Release/Company compilation can create a candidate build receipt")
    current = capture_source_state(source_root)
    if not _same(current, source_state):
        raise ValueError("Source changed during compilation; no build receipt can be issued")
    bundle = _plain(bundle)
    files = inspect_bundle(bundle, architecture=architecture, version=current["version"], build_number=current["buildNumber"])
    _source_configuration(bundle, current)
    receipt = {**current, "runtimeFamily": "wpf_legacy", "platform": "windows", "architecture": architecture,
               "configuration": configuration, "distributionProfile": distribution_profile, "files": files}
    _write_json(_output(output, bundle, ".json"), receipt)
    return receipt


def validate_package(path: Path, *, architecture: str, version: str, build_number: int) -> dict:
    path = _plain(path)
    if not path.is_file() or not 1 <= path.stat().st_size <= MAX_PACKAGE_BYTES:
        raise ValueError("Candidate ZIP is absent or oversized")
    with zipfile.ZipFile(path) as archive, tempfile.TemporaryDirectory(prefix="uten-wpf-verify-") as temporary:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        if (len(names) != len(set(name.casefold() for name in names)) or MANIFEST not in names
                or set(names) - (ALLOWED | {MANIFEST}) or not REQUIRED.issubset(names)):
            raise ValueError("Candidate ZIP file allowlist is invalid")
        total = 0
        root = Path(temporary)
        for item in entries:
            mode = item.external_attr >> 16
            if (item.flag_bits & 1 or stat.S_IFMT(mode) not in {0, stat.S_IFREG}
                    or item.is_dir() or not 1 <= item.file_size <= MAX_FILE_BYTES):
                raise ValueError("Candidate ZIP contains an unsafe entry")
            total += item.file_size
            if total > MAX_TOTAL_BYTES:
                raise ValueError("Expanded candidate ZIP is oversized")
            with archive.open(item) as source, (root / item.filename).open("wb") as target:
                received = 0
                for chunk in iter(lambda: source.read(65536), b""):
                    received += len(chunk)
                    if received > item.file_size:
                        raise ValueError("Candidate ZIP expanded size differs")
                    target.write(chunk)
                if received != item.file_size:
                    raise ValueError("Candidate ZIP is truncated")
        manifest = _read_json(root / MANIFEST)
        expected = {"schemaVersion": 1, "platform": "windows", "runtimeFamily": "wpf_legacy",
            "architecture": architecture, "version": version, "buildNumber": build_number,
            "packageKind": "update", "executable": EXECUTABLE, "candidate": True, "releaseReady": False}
        if any(type(manifest.get(key)) is not type(value) or manifest[key] != value for key, value in expected.items()):
            raise ValueError("Candidate manifest runtime/version/architecture/type differs")
        (root / MANIFEST).unlink()
        files = inspect_bundle(root, architecture=architecture, version=version, build_number=build_number)
        if not _same(manifest.get("files"), files):
            raise ValueError("Candidate ZIP contents differ from their exact SHA-256 manifest")
        return manifest


def package_update(bundle: Path, output: Path, *, architecture: str, source_root: Path,
                   receipt_path: Path, build: bool = False) -> dict:
    state = capture_source_state(source_root)
    receipt = _read_json(receipt_path)
    expected = {**state, "runtimeFamily": "wpf_legacy", "platform": "windows", "architecture": architecture,
                "configuration": "Release", "distributionProfile": "Company"}
    if any(not _same(receipt.get(key), value) for key, value in expected.items()):
        raise ValueError("Build receipt does not match this clean reviewed Release/Company source")
    bundle = _plain(bundle)
    output = _output(output, bundle, ".zip")
    files = inspect_bundle(bundle, architecture=architecture, version=state["version"], build_number=state["buildNumber"])
    _source_configuration(bundle, state)
    if not _same(receipt.get("files"), files):
        raise ValueError("Payload changed after its build receipt was recorded")
    manifest = {"schemaVersion": 1, "runtimeFamily": "wpf_legacy", "platform": "windows",
        "architecture": architecture, "version": state["version"], "buildNumber": state["buildNumber"],
        "packageKind": "update", "executable": EXECUTABLE, "files": files,
        "sourceCommit": state["sourceCommit"], "candidate": True, "releaseReady": False}
    result = {"mode": "candidate" if build else "dry-run", "package": str(output), **manifest,
        "remainingValidation": ["complete ERP workflow migration", "Win7 target-PC acceptance", "native updater implementation/acceptance"]}
    if not build:
        return result
    output.parent.mkdir(parents=True, exist_ok=True)
    old_state = _digest(output) if output.exists() else None
    with tempfile.TemporaryDirectory(prefix=".uten-wpf-candidate-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        frozen = temporary / "payload"
        frozen.mkdir()
        for item in files:
            shutil.copyfile(_plain(bundle / item["path"]), frozen / item["path"])
        if inspect_bundle(frozen, architecture=architecture, version=state["version"], build_number=state["buildNumber"]) != files:
            raise ValueError("Payload changed while freezing the private snapshot")
        candidate = temporary / "candidate.zip"
        with zipfile.ZipFile(candidate, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for item in files:
                archive.write(frozen / item["path"], item["path"])
            archive.writestr(MANIFEST, json.dumps(manifest, ensure_ascii=False, separators=(",", ":")))
        validate_package(candidate, architecture=architecture, version=state["version"], build_number=state["buildNumber"])
        if capture_source_state(source_root) != state:
            raise ValueError("Source changed while preparing the candidate ZIP")
        if _plain(output) != output or (_digest(output) if output.exists() else None) != old_state:
            raise ValueError("Output changed during candidate preparation; previous bytes preserved")
        result.update({"sha256": _digest(candidate), "sizeBytes": candidate.stat().st_size})
        os.replace(candidate, output)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    state = commands.add_parser("source-state")
    state.add_argument("--source-root", type=Path, default=ROOT)
    receipt = commands.add_parser("receipt")
    package = commands.add_parser("package")
    for command in (receipt, package):
        command.add_argument("--source-root", type=Path, default=ROOT)
        command.add_argument("--bundle", type=Path, required=True)
        command.add_argument("--architecture", choices=("x86", "x64"), required=True)
        command.add_argument("--output", type=Path, required=True)
    receipt.add_argument("--source-state", type=Path, required=True)
    receipt.add_argument("--configuration", required=True)
    receipt.add_argument("--distribution-profile", required=True)
    package.add_argument("--receipt", type=Path, required=True)
    mode = package.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--build", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "source-state":
            result = capture_source_state(args.source_root)
        elif args.command == "receipt":
            result = write_build_receipt(args.bundle, args.output, architecture=args.architecture, source_root=args.source_root,
                source_state=_read_json(args.source_state), configuration=args.configuration, distribution_profile=args.distribution_profile)
        else:
            result = package_update(args.bundle, args.output, architecture=args.architecture, source_root=args.source_root,
                receipt_path=args.receipt, build=args.build)
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
