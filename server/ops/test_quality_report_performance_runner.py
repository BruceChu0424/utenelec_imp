from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("run_quality_report_performance.py")
spec = importlib.util.spec_from_file_location("quality_report_runner", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PerformanceEvidenceSafetyTest(unittest.TestCase):
    def test_compiled_identity_changes_with_bytes_not_directory_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            first, second = Path(temporary) / "first", Path(temporary) / "second"
            first.mkdir(); second.mkdir()
            (first / "A.class").write_bytes(b"first")
            (second / "A.class").write_bytes(b"first")
            self.assertEqual(runner.tree_identity(first), runner.tree_identity(second))
            (second / "A.class").write_bytes(b"changed")
            self.assertNotEqual(runner.tree_identity(first), runner.tree_identity(second))

    def test_preparation_never_replaces_prior_run_evidence(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "docker") as docker:
            with self.assertRaises(ValueError):
                runner.prepare(SimpleNamespace(), Path(temporary))
            docker.assert_not_called()

    def test_measurement_requires_explicit_quiet_window(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "docker") as docker:
            output = Path(temporary)
            runner.write_json(output / "manifest.json", {"state": "PREPARED"})
            with self.assertRaises(ValueError):
                runner.run(SimpleNamespace(quiet_window=False), output)
            docker.assert_not_called()

    def test_successful_process_without_complete_tests_is_invalid_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            manifest = {
                "state": "PREPARED", "runnerSha256": runner.digest(SCRIPT), "image": "fixture-image",
                "verifierSha256": runner.digest(SCRIPT.with_name("verify_quality_report_snapshot.py")),
                "imageIdentity": "sha256:fixture", "workVolume": "uten-performance-fixture-work",
                "postgresImageIdentity": "sha256:fixture",
                "cacheVolume": "uten-performance-fixture-cache", "baselineIdentity": "baseline-fixture",
                "sourceIdentity": "candidate-fixture", "network": "isolated-fixture", "suite": "fixture",
                "daemonVolume": "uten-performance-fixture-daemon", "baselinePath": "fixture-before", "candidatePath": "fixture-after",
                "daemonContainer": "fixture-daemon",
            }
            runner.write_json(output / "manifest.json", manifest)

            def docker(*arguments, **kwargs):
                if arguments[:2] == ("image", "inspect"):
                    return json.dumps([{"Id": "sha256:fixture"}])
                if arguments[:2] == ("volume", "inspect"):
                    return json.dumps([{"Labels": {"uten.run": "fixture", "uten.task": "quality-report-performance"}}])
                return ""

            with patch.object(runner, "docker", side_effect=docker), patch.object(runner, "validate_topology"), patch.object(runner, "observe_load"), patch.object(runner, "verify_snapshot"), patch.object(runner.subprocess, "run", return_value=SimpleNamespace(returncode=0)):
                with self.assertRaisesRegex(ValueError, "four complete"):
                    runner.run(SimpleNamespace(quiet_window=True, run_id="fixture", side="baseline"), output)
            receipt = json.loads((output / "baseline/receipt.json").read_text())
            self.assertEqual("INVALID_EVIDENCE", receipt["state"])
            self.assertTrue((output / "baseline/maven.log").is_file())

    def test_daemon_rejects_host_published_api_or_host_bind(self):
        manifest = {"runId": "fixture", "network": "net", "daemonContainer": "daemon",
                    "daemonVolume": "data", "daemonImageIdentity": "image", "fixtureImages": {}}
        labels = {"uten.run": "fixture", "uten.task": "quality-report-performance"}
        network = {"Internal": True, "Labels": labels}
        daemon = {"Config": {"Labels": labels}, "Image": "image", "State": {"Running": True},
                  "HostConfig": {"PortBindings": {"2375/tcp": [{"HostPort": "2375"}]}},
                  "Mounts": [{"Name": "data", "Destination": "/var/lib/docker"}],
                  "NetworkSettings": {"Networks": {"net": {}}}}
        def inspect(*arguments):
            return json.dumps([network if arguments[0] == "network" else daemon])
        with patch.object(runner, "docker", side_effect=inspect):
            with self.assertRaisesRegex(ValueError, "no host-published"):
                runner.validate_topology(manifest)
            daemon["HostConfig"]["PortBindings"] = {}
            daemon["Mounts"].append({"Source": "/var/run/docker.sock", "Destination": "/var/run/docker.sock"})
            with self.assertRaisesRegex(ValueError, "only its run-owned"):
                runner.validate_topology(manifest)
            daemon["Mounts"].pop()
            runner.validate_topology(manifest)

    def test_snapshot_verifier_uses_current_interpreter_and_restores_arguments(self):
        previous = runner.sys.argv
        with patch.object(runner.runpy, "run_path", side_effect=ValueError("fixture mismatch")) as execute, patch.object(runner.subprocess, "run") as child:
            with self.assertRaisesRegex(ValueError, "fixture mismatch"):
                runner.verify_snapshot(["--run-id", "fixture"])
            execute.assert_called_once()
            child.assert_not_called()
            self.assertIs(previous, runner.sys.argv)

    def test_windows_observation_collects_resource_counters_without_command_lines(self):
        with patch.object(runner.sys, "platform", "win32"), patch.object(runner.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout='{"available":true}')) as read:
            self.assertTrue(runner.windows_resources()["available"])
            script = read.call_args.args[0][-1]
            self.assertIn("cpu100ns", script)
            self.assertIn("readBytes", script)
            self.assertIn("freePhysicalKb", script)
            self.assertNotIn("CommandLine", script)
            self.assertNotIn("ExecutablePath", script)


if __name__ == "__main__":
    unittest.main()
