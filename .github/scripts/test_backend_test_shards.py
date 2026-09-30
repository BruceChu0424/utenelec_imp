"""Regression fixtures for coverage, failure, skip and stale-evidence gates."""
import copy
import contextlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import sys
import threading
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import backend_test_shards as runner

SOURCE = {"sha": "a" * 40, "fingerprint": "b" * 64}


def test_class(name="example.AtestTest", methods=("plain",), phase="surefire", kind="test", gates=()):
    return {"name": name, "phase": phase,
            "methods": [{"id": name + "#" + method, "class": name, "method": method,
                         "kind": kind, "environment_gates": list(gates)} for method in methods]}


def plan(classes=None, shards=1):
    value = runner.make_plan(classes or [test_class()], shards, {}, SOURCE)
    value["plan_hash"] = runner.digest(value)
    return value


def testcase(name="plain", classname="example.AtestTest", status="passed", reason="", phase="surefire"):
    return {"phase": phase, "class": classname, "name": name, "status": status, "skip_reason": reason,
            "seconds": 0.1, "suite": classname, "suite_seconds": 90.0}


def save_xml(directory, cases):
    grouped = {}
    for case in cases:
        grouped.setdefault((case["phase"], case["class"]), []).append(case)
    for (phase, classname), group in grouped.items():
        suite = ET.Element("testsuite", name=classname, tests=str(len(group)), time="90")
        for case in group:
            item = ET.SubElement(suite, "testcase", classname=classname, name=case["name"], time=str(case["seconds"]))
            if case["status"] == "skipped":
                ET.SubElement(item, "skipped", message=case["skip_reason"])
            if case["status"] == "failed":
                ET.SubElement(item, "error", message="fixture failure")
        path = directory / f"{phase}-reports" / f"TEST-{classname}.xml"
        path.parent.mkdir(parents=True, exist_ok=True)
        ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def save_report(directory, manifest, shard, cases, code=0, unfiltered=False):
    save_xml(directory, cases)
    records, _ = runner.xml_cases(directory)
    report = {"schema_version": 1, "source": manifest["source"], "plan_hash": manifest["plan_hash"],
              "shard": shard, "coverage": manifest["coverage"], "database_tests_enabled": True,
              "maven_exit_code": code, "elapsed_seconds": 100.0, "unfiltered": unfiltered,
              **runner.audit_cases(manifest, shard, records, code)}
    runner.write_json(directory / "report.json", report)
    return report


class InventoryAndBalanceTests(unittest.TestCase):
    def test_lpt_uses_duration_instead_of_class_count_and_keeps_unknown_classes(self):
        classes = [test_class("example." + value + "Test") for value in "ABCDE"]
        history = {"classes": {row["name"]: {"seconds": seconds} for row, seconds in zip(classes[:4], [100, 70, 40, 10])}}
        shards = runner.balance(classes, 2, history)
        self.assertEqual(set(row["name"] for row in classes), {name for shard in shards for name in shard["classes"]})
        self.assertEqual(5, sum(len(shard["classes"]) for shard in shards))
        self.assertLessEqual(max(shard["estimated_seconds"] for shard in shards), 170)

    def test_failsafe_is_owned_once_and_never_dropped(self):
        classes = [test_class("example.A" + str(i) + "Test") for i in range(5)]
        classes += [test_class("example.PackagingIT", phase="failsafe"), test_class("example.SecondIT", phase="failsafe")]
        shards = runner.balance(classes, 4, {})
        self.assertIn("example.PackagingIT", shards[0]["classes"])
        self.assertIn("example.SecondIT", shards[0]["classes"])
        self.assertEqual(7, sum(len(shard["classes"]) for shard in shards))

    def test_overloaded_or_duplicate_discovery_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            plan([test_class(methods=("same", "same"))])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            plan([test_class(), test_class()])

    def test_nonfinite_history_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "finite"):
            runner.balance([test_class()], 1, {"classes": {"bad": {"seconds": float("nan")}}})

    def test_maven_custom_exclusions_require_discovery_support(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "effective.xml"
            path.write_text('''<project xmlns="http://maven.apache.org/POM/4.0.0"><build><plugins><plugin>
                <artifactId>maven-surefire-plugin</artifactId><configuration><excludes><exclude>**/*DbTest.java</exclude></excludes>
                </configuration></plugin></plugins></build></project>''')
            with self.assertRaisesRegex(ValueError, "custom selection"):
                runner.validate_maven_discovery(path)


class CoverageTests(unittest.TestCase):
    def test_missing_method_cannot_be_hidden_by_passing_class(self):
        result = runner.audit_cases(plan([test_class(methods=("plain", "omitted"))]), 0, [testcase()], 0)
        self.assertFalse(result["complete"])
        self.assertIn("Missing discovered method: example.AtestTest#omitted", result["errors"])

    def test_missing_failsafe_blocks_full_verify(self):
        manifest = plan([test_class(), test_class("example.PackageIT", phase="failsafe")])
        result = runner.audit_cases(manifest, 0, [testcase()], 0)
        self.assertFalse(result["complete"])
        self.assertTrue(any("PackageIT" in error for error in result["errors"]))

    def test_parameter_instances_must_not_be_duplicated(self):
        manifest = plan([test_class(methods=("parameters",), kind="template")])
        cases = [testcase("parameters(String)[1]"), testcase("parameters(String)[2]")]
        self.assertTrue(runner.audit_cases(manifest, 0, cases, 0)["complete"])
        self.assertFalse(runner.audit_cases(manifest, 0, cases + cases[:1], 0)["complete"])

    def test_dynamic_factory_and_nested_methods_have_distinct_identities(self):
        cls = test_class(methods=("generated",), kind="template")
        nested = test_class("example.AtestTest$Child", methods=("inside",))["methods"][0]
        cls["methods"].append(nested)
        result = runner.audit_cases(plan([cls]), 0,
                                    [testcase("generated()[1]"), testcase("generated()[2]"), testcase("inside", "example.AtestTest$Child")], 0)
        self.assertTrue(result["complete"], result["errors"])

    def test_static_test_repeated_with_distinct_names_is_not_parameterized(self):
        result = runner.audit_cases(plan(), 0, [testcase("plain()[1]"), testcase("plain()[2]")], 0)
        self.assertFalse(result["complete"])

    def test_unknown_method_and_wrong_plugin_phase_fail(self):
        self.assertFalse(runner.audit_cases(plan(), 0, [testcase("renamed")], 0)["complete"])
        self.assertFalse(runner.audit_cases(plan(), 0, [testcase(phase="failsafe")], 0)["complete"])

    def test_maven_packaging_failure_cannot_be_hidden_by_passing_tests(self):
        self.assertFalse(runner.audit_cases(plan(), 0, [testcase()], 1)["complete"])

    def test_class_fixture_failure_remains_rerunnable(self):
        result = runner.audit_cases(plan(), 0, [testcase("example.AtestTest", status="failed")], 1)
        self.assertEqual(["example.AtestTest"], result["failed_classes"])
        self.assertFalse(result["complete"])

    def test_startup_time_is_retained_and_nested_time_not_counted_twice(self):
        cls = test_class()
        cls["methods"].append(test_class("example.AtestTest$Child", methods=("inside",))["methods"][0])
        case = testcase("inside", "example.AtestTest$Child")
        case["suite_seconds"] = 30.0
        result = runner.audit_cases(plan([cls]), 0, [testcase(), case], 0)
        self.assertEqual(90.0, result["class_seconds"]["example.AtestTest"])

    def test_database_disabled_and_unexplained_skips_fail(self):
        cls = test_class(gates=("UTEN_RUN_DB_TESTS",))
        case = testcase(status="skipped", reason="Environment variable [UTEN_RUN_DB_TESTS] does not exist")
        self.assertFalse(runner.audit_cases(plan([cls]), 0, [case], 0)["complete"])
        self.assertFalse(runner.audit_cases(plan(), 0, [testcase(status="skipped", reason="disabled temporarily")], 0)["complete"])

    def test_optional_skip_requires_exact_declared_gate_and_reason(self):
        gate = "UTEN_RUN_PRODUCTION_STRESS"
        case = testcase(status="skipped", reason=f"Environment variable [{gate}] does not exist")
        allowed = runner.audit_cases(plan([test_class(gates=(gate,))]), 0, [case], 0)
        self.assertTrue(allowed["complete"])
        self.assertTrue(allowed["skipped"][0]["permitted"])
        self.assertFalse(runner.audit_cases(plan(), 0, [case], 0)["complete"])


class EvidenceTests(unittest.TestCase):
    def test_missing_duplicate_stale_and_focused_reports_fail(self):
        manifest = plan()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertFalse(runner.verify_reports(manifest, root)["complete"])
            report = save_report(root / "shard-0", manifest, 0, [testcase()])
            self.assertTrue(runner.verify_reports(manifest, root)["complete"])
            report["plan_hash"] = "stale"
            runner.write_json(root / "shard-0" / "report.json", report)
            self.assertFalse(runner.verify_reports(manifest, root)["complete"])
            report["plan_hash"] = manifest["plan_hash"]
            report["coverage"] = "focused-incomplete"
            runner.write_json(root / "shard-0" / "report.json", report)
            self.assertFalse(runner.verify_reports(manifest, root)["complete"])
            save_report(root / "shard-0", manifest, 0, [testcase()])
            save_report(root / "duplicate", manifest, 0, [testcase()])
            self.assertFalse(runner.verify_reports(manifest, root)["complete"])

    def test_xml_reaudited_even_when_report_claims_success(self):
        manifest = plan()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            save_report(root / "shard-0", manifest, 0, [testcase()])
            save_xml(root / "shard-0", [testcase(status="failed")])
            self.assertFalse(runner.verify_reports(manifest, root)["complete"])

    def test_malformed_and_inconsistent_xml_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            directory = root / "surefire-reports"
            directory.mkdir()
            (directory / "TEST-broken.xml").write_text("<testsuite>")
            self.assertTrue(runner.xml_cases(root)[1])
            (directory / "TEST-broken.xml").write_text('<testsuite tests="1" failures="1"><testcase classname="C" name="a"/></testsuite>')
            self.assertTrue(runner.xml_cases(root)[1])

    def test_changed_parameter_instance_is_detected_against_unfiltered_baseline(self):
        manifest = plan([test_class(methods=("parameters",), kind="template")])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            baseline, shards = root / "baseline", root / "shards"
            runner.write_json(baseline / "baseline-plan.json", manifest)
            save_report(baseline / "shard-0", manifest, 0,
                        [testcase("parameters(int)[1]"), testcase("parameters(int)[2]")], unfiltered=True)
            save_report(shards / "shard-0", manifest, 0, [testcase("parameters(int)[1]")])
            self.assertTrue(runner.verify_reports(manifest, shards)["complete"])
            result = runner.compare_evidence(manifest, shards, baseline)
            self.assertFalse(result["complete"])
            self.assertEqual(1, len(result["missing"]))
            save_report(shards / "shard-0", manifest, 0,
                        [testcase("parameters(int)[1]"), testcase("parameters(int)[2]")])
            self.assertTrue(runner.compare_evidence(manifest, shards, baseline)["complete"])

    def test_plan_tampering_or_source_change_fails(self):
        manifest = plan()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "plan.json"
            runner.write_json(path, manifest)
            with patch.object(runner, "source_identity", return_value={**SOURCE, "sha": "changed"}):
                with self.assertRaisesRegex(ValueError, "Source SHA"):
                    runner.checked_plan(path)
            manifest["shards"][0]["classes"] = []
            runner.write_json(path, manifest)
            with self.assertRaisesRegex(ValueError, "hash"):
                runner.checked_plan(path, check_source=False)

    def test_failed_maven_always_emits_report_and_keeps_full_verify_flags(self):
        manifest = plan()
        with tempfile.TemporaryDirectory() as temp, patch.object(runner, "source_identity", return_value=SOURCE), \
                patch.object(runner, "command_log", return_value=7) as command, patch.dict(runner.os.environ, {}, clear=True):
            root = Path(temp)
            self.assertFalse(runner.run_one(manifest, 0, root, "mvn"))
            args = command.call_args.args[0]
            self.assertIn("verify", args)
            self.assertIn("clean", args)
            self.assertIn("-DskipITs=false", args)
            self.assertIn("-DskipTests=false", args)
            self.assertIn("-Djunit.jupiter.execution.parallel.enabled=false", args)
            self.assertTrue(any(argument.startswith("-Duten.test.tmpdir=") for argument in args))
            self.assertEqual("true", command.call_args.args[3]["UTEN_RUN_DB_TESTS"])
            report = runner.read_json(root / "shard-0" / "report.json")
            self.assertEqual(7, report["maven_exit_code"])
            self.assertFalse(report["complete"])
            self.assertTrue((root / "shard-0" / "failsafe-includes.txt").exists())

    def test_baseline_command_really_omits_filters(self):
        manifest = plan()
        with tempfile.TemporaryDirectory() as temp, patch.object(runner, "source_identity", return_value=SOURCE), \
                patch.object(runner, "command_log", return_value=7) as command, patch.dict(runner.os.environ, {}, clear=True):
            runner.run_one(manifest, 0, Path(temp), "mvn", unfiltered=True)
            self.assertFalse(any("includesFile" in argument for argument in command.call_args.args[0]))


class SourceIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "core.autocrlf", "false")
        (self.root / ".gitattributes").write_text("*.txt text eol=lf\n*.bin -text\n")
        (self.root / "source.txt").write_bytes(b"first\n")
        (self.root / "asset.bin").write_bytes(b"\x00\xff\r\n")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.PIPE)

    def identity(self):
        return runner.source_identity(self.root)

    def test_dirty_staged_untracked_and_deleted_content_all_change_identity(self):
        original = self.identity()
        (self.root / "source.txt").write_bytes(b"changed\n")
        dirty = self.identity()
        self.assertNotEqual(original, dirty)
        self.git("add", "source.txt")
        self.assertEqual(dirty, self.identity())
        (self.root / "new.txt").write_bytes(b"new\n")
        added = self.identity()
        self.assertNotEqual(dirty, added)
        self.git("add", "new.txt")
        self.assertEqual(added, self.identity())
        (self.root / "source.txt").unlink()
        removed = self.identity()
        self.assertNotEqual(added, removed)
        self.git("add", "-u")
        self.assertEqual(removed, self.identity())

    def test_git_text_attributes_normalize_checkout_but_preserve_binary_bytes(self):
        original = self.identity()
        (self.root / "source.txt").write_bytes(b"first\r\n")
        self.assertEqual(original, self.identity())
        (self.root / "asset.bin").write_bytes(b"\x00\xff\n")
        self.assertNotEqual(original, self.identity())

    def test_same_content_new_commit_has_different_sha(self):
        original = self.identity()
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "next")
        changed = self.identity()
        self.assertNotEqual(original["sha"], changed["sha"])
        self.assertEqual(original["fingerprint"], changed["fingerprint"])

    @unittest.skipIf(runner.os.name == "nt", "POSIX executable bits are not meaningful on Windows")
    def test_unstaged_executable_mode_change_is_included(self):
        self.git("config", "core.filemode", "true")
        original = self.identity()
        (self.root / "source.txt").chmod(0o755)
        changed = self.identity()
        self.assertNotEqual(original, changed)
        self.git("add", "source.txt")
        self.assertEqual(changed, self.identity())

    def test_index_or_commit_changes_during_identity_capture_are_rejected(self):
        real = subprocess.check_output
        reads = 0
        def changed(command, **kwargs):
            nonlocal reads
            value = real(command, **kwargs)
            if command[1:] == ["rev-parse", "HEAD"]:
                reads += 1
                if reads == 2:
                    return b"changed-sha\n"
            return value
        with patch.object(runner.subprocess, "check_output", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "changed while"):
                self.identity()


class ProgressLoggingTests(unittest.TestCase):
    def test_progress_arrives_before_exit_and_noise_is_retained_only_in_log(self):
        ready = threading.Event()
        class Capture(io.StringIO):
            def write(self, text):
                if "[INFO] Running fixture.ProgressTest" in text:
                    ready.set()
                return super().write(text)
        capture = Capture()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release = root / "release"
            log = root / "maven.log"
            script = ("from pathlib import Path; import sys,time; "
                      "print('SQL_NOISE_kept_on_disk',flush=True); "
                      "print('[INFO] Running fixture.ProgressTest',flush=True); "
                      "deadline=time.monotonic()+5\n"
                      "while not Path(sys.argv[1]).exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
                      "print('[INFO] BUILD SUCCESS',flush=True)\n")
            result = []
            with contextlib.redirect_stdout(capture):
                worker = threading.Thread(target=lambda: result.append(
                    runner.command_log([sys.executable, "-u", "-c", script, str(release)], root, log)))
                worker.start()
                try:
                    self.assertTrue(ready.wait(3), "Expected live progress before child process exits")
                    self.assertTrue(worker.is_alive())
                    self.assertIn("SQL_NOISE_kept_on_disk", log.read_text())
                    self.assertNotIn("SQL_NOISE_kept_on_disk", capture.getvalue())
                finally:
                    release.touch()
                    worker.join(6)
            self.assertEqual([0], result)
            self.assertIn("BUILD SUCCESS", capture.getvalue())
            self.assertIn("BUILD SUCCESS", log.read_text())


class WorkflowGatingTests(unittest.TestCase):
    """Keep optional comparison separate from the mandatory complete-suite gate."""
    @classmethod
    def setUpClass(cls):
        cls.workflow = (runner.ROOT / ".github/workflows/quality.yml").read_text(encoding="utf-8")

    def job(self, name):
        match = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:\n|\Z)",
                          self.workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, f"Missing required workflow job {name}")
        return match.group(1)

    def step(self, job, contains):
        blocks = re.findall(r"^      - (.*?)(?=^      - |\Z)", job, re.MULTILINE | re.DOTALL)
        matches = [block for block in blocks if contains in block]
        self.assertEqual(1, len(matches), f"Expected one step containing {contains}")
        return matches[0]

    def needs(self, job):
        line = re.search(r"^    needs: (.+)$", job, re.MULTILINE)
        self.assertIsNotNone(line)
        return {value.strip() for value in line.group(1).strip("[]").split(",")}

    def gate_script(self):
        block = self.step(self.job("backend-db"), "backend_test_shards.py verify ")
        lines = block.splitlines()
        start = lines.index("        run: |") + 1
        return "\n".join(line[10:] for line in lines[start:] if line.startswith("          "))

    def test_optional_reference_never_disables_any_full_partition(self):
        planning, shards = self.job("backend-plan"), self.job("backend-shards")
        self.assertIn("--shards 4", planning)
        self.assertEqual({"backend-plan"}, self.needs(shards))
        self.assertRegex(shards, r"(?m)^        shard: \[0, 1, 2, 3\]$")
        self.assertRegex(shards, r"(?m)^      fail-fast: false$")
        for job in (planning, shards):
            self.assertNotIn("compare_reference", job)
            self.assertNotRegex(job, r"(?m)^    if:")
            self.assertNotIn("continue-on-error:", job)
        run = self.step(shards, "backend_test_shards.py run ")
        self.assertNotRegex(run, r"(?m)^        if:")
        self.assertIn('UTEN_RUN_DB_TESTS: "true"', run)
        self.assertIn("--shard ${{ matrix.shard }} --output server/target-ci-reports", run)

    def test_ordinary_reference_job_is_an_explicit_successful_noop(self):
        switch = re.search(r"(?m)^      compare_reference:\n(?:        .*\n)*", self.workflow)
        self.assertIsNotNone(switch)
        self.assertIn("        type: boolean\n", switch.group())
        self.assertIn("        default: false\n", switch.group())
        reference = self.job("backend-reference")
        self.assertNotRegex(reference, r"(?m)^    if:")
        self.assertEqual({"backend-plan"}, self.needs(reference))
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.compare_reference", reference)
        noop = self.step(reference, "Additional serial comparison was not requested")
        self.assertIn("if: env.RUN_REFERENCE != 'true'", noop)
        self.assertIn("run: echo ", noop)
        baseline = self.step(reference, "backend_test_shards.py baseline ")
        self.assertIn("if: env.RUN_REFERENCE == 'true'", baseline)
        self.assertIn('UTEN_RUN_DB_TESTS: "true"', baseline)
        self.assertIn("--plan server/target-ci-plan/plan.json --output server/target-ci-reference", baseline)
        self.assertNotIn("continue-on-error:", reference)

    def test_comparison_waits_for_all_producers_and_downloads_same_run_artifacts(self):
        reference, gate = self.job("backend-reference"), self.job("backend-db")
        self.assertEqual({"backend-plan", "backend-shards", "backend-reference"}, self.needs(gate))
        self.assertRegex(gate, r"(?m)^    if: always\(\)$")
        self.assertNotIn("backend_test_shards.py compare ", reference)
        self.assertNotIn("backend-test-results-*", reference)
        self.assertIn("--reports server/target-ci-reports --reference server/target-ci-reference", self.gate_script())
        download = self.step(gate, "name: backend-unfiltered-reference")
        self.assertIn("actions/download-artifact@", download)
        self.assertIn("if: github.event_name == 'workflow_dispatch' && inputs.compare_reference", download)
        self.assertIn("path: server/target-ci-reference", download)
        parallel = self.step(gate, "pattern: backend-test-results-*")
        self.assertIn("path: server/target-ci-reports", parallel)
        self.assertIn("merge-multiple: true", parallel)
        for job in (reference, gate, self.job("backend-shards")):
            self.assertNotIn("run-id:", job, "Evidence must come from this workflow run")
            self.assertNotIn("continue-on-error:", job)

    def test_failures_keep_raw_reference_and_reconciliation_evidence(self):
        reference_upload = self.step(self.job("backend-reference"), "name: backend-unfiltered-reference")
        self.assertIn("actions/upload-artifact@", reference_upload)
        self.assertIn("if: always() && env.RUN_REFERENCE == 'true'", reference_upload)
        self.assertIn("server/target-ci-reference/", reference_upload)
        self.assertIn("!server/target-ci-reference/**/tmp/**", reference_upload)
        for job, marker in (("backend-shards", "name: backend-test-results-"),
                            ("backend-db", "name: backend-test-summary")):
            upload = self.step(self.job(job), marker)
            self.assertIn("if: always()", upload)
            self.assertIn("if-no-files-found: error", upload)
        summary = self.step(self.job("backend-db"), "name: backend-test-summary")
        self.assertIn("server/target-ci-reports/verification.json", summary)
        self.assertIn("server/target-ci-reports/comparison.json", summary)

    def test_fast_lane_also_exercises_build_directory_independence(self):
        self.assertIn("-Duten.build.directory=target-fast verify", self.job("backend-fast"))

    def test_active_web_artifacts_keep_javascript_checks_and_explicit_target(self):
        for name in ("quality.yml", "simple-release.yml", "_unsigned-candidate-build.yml"):
            with self.subTest(workflow=name):
                source = (runner.ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
                commands = [line.strip() for line in source.splitlines() if "flutter build web " in line]
                self.assertEqual(1, len(commands))
                options = commands[0].split()
                for option in ("--release", "--no-pub", "--no-web-resources-cdn", "--no-wasm-dry-run"):
                    self.assertIn(option, options)
                self.assertNotIn("--wasm", options)
        frontend = self.job("frontend")
        self.assertIn("flutter analyze --no-pub", frontend)
        self.assertIn("flutter test --no-pub", frontend)
        self.assertIn("verify-font-assets.ps1", frontend)

    def test_actual_gate_shell_rejects_failed_or_skipped_producers_and_comparison(self):
        gate = self.job("backend-db")
        for variable, job in (("PLAN_RESULT", "backend-plan"), ("PARTITION_RESULT", "backend-shards"),
                              ("REFERENCE_RESULT", "backend-reference")):
            self.assertIn(variable + ": ${{ needs." + job + ".result }}", gate)
        self.assertIn("COMPARE_REFERENCE: ${{ github.event_name == 'workflow_dispatch' && inputs.compare_reference }}", gate)
        bash = shutil.which("bash")
        if runner.os.name == "nt" and shutil.which("git"):
            git_bash = Path(shutil.which("git")).parent.parent / "bin/bash.exe"
            if git_bash.is_file():
                bash = str(git_bash)
        if not bash:
            self.skipTest("Bash is required to execute the actual GitHub gate shell")
        # Stub only the expensive Python commands. Execute the workflow's real Bash
        # conditions and exit propagation, including the producer-result checks.
        stub = '''python3() {
  printf '%s\\n' "$2" >> "$TEST_GATE_TRACE"
  case "$2" in
    verify) return "$VERIFY_EXIT" ;;
    compare) return "$COMPARE_EXIT" ;;
    *) return 99 ;;
  esac
}
'''
        cases = [
            ({"COMPARE_REFERENCE": "false", "COMPARE_EXIT": "99"}, True, ["verify"]),
            ({"COMPARE_REFERENCE": "true"}, True, ["verify", "compare"]),
            ({"VERIFY_EXIT": "1"}, False, ["verify"]),
            ({"COMPARE_REFERENCE": "true", "COMPARE_EXIT": "1"}, False, ["verify", "compare"]),
            ({"PLAN_RESULT": "failure"}, False, ["verify"]),
            ({"PARTITION_RESULT": "failure"}, False, ["verify"]),
            ({"PARTITION_RESULT": "skipped"}, False, ["verify"]),
            ({"REFERENCE_RESULT": "failure"}, False, ["verify"]),
            ({"COMPARE_REFERENCE": "true", "REFERENCE_RESULT": "cancelled"}, False, ["verify", "compare"]),
        ]
        for overrides, success, expected_calls in cases:
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory() as temp:
                environment = {**runner.os.environ, "PLAN_RESULT": "success", "PARTITION_RESULT": "success",
                               "REFERENCE_RESULT": "success", "COMPARE_REFERENCE": "false", "VERIFY_EXIT": "0",
                               "COMPARE_EXIT": "0", "TEST_GATE_TRACE": "trace.txt", **overrides}
                result = subprocess.run([bash, "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", stub + self.gate_script()],
                                        cwd=temp, env=environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(success, result.returncode == 0, result.stderr)
                self.assertEqual(expected_calls, (Path(temp) / "trace.txt").read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
