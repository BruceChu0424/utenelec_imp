#!/usr/bin/env python3
"""Record actual CI for explicitly authorized company testing; never certify green."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlencode
from release_gate import GitHubApi, GateError, WORKFLOWS, positive_integer, validate_run

CONFIRMATION = "PUBLISH_COMPANY_TEST_WITH_UNRESOLVED_CI"


def bind_manual_source(sha, expected, confirmation, environment):
    if (not re.fullmatch(r"[0-9a-f]{40}", sha or "") or sha != expected
            or sha != environment.get("GITHUB_SHA")
            or environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or environment.get("GITHUB_REF") != "refs/heads/main"
            or confirmation != CONFIRMATION):
        raise GateError("Company testing requires manual main dispatch, exact SHA and explicit unresolved-CI confirmation.")


def collect(api, repository, sha):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise GateError("Invalid publication repository identity.")
    evidence = []
    for filename in WORKFLOWS:
        path = ".github/workflows/" + filename
        workflow = api.get(f"/repos/{repository}/actions/workflows/{filename}")
        identity = positive_integer(workflow.get("id"), "workflow ID")
        if workflow.get("path") != path or workflow.get("state") != "active":
            raise GateError("Company testing evidence has a different or inactive workflow.")
        query = urlencode({"head_sha": sha, "per_page": 100, "page": 1})
        listing = api.get(f"/repos/{repository}/actions/workflows/{identity}/runs?{query}")
        count, runs = listing.get("total_count"), listing.get("workflow_runs")
        if type(count) is not int or not 0 <= count <= 100 or not isinstance(runs, list) or len(runs) != count:
            raise GateError("Company testing CI inventory is incomplete or unbounded.")
        if not runs:
            evidence.append({"workflow": path, "workflowId": identity, "status": "not_started", "conclusion": None})
            continue
        latest = max(runs, key=lambda item: validate_run(item, identity, path, sha, repository))
        current = api.get(f"/repos/{repository}/actions/runs/{latest['id']}")
        key = validate_run(current, identity, path, sha, repository)
        if key < validate_run(latest, identity, path, sha, repository):
            raise GateError("Company testing CI attempt moved backwards.")
        if (current.get("status") not in {"completed", "queued", "in_progress", "waiting", "pending", "requested"}
                or current.get("conclusion") not in {None, "success", "failure", "cancelled", "timed_out", "action_required", "neutral", "skipped", "stale", "startup_failure"}):
            raise GateError("Unknown company testing CI state.")
        evidence.append({"workflow": path, "workflowId": identity, "runId": key[1], "attempt": key[2],
                         "status": current["status"], "conclusion": current.get("conclusion")})
    return {"schemaVersion": 1, "publicationMode": "explicit_company_test", "sourceCommit": sha,
            "ciCertifiedGreen": False, "authorization": CONFIRMATION,
            "capturedAtUtc": datetime.now(timezone.utc).isoformat(), "workflows": evidence}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("sha", "expected-source-sha", "confirmation", "output"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args(argv)
    try:
        bind_manual_source(args.sha, args.expected_source_sha, args.confirmation, os.environ)
        evidence = collect(GitHubApi(os.environ.get("GH_TOKEN", ""), os.environ.get("GITHUB_API_URL", "https://api.github.com")),
                           os.environ.get("GITHUB_REPOSITORY", ""), args.sha)
        Path(args.output).write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (GateError, OSError) as failure:
        print(f"::error::Company testing publication identity rejected: {failure}", file=sys.stderr)
        return 1
    print("Explicit company testing publication: actual CI recorded; CI is NOT certified green.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
