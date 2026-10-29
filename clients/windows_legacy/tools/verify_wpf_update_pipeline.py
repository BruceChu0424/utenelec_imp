#!/usr/bin/env python3
"""Explicit offline same-producer/native/optional-Java fixture integration.

No business executable or production updater is executed. The explicit test
harness only emits inert CLR metadata and applies approved bytes within its
own new temporary installation. Every ZIP/receipt/source repo is temporary.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import package_wpf as producer
from sync_package_contract import synchronize

def run(arguments: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(arguments, cwd=cwd, capture_output=True)
    if result.returncode:
        raise ValueError("Offline fixture command failed: " + result.stdout.decode("utf-8", "replace")
                         + result.stderr.decode("utf-8", "replace"))
    return result.stdout.decode("utf-8", "strict").strip()

def java_argument(value: str) -> str:
    # Java @argfile syntax, never a shell command.
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

def build_fixture_package(root: Path, architecture: str) -> dict:
    """Actual producer flow for an explicitly synthetic clean source and inert payload."""
    source = root / "synthetic-clean-source"
    source.mkdir()
    for name in producer.SOURCE_REQUIRED:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("Synthetic integration fixture source; not a product release.\n", encoding="utf-8")
    (source / "pubspec.yaml").write_text("name: fixture\nversion: 2.5.35+2535\n", encoding="utf-8")
    (source / "clients/windows_legacy/package-contract.json").write_bytes(producer.CONTRACT_PATH.read_bytes())
    (source / "clients/windows_legacy/Uten.Legacy.Desktop/uten.client.json").write_bytes((root / "payload/uten.client.json").read_bytes())
    (source / "clients/windows_legacy/dependencies.lock.json").write_bytes(producer.DEPENDENCY_LOCK.read_bytes())
    run(["git", "init", "-q"], cwd=source)
    run(["git", "add", "."], cwd=source)
    run(["git", "-c", "user.name=WPF integration fixture", "-c", "user.email=fixture@example.invalid",
         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=disabled-hooks", "commit", "-qm", "inert synthetic integration fixture"], cwd=source)
    state = producer.capture_source_state(source)
    receipt = root / "receipt.json"
    producer.write_build_receipt(root / "payload", receipt, architecture=architecture, source_root=source,
        source_state=state, configuration="Release", distribution_profile="Company")
    return producer.package_update(root / "payload", root / "producer.zip", architecture=architecture,
        source_root=source, receipt_path=receipt, build=True)

def verify(harness: Path, architecture: str, java_report: Path | None = None, java_exe: str | None = None) -> dict:
    synchronize()
    harness = harness.resolve(strict=True)
    if harness.name != "Uten.Wpf.PackageContract.Checks.exe":
        raise ValueError("Use the explicitly compiled package-contract test harness, never the product executable")
    with tempfile.TemporaryDirectory(prefix="uten-wpf-producer-link-") as temporary:
        root = Path(temporary).resolve()
        emitted = json.loads(run([str(harness), "emit", str(root)]))
        if emitted != {"architecture": architecture, "fixtureOnly": True}:
            raise ValueError("Native fixture harness architecture differs")
        package = build_fixture_package(root, architecture)
        # A second independent producer read precedes the native consumer.
        producer.validate_package(root / "producer.zip", architecture=architecture, version="2.5.35", build_number=2535)
        native = json.loads(run([str(harness), "verify", str(root)]))
        if native.get("architecture") != architecture or native.get("assertions", 0) < 9:
            raise ValueError("Native same-package checks did not complete")
        java_result = "not_requested"
        if java_report is not None:
            properties = {item.get("name"): item.get("value") for item in ET.parse(java_report).getroot().findall("./properties/property")}
            classpath = properties.get("java.class.path")
            java = java_exe or shutil.which("java.exe") or shutil.which("java")
            if not classpath or not java:
                raise ValueError("Existing Java executable and the isolated Surefire classpath are required")
            arguments = root / "java-fixture.args"
            arguments.write_text("-classpath\n" + java_argument(classpath) + "\n"
                "com.uten.imp.features.clientupdates.WpfProducerPackageIntegration\n"
                + java_argument(str(root / "producer.zip")) + "\n" + architecture + "\n", encoding="utf-8")
            java_result = run([str(java), "@" + str(arguments)])
            if java_result != "PASS same-producer WPF package " + architecture:
                raise ValueError("Java same-package inspector did not complete")
        return {"fixtureOnly": True, "architecture": architecture, "producerSha256": package["sha256"],
            "sizeBytes": package["sizeBytes"], "nativeAssertions": native["assertions"], "java": java_result,
            "productionExecuteRun": False, "formalPackageCreated": False, "win7Accepted": False}

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-harness", required=True, type=Path)
    parser.add_argument("--architecture", required=True, choices=("x86", "x64"))
    parser.add_argument("--java-report", type=Path)
    parser.add_argument("--java-executable")
    args = parser.parse_args()
    try:
        result = verify(args.fixture_harness, args.architecture, args.java_report, args.java_executable)
    except (ValueError, OSError, KeyError) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
