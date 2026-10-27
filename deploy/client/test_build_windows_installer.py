import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import build_windows_installer as setup
from package_windows import MANIFEST_NAME, UPDATER_PATH, inspect_executable, inspect_executable_info
from test_package_windows import fixture_executable


def setup_fixture(*, architecture="x64", loader="x86", build=2531, strings=None, product_version=None,
                  local_test=False):
    numeric = f"2.5.31.{build}"
    resources = {
        "ProductName": setup.LOCAL_PRODUCT_NAME if local_test else setup.PRODUCT_NAME,
        # Inno's official Compiler.ExeUpdateFunc.pas writes this capitalization.
        "OriginalFileName": setup.LOCAL_ORIGINAL_FILENAME if local_test else setup.ORIGINAL_FILENAME,
        "FileDescription": f"{setup.LOCAL_PRODUCT_NAME if local_test else setup.PRODUCT_NAME} ({architecture})",
        "FileVersion": numeric,
        "ProductVersion": numeric,
    }
    if strings:
        resources.update(strings)
    return fixture_executable(build, architecture=loader, version=(2, 5, 31),
                              product_version=product_version, strings=resources)


class WindowsSetupSourceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uimp setup fixture ")
        # Windows runners can expose TEMP through its 8.3 alias (RUNNER~1).
        # The builder resolves publication paths, so fault injections must use
        # that same filesystem identity rather than an unequal lexical alias.
        self.root = Path(self.temporary.name).resolve()
        self.bundle = self.root / "runtime bundle"
        for relative in ("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat",
                         "data/flutter_assets/AssetManifest.bin", UPDATER_PATH):
            path = self.bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic fixture")
        (self.bundle / "uten_imp.exe").write_bytes(fixture_executable(2531, version=(2, 5, 31)))
        self.output = self.root / "output not created" / "uten-imp-2.5.31-windows-x64-setup.exe"
        self.update_output = self.root / "output not created" / "uten-imp-2.5.31-windows-x64-update.zip"
        self.compiler = self.root / "fixture compiler" / "ISCC.exe"
        self.compiler.parent.mkdir()
        self.compiler.write_bytes(b"never executed; only the injected compiler boundary is used")

    def tearDown(self):
        self.temporary.cleanup()

    def build(self, **options):
        return setup.build_windows_setup(self.bundle, self.output, version="2.5.31",
            build_number=2531, architecture="x64", **options)

    def write_setup(self, data=None):
        path = self.root / "setup-fixture.exe"
        path.write_bytes(data if data is not None else setup_fixture())
        return path

    def fixture_compiler(self, command, **options):
        defines = dict(argument[2:].split("=", 1) for argument in command if argument.startswith("/D") and "=" in argument)
        generated = Path(defines["OutputDir"]) / (defines["SetupBaseName"] + ".exe")
        generated.write_bytes(setup_fixture(local_test="/DLocalTest" in command))
        return subprocess.CompletedProcess(command, 0, "synthetic compiler boundary", "")

    def test_default_dry_run_validates_payload_and_never_calls_a_compiler(self):
        runner = mock.Mock(side_effect=AssertionError("Dry runs must never compile"))
        with mock.patch.object(setup, "find_compiler", return_value=None):
            plan = self.build(runner=runner)
        self.assertTrue(plan["dryRun"])
        self.assertTrue(plan["payloadValidated"])
        self.assertFalse(plan["compilerFound"])
        self.assertEqual("windows_setup", plan["mode"])
        self.assertEqual(("x64", "x86"), (plan["architecture"], plan["loaderArchitecture"]))
        self.assertFalse(self.output.parent.exists())
        runner.assert_not_called()

    def test_local_test_dry_run_is_explicit_and_cannot_emit_a_production_update_zip(self):
        plan = self.build(local_test=True)
        self.assertTrue(plan["localTest"])
        self.assertIn("/DLocalTest", plan["command"])
        self.assertFalse(self.output.exists())
        with self.assertRaisesRegex(ValueError, "production distribution"):
            self.build(local_test=True, update_output=self.update_output)

    def test_local_test_product_resources_cannot_pass_the_production_validator(self):
        path = self.write_setup(setup_fixture(local_test=True))
        with self.assertRaisesRegex(ValueError, "resources do not match"):
            setup.validate_setup(path, version="2.5.31", build_number=2531, architecture="x64")
        receipt = setup.validate_setup(path, version="2.5.31", build_number=2531, architecture="x64", local_test=True)
        self.assertTrue(receipt["localTest"])
        result = self.build(compiler=self.compiler, compile=True, runner=self.fixture_compiler, local_test=True)
        self.assertTrue(result["localTest"])

    def test_actual_inno_ascii_space_padding_is_canonicalized_without_trimming_other_values(self):
        numeric = "2.5.31.2531"
        strings = {"ProductName": setup.PRODUCT_NAME + "   ",
                   "OriginalFileName": setup.ORIGINAL_FILENAME + "   ",
                   "FileDescription": f"{setup.PRODUCT_NAME} (x64)   ",
                   "FileVersion": numeric + "   ", "ProductVersion": numeric + "   "}
        path = self.write_setup(setup_fixture(strings=strings))
        setup.validate_setup(path, version="2.5.31", build_number=2531, architecture="x64")
        for value in (" " + setup.PRODUCT_NAME, setup.PRODUCT_NAME + "\u00a0", setup.PRODUCT_NAME.lower()):
            with self.subTest(value=value), self.assertRaises(ValueError):
                setup.validate_setup(self.write_setup(setup_fixture(strings={"ProductName": value})),
                    version="2.5.31", build_number=2531, architecture="x64")

    def test_local_test_script_keeps_identity_directory_and_shortcuts_separate(self):
        script = setup.SCRIPT.read_text(encoding="utf-8-sig")
        self.assertIn("AppId=com.uten.uten_imp.local_test", script)
        self.assertIn("DefaultDirName={localappdata}\\Programs\\Uten\\UIMP-LocalTest", script)
        self.assertIn("chinesesimp.AppDisplayName=UTEN - 本地测试", script)
        self.assertIn("english.AppDisplayName=UTEN - 本地测试", script)
        self.assertIn("#ifdef LocalTest\nUsePreviousAppDir=no\n#else\nUsePreviousAppDir=yes\n#endif", script)
        self.assertIn("VersionInfoProductName=" + setup.LOCAL_PRODUCT_NAME, script)
        self.assertIn("VersionInfoOriginalFileName=" + setup.LOCAL_ORIGINAL_FILENAME, script)

    @unittest.skipUnless(os.environ.get("UTEN_TEST_ISCC"), "An explicitly supplied verified ISCC is required")
    def test_actual_verified_iscc_compiles_only_an_isolated_synthetic_local_test_installer(self):
        result = self.build(compiler=Path(os.environ["UTEN_TEST_ISCC"]), compile=True, local_test=True)
        self.assertTrue(result["localTest"])
        self.assertGreater(result["sizeBytes"], 0)
        with self.assertRaises(ValueError):
            setup.validate_setup(self.output, version="2.5.31", build_number=2531, architecture="x64")

    def test_command_keeps_spaced_paths_in_single_arguments_and_separates_payload_architecture(self):
        command = setup.compiler_command(self.compiler, self.bundle, self.root / "compiler output", "UIMPSetup",
            version="2.5.31", build_number=2531, architecture="x64")
        self.assertEqual(str(self.compiler), command[0])
        self.assertIn(f"/DPayloadDir={self.bundle}", command)
        self.assertIn("/DAllowedArchitectures=x64compatible", command)
        self.assertIn("/DInstall64Architectures=x64compatible", command)
        self.assertIn("/DPayloadArchitecture=x64", command)
        self.assertEqual(str(setup.SCRIPT), command[-1])

    def test_all_payload_architectures_use_their_own_install_gate(self):
        for architecture, expected in setup.ARCHITECTURES.items():
            with self.subTest(architecture=architecture):
                command = setup.compiler_command(None, self.bundle, self.root, "UIMPSetup",
                    version="2.5.31", build_number=2531, architecture=architecture)
                self.assertIn(f"/DAllowedArchitectures={expected[0]}", command)
                self.assertIn(f"/DInstall64Architectures={expected[1]}", command)

    def test_fixture_compile_embeds_only_one_validated_payload_and_publishes_checked_exe(self):
        def compiler_boundary(command, **options):
            self.assertTrue(options["check"])
            defines = dict(argument[2:].split("=", 1) for argument in command if argument.startswith("/D"))
            payload = Path(defines["PayloadDir"])
            manifest = json.loads((payload / MANIFEST_NAME).read_text())
            self.assertEqual("installer", manifest["packageKind"])
            self.assertTrue((payload / UPDATER_PATH).is_file())
            self.assertFalse(any(path.suffix == ".zip" for path in payload.rglob("*")))
            for record in manifest["files"]:
                self.assertEqual(record["sha256"], hashlib.sha256((payload / record["path"]).read_bytes()).hexdigest())
            generated = Path(defines["OutputDir"]) / (defines["SetupBaseName"] + ".exe")
            generated.write_bytes(setup_fixture())
            return subprocess.CompletedProcess(command, 0, "synthetic compiler boundary", "")
        receipt = self.build(compiler=self.compiler, compile=True, runner=compiler_boundary)
        self.assertFalse(receipt["dryRun"])
        self.assertEqual("windows_setup", receipt["mode"])
        self.assertEqual("outer-pe-version-resources-only", receipt["validation"])
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), receipt["sha256"])
        self.assertEqual([], list(self.output.parent.glob(".uten-uimp-setup-*")))

    def test_missing_compiler_is_reported_without_installing_or_producing_an_output(self):
        with mock.patch.object(setup, "find_compiler", return_value=None):
            with self.assertRaisesRegex(ValueError, "not installed"):
                self.build(compile=True)
        self.assertFalse(self.output.exists())

    def test_failed_compilation_preserves_the_existing_output(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"prior approved installer")
        runner = mock.Mock(side_effect=subprocess.CalledProcessError(2, ["fixture-iscc"]))
        with self.assertRaises(subprocess.CalledProcessError):
            self.build(compiler=self.compiler, compile=True, runner=runner)
        self.assertEqual(b"prior approved installer", self.output.read_bytes())

    def test_invalid_compiler_product_cannot_replace_existing_output(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"prior approved installer")
        def compiler_boundary(command, **options):
            defines = dict(argument[2:].split("=", 1) for argument in command if argument.startswith("/D"))
            (Path(defines["OutputDir"]) / (defines["SetupBaseName"] + ".exe")).write_bytes(setup_fixture(build=2530))
        with self.assertRaisesRegex(ValueError, "binary version"):
            self.build(compiler=self.compiler, compile=True, runner=compiler_boundary)
        self.assertEqual(b"prior approved installer", self.output.read_bytes())

    def test_required_fixed_updater_is_checked_before_any_compiler_call(self):
        (self.bundle / UPDATER_PATH).unlink()
        runner = mock.Mock()
        with self.assertRaises(ValueError):
            self.build(compiler=self.compiler, compile=True, runner=runner)
        runner.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_paired_dry_run_validates_both_plans_without_publishing_or_compiling(self):
        runner = mock.Mock(side_effect=AssertionError("A dry run cannot invoke ISCC"))
        plan = self.build(update_output=self.update_output, runner=runner)
        self.assertTrue(plan["dryRun"])
        self.assertTrue(plan["updatePackage"]["dryRun"])
        self.assertEqual(("windows_setup", "windows_archive"), (plan["mode"], plan["updatePackage"]["mode"]))
        self.assertEqual(("2.5.31", 2531, "x64"),
            (plan["updatePackage"]["version"], plan["updatePackage"]["buildNumber"], plan["updatePackage"]["architecture"]))
        self.assertFalse(plan["publication"]["atomicAcrossFiles"])
        self.assertFalse(self.output.exists())
        self.assertFalse(self.update_output.exists())
        self.assertFalse(self.output.parent.exists())
        runner.assert_not_called()

    def test_paired_compile_uses_one_snapshot_and_excludes_the_fixed_updater_from_the_update(self):
        original = (self.bundle / "data/app.so").read_bytes()
        calls = []
        def compiler_boundary(command, **options):
            calls.append(command)
            # Model the original build folder changing after its private snapshot
            # was captured; neither deliverable may reread this external folder.
            (self.bundle / "data/app.so").write_bytes(b"later unrelated build output")
            return self.fixture_compiler(command, **options)
        receipt = self.build(compiler=self.compiler, compile=True, runner=compiler_boundary,
                             update_output=self.update_output)
        self.assertEqual(1, len(calls))
        self.assertEqual(("windows_setup", "windows_archive"), (receipt["mode"], receipt["updatePackage"]["mode"]))
        self.assertEqual(receipt["buildNumber"], receipt["updatePackage"]["buildNumber"])
        self.assertEqual(receipt["version"], receipt["updatePackage"]["version"])
        self.assertFalse(receipt["publication"]["atomicAcrossFiles"])
        with zipfile.ZipFile(self.update_output) as archive:
            self.assertNotIn(UPDATER_PATH, archive.namelist())
            self.assertEqual(original, archive.read("data/app.so"))
            self.assertNotIn("packageKind", json.loads(archive.read(MANIFEST_NAME)))
        for path, result in ((self.output, receipt), (self.update_output, receipt["updatePackage"])):
            self.assertEqual(str(path), result["package"])
            self.assertEqual(path.stat().st_size, result["sizeBytes"])
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), result["sha256"])
        self.assertEqual([], list(self.output.parent.glob(".uten-uimp-*")))

    def test_paired_compiler_failure_keeps_both_prior_outputs(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"prior setup")
        self.update_output.write_bytes(b"prior update")
        runner = mock.Mock(side_effect=subprocess.CalledProcessError(2, ["synthetic compiler"]))
        with self.assertRaises(subprocess.CalledProcessError):
            self.build(compiler=self.compiler, compile=True, runner=runner, update_output=self.update_output)
        self.assertEqual(b"prior setup", self.output.read_bytes())
        self.assertEqual(b"prior update", self.update_output.read_bytes())

    def test_second_publication_failure_rolls_back_both_prior_outputs(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"prior setup")
        self.update_output.write_bytes(b"prior update")
        original_replace = os.replace
        def replace_boundary(source, target):
            if Path(target) == self.update_output and Path(source).name.startswith(".uten-uimp-incoming-"):
                raise OSError("Synthetic second output publication failure")
            return original_replace(source, target)
        with mock.patch.object(setup.os, "replace", side_effect=replace_boundary):
            with self.assertRaisesRegex(OSError, "second output"):
                self.build(compiler=self.compiler, compile=True, runner=self.fixture_compiler,
                           update_output=self.update_output)
        self.assertEqual(b"prior setup", self.output.read_bytes())
        self.assertEqual(b"prior update", self.update_output.read_bytes())
        self.assertEqual([], list(self.output.parent.glob(".uten-uimp-*")))

    def test_second_publication_failure_removes_a_newly_created_first_output(self):
        original_replace = os.replace
        def replace_boundary(source, target):
            if Path(target) == self.update_output and Path(source).name.startswith(".uten-uimp-incoming-"):
                raise OSError("Synthetic second output publication failure")
            return original_replace(source, target)
        with mock.patch.object(setup.os, "replace", side_effect=replace_boundary):
            with self.assertRaises(OSError):
                self.build(compiler=self.compiler, compile=True, runner=self.fixture_compiler,
                           update_output=self.update_output)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.update_output.exists())
        self.assertEqual([], list(self.output.parent.glob(".uten-uimp-*")))

    def test_rollback_preserves_a_concurrent_edit_and_retains_its_recovery_backup(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"prior setup")
        self.update_output.write_bytes(b"prior update")
        original_replace = os.replace
        def replace_boundary(source, target):
            if Path(target) == self.update_output and Path(source).name.startswith(".uten-uimp-incoming-"):
                self.output.write_bytes(b"another producer's concurrent edit")
                raise OSError("Synthetic second output publication failure")
            return original_replace(source, target)
        with mock.patch.object(setup.os, "replace", side_effect=replace_boundary):
            with self.assertRaisesRegex(RuntimeError, "manual recovery"):
                self.build(compiler=self.compiler, compile=True, runner=self.fixture_compiler,
                           update_output=self.update_output)
        self.assertEqual(b"another producer's concurrent edit", self.output.read_bytes())
        self.assertEqual(b"prior update", self.update_output.read_bytes())
        backups = list(self.output.parent.glob(".uten-uimp-backup-*"))
        self.assertTrue(any(path.read_bytes() == b"prior setup" for path in backups))
        self.assertEqual([], list(self.output.parent.glob(".uten-uimp-incoming-*")))

    def test_all_staged_outputs_are_validated_before_the_first_publication(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"prior setup")
        self.update_output.write_bytes(b"prior update")
        original_package = setup.package_release
        def package_boundary(*args, **kwargs):
            receipt = original_package(*args, **kwargs)
            if kwargs.get("kind", "update") == "update":
                with Path(args[1]).open("ab") as stream:
                    stream.write(b"synthetic post-validation mutation")
            return receipt
        with mock.patch.object(setup, "package_release", side_effect=package_boundary):
            with self.assertRaisesRegex(ValueError, "changed before publication"):
                self.build(compiler=self.compiler, compile=True, runner=self.fixture_compiler,
                           update_output=self.update_output)
        self.assertEqual(b"prior setup", self.output.read_bytes())
        self.assertEqual(b"prior update", self.update_output.read_bytes())

    def test_paired_output_paths_must_be_distinct_and_outside_the_bundle(self):
        for update in (self.output, self.bundle / "update.zip", self.root / "wrong.exe"):
            with self.subTest(update=update), self.assertRaises(ValueError):
                self.build(update_output=update)
        self.output.parent.mkdir()
        self.output.write_bytes(b"same original inode")
        self.update_output.hardlink_to(self.output)
        with self.assertRaisesRegex(ValueError, "different files"):
            self.build(update_output=self.update_output)
        self.assertEqual(b"same original inode", self.output.read_bytes())
        self.assertEqual(b"same original inode", self.update_output.read_bytes())

    def test_a_matching_build_with_the_wrong_payload_display_version_is_rejected(self):
        for data in (fixture_executable(2531, version=(2, 4, 31)),
                     fixture_executable(2531, version=(2, 5, 31), product_version=(2, 4, 31, 2531))):
            (self.bundle / "uten_imp.exe").write_bytes(data)
            with self.assertRaisesRegex(ValueError, "file/product version"):
                self.build(update_output=self.update_output)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.update_output.exists())

    def test_paired_cli_is_a_dry_run_until_compile_is_explicit(self):
        executable = sys.executable if Path(sys.executable).is_file() else shutil.which("python")
        self.assertIsNotNone(executable)
        command = [executable, str(Path(setup.__file__)), "--bundle", str(self.bundle), "--output", str(self.output),
                   "--update-output", str(self.update_output), "--version", "2.5.31", "--build-number", "2531"]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        plan = json.loads(result.stdout)
        self.assertTrue(plan["dryRun"])
        self.assertTrue(plan["updatePackage"]["dryRun"])
        self.assertFalse(self.output.exists())
        self.assertFalse(self.update_output.exists())

    def test_setup_resources_and_loader_are_validated_without_execution(self):
        path = self.write_setup()
        info = inspect_executable_info(path)
        self.assertEqual(("x86", 2531), inspect_executable(path))
        self.assertEqual(setup.ORIGINAL_FILENAME, info["strings"]["originalfilename"])
        receipt = setup.validate_setup(path, version="2.5.31", build_number=2531, architecture="x64")
        self.assertEqual(("x64", "x86"), (receipt["architecture"], receipt["loaderArchitecture"]))

    def test_setup_product_version_or_declared_payload_mismatch_is_rejected(self):
        cases = [
            setup_fixture(loader="x64"),
            setup_fixture(architecture="arm64"),
            setup_fixture(product_version=(2, 5, 31, 2530)),
            setup_fixture(strings={"ProductName": "Another product"}),
            setup_fixture(strings={"OriginalFileName": "other.exe"}),
            setup_fixture(strings={"FileVersion": "2.5.31"}),
            setup_fixture(strings={"ProductVersion": "2.5.31"}),
            b"MZ incomplete executable",
        ]
        for index, data in enumerate(cases):
            with self.subTest(case=index):
                with self.assertRaises(ValueError):
                    setup.validate_setup(self.write_setup(data), version="2.5.31", build_number=2531, architecture="x64")

    def test_case_insensitive_duplicate_version_fields_are_rejected(self):
        path = self.write_setup(setup_fixture(strings={"originalfilename": setup.ORIGINAL_FILENAME}))
        with self.assertRaisesRegex(ValueError, "duplicate version string"):
            setup.validate_setup(path, version="2.5.31", build_number=2531, architecture="x64")

    def test_resource_tree_truncation_is_rejected(self):
        data = bytearray(setup_fixture())
        struct.pack_into("<I", data, 584, 0xFFFFFF00)
        with self.assertRaises(ValueError):
            setup.validate_setup(self.write_setup(bytes(data)), version="2.5.31", build_number=2531, architecture="x64")

    def test_invalid_versions_and_unsafe_output_paths_are_rejected(self):
        for version in ("2.5", "v2.5.31", "2.5.31-beta", "2.65536.31", "2.05.31"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                setup.version_numbers(version, 2531)
        for build in (0, 65536):
            with self.subTest(build=build), self.assertRaises(ValueError):
                setup.version_numbers("2.5.31", build)
        for output in (self.bundle / "setup.exe", self.root / "setup.zip", self.root / 'bad"name.exe'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                setup.build_windows_setup(self.bundle, output, version="2.5.31", build_number=2531, architecture="x64")

    def test_script_uses_localized_names_per_user_shortcuts_and_one_payload(self):
        script = setup.SCRIPT.read_text(encoding="utf-8-sig")
        for expected in (
            "#if Ver < 0x06050000",
            "AppId=com.uten.uten_imp", "PrivilegesRequired=lowest",
            "DefaultDirName={localappdata}\\Programs\\Uten\\UIMP", "DisableDirPage=no",
            "UsePreviousAppDir=yes", "UseSetupLdr=yes", "DiskSpanning=no",
            "VersionInfoProductName=Uten IMP Windows Setup",
            "VersionInfoOriginalFileName=UtenIMPSetup.exe",
            "VersionInfoDescription=Uten IMP Windows Setup ({#PayloadArchitecture})",
            "english.AppDisplayName=UTEN",
            "chinesesimp.AppDisplayName=UTEN",
            'Name: "{autoprograms}\\{cm:AppDisplayName}"',
            'Name: "{userdesktop}\\{cm:AppDisplayName}"',
        ):
            self.assertIn(expected, script)
        self.assertEqual(1, script.count('Source: "{#PayloadDir}\\*"'))
        self.assertNotIn("[UninstallDelete]", script)
        self.assertNotIn("[InstallDelete]", script)


if __name__ == "__main__":
    unittest.main()
