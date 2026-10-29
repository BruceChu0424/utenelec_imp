#!/usr/bin/env python3
"""Explicit ISCC compile of an inert, non-installable x86/x64 Setup fixture."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import tempfile
import uuid
import build_wpf_installer as builder
from verify_wpf_update_pipeline import run

def verify(harnesses: dict[str, Path], helpers: dict[str, Path], compiler: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="uten-wpf-producer-link-") as temporary_x86, \
         tempfile.TemporaryDirectory(prefix="uten-wpf-producer-link-") as temporary_x64:
        roots = {"x86": Path(temporary_x86).resolve(), "x64": Path(temporary_x64).resolve()}
        for architecture, root in roots.items():
            proof = json.loads(run([str(harnesses[architecture].resolve()), "emit", str(root)]))
            if proof != {"architecture": architecture, "fixtureOnly": True}:
                raise ValueError("Installer fixture harness architecture differs")
        output = builder.ROOT / "build/windows-wpf/installer-execute/setup" / ("UtenWin7WpfFixture-" + uuid.uuid4().hex + ".exe")
        payloads = {arch: root / "payload" for arch, root in roots.items()}
        result = builder.build_installer(payloads, helpers, payloads["x86"] / "uten.client.json",
            builder.ROOT / "windows/runner/resources/app_icon.ico", output, compiler.resolve(),
            fixture=True, version="2.5.35", build_number=2535, build=True)
        if not result["fixtureOnly"] or result["setupExecuted"] or result["outerArchitecture"] != "x86":
            raise ValueError("Compiler fixture did not preserve the non-installable boundary")
        return result

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for role in ("harness", "updater"):
        for arch in ("x86", "x64"):
            parser.add_argument("--" + role + "-" + arch, required=True, type=Path)
    parser.add_argument("--compiler", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = verify({arch: getattr(args, "harness_" + arch) for arch in ("x86", "x64")},
            {arch: getattr(args, "updater_" + arch) for arch in ("x86", "x64")}, args.compiler)
    except (ValueError, OSError, KeyError) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
