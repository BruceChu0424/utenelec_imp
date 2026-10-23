#!/usr/bin/env python3
"""Run every DR fixture with its real Linux, root, mount, Node, and crypto prerequisites."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def probe_mount():
    """Capture the actual kernel/LSM decision, without confusing it with a missing capability."""
    profile = Path("/proc/self/attr/current")
    capability = next((line for line in Path("/proc/self/status").read_text().splitlines()
                       if line.startswith("CapEff:")), "unavailable")
    with tempfile.TemporaryDirectory(prefix="uten-dr-mount-probe-") as directory:
        result = subprocess.run(["mount", "-t", "tmpfs", "-o", "size=64k,mode=0550", "tmpfs", directory],
                                capture_output=True, text=True)
        if result.returncode == 0:
            subprocess.run(["umount", directory], check=True, capture_output=True)
        print(json.dumps({"mountProbe": {"returnCode": result.returncode, "stderr": result.stderr.strip(),
                          "capabilities": capability, "lsmProfile": profile.read_text().strip() if profile.exists() else "unavailable"}}))
    return 0


def main():
    if os.name != "posix" or os.geteuid() != 0 or not shutil.which("node"):
        raise SystemExit("DR contracts require the disposable Linux root fixture with Node")
    if sys.argv[1:] == ["--probe-mount"]:
        return probe_mount()
    if sys.argv[1:]:
        raise SystemExit("Unsupported DR fixture arguments")
    os.environ["UTEN_REQUIRE_DR_CONTRACTS"] = "true"
    root = Path(__file__).resolve().parents[3]
    succeeded = True
    for directory in (root / "deploy/disaster-recovery", root / "deploy/dr-backup"):
        # These independent script directories are not Python packages.
        sys.path.insert(0, str(directory))
        suite = unittest.TestLoader().discover(str(directory), pattern="test*.py", top_level_dir=str(directory))
        if not suite.countTestCases():
            raise SystemExit(f"No tests discovered in {directory.name}")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        if result.skipped:
            print(f"Required {directory.name} fixtures skipped: {len(result.skipped)}", file=sys.stderr)
        succeeded = result.wasSuccessful() and not result.skipped and succeeded
    return 0 if succeeded else 1


if __name__ == "__main__":
    sys.exit(main())
