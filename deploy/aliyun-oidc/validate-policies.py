#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from policy_lib import PolicyError, validate_bundle, workflow_gaps


def main() -> int:
    parser = argparse.ArgumentParser(description="Strictly validate Uten IMP Aliyun policy bundle")
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--workflow", type=Path)
    parser.add_argument("--require-commissionable", action="store_true")
    args = parser.parse_args()
    try:
        metadata = validate_bundle(args.bundle, Path(__file__).resolve().parent)
        print("STATIC POLICY VALIDATION PASS")
        gaps = workflow_gaps(metadata, args.workflow) if args.workflow else []
        for gap in gaps:
            print(f"WORKFLOW NO-GO: missing independent boundary: {gap}")
        print("COMMISSIONING NO-GO: " + metadata["commissioning"]["reason"])
        if args.require_commissionable or gaps:
            return 3
        return 0
    except (OSError, PolicyError) as exc:
        print(f"POLICY VALIDATION FAILED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
