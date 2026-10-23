import copy
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

import vendor_pub_audit as audit


class VendorPubAuditTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "third_party/fixture_plugin"
        self.directory.mkdir(parents=True)
        self.output = self.root / "audit-output"
        original = {"pubspec.yaml": b"name: fixture_plugin\nversion: 1.2.3\n", "LICENSE": b"Original fixture license\n",
                    "lib/plugin.dart": b"const value = 1;\n", "android/build.gradle": b"original toolchain\n"}
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as tar:
            for name, data in original.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
                path = self.directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        self.archive = archive.getvalue()
        (self.directory / "pubspec.yaml").write_text("name: fixture_plugin\nversion: 1.2.3+uten.1\npublish_to: none\n")
        (self.directory / "android/build.gradle").write_text("reviewed migrated toolchain\n")
        (self.directory / "UPSTREAM.md").write_text("Original archive and reviewed patch provenance\n")
        self.registry = {"schemaVersion": 1, "packages": [{"name": "fixture_plugin", "upstreamVersion": "1.2.3",
            "localVersion": "1.2.3+uten.1", "archiveSha256": hashlib.sha256(self.archive).hexdigest(),
            "modifiedFiles": ["pubspec.yaml", "android/build.gradle"], "localOnlyFiles": ["UPSTREAM.md"],
            "files": {path.relative_to(self.directory).as_posix(): audit.digest(path.read_bytes())
                      for path in self.directory.rglob("*") if path.is_file()}}]}
        (self.root / "pubspec.lock").write_text('packages:\n  fixture_plugin:\n    description:\n      path: "third_party/fixture_plugin"\n'
            '      relative: true\n    source: path\n    version: "1.2.3+uten.1"\n')

    def build(self, registry=None, archive=None):
        return audit.build_audit(self.root, registry or self.registry, self.output,
                                 fetch=lambda _: self.archive if archive is None else archive)

    def test_audit_lock_uses_original_hosted_identity_only_after_archive_source_license_and_version_verification(self):
        evidence = self.build()
        source = (self.output / "pubspec.lock").read_text()
        self.assertIn('version: "1.2.3"', source)
        self.assertNotIn("+uten.1", source)
        self.assertIn("source: hosted", source)
        self.assertIn(self.registry["packages"][0]["archiveSha256"], source)
        self.assertTrue(evidence[0]["licenseVerified"])
        self.assertEqual(5, evidence[0]["verifiedSourceFiles"])

    def test_tampered_runtime_patch_metadata_license_or_extra_source_cannot_generate_an_audit_lock(self):
        for relative in ("lib/plugin.dart", "android/build.gradle", "pubspec.yaml", "LICENSE", "extra.dart"):
            with self.subTest(relative=relative):
                path = self.directory / relative
                before = path.read_bytes() if path.exists() else None
                path.write_bytes(b"unreviewed change\n")
                with self.assertRaises(ValueError):
                    self.build()
                self.assertFalse(self.output.exists())
                if before is None:
                    path.unlink()
                else:
                    path.write_bytes(before)

    def test_archive_corruption_or_wrong_original_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "archive/version"):
            self.build(archive=self.archive + b"tampering")
        registry = copy.deepcopy(self.registry)
        registry["packages"][0].update(upstreamVersion="9.9.9", localVersion="9.9.9+uten.1")
        with self.assertRaisesRegex(ValueError, "archive package identity"):
            self.build(registry)
        self.assertFalse(self.output.exists())

    def test_application_cannot_scan_one_version_while_running_a_different_vendor_or_path(self):
        path = self.root / "pubspec.lock"
        before = path.read_text()
        for change in (before.replace("1.2.3+uten.1", "1.2.4+uten.1"), before.replace("third_party/fixture_plugin", "third_party/other")):
            path.write_text(change)
            with self.assertRaises(ValueError):
                self.build()
            self.assertFalse(self.output.exists())
        path.write_text(before)

    def test_no_partial_clean_input_is_written_when_later_package_verification_fails(self):
        registry = copy.deepcopy(self.registry)
        registry["packages"].append(copy.deepcopy(registry["packages"][0]))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.build(registry)
        self.assertFalse(self.output.exists())

    def test_hygiene_scope_cannot_allow_substantive_code_changes_even_if_local_file_hash_is_updated(self):
        record = copy.deepcopy(self.registry["packages"][0])
        record["hygieneFiles"] = ["lib/plugin.dart"]
        audit.verify_package(self.root, record, self.archive)
        path = self.directory / "lib/plugin.dart"
        path.write_bytes(b"const value = 2;\n")
        record["files"]["lib/plugin.dart"] = audit.digest(path.read_bytes())
        with self.assertRaisesRegex(ValueError, "substantive source"):
            audit.verify_package(self.root, record, self.archive)

    def test_ci_scans_and_preserves_the_generated_audit_input(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/osv-scanner.yml").read_text(encoding="utf-8")
        self.assertIn("vendor_pub_audit.py --output .local-artifacts/vendor-pub-audit", workflow)
        self.assertIn("--lockfile\n            ./.local-artifacts/vendor-pub-audit/pubspec.lock", workflow)
        self.assertIn("            .local-artifacts/vendor-pub-audit/evidence.json", workflow)


if __name__ == "__main__":
    unittest.main()
