#!/usr/bin/env python3
"""Prepare or compile the standard UIMP first-install Setup.exe with Inno Setup.

The default is a validated dry run. --compile invokes an already installed ISCC;
this helper never installs build tools, fetches packages, or publishes a release.
Application updates continue to use package_windows.py's default update ZIP.
--update-output prepares both artifacts from the same private payload snapshot.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

from package_windows import inspect_executable_info, package_release, validate_package

PRODUCT_NAME = "Uten IMP Windows Setup"
ORIGINAL_FILENAME = "UtenIMPSetup.exe"
LOCAL_PRODUCT_NAME = "Uten IMP Windows Local Test Setup"
LOCAL_ORIGINAL_FILENAME = "UtenIMPLocalTestSetup.exe"
MAX_SETUP_BYTES = 512 * 1024 * 1024
HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "windows_installer.iss"
ICON = HERE.parents[1] / "windows" / "runner" / "resources" / "app_icon.ico"
ARCHITECTURES = {
    "x64": ("x64compatible", "x64compatible"),
    "arm64": ("arm64", "arm64"),
    "x86": ("x86compatible", ""),
}


def version_numbers(version: str, build_number: int) -> tuple[int, int, int, int]:
    if not isinstance(version, str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Setup version must be three numeric version components")
    parts = tuple(int(part) for part in version.split("."))
    if any(part > 65535 for part in parts) or not 1 <= build_number <= 65535:
        raise ValueError("Setup version/build must fit Windows version resource fields")
    return (*parts, build_number)


def validate_setup(path: Path, *, version: str, build_number: int, architecture: str,
                   local_test: bool = False) -> dict:
    expected = version_numbers(version, build_number)
    if architecture not in ARCHITECTURES:
        raise ValueError("Unsupported setup payload architecture")
    if path.is_symlink() or not path.is_file() or not 1 <= path.stat().st_size <= MAX_SETUP_BYTES:
        raise ValueError("Setup must be a regular EXE between 1 byte and 512 MiB")
    info = inspect_executable_info(path)
    # Inno's x86 loader can contain x64 or ARM64 application files. These fields
    # validate the loader and its declared target, not an extracted inner payload.
    if info["architecture"] != "x86" or info["peMagic"] != 0x10B:
        raise ValueError("Setup must use the standard x86 PE32 Inno loader")
    if info["fileVersion"] != expected or info["productVersion"] != expected:
        raise ValueError("Setup binary version differs from the requested release")
    numeric = ".".join(str(part) for part in expected)
    product_name = LOCAL_PRODUCT_NAME if local_test else PRODUCT_NAME
    required = {
        "ProductName": product_name,
        "OriginalFilename": LOCAL_ORIGINAL_FILENAME if local_test else ORIGINAL_FILENAME,
        "FileDescription": f"{product_name} ({architecture})",
        "FileVersion": numeric,
        "ProductVersion": numeric,
    }
    # Inno updates fixed-capacity resource fields in place and fills their tail
    # with ASCII spaces. Normalize only that documented compiler padding.
    if any(info["strings"].get(key.casefold(), "").rstrip(" \0") != value for key, value in required.items()):
        raise ValueError("Setup product/version/target resources do not match")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    receipt = {"package": str(path), "version": version, "buildNumber": build_number,
            "architecture": architecture, "loaderArchitecture": "x86", "packageKind": "installer",
            "mode": "windows_setup", "sha256": digest, "sizeBytes": path.stat().st_size,
            "validation": "outer-pe-version-resources-only"}
    if local_test:
        receipt["localTest"] = True
    return receipt


def find_compiler(requested: Path | None = None) -> Path | None:
    candidates = [requested] if requested is not None else [
        Path(found) if (found := shutil.which("ISCC.exe")) else None,
        Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Inno Setup 6/ISCC.exe",
        Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Inno Setup 6/ISCC.exe",
        Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Inno Setup 7/ISCC.exe",
    ]
    for candidate in candidates:
        if candidate is not None and candidate.is_file() and not candidate.is_symlink():
            return candidate.resolve()
    return None


def compiler_command(compiler: Path | None, payload: Path, output_directory: Path,
                     output_basename: str, *, version: str, build_number: int,
                     architecture: str, local_test: bool = False) -> list[str]:
    allowed, install64 = ARCHITECTURES[architecture]
    values = {
        "PayloadDir": str(payload), "OutputDir": str(output_directory), "SetupBaseName": output_basename,
        "AppVersion": version, "BuildNumber": str(build_number), "PayloadArchitecture": architecture,
        "AllowedArchitectures": allowed, "Install64Architectures": install64, "AppIcon": str(ICON),
    }
    return [str(compiler or "ISCC.exe"), "/Qp", *(f"/D{key}={value}" for key, value in values.items()),
            *(["/DLocalTest"] if local_test else []), str(SCRIPT)]


def _output_path(path: Path, bundle: Path, extension: str) -> Path:
    if path.is_symlink() or path.is_junction() or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._ -]{0,180}" + re.escape(extension), path.name, re.I):
        raise ValueError(f"Output must be a regular {extension} filename")
    path = path.resolve()
    if path == bundle or bundle in path.parents:
        raise ValueError("Output must be outside the runtime bundle")
    if path.exists() and not path.is_file():
        raise ValueError("Output cannot replace a directory or special file")
    return path


def _file_state(path: Path):
    if not path.exists():
        return None
    value = path.stat()
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns


def _publish_outputs(artifacts: list[tuple[Path, Path, object]]) -> list[dict]:
    """Validate all private copies before replacing the one or two named targets.

    Each replace is atomic, not the pair. A failure attempts task-scoped rollback;
    recovery copies remain available if a concurrent edit prevents safe rollback.
    """
    if not 1 <= len(artifacts) <= 2:
        raise ValueError("Only the requested setup/update targets may be published")
    states = []
    preserve_backups = False
    try:
        for source, target, validator in artifacts:
            if source.is_symlink() or not source.is_file():
                raise ValueError("Compiler/package output is missing or linked")
            if target.is_symlink() or target.is_junction() or target.resolve() != target:
                raise ValueError("Output path changed after validation")
            if target.exists() and not target.is_file():
                raise ValueError("Output cannot replace a directory or special file")
            target.parent.mkdir(parents=True, exist_ok=True)
            state = {"target": target, "incoming": None, "backup": None,
                     "before": _file_state(target), "committed": False}
            states.append(state)
            descriptor, name = tempfile.mkstemp(prefix=".uten-uimp-incoming-", suffix=target.suffix, dir=target.parent)
            os.close(descriptor)
            state["incoming"] = Path(name)
            shutil.copyfile(source, state["incoming"])
            state["receipt"] = validator(state["incoming"])
            if state["before"] is not None:
                descriptor, name = tempfile.mkstemp(prefix=".uten-uimp-backup-", suffix=target.suffix, dir=target.parent)
                os.close(descriptor)
                state["backup"] = Path(name)
                shutil.copyfile(target, state["backup"])
            if _file_state(target) != state["before"]:
                raise ValueError("Existing output changed during preparation")
        for state in states:
            if state["target"].is_symlink() or state["target"].resolve() != state["target"]:
                raise ValueError("Output path changed before publication")
            if _file_state(state["target"]) != state["before"]:
                raise ValueError("Existing output changed before publication")
            state["after"] = _file_state(state["incoming"])
            if state["after"] is None:
                raise ValueError("Prepared output disappeared before publication")
            os.replace(state["incoming"], state["target"])
            state["committed"] = True
        return [{**state["receipt"], "package": str(state["target"])} for state in states]
    except BaseException as failure:
        # Interrupted or failed recovery must never discard the only old copy.
        preserve_backups = True
        recovery = []
        for state in reversed(states):
            if not state["committed"]:
                continue
            try:
                if state["target"].is_symlink() or state["target"].resolve() != state["target"]:
                    raise OSError("Output path changed; refusing unsafe rollback")
                if _file_state(state["target"]) != state["after"]:
                    raise OSError("Published output changed; refusing to overwrite a concurrent edit")
                if state["backup"] is None:
                    state["target"].unlink()
                else:
                    os.replace(state["backup"], state["target"])
            except Exception:
                recovery.append(str(state["backup"] or state["target"]))
        if recovery:
            raise RuntimeError("Output rollback needs manual recovery; retained paths: " + ", ".join(recovery)) from failure
        preserve_backups = False
        raise
    finally:
        for state in states:
            for key in ("incoming", "backup"):
                path = state[key]
                if path is not None and not (key == "backup" and preserve_backups):
                    try:
                        path.unlink(missing_ok=True)
                    except OSError:
                        # A deferred task-local cleanup must not disguise the
                        # already known publication or rollback outcome.
                        pass


def build_windows_setup(bundle: Path, output: Path, *, version: str, build_number: int,
                        architecture: str, compiler: Path | None = None, compile: bool = False,
                        runner=subprocess.run, update_output: Path | None = None,
                        local_test: bool = False, source_root: Path | None = None) -> dict:
    expected_version = version_numbers(version, build_number)
    if architecture not in ARCHITECTURES:
        raise ValueError("Unsupported setup payload architecture")
    if local_test and update_output is not None:
        raise ValueError("Local-test setup cannot emit an update ZIP for the production distribution channel")
    bundle = bundle.resolve(strict=True)
    payload_info = inspect_executable_info(bundle / "uten_imp.exe")
    if payload_info["fileVersion"] != expected_version or payload_info["productVersion"] != expected_version:
        raise ValueError("Runtime executable file/product version differs from the requested release")
    output = _output_path(output, bundle, ".exe")
    if update_output is not None:
        update_output = _output_path(update_output, bundle, ".zip")
        if output == update_output or output.exists() and update_output.exists() and output.samefile(update_output):
            raise ValueError("Setup and update outputs must be different files")
    if not SCRIPT.is_file() or not ICON.is_file():
        raise ValueError("Installer script or application icon is missing")
    compiler = find_compiler(compiler)
    if compile and compiler is None:
        raise ValueError("Inno Setup ISCC.exe is not installed; install an approved compiler before an explicitly requested build")
    # All transient inputs are private and removed on failure or dry run. The
    # original output is atomically replaced only after a successful EXE check.
    with tempfile.TemporaryDirectory(prefix="uten-uimp-setup-") as temporary:
        staging = Path(temporary)
        archive_path = staging / "validated-bootstrap.zip"
        payload = staging / "payload"
        compiler_output = staging / "compiled"
        payload_receipt = package_release(bundle, archive_path, build_number=build_number,
                                          architecture=architecture, kind="installer", version=version,
                                          source_root=source_root)
        validate_package(archive_path, build_number=build_number, architecture=architecture, kind="installer",
                         version=version)
        payload.mkdir()
        compiler_output.mkdir()
        with zipfile.ZipFile(archive_path) as archive:
            # Paths and link bits were validated by the shared complete-package
            # algorithm. The wildcard given to ISCC contains no intermediate ZIP.
            for entry in archive.infolist():
                target = payload.joinpath(*entry.filename.split("/"))
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, target.open("xb") as destination:
                    shutil.copyfileobj(source, destination, 65536)
        update_path = staging / "application-update.zip"
        update_receipt = None
        if update_output is not None:
            # Both artifacts consume this one validated snapshot, not a second
            # read of a potentially changing external Flutter build directory.
            update_receipt = package_release(payload, update_path, build_number=build_number,
                                             architecture=architecture, version=version)
            validate_package(update_path, build_number=build_number, architecture=architecture,
                             version=version)
        command = compiler_command(compiler, payload, compiler_output, output.stem,
                                   version=version, build_number=build_number, architecture=architecture,
                                   local_test=local_test)
        if not compile:
            plan = {"dryRun": True, "compilerFound": compiler is not None, "mode": "windows_setup",
                    "packageKind": "installer", "architecture": architecture, "loaderArchitecture": "x86",
                    "version": version, "buildNumber": build_number, "output": str(output),
                    "runtimeValidation": payload_receipt["runtimeValidation"],
                    "omittedUnusedNativeArtifacts": payload_receipt["omittedUnusedNativeArtifacts"],
                    "payloadValidated": True, "command": compiler_command(compiler, Path("<validated-payload>"),
                        Path("<private-output>"), output.stem, version=version,
                        build_number=build_number, architecture=architecture, local_test=local_test)}
            if local_test:
                plan["localTest"] = True
            if update_output is not None:
                plan["updatePackage"] = {"dryRun": True, "output": str(update_output),
                    "mode": "windows_archive", "packageKind": "update", "version": version,
                    "buildNumber": build_number, "architecture": architecture, "payloadValidated": True}
                plan["publication"] = {"atomicAcrossFiles": False, "strategy": "validated-staging-with-task-scoped-rollback"}
            return plan
        runner(command, check=True, capture_output=True, text=True)
        generated = compiler_output / output.name
        artifacts = [(generated, output, lambda path: validate_setup(path, version=version,
            build_number=build_number, architecture=architecture, local_test=local_test))]
        if update_output is not None:
            def validate_update(path):
                validate_package(path, build_number=build_number, architecture=architecture,
                                 version=version)
                with path.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                if digest != update_receipt["sha256"]:
                    raise ValueError("Prepared update package changed before publication")
                return {**update_receipt, "sha256": digest, "sizeBytes": path.stat().st_size,
                        "packageKind": "update", "version": version}
            artifacts.append((update_path, update_output, validate_update))
        receipts = _publish_outputs(artifacts)
        result = {**receipts[0], "dryRun": False,
                  "runtimeValidation": payload_receipt["runtimeValidation"],
                  "omittedUnusedNativeArtifacts": payload_receipt["omittedUnusedNativeArtifacts"]}
        if update_output is not None:
            result["updatePackage"] = receipts[1]
            result["publication"] = {"atomicAcrossFiles": False, "strategy": "validated-staging-with-task-scoped-rollback"}
        return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--architecture", choices=tuple(ARCHITECTURES), default="x64")
    parser.add_argument("--iscc", type=Path)
    parser.add_argument("--update-output", type=Path, help="also prepare an in-place update ZIP from the same payload")
    parser.add_argument("--local-test", action="store_true", help="isolate test installation identity, directory and PE product resources")
    parser.add_argument("--source-root", type=Path,
                        help="reviewed source tree when an external bundle needs unused-JNI evidence")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--compile", action="store_true", help="explicitly compile with an already installed ISCC")
    mode.add_argument("--dry-run", action="store_true", help="validate and print the plan (default)")
    args = parser.parse_args()
    print(json.dumps(build_windows_setup(args.bundle, args.output, version=args.version,
        build_number=args.build_number, architecture=args.architecture, compiler=args.iscc,
        compile=args.compile, update_output=args.update_output, local_test=args.local_test,
        source_root=args.source_root), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
