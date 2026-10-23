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


WORKFLOWS = ("quality.yml", "codeql.yml", "osv-scanner.yml", "material-forecast.yml")
PAGE_SIZE = 100
MAX_RUNS = 1000
MAX_JOBS = 1000
MAX_ANNOTATIONS = 1000


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
        return self._get(path, dict)

    def get_array(self, path):
        return self._get(path, list)

    def _get(self, path, expected_type):
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
                if not isinstance(result, expected_type):
                    raise GateError("GitHub API returned an invalid response shape.")
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


def require_clean_job_annotations(api, repository, current, path, sha, pending=False):
    """A successful workflow can still carry warning/error annotations."""
    run_id = current["id"]
    attempt = current["run_attempt"]
    suite_id = positive_integer(current.get("check_suite_id"), "check suite ID")
    prefix = f"/repos/{repository}"
    jobs = []
    total = None
    for page in range(1, MAX_JOBS // PAGE_SIZE + 1):
        payload = api.get(f"{prefix}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page={PAGE_SIZE}&page={page}")
        count, batch = payload.get("total_count"), payload.get("jobs")
        if (type(count) is not int or count < 0 or count > MAX_JOBS
                or not isinstance(batch, list) or len(batch) > PAGE_SIZE
                or (total is not None and total != count)):
            raise GateError(f"Invalid or changing job inventory for {path}.")
        total = count
        jobs.extend(batch)
        if len(jobs) >= total:
            break
        if not batch:
            raise GateError(f"Incomplete job inventory for {path}.")
    if len(jobs) != total or (not pending and not jobs):
        raise GateError(f"Incomplete job inventory for {path}.")
    job_ids = set()
    for job in jobs:
        if not isinstance(job, dict):
            raise GateError(f"Invalid job evidence for {path}.")
        job_id = positive_integer(job.get("id"), "job ID")
        if (job_id in job_ids or job.get("run_id") != run_id
                or job.get("run_attempt") != attempt or job.get("head_sha") != sha):
            raise GateError(f"Job identity/attempt mismatch for {path}.")
        job_ids.add(job_id)
        if (job.get("conclusion") not in ((None, "success") if pending else ("success",))
                or (not pending and job.get("status") != "completed")):
            raise GateError(f"A job has not succeeded for {path}.")
        check_url = job.get("check_run_url")
        check_path = urllib.parse.urlsplit(check_url).path if isinstance(check_url, str) else ""
        match = re.fullmatch(re.escape(prefix) + r"/check-runs/([1-9][0-9]*)", check_path)
        if not match:
            raise GateError(f"Missing or invalid check-run identity for {path}.")
        check_id = int(match.group(1))
        # Only use the validated repository-relative route, never an API-provided origin.
        check_route = f"{prefix}/check-runs/{check_id}"
        check = api.get(check_route)
        suite = check.get("check_suite")
        output = check.get("output")
        if (check.get("id") != check_id or check.get("head_sha") != sha
                or not isinstance(suite, dict) or suite.get("id") != suite_id
                or not isinstance(output, dict)):
            raise GateError(f"Check-run SHA/suite mismatch for {path}.")
        count = output.get("annotations_count")
        if type(count) is not int or count < 0 or count > MAX_ANNOTATIONS:
            raise GateError(f"Invalid annotation count for {path}.")
        annotations = []
        for page in range(1, max(1, (count + PAGE_SIZE - 1) // PAGE_SIZE) + 1):
            batch = api.get_array(f"{check_route}/annotations?per_page={PAGE_SIZE}&page={page}")
            if not isinstance(batch, list) or len(batch) > PAGE_SIZE:
                raise GateError(f"Invalid annotation listing for {path}.")
            annotations.extend(batch)
        if len(annotations) != count:
            raise GateError(f"Incomplete annotation listing for {path}.")
        for annotation in annotations:
            level = annotation.get("annotation_level") if isinstance(annotation, dict) else None
            if level not in {"notice", "warning", "failure"}:
                raise GateError(f"Invalid annotation evidence for {path}.")
            if level != "notice":
                # Annotation messages may contain source data or credentials; report only identity/level.
                raise GateError(f"Check run {check_id} for {path} contains a {level} annotation; fix its root cause and rerun CI.")


def require_release_gates(api, repository, sha, allow_running=False):
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
        pending = current.get("status") in {"queued", "in_progress", "waiting", "pending", "requested"}
        if allow_running and pending and current.get("conclusion") is None:
            require_clean_job_annotations(api, repository, current, path, sha, pending=True)
            evidence.append(f"{filename}: run {current_key[1]} attempt {current_key[2]} is still running for {sha}; explicitly authorized manual release, CI not yet passed")
            continue
        if current.get("status") != "completed" or current.get("conclusion") != "success":
            # Only known enum values are printed, never arbitrary API error text.
            known = {"completed", "queued", "in_progress", "waiting", "pending", "requested",
                     "failure", "cancelled", "timed_out", "action_required", "neutral", "skipped", "stale"}
            status = current.get("status")
            status = status if isinstance(status, str) and status in known else "unknown"
            conclusion = current.get("conclusion")
            conclusion = conclusion if isinstance(conclusion, str) and conclusion in known else "not-success"
            raise GateError(f"Latest run {current_key[1]} attempt {current_key[2]} for {path} is {status}/{conclusion}; wait for or fix it, then rerun release manually.")
        require_clean_job_annotations(api, repository, current, path, sha)
        refreshed = api.get(f"{prefix}/runs/{current_key[1]}")
        if (validate_run(refreshed, workflow_id, path, sha, repository) != current_key
                or refreshed.get("status") != "completed" or refreshed.get("conclusion") != "success"):
            raise GateError(f"Run attempt changed during annotation verification for {path}; rerun release.")
        evidence.append(f"{filename}: run {current_key[1]} attempt {current_key[2]} completed successfully with zero warning/failure annotations for {sha}")
    return evidence


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--allow-running", action="store_true",
                        help="Explicit manual dispatch only: permit pending checks, never failed checks")
    args = parser.parse_args(argv)
    try:
        if args.allow_running and os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
            raise GateError("Pending-check release requires an explicit manual workflow dispatch.")
        api = GitHubApi(os.environ.get("GH_TOKEN", ""), os.environ.get("GITHUB_API_URL", "https://api.github.com"))
        evidence = require_release_gates(api, os.environ.get("GITHUB_REPOSITORY", ""), args.sha, args.allow_running)
    except GateError as failure:
        print(f"::error::Release gate rejected: {failure}", file=sys.stderr)
        return 1
    print("Release gates verified for the exact checkout commit:")
    for line in evidence:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
