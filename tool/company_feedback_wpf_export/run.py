"""Rebuild/run native output contracts in task-owned Debug outputs; never packages or installs."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def capture(root: Path, *args: str) -> str:
    return subprocess.check_output(args, cwd=root, text=True, encoding="utf-8").strip()


def main() -> int:
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--run-tag", required=True)
    parser.add_argument("--msbuild", type=Path)
    parser.add_argument("--restore-pinned-dependency", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,30}", args.run_tag):
        parser.error("run-tag must be a short safe task identifier")
    dirty = capture(root, "git", "diff", "HEAD", "--name-only")
    if dirty:
        parser.error("commit the reviewed source before acceptance; preserve all existing changes")
    output = root / "evidence" / ("wpf-export-" + args.run_tag)
    output.mkdir(parents=True, exist_ok=False)
    msbuild = args.msbuild
    if msbuild is None:
        locator = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
        found = capture(root, str(locator), "-latest", "-products", "*", "-requires", "Microsoft.Component.MSBuild", "-find", "MSBuild/**/Bin/MSBuild.exe")
        msbuild = Path(found.splitlines()[0])
    msbuild = msbuild.resolve(strict=True)
    if msbuild.name.lower() != "msbuild.exe":
        parser.error("msbuild must identify an installed MSBuild.exe")
    report: dict = {
        "sourceHead": capture(root, "git", "rev-parse", "HEAD"),
        "sourceTree": capture(root, "git", "rev-parse", "HEAD^{tree}"),
        "root": str(root), "msbuild": str(msbuild), "results": [],
        "classification": "host Windows WPF/CurrentUser DPAPI/controlled HTTP codec; not PostgreSQL or Win7 target acceptance",
        "formalPackageOrInstall": False,
    }

    def run(name: str, argv: list[str], env: dict | None = None) -> int:
        started = time.monotonic()
        with (output / (name + ".log")).open("w", encoding="utf-8") as log:
            result = subprocess.run(argv, cwd=root, stdout=log, stderr=subprocess.STDOUT, env=env, check=False)
        report["results"].append({"name": name, "exitCode": result.returncode, "elapsedSeconds": round(time.monotonic() - started, 3)})
        (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        return result.returncode

    dependency = [sys.executable, "clients/windows_legacy/tools/restore_dependencies.py", "--restore" if args.restore_pinned_dependency else "--check"]
    if run("pinned-dependency", dependency) != 0:
        return 1
    failed = False
    for arch in ("x86", "x64"):
        build = root / "build/windows-wpf" / ("feedback-export-" + args.run_tag + "-" + arch)
        if build.exists():
            raise RuntimeError("refusing reused build output: " + str(build))
        args_build = [str(msbuild), "clients/windows_legacy/Uten.Legacy.Tests/Uten.Legacy.Tests.csproj", "/nologo", "/verbosity:minimal", "/t:Build", "/warnAsError", "/p:Configuration=Debug", "/p:Platform=" + arch, "/p:PlatformTarget=" + arch, "/p:UtenDistributionProfile=Unreviewed", "/p:UtenBuildScope=" + args.run_tag, "/p:OutputPath=" + str(build) + os.sep, "/p:Restore=false"]
        if run("build-" + arch, args_build) != 0:
            failed = True
            continue
        env = dict(os.environ)
        env["UTEN_EXPORT_BUDGET_EVIDENCE"] = str(output / ("original-" + arch))
        executable = build / "Uten.Legacy.Tests.exe"
        failed |= run("large-" + arch, [str(executable), "--large-unit-export-contracts"], env) != 0
        failed |= run("full-" + arch, [str(executable)], env) != 0
    report["sourceHeadAfter"] = capture(root, "git", "rev-parse", "HEAD")
    report["canonicalDiffAfter"] = capture(root, "git", "diff", "HEAD", "--name-only")
    report["passed"] = not failed and not report["canonicalDiffAfter"] and report["sourceHeadAfter"] == report["sourceHead"]
    report["evidenceHashes"] = [{"path": str(path.relative_to(output)), "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in sorted(output.rglob("*")) if path.is_file() and path.name != "result.json"]
    (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"passed": report["passed"], "output": str(output), "sourceHead": report["sourceHead"]}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
