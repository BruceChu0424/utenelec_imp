"""Offline GitHub response fixtures and the actual release-workflow ordering contract."""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import urllib.error
import urllib.parse
import zipfile
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
    def test_all_four_exact_commit_workflows_must_pass(self):
        api = FixtureApi()
        evidence = gate.require_release_gates(api, REPOSITORY, SHA)
        self.assertEqual(4, len(evidence))
        self.assertTrue(all(SHA in item for item in evidence))
        self.assertEqual(12, len(api.calls))

    def test_forecast_missing_failed_or_pending_cannot_be_bypassed_by_other_green_gates(self):
        for state in ("missing", "failure", "in_progress"):
            with self.subTest(state=state):
                api = FixtureApi()
                if state == "missing":
                    api.runs["material-forecast.yml"] = []
                elif state == "failure":
                    api.runs["material-forecast.yml"][0]["conclusion"] = "failure"
                else:
                    api.runs["material-forecast.yml"][0].update(status=state, conclusion=None)
                with self.assertRaisesRegex(gate.GateError, "material-forecast"):
                    gate.require_release_gates(api, REPOSITORY, SHA)

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
    def test_quality_and_release_use_the_same_strict_lock_before_all_flutter_consumers(self):
        workflows = {name: (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
                     for name in ("quality.yml", "simple-release.yml", "_unsigned-candidate-build.yml", "release.yml")}
        versions = []
        for name, source in workflows.items():
            with self.subTest(workflow=name):
                versions.append(re.findall(r"^\s+flutter-version: (\S+)$", source, re.MULTILINE))
                resolves = re.findall(r"^\s*(?:- run:\s*)?(flutter pub [^\n]+)$", source, re.MULTILINE)
                self.assertEqual(["flutter pub get --enforce-lockfile"], resolves)
                strict_position = source.index(resolves[0])
                consumers = list(re.finditer(
                    r"^\s*(?:- run:\s*)?(flutter (?:analyze|test|build web)\b[^\n]*)",
                    source, re.MULTILINE))
                self.assertTrue(consumers)
                for command in consumers:
                    self.assertGreater(command.start(1), strict_position)
                    self.assertIn("--no-pub", command.group(1).split())
                strict_step = next(block for block in source.split("      - ")
                                   if "flutter pub get --enforce-lockfile" in block)
                self.assertNotIn("continue-on-error", strict_step)
                self.assertNotIn("||", strict_step)
                self.assertNotIn("--dry-run", strict_step)
                if name in ("quality.yml", "simple-release.yml"):
                    self.assertIn("-p 'test_release_gate.py' -v", source)
        self.assertEqual(1, len(versions[0]))
        self.assertTrue(all(version == versions[0] for version in versions[1:]))

    def test_security_scan_and_build_share_the_canonical_hashed_checkout_lock(self):
        lock = (ROOT / "pubspec.lock").read_text(encoding="utf-8")
        hosted = [block for block in re.split(r"(?m)^  [a-z_][a-z0-9_]*:\n", lock)[1:]
                  if re.search(r"(?m)^    source: hosted$", block)]
        self.assertTrue(hosted)
        for block in hosted:
            self.assertEqual(["https://pub.dev"], re.findall(r'^      url: "([^"]+)"$', block, re.MULTILINE))
            self.assertRegex(block, r'(?m)^      sha256: "?[a-f0-9]{64}"?$')
        osv = (ROOT / ".github/workflows/osv-scanner.yml").read_text(encoding="utf-8")
        self.assertIn("--lockfile\n            ./pubspec.lock", osv)
        self.assertIn("\n            pubspec.lock\n", osv)
        self.assertNotRegex(osv, r"\b(?:flutter|dart)\s+pub\b")
        for name in ("quality.yml", "simple-release.yml", "_unsigned-candidate-build.yml", "release.yml", "osv-scanner.yml"):
            source = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
            with self.subTest(workflow=name):
                self.assertNotIn("PUB_HOSTED_URL", source)
                self.assertNotRegex(source, r"\b(?:rm|unlink|Remove-Item)\b[^\n]*pubspec\.lock")

    def test_current_release_verifies_migrations_before_signed_inventory(self):
        workflow = (ROOT / ".github/workflows/simple-release.yml").read_text(encoding="utf-8")
        build = workflow.split("      - name: Build server application and migrator\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("-Dtest=ForwardMigrationSequenceContractTest,FlywayChecksumManifestExporterTest", build)
        self.assertIn("-Duten.exportFlywayChecksums=true test", build)
        assembly = workflow.split("      - name: Assemble release directory\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("--flyway-dir server/src/main/resources/db/migration", assembly)
        self.assertIn("--flyway-checksums server/target/uten-imp-flyway-checksums.tsv", assembly)
        self.assertLess(assembly.index("verify-migrations"), assembly.index("sha256sum > SHA256SUMS"))
        self.assertLess(workflow.index("verify-migrations"), workflow.index("${{ secrets.RELEASE_SIGNING_KEY }}"))
        self.assertNotIn("continue-on-error", build + assembly)

    def test_application_identity_and_browser_metadata_share_the_release_checkout(self):
        workflow = (ROOT / ".github/workflows/simple-release.yml").read_text(encoding="utf-8")
        build = workflow.split("      - name: Build Flutter Web\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn('--dart-define="APP_VERSION=$VERSION"', build)
        self.assertIn('--dart-define="APP_BUILD_ID=$GITHUB_SHA"', build)
        self.assertIn("node --test web/update_check.test.cjs", build)
        assembly = workflow.split("      - name: Assemble release directory\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn('stamp-web \\\n            --pubspec pubspec.yaml \\\n            --web-root dist/web --version "$VERSION" --commit "$GITHUB_SHA"', assembly)
        self.assertLess(assembly.index("stamp-web"), assembly.index("sha256sum > SHA256SUMS"))
        self.assertNotIn("publishedAt", assembly)

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
        expected = {"quality.yml": "Quality Gate", "codeql.yml": "CodeQL",
                    "osv-scanner.yml": "Dependency Vulnerability Scan", "material-forecast.yml": "Material forecast"}
        self.assertEqual(set(expected), set(gate.WORKFLOWS))
        for filename, name in expected.items():
            content = (ROOT / ".github/workflows" / filename).read_text(encoding="utf-8")
            self.assertIn("name: " + name + "\n", content)
            self.assertIn("branches: [main]", content)


@unittest.skipUnless(os.name == "posix", "release assembly uses the Linux CI environment")
class SimpleReleaseWebAssemblyTest(unittest.TestCase):
    version = "v2.5.3"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ("server/target", "server/src/main/resources/db/migration", "build/web", "deploy/release"):
            (self.root / directory).mkdir(parents=True)
        spec = importlib.util.spec_from_file_location("assembly_release_tools", ROOT / "deploy/release/release_tools.py")
        tools = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = tools
        spec.loader.exec_module(tools)
        self.migration_name = "V1__initial_schema.sql"
        self.migration = self.root / "server/src/main/resources/db/migration" / self.migration_name
        self.migration.write_text("create table fixture(id integer);\n", encoding="utf-8")
        (self.root / "server/target/uten-imp-flyway-checksums.tsv").write_text(
            tools.FLYWAY_CHECKSUM_HEADER + "\n1\t" + self.migration_name + "\t-1320745395\n", encoding="utf-8")
        for name, prefix in (("uten-imp-server-0.1.0.jar", "BOOT-INF/classes/db/migration/"),
                             ("uten-imp-migrator.jar", "db/migration/")):
            with zipfile.ZipFile(self.root / "server/target" / name, "w") as jar:
                jar.write(self.migration, prefix + self.migration_name)
                if name == "uten-imp-migrator.jar":
                    jar.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nMain-Class: com.uten.imp.migration.UtenImpMigrator\r\n\r\n")
                    for application_class in tools.MIGRATOR_APPLICATION_CLASSES:
                        jar.writestr(application_class, b"fixture-bytecode")
        shutil.copyfile(ROOT / "web/index.html", self.root / "build/web/index.html")
        shutil.copyfile(ROOT / "deploy/release/release_tools.py", self.root / "deploy/release/release_tools.py")
        (self.root / "pubspec.yaml").write_text("name: uten_imp\nversion: 2.5.3+253\n", encoding="utf-8")
        # Flutter 3.44.2 output for the checkout that failed v2.5.3 assembly.
        (self.root / "build/web/version.json").write_bytes(
            b'{"app_name":"uten_imp","version":"2.5.3","build_number":"253","package_name":"uten_imp"}'
        )
        workflow = (ROOT / ".github/workflows/simple-release.yml").read_text(encoding="utf-8")
        block = workflow.split("      - name: Assemble release directory\n", 1)[1].split("      - name:", 1)[0]
        self.assembly = textwrap.dedent(block.split("        run: |\n", 1)[1])

    def assemble(self):
        return subprocess.run(
            ["bash", "-c", self.assembly], cwd=self.root,
            env={**os.environ, "VERSION": self.version, "GITHUB_SHA": SHA},
            check=False, capture_output=True, text=True, timeout=30,
        )

    def test_actual_assembly_stamps_browser_identity_before_the_signed_inventory(self):
        result = self.assemble()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        dist = self.root / "dist"
        metadata = json.loads((dist / "web/version.json").read_text(encoding="utf-8"))
        self.assertEqual({"commitSha": SHA, "product": "uten-imp", "releaseSequence": 100002005003,
                          "schemaVersion": 1, "version": self.version}, metadata)
        index = (dist / "web/index.html").read_text(encoding="utf-8")
        self.assertNotIn("__UTEN_RELEASE_VERSION__", index)
        self.assertEqual([self.version], re.findall(r'<meta name="uten-release-version" content="([^"]+)">', index))
        self.assertIn('src="update_check.js"', index)
        checksums = dict(line.split("  ", 1)[::-1]
                         for line in (dist / "SHA256SUMS").read_text().splitlines())
        actual = {"./" + path.relative_to(dist).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in dist.rglob("*") if path.is_file() and path.name != "SHA256SUMS"}
        self.assertEqual(actual, checksums)
        self.assertFalse(any(path.name.startswith(".uten-web-release") for path in dist.rglob("*")))

    def test_unreviewed_web_metadata_blocks_assembly_before_checksums(self):
        (self.root / "build/web/version.json").write_text(
            json.dumps({"version": self.version, "commit": SHA, "publishedAt": "old format"})
        )
        result = self.assemble()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("differs from the reviewed Flutter", result.stderr)
        self.assertFalse((self.root / "dist/SHA256SUMS").exists())

    def test_checkout_version_mismatch_blocks_actual_assembly_before_checksums(self):
        (self.root / "pubspec.yaml").write_text("name: uten_imp\nversion: 2.5.4+254\n", encoding="utf-8")
        result = self.assemble()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("pubspec version differs", result.stderr)
        self.assertFalse((self.root / "dist/SHA256SUMS").exists())

    def test_duplicate_migration_blocks_actual_assembly_before_checksums(self):
        (self.migration.parent / "V1__parallel_worker.sql").write_text("select 1;\n", encoding="utf-8")
        result = self.assemble()
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "dist/SHA256SUMS").exists())

    def test_missing_or_changed_sql_in_either_jar_blocks_actual_assembly(self):
        for name, prefix in (("uten-imp-server-0.1.0.jar", "BOOT-INF/classes/db/migration/"),
                             ("uten-imp-migrator.jar", "db/migration/")):
            path = self.root / "server/target" / name
            original = path.read_bytes()
            for mutation in ("missing", "changed"):
                with self.subTest(jar=name, mutation=mutation):
                    with zipfile.ZipFile(io.BytesIO(original)) as source, zipfile.ZipFile(path, "w") as target:
                        for item in source.infolist():
                            if item.filename == prefix + self.migration_name:
                                if mutation == "changed": target.writestr(item, b"select 'unreviewed';\n")
                            else:
                                target.writestr(item, source.read(item))
                    result = self.assemble()
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("migrations differ", result.stderr)
                    self.assertFalse((self.root / "dist/SHA256SUMS").exists())
                    path.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
