import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import build_windows_release as orchestrator
from build_windows_installer import build_windows_setup
from test_build_windows_installer import setup_fixture
from test_verify_windows_release import ENDPOINTS, formal_bundle

FAKE_COMMIT = "0123456789abcdef0123456789abcdef01234567"


def git_runner(outputs: dict[str, str]):
    """A subprocess boundary answering git commands from canned outputs."""
    def run(command, **options):
        key = " ".join(command[1:])
        if key not in outputs:
            return SimpleNamespace(returncode=1, stdout="", stderr=f"no canned answer for git {key}")
        return SimpleNamespace(returncode=0, stdout=outputs[key], stderr="")
    return run


def fixture_compiler_runner(command, **options):
    """ISCC boundary that materializes a version-correct Setup.exe from defines."""
    defines = dict(argument[2:].split("=", 1) for argument in command
                   if argument.startswith("/D") and "=" in argument)
    generated = Path(defines["OutputDir"]) / (defines["SetupBaseName"] + ".exe")
    generated.write_bytes(setup_fixture(build=int(defines["BuildNumber"])))
    return subprocess.CompletedProcess(command, 0, "synthetic compiler boundary", "")


class BuildWindowsReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten formal release ")
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        (self.repository / "pubspec.yaml").write_text(
            "name: uten_imp\nversion: 2.5.31+2531\n", encoding="utf-8")
        (self.repository / "pubspec.lock").write_bytes(b"locked mirror state")
        self.compiler = self.root / "fixture ISCC.exe"
        self.compiler.write_bytes(b"never executed")
        self.output_dir = self.root / "delivery"
        self.clean_git = git_runner({"rev-parse HEAD": FAKE_COMMIT + "\n", "status --porcelain": ""})
        self.dirty_git = git_runner({"rev-parse HEAD": FAKE_COMMIT + "\n",
                                     "status --porcelain": " M lib/something.dart\n"})

    def tearDown(self):
        self.temporary.cleanup()

    def fixture_repository(self, **bundle_options) -> None:
        formal_bundle(self.repository / orchestrator.BUNDLE, **bundle_options)

    def package_with_fixture_compiler(self, bundle, setup_path, update_path, *, version,
                                      build_number, architecture, compiler, repository, runner):
        build_windows_setup(bundle, setup_path, version=version, build_number=build_number,
                            architecture=architecture, compiler=compiler, compile=True,
                            update_output=update_path, source_root=repository,
                            runner=fixture_compiler_runner)

    def test_pubspec_is_the_only_version_source(self):
        self.assertEqual(("2.5.31", 2531), orchestrator.read_release_version(self.repository))
        (self.repository / "pubspec.yaml").write_text("name: uten_imp\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "bump the release version"):
            orchestrator.read_release_version(self.repository)

    def test_formal_endpoints_must_be_https_company_entries(self):
        self.assertEqual(("https://a.example/api", "https://b.example/api"),
                         orchestrator.formal_endpoints("https://a.example/api", "https://b.example/api"))
        for api, cloud in (("http://a.example/api", "https://b.example/api"),
                           ("https://a.example/api", "https://127.0.0.1:8443/api"),
                           ("https://localhost/api", "https://b.example/api")):
            with self.subTest(api=api), self.assertRaisesRegex(ValueError, "must be"):
                orchestrator.formal_endpoints(api, cloud)

    def test_dirty_tree_is_refused_unless_explicitly_recorded(self):
        self.fixture_repository()
        with self.assertRaisesRegex(ValueError, "working tree is dirty"):
            orchestrator.build_formal_release(self.repository, self.output_dir,
                                              api=ENDPOINTS[0], cloud_api=ENDPOINTS[1],
                                              runner=self.dirty_git, skip_build=True,
                                              package_pair=self.package_with_fixture_compiler,
                                              iscc=self.compiler)
        audit = orchestrator.audit_repository(self.repository, runner=self.dirty_git)
        self.assertFalse(audit["treeClean"])
        self.assertEqual([" M lib/something.dart"], audit["changes"])

    def test_formal_pair_end_to_end_with_preflight_and_receipt(self):
        self.fixture_repository()
        receipt = orchestrator.build_formal_release(self.repository, self.output_dir,
                                                    api=ENDPOINTS[0], cloud_api=ENDPOINTS[1],
                                                    runner=self.clean_git, skip_build=True,
                                                    package_pair=self.package_with_fixture_compiler,
                                                    iscc=self.compiler)
        self.assertEqual("FORMAL_WINDOWS_PAIR_READY_FOR_PUBLISH", receipt["state"])
        self.assertEqual((FAKE_COMMIT, True), (receipt["commit"], receipt["treeClean"]))
        self.assertEqual(("2.5.31", 2531, "x64"), (receipt["version"], receipt["buildNumber"], receipt["architecture"]))
        self.assertEqual([], receipt["preflight"]["failures"])
        setup = self.output_dir / "UTEN-2.5.31-Windows-x64-Setup.exe"
        update = self.output_dir / "UTEN-2.5.31-Windows-x64-update.zip"
        self.assertTrue(setup.is_file() and update.is_file())
        self.assertEqual(["installer", "update"], [a["packageKind"] for a in receipt["artifacts"]])
        self.assertEqual("2.5.31", receipt["artifacts"][1]["manifest"]["version"])
        for form in receipt["publishForm"]:
            self.assertEqual("windows", form["platform"])
            self.assertEqual("flutter", form["runtimeFamily"])
        written = json.loads((self.output_dir / "delivery-receipt.json").read_text(encoding="utf-8"))
        self.assertEqual(receipt["state"], written["state"])
        self.assertFalse(written["publication"]["clientCatalogPublicationPerformed"])

    def test_a_pair_that_fails_preflight_is_marked_rejected_not_ready(self):
        self.fixture_repository(engine_dll=False)
        receipt = orchestrator.build_formal_release(self.repository, self.output_dir,
                                                    api=ENDPOINTS[0], cloud_api=ENDPOINTS[1],
                                                    runner=self.clean_git, skip_build=True,
                                                    package_pair=self.package_with_fixture_compiler,
                                                    iscc=self.compiler)
        self.assertEqual("FORMAL_WINDOWS_PAIR_REJECTED_BY_PREFLIGHT", receipt["state"])
        self.assertIn("flutter_windows.dll PE characteristics do not mark a DLL",
                      "; ".join(receipt["preflight"]["failures"]))

    def test_missing_endpoint_blocks_packaging_before_any_artifact(self):
        self.fixture_repository(endpoints=(ENDPOINTS[0],))
        with self.assertRaisesRegex(ValueError, "endpoints missing from data/app.so"):
            orchestrator.build_formal_release(self.repository, self.output_dir,
                                              api=ENDPOINTS[0], cloud_api=ENDPOINTS[1],
                                              runner=self.clean_git, skip_build=True,
                                              package_pair=self.package_with_fixture_compiler,
                                              iscc=self.compiler)
        self.assertFalse(self.output_dir.exists())

    def test_mirror_rewritten_pubspec_lock_is_restored_on_a_clean_tree(self):
        self.fixture_repository()
        lock_before = (self.repository / "pubspec.lock").read_bytes()

        def flutter_build(repository, *, version, build_number, api, cloud_api, runner):
            (repository / "pubspec.lock").write_bytes(b"rewritten by the cn mirror")

        receipt = orchestrator.build_formal_release(self.repository, self.output_dir,
                                                    api=ENDPOINTS[0], cloud_api=ENDPOINTS[1],
                                                    runner=self.clean_git,
                                                    flutter_build=flutter_build,
                                                    package_pair=self.package_with_fixture_compiler,
                                                    iscc=self.compiler)
        self.assertEqual("executed", receipt["flutterBuild"])
        self.assertEqual(lock_before, (self.repository / "pubspec.lock").read_bytes())

    def test_pubspec_lock_change_survives_and_is_recorded_on_a_dirty_tree(self):
        self.fixture_repository()

        def flutter_build(repository, *, version, build_number, api, cloud_api, runner):
            (repository / "pubspec.lock").write_bytes(b"rewritten by the cn mirror")

        receipt = orchestrator.build_formal_release(self.repository, self.output_dir,
                                                    api=ENDPOINTS[0], cloud_api=ENDPOINTS[1],
                                                    runner=self.dirty_git, allow_dirty=True,
                                                    flutter_build=flutter_build,
                                                    package_pair=self.package_with_fixture_compiler,
                                                    iscc=self.compiler)
        self.assertEqual(b"rewritten by the cn mirror", (self.repository / "pubspec.lock").read_bytes())
        self.assertIn("pubspec.lock changed during the build", receipt["pubspecLockNote"])


if __name__ == "__main__":
    unittest.main()
