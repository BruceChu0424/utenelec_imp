"""Payload and isolation checks use synthetic PE files, never a target runtime."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

import prepare_auto_installer as planner
from test_package_windows import fixture_executable, runtime_fixtures


class AutoInstallerPlanTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uimp legacy source test ")
        self.root = Path(self.temporary.name).resolve()
        self.review = {"schemaVersion": 1, "applicationVersion": "2.5.34",
                       "applicationBuild": 2534, "sourceCommit": "a" * 40, "runtimes": {}}
        for role, architecture in planner.ROLES.items():
            directory = self.root / role
            directory.mkdir()
            if role.startswith("legacy-"):
                for name in ("chrome.exe", "chrome.dll"):
                    (directory / name).write_bytes(fixture_executable(architecture=architecture))
                (directory / "icudtl.dat").write_bytes(b"synthetic browser fixture")
                (directory / "LICENSE").write_text("synthetic license fixture", encoding="utf-8")
                metadata = {"vendor": "Supermium", "runtimeVersion": "synthetic-fixture",
                            "sourceUrl": "https://github.com/win32ss/supermium/releases/tag/test-fixture",
                            "licenseFiles": ["LICENSE"]}
            else:
                for name in ("data/app.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin",
                             "client_updater/client_updater.ps1"):
                    target = directory / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b"synthetic native fixture")
                (directory / "uten_imp.exe").write_bytes(fixture_executable(2534, version=(2, 5, 34)))
                runtime_fixtures(directory)
                metadata = {}
            self.review["runtimes"][role] = {**metadata, "directory": str(directory),
                                              "files": planner.inventory(directory)}

    def tearDown(self):
        self.temporary.cleanup()

    def inspect(self, review=None):
        return planner.inspect_review(review or self.review, "https://erp.company.test/")

    def refresh_hashes(self, role):
        item = self.review["runtimes"][role]
        item["files"] = planner.inventory(Path(item["directory"]))

    def test_reviewed_inputs_prepare_only_source_and_do_not_publish(self):
        plan = self.inspect()
        output = self.root / "source output"
        planner.write_source_plan(plan, output)
        self.assertEqual({"auto_installer_inputs.iss", "runtime_policy.iss", "plan.json"},
                         {path.name for path in output.iterdir()})
        saved = json.loads((output / "plan.json").read_text(encoding="utf-8"))
        self.assertFalse(saved["releaseReady"])
        self.assertEqual("source-plan-only", saved["status"])
        self.assertEqual("not-connected-to-current-client-catalog", saved["publication"])
        include = (output / "auto_installer_inputs.iss").read_text(encoding="utf-8-sig")
        for macro in planner.MACROS.values():
            self.assertIn(f"#define {macro} ", include)
        self.assertNotIn("PayloadNativeX64", include)
        self.assertTrue((planner.HERE.parents[2] / "windows/runner/resources/app_icon.ico").is_file())
        self.assertFalse((output / "artifacts").exists())

    def test_pilot_never_installs_or_starts_a_second_native_client(self):
        source = (planner.HERE / "windows_auto_installer.iss").read_text(encoding="utf-8-sig")
        self.assertNotIn("PayloadNativeX64", source)
        self.assertNotIn("uten_imp.exe", source)
        self.assertIn("if SelectedRuntime = 'native-x64' then begin", source)
        self.assertIn("Result := False;\n    Exit;", source)

    def test_changed_reviewed_file_is_rejected(self):
        item = self.review["runtimes"]["legacy-x86"]
        (Path(item["directory"]) / "chrome.dll").write_bytes(b"changed after review")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.inspect()

    def test_extra_unreviewed_file_is_rejected(self):
        directory = Path(self.review["runtimes"]["legacy-x64"]["directory"])
        (directory / "unreviewed.dll").write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.inspect()

    def test_wrong_architecture_is_rejected_even_when_hashes_match(self):
        directory = Path(self.review["runtimes"]["legacy-x86"]["directory"])
        (directory / "chrome.exe").write_bytes(fixture_executable(architecture="x64"))
        self.refresh_hashes("legacy-x86")
        with self.assertRaisesRegex(ValueError, "architecture mismatch"):
            self.inspect()

    def test_native_version_mismatch_does_not_become_a_downgrade(self):
        review = copy.deepcopy(self.review)
        review["applicationBuild"] = 2535
        with self.assertRaisesRegex(ValueError, "version/build/architecture"):
            self.inspect(review)

    def test_native_missing_vc_runtime_cannot_bypass_existing_validator(self):
        directory = Path(self.review["runtimes"]["native-x64"]["directory"])
        (directory / "msvcp140.dll").unlink()
        self.refresh_hashes("native-x64")
        with self.assertRaisesRegex(ValueError, "Visual C\\+\\+ runtime"):
            self.inspect()

    def test_licenses_must_be_present_in_the_reviewed_runtime(self):
        self.review["runtimes"]["legacy-x64"]["licenseFiles"] = ["MISSING-LICENSE"]
        with self.assertRaisesRegex(ValueError, "license texts"):
            self.inspect()

    def test_pristine_runtime_cannot_include_employee_browser_profiles_or_keys(self):
        directory = Path(self.review["runtimes"]["legacy-x86"]["directory"])
        for name in ("User Data", "Cookies", "employee.key"):
            with self.subTest(name=name):
                path = directory / name
                path.write_bytes(b"private fixture")
                try:
                    with self.assertRaisesRegex(ValueError, "pristine"):
                        planner.inventory(directory)
                finally:
                    path.unlink()

    def test_source_plan_cannot_overwrite_or_be_written_into_payload(self):
        plan = self.inspect()
        for output in (self.root, self.root / "native-x64" / "plan"):
            with self.subTest(output=output):
                with self.assertRaises(ValueError):
                    planner.write_source_plan(plan, output)

    def test_company_url_preserves_https_and_contains_no_credentials_or_flags(self):
        for url in ("http://erp.company.test/", "https://user:password@erp.company.test/",
                    "https://erp.company.test/?token=private", "https://erp.company.test/#token",
                    "https://localhost/", "https://127.0.0.1/", "https://erp.example.invalid/",
                    'https://erp.company.test/" --ignore-certificate-errors',
                    "https://erp.company.test/\n", "https://erp.company.test:65536/"):
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    planner.validate_company_url(url)
        self.assertEqual("https://erp.company.test:8443/erp/",
                         planner.validate_company_url("https://erp.company.test:8443/erp/"))

    def test_all_architectures_and_exact_source_identity_are_required(self):
        for field in ("legacy-x86", "legacy-x64", "native-x64"):
            review = copy.deepcopy(self.review)
            del review["runtimes"][field]
            with self.assertRaisesRegex(ValueError, "exactly"):
                self.inspect(review)
        self.review["sourceCommit"] = "main"
        with self.assertRaisesRegex(ValueError, "exact reviewed"):
            self.inspect()


if __name__ == "__main__":
    unittest.main()
