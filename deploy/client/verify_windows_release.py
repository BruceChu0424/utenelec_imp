"""Replay the server's paired_v1 publishing contract on finished Windows bytes.

The publish page validates uploaded Windows packages field by field (server:
ClientPackageInspector / WindowsFlutterPackageInspector / WindowsSetupInspector,
paired contract since b4f23f485). Any mismatch is reported to the operator as
one generic message ("Windows 软件清单的平台、架构、包类型或构建号与发布信息不
一致"), which is how the 2026-10-30 2.5.36 incident surfaced only at upload
time: the packager had never stamped the manifest version. This tool runs the
same checks locally on the finished Setup.exe/update ZIP, collecting every
failure with its exact field, so a defective pair never leaves the packaging
machine. Keep the checks aligned with the server classes named above.

Usage:
  python deploy/client/verify_windows_release.py \
    --setup '<dir>/UTEN-<version>-Windows-x64-Setup.exe' \
    --update '<dir>/UTEN-<version>-Windows-x64-update.zip' \
    --version <version> --build-number <build> --architecture x64 \
    --require 'https://<company>/api' --require 'https://<cloud>/api'
"""
import argparse
import hashlib
import json
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

from build_windows_installer import validate_setup
from package_windows import MANIFEST_NAME, inspect_executable_info, inspect_pe_imports

MANIFEST_LIMIT_BYTES = 8 * 1024 * 1024
REQUIRED_ENTRIES = ("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat", MANIFEST_NAME)
EXECUTABLE_IDENTITY = {"originalfilename": "uten_imp.exe", "internalname": "uten_imp",
                       "companyname": "Uten", "productname": "优腾综合管理平台"}
PE_CHARACTERISTICS_EXECUTABLE = 0x2
PE_CHARACTERISTICS_DLL = 0x2000
ELF_MACHINES = {"x86": (1, 3), "x64": (2, 62), "arm64": (2, 183)}


def _version_tuple(version: str, build_number: int) -> tuple[int, int, int, int]:
    parts = version.split("-", 2)[0].split(".", -1)
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        raise ValueError(f"Version must be three numeric components: {version!r}")
    numbers = tuple(int(part) for part in parts)
    return (*numbers, build_number)


def _pe_characteristics(blob: bytes) -> int:
    if blob[:2] != b"MZ":
        raise ValueError("not a PE image")
    header = struct.unpack_from("<I", blob, 60)[0]
    if blob[header:header + 4] != b"PE\0\0":
        raise ValueError("not a PE image")
    return struct.unpack_from("<H", blob, header + 22)[0]


def _elf_matches(blob: bytes, architecture: str) -> bool:
    expected_class, expected_machine = ELF_MACHINES[architecture]
    if len(blob) < 20 or blob[:4] != b"\x7fELF" or blob[4] != expected_class or blob[5] != 1:
        return False
    file_type, machine = struct.unpack_from("<HH", blob, 16)
    return file_type == 3 and machine == expected_machine


def verify_update_zip(path: Path, *, version: str, build_number: int, architecture: str,
                      required_endpoints: tuple[str, ...] | list[str] = ()) -> dict:
    """Collect every way the server could reject this update ZIP."""
    failures: list[str] = []
    report = {"package": str(path), "kind": "update"}
    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        return {**report, "ok": False, "failures": ["update ZIP is not a valid ZIP file"]}
    with archive:
        entries: dict[str, zipfile.ZipInfo] = {}
        for entry in archive.infolist():
            name = entry.filename.rstrip("/") if entry.filename.endswith("/") else entry.filename
            folded = name.casefold()
            if folded in entries:
                failures.append(f"archive has duplicate case-folded path: {name}")
                continue
            if entry.is_dir():
                failures.append(f"Windows package must not contain an explicit directory entry: {name}")
                continue
            mode = entry.external_attr >> 16
            if (mode & 0o170000) == 0o120000:
                failures.append(f"archive must not contain a symlink: {name}")
                continue
            if name != entry.filename or name.startswith(("/", "\\")) or "\\" in name or ":" in name:
                failures.append(f"archive entry has an unsafe path: {entry.filename!r}")
                continue
            entries[folded] = entry
        for required in REQUIRED_ENTRIES:
            if required.casefold() not in entries:
                failures.append(f"update ZIP is missing a required runtime file: {required}")
        if any(name.startswith("client_updater/") for name in entries):
            failures.append("update ZIP must not contain the first-install updater")
        if not any(name.startswith("data/flutter_assets/") for name in entries):
            failures.append("update ZIP is missing Flutter assets")
        if MANIFEST_NAME.casefold() not in entries:
            return {**report, "ok": False, "failures": failures or [f"update ZIP is missing {MANIFEST_NAME}"]}
        manifest_entry = entries[MANIFEST_NAME.casefold()]
        if manifest_entry.file_size > MANIFEST_LIMIT_BYTES:
            failures.append("manifest is larger than 8 MiB")
            return {**report, "ok": False, "failures": failures}
        manifest = json.loads(archive.read(manifest_entry))

        # Field-by-field mirror of the server's paired_v1 comparison; the
        # server collapses all of these into one message.
        for field, value in (("schemaVersion", 1), ("platform", "windows"),
                             ("architecture", architecture), ("buildNumber", build_number),
                             ("version", version), ("packageKind", "update"),
                             ("executable", "uten_imp.exe")):
            actual = manifest.get(field)
            if isinstance(value, str):
                if not isinstance(actual, str) or actual != value:
                    failures.append(f"manifest {field} is {actual!r}, expected {value!r}")
            elif actual != value or isinstance(actual, bool):
                failures.append(f"manifest {field} is {actual!r}, expected {value!r}")
        family = manifest.get("runtimeFamily", "flutter")
        if family != "flutter":
            failures.append(f"manifest runtimeFamily is {family!r}, expected 'flutter'")
        files = manifest.get("files")
        if not isinstance(files, list) or not files:
            failures.append("manifest files is not a non-empty array")
            files = []
        recorded: dict[str, dict] = {}
        for item in files:
            if not isinstance(item, dict):
                failures.append("manifest files contains a non-object record")
                continue
            name = item.get("path")
            if not isinstance(name, str) or not name or name.startswith("/") or "\\" in name or ".." in name.split("/"):
                failures.append(f"manifest files record has an unsafe path: {name!r}")
                continue
            if name.casefold() in recorded:
                failures.append(f"manifest files lists {name} more than once")
                continue
            recorded[name.casefold()] = item
            entry = entries.get(name.casefold())
            if entry is None:
                failures.append(f"manifest lists a file that is not in the ZIP: {name}")
                continue
            digest = hashlib.sha256(archive.read(entry)).hexdigest()
            if item.get("size") != entry.file_size:
                failures.append(f"manifest size for {name} is {item.get('size')!r}, archive has {entry.file_size}")
            if not isinstance(item.get("sha256"), str) or item["sha256"] != digest:
                failures.append(f"manifest sha256 for {name} does not match the archived bytes")
        unlisted = sorted(set(entries) - set(recorded) - {MANIFEST_NAME.casefold()})
        for name in unlisted:
            failures.append(f"archive contains a file that the manifest does not list: {name}")
        report["manifest"] = {key: manifest.get(key) for key in
                              ("schemaVersion", "platform", "architecture", "version", "buildNumber",
                               "packageKind", "runtimeFamily", "executable")}
        report["manifest"]["files"] = len(files)

        with tempfile.TemporaryDirectory(prefix="uten-release-preflight-") as temporary:
            extracted = Path(temporary)
            for folded, entry in entries.items():
                target = extracted.joinpath(*entry.filename.split("/"))
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
            executable = extracted / "uten_imp.exe"
            if executable.is_file():
                try:
                    info = inspect_executable_info(executable)
                    expected_tuple = _version_tuple(version, build_number)
                    if info["architecture"] != architecture:
                        failures.append(f"uten_imp.exe architecture is {info['architecture']!r}, expected {architecture!r}")
                    for field in ("fileVersion", "productVersion"):
                        if info[field] != expected_tuple:
                            failures.append(f"uten_imp.exe {field} is {info[field]}, expected {expected_tuple}")
                    identity = {key.casefold(): value for key, value in info.get("strings", {}).items()}
                    for key, value in EXECUTABLE_IDENTITY.items():
                        if identity.get(key) != value:
                            failures.append(f"uten_imp.exe {key} is {identity.get(key)!r}, expected {value!r}")
                    characteristics = _pe_characteristics(executable.read_bytes())
                    if not characteristics & PE_CHARACTERISTICS_EXECUTABLE or characteristics & PE_CHARACTERISTICS_DLL:
                        failures.append("uten_imp.exe PE characteristics are not a plain executable image")
                except ValueError as error:
                    failures.append(f"uten_imp.exe cannot be verified: {error}")
            engine = extracted / "flutter_windows.dll"
            if engine.is_file():
                try:
                    # The server checks only the machine and DLL flag here; the
                    # real engine ships without version resources, so the
                    # version-resource reader must not be used on it.
                    info = inspect_pe_imports(engine)
                    if info["architecture"] != architecture:
                        failures.append(f"flutter_windows.dll architecture is {info['architecture']!r}, expected {architecture!r}")
                    characteristics = _pe_characteristics(engine.read_bytes())
                    if not characteristics & PE_CHARACTERISTICS_DLL:
                        failures.append("flutter_windows.dll PE characteristics do not mark a DLL")
                except ValueError as error:
                    failures.append(f"flutter_windows.dll cannot be verified: {error}")
            snapshot = extracted / "data" / "app.so"
            if snapshot.is_file():
                blob = snapshot.read_bytes()
                if not _elf_matches(blob, architecture):
                    failures.append(f"data/app.so is not an ELF shared object for {architecture}")
                for endpoint in required_endpoints:
                    if endpoint.encode("utf-8") not in blob:
                        failures.append(f"data/app.so does not embed the approved endpoint {endpoint}")
    return {**report, "ok": not failures, "failures": failures}


def verify_setup(path: Path, *, version: str, build_number: int, architecture: str) -> dict:
    """Outer PE version-resource check, identical to the server's setup gate."""
    try:
        validate_setup(path, version=version, build_number=build_number,
                       architecture=architecture, local_test=False)
    except ValueError as error:
        return {"package": str(path), "kind": "installer", "ok": False, "failures": [f"Setup.exe: {error}"]}
    return {"package": str(path), "kind": "installer", "ok": True, "failures": []}


def verify_pair(setup: Path, update: Path, *, version: str, build_number: int, architecture: str,
                required_endpoints: tuple[str, ...] | list[str] = ()) -> dict:
    reports = [verify_setup(setup, version=version, build_number=build_number, architecture=architecture),
               verify_update_zip(update, version=version, build_number=build_number,
                                 architecture=architecture, required_endpoints=required_endpoints)]
    failures = [failure for report in reports for failure in report["failures"]]
    return {"ok": not failures, "version": version, "buildNumber": build_number,
            "architecture": architecture, "reports": reports, "failures": failures}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--setup", required=True, type=Path)
    parser.add_argument("--update", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--architecture", choices=("x64", "arm64", "x86"), default="x64")
    parser.add_argument("--require", action="append", default=[], metavar="URL",
                        help="approved endpoint URL that must be embedded in data/app.so; repeatable")
    args = parser.parse_args(argv)
    verdict = verify_pair(args.setup, args.update, version=args.version,
                          build_number=args.build_number, architecture=args.architecture,
                          required_endpoints=args.require)
    print(json.dumps(verdict, ensure_ascii=False, indent=2))
    if verdict["ok"]:
        print(f"[OK] pair satisfies the paired_v1 contract for {args.version}+{args.build_number} {args.architecture}")
        return 0
    print(f"[FAIL] {len(verdict['failures'])} problem(s) would be rejected at publish time:")
    for failure in verdict["failures"]:
        print(f"  - {failure}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
