import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from package_windows import MANIFEST_NAME, package_release
from test_build_windows_installer import setup_fixture
from test_package_windows import fixture_executable, runtime_fixtures
from verify_windows_release import verify_pair, verify_update_zip

ENDPOINTS = ("https://company.example/api", "https://cloud.example/api")
IDENTITY = {"CompanyName": "Uten", "ProductName": "优腾综合管理平台",
            "OriginalFileName": "uten_imp.exe", "InternalName": "uten_imp"}


def elf_blob(architecture: str = "x64", extra: bytes = b"") -> bytes:
    elf_class, machine = {"x86": (1, 3), "x64": (2, 62), "arm64": (2, 183)}[architecture]
    head = bytearray(64)
    head[:4] = b"\x7fELF"
    head[4], head[5], head[6] = elf_class, 1, 1
    struct.pack_into("<HH", head, 16, 3, machine)
    return bytes(head) + extra


def with_pe_characteristics(blob: bytes, characteristics: int) -> bytes:
    data = bytearray(blob)
    struct.pack_into("<H", data, 128 + 22, characteristics)
    return bytes(data)


def formal_bundle(bundle: Path, *, version=(2, 5, 31), build=2531, architecture="x64",
                  endpoints=ENDPOINTS, engine_dll=True, exe_identity=IDENTITY,
                  snapshot_architecture=None) -> Path:
    """A bundle that satisfies the server's paired_v1 byte contract, not just the packager's."""
    for relative in ("data/icudtl.dat", "data/flutter_assets/AssetManifest.bin", "client_updater/client_updater.ps1"):
        (bundle / relative).parent.mkdir(parents=True, exist_ok=True)
        (bundle / relative).write_bytes(b"synthetic fixture")
    (bundle / "uten_imp.exe").write_bytes(with_pe_characteristics(
        fixture_executable(build, architecture=architecture, version=version, strings=exe_identity),
        0x0002))
    runtime_fixtures(bundle, architecture=architecture)
    engine_characteristics = 0x2002 if engine_dll else 0x0002
    (bundle / "flutter_windows.dll").write_bytes(with_pe_characteristics(
        fixture_executable(build, architecture=architecture, version=version), engine_characteristics))
    snapshot = elf_blob(snapshot_architecture or architecture,
                        extra=b"".join(url.encode() for url in endpoints))
    (bundle / "data/app.so").write_bytes(snapshot)
    return bundle


class VerifyWindowsReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten release preflight ")
        self.root = Path(self.temporary.name)
        self.output = self.root / "update.zip"

    def tearDown(self):
        self.temporary.cleanup()

    def build_update(self, **bundle_options) -> Path:
        version = ".".join(str(part) for part in bundle_options.get("version", (2, 5, 31)))
        bundle = formal_bundle(self.root / "bundle", **bundle_options)
        package_release(bundle, self.output, build_number=2531, architecture="x64", version=version)
        return self.output

    def verify(self, path=None, **options):
        defaults = dict(version="2.5.31", build_number=2531, architecture="x64",
                        required_endpoints=ENDPOINTS)
        defaults.update(options)
        return verify_update_zip(path or self.output, **defaults)

    def rewrite_manifest(self, mutate) -> None:
        with zipfile.ZipFile(self.output) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        manifest = json.loads(entries[MANIFEST_NAME])
        mutate(manifest)
        entries[MANIFEST_NAME] = json.dumps(manifest).encode()
        with zipfile.ZipFile(self.output, "w") as archive:
            for name, content in entries.items():
                archive.writestr(name, content)

    def test_a_contract_clean_pair_passes(self):
        self.build_update()
        setup = self.root / "setup.exe"
        setup.write_bytes(setup_fixture(build=2531))
        verdict = verify_pair(setup, self.output, version="2.5.31", build_number=2531,
                              architecture="x64", required_endpoints=ENDPOINTS)
        self.assertEqual([], verdict["failures"], verdict["failures"])
        self.assertTrue(verdict["ok"])

    def test_manifest_without_version_is_rejected_exactly_like_the_server(self):
        self.build_update()
        self.rewrite_manifest(lambda manifest: manifest.pop("version"))
        report = self.verify()
        self.assertFalse(report["ok"])
        self.assertIn("manifest version is None", "; ".join(report["failures"]))

    def test_every_manifest_field_mismatch_is_reported_by_name(self):
        self.build_update()
        self.rewrite_manifest(lambda manifest: manifest.update(
            {"version": "9.9.9", "architecture": "arm64", "buildNumber": 1,
             "packageKind": "installer", "platform": "android"}))
        failures = "; ".join(self.verify()["failures"])
        for field in ("version", "architecture", "buildNumber", "packageKind", "platform"):
            self.assertIn(f"manifest {field}", failures)

    def test_unlisted_and_unhashed_files_are_rejected(self):
        self.build_update()
        with zipfile.ZipFile(self.output) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        with zipfile.ZipFile(self.output, "w") as archive:
            for name, content in entries.items():
                archive.writestr(name, b"tampered" if name == "data/icudtl.dat" else content)
            archive.writestr("data/flutter_assets/smuggled.dll", b"not in the manifest")
        failures = "; ".join(self.verify()["failures"])
        self.assertIn("does not match the archived bytes", failures)
        self.assertIn("data/flutter_assets/smuggled.dll", failures)

    def test_missing_approved_endpoint_is_rejected(self):
        self.build_update(endpoints=("https://company.example/api",))
        failures = "; ".join(self.verify()["failures"])
        self.assertIn("does not embed the approved endpoint https://cloud.example/api", failures)

    def test_engine_without_dll_flag_and_wrong_snapshot_machine_are_rejected(self):
        self.build_update(engine_dll=False, snapshot_architecture="x86")
        failures = "; ".join(self.verify()["failures"])
        self.assertIn("flutter_windows.dll PE characteristics do not mark a DLL", failures)
        self.assertIn("data/app.so is not an ELF shared object for x64", failures)

    def test_executable_identity_mismatch_is_rejected(self):
        self.build_update(exe_identity={**IDENTITY, "InternalName": "some_other_app"})
        failures = "; ".join(self.verify()["failures"])
        self.assertIn("uten_imp.exe internalname is 'some_other_app'", failures)

    def test_executable_version_resources_must_equal_the_publish_request(self):
        # Package honestly at 2.5.30, then publish-request 2.5.31: only the
        # preflight stands between the mismatch and the server's rejection.
        self.build_update(version=(2, 5, 30))
        self.rewrite_manifest(lambda manifest: manifest.update({"version": "2.5.31"}))
        failures = "; ".join(self.verify()["failures"])
        self.assertIn("uten_imp.exe fileVersion is (2, 5, 30, 2531), expected (2, 5, 31, 2531)", failures)

    def test_setup_with_wrong_version_resources_is_rejected(self):
        self.build_update()
        setup = self.root / "setup.exe"
        setup.write_bytes(setup_fixture(build=2530))
        verdict = verify_pair(setup, self.output, version="2.5.31", build_number=2531,
                              architecture="x64", required_endpoints=ENDPOINTS)
        self.assertFalse(verdict["ok"])
        self.assertIn("Setup binary version differs", "; ".join(verdict["failures"]))


if __name__ == "__main__":
    unittest.main()
