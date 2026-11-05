#!/usr/bin/env python3
"""Serialize source checksums with an explicit algorithm, without changing recorded facts."""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import re

ALGORITHMS = {
    "sourceSha256": "sha256",
    "parallelWorkingTreeSha256": "sha256",
    "all132RawBlobIds": "git-blob-sha1",
}


def source_records(mapping: dict, algorithm: str) -> tuple[dict, int]:
    """Keep path lookup stable while separating filenames from checksum values."""
    length = {"sha256": 64, "git-blob-sha1": 40}[algorithm]
    result = {}
    converted = 0
    for path, value in mapping.items():
        if not isinstance(path, str):
            raise ValueError("source checksum keys must be repository-relative file paths")
        relative = PurePosixPath(path)
        if "/" not in path or relative.is_absolute() or PureWindowsPath(path).drive or ".." in relative.parts:
            raise ValueError("source checksum keys must be repository-relative file paths")
        if isinstance(value, dict):
            if set(value) != {"algorithm", "digest"} or value["algorithm"] != algorithm:
                raise ValueError("source checksum algorithm differs from its declared field")
            digest = value["digest"]
        else:
            digest = value
            converted += 1
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{" + str(length) + r"}", digest):
            raise ValueError("source checksum has an invalid algorithm or digest")
        result[path] = {"algorithm": algorithm, "digest": digest}
    return result, converted


def encode(document: dict) -> tuple[dict, int]:
    converted = 0

    def visit(value):
        nonlocal converted
        if isinstance(value, list):
            return [visit(item) for item in value]
        if not isinstance(value, dict):
            return value
        result = {}
        for field, item in value.items():
            if field in ALGORITHMS and isinstance(item, dict):
                result[field], count = source_records(item, ALGORITHMS[field])
                converted += count
            else:
                result[field] = visit(item)
        return result

    result = visit(document)
    if converted:
        result["sourceFingerprintEncoding"] = "typed-checksums-v1"
    return result, converted


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("files", type=Path, nargs="+")
    args = parser.parse_args()
    pending = False
    for path in args.files:
        document = json.loads(path.read_text(encoding="utf-8-sig"))
        result, count = encode(document)
        if count and args.write:
            path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
        pending = pending or count > 0
        print(json.dumps({"file": path.as_posix(), "sourceChecksums": count, "written": bool(count and args.write)}))
    return 1 if pending and not args.write else 0


if __name__ == "__main__":
    raise SystemExit(main())
