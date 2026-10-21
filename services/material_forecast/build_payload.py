"""Build one platform's offline, fully hash-locked signed-release payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import runpy
import shutil
import subprocess
import sys
import zipfile
import uuid
from email.parser import BytesParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TARGETS = ("linux-x86_64", "windows-x86_64")


def pinned_versions(path: Path) -> dict[str, str]:
    versions = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+!-]+)(?: --hash=sha256:[0-9a-f]{64})?", line)
        if match is None:
            raise ValueError("runtime inputs must contain exact package pins only")
        name = re.sub(r"[-_.]+", "-", match[1]).lower()
        if name in versions:
            raise ValueError("duplicate runtime package pin")
        versions[name] = match[2]
    return versions


def validate_requirement_versions(root: Path, *, refresh_lock: bool = False) -> None:
    direct = pinned_versions(root / "requirements.txt")
    closure = pinned_versions(root / "requirements.runtime.txt")
    if not direct or any(closure.get(name) != version for name, version in direct.items()):
        raise ValueError("direct requirements differ from the reviewed runtime closure")
    if not refresh_lock:
        for target in TARGETS:
            if pinned_versions(root / "runtime-locks" / (target + ".lock")) != closure:
                raise ValueError("complete runtime closure and both platform locks must be updated together")


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def wheel_lock(directory: Path) -> str:
    entries = []
    for path in sorted(directory.glob("*.whl")):
        with zipfile.ZipFile(path) as archive:
            metadata = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
            if len(metadata) != 1:
                raise ValueError("invalid wheel metadata")
            item = BytesParser().parsebytes(archive.read(metadata[0]))
        name = re.sub(r"[-_.]+", "-", item["Name"]).lower()
        entries.append((name, f"{name}=={item['Version']} --hash=sha256:{sha(path)}"))
    if len({name for name, _ in entries}) != len(entries) or not entries:
        raise ValueError("duplicate or empty wheel set")
    return "\n".join(line for _, line in sorted(entries)) + "\n"


def build(output: Path, platform: str, refresh_lock: bool = False, wheelhouse_source: Path | None = None) -> dict:
    validate_requirement_versions(ROOT, refresh_lock=refresh_lock)
    output = output.absolute()
    if output.exists() or output.is_symlink() or platform not in TARGETS:
        raise ValueError("choose a new output directory and a supported platform")
    lock_path = ROOT / "runtime-locks" / (platform + ".lock")
    if not refresh_lock and not lock_path.is_file():
        raise ValueError("reviewed platform lock is missing; refresh it explicitly before release")
    output.mkdir(parents=True)
    wheels = output / "wheelhouse"
    wheels.mkdir()
    command = [sys.executable, "-m", "pip", "download", "--disable-pip-version-check", "--no-deps",
               "--only-binary=:all:", "--python-version", "3.12", "--implementation", "cp",
               "--abi", "cp312", "--abi", "abi3", "--abi", "none", "--dest", str(wheels)]
    platforms = ["win_amd64"] if platform == "windows-x86_64" else [
        *[f"manylinux_2_{minor}_x86_64" for minor in range(39, 16, -1)], "manylinux2014_x86_64", "linux_x86_64"]
    for tag in platforms:
        command += ["--platform", tag]
    command += ["--index-url", "https://pypi.org/simple", "-r",
                str(ROOT / "requirements.runtime.txt" if refresh_lock else lock_path)]
    if not refresh_lock:
        command.append("--require-hashes")
    # Download-only: no package metadata build, sdist execution or host installation.
    if wheelhouse_source is None:
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("PIP_") and key not in {"PYTHONPATH", "PYTHONHOME"}}
        environment.update(PIP_CONFIG_FILE=os.devnull, PIP_NO_INPUT="1")
        subprocess.run(command, check=True, env=environment)
    else:
        for wheel in wheelhouse_source.glob("*.whl"):
            if wheel.is_symlink():
                raise ValueError("wheel links are forbidden")
            shutil.copyfile(wheel, wheels / wheel.name)
    generated = wheel_lock(wheels)
    if refresh_lock:
        lock_path.parent.mkdir(exist_ok=True)
        lock_path.write_text(generated, encoding="utf-8", newline="\n")
    if generated != lock_path.read_text(encoding="utf-8"):
        raise ValueError("wheel inventory differs from the reviewed exact platform lock")
    (output / "requirements.lock").write_text(generated, encoding="utf-8", newline="\n")
    for name in ("worker.py", "prepare_runtime.py", "prepare_runtime.ps1"):
        shutil.copyfile(ROOT / name, output / name)
    shutil.copytree(ROOT / "forecast_worker", output / "forecast_worker", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    catalog = ROOT.parents[1] / "server/src/main/resources/pricing/material-benchmarks.json"
    shutil.copyfile(catalog, output / "material-benchmarks.json")
    # Preserve upstream metadata/licenses within each wheel; all installed artifacts are inventoried.
    files = {path.relative_to(output).as_posix(): {"sha256": sha(path), "bytes": path.stat().st_size}
             for path in sorted(output.rglob("*")) if path.is_file()}
    version = re.search(r'__version__ = "([^"]+)"', (ROOT / "forecast_worker/__init__.py").read_text()).group(1)
    manifest = {"schemaVersion": 1, "platform": platform, "pythonVersion": "3.12", "workerVersion": version,
                "lockDigest": sha(output / "requirements.lock"), "files": files}
    (output / "runtime-manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return {"payload": str(output.resolve()), "platform": platform, "wheelCount": len(list(wheels.glob("*.whl"))), "lockDigest": manifest["lockDigest"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--platform", choices=TARGETS)
    parser.add_argument("--development-cache", action="store_true", help="developer entry point: prepare a source-addressed private payload")
    parser.add_argument("--refresh-lock", action="store_true", help="maintainer-only explicit lock generation for review")
    parser.add_argument("--wheelhouse-source", type=Path, help="reuse a local wheelhouse only when it matches the reviewed platform lock")
    args = parser.parse_args()
    if args.development_cache:
        if os.name != "nt" or sys.version_info[:2] != (3, 12):
            raise ValueError("Windows developer bootstrap requires Python 3.12")
        files = [ROOT / name for name in ("worker.py", "prepare_runtime.py", "prepare_runtime.ps1", "build_payload.py")]
        files += sorted((ROOT / "forecast_worker").glob("*.py"))
        files += [ROOT / "runtime-locks/windows-x86_64.lock", ROOT.parents[1] / "server/src/main/resources/pricing/material-benchmarks.json"]
        source_digest = hashlib.sha256("".join(sha(path) for path in files).encode()).hexdigest()[:24]
        directory = Path(os.environ["LOCALAPPDATA"]) / "UtenIMP/material-forecast/payloads" / source_digest
        directory.parent.mkdir(parents=True, exist_ok=True)
        guard = runpy.run_path(str(ROOT / "prepare_runtime.py"))["install_lock"]
        with guard(directory.parent / (source_digest + ".lock")):
            if directory.exists():
                if not (directory / "runtime-manifest.json").is_file():
                    raise ValueError("incomplete developer payload; retain it for diagnosis")
            else:
                staged = directory.with_name("." + source_digest + ".partial-" + uuid.uuid4().hex)
                build(staged, "windows-x86_64")
                os.rename(staged, directory)
            print(json.dumps({"payload": str(directory.resolve())}))
        return 0
    if args.output is None or args.platform is None:
        parser.error("--output and --platform are required for release builds")
    print(json.dumps(build(args.output, args.platform, args.refresh_lock, args.wheelhouse_source)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
