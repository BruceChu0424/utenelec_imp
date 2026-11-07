"""Offline protocol corruption and whole-file execution boundary regressions."""
import copy
import base64
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import flutter_test_shards as runner
import backend_test_shards

SOURCE = {"sha": "a" * 40, "fingerprint": "b" * 64}
CI = {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"}


def events(files, root, platform="vm"):
    result = [{"type": "start", "time": 0, "protocolVersion": "0.1.1", "runnerVersion": None}]
    metadata = {"skip": False, "skipReason": None}
    for number, file in enumerate(files):
        base = number * 10
        result.extend([
            {"type": "suite", "time": base + 1, "suite": {"id": base, "platform": platform, "path": str(root / file)}},
            {"type": "testStart", "time": base + 2, "test": {"id": base + 1, "suiteID": base, "name": "loading " + file, "groupIDs": [], "metadata": metadata}},
            {"type": "testDone", "time": base + 3, "testID": base + 1, "result": "success", "skipped": False, "hidden": True},
            {"type": "group", "time": base + 4, "group": {"id": base + 2, "suiteID": base, "parentID": None, "name": "", "testCount": 1, "metadata": metadata}},
            {"type": "testStart", "time": base + 5, "test": {"id": base + 3, "suiteID": base, "name": "generated instance", "groupIDs": [base + 2], "metadata": metadata}},
            {"type": "testDone", "time": base + 6, "testID": base + 3, "result": "success", "skipped": False, "hidden": False},
        ])
    result.extend([{"type": "allSuites", "time": len(files) * 10, "count": len(files)},
                   {"type": "done", "time": len(files) * 10 + 1, "success": True}])
    return copy.deepcopy(result)


class FlutterEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "test/nested").mkdir(parents=True)
        (self.root / "test/a_test.dart").write_text("void main() {}", encoding="utf-8")
        (self.root / "test/nested/b_test.dart").write_text("void main() {}", encoding="utf-8")
        (self.root / ".gitignore").write_text("/test/.uten-ci-codec-worker.js\n", encoding="utf-8")
        self.events_file = self.root / "machine.jsonl"
        self.reports = self.root / runner.REPORT_ROOT
        self.addCleanup(patch.stopall)
        patch.object(runner, "source_identity", return_value=SOURCE).start()
        patch.object(runner, "ci_identity", return_value=CI).start()
        patch.object(runner, "BROWSER_FILES", ()).start()
        # CI's checkout SHA belongs to the real repository. Keep the same
        # production gate active with the identity owned by this fixture.
        patch.dict(os.environ, {"GITHUB_SHA": SOURCE["sha"]}).start()

    def plan(self, count=2):
        return runner.make_plan(runner.inventory(self.root), count, {}, SOURCE)

    def write_events(self, rows):
        self.events_file.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
        return self.events_file

    def parse(self, rows, files=("test/a_test.dart",)):
        return runner.parse_events(self.write_events(rows), files, self.root)

    def save_reports(self, plan):
        cohorts = [(shard, "vm", runner.COMMAND_OPTIONS) for shard in plan["shards"]]
        if plan["browser_files"]:
            cohorts.append(({"id": "browser", "files": plan["browser_files"]}, "chrome", runner.BROWSER_OPTIONS))
        for shard, mode, options in cohorts:
            directory = self.reports / f"shard-{shard['id']}"
            directory.mkdir(parents=True)
            raw = directory / "machine.jsonl"
            skips = [row["path"] for row in plan["files"] if mode == "vm" and row["vm_platform_skip"] and row["path"] in shard["files"]]
            raw.write_text("\n".join(json.dumps(row) for row in events([file for file in shard["files"] if file not in skips], self.root, mode)) + "\n", encoding="utf-8")
            (directory / "stderr.log").write_text("", encoding="utf-8")
            (directory / "stdout.log").write_text("00:01 +1: All tests passed!\n", encoding="utf-8")
            report = {"schema_version": runner.VERSION, "source": SOURCE, "source_after": SOURCE, "ci": CI, "mode": mode,
                      "plan_hash": plan["plan_hash"], "shard": shard["id"], "files": shard["files"],
                      "command": ["flutter", *options, runner.file_reporter_option(shard["id"]), *shard["files"]],
                      "command_prefix": ["flutter"],
                      "sdk": {"frameworkVersion": runner.FLUTTER_VERSION}, "exit_code": 0, "complete": True,
                      "machine_sha256": runner.sha256(raw), "stdout_sha256": runner.sha256(directory / "stdout.log"), "stderr_sha256": runner.sha256(directory / "stderr.log"),
                      "results": runner.parse_events(raw, shard["files"], self.root, skips, mode)}
            if mode == "chrome":
                prefix, tool, _ = self.isolated_tool()
                report.update(command_prefix=prefix,
                              command=[*prefix, *options, runner.file_reporter_option(shard["id"]), *shard["files"]],
                              isolated_tool=tool)
                report["sdk"]["frameworkRevision"] = runner.web_tools.SDK_REVISION
                report["worker"] = {**runner.verify_worker(self.root), "verified_after": True}
            runner.write_json(directory / "report.json", report)

    def isolated_tool(self, *unused):
        tools = runner.web_tools
        sdk = self.root / "sdk"
        private = self.root / "build/flutter-ci-tools/protocol"
        dart = sdk / ("bin/cache/dart-sdk/bin/dart.exe" if os.name == "nt" else "bin/cache/dart-sdk/bin/dart")
        prefix = [str(dart), "--packages=" + str(private / "package_config.json"), str(private / "flutter_tools_private.snapshot")]
        inputs = {"version": tools.VERSION, "sdk_revision": tools.SDK_REVISION, "sdk_root": str(sdk),
                  "sdk_source_normalized_sha256": tools.SDK_SOURCE_SHA256,
                  "bootstrap_sha256": tools.sha256(tools.__file__),
                  "asset_fragment_sha256": tools.sha256(tools.ASSET_FRAGMENT),
                  "patched_source_sha256": "5" * 64,
                  "sdk_inputs": {"packages/flutter_tools/" + tools.SDK_SOURCE: tools.SDK_SOURCE_SHA256,
                                 "packages/flutter_tools/.dart_tool/package_config.json": "2" * 64}}
        evidence = {"kind": "isolated-pinned-web-test-tools", "inputs": inputs,
                    "files": {"package_config.json": "3" * 64, "flutter_tools_private.snapshot": "4" * 64,
                              "framework/" + tools.SDK_SOURCE: "5" * 64},
                    "command_prefix": prefix, "sdk_inputs_after": inputs["sdk_inputs"], "sdk_unchanged": True}
        return prefix, evidence, dict(os.environ)

    def native_process_output(self, command, options, raw):
        reporter = [argument for argument in command if argument.startswith("--file-reporter=")]
        self.assertEqual(1, len(reporter))
        self.assertNotIn("--machine", command)
        self.assertEqual(["--reporter", "expanded"], command[command.index("--reporter"):command.index("--reporter") + 2])
        machine = self.root / reporter[0].removeprefix("--file-reporter=json:")
        machine.write_text(raw, encoding="utf-8")
        options["stdout"].write(b"00:01 +1: Native expanded diagnostics and stack trace\n")

    def test_exact_sdk_file_suffix_recursion_and_non_test_files(self):
        (self.root / "test/nested/helper.dart").write_text("", encoding="utf-8")
        (self.root / "hit_test.dart").write_text("", encoding="utf-8")
        self.assertEqual(["test/a_test.dart", "test/nested/b_test.dart"], [row["path"] for row in runner.inventory(self.root)])

    def test_balance_uses_duration_then_bytes_without_parsing_test_declarations(self):
        for i in range(10):
            (self.root / f"test/generated{i}_test.dart").write_text("// no guessed test count" * (i + 1), encoding="utf-8")
        files = runner.inventory(self.root)
        plan = runner.make_plan(files, 8, {"durations_seconds": {"test/a_test.dart": 100}}, SOURCE)
        runner.validate_plan(plan, self.root)
        assigned = [file for shard in plan["shards"] for file in shard["files"]]
        self.assertEqual(sorted(row["path"] for row in files), sorted(assigned))
        self.assertEqual(8, len(plan["shards"]))
        self.assertTrue(all(shard["files"] for shard in plan["shards"]))
        self.assertEqual("historical_seconds", next(row for row in plan["files"] if row["path"] == "test/a_test.dart")["weight_source"])

    def test_duplicate_omitted_empty_and_filtered_plans_are_rejected(self):
        for change in ("duplicate", "omitted", "empty", "filter", "boolean_id"):
            with self.subTest(change=change):
                plan = self.plan()
                if change == "duplicate": plan["shards"][1]["files"] = plan["shards"][0]["files"][:]
                elif change == "omitted": plan["files"].pop()
                elif change == "empty": plan["shards"][1]["files"] = []
                elif change == "boolean_id": plan["shards"][0]["id"] = False
                else: plan["command_options"].extend(["--tags", "fast"])
                plan["plan_hash"] = runner.digest({k: v for k, v in plan.items() if k != "plan_hash"})
                with self.assertRaises(ValueError): runner.validate_plan(plan, self.root)

    def test_wrong_sha_changed_content_or_workflow_attempt_rejects_plan(self):
        with patch.dict(os.environ, {"GITHUB_SHA": "c" * 40}), self.assertRaisesRegex(ValueError, "target SHA"):
            runner.validate_plan(self.plan(), self.root)
        for source in ({"sha": "c" * 40, "fingerprint": SOURCE["fingerprint"]}, {"sha": SOURCE["sha"], "fingerprint": "d" * 64}):
            with patch.object(runner, "source_identity", return_value=source), self.assertRaises(ValueError):
                runner.validate_plan(self.plan(), self.root)
        plan = self.plan()
        (self.root / "test/a_test.dart").write_text("changed", encoding="utf-8")
        with self.assertRaises(ValueError): runner.validate_plan(plan, self.root)
        with patch.object(runner, "ci_identity", return_value={**CI, "GITHUB_RUN_ATTEMPT": "3"}), self.assertRaises(ValueError):
            runner.validate_plan(plan, self.root)

    def test_verified_browser_worker_copy_preserves_the_real_planned_git_identity(self):
        runner.BROWSER_FILES = ("test/browser_test.dart",)
        (self.root / "test/browser_test.dart").write_text("@TestOn('browser')\nlibrary;\nvoid main() {}", encoding="utf-8")
        (self.root / "web").mkdir()
        source = self.root / runner.WORKER_SOURCE
        source.write_text("reviewed worker bytes", encoding="utf-8")
        def git(*arguments):
            return subprocess.run(["git", "-C", str(self.root), *arguments], check=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        git("init", "-q")
        git("config", "user.name", "CI fixture")
        git("config", "user.email", "ci-fixture@example.invalid")
        git("config", "core.autocrlf", "false")
        git("add", ".")
        git("commit", "-qm", "source fixture")
        before = backend_test_shards.source_identity(self.root)
        with patch.object(runner, "source_identity", backend_test_shards.source_identity), patch.dict(os.environ, {"GITHUB_SHA": before["sha"]}):
            plan = runner.make_plan(runner.inventory(self.root), 1, {}, before)
            worker = self.root / runner.WORKER_PATH
            worker.write_bytes(source.read_bytes())
            self.assertEqual(before, backend_test_shards.source_identity(self.root))
            runner.validate_plan(plan, self.root)
            self.assertEqual(runner.sha256(source), runner.verify_worker(self.root)["sha256"])
            worker.write_text("changed worker bytes", encoding="utf-8")
            with self.assertRaises(ValueError): runner.verify_worker(self.root)
            worker.unlink()
            worker.symlink_to(source)
            with self.assertRaises(ValueError): runner.verify_worker(self.root)
            worker.unlink()
            worker.write_bytes(source.read_bytes())
            (self.root / "test/other_generated_worker.js").write_text("other source bytes", encoding="utf-8")
            self.assertNotEqual(before, backend_test_shards.source_identity(self.root))
            with self.assertRaises(ValueError): runner.validate_plan(plan, self.root)

    def test_source_owned_browser_selector_is_separate_from_completed_vm_files(self):
        browser = self.root / "test/browser_test.dart"
        browser.write_text("@TestOn('browser')\nlibrary;\nvoid main() {}", encoding="utf-8")
        runner.BROWSER_FILES = ("test/browser_test.dart",)
        plan = self.plan()
        self.assertTrue(next(row for row in plan["files"] if row["path"] == "test/browser_test.dart")["vm_platform_skip"])
        raw = self.write_events(events(["test/a_test.dart"], self.root))
        result = runner.parse_events(raw, ["test/a_test.dart", "test/browser_test.dart"], self.root, ["test/browser_test.dart"])
        self.assertEqual(["test/browser_test.dart"], result["platform_skipped_files"])
        with self.assertRaises(ValueError): runner.parse_events(raw, ["test/a_test.dart", "test/nested/b_test.dart"], self.root)

    def test_forged_platform_skip_without_the_actual_library_declaration_is_rejected(self):
        plan = self.plan()
        plan["files"][0]["vm_platform_skip"] = True
        plan["plan_hash"] = runner.digest({k: v for k, v in plan.items() if k != "plan_hash"})
        with self.assertRaises(ValueError): runner.validate_plan(plan, self.root)

    def test_comments_strings_and_unknown_selectors_cannot_authorize_a_missing_vm_suite(self):
        for text in ("// @TestOn('browser')\nlibrary;", 'const text = "@TestOn(\'browser\') library;";',
                     "/* @TestOn('browser') */\nlibrary;", "@TestOn('unknown')\nlibrary;",
                     "@TestOn('browser')\nconst fake = 'library;';"):
            with self.subTest(source=text):
                (self.root / "test/a_test.dart").write_text(text, encoding="utf-8")
                row = next(row for row in runner.inventory(self.root) if row["path"] == "test/a_test.dart")
                self.assertFalse(row["vm_platform_skip"])
                with self.assertRaises(ValueError):
                    self.parse(events(["test/nested/b_test.dart"], self.root),
                               ["test/a_test.dart", "test/nested/b_test.dart"])

    def test_browser_declaration_does_not_hide_an_omitted_regular_file_or_an_empty_success(self):
        raw = self.write_events(events(["test/a_test.dart"], self.root))
        with self.assertRaises(ValueError):
            runner.parse_events(raw, ["test/a_test.dart", "test/nested/b_test.dart", "test/browser_test.dart"],
                                self.root, ["test/browser_test.dart"])
        rows = [{"type": "start", "time": 0, "protocolVersion": "0.1.1"},
                {"type": "allSuites", "time": 0, "count": 0}, {"type": "done", "time": 1, "success": True}]
        with self.assertRaises(ValueError): self.parse(rows)
        declared = events(["test/a_test.dart"], self.root)
        declared[5]["test"]["metadata"] = {"skip": True, "skipReason": "original declared skip"}
        declared[6]["skipped"] = True
        with self.assertRaises(ValueError): self.parse(declared, ["test/a_test.dart", "test/nested/b_test.dart"])

    def test_runtime_group_inventory_and_complete_test_lifecycles(self):
        result = self.parse(events(["test/a_test.dart"], self.root))
        self.assertEqual(1, result["testcase_count"])
        self.assertEqual([], result["skipped"])
        self.assertTrue(result["complete"])

    def test_malformed_truncated_cancelled_error_and_protocol_streams_cannot_pass(self):
        original = events(["test/a_test.dart"], self.root)
        variants = [original[:-1], original[1:], original + [original[-1]],
                    original[:-1] + [{**original[-1], "success": None}],
                    [{**original[0], "protocolVersion": "other"}, *original[1:]],
                    original[:-1] + [{"type": "error", "time": 10, "testID": 3, "isFailure": False}, original[-1]],
                    [row for row in original if not (row["type"] == "testDone" and row["testID"] == 3)],
                    [({**row, "result": "error"} if row["type"] == "testDone" and row["testID"] == 3 else row) for row in original],
                    [({**row, "count": 99} if row["type"] == "allSuites" else row) for row in original]]
        for variant in variants:
            with self.subTest(stream=variant), self.assertRaises(ValueError): self.parse(variant)
        self.events_file.write_text('not JSON\n', encoding="utf-8")
        with self.assertRaises(ValueError): runner.parse_events(self.events_file, ["test/a_test.dart"], self.root)

    def test_root_group_detects_a_missing_test_even_when_remaining_pairs_and_done_look_successful(self):
        rows = events(["test/a_test.dart"], self.root)
        rows = [row for row in rows if not (row["type"] == "testStart" and row["test"]["id"] == 3)
                and not (row["type"] == "testDone" and row["testID"] == 3)]
        with self.assertRaisesRegex(ValueError, "runtime root-group"): self.parse(rows)

    def test_duplicate_ids_done_and_foreign_file_or_group_ownership_are_rejected(self):
        original = events(["test/a_test.dart"], self.root)
        variants = [original[:6] + [original[5]] + original[6:], original[:2] + [original[1]] + original[2:]]
        for kind in ("foreign", "group"):
            rows = copy.deepcopy(original)
            if kind == "foreign": rows[1]["suite"]["path"] = str(self.root / "test/not_assigned_test.dart")
            else: rows[5]["test"]["groupIDs"] = [999]
            variants.append(rows)
        for variant in variants:
            with self.subTest(stream=variant), self.assertRaises(ValueError): self.parse(variant)

    def test_declared_and_runtime_skip_reasons_are_retained_but_unexplained_skip_is_not_success(self):
        rows = events(["test/a_test.dart"], self.root)
        rows[6]["skipped"] = True
        with self.assertRaisesRegex(ValueError, "skip without"): self.parse(rows)
        rows[5]["test"]["metadata"] = {"skip": True, "skipReason": "original declaration"}
        self.assertEqual("original declaration", self.parse(rows)["skipped"][0]["reason"])
        rows[5]["test"]["metadata"] = {"skip": False, "skipReason": None}
        rows.insert(6, {"type": "print", "time": 5, "testID": 3, "messageType": "skip", "message": "original runtime reason"})
        self.assertEqual("original runtime reason", self.parse(rows)["skipped"][0]["reason"])

    def test_only_the_sdk_process_start_array_can_mix_with_json_reporter_events(self):
        rows = events(["test/a_test.dart"], self.root)
        rows.insert(3, [{"event": "test.startedProcess", "params": {"vmServiceUri": None}}])
        self.assertTrue(self.parse(rows)["complete"])
        rows[3][0]["event"] = "tool.error"
        with self.assertRaises(ValueError): self.parse(rows)

    def test_all_reports_are_reconciled_fresh_from_the_same_source_and_native_events(self):
        plan = self.plan()
        self.save_reports(plan)
        result = runner.verify_reports(plan, self.reports, self.root)
        self.assertEqual(2, result["file_count"])
        self.assertEqual(2, result["testcase_count"])
        self.assertEqual(0, result["skipped_count"])

    def test_nonzero_exit_false_zero_wrong_sha_wrong_sdk_attempt_and_filtered_commands_fail(self):
        plan = self.plan()
        self.save_reports(plan)
        path = self.reports / "shard-0/report.json"
        original = runner.read_json(path)
        for field, value in (("exit_code", 1), ("exit_code", False), ("complete", False), ("shard", False),
                             ("source", {**SOURCE, "sha": "c" * 40}), ("source_after", {**SOURCE, "fingerprint": "c" * 64}),
                             ("ci", {**CI, "GITHUB_RUN_ATTEMPT": "1"}), ("sdk", {"frameworkVersion": "other"}),
                             ("command", ["flutter", *runner.COMMAND_OPTIONS, "--name", "fast", *original["files"]])):
            with self.subTest(field=field, value=value):
                runner.write_json(path, {**original, field: value})
                with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)
        runner.write_json(path, original)

    def test_missing_extra_or_cross_owned_report_files_cannot_pass(self):
        plan = self.plan()
        self.save_reports(plan)
        report = self.reports / "shard-0/report.json"
        report.rename(report.with_name("missing.json"))
        with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)
        report.with_name("missing.json").rename(report)
        (self.reports / "shard-8").mkdir()
        with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)

    def test_modified_raw_output_or_false_producer_success_is_rejected(self):
        plan = self.plan()
        self.save_reports(plan)
        raw = self.reports / "shard-0/machine.jsonl"
        raw.write_text(raw.read_text(encoding="utf-8") + 'broken\n', encoding="utf-8")
        with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)
        report = self.reports / "shard-0/report.json"
        value = runner.read_json(report)
        runner.write_json(report, {**value, "machine_sha256": runner.sha256(raw)})
        with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)

    def test_tool_error_on_stderr_is_not_hidden_by_a_successful_machine_summary(self):
        plan = self.plan()
        self.save_reports(plan)
        stderr = self.reports / "shard-0/stderr.log"
        stderr.write_text("Unhandled exception: tool failure\n", encoding="utf-8")
        report = self.reports / "shard-0/report.json"
        value = runner.read_json(report)
        runner.write_json(report, {**value, "stderr_sha256": runner.sha256(stderr)})
        with self.assertRaisesRegex(ValueError, "tool error"): runner.verify_reports(plan, self.reports, self.root)

    def test_process_launch_failure_still_has_a_failed_structured_report(self):
        plan = self.plan()
        with patch.object(runner.subprocess, "run", side_effect=OSError("synthetic launch failure")):
            result = runner.run_shard(plan, 0, self.reports, root=self.root)
        self.assertFalse(result["complete"])
        self.assertIsNone(result["exit_code"])
        self.assertTrue((self.reports / "shard-0/report.json").is_file())

    def test_one_execution_keeps_expanded_stdout_and_native_json_with_independent_hashes(self):
        plan = self.plan()
        def process(command, **options):
            if "--version" in command:
                return subprocess.CompletedProcess(command, 0, json.dumps({"frameworkVersion": runner.FLUTTER_VERSION}), "")
            raw = "\n".join(json.dumps(row) for row in events(plan["shards"][0]["files"], self.root)) + "\n"
            self.native_process_output(command, options, raw)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(runner.subprocess, "run", side_effect=process) as launches:
            report = runner.run_shard(plan, 0, self.reports, root=self.root)
        self.assertTrue(report["complete"], report)
        self.assertEqual(1, sum("--version" not in call.args[0] for call in launches.call_args_list))
        self.assertEqual(1, report["results"]["testcase_count"])
        directory = self.reports / "shard-0"
        self.assertIn("stack trace", (directory / "stdout.log").read_text())
        self.assertEqual(runner.sha256(directory / "stdout.log"), report["stdout_sha256"])
        self.assertNotEqual(report["stdout_sha256"], report["machine_sha256"])

    def test_reporter_arguments_cannot_be_removed_redirected_duplicated_or_filtered(self):
        plan = self.plan(); self.save_reports(plan)
        path = self.reports / "shard-0/report.json"; original = runner.read_json(path)
        for reporter in ([], ["--file-reporter=json:../../source"],
                         [runner.file_reporter_option(1)], [runner.file_reporter_option(0)] * 2,
                         [runner.file_reporter_option(0), "--name", "fast"]):
            command = ["flutter", *runner.COMMAND_OPTIONS, *reporter, *original["files"]]
            with self.subTest(command=command):
                runner.write_json(path, {**original, "command": command})
                with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)

    def test_output_path_cannot_escape_the_fixed_ignored_report_root(self):
        plan = self.plan()
        for output in (self.root / "outside", "build/other", "build/flutter-ci-reports/../outside",
                       "build/flutter-ci-reports&filter", "../outside"):
            with self.subTest(output=output), patch.object(runner.subprocess, "run") as launch:
                with self.assertRaisesRegex(ValueError, "fixed report root"):
                    runner.run_shard(plan, 0, output, root=self.root)
                launch.assert_not_called()
        self.assertFalse(self.reports.exists())

    def test_missing_tampered_or_linked_stdout_cannot_supply_evidence(self):
        plan = self.plan(); self.save_reports(plan)
        directory = self.reports / "shard-0"; stdout = directory / "stdout.log"
        original = stdout.read_bytes(); stdout.unlink()
        with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)
        stdout.write_text("forged human success", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "tampered"): runner.verify_reports(plan, self.reports, self.root)
        stdout.write_bytes(original)
        target = self.root / "forged.log"; target.write_bytes(original); stdout.unlink()
        try:
            stdout.symlink_to(target)
        except OSError as error:
            self.skipTest(str(error))
        with self.assertRaisesRegex(ValueError, "linked/special"): runner.verify_reports(plan, self.reports, self.root)

    def test_linked_output_parent_is_rejected_before_the_sdk_runs(self):
        plan = self.plan(); target = self.root / "outside"; target.mkdir()
        try:
            (self.root / "build").symlink_to(target, target_is_directory=True)
        except OSError as error:
            self.skipTest(str(error))
        with patch.object(runner.subprocess, "run") as launch:
            with self.assertRaisesRegex(ValueError, "linked/special"):
                runner.run_shard(plan, 0, self.reports, root=self.root)
            launch.assert_not_called()
        self.assertEqual([], list(target.iterdir()))

    def test_nonzero_tool_exit_cannot_become_success_even_with_complete_native_events(self):
        plan = self.plan()
        def process(command, **options):
            if "--version" in command:
                return subprocess.CompletedProcess(command, 0, json.dumps({"frameworkVersion": runner.FLUTTER_VERSION}), "")
            raw = "\n".join(json.dumps(row) for row in events(plan["shards"][0]["files"], self.root)) + "\n"
            self.native_process_output(command, options, raw)
            return subprocess.CompletedProcess(command, 7)
        with patch.object(runner.subprocess, "run", side_effect=process):
            report = runner.run_shard(plan, 0, self.reports, root=self.root)
        self.assertFalse(report["complete"])
        self.assertEqual(7, report["exit_code"])
        self.assertTrue(report["results"]["complete"])

    def test_cli_has_no_test_name_tag_run_skipped_or_case_shard_bypass(self):
        for flag in ("--name", "--plain-name", "--tags", "--exclude-tags", "--run-skipped", "--total-shards", "--reporter", "--file-reporter", "--machine"):
            with patch.object(sys, "argv", ["tool", "run", "--plan", "x", "--shard", "0", flag, "value"]), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                runner.main()
            self.assertEqual(2, failure.exception.code)

    def browser_plan(self):
        runner.BROWSER_FILES = ("test/a_test.dart", "test/nested/b_test.dart")
        (self.root / "test/nested/b_test.dart").write_text("@TestOn('browser')\nlibrary;\nvoid main() {}", encoding="utf-8")
        (self.root / "web").mkdir()
        (self.root / runner.WORKER_SOURCE).write_text("reviewed worker bytes", encoding="utf-8")
        (self.root / runner.WORKER_PATH).write_bytes((self.root / runner.WORKER_SOURCE).read_bytes())
        return self.plan(1)

    def test_every_vm_inapplicable_file_must_belong_to_the_fixed_browser_cohort(self):
        plan = self.browser_plan()
        runner.validate_plan(plan, self.root)
        for change in ("missing", "duplicate", "filter", "unknown"):
            invalid = copy.deepcopy(plan)
            if change == "missing": invalid["browser_files"].pop()
            elif change == "duplicate": invalid["browser_files"].append(invalid["browser_files"][0])
            elif change == "filter": invalid["browser_options"].extend(["--name", "only one"])
            else: invalid["browser_files"].append("test/unknown_test.dart")
            invalid["plan_hash"] = runner.digest({k: v for k, v in invalid.items() if k != "plan_hash"})
            with self.subTest(change=change), self.assertRaises(ValueError): runner.validate_plan(invalid, self.root)
        runner.BROWSER_FILES = ("test/a_test.dart",)
        with self.assertRaisesRegex(ValueError, "every VM-inapplicable"):
            runner.validate_plan(self.plan(1), self.root)

    def test_browser_evidence_closes_vm_platform_exceptions_and_allows_explicit_dual_platform_file(self):
        plan = self.browser_plan()
        self.save_reports(plan)
        result = runner.verify_reports(plan, self.reports, self.root)
        self.assertEqual(["test/nested/b_test.dart"], result["browser_only_files"])
        self.assertEqual(list(runner.BROWSER_FILES), result["browser"]["files"])
        self.assertEqual(3, result["testcase_count"])
        self.assertEqual(2, result["executed_file_count"])
        self.assertEqual(1, result["vm_file_count"])
        self.assertEqual(2, result["browser_file_count"])
        self.assertEqual(["test/a_test.dart"], result["dual_platform_files"])
        self.assertEqual(["test/nested/b_test.dart"], result["shards"][0]["platform_skipped_files"])

    def test_missing_browser_report_wrong_sha_or_platform_nonzero_and_filters_fail(self):
        plan = self.browser_plan()
        self.save_reports(plan)
        report = self.reports / "shard-browser/report.json"
        original = runner.read_json(report)
        for field, value in (("exit_code", 1), ("mode", "vm"), ("source", {**SOURCE, "sha": "c" * 40}),
                             ("files", original["files"][:1]), ("worker", None),
                             ("command", ["flutter", *runner.BROWSER_OPTIONS, "--tags", "fast", *original["files"]])):
            with self.subTest(field=field):
                runner.write_json(report, {**original, field: value})
                with self.assertRaises(ValueError): runner.verify_reports(plan, self.reports, self.root)
        runner.write_json(report, original)
        shutil.rmtree(report.parent)
        with self.assertRaisesRegex(ValueError, "missing, duplicate"):
            runner.verify_reports(plan, self.reports, self.root)

    def test_browser_file_with_only_declared_skips_is_not_actual_browser_coverage(self):
        plan = self.browser_plan()
        self.save_reports(plan)
        directory = self.reports / "shard-browser"
        rows = events(plan["browser_files"], self.root, "chrome")
        rows[5]["test"]["metadata"] = {"skip": True, "skipReason": "declaration"}
        rows[6]["skipped"] = True
        raw = directory / "machine.jsonl"
        raw.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
        report = runner.read_json(directory / "report.json")
        report.update(machine_sha256=runner.sha256(raw), results=runner.parse_events(raw, plan["browser_files"], self.root, platform="chrome"))
        runner.write_json(directory / "report.json", report)
        with self.assertRaisesRegex(ValueError, "without real non-skipped"):
            runner.verify_reports(plan, self.reports, self.root)

    def test_worker_is_verified_before_and_after_browser_execution(self):
        plan = self.browser_plan()
        def process(command, **options):
            if "--version" in command:
                return subprocess.CompletedProcess(command, 0, json.dumps({"frameworkVersion": runner.FLUTTER_VERSION}), "")
            self.assertEqual([*runner.BROWSER_OPTIONS, runner.file_reporter_option("browser"), *plan["browser_files"]], command[3:])
            raw = "\n".join(json.dumps(row) for row in events(plan["browser_files"], self.root, "chrome")) + "\n"
            self.native_process_output(command, options, raw)
            (self.root / runner.WORKER_PATH).write_text("tampered", encoding="utf-8")
            return subprocess.CompletedProcess(command, 0)
        with patch.object(runner.subprocess, "run", side_effect=process), \
                patch.object(runner.web_tools, "prepare", side_effect=self.isolated_tool), \
                patch.object(runner.web_tools, "confirm_sdk_unchanged"):
            report = runner.run_browser(plan, self.reports, root=self.root)
        self.assertFalse(report["complete"])
        self.assertIn("worker", report["error"])
        shutil.rmtree(self.reports)
        with patch.object(runner.subprocess, "run") as launch:
            report = runner.run_browser(plan, self.reports, root=self.root)
        launch.assert_not_called()
        self.assertFalse(report["complete"])

    def test_browser_stream_cannot_reuse_a_vm_result(self):
        self.browser_plan()
        with self.assertRaisesRegex(ValueError, "foreign platform"):
            runner.parse_events(self.write_events(events(list(runner.BROWSER_FILES), self.root)), runner.BROWSER_FILES,
                                self.root, platform="chrome")

    def test_browser_cli_rejects_arbitrary_file_arguments_and_skip_controls(self):
        for arguments in (("--name", "x"), ("--tags", "x"), ("--run-skipped",), ("test/a_test.dart",), ("--platform", "vm")):
            with patch.object(sys, "argv", ["tool", "browser", "--plan", "x", *arguments]), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                runner.main()
            self.assertEqual(2, failure.exception.code)


class FlutterWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (runner.ROOT / ".github/workflows/quality.yml").read_text(encoding="utf-8")

    def job(self, name):
        return re.search(r"(?ms)^  " + re.escape(name) + r":\n.*?(?=^  [a-z][a-z0-9-]*:|\Z)", self.source).group()

    def test_browser_contract_reaches_the_required_environment_as_exact_shared_bytes(self):
        prefix = "--dart-define=SUBCONTRACT_RECEIPT_CONTRACT_BASE64="
        values = [value[len(prefix):] for value in runner.BROWSER_OPTIONS if value.startswith(prefix)]
        self.assertEqual(1, len(values))
        self.assertEqual((runner.ROOT / runner.BROWSER_CONTRACT).read_bytes(),
                         base64.b64decode(values[0], validate=True))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                runner.subcontract_browser_contract_define(root)
            fixture = root / runner.BROWSER_CONTRACT
            fixture.parent.mkdir(parents=True)
            fixture.write_text('{"schemaVersion":1,"vectors":[]}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "shared subcontract browser contract"):
                runner.subcontract_browser_contract_define(root)

    def test_master_reference_browser_define_preserves_the_canonical_permission_vectors(self):
        prefix = "--dart-define=BUSINESS_MASTER_REFERENCE_CONTRACT_BASE64="
        values = [value[len(prefix):] for value in runner.BROWSER_OPTIONS if value.startswith(prefix)]
        self.assertEqual(1, len(values))
        self.assertEqual((runner.ROOT / runner.MASTER_REFERENCE_CONTRACT).read_bytes(),
                         base64.b64decode(values[0], validate=True))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(FileNotFoundError):
                runner.master_reference_browser_contract_define(root)
            fixture = root / runner.MASTER_REFERENCE_CONTRACT
            fixture.parent.mkdir(parents=True)
            for invalid in ({"version": 1, "goods": {}, "cases": [{}]},
                            {"version": 1, "goods": {"name": "货品"}, "cases": []},
                            {"version": 2, "goods": {"id": "real"}, "cases": [{}]}):
                fixture.write_text(json.dumps(invalid), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "shared master reference browser contract"):
                    runner.master_reference_browser_contract_define(root)
            # Preserve the supplied UTF-8/newline bytes, independently of how
            # JSON validation represents the same document in memory.
            canonical = b'\xef\xbb\xbf' + '{"version":1,"goods":{"name":"货品"},"cases":[{"grants":[]}]}\r\n'.encode("utf-8")
            fixture.write_bytes(canonical)
            encoded = runner.master_reference_browser_contract_define(root)[len(prefix):]
            self.assertEqual(canonical, base64.b64decode(encoded, validate=True))

    def test_complete_vm_inventory_has_eight_non_fail_fast_partitions_and_four_workers(self):
        plan, shards = self.job("frontend-plan"), self.job("frontend-shards")
        self.assertIn("flutter_test_shards.py plan --output build/flutter-ci-plan --shards 8", plan)
        self.assertIn("max-parallel: 4", shards)
        self.assertIn("fail-fast: false", shards)
        self.assertIn("shard: [0, 1, 2, 3, 4, 5, 6, 7]", shards)
        self.assertIn("--shard ${{ matrix.shard }} --output build/flutter-ci-reports", shards)
        self.assertIn("if: always()", shards)
        self.assertNotIn("continue-on-error", shards)

    def test_original_stages_are_independent_and_required_by_the_exact_web_check(self):
        gate = self.job("frontend")
        self.assertIn("name: Flutter / Web\n", gate)
        self.assertIn("if: always()", gate)
        for name in ("plan", "format", "analyze", "issuer", "shards", "browser", "build"):
            self.assertIn("frontend-" + name, gate)
            self.assertIn("needs.frontend-" + name + ".result", gate)
        for name in ("format", "analyze", "issuer", "browser", "build"):
            self.assertNotRegex(self.job("frontend-" + name), r"(?m)^    needs:")
        self.assertIn("dart format --output=none --set-exit-if-changed lib test", self.job("frontend-format"))
        self.assertIn("flutter analyze --no-pub", self.job("frontend-analyze"))
        issuer = self.job("frontend-issuer")
        for name in ("session_backend_owner_race_test.dart", "pending_refresh_revocation_backend_owner_test.dart", "auth_interceptor_backend_issuer_race_test.dart"):
            self.assertIn(name, issuer)
        for value in ("API_BASE_URL=https://lan.uten.test/api", "CLOUD_API_BASE_URL=https://cloud.uten.test/api"):
            self.assertIn(value, issuer)
        browser = self.job("frontend-browser")
        for path in ("web/update_check.test.cjs", "web/maintenance.test.cjs"):
            self.assertIn(path, browser)
        self.assertEqual(("test/shared/drafts/form_draft_storage_browser_test.dart", "test/shared/drafts/form_draft_history_browser_test.dart",
                          "test/device_audit_receipt_storage_web_test.dart", "test/features/production/models/material_quantity_apportionment_test.dart",
                          "test/attachments/attachment_media_preview_browser_test.dart", "test/core/web_update_bridge_browser_test.dart",
                          "test/features/warehouse/subcontract_actual_receipt_browser_test.dart",
                          "test/support/audit_font_asset_loader_test.dart"), runner.BROWSER_FILES)
        self.assertIn("flutter_test_shards.py browser --plan build/flutter-ci-plan/plan.json", browser)
        self.assertIn("name: flutter-test-results-browser", browser)
        self.assertIn("path: build/flutter-ci-reports/", browser)
        self.assertIn("if: always()", browser)
        self.assertIn("trap 'rm -f --", browser)
        self.assertIn("cmp -- web/uten_data_codec_worker.js", browser)
        build = self.job("frontend-build")
        for value in ("verify-font-assets.ps1", "flutter build web --release --no-pub --no-web-resources-cdn --no-wasm-dry-run --dart-define=API_BASE_URL=/api", "release_tools.stamp_web_release", 'commit=os.environ["GITHUB_SHA"]'):
            self.assertIn(value, build)
        self.assertIn("flutter_test_shards.py verify", gate)
        for name in ("PLAN", "FORMAT", "ANALYZE", "ISSUER", "VM", "BROWSER", "BUILD"):
            self.assertIn(f'test "${name}_RESULT" = success', gate)

    def test_preserves_same_sha_runs_and_does_not_cancel_older_checks(self):
        self.assertIn("group: quality-${{ github.sha }}", self.source)
        self.assertIn("cancel-in-progress: false", self.source)

    def test_actual_aggregate_shell_rejects_any_failed_cancelled_or_skipped_original_stage(self):
        gate = self.job("frontend")
        body = gate.split("      - name: Require all original stages", 1)[1].split("      - name:", 1)[0]
        body = body.split("        run: |\n", 1)[1]
        body = "\n".join(line[10:] for line in body.splitlines() if line.startswith("          "))
        verify = "python3 .github/scripts/flutter_test_shards.py verify --plan build/flutter-ci-plan/plan.json --reports build/flutter-ci-reports"
        self.assertIn(verify, body)
        bash = shutil.which("bash")
        if os.name == "nt" and shutil.which("git"):
            candidate = Path(shutil.which("git")).parent.parent / "bin/bash.exe"
            if candidate.is_file(): bash = str(candidate)
        if not bash: self.skipTest("actual bash executable required")
        stages = [name + "_RESULT" for name in ("PLAN", "FORMAT", "ANALYZE", "ISSUER", "VM", "BROWSER", "BUILD")]
        environment = {**os.environ, **dict.fromkeys(stages, "success")}
        def run(text, env):
            return subprocess.run([bash, "-e", "-o", "pipefail", "-c", text], env=env,
                                  capture_output=True, check=False).returncode
        passing = body.replace(verify, "true")
        self.assertEqual(0, run(passing, environment))
        self.assertNotEqual(0, run(body.replace(verify, "false"), environment))
        for name in stages:
            for state in ("failure", "cancelled", "skipped", ""):
                with self.subTest(stage=name, state=state):
                    self.assertNotEqual(0, run(passing, {**environment, name: state}))


if __name__ == "__main__":
    unittest.main()
