"""Ownership and immutable-SDK boundaries for the actual browser bootstrap."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from urllib.parse import urlsplit

import isolated_flutter_web_tools as tools


class IsolatedFlutterToolTests(unittest.TestCase):
    def test_package_resolution_keeps_every_dependency_and_redirects_only_tool_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / "sdk/packages/flutter_tools/.dart_tool/package_config.json"
            original.parent.mkdir(parents=True)
            value = {"configVersion": 2, "packages": [
                {"name": "flutter_tools", "rootUri": "../", "packageUri": "lib/"},
                {"name": "path", "rootUri": "../../../cache/path", "languageVersion": "3.4"}]}
            original.write_text(json.dumps(value), encoding="utf-8")
            before = original.read_bytes()
            private = root / "private tools/framework"
            result = tools.package_config(original, private)
            self.assertEqual(before, original.read_bytes())
            self.assertEqual(private.resolve().as_uri() + "/", result["packages"][0]["rootUri"])
            self.assertEqual("file", urlsplit(result["packages"][1]["rootUri"]).scheme)
            self.assertTrue(result["packages"][1]["rootUri"].endswith("/sdk/cache/path"))
            self.assertEqual("3.4", result["packages"][1]["languageVersion"])

    def test_unknown_vendor_source_is_never_patched_as_if_it_were_the_reviewed_sdk(self):
        with self.assertRaisesRegex(ValueError, "Unreviewed"):
            tools.patched_source("request.requestedUri.path.contains('host.dart.js')")

    def test_one_tool_owner_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "package_config.json"
            for packages in ([], [{"name": "flutter_tools", "rootUri": "../"}] * 2):
                path.write_text(json.dumps({"configVersion": 2, "packages": packages}), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    tools.package_config(path, Path(directory) / "copy")

    def test_tool_evidence_rejects_changed_recipe_revision_dependency_or_snapshot_identity(self):
        from test_flutter_test_shards import FlutterEvidenceTests
        owner = FlutterEvidenceTests()
        owner.root = Path(tempfile.gettempdir()) / "fixture-browser-tool"
        prefix, evidence, _ = owner.isolated_tool()
        tools.validate_evidence(evidence, prefix)
        for target, key, value in [
            ("inputs", "sdk_revision", "f" * 40),
            ("inputs", "bootstrap_sha256", "0" * 64),
            ("inputs", "asset_fragment_sha256", "0" * 64),
            ("inputs", "sdk_source_normalized_sha256", "0" * 64),
            ("files", "flutter_tools_private.snapshot", None),
            ("files", "framework/" + tools.SDK_SOURCE, "0" * 64),
        ]:
            damaged = copy.deepcopy(evidence)
            damaged[target][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                tools.validate_evidence(damaged, prefix)
        damaged = copy.deepcopy(evidence)
        damaged["sdk_inputs_after"] = {}
        with self.assertRaises(ValueError):
            tools.validate_evidence(damaged, prefix)
        with self.assertRaises(ValueError):
            tools.validate_evidence(evidence, [prefix[0], "--packages=other", prefix[2]])


if __name__ == "__main__":
    unittest.main()
