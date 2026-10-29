"""Offline staging/receipt contract checks. No Setup or compiler is executed."""
from pathlib import Path
import json
import shutil
import unittest
from unittest import mock
import subprocess
import uuid
import build_wpf_installer as installer
import package_wpf as package
import test_package_wpf as fixtures

class InstallerStagingContractTest(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.WpfCandidatePackageTest("test_default_is_read_only_dry_run_with_no_zip_or_directory")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.addCleanup(self.fixture.tearDown)
        root = self.fixture.root
        for owning in (installer.INSTALLER, installer.POLICY, Path(installer.__file__).resolve()):
            destination = self.fixture.source / owning.relative_to(package.ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(owning, destination)
        self.fixture.git("add", ".")
        self.fixture.git("-c", "user.name=WPF Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                         "-c", "core.hooksPath=disabled-hooks", "commit", "-qm", "owned installer tool fixture")
        self.fixture.state = package.capture_source_state(self.fixture.source)
        self.fixture.issue_receipt()
        x86 = root / "x86 payload"
        shutil.copytree(self.fixture.bundle, x86)
        (x86 / package.EXECUTABLE).write_bytes(fixtures.managed_fixture("x86"))
        self.payloads = {"x86": x86, "x64": self.fixture.bundle}
        self.helpers = {}
        self.receipts = {"x64": self.fixture.receipt, "x86": root / "x86-receipt.json"}
        self.bootstrap_receipts = {}
        package.write_build_receipt(x86, self.receipts["x86"], architecture="x86", source_root=self.fixture.source,
            source_state=self.fixture.state, configuration="Release", distribution_profile="Company")
        for arch in ("x86", "x64"):
            directory = root / ("bootstrap-" + arch)
            directory.mkdir()
            helper = directory / "Uten.Legacy.Updater.exe"
            helper.write_bytes(fixtures.managed_fixture(arch))
            helper.with_suffix(".exe.config").write_bytes((self.fixture.bundle / package.APP_CONFIG).read_bytes())
            self.helpers[arch] = helper
            receipt = root / (arch + "-bootstrap-receipt.json")
            package.write_bootstrap_receipt(helper, receipt, architecture=arch, source_root=self.fixture.source, source_state=self.fixture.state)
            self.bootstrap_receipts[arch] = receipt
        self.compiler = root / "ISCC.exe"
        self.compiler.write_bytes(b"never-executed compiler fixture")
        self.output = package.ROOT / "build/windows-wpf/installer-execute/staging-tests" / uuid.uuid4().hex / "UtenWin7WpfFixture-test.exe"

    def plan(self, **options):
        return installer.build_installer(self.payloads, self.helpers, self.fixture.bundle / "uten.client.json",
            package.ROOT / "windows/runner/resources/app_icon.ico", self.output, self.compiler,
            fixture=options.pop("fixture", True), version="1.2.3", build_number=45, source_root=self.fixture.source,
            receipts=self.receipts, bootstrap_receipts=options.pop("bootstrap_receipts", self.bootstrap_receipts), **options)

    def test_default_dry_run_binds_six_runtime_and_two_fixed_bootstrap_files(self):
        result = self.plan()
        self.assertFalse(result["build"])
        self.assertFalse(self.output.parent.exists())
        for arch in ("x86", "x64"):
            self.assertEqual(6, len(result["architectures"][arch]["files"]))
            self.assertEqual(2, len(result["architectures"][arch]["bootstrap"]))
        self.assertIsNone(result["sourceState"])

    def test_company_requires_same_source_app_and_bootstrap_receipts(self):
        result = self.plan(fixture=False)
        self.assertEqual(self.fixture.state, result["sourceState"])
        with self.assertRaisesRegex(ValueError, "both same-source bootstrap receipts"):
            self.plan(fixture=False, bootstrap_receipts={})
        changed = json.loads(self.bootstrap_receipts["x86"].read_text(encoding="utf-8"))
        changed["sourceCommit"] = "0" * 40
        self.bootstrap_receipts["x86"].write_text(json.dumps(changed), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "bootstrap receipt differs"):
            self.plan(fixture=False)

    def test_mismatched_bootstrap_architecture_and_company_marker_are_rejected(self):
        correct = self.helpers["x86"]
        self.helpers["x86"] = self.helpers["x64"]
        with self.assertRaisesRegex(ValueError, "architecture"):
            self.plan()
        self.helpers["x86"] = correct
        correct.write_bytes(fixtures.managed_fixture("x86", marker="UTEN WPF candidate; Configuration=Debug; Distribution=Company"))
        with self.assertRaisesRegex(ValueError, "same Release/Company"):
            self.plan(fixture=False)

    def test_two_architectures_cannot_bind_different_endpoint_configuration(self):
        value = dict(self.fixture.config)
        value["endpoints"] = [{"id": "company", "name": "Other", "apiBaseUrl": "https://other.example/api"}]
        (self.payloads["x86"] / "uten.client.json").write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "same separately approved"):
            self.plan()

    def test_prior_candidate_is_never_overwritten(self):
        self.output.parent.mkdir(parents=True)
        self.output.write_bytes(b"previous isolated candidate")
        try:
            with self.assertRaisesRegex(ValueError, "previous Setup/receipt bytes are preserved"):
                self.plan()
            self.assertEqual(b"previous isolated candidate", self.output.read_bytes())
        finally:
            # Only this known one-file test leaf; no recursive cleanup API.
            self.output.unlink()
            self.output.parent.rmdir()

    def test_fixture_is_non_installable_and_template_has_no_recursive_payload_copy(self):
        source = installer.INSTALLER.read_text(encoding="utf-8")
        self.assertIn("#ifdef ValidationFixture", source)
        self.assertIn("Result := False;\n  Exit;", source)
        self.assertNotIn("recursesubdirs", source)
        self.assertIn("Information.LinkCount = 1", source)
        self.assertIn("InstallerUpdateLock", source)
        for arch in ("x86", "x64"):
            self.assertEqual(7, source.count("Check: UseArchitecture('" + arch + "')"))

    def test_frozen_payload_mutation_fails_before_any_candidate_or_receipt_commit(self):
        def mutate(arguments, **options):
            payload = next(argument.split("=", 1)[1] for argument in arguments if argument.startswith("/DPayloadX86="))
            with (Path(payload) / package.CORE).open("ab") as stream:
                stream.write(b"untrusted concurrent fixture mutation")
            return subprocess.CompletedProcess(arguments, 0, b"fixture compiler", b"")
        try:
            with mock.patch.object(installer.subprocess, "run", side_effect=mutate):
                with self.assertRaisesRegex(ValueError, "Frozen Setup payload/bootstrap changed"):
                    self.plan(build=True)
            self.assertFalse(self.output.exists())
            self.assertFalse(self.output.with_suffix(".receipt.json").exists())
        finally:
            self.output.with_suffix(".iscc.log").unlink(missing_ok=True)
            if self.output.parent.is_dir():
                self.output.parent.rmdir()

if __name__ == "__main__":
    unittest.main()
