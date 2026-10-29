"""Offline generated-consumer and authoritative dependency contract checks."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import sync_package_contract as contract

class SharedPackageContractTest(unittest.TestCase):
    def test_generated_consumers_match_the_same_reviewed_contract_and_lock(self):
        contract.synchronize()
        value = contract.load_contract()
        self.assertEqual(6, len(value["files"]))
        self.assertNotIn("uten-wpf.ico", value["files"])
        self.assertEqual("update", value["packageKind"])

    def test_generated_values_come_from_source_and_not_an_embedded_fallback(self):
        value = contract.load_contract()
        value["maximumManifestBytes"] += 1
        cs, java = contract.render(value, "source-sha", "lock-sha")
        self.assertIn(str(value["maximumManifestBytes"]), cs)
        self.assertIn(str(value["maximumManifestBytes"]), java)
        self.assertIn(value["dependency"]["dllSha256"], cs)
        self.assertIn(value["dependency"]["licenseSha256"], java)

    def test_unknown_or_duplicate_contract_fields_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="uten-wpf-contract-") as temporary:
            source = Path(temporary) / "package-contract.json"
            value = json.loads(contract.CONTRACT.read_text(encoding="utf-8"))
            value["silentFallback"] = 1
            source.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(ValueError):
                contract.load_contract(source)
            source.write_text('{"schemaVersion":1,"schemaVersion":1}', encoding="utf-8")
            with self.assertRaises(ValueError):
                contract.load_contract(source)

    def test_dependency_version_and_hash_have_one_authority(self):
        with tempfile.TemporaryDirectory(prefix="uten-wpf-contract-") as temporary:
            lock = Path(temporary) / "dependencies.lock.json"
            value = json.loads(contract.LOCK.read_text(encoding="utf-8"))
            value["version"] = "unreviewed"
            lock.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(ValueError):
                contract.load_contract(lock_path=lock)
            value["version"] = "2.7.0"
            value["files"]["LICENSE.md"] = "malformed"
            lock.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(ValueError):
                contract.load_contract(lock_path=lock)

    def test_check_detects_edited_generated_snapshot_without_rewriting_it(self):
        with tempfile.TemporaryDirectory(prefix="uten-wpf-contract-") as temporary:
            snapshot = Path(temporary) / "PackageContract.g.cs"
            changed = contract.CS.read_bytes() + b"// unreviewed drift\n"
            snapshot.write_bytes(changed)
            with mock.patch.object(contract, "CS", snapshot):
                with self.assertRaises(ValueError):
                    contract.synchronize()
            self.assertEqual(changed, snapshot.read_bytes())

if __name__ == "__main__":
    unittest.main()
