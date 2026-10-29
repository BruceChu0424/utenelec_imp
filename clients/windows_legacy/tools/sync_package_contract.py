#!/usr/bin/env python3
"""Offline schema-1 WPF package contract and dependency-lock bindings.

The JSON contract owns package constants; dependencies.lock.json alone owns
vendor hashes. --write regenerates C#/Java consumers, --check is read-only.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
CONTRACT = HERE.parent / "package-contract.json"
LOCK = HERE.parent / "dependencies.lock.json"
CS = HERE.parent / "Uten.Legacy.Updater/PackageContract.g.cs"
JAVA = ROOT / "server/src/main/java/com/uten/imp/features/clientupdates/WpfPackageContract.java"

def _object(data: bytes) -> dict:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate contract key")
            result[key] = value
        return result
    value = json.loads(data.decode("utf-8-sig"), object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError("Expected contract object")
    return value

def load_contract(path: Path = CONTRACT, lock_path: Path = LOCK) -> dict:
    contract = _object(path.read_bytes())
    required = {"schemaVersion", "contractId", "platform", "runtimeFamily", "packageKind", "executable", "manifest",
        "architectures", "files", "maximumPackageBytes", "maximumFileBytes", "maximumExpandedBytesExclusive",
        "maximumManifestBytes", "maximumCentralDirectoryBytes", "maximumManagedFileBytes", "maximumMetadataBytes", "maximumClrVersionBytes",
        "clrHeaderBytes", "clrVersionPrefix", "companyReleaseMarker", "maximumConfigurationBytes", "maximumLicenseBytes",
        "manifestRequiredKeys", "manifestOptionalKeys", "fileRecordKeys", "dependency"}
    if set(contract) != required or type(contract["schemaVersion"]) is not int or contract["schemaVersion"] != 1:
        raise ValueError("Unknown WPF package contract schema or fields")
    for key in required:
        if key.startswith("maximum") or key == "clrHeaderBytes":
            if type(contract[key]) is not int or not 1 <= contract[key] <= 2**31 - 1:
                raise ValueError("Invalid bounded contract constant: " + key)
        elif key not in {"schemaVersion", "architectures", "files", "manifestRequiredKeys", "manifestOptionalKeys", "fileRecordKeys", "dependency"}:
            if not isinstance(contract[key], str) or not contract[key] or any(ord(character) < 32 for character in contract[key]):
                raise ValueError("Invalid contract text constant: " + key)
    if not (contract["maximumMetadataBytes"] <= contract["maximumManagedFileBytes"] <= contract["maximumFileBytes"]
            <= contract["maximumPackageBytes"] < contract["maximumExpandedBytesExclusive"]
            and contract["maximumManifestBytes"] <= contract["maximumFileBytes"]):
        raise ValueError("Inconsistent bounded package limits")
    if (contract["platform"], contract["runtimeFamily"], contract["packageKind"]) != ("windows", "wpf_legacy", "update"):
        raise ValueError("Schema 1 belongs only to the independent WPF update runtime")
    for key in ("files", "architectures", "manifestRequiredKeys", "manifestOptionalKeys", "fileRecordKeys"):
        values = contract[key]
        if not isinstance(values, list) or not values or any(not isinstance(item, str) or not item for item in values) or len(set(values)) != len(values):
            raise ValueError("Invalid contract collection: " + key)
    if contract["architectures"] != ["x86", "x64"] or len(contract["files"]) != 6:
        raise ValueError("Schema 1 must remain a six-file x86/x64 package")
    for name in contract["files"] + [contract["manifest"]]:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ValueError("Contract file names must be ordinary root leaves")
    dependency = contract["dependency"]
    if set(dependency) != {"lockFile", "package", "version", "targetFramework", "dll", "dllLockPath", "license", "licenseLockPath", "architecture", "upgradeRequires"}:
        raise ValueError("Unknown dependency contract fields")
    lock = _object(lock_path.read_bytes())
    if (lock.get("schemaVersion") != 1 or dependency["lockFile"] != lock_path.name
            or any(lock.get(key) != dependency[key] for key in ("package", "version", "targetFramework"))
            or dependency["architecture"] != "anycpu"):
        raise ValueError("Schema-1 dependency identity differs from its authoritative lock")
    for role in ("dll", "license"):
        digest = lock.get("files", {}).get(dependency[role + "LockPath"])
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Missing authoritative dependency SHA-256")
        if dependency[role] not in contract["files"]:
            raise ValueError("Dependency file is outside the approved six-file set")
        dependency[role + "Sha256"] = digest
    return contract

def _constant(key: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", key).upper()

def render(contract: dict, source_hash: str, lock_hash: str) -> tuple[str, str]:
    header = "// Generated by sync_package_contract.py; edit package-contract.json / dependencies.lock.json only.\n"
    header += "// sourceSHA256=" + source_hash + "; dependencyLockSHA256=" + lock_hash + "\n"
    cs = [header, "namespace Uten.Legacy.Updater\n{\n    internal static class PackageContract\n    {\n"]
    java = [header, "package com.uten.imp.features.clientupdates;\n\nimport java.util.Set;\n\nfinal class WpfPackageContract {\n    private WpfPackageContract() { }\n"]
    for key, value in contract.items():
        if key == "dependency":
            continue
        name = key[0].upper() + key[1:]
        if isinstance(value, str):
            cs.append("        internal const string " + name + " = " + json.dumps(value) + ";\n")
            java.append("    static final String " + _constant(key) + " = " + json.dumps(value) + ";\n")
        elif type(value) is int:
            cs.append("        internal const int " + name + " = " + str(value) + ";\n")
            java.append("    static final int " + _constant(key) + " = " + str(value) + ";\n")
        elif isinstance(value, list):
            joined = ", ".join(json.dumps(item) for item in value)
            cs.append("        internal static readonly string[] " + name + " = { " + joined + " };\n")
            java.append("    static final Set<String> " + _constant(key) + " = Set.of(" + joined + ");\n")
    for role in ("dll", "license"):
        key = "dependency" + role.capitalize() + "Sha256"
        digest = contract["dependency"][role + "Sha256"]
        cs.append("        internal const string " + key[0].upper() + key[1:] + " = " + json.dumps(digest) + ";\n")
        java.append("    static final String " + _constant(key) + " = " + json.dumps(digest) + ";\n")
    cs.append("    }\n}\n")
    java.append("}\n")
    return "".join(cs), "".join(java)

def synchronize(write: bool = False) -> None:
    contract = load_contract()
    expected = render(contract, hashlib.sha256(CONTRACT.read_bytes()).hexdigest(), hashlib.sha256(LOCK.read_bytes()).hexdigest())
    for path, content in zip((CS, JAVA), expected):
        if write:
            path.write_text(content, encoding="utf-8", newline="\n")
        elif not path.is_file() or path.read_text(encoding="utf-8") != content:
            raise ValueError("Generated WPF package contract drift: " + str(path.relative_to(ROOT)))

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()
    try:
        synchronize(args.write)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.error(str(error))
    print("WPF package contract generated" if args.write else "WPF package contract matches authoritative sources")

if __name__ == "__main__":
    main()
