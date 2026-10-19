"""OSV process/output regressions; no Docker, network or credentials required."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import osv_scan_gate as gate


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(gate.__file__)
SARIF = {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": "osv-scanner"}}, "results": []}]}


class OsvScanGateTest(unittest.TestCase):
    def fixture(self, root):
        scan, sarif = root / "results.json", root / "results.sarif"
        scan.write_text(json.dumps({"results": []}), encoding="utf-8")
        sarif.write_text(json.dumps(SARIF), encoding="utf-8")
        return scan, sarif

    def test_complete_successful_json_and_sarif_are_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            scan, sarif = self.fixture(Path(temporary))
            # Both official v2.3.8's non-omitempty field and real clean Docker
            # outputs use an explicit empty results array. Empty bytes are not {}.
            self.assertEqual({"results": []}, json.loads(scan.read_text()))
            self.assertEqual({"scanner": "success", "reporter": "success", "sarifRuns": 1, "sarifResults": 0},
                             gate.require_scan_success("success", "success", scan, sarif))

    def test_failed_scanner_cannot_be_hidden_by_successful_reporter_or_valid_clean_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            scan, sarif = self.fixture(Path(temporary))
            with self.assertRaisesRegex(gate.ScanGateError, "scanner did not succeed"):
                gate.require_scan_success("failure", "success", scan, sarif)

    def test_reporter_failure_cannot_be_hidden_by_successful_scanner(self):
        with tempfile.TemporaryDirectory() as temporary:
            scan, sarif = self.fixture(Path(temporary))
            with self.assertRaisesRegex(gate.ScanGateError, "reporter did not succeed"):
                gate.require_scan_success("success", "failure", scan, sarif)

    def test_vulnerability_failure_remains_blocked_after_sarif_is_written(self):
        with tempfile.TemporaryDirectory() as temporary:
            scan, sarif = self.fixture(Path(temporary))
            report = copy.deepcopy(SARIF)
            report["runs"][0]["results"] = [{"ruleId": "fixture-vulnerability"}]
            sarif.write_text(json.dumps(report), encoding="utf-8")
            with self.assertRaisesRegex(gate.ScanGateError, "scanner did not succeed"):
                gate.require_scan_success("failure", "failure", scan, sarif)
            self.assertEqual("fixture-vulnerability", json.loads(sarif.read_text())["runs"][0]["results"][0]["ruleId"])

    def test_sarif_findings_cannot_be_hidden_by_successful_process_outcomes(self):
        with tempfile.TemporaryDirectory() as temporary:
            scan, sarif = self.fixture(Path(temporary))
            report = copy.deepcopy(SARIF)
            report["runs"].append({"tool": {"driver": {"name": "osv-scanner"}},
                                   "results": [{"ruleId": "first-vulnerability"}, {"ruleId": "second-vulnerability"}]})
            sarif.write_text(json.dumps(report), encoding="utf-8")
            with self.assertRaisesRegex(gate.ScanGateError, "SARIF contains 2 unignored finding"):
                gate.require_scan_success("success", "success", scan, sarif)

    def test_skipped_cancelled_unknown_or_empty_outcomes_never_count_as_scans(self):
        for outcome in ("skipped", "cancelled", "", "unknown"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as temporary:
                scan, sarif = self.fixture(Path(temporary))
                with self.assertRaises(gate.ScanGateError):
                    gate.require_scan_success(outcome, "success", scan, sarif)

    def test_missing_empty_truncated_and_trailing_json_are_rejected(self):
        for contents in (None, "", '{"results":[', '{"results":[]} garbage'):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as temporary:
                scan, sarif = self.fixture(Path(temporary))
                if contents is None:
                    scan.unlink()
                else:
                    scan.write_text(contents, encoding="utf-8")
                with self.assertRaisesRegex(gate.ScanGateError, "Scanner output is missing, empty or invalid JSON"):
                    gate.require_scan_success("success", "success", scan, sarif)

    def test_nonobject_scan_or_invalid_results_type_is_rejected(self):
        for document in ([], None, "clean", {}, {"results": None}, {"results": "not an array"}):
            with self.subTest(document=document), tempfile.TemporaryDirectory() as temporary:
                scan, sarif = self.fixture(Path(temporary))
                scan.write_text(json.dumps(document), encoding="utf-8")
                with self.assertRaises(gate.ScanGateError):
                    gate.require_scan_success("success", "success", scan, sarif)

    def test_missing_empty_invalid_or_incomplete_sarif_is_rejected(self):
        for document in (None, "", "{", {}, {"version": "2.1.0", "runs": []},
                         {"version": "2.0.0", "runs": SARIF["runs"]},
                         {"version": "2.1.0", "runs": [{}]}):
            with self.subTest(document=document), tempfile.TemporaryDirectory() as temporary:
                scan, sarif = self.fixture(Path(temporary))
                if document is None:
                    sarif.unlink()
                else:
                    sarif.write_text(document if isinstance(document, str) else json.dumps(document), encoding="utf-8")
                with self.assertRaises(gate.ScanGateError):
                    gate.require_scan_success("success", "success", scan, sarif)

    def test_actual_cli_returns_nonzero_on_scan_crash_even_when_reporter_and_files_look_clean(self):
        with tempfile.TemporaryDirectory() as temporary:
            scan, sarif = self.fixture(Path(temporary))
            command = [sys.executable, str(SCRIPT), "--scan-outcome", "failure", "--report-outcome", "success",
                       "--json", str(scan), "--sarif", str(sarif)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(1, result.returncode)
            self.assertIn("::error::OSV scanner did not succeed", result.stderr)
            self.assertNotIn("verified", result.stdout)
            command[command.index("--scan-outcome") + 1] = "success"
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(0, result.returncode)
            self.assertIn("verified", result.stdout)


class OsvWorkflowContractTest(unittest.TestCase):
    def test_original_scanner_and_reporter_use_supported_flags_in_the_input_workspace(self):
        workflow = (ROOT / ".github/workflows/osv-scanner.yml").read_text(encoding="utf-8")
        # 与 osv-scanner.yml 的钉版 action 哈希同步更新（2026-10-19 v2.3.8）。
        revision = "9a96bc4d2b09685b6142bcfe25a3dc17cb2d7347"
        self.assertIn("google/osv-scanner-action/osv-scanner-action@" + revision, workflow)
        self.assertIn("google/osv-scanner-action/osv-reporter-action@" + revision, workflow)
        self.assertIn("--output-file=results.json", workflow)
        self.assertIn("--output-files=sarif:results.sarif", workflow)
        self.assertIn("--fail-on-vuln=true", workflow)
        self.assertIn("-L\n            ./server/target/classes/META-INF/sbom/application.cdx.json", workflow)
        self.assertIn("--lockfile\n            ./pubspec.lock", workflow)
        self.assertIn("--config\n            ./osv-scanner.toml", workflow)
        for removed in ("--sbom", "--output=", "download-artifact", "security-events: write", "upload-sarif", "NODE_NO_WARNINGS"):
            self.assertNotIn(removed, workflow)

    def test_gate_uses_actual_outcomes_and_preserves_both_inputs_and_results(self):
        workflow = (ROOT / ".github/workflows/osv-scanner.yml").read_text(encoding="utf-8")
        self.assertIn("SCAN_OUTCOME: ${{ steps.osv-scan.outcome }}", workflow)
        self.assertIn("REPORT_OUTCOME: ${{ steps.osv-report.outcome }}", workflow)
        self.assertNotIn(".conclusion", workflow)
        self.assertIn("--json results.json --sarif results.sarif", workflow)
        self.assertIn("python3 -m unittest discover -s .github/scripts -p test_osv_scan_gate.py -v", workflow)
        self.assertIn("name: osv-inputs", workflow)
        self.assertIn("name: OSV Scanner SARIF file", workflow)
        self.assertIn("results.json\n            results.sarif", workflow)
        self.assertLess(workflow.index("name: Run OSV scanner"), workflow.index("name: Generate OSV SARIF"))
        self.assertLess(workflow.index("rm -f -- results.json results.sarif"), workflow.index("name: Run OSV scanner"))
        self.assertLess(workflow.index("name: Generate OSV SARIF"), workflow.index("name: Require complete successful scan and report"))


if __name__ == "__main__":
    unittest.main()
