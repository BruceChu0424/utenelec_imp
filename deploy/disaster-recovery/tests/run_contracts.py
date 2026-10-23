#!/usr/bin/env python3
"""Run every DR fixture with its real Linux, root, mount, Node, and crypto prerequisites."""
import os
from pathlib import Path
import shutil
import sys
import unittest


def main():
    if os.name != "posix" or os.geteuid() != 0 or not shutil.which("node"):
        raise SystemExit("DR contracts require the disposable Linux root fixture with Node")
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
