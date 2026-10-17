#!/usr/bin/env python3
"""Require complete OSV outputs and successful scanner/reporter outcomes."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


class ScanGateError(RuntimeError):
    pass


def load_object(path: Path, label: str) -> dict:
    try:
        with path.open(encoding="utf-8") as stream:
            document = json.load(stream)
    except (OSError, UnicodeError, ValueError) as failure:
        raise ScanGateError(f"{label} output is missing, empty or invalid JSON") from failure
    if not isinstance(document, dict):
        raise ScanGateError(f"{label} output must be a JSON object")
    return document


def require_scan_success(scan_outcome: str, report_outcome: str, scan_json: Path, sarif_path: Path) -> dict:
    scan = load_object(scan_json, "Scanner")
    # The pinned scanner's Results field has no omitempty; a completed clean
    # scan writes results: [], rather than an empty object or empty bytes.
    if not isinstance(scan.get("results"), list):
        raise ScanGateError("Scanner results must be an array")
    sarif = load_object(sarif_path, "SARIF")
    runs = sarif.get("runs")
    if sarif.get("version") != "2.1.0" or not isinstance(runs, list) or not runs:
        raise ScanGateError("SARIF output must contain a 2.1.0 run")
    for run in runs:
        if (not isinstance(run, dict) or not isinstance(run.get("tool"), dict)
                or not isinstance(run["tool"].get("driver"), dict)
                or not run["tool"]["driver"].get("name")
                or not isinstance(run.get("results", []), list)):
            raise ScanGateError("SARIF output contains an invalid run")
    # GHA's conclusion becomes success under continue-on-error. Use the actual
    # outcome so a crash or vulnerability cannot be hidden by a clean reporter.
    if scan_outcome != "success":
        raise ScanGateError("OSV scanner did not succeed: " + scan_outcome)
    if report_outcome != "success":
        raise ScanGateError("OSV reporter did not succeed: " + report_outcome)
    # This OSV reporter has already filtered the registered config exceptions.
    # Count actual records independently; process success cannot waive findings.
    result_count = sum(len(run.get("results", [])) for run in runs)
    if result_count:
        raise ScanGateError(f"OSV SARIF contains {result_count} unignored finding(s)")
    return {"scanner": scan_outcome, "reporter": report_outcome,
            "sarifRuns": len(runs), "sarifResults": result_count}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan-outcome", required=True)
    parser.add_argument("--report-outcome", required=True)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--sarif", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = require_scan_success(args.scan_outcome, args.report_outcome, args.json, args.sarif)
    except ScanGateError as failure:
        print("::error::" + str(failure), file=sys.stderr)
        return 1
    print("Complete OSV scan and report verified: " + json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
