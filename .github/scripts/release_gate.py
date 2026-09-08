#!/usr/bin/env python3
"""Read-only same-commit release gate. Never accept an older green run over a newer attempt."""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


WORKFLOWS = ("quality.yml", "codeql.yml", "osv-scanner.yml")
PAGE_SIZE = 100
MAX_RUNS = 1000


class GateError(Exception):
    """A prerequisite cannot be proven; safe to print without API bodies or credentials."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHubApi:
    def __init__(self, token, api_url="https://api.github.com"):
        parsed = urllib.parse.urlsplit(api_url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username
                or parsed.password or parsed.query or parsed.fragment):
            raise GateError("GitHub API URL must be an HTTPS origin/path without credentials.")
        if not token:
            raise GateError("GH_TOKEN is required with Actions read permission.")
        self.base = api_url.rstrip("/")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)

    def get(self, path):
        request = urllib.request.Request(self.base + path, headers={
            "Authorization": "Bearer " + self.token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2026-03-10",
            "User-Agent": "uten-imp-release-gate",
        })
        try:
            with self.opener.open(request, timeout=20) as response:
                if response.status != 200:
                    raise GateError("GitHub API returned an unexpected status.")
                body = response.read(10_000_001)
                if len(body) > 10_000_000:
                    raise GateError("GitHub API response exceeded the release-gate limit.")
                result = json.loads(body)
                if not isinstance(result, dict):
                    raise GateError("GitHub API returned an invalid object.")
                return result
        except urllib.error.HTTPError as failure:
            # Error bodies and request headers can contain sensitive details; never log them.
            failure.close()
            raise GateError(f"GitHub API HTTP {failure.code}; verify Actions read access and rerun manually.") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise GateError("GitHub API transport failed; rerun manually after connectivity is restored.") from None
        except (ValueError, UnicodeError):
            raise GateError("GitHub API returned invalid JSON; release remains blocked.") from None


def positive_integer(value, label):
    if type(value) is not int or value < 1:
        raise GateError(f"Missing or invalid {label} in workflow evidence.")
    return value


def validate_run(run, workflow_id, path, sha, repository):
    if not isinstance(run, dict):
        raise GateError(f"Invalid run evidence for {path}.")
    if run.get("head_sha") != sha:
        raise GateError(f"Wrong commit SHA returned for {path}; release remains blocked.")
    # REST paths may have a @ref suffix. The actual workflow file and numeric ID must both match.
    run_path = run.get("path")
    if (run.get("workflow_id") != workflow_id or not isinstance(run_path, str)
            or run_path.split("@", 1)[0] != path):
        raise GateError(f"Workflow identity mismatch for {path}.")
    run_repository = run.get("repository")
    if (not isinstance(run_repository, dict)
            or not isinstance(run_repository.get("full_name"), str)
            or run_repository["full_name"].casefold() != repository.casefold()):
        raise GateError(f"Run repository mismatch for {path}.")
    return (positive_integer(run.get("run_number"), "run number"),
            positive_integer(run.get("id"), "run ID"),
            positive_integer(run.get("run_attempt"), "run attempt"))


def require_release_gates(api, repository, sha):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise GateError("GITHUB_REPOSITORY must identify one owner/repository.")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise GateError("The exact checked-out 40-character commit SHA is required.")
    prefix = f"/repos/{repository}/actions"
    evidence = []
    for filename in WORKFLOWS:
        path = ".github/workflows/" + filename
        workflow = api.get(f"{prefix}/workflows/{filename}")
        workflow_id = positive_integer(workflow.get("id"), "workflow ID")
        if workflow.get("path") != path or workflow.get("state") != "active":
            raise GateError(f"Required workflow {path} is missing, disabled or has a different identity.")
        runs = []
        total = None
        for page in range(1, MAX_RUNS // PAGE_SIZE + 1):
            query = urllib.parse.urlencode({"head_sha": sha, "per_page": PAGE_SIZE, "page": page})
            payload = api.get(f"{prefix}/workflows/{workflow_id}/runs?{query}")
            count = payload.get("total_count")
            batch = payload.get("workflow_runs")
            if type(count) is not int or count < 0 or not isinstance(batch, list):
                raise GateError(f"Invalid run listing for {path}.")
            if count == 0:
                raise GateError(f"No run exists for {path} at {sha}; complete that workflow and rerun release.")
            if count > MAX_RUNS or len(batch) > PAGE_SIZE:
                raise GateError(f"Run history exceeds the bounded verification limit for {path}.")
            if total is not None and total != count:
                raise GateError(f"Run history changed during verification for {path}; rerun release manually.")
            total = count
            for run in batch:
                validate_run(run, workflow_id, path, sha, repository)
            runs.extend(batch)
            if len(runs) >= total:
                break
            if not batch:
                raise GateError(f"Incomplete run listing for {path}.")
        if len(runs) != total or len({run["id"] for run in runs}) != len(runs):
            raise GateError(f"Incomplete or duplicated run listing for {path}.")
        latest = max(runs, key=lambda run: validate_run(run, workflow_id, path, sha, repository))
        # A rerun uses the same run ID. Fetch its current attempt instead of trusting a cached green list row.
        current = api.get(f"{prefix}/runs/{latest['id']}")
        current_key = validate_run(current, workflow_id, path, sha, repository)
        latest_key = validate_run(latest, workflow_id, path, sha, repository)
        if current_key[:2] != latest_key[:2] or current_key[2] < latest_key[2]:
            raise GateError(f"Latest run/attempt evidence changed inconsistently for {path}.")
        if current.get("status") != "completed" or current.get("conclusion") != "success":
            # Only known enum values are printed, never arbitrary API error text.
            known = {"completed", "queued", "in_progress", "waiting", "pending", "requested",
                     "failure", "cancelled", "timed_out", "action_required", "neutral", "skipped", "stale"}
            status = current.get("status")
            status = status if isinstance(status, str) and status in known else "unknown"
            conclusion = current.get("conclusion")
            conclusion = conclusion if isinstance(conclusion, str) and conclusion in known else "not-success"
            raise GateError(f"Latest run {current_key[1]} attempt {current_key[2]} for {path} is {status}/{conclusion}; wait for or fix it, then rerun release manually.")
        evidence.append(f"{filename}: run {current_key[1]} attempt {current_key[2]} completed successfully for {sha}")
    return evidence


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True)
    args = parser.parse_args(argv)
    try:
        api = GitHubApi(os.environ.get("GH_TOKEN", ""), os.environ.get("GITHUB_API_URL", "https://api.github.com"))
        evidence = require_release_gates(api, os.environ.get("GITHUB_REPOSITORY", ""), args.sha)
    except GateError as failure:
        print(f"::error::Release gate rejected: {failure}", file=sys.stderr)
        return 1
    print("Release gates verified for the exact checkout commit:")
    for line in evidence:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
