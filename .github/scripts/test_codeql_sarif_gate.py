import json
from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import tempfile
import unittest

from check_codeql_sarif import inspect_sarif, main


class CodeqlSarifGateTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, run, name="java.sarif"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"version": "2.1.0", "runs": [run]}), encoding="utf-8")
        return path

    def invoke(self, path):
        output = io.StringIO()
        with redirect_stdout(output), redirect_stderr(output):
            result = main([str(path)])
        self.last_output = output.getvalue()
        return result

    @staticmethod
    def run_with(results):
        return {"tool": {"driver": {"name": "CodeQL"}}, "results": results}

    def test_complete_zero_result_analysis_passes(self):
        path = self.write(self.run_with([]))
        self.assertEqual(self.invoke(path), 0)

    def test_codeql_extension_rule_defaults_are_used(self):
        run = self.run_with([{"ruleId": "java/problem"}])
        run["tool"]["extensions"] = [{"name": "java", "rules": [
            {"id": "java/problem", "defaultConfiguration": {"level": "error"}}]}]
        summary = inspect_sarif(self.write(run))
        self.assertEqual(summary["levels"], {"error": 1})
        self.assertEqual(summary["findings"], 1)

    def test_explicit_component_reference_disambiguates_rule_ids(self):
        run = self.run_with([{"rule": {"id": "shared", "index": 0, "toolComponent": {"index": 0}}}])
        run["tool"]["driver"]["rules"] = [{"id": "shared", "defaultConfiguration": {"level": "note"}}]
        run["tool"]["extensions"] = [{"name": "java", "rules": [
            {"id": "shared", "defaultConfiguration": {"level": "error"}}]}]
        self.assertEqual(inspect_sarif(self.write(run))["levels"], {"error": 1})

    def test_result_level_overrides_rule_default(self):
        run = self.run_with([{"ruleId": "problem", "level": "note"}])
        run["tool"]["driver"]["rules"] = [{"id": "problem", "defaultConfiguration": {"level": "error"}}]
        self.assertEqual(inspect_sarif(self.write(run))["levels"], {"note": 1})

    def test_notes_and_preexisting_suppressions_still_block(self):
        run = self.run_with([{"ruleId": "problem", "level": "note",
                              "suppressions": [{"kind": "external", "status": "accepted"}]}])
        self.assertEqual(self.invoke(self.write(run)), 1)
        self.assertIn("zero are required", self.last_output)

    def test_every_sarif_file_is_reconciled(self):
        self.write(self.run_with([]))
        self.write(self.run_with([{"level": "warning"}]), "nested/second.sarif")
        self.assertEqual(inspect_sarif(self.root)["findings"], 1)
        self.assertEqual(self.invoke(self.root), 1)

    def test_missing_or_empty_analysis_cannot_pass_as_zero(self):
        with self.assertRaises(ValueError):
            inspect_sarif(self.root)
        path = self.root / "empty.sarif"
        path.write_text('{"runs": []}', encoding="utf-8")
        with self.assertRaises(ValueError):
            inspect_sarif(path)

    def test_failed_invocation_cannot_pass_as_zero(self):
        run = self.run_with([])
        run["invocations"] = [{"executionSuccessful": False}]
        with self.assertRaises(ValueError):
            inspect_sarif(self.write(run))

    def test_absent_results_cannot_pass_as_zero(self):
        run = self.run_with([])
        del run["results"]
        with self.assertRaises(ValueError):
            inspect_sarif(self.write(run))


if __name__ == "__main__":
    unittest.main()
