#!/usr/bin/env python3
"""Host-side helper: replace only inet/uten_remote in a single nft transaction."""
from __future__ import annotations
import os
from pathlib import Path
import stat
import subprocess
import sys

CONFIG = Path("/etc/uten-remote/firewall.nft")
NFT = "/usr/sbin/nft"


def transaction(content: str, exists: bool) -> str:
    if content.count("table inet uten_remote {") != 1:
        raise ValueError("unexpected firewall table")
    if any(line.strip().startswith(("include ", "delete ", "flush ", "destroy ", "add table")) for line in content.splitlines()):
        raise ValueError("unsupported firewall statement")
    return ("delete table inet uten_remote\n" if exists else "") + content


def apply(path: Path = CONFIG, runner=subprocess.run) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError("configuration must be root-owned and not writable by group/others")
    content = path.read_text(encoding="utf-8")
    current = runner([NFT, "list", "table", "inet", "uten_remote"], capture_output=True, timeout=10)
    if current.returncode not in (0, 1):
        raise ValueError("cannot inspect firewall")
    # A missing table returns 1; check/apply still fail closed on privileges or syntax.
    batch = transaction(content, current.returncode == 0)
    checked = runner([NFT, "--check", "-f", "-"], input=batch, text=True, capture_output=True, timeout=10)
    if checked.returncode:
        raise ValueError("firewall validation failed")
    applied = runner([NFT, "-f", "-"], input=batch, text=True, capture_output=True, timeout=10)
    if applied.returncode:
        raise ValueError("firewall transaction failed")


def main() -> int:
    try:
        if os.geteuid() != 0:
            raise ValueError("requires root")
        apply()
    except (OSError, ValueError, subprocess.SubprocessError):
        print("Dedicated remote firewall was not applied; existing rules were preserved.", file=sys.stderr)
        return 1
    print("Dedicated remote firewall applied atomically; other tables preserved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
