#!/usr/bin/env python3
"""Require complete CodeQL SARIF with zero findings, including notes and suppressions."""

import argparse
from collections import Counter
import json
from pathlib import Path
import sys


def _rule(run, result):
    tool = run.get("tool", {})
    driver = tool.get("driver", {})
    extensions = tool.get("extensions", [])
    reference = result.get("rule", {})
    component = reference.get("toolComponent", {})
    selected = None
    if "index" in component:
        index = component["index"]
        if isinstance(index, int) and 0 <= index < len(extensions):
            selected = extensions[index]
    elif "name" in component:
        selected = next((part for part in [driver, *extensions]
                         if part.get("name") == component["name"]), None)
    elif "ruleIndex" in result:
        selected = driver

    rule_id = result.get("ruleId", reference.get("id"))
    if selected is not None:
        rules = selected.get("rules", [])
        index = reference.get("index", result.get("ruleIndex"))
        if isinstance(index, int) and 0 <= index < len(rules):
            return rules[index]
        return next((rule for rule in rules if rule.get("id") == rule_id), {})
    matches = [rule for part in [driver, *extensions] for rule in part.get("rules", [])
               if rule.get("id") == rule_id]
    return matches[0] if len(matches) == 1 else {}


def inspect_sarif(path):
    path = Path(path)
    files = [path] if path.is_file() else sorted(path.rglob("*.sarif")) if path.is_dir() else []
    if not files:
        raise ValueError("CodeQL SARIF output is missing")
    levels = Counter()
    run_count = 0
    for filename in files:
        try:
            document = json.loads(filename.read_text(encoding="utf-8"))
        except (OSError, ValueError) as failure:
            raise ValueError(f"Unreadable CodeQL SARIF: {filename}") from failure
        runs = document.get("runs") if isinstance(document, dict) else None
        if not isinstance(runs, list) or not runs:
            raise ValueError(f"CodeQL SARIF has no analysis run: {filename}")
        for run in runs:
            if not isinstance(run, dict) or run.get("tool", {}).get("driver", {}).get("name") != "CodeQL":
                raise ValueError(f"Unexpected SARIF producer: {filename}")
            if any(invocation.get("executionSuccessful") is False for invocation in run.get("invocations", [])):
                raise ValueError(f"CodeQL analysis did not complete successfully: {filename}")
            results = run.get("results")
            if not isinstance(results, list):
                raise ValueError(f"CodeQL SARIF has no results array: {filename}")
            run_count += 1
            for result in results:
                if not isinstance(result, dict):
                    raise ValueError(f"Invalid CodeQL result: {filename}")
                level = result.get("level") or _rule(run, result).get("defaultConfiguration", {}).get("level", "warning")
                levels[level] += 1
    return {"files": len(files), "runs": run_count,
            "findings": sum(levels.values()), "levels": dict(sorted(levels.items()))}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", help="CodeQL SARIF file or output directory")
    arguments = parser.parse_args(argv)
    try:
        summary = inspect_sarif(arguments.path)
    except ValueError as failure:
        print(json.dumps({"error": str(failure)}), file=sys.stderr)
        return 2
    print(json.dumps(summary, sort_keys=True))
    if summary["findings"]:
        print(f"::error::CodeQL produced {summary['findings']} findings; zero are required.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
