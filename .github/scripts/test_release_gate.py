"""Offline GitHub response fixtures and the actual release-workflow ordering contract."""

import contextlib
import copy
import io
from pathlib import Path
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch

import release_gate as gate


SHA = "a" * 40
REPOSITORY = "owner/repository"
ROOT = Path(__file__).resolve().parents[2]


def run(workflow_id, filename, run_id, number=1, attempt=1, status="completed", conclusion="success"):
    return {"id": run_id, "workflow_id": workflow_id, "path": ".github/workflows/" + filename + "@main",
            "head_sha": SHA, "run_number": number, "run_attempt": attempt,
            "status": status, "conclusion": conclusion, "repository": {"full_name": REPOSITORY}}


class FixtureApi:
    def __init__(self):
        self.workflows = {name: {"id": 100 + i, "path": ".github/workflows/" + name, "state": "active"}
                          for i, name in enumerate(gate.WORKFLOWS)}
        self.runs = {name: [run(100 + i, name, 1000 + i)] for i, name in enumerate(gate.WORKFLOWS)}
        self.details = {}
        self.calls = []

    def get(self, path):
        self.calls.append(path)
        route = path.split("/actions/", 1)[1]
        if route.startswith("runs/"):
            run_id = int(route.split("/")[1])
            current = self.details.get(run_id)
            if current is None:
                current = next(r for runs in self.runs.values() for r in runs if r["id"] == run_id)
            return copy.deepcopy(current)
        workflow = route.split("/")[1]
        if workflow in self.workflows:
            return copy.deepcopy(self.workflows[workflow])
        name = next(name for name, metadata in self.workflows.items() if str(metadata["id"]) == workflow)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
        assert query["head_sha"] == [SHA]
        assert "status" not in query  # Filtering to success/completed would hide a later pending/failed run.
        page = int(query["page"][0])
        return {"total_count": len(self.runs[name]),
                "workflow_runs": copy.deepcopy(self.runs[name][(page - 1) * gate.PAGE_SIZE:page * gate.PAGE_SIZE])}


class ReleaseGateTest(unittest.TestCase):
    def test_all_three_exact_commit_workflows_must_pass(self):
        api = FixtureApi()
        evidence = gate.require_release_gates(api, REPOSITORY, SHA)
        self.assertEqual(3, len(evidence))
        self.assertTrue(all(SHA in item for item in evidence))
        self.assertEqual(9, len(api.calls))

    def test_missing_run_rejects_instead_of_accepting_other_workflows(self):
        api = FixtureApi()
        api.runs["osv-scanner.yml"] = []
        with self.assertRaisesRegex(gate.GateError, "No run exists.*osv-scanner"):
            gate.require_release_gates(api, REPOSITORY, SHA)

    def test_wrong_sha_in_listing_or_current_attempt_rejects(self):
        for in_detail in (False, True):
            with self.subTest(in_detail=in_detail):
                api = FixtureApi()
                record = copy.deepcopy(api.runs["quality.yml"][0])
                record["head_sha"] = "b" * 40
                if in_detail:
                    api.details[record["id"]] = record
                else:
                    api.runs["quality.yml"] = [record]
                with self.assertRaisesRegex(gate.GateError, "Wrong commit SHA"):
                    gate.require_release_gates(api, REPOSITORY, SHA)

    def test_newer_failed_cancelled_or_non_success_run_blocks_old_success(self):
        for conclusion in ("failure", "cancelled", "timed_out", "neutral", "skipped", "action_required"):
            with self.subTest(conclusion=conclusion):
                api = FixtureApi()
                api.runs["quality.yml"].append(run(100, "quality.yml", 2000, number=2, conclusion=conclusion))
                api.runs["quality.yml"].reverse()  # Selection must not depend on response ordering.
                with self.assertRaises(gate.GateError):
                    gate.require_release_gates(api, REPOSITORY, SHA)

    def test_newer_queued_or_running_run_blocks_old_success(self):
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            with self.subTest(status=status):
                api = FixtureApi()
                api.runs["quality.yml"].append(run(100, "quality.yml", 2000, number=2, status=status, conclusion=None))
                with self.assertRaisesRegex(gate.GateError, status):
                    gate.require_release_gates(api, REPOSITORY, SHA)

    def test_explicit_manual_mode_accepts_running_without_failed_jobs(self):
        api = FixtureApi()
        api.details[1000] = run(100, "quality.yml", 1000, status="in_progress", conclusion=None)
        original_get = api.get
        with patch.object(api, "get", side_effect=lambda path: (
                {"total_count": 2, "jobs": [{"conclusion": "success"}, {"conclusion": None}]}
                if "/jobs?" in path else original_get(path))):
            evidence = gate.require_release_gates(api, REPOSITORY, SHA, allow_running=True)
        self.assertIn("CI not yet passed", evidence[0])

    def test_manual_mode_never_accepts_failed_or_incomplete_jobs(self):
        for payload in ({"total_count": 1, "jobs": [{"conclusion": "failure"}]},
                        {"total_count": 2, "jobs": [{"conclusion": None}]},
                        {"total_count": 1, "jobs": [{"conclusion": "cancelled"}]}):
            api = FixtureApi()
            api.details[1000] = run(100, "quality.yml", 1000, status="in_progress", conclusion=None)
            original_get = api.get
            with self.subTest(payload=payload), patch.object(api, "get", side_effect=lambda path: (
                    payload if "/jobs?" in path else original_get(path))):
                with self.assertRaises(gate.GateError):
                    gate.require_release_gates(api, REPOSITORY, SHA, allow_running=True)

    def test_manual_mode_does_not_accept_completed_failure(self):
        api = FixtureApi()
        api.details[1000] = run(100, "quality.yml", 1000, conclusion="failure")
        with self.assertRaises(gate.GateError):
            gate.require_release_gates(api, REPOSITORY, SHA, allow_running=True)

    def test_pending_override_cannot_be_used_for_a_tag_push(self):
        with patch.dict("os.environ", {"GITHUB_EVENT_NAME": "push"}), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(1, gate.main(["--sha", SHA, "--allow-running"]))

    def test_fresh_attempt_overrules_stale_green_listing(self):
        for status, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "cancelled")):
            with self.subTest(status=status, conclusion=conclusion):
                api = FixtureApi()
                api.details[1000] = run(100, "quality.yml", 1000, attempt=2, status=status, conclusion=conclusion)
                with self.assertRaisesRegex(gate.GateError, "attempt 2"):
                    gate.require_release_gates(api, REPOSITORY, SHA)

    def test_current_successful_rerun_can_supersede_old_failed_attempt(self):
        api = FixtureApi()
        api.runs["quality.yml"][0]["conclusion"] = "failure"
        api.details[1000] = run(100, "quality.yml", 1000, attempt=2)
        self.assertIn("attempt 2", gate.require_release_gates(api, REPOSITORY, SHA)[0])

    def test_current_attempt_cannot_go_backwards(self):
        api = FixtureApi()
        api.runs["quality.yml"][0]["run_attempt"] = 2
        api.details[1000] = run(100, "quality.yml", 1000, attempt=1)
        with self.assertRaisesRegex(gate.GateError, "inconsistently"):
            gate.require_release_gates(api, REPOSITORY, SHA)

    def test_workflow_file_and_numeric_id_are_required_not_display_name(self):
        for field, value in (("workflow_id", 999), ("path", ".github/workflows/impostor.yml@main")):
            with self.subTest(field=field):
                api = FixtureApi()
                api.runs["quality.yml"][0][field] = value
                api.runs["quality.yml"][0]["name"] = "Quality Gate"
                with self.assertRaisesRegex(gate.GateError, "identity mismatch"):
                    gate.require_release_gates(api, REPOSITORY, SHA)

    def test_disabled_or_wrong_metadata_workflow_rejects(self):
        for field, value in (("state", "disabled_manually"), ("path", ".github/workflows/wrong.yml")):
            with self.subTest(field=field):
                api = FixtureApi()
                api.workflows["quality.yml"][field] = value
                with self.assertRaises(gate.GateError):
                    gate.require_release_gates(api, REPOSITORY, SHA)

    def test_wrong_repository_rejects(self):
        api = FixtureApi()
        api.runs["quality.yml"][0]["repository"]["full_name"] = "another/repository"
        with self.assertRaisesRegex(gate.GateError, "repository mismatch"):
            gate.require_release_gates(api, REPOSITORY, SHA)

    def test_pagination_does_not_hide_newer_failure(self):
        api = FixtureApi()
        api.runs["quality.yml"] = [run(100, "quality.yml", 2000 + i, number=i + 1) for i in range(101)]
        api.runs["quality.yml"][-1]["conclusion"] = "failure"
        with self.assertRaisesRegex(gate.GateError, "2100"):
            gate.require_release_gates(api, REPOSITORY, SHA)
        self.assertTrue(any("page=2" in call for call in api.calls))

    def test_excessive_history_is_bounded_and_rejected(self):
        api = FixtureApi()
        api.runs["quality.yml"] = [run(100, "quality.yml", 2000 + i, number=i + 1) for i in range(1001)]
        with self.assertRaisesRegex(gate.GateError, "bounded"):
            gate.require_release_gates(api, REPOSITORY, SHA)
        self.assertEqual(2, len(api.calls))

    def test_duplicate_listing_cannot_hide_an_unseen_newer_run(self):
        api = FixtureApi()
        api.runs["quality.yml"].append(copy.deepcopy(api.runs["quality.yml"][0]))
        with self.assertRaisesRegex(gate.GateError, "duplicated"):
            gate.require_release_gates(api, REPOSITORY, SHA)

    def test_api_http_or_transport_errors_never_log_credentials_or_body(self):
        sensitive = "offline-sentinel-do-not-print"
        errors = [urllib.error.HTTPError("https://api.github.com", 403, sensitive, {}, io.BytesIO(sensitive.encode())),
                  urllib.error.URLError(sensitive), TimeoutError(sensitive)]
        for failure in errors:
            with self.subTest(failure=type(failure).__name__):
                stderr = io.StringIO()
                with patch.dict("os.environ", {"GH_TOKEN": sensitive, "GITHUB_REPOSITORY": REPOSITORY}), \
                        patch("urllib.request.OpenerDirector.open", side_effect=failure), contextlib.redirect_stderr(stderr):
                    self.assertEqual(1, gate.main(["--sha", SHA]))
                self.assertIn("Release gate rejected", stderr.getvalue())
                self.assertNotIn(sensitive, stderr.getvalue())

    def test_invalid_api_json_rejects(self):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b"not json"
        with patch("urllib.request.OpenerDirector.open", return_value=response):
            with self.assertRaisesRegex(gate.GateError, "invalid JSON"):
                gate.GitHubApi("offline-test").get("/repos/owner/repository/actions/workflows/quality.yml")

    def test_missing_token_and_invalid_sha_reject(self):
        with self.assertRaisesRegex(gate.GateError, "GH_TOKEN"):
            gate.GitHubApi("")
        with self.assertRaisesRegex(gate.GateError, "commit SHA"):
            gate.require_release_gates(FixtureApi(), REPOSITORY, "main")


class ReleaseWorkflowContractTest(unittest.TestCase):
    def test_guard_runs_before_build_and_again_before_credentials_are_exposed(self):
        workflow = (ROOT / ".github/workflows/simple-release.yml").read_text(encoding="utf-8")
        guard = "python3 .github/scripts/release_gate.py --sha"
        self.assertEqual(2, workflow.count(guard))
        self.assertLess(workflow.index("actions/checkout@"), workflow.index(guard))
        self.assertLess(workflow.index(guard), workflow.index("mvn $MAVEN_ARGS clean package -DskipTests"))
        self.assertLess(workflow.index("Assemble release directory"), workflow.rindex(guard))
        self.assertLess(workflow.rindex(guard), workflow.index("${{ secrets.RELEASE_SIGNING_KEY }}"))
        self.assertLess(workflow.rindex(guard), workflow.index("${{ secrets.OSS_ACCESS_KEY_ID }}"))
        self.assertEqual(2, workflow.count('test "$CHECKOUT_SHA" = "$GITHUB_SHA"'))
        self.assertIn("  actions: read", workflow)
        self.assertNotIn("actions: write", workflow)
        self.assertIn("test_release_gate.py", workflow)
        for block in workflow.split("      - name:"):
            if guard in block:
                self.assertNotIn("continue-on-error", block)

    def test_required_workflows_are_the_existing_named_gates(self):
        expected = {"quality.yml": "Quality Gate", "codeql.yml": "CodeQL", "osv-scanner.yml": "Dependency Vulnerability Scan"}
        self.assertEqual(set(expected), set(gate.WORKFLOWS))
        for filename, name in expected.items():
            content = (ROOT / ".github/workflows" / filename).read_text(encoding="utf-8")
            self.assertIn("name: " + name + "\n", content)
            self.assertIn("branches: [main]", content)


if __name__ == "__main__":
    unittest.main()
