import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("remote_tls", Path(__file__).with_name("remote_tls.py"))
tls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tls)


class TlsLifecycleTest(unittest.TestCase):
    def test_dns_failure_persists_and_publishes_control_plane_failed_enum(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            published = []
            def failed_caa():
                raise ValueError("DNS operation rejected")
            with patch.object(tls, "WORK", root / "work"), patch.object(tls, "LOGS", root / "logs"), \
                    patch.object(tls.os, "geteuid", return_value=0), patch.object(sys, "argv", ["remote_tls.py", "renew"]), \
                    patch.object(tls, "transport_certificates_current", return_value=True), \
                    patch.object(tls, "module", return_value=SimpleNamespace(ensure_caa=failed_caa)), \
                    patch.object(tls, "ssh", side_effect=lambda action, value: published.append((action, json.loads(value)))):
                self.assertEqual(tls.main(), 1)
            saved = json.loads((root / "work/tls-status.json").read_text())
            self.assertEqual(published, [("publish-status", saved)])
            for role in ("employee", "dr"):
                self.assertEqual(saved[role]["lastOutcome"], "FAILED")
                self.assertEqual(saved[role]["errorCode"], "DNS_POLICY_NOT_READY")
                self.assertTrue(saved[role]["lastFailureAt"])
                self.assertFalse(saved[role]["publicChainVerified"])

    def test_interrupted_status_serialization_preserves_previous_complete_record(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(tls, "WORK", Path(folder)):
            path = Path(folder) / "tls-status.json"
            previous = {"schemaVersion": 1, "updatedAt": "previous"}
            tls.save_state(previous)
            with self.assertRaises(TypeError):
                tls.save_state({"schemaVersion": 1, "unsupported": object()})
            self.assertEqual(json.loads(path.read_text()), previous)


if __name__ == "__main__":
    unittest.main()
