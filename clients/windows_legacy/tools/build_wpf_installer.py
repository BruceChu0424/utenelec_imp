#!/usr/bin/env python3
"""Dry-run by default: freeze validated WPF app/bootstrap inputs and compile an isolated candidate Setup.

Never runs Setup, installs dependencies, publishes or touches any existing
installation. --fixture produces an unmistakable non-installable compiler
fixture. Company mode requires the same clean-source receipts as update ZIP.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
import package_wpf as package

ROOT = package.ROOT
INSTALLER = ROOT / "clients/windows_legacy/installer/windows_wpf_installer.iss"
POLICY = INSTALLER.with_name("wpf_install_policy.iss")

def compiler_snapshot(compiler: Path) -> dict:
    paths = [path for path in compiler.parent.iterdir()
             if path.is_file() and path.suffix.lower() in {".exe", ".dll", ".e32", ".e64", ".isl", ".iss"}]
    language = compiler.parent / "Languages/ChineseSimplified.isl"
    if language.is_file():
        paths.append(language)
    return {str(path.relative_to(compiler.parent)).replace("\\", "/"): package._digest(package._plain(path)) for path in sorted(paths)}

def verify_frozen(stage: Path, plan: dict) -> None:
    common = {stage / "uten.client.json": plan["configurationSha256"], stage / "uten-wpf.ico": plan["iconSha256"],
              stage / INSTALLER.name: plan["templateSha256"], stage / POLICY.name: plan["policySha256"]}
    if any(package._digest(package._plain(path)) != expected for path, expected in common.items()):
        raise ValueError("Frozen common Setup inputs changed")
    for architecture in ("x86", "x64"):
        for record in plan["architectures"][architecture]["files"] + plan["architectures"][architecture]["bootstrap"]:
            path = package._plain(stage / architecture / record["path"])
            if path.stat().st_size != record["size"] or package._digest(path) != record["sha256"]:
                raise ValueError("Frozen Setup payload/bootstrap changed")

def inspect_inputs(payloads: dict[str, Path], helpers: dict[str, Path], configuration: Path, icon: Path,
                   *, fixture: bool, version: str, build_number: int, source_root: Path,
                   receipts: dict[str, Path] | None = None, bootstrap_receipts: dict[str, Path] | None = None) -> dict:
    state = None if fixture else package.capture_source_state(source_root)
    if state is not None and (version != state["version"] or build_number != state["buildNumber"]):
        raise ValueError("Setup version/build must match the one reviewed source state")
    if state is not None:
        recorded = {item["path"]: item["sha256"] for item in state["sourceFiles"]}
        for owning in (INSTALLER, POLICY, Path(__file__).resolve()):
            if recorded.get(owning.relative_to(ROOT).as_posix()) != package._digest(owning):
                raise ValueError("Installer tool/template/policy differ from the one reviewed source state")
    configuration, icon = package._plain(configuration), package._plain(icon)
    package._configuration(configuration)
    if not icon.is_file() or icon.suffix.lower() != ".ico" or not 1 <= icon.stat().st_size <= 1024 * 1024:
        raise ValueError("An existing bounded approved ICO is required")
    result = {"schemaVersion": 1, "candidate": True, "releaseReady": False, "fixtureOnly": fixture,
        "version": version, "buildNumber": build_number, "runtimeFamily": "wpf_legacy", "platform": "windows",
        "configurationSha256": package._digest(configuration), "iconSha256": package._digest(icon),
        "sourceState": state, "architectures": {}}
    for architecture in ("x86", "x64"):
        payload = package._plain(payloads[architecture])
        files = package.inspect_bundle(payload, architecture=architecture, version=version, build_number=build_number)
        if package._digest(payload / "uten.client.json") != result["configurationSha256"]:
            raise ValueError("Both architecture payloads must contain the same separately approved connection file")
        if state is not None:
            package._source_configuration(payload, state)
            if not receipts or architecture not in receipts:
                raise ValueError("Company Setup requires both reviewed architecture receipts")
            receipt = package._read_json(receipts[architecture])
            expected = {**state, "runtimeFamily": "wpf_legacy", "platform": "windows", "architecture": architecture,
                        "configuration": "Release", "distributionProfile": "Company", "files": files}
            if not package._same(receipt, expected):
                raise ValueError("Setup payload receipt differs from this reviewed Company source")
        bootstrap = package.inspect_bootstrap(helpers[architecture], architecture=architecture, version=version, build_number=build_number, company=not fixture)
        if state is not None:
            if not bootstrap_receipts or not bootstrap_receipts.get(architecture):
                raise ValueError("Company Setup requires both same-source bootstrap receipts")
            expected = {**state, "artifactKind": "bootstrap", "runtimeFamily": "wpf_legacy", "platform": "windows",
                "architecture": architecture, "configuration": "Release", "distributionProfile": "Company", "files": bootstrap["files"]}
            if not package._same(package._read_json(bootstrap_receipts[architecture]), expected):
                raise ValueError("Setup bootstrap receipt differs from this reviewed Company source")
        result["architectures"][architecture] = {"files": files, "bootstrap": bootstrap["files"], "bootstrapFileVersion": bootstrap["fileVersion"]}
    return result

def build_installer(payloads: dict[str, Path], helpers: dict[str, Path], configuration: Path, icon: Path,
                    output: Path, compiler: Path, *, fixture: bool = False, version: str | None = None,
                    build_number: int | None = None, source_root: Path = ROOT, receipts: dict[str, Path] | None = None,
                    build: bool = False, bootstrap_receipts: dict[str, Path] | None = None) -> dict:
    if not fixture:
        reviewed_version, reviewed_build = package._version(source_root)
        version = version or reviewed_version
        build_number = build_number or reviewed_build
    if not version or build_number is None:
        raise ValueError("Explicit fixture version/build are required")
    # Shares version range/canonical spelling with producer metadata.
    parts = version.split(".")
    if len(parts) != 3 or any(not item.isdigit() or str(int(item)) != item or int(item) > 65535 for item in parts) or not 1 <= build_number <= 65535:
        raise ValueError("Invalid bounded installer version/build")
    plan = inspect_inputs(payloads, helpers, configuration, icon, fixture=fixture, version=version,
                          build_number=build_number, source_root=source_root, receipts=receipts, bootstrap_receipts=bootstrap_receipts)
    output, compiler = package._plain(output), package._plain(compiler)
    allowed = (ROOT / "build/windows-wpf").resolve()
    if allowed not in output.parents or output.suffix.lower() != ".exe" or compiler.name.lower() != "iscc.exe" or not compiler.is_file():
        raise ValueError("Setup must use an existing ISCC and a task-private build/windows-wpf candidate output")
    if fixture and not output.name.startswith("UtenWin7WpfFixture-"):
        raise ValueError("Non-installable fixture Setup must be distinctly named UtenWin7WpfFixture-*")
    receipt_path = output.with_suffix(".receipt.json")
    if output.exists() or receipt_path.exists():
        raise ValueError("Use a new candidate filename; previous Setup/receipt bytes are preserved")
    plan.update({"mode": "fixture" if fixture else "candidate", "output": str(output),
        "compilerSha256": package._digest(compiler), "compilerInputs": compiler_snapshot(compiler), "templateSha256": package._digest(INSTALLER),
        "policySha256": package._digest(POLICY), "build": build, "setupExecuted": False, "win7Accepted": False})
    if not build:
        return plan
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".uten-wpf-setup-", dir=output.parent) as temporary:
        stage = Path(temporary).resolve()
        if stage.parent != output.parent or not stage.name.startswith(".uten-wpf-setup-"):
            raise ValueError("Setup staging leaves its exact private parent")
        for architecture in ("x86", "x64"):
            destination = stage / architecture
            destination.mkdir()
            for record in plan["architectures"][architecture]["files"]:
                shutil.copyfile(package._plain(payloads[architecture] / record["path"]), destination / record["path"])
            bootstrap = destination / "client_updater"
            bootstrap.mkdir()
            shutil.copyfile(package._plain(helpers[architecture]), bootstrap / "Uten.Legacy.Updater.exe")
            shutil.copyfile(package._plain(helpers[architecture].with_suffix(".exe.config")), bootstrap / "Uten.Legacy.Updater.exe.config")
        shutil.copyfile(configuration, stage / "uten.client.json")
        shutil.copyfile(icon, stage / "uten-wpf.ico")
        shutil.copyfile(INSTALLER, stage / INSTALLER.name)
        shutil.copyfile(POLICY, stage / POLICY.name)
        # Revalidate the frozen app leaves independently from bootstrap. Exact
        # eight-file staging never turns bootstrap into part of an update ZIP.
        verify_frozen(stage, plan)
        compiled = stage / "compiled"
        arguments = [str(compiler), "/O" + str(compiled), "/F" + output.stem,
            "/DPayloadX86=" + str(stage / "x86"), "/DPayloadX64=" + str(stage / "x64"),
            "/DUpdaterX86=" + str(stage / "x86/client_updater/Uten.Legacy.Updater.exe"),
            "/DUpdaterX64=" + str(stage / "x64/client_updater/Uten.Legacy.Updater.exe"),
            "/DOutputDir=" + str(compiled), "/DVersion=" + version, "/DBuildNumber=" + str(build_number),
            "/DAppIcon=" + str(stage / "uten-wpf.ico"), "/DAppConfiguration=" + str(stage / "uten.client.json")]
        if fixture:
            arguments.append("/DValidationFixture")
        arguments.append(str(stage / INSTALLER.name))
        process = subprocess.run(arguments, capture_output=True)
        log = process.stdout + process.stderr
        output.with_suffix(".iscc.log").write_bytes(log)
        if process.returncode:
            raise ValueError("ISCC rejected candidate; see isolated .iscc.log")
        verify_frozen(stage, plan)
        candidate = compiled / output.name
        info = package.inspect_executable_info(candidate)
        output.with_suffix(".identity.json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
        expected_version = tuple(map(int, version.split("."))) + (build_number,)
        product = "Uten IMP WPF Non-installable Fixture" if fixture else "Uten IMP Native WPF Compatibility Validation"
        if (info["architecture"] != "x86" or info["fileVersion"] != expected_version
                or info["productVersion"] != expected_version or info["strings"].get("productname", "").rstrip(" ") != product
                or info["strings"].get("filedescription", "").rstrip(" ") != product
                or info["strings"].get("originalfilename", "").rstrip(" ") != "UtenWin7WpfSetup.exe"):
            raise ValueError("Compiled Setup loader identity/version differs: " + json.dumps(info, ensure_ascii=False))
        # Bind both the frozen and live inputs again before publishing a new
        # local candidate. No overwrite, upload or installer execution exists.
        again = inspect_inputs(payloads, helpers, configuration, icon, fixture=fixture, version=version,
            build_number=build_number, source_root=source_root, receipts=receipts, bootstrap_receipts=bootstrap_receipts)
        for key in ("architectures", "configurationSha256", "iconSha256", "sourceState"):
            if not package._same(plan[key], again[key]):
                raise ValueError("Input changed during Setup compilation")
        if package._digest(INSTALLER) != plan["templateSha256"] or package._digest(POLICY) != plan["policySha256"] or compiler_snapshot(compiler) != plan["compilerInputs"]:
            raise ValueError("Compiler/template/policy changed during Setup compilation")
        plan.update({"sha256": package._digest(candidate), "sizeBytes": candidate.stat().st_size,
            "outerArchitecture": "x86", "bootstrapExcludedFromUpdateZip": True})
        # A new immutable local candidate never replaces an older Setup or receipt.
        with receipt_path.open("x", encoding="utf-8") as receipt:
            json.dump(plan, receipt, ensure_ascii=False, indent=2)
            receipt.write("\n")
        if output.exists():
            raise ValueError("Candidate output appeared concurrently; it was preserved")
        candidate.rename(output)
    return plan

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for role in ("payload", "updater", "receipt", "bootstrap-receipt"):
        for architecture in ("x86", "x64"):
            parser.add_argument("--" + role + "-" + architecture, type=Path, required=role in ("payload", "updater"))
    parser.add_argument("--configuration", required=True, type=Path)
    parser.add_argument("--icon", required=True, type=Path)
    parser.add_argument("--compiler", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--version")
    parser.add_argument("--build-number", type=int)
    parser.add_argument("--fixture", action="store_true")
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    try:
        result = build_installer({arch: getattr(args, "payload_" + arch) for arch in ("x86", "x64")},
            {arch: getattr(args, "updater_" + arch) for arch in ("x86", "x64")}, args.configuration, args.icon,
            args.output, args.compiler, fixture=args.fixture, version=args.version, build_number=args.build_number,
            source_root=args.source_root, receipts={arch: getattr(args, "receipt_" + arch) for arch in ("x86", "x64")},
            bootstrap_receipts={arch: getattr(args, "bootstrap_receipt_" + arch) for arch in ("x86", "x64")}, build=args.build)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
