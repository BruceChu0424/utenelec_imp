#!/usr/bin/env python3
"""Bind an offline import to the exact reviewed Flyway source inventory.

Flyway's checksum is CRC32 over UTF-8 lines without line terminators (and
without a first-line BOM). The integration test compares this implementation
with Flyway's own ChecksumCalculator across the full formal resource set.
This is an equality check, not a replacement for approved source provenance.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import zlib


def flyway_checksum(content: bytes) -> int:
    text = content.decode("utf-8-sig")
    checksum = 0
    for line in re.split(r"\r\n|\n|\r", text):
        checksum = zlib.crc32(line.encode("utf-8"), checksum)
    return checksum if checksum < 2**31 else checksum - 2**32


def verify(root: pathlib.Path, manifest: pathlib.Path) -> tuple[int, int, str]:
    root = root.resolve(strict=True)
    legacy = root / "server/legacy_migration"
    migrations = root / "server/src/main/resources/db/migration"
    controlled = [legacy / "migrate.sh", legacy / "export_legacy.ps1",
                  legacy / "verify_candidate.py", legacy / "reconcile_modules.py",
                  legacy / "compose_bootstrap.py", legacy / "mapping-version.txt"]
    controlled.append(legacy / "prepare_source_authority.py")
    controlled.append(legacy / "prepare_hr_keys.py")
    controlled.append(legacy / "cleanup_hr_keep_admin.sql")
    controlled.extend(sorted(legacy.glob("migrate_*.sql")))
    records = []
    versions: set[int] = set()
    for path in sorted(migrations.iterdir()):
        if path.suffix != ".sql":
            continue
        match = re.fullmatch(r"V([0-9]+)__[A-Za-z0-9_]+\.sql", path.name)
        if match is None or path.is_symlink() or not path.is_file():
            raise ValueError("invalid or non-regular migration resource")
        version = int(match[1])
        if version in versions:
            raise ValueError("duplicate Flyway source version")
        versions.add(version)
        records.append((version, path.name, flyway_checksum(path.read_bytes())))
        controlled.append(path)
    if not records:
        raise ValueError("reviewed Flyway source inventory is empty")
    records.sort()
    relative = [path.relative_to(root).as_posix() for path in controlled]
    for path in controlled:
        if not path.is_file() or path.is_symlink():
            raise ValueError("candidate contains a missing or non-regular file")
    # A manifest cannot authorize arbitrary local/untracked importer or SQL bytes.
    subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", "--", *relative],
                   check=True, stdout=subprocess.DEVNULL)
    dirty = subprocess.check_output([
        "git", "-C", str(root), "status", "--porcelain=v1", "--untracked-files=all", "--",
        *relative, "server/src/main/resources/db/migration",
    ], text=True)
    if dirty.strip():
        raise ValueError("reviewed importer/Flyway candidate has uncommitted bytes")
    if not manifest.is_file() or manifest.is_symlink():
        raise ValueError("Flyway manifest must be a regular file")
    expected = ["# uten-imp-flyway-checksums-v1", *[
        f"{version}\t{name}\t{checksum}" for version, name, checksum in records
    ]]
    if manifest.read_text(encoding="utf-8").splitlines() != expected:
        raise ValueError("Flyway manifest is not the exact reviewed source inventory")
    mapping = (legacy / "mapping-version.txt").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"bootstrap-v[1-9][0-9]*", mapping):
        raise ValueError("invalid independent import mapping version")
    return len(records), records[-1][0], mapping


if __name__ == "__main__":
    try:
        print("|".join(map(str, verify(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])))))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Candidate rejected: {error}", file=sys.stderr)
        sys.exit(66)
