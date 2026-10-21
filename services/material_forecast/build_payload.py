"""Entry point for the one Git-bound, hash-locked release payload builder.

requirements.txt is the sole dependency authority. Platform locks are checked
compatibility exports, never inputs to a second downloader. The outer release
signs this exact payload. There is no unhashed refresh mode.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import runpy
import shutil
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[1]
TARGETS = ("linux-x86_64", "windows-x86_64")
_spec = importlib.util.spec_from_file_location(
    "material_forecast_release", REPOSITORY / "deploy/release/material_forecast_payload.py")
strict = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(strict)


def validate_requirement_versions(root: Path, *, refresh_lock: bool = False) -> None:
    strict.require(not refresh_lock, "unhashed lock refresh is forbidden; review requirements.txt first")
    strict.validate_derived(root)


def identity(repo: Path, version: str | None, commit: str | None) -> tuple[str, str]:
    commit = commit or strict._git(repo, "rev-parse", "HEAD").decode().strip()
    if version is None:
        import re
        text = strict.git_source(repo, commit, "pubspec.yaml").decode("utf-8")
        found = re.findall(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+[1-9][0-9]*\s*$", text, re.MULTILINE)
        strict.require(len(found) == 1, "invalid checkout application version")
        version = "v" + found[0]
    strict.validate_identity(version, commit)
    return version, commit


def build(output: Path, platform: str, refresh_lock: bool = False, wheelhouse_source: Path | None = None,
          *, repo: Path = REPOSITORY, version: str | None = None, commit: str | None = None,
          development: bool = False) -> dict:
    strict.require(not refresh_lock, "unhashed lock refresh is forbidden")
    repo = repo.resolve()
    version, commit = identity(repo, version, commit)
    before = strict.source_identity(repo, version, commit, platform, development)
    validate_requirement_versions(repo / "services/material_forecast")
    output = output.absolute()
    strict.no_symlink_ancestors(output)
    strict.require(not output.exists() and not output.is_relative_to(repo / "services"),
                   "output must be a new runtime directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Core builds stage under checkout/build. Export those same verified bytes
    # to RUNNER_TEMP or the developer cache, with exactly one wheel download.
    stage = repo / "build" / ("material-forecast-" + uuid.uuid4().hex)
    strict.build(repo, stage, version, commit, wheelhouse_source, platform, development)
    try:
        with tempfile.TemporaryDirectory(prefix=".material-forecast-export-", dir=output.parent) as temporary:
            copied = Path(temporary) / "payload"
            shutil.copytree(stage, copied, symlinks=False)
            result = strict.verify(copied, version, commit, platform)
            strict.require(strict.source_identity(repo, version, commit, platform, development) == before,
                           "runtime source changed during export")
            strict.require(not output.exists(), "runtime output appeared during export")
            copied.rename(output)
    finally:
        strict.no_symlink_ancestors(stage)
        shutil.rmtree(stage)
    return {**result, "payload": str(output.resolve())}


def development_payload(cache: Path, platform: str, wheelhouse_source: Path | None = None,
                        *, repo: Path = REPOSITORY) -> dict:
    repo = repo.resolve()
    version, commit = identity(repo, None, None)
    strict.require_build_host(platform)
    source_digest = strict.source_identity(repo, version, commit, platform, True)
    validate_requirement_versions(repo / "services/material_forecast")
    cache = cache.absolute()
    strict.no_symlink_ancestors(cache)
    strict.require(not cache.is_relative_to(repo), "development payload cache must be outside the checkout")
    cache.mkdir(parents=True, exist_ok=True)
    directory = cache / source_digest
    guard = runpy.run_path(str(repo / "services/material_forecast/prepare_runtime.py"))["install_lock"]
    with guard(cache / (source_digest + ".lock")):
        if not directory.exists():
            build(directory, platform, wheelhouse_source=wheelhouse_source, repo=repo,
                  version=version, commit=commit, development=True)
        # A directory/manifest existing is never sufficient, even on a cache hit.
        result = strict.verify(directory, version, commit, platform)
        strict.verify_checkout_sources(directory, repo, commit)
        strict.require(strict.source_identity(repo, version, commit, platform, True) == source_digest,
                       "runtime source changed during cache verification")
    return {**result, "payload": str(directory.resolve()), "sourceIdentity": source_digest}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--platform", choices=TARGETS)
    parser.add_argument("--version")
    parser.add_argument("--commit")
    parser.add_argument("--development-cache", action="store_true")
    parser.add_argument("--wheelhouse-source", type=Path)
    args = parser.parse_args()
    try:
        if args.development_cache:
            platform = args.platform or ("windows-x86_64" if os.name == "nt" else "linux-x86_64")
            base = Path(os.environ["LOCALAPPDATA"]) if os.name == "nt" else Path.home() / ".cache"
            result = development_payload(base / "UtenIMP/material-forecast/payloads", platform, args.wheelhouse_source)
        else:
            if args.output is None or args.platform is None:
                parser.error("--output and --platform are required for release builds")
            result = build(args.output, args.platform, wheelhouse_source=args.wheelhouse_source,
                           version=args.version, commit=args.commit)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, "material-forecast payload rejected: " + str(error) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
