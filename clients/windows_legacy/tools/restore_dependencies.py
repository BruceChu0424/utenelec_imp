#!/usr/bin/env python3
"""Check or restore one pinned managed TLS library in this task's private build.

No NuGet/global cache/SDK installation. Default is an offline check. --restore
downloads only the exact locked package if absent, verifies its catalog SHA-512,
and extracts only the net461 DLL and its MIT license after per-file SHA-256 checks.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import tempfile
import urllib.request
import zipfile

HERE = Path(__file__).resolve().parent
CLIENT = HERE.parent
ROOT = CLIENT.parents[1]
BUILD = ROOT / "build/windows-wpf/dependencies"
MAX_PACKAGE = 16 * 1024 * 1024


def reject_links(path: Path) -> None:
    for entry in (path, *path.parents):
        if entry.is_symlink() or (hasattr(entry, "is_junction") and entry.is_junction()):
            raise ValueError("Dependency paths must not contain symbolic links or junctions")


def checked_contents(data: bytes, lock: dict) -> dict[str, bytes]:
    if len(data) > MAX_PACKAGE or base64.b64encode(hashlib.sha512(data).digest()).decode() != lock["packageSha512Base64"]:
        raise ValueError("Pinned NuGet SHA-512 does not match")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        seen = set()
        expanded = 0
        for info in archive.infolist():
            # ZipInfo.filename normalizes backslashes on Windows. Validate the
            # original archive spelling before that host-specific normalization.
            name = info.orig_filename
            path = PurePosixPath(name)
            if (path.is_absolute() or ".." in path.parts or chr(92) in name or ":" in name or any(ord(c) < 32 for c in name)
                    or name.casefold() in seen or info.file_size > 16 * 1024 * 1024):
                raise ValueError("Unsafe or duplicate dependency archive entry")
            seen.add(name.casefold())
            expanded += info.file_size
            if expanded > 64 * 1024 * 1024:
                raise ValueError("Dependency archive expands beyond its bound")
        result = {}
        for name, expected in lock["files"].items():
            if name != "LICENSE.md" and not name.startswith("lib/net461/"):
                raise ValueError("Only the approved net461 assembly and license may be extracted")
            if ".." in PurePosixPath(name).parts or PurePosixPath(name).is_absolute():
                raise ValueError("Invalid dependency output path")
            content = archive.read(name)
            if hashlib.sha256(content).hexdigest() != expected:
                raise ValueError("Pinned dependency file SHA-256 does not match")
            result[name] = content
        return result


def atomic_write(path: Path, content: bytes) -> None:
    reject_links(path)
    if not path.resolve().is_relative_to(BUILD.resolve()):
        raise ValueError("Dependency output leaves the private build directory")
    path.parent.mkdir(parents=True, exist_ok=True)
    reject_links(path)
    handle, temporary = tempfile.mkstemp(prefix=".dependency-", dir=path.parent)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(restore: bool) -> dict:
    lock = json.loads((CLIENT / "dependencies.lock.json").read_text(encoding="utf-8"))
    if (lock["schemaVersion"] != 1 or lock["package"] != "BouncyCastle.Cryptography"
            or lock["version"] != "2.7.0" or lock["targetFramework"] != "net461"):
        raise ValueError("Unexpected managed TLS dependency lock")
    archive_path = BUILD / "BouncyCastle.Cryptography.2.7.0.nupkg"
    destination = BUILD / "BouncyCastle.Cryptography.2.7.0"
    reject_links(archive_path)
    if not archive_path.exists():
        if not restore:
            raise ValueError("Pinned dependency is absent; run this tool with --restore")
        expected_url = "https://api.nuget.org/v3-flatcontainer/bouncycastle.cryptography/2.7.0/bouncycastle.cryptography.2.7.0.nupkg"
        if lock["url"] != expected_url:
            raise ValueError("Dependency URL is outside the approved package")
        with urllib.request.urlopen(expected_url, timeout=30) as response:
            if response.url != expected_url:
                raise ValueError("Dependency download redirected outside its exact URL")
            data = response.read(MAX_PACKAGE + 1)
        contents = checked_contents(data, lock)
        atomic_write(archive_path, data)
    else:
        if not archive_path.is_file() or archive_path.stat().st_size > MAX_PACKAGE:
            raise ValueError("Invalid private dependency archive")
        contents = checked_contents(archive_path.read_bytes(), lock)
    for name, content in contents.items():
        target = destination.joinpath(*PurePosixPath(name).parts)
        reject_links(target)
        if target.exists() and hashlib.sha256(target.read_bytes()).digest() == hashlib.sha256(content).digest():
            continue
        if not restore:
            raise ValueError("Dependency file is missing or changed; explicit private restore required")
        atomic_write(target, content)
    return {"package": lock["package"], "version": lock["version"], "framework": "net461",
            "sha512Verified": True, "fileCount": len(contents), "globalChanges": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--restore", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.restore), ensure_ascii=False))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
