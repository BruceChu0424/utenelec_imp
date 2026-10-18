#!/usr/bin/env python3
"""Restore a stale tunnel only. Never retry business requests or change routes."""
from __future__ import annotations
import subprocess
import sys
import time


def healthy(output: str, now: int) -> bool:
    lines = [line.split() for line in output.splitlines() if line.strip()]
    if len(lines) != 1 or len(lines[0]) != 2:
        return False
    try:
        timestamp = int(lines[0][1])
    except ValueError:
        return False
    # Keepalive causes rekey/handshake around every two minutes. Allow jitter.
    return timestamp > 0 and -30 <= now - timestamp <= 240


def main() -> int:
    try:
        result = subprocess.run(["/usr/bin/wg", "show", "wg-uten", "latest-handshakes"],
                                capture_output=True, text=True, timeout=10)
        if result.returncode == 0 and healthy(result.stdout, int(time.time())):
            return 0
        # Restart only this dedicated interface. Watchdog interval bounds retries.
        # Starting an inactive interface also handles a previous transient startup failure.
        result = subprocess.run(["/usr/bin/systemctl", "restart", "wg-quick@wg-uten.service"],
                                capture_output=True, timeout=30)
        print("Remote tunnel recovery requested; business requests were not replayed.")
        return 0 if result.returncode == 0 else 1
    except (OSError, subprocess.SubprocessError):
        print("Remote tunnel recovery failed; inspect the dedicated unit locally.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
