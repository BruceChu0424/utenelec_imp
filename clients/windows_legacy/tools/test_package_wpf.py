"""Offline, non-executable PE fixtures: no real installer/runtime is run or published."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import package_wpf as package

sys.path.insert(0, str(package.ROOT / "deploy/client"))
from test_package_windows import fixture_executable


def managed_fixture(architecture="x64", *, dll=False, anycpu=False, marker=package.MARKER,
                    build=45, version=(1, 2, 3), metadata_version=b"v4.0.30319\0", flags=None):
    machine_architecture = "x86" if anycpu else architecture
    data = bytearray(fixture_executable(build, architecture=machine_architecture, version=version,
                                       strings={"Comments": marker}))
    pe, optional = 128, 152
    struct.pack_into("<H", data, pe + 22, 0x2002 if dll else 2)
    optional_size = 224 if machine_architecture == "x86" else 240
    directory_offset = 96 if machine_architecture == "x86" else 112
    section = optional + optional_size
    clr = len(data)
    metadata = clr + 72
    metadata_bytes = b"BSJB" + struct.pack("<HHII", 1, 1, 0, len(metadata_version)) + metadata_version
    data.extend(b"\0" * 72 + metadata_bytes)
    raw_size = len(data) - 512
    struct.pack_into("<I", data, section + 8, raw_size)
    struct.pack_into("<I", data, section + 16, raw_size)
    struct.pack_into("<II", data, optional + directory_offset + 14 * 8, 4096 + clr - 512, 72)
    if flags is None:
        flags = 1 if anycpu or architecture == "x64" else 3
    struct.pack_into("<IHHIIII", data, clr, 72, 2, 5, 4096 + metadata - 512,
                     len(metadata_bytes), flags, 0)
    return bytes(data)


class WpfCandidatePackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten WPF candidate fixture ")
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "clean source"
        self.source.mkdir()
        self.bundle = self.root / "approved payload"
        self.bundle.mkdir()
        self.output = self.root / "not created" / "candidate.zip"
        self.receipt = self.root / "receipt.json"
        self.config = {"endpoints": [{"id": "company", "name": "Company", "apiBaseUrl": "https://company.example/api"}],
                       "selectedEndpointId": "company"}
        self.bc = managed_fixture(dll=True, anycpu=True, build=0, version=(2, 7, 0))
        license_bytes = b"Synthetic dependency license fixture."
        self.lock = self.source / "clients/windows_legacy/dependencies.lock.json"
        for name in package.SOURCE_REQUIRED:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic source input", encoding="utf-8")
        (self.source / "pubspec.yaml").write_text("name: fixture\nversion: 1.2.3+45\n", encoding="utf-8")
        (self.source / "clients/windows_legacy/package-contract.json").write_bytes(package.CONTRACT_PATH.read_bytes())
        self.lock.write_text(json.dumps({"schemaVersion": 1, "package": "BouncyCastle.Cryptography", "version": "2.7.0", "targetFramework": "net461", "files": {
            "lib/net461/BouncyCastle.Cryptography.dll": hashlib.sha256(self.bc).hexdigest(),
            "LICENSE.md": hashlib.sha256(license_bytes).hexdigest()}}), encoding="utf-8")
        config_bytes = json.dumps(self.config).encode("utf-8")
        (self.source / "clients/windows_legacy/Uten.Legacy.Desktop/uten.client.json").write_bytes(config_bytes)
        (self.bundle / package.EXECUTABLE).write_bytes(managed_fixture())
        (self.bundle / package.CORE).write_bytes(managed_fixture(dll=True, anycpu=True))
        (self.bundle / package.BC).write_bytes(self.bc)
        (self.bundle / package.LICENSE).write_bytes(license_bytes)
        (self.bundle / "uten.client.json").write_bytes(config_bytes)
        (self.bundle / package.APP_CONFIG).write_text(
            '<configuration><startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8"/>'
            '</startup><runtime/></configuration>', encoding="utf-8")
        self.patch = mock.patch.object(package, "DEPENDENCY_LOCK", self.lock)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=WPF Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=disabled-hooks", "commit", "-qm", "synthetic reviewed source")
        self.state = package.capture_source_state(self.source)
        self.issue_receipt()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        result = subprocess.run(["git", "-C", str(self.source), *arguments], capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        return result.stdout

    def issue_receipt(self, **options):
        return package.write_build_receipt(self.bundle, self.receipt, architecture=options.pop("architecture", "x64"),
            source_root=self.source, source_state=self.state, configuration=options.pop("configuration", "Release"),
            distribution_profile=options.pop("distribution_profile", "Company"), **options)

    def build(self, **options):
        return package.package_update(self.bundle, self.output, architecture=options.pop("architecture", "x64"),
            source_root=self.source, receipt_path=self.receipt, **options)

    def validate(self):
        return package.validate_package(self.output, architecture="x64", version="1.2.3", build_number=45)

    def rewrite_zip(self, mutate):
        with zipfile.ZipFile(self.output) as archive:
            entries = {entry.filename: archive.read(entry) for entry in archive.infolist()}
        mutate(entries)
        with zipfile.ZipFile(self.output, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    def test_default_is_read_only_dry_run_with_no_zip_or_directory(self):
        result = self.build()
        self.assertEqual("dry-run", result["mode"])
        self.assertFalse(result["releaseReady"])
        self.assertTrue(result["candidate"])
        self.assertFalse(self.output.parent.exists())
        self.assertFalse((self.bundle / package.MANIFEST).exists())

    def test_candidate_round_trip_exact_files_hashes_and_family(self):
        result = self.build(build=True)
        self.assertEqual("candidate", result["mode"])
        self.assertFalse(result["releaseReady"])
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), result["sha256"])
        manifest = self.validate()
        self.assertEqual("wpf_legacy", manifest["runtimeFamily"])
        self.assertEqual("update", manifest["packageKind"])
        self.assertEqual("1.2.3", manifest["version"])
        self.assertEqual(45, manifest["buildNumber"])
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(package.REQUIRED | {package.MANIFEST}, set(archive.namelist()))
            for item in manifest["files"]:
                data = archive.read(item["path"])
                self.assertEqual(len(data), item["size"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"])

    def test_x86_requires_explicit_32bit_clr_main_and_accepts_same_arch_core(self):
        (self.bundle / package.EXECUTABLE).write_bytes(managed_fixture("x86"))
        (self.bundle / package.CORE).write_bytes(managed_fixture("x86", dll=True))
        self.issue_receipt(architecture="x86")
        result = self.build(architecture="x86", build=True)
        self.assertEqual("x86", result["architecture"])
        package.validate_package(self.output, architecture="x86", version="1.2.3", build_number=45)

    def test_anycpu_main_or_wrong_core_architecture_is_rejected(self):
        (self.bundle / package.EXECUTABLE).write_bytes(managed_fixture(anycpu=True))
        with self.assertRaisesRegex(ValueError, "CLR architecture"):
            self.issue_receipt(architecture="x86")
        (self.bundle / package.EXECUTABLE).write_bytes(managed_fixture())
        (self.bundle / package.CORE).write_bytes(managed_fixture("x86", dll=True))
        with self.assertRaisesRegex(ValueError, "CLR architecture"):
            self.issue_receipt()

    def test_clr_v2_or_native_entrypoint_cannot_pass(self):
        for data in (managed_fixture(metadata_version=b"v2.0.50727\0"), managed_fixture(flags=0x11)):
            (self.bundle / package.EXECUTABLE).write_bytes(data)
            with self.assertRaises(ValueError):
                self.issue_receipt()

    def test_both_main_and_core_must_have_exact_pubspec_version(self):
        for name in (package.EXECUTABLE, package.CORE):
            original = (self.bundle / name).read_bytes()
            (self.bundle / name).write_bytes(managed_fixture(dll=name == package.CORE, anycpu=name == package.CORE, build=44))
            try:
                with self.assertRaisesRegex(ValueError, "pubspec"):
                    self.issue_receipt()
            finally:
                (self.bundle / name).write_bytes(original)

    def test_debug_localtest_and_unreviewed_compiled_markers_are_rejected(self):
        for configuration, profile in (("Debug", "Company"), ("Release", "LocalTest"), ("Release", "Unreviewed")):
            (self.bundle / package.EXECUTABLE).write_bytes(managed_fixture(
                marker=f"UTEN WPF candidate; Configuration={configuration}; Distribution={profile}"))
            with self.assertRaisesRegex(ValueError, "Debug/LocalTest"):
                self.issue_receipt()

    def test_self_declared_receipt_cannot_override_compiled_profile(self):
        for configuration, profile in (("Debug", "Company"), ("Release", "LocalTest")):
            with self.assertRaisesRegex(ValueError, "explicit Release/Company"):
                self.issue_receipt(configuration=configuration, distribution_profile=profile)

    def test_fixed_bc_dll_and_license_hashes_are_both_required(self):
        for name in (package.BC, package.LICENSE):
            original = (self.bundle / name).read_bytes()
            (self.bundle / name).write_bytes(original + b"modified")
            try:
                with self.assertRaisesRegex(ValueError, "fixed private dependency lock"):
                    self.issue_receipt()
            finally:
                (self.bundle / name).write_bytes(original)

    def test_unknown_private_files_profiles_pdb_and_symlinks_are_forbidden(self):
        for name in ("session.json", "password.txt", "Uten.Legacy.Desktop.pdb", "User Data"):
            path = self.bundle / name
            path.write_bytes(b"private fixture")
            try:
                with self.assertRaisesRegex(ValueError, "approved app files"):
                    self.issue_receipt()
            finally:
                path.unlink()
        target = self.bundle / "uten.client.json"
        original = target.read_bytes()
        target.unlink()
        try:
            target.symlink_to(self.source / "clients/windows_legacy/Uten.Legacy.Desktop/uten.client.json")
        except OSError:
            target.write_bytes(original)
            self.skipTest("Host does not permit an unprivileged symlink fixture")
        with self.assertRaisesRegex(ValueError, "Symlinks"):
            self.issue_receipt()

    def test_endpoint_configuration_rejects_localhost_http_credentials_and_private_fields(self):
        for url in ("http://company.example/api", "https://localhost/api", "https://127.1/api",
                    "https://[::ffff:127.0.0.1]/api", "https://0x7f000001/api", "https://name:secret@company.example/api"):
            data = json.loads(json.dumps(self.config))
            data["endpoints"][0]["apiBaseUrl"] = url
            (self.bundle / "uten.client.json").write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(ValueError, msg=url):
                self.issue_receipt()
        data = {**self.config, "password": "private fixture"}
        (self.bundle / "uten.client.json").write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "private settings"):
            self.issue_receipt()

    def test_other_https_endpoint_still_requires_the_reviewed_source_configuration(self):
        data = json.loads(json.dumps(self.config))
        data["endpoints"][0]["apiBaseUrl"] = "https://other.example/api"
        (self.bundle / "uten.client.json").write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "reviewed Company source"):
            self.issue_receipt()

    def test_runtime_requires_net48_without_dtd_or_remote_assembly_loading(self):
        for config in ('<configuration><startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.7"/></startup></configuration>',
                       '<!DOCTYPE x [<!ENTITY secret "x">]><configuration/>',
                       '<configuration><runtime><loadFromRemoteSources enabled="true"/></runtime></configuration>'):
            (self.bundle / package.APP_CONFIG).write_text(config, encoding="utf-8")
            with self.assertRaises(ValueError):
                self.issue_receipt()

    def test_dirty_or_changed_source_cannot_get_or_use_a_receipt(self):
        source_file = self.source / "pubspec.yaml"
        source_file.write_text("name: fixture\nversion: 1.2.3+46\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "committed and clean"):
            self.build()
        self.git("add", ".")
        self.git("-c", "user.name=WPF Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                 "-c", "core.hooksPath=disabled-hooks", "commit", "-qm", "new reviewed version")
        with self.assertRaisesRegex(ValueError, "receipt"):
            self.build()
        with self.assertRaisesRegex(ValueError, "changed during compilation"):
            self.issue_receipt()

    def test_payload_changed_after_receipt_never_overwrites_previous_output(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"previous candidate bytes")
        with (self.bundle / package.EXECUTABLE).open("ab") as stream:
            stream.write(b"unreceipted non-executable overlay")
        with self.assertRaisesRegex(ValueError, "changed after"):
            self.build(build=True)
        self.assertEqual(b"previous candidate bytes", self.output.read_bytes())

    def test_mutation_during_private_freeze_preserves_previous_output(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"previous candidate bytes")
        original_copy = shutil.copyfile
        def mutate(source, target):
            if Path(source).name == package.EXECUTABLE:
                Path(source).write_bytes(b"changed before snapshot copy")
            return original_copy(source, target)
        with mock.patch.object(package.shutil, "copyfile", side_effect=mutate):
            with self.assertRaises(ValueError):
                self.build(build=True)
        self.assertEqual(b"previous candidate bytes", self.output.read_bytes())

    def test_zip_tamper_wrong_family_and_unlisted_files_fail_independent_verification(self):
        self.build(build=True)
        original = self.output.read_bytes()
        def family(entries):
            manifest = json.loads(entries[package.MANIFEST])
            manifest["runtimeFamily"] = "flutter"
            entries[package.MANIFEST] = json.dumps(manifest).encode()
        def tamper(entries):
            entries[package.LICENSE] += b"modified"
        def private(entries):
            entries["profile/credentials.json"] = b"private fixture"
        for mutation in (family, tamper, private):
            self.output.write_bytes(original)
            self.rewrite_zip(mutation)
            with self.assertRaises(ValueError):
                self.validate()

    def test_shared_managed_and_manifest_limits_are_enforced(self):
        self.build(build=True)
        self.rewrite_zip(lambda entries: entries.__setitem__(package.MANIFEST,
            entries[package.MANIFEST] + b" " * package.MAX_MANIFEST_BYTES))
        with self.assertRaisesRegex(ValueError, "manifest exceeds"):
            self.validate()
        executable = self.bundle / package.EXECUTABLE
        with executable.open("r+b") as stream:
            stream.truncate(package.CONTRACT["maximumManagedFileBytes"] + 1)
        with self.assertRaisesRegex(ValueError, "Managed file exceeds"):
            package.inspect_managed(executable, executable=True)

    def test_reviewed_source_contract_must_match_the_executing_tool(self):
        path = self.source / "clients/windows_legacy/package-contract.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        value["contractId"] = "different-reviewed-contract"
        path.write_text(json.dumps(value), encoding="utf-8")
        self.git("add", ".")
        self.git("-c", "user.name=WPF Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                 "-c", "core.hooksPath=disabled-hooks", "commit", "-qm", "different synthetic source contract")
        with self.assertRaisesRegex(ValueError, "contract/dependency lock differs"):
            package.capture_source_state(self.source)

    def test_directory_count_zip64_and_oversized_directory_reject_before_zipfile_allocation(self):
        self.build(build=True)
        original = self.output.read_bytes()
        for offset, format, number in ((8, "<H", 65535), (10, "<H", 65535),
                                      (12, "<I", package.CONTRACT["maximumCentralDirectoryBytes"] + 1),
                                      (4, "<H", 1)):
            data = bytearray(original)
            end = data.rfind(b"PK\x05\x06")
            struct.pack_into(format, data, end + offset, number)
            self.output.write_bytes(data)
            with mock.patch.object(package.zipfile, "ZipFile", side_effect=AssertionError("ZIP entries allocated before directory gate")):
                with self.assertRaisesRegex(ValueError, "bounded seven-entry"):
                    self.validate()


if __name__ == "__main__":
    unittest.main()
