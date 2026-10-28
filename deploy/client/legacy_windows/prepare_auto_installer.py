#!/usr/bin/env python3
"""Inspect reviewed payloads and prepare an isolated auto-installer source plan.

Never downloads a runtime, invokes ISCC, creates an EXE/ZIP, or publishes a release.
The existing Windows 10 builder, dependency policy, and release catalog are unchanged.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from build_windows_installer import version_numbers
from package_windows import (inspect_executable_info, inspect_pe_imports, required_files,
                             validate_release_path, validate_runtime_dependencies)
from runtime_policy import render_inno_policy

ROLES = {"legacy-x86": "x86", "legacy-x64": "x64", "native-x64": "x64"}
MACROS = {"legacy-x86": "PayloadLegacyX86", "legacy-x64": "PayloadLegacyX64"}
MAX_FILES = 20000
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
PRIVATE_NAMES = {"user data", "default", "login data", "cookies", "history", "preferences",
                 "local state", "web data", "profile", "profiles", "cache", "crashpad"}


def _linked(path: Path) -> bool:
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def _plain_path(path: Path) -> Path:
    path = path.absolute()
    if any(_linked(parent) for parent in (path, *path.parents)):
        raise ValueError("Linked payload or output paths are not allowed")
    if any(ord(char) < 32 or char in '\"{};' for char in str(path)):
        raise ValueError("Path cannot be represented safely in the installer source")
    return path.resolve()


def validate_company_url(value: str) -> str:
    if not isinstance(value, str) or not value or not value.isascii():
        raise ValueError("Company web entry must be an ASCII HTTPS URL")
    url = urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.username is not None
            or url.password is not None or url.query or url.fragment
            or not re.fullmatch(r"[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~/-]*)?", url.netloc + url.path)
            or any(ord(char) < 33 for char in value)):
        raise ValueError("Company URL must use HTTPS, a DNS host, and no credentials/query/fragment")
    if url.port is not None and not 1 <= url.port <= 65535:
        raise ValueError("Invalid company HTTPS port")
    host = url.hostname.lower()
    if host == "localhost" or host.endswith((".localhost", ".invalid")):
        raise ValueError("Local test or placeholder entries cannot enter this installer plan")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("Use the approved HTTPS DNS name rather than an IP address")
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", host):
        raise ValueError("Invalid company DNS name")
    return value


def inventory(root: Path) -> dict[str, str]:
    """Hash an exact pristine runtime tree; never load its EXE/DLL files."""
    root = _plain_path(root)
    if not root.is_dir():
        raise ValueError("Payload directory does not exist")
    files = {}
    seen = set()
    total = 0
    for folder, directories, names in os.walk(root, followlinks=False):
        for name in sorted(directories + names):
            path = Path(folder) / name
            if _linked(path):
                raise ValueError("Linked runtime entries are not allowed")
            if name.casefold() in PRIVATE_NAMES or path.suffix.casefold() in {".key", ".p12", ".pfx"}:
                raise ValueError("Runtime must be pristine: private profile/key/cache entry found")
            if path.is_dir():
                continue
            if not path.is_file():
                raise ValueError("Runtime contains a special file")
            relative = path.relative_to(root).as_posix()
            if any(ord(char) < 32 or char in '\"{};:' for char in relative):
                raise ValueError("Unsafe runtime filename")
            key = relative.casefold()
            if key in seen:
                raise ValueError("Case-insensitive duplicate runtime path")
            seen.add(key)
            total += path.stat().st_size
            if len(seen) > MAX_FILES or total > MAX_TOTAL_BYTES:
                raise ValueError("Runtime inventory exceeds the package bounds")
            with path.open("rb") as stream:
                files[relative] = hashlib.file_digest(stream, "sha256").hexdigest()
    if not files:
        raise ValueError("Runtime payload is empty")
    return dict(sorted(files.items()))


def inspect_review(review: dict, company_web_url: str) -> dict:
    if not isinstance(review, dict) or review.get("schemaVersion") != 1:
        raise ValueError("Unsupported review schema")
    version, build = review.get("applicationVersion"), review.get("applicationBuild")
    if type(build) is not int:
        raise ValueError("Application build must be an integer")
    expected_version = version_numbers(version, build)
    if not isinstance(review.get("sourceCommit"), str) or not re.fullmatch(r"[0-9a-f]{40}", review["sourceCommit"]):
        raise ValueError("An exact reviewed application source commit is required")
    company_web_url = validate_company_url(company_web_url)
    runtimes = review.get("runtimes")
    if not isinstance(runtimes, dict) or set(runtimes) != set(ROLES):
        raise ValueError("Supply exactly legacy-x86, legacy-x64 and native-x64 reviewed payloads")
    checked = {}
    for role, architecture in ROLES.items():
        item = runtimes[role]
        if not isinstance(item, dict) or not isinstance(item.get("directory"), str):
            raise ValueError("Each runtime must name its reviewed directory")
        root = _plain_path(Path(item["directory"]))
        actual = inventory(root)
        expected = item.get("files")
        if (not isinstance(expected, dict) or not expected
                or any(not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
                       for digest in expected.values()) or actual != expected):
            raise ValueError(f"{role}: files differ from the reviewed SHA-256 inventory")
        if role.startswith("legacy-"):
            if item.get("vendor") != "Supermium" or not isinstance(item.get("runtimeVersion"), str) or not item["runtimeVersion"].strip():
                raise ValueError("Legacy runtime requires its vendor and exact reviewed version")
            if not isinstance(item.get("sourceUrl"), str):
                raise ValueError("Legacy runtime requires its HTTPS upstream source URL")
            source = urlsplit(item["sourceUrl"])
            if source.scheme != "https" or not source.hostname or source.username or source.password:
                raise ValueError("Legacy runtime requires its HTTPS upstream source URL")
            licenses = item.get("licenseFiles")
            if (not isinstance(licenses, list) or not licenses
                    or any(not isinstance(name, str) or name not in actual or (root / name).stat().st_size == 0
                           for name in licenses)):
                raise ValueError("Preserve the reviewed runtime and third-party license texts")
            for required in ("chrome.exe", "chrome.dll", "icudtl.dat"):
                if required not in actual:
                    raise ValueError(f"{role}: missing browser runtime component {required}")
            for name in ("chrome.exe", "chrome.dll"):
                if inspect_pe_imports(root / name)["architecture"] != architecture:
                    raise ValueError(f"{role}: runtime architecture mismatch")
            # The ordinary native validator explicitly assumes Windows 10 OS
            # contracts. Never apply it to legacy modules and call that Win7 proof.
            validation = "hashes-and-entrypoint-architecture; legacy imports/OS execution still require review"
        else:
            if not required_files("installer").issubset(actual):
                raise ValueError("Native payload is missing a complete existing first-install runtime")
            if not any(name.startswith("data/flutter_assets/") for name in actual):
                raise ValueError("Native payload is missing the existing Flutter assets")
            for name in actual:
                validate_release_path(name, kind="installer")
            info = inspect_executable_info(root / "uten_imp.exe")
            if info["architecture"] != architecture or info["fileVersion"] != expected_version or info["productVersion"] != expected_version:
                raise ValueError("Native application version/build/architecture differs from the reviewed application")
            modules = {name: inspect_pe_imports(root / name) for name in actual
                       if Path(name).suffix.casefold() in {".exe", ".dll"}}
            with (root / "data/app.so").open("rb") as stream:
                aot_header = stream.read(2)
            if aot_header == b"MZ":
                modules["data/app.so"] = inspect_pe_imports(root / "data/app.so")
            validation = validate_runtime_dependencies(modules, architecture=architecture)
        checked[role] = {"directory": str(root), "architecture": architecture,
                         "files": actual, "validation": validation}
    roots = [Path(item["directory"]) for item in checked.values()]
    if any(a == b or a in b.parents or b in a.parents for index, a in enumerate(roots) for b in roots[index + 1:]):
        raise ValueError("The three payloads require separate, non-overlapping directories")
    return {"schemaVersion": 1, "status": "source-plan-only", "releaseReady": False,
            "applicationVersion": version, "applicationBuild": build,
            "sourceCommit": review["sourceCommit"], "companyWebUrl": company_web_url,
            "runtimes": checked, "publication": "not-connected-to-current-client-catalog",
            "modernWindowsBehavior": "pilot exits before installing or launching any native client",
            "remainingValidation": ["review exact runtime redistribution licenses and OS import compatibility",
                "Win7 x86/x64 and Win8/8.1 real-machine end-to-end acceptance",
                "browser company-CA trust, authentication, files, exports and printing",
                "runtime updates with no cross-target recommendation or package cleanup",
                "same reviewed application source/version for native and served Web UI"]}


def write_source_plan(plan: dict, directory: Path) -> None:
    directory = _plain_path(directory)
    roots = [Path(item["directory"]) for item in plan["runtimes"].values()]
    if directory.exists() or any(directory == root or directory in root.parents or root in directory.parents for root in roots):
        raise ValueError("Plan directory must be new and outside all payload directories")
    directory.mkdir(parents=True)
    policy_path = directory / "runtime_policy.iss"
    policy_path.write_text(render_inno_policy(), encoding="utf-8-sig")
    values = {macro: plan["runtimes"][role]["directory"] for role, macro in MACROS.items()}
    values.update({"CompanyWebUrl": plan["companyWebUrl"], "AppVersion": plan["applicationVersion"],
                   "BuildNumber": str(plan["applicationBuild"]), "OutputDir": str(directory / "artifacts"),
                   "SetupBaseName": "UTEN-CompatibilityPilot-Auto-Setup",
                   "AppIcon": str(HERE.parents[2] / "windows/runner/resources/app_icon.ico"),
                   "PolicyInclude": str(policy_path)})
    source = "\n".join(f'#define {key} "{value}"' for key, value in values.items())
    source += f'\n#include "{HERE / "windows_auto_installer.iss"}"\n'
    (directory / "auto_installer_inputs.iss").write_text(source, encoding="utf-8-sig")
    (directory / "plan.json").write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    scan = commands.add_parser("inventory", help="print hashes for human review; no approval is implied")
    scan.add_argument("directory", type=Path)
    prepare = commands.add_parser("plan", help="inspect reviewed inputs; never compile/package/publish")
    prepare.add_argument("--review", type=Path, required=True)
    prepare.add_argument("--company-web-url", required=True)
    prepare.add_argument("--source-output", type=Path, help="optional new folder for source plan/ISS includes")
    args = parser.parse_args()
    try:
        if args.command == "inventory":
            result = inventory(args.directory)
        else:
            result = inspect_review(json.loads(args.review.read_text(encoding="utf-8-sig")), args.company_web_url)
            if args.source_output:
                write_source_plan(result, args.source_output)
    except (ValueError, OSError, TypeError, KeyError) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
