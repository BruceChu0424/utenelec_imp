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


# BEGIN GENERATED FLYWAY VERSION CONTRACT
# Source: deploy/contracts/flyway_version_contract.py
# SHA-256: 93a6b6905c618a662c956dfddd1213731f939f954dbde6ed42b03db294e58fde
_FLYWAY_SEMANTIC_RE = __import__("re").compile(r"[0-9]+(?:[._][0-9]+)*")
_FLYWAY_SCRIPT_RE = __import__("re").compile(
    r"V(?P<version>[0-9]+(?:[._][0-9]+)*)__"
    r"(?P<description>[^\x00-\x1f\x7f-\x9f/\\]{1,200})\.sql"
)


def _flyway_semantic_key(value: object) -> tuple[int, ...]:
    if type(value) is not str or len(value) > 50 or not _FLYWAY_SEMANTIC_RE.fullmatch(value):
        raise ValueError("Flyway version must contain bounded ASCII integer components")
    parts = tuple(int(part) for part in value.replace("_", ".").split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def _flyway_version_key(value: object) -> tuple[int, ...]:
    parts = _flyway_semantic_key(value)
    if parts <= (0,) or value != ".".join(str(part) for part in parts):
        raise ValueError("Flyway version is not a canonical positive dotted identity")
    return parts


def _flyway_script_parts(filename: object) -> tuple[tuple[int, ...], str, str]:
    if type(filename) is not str or len(filename.encode("utf-8")) > 255:
        raise ValueError("Flyway script must be a bounded exact basename")
    match = _FLYWAY_SCRIPT_RE.fullmatch(filename)
    if match is None:
        raise ValueError("Flyway script basename is not canonical")
    token = match.group("version")
    if "." in token and "_" in token:
        raise ValueError("Flyway script version mixes component separators")
    key = _flyway_version_key(token.replace("_", "."))
    raw_description = match.group("description")
    return key, raw_description, raw_description.replace("_", " ")


def _flyway_head_identity(version: object) -> int | str:
    key = _flyway_version_key(version)
    return key[0] if len(key) == 1 else str(version)


def _flyway_head_key(value: object) -> tuple[int, ...]:
    if type(value) is int and value > 0 and len(str(value)) <= 50:
        return (value,)
    if type(value) is str and "." in value:
        return _flyway_version_key(value)
    raise ValueError("Flyway database head must be an integer or canonical dotted string")

_FLYWAY_CONTRACT_ERROR = ValueError
# END GENERATED FLYWAY VERSION CONTRACT

def flyway_checksum(content: bytes) -> int:
    text = content.decode("utf-8-sig")
    checksum = 0
    for line in re.split(r"\r\n|\n|\r", text):
        checksum = zlib.crc32(line.encode("utf-8"), checksum)
    return checksum if checksum < 2**31 else checksum - 2**32


def verify(root: pathlib.Path, manifest: pathlib.Path) -> tuple[int, int | str, str]:
    root = root.resolve(strict=True)
    legacy = root / "server/legacy_migration"
    migrations = root / "server/src/main/resources/db/migration"
    controlled = [legacy / "migrate.sh", legacy / "export_legacy.ps1",
                  legacy / "verify_candidate.py", legacy / "reconcile_modules.py",
                  legacy / "compose_bootstrap.py", legacy / "mapping-version.txt"]
    controlled.append(legacy / "prepare_source_authority.py")
    controlled.append(legacy / "prepare_hr_keys.py")
    controlled.append(legacy / "cleanup_hr_keep_admin.sql")
    # ADR-145: the reviewed warehouse crosswalk decides every warehouse identity.
    controlled.append(legacy / "warehouse_crosswalk.csv")
    controlled.extend(sorted(legacy.glob("migrate_*.sql")))
    records = []
    versions: set[tuple[int, ...]] = set()
    for path in sorted(migrations.iterdir()):
        if path.suffix != ".sql":
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError("invalid or non-regular migration resource")
        key, _, _ = _flyway_script_parts(path.name)
        version = ".".join(map(str, key))
        if key in versions:
            raise ValueError("duplicate Flyway source version")
        versions.add(key)
        records.append((key, version, path.name, flyway_checksum(path.read_bytes())))
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
        f"{version}\t{name}\t{checksum}" for _, version, name, checksum in records
    ]]
    if manifest.read_text(encoding="utf-8").splitlines() != expected:
        raise ValueError("Flyway manifest is not the exact reviewed source inventory")
    mapping = (legacy / "mapping-version.txt").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"bootstrap-v[1-9][0-9]*", mapping):
        raise ValueError("invalid independent import mapping version")
    return len(records), _flyway_head_identity(records[-1][1]), mapping


if __name__ == "__main__":
    try:
        print("|".join(map(str, verify(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])))))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Candidate rejected: {error}", file=sys.stderr)
        sys.exit(66)
