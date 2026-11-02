"""Reject Android compiler diagnostics even when Gradle's fallback exits zero."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


DIAGNOSTIC = re.compile(
    r"^\s*(?:e:|w:|\[WARNING\]|\[ERROR\])(?:\s|$)"
    r"|(?:^|\s)(?:warning|error):"
    r"|^\s*Deprecated Gradle features were used"
    r"|Daemon compilation failed:", re.IGNORECASE)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def inspect(path: Path) -> list[dict]:
    if path.stat().st_size == 0:
        raise ValueError("Android build log is empty")
    findings = []
    with path.open(encoding="utf-8", errors="replace") as stream:
        for number, line in enumerate(stream, 1):
            plain = ANSI_ESCAPE.sub("", line)
            if DIAGNOSTIC.search(plain):
                findings.append({"line": number, "text": plain.strip()[:600]})
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    try:
        findings = inspect(args.log)
    except (OSError, ValueError):
        print("::error::Android build log is missing, empty or unreadable.")
        return 2
    print(json.dumps({"diagnostics": len(findings), "firstFindings": findings[:10]}))
    if findings:
        print("::error::Android build emitted compiler errors or warnings; a zero Gradle exit code is insufficient.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
