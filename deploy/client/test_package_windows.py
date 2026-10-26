import hashlib
import json
import shutil
import struct
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
import zipfile

from package_windows import MANIFEST_NAME, UPDATER_PATH, inspect_executable, package_release, validate_package, validate_release_path


def version_block(key: str, value: bytes = b"", *, value_length: int = 0,
                  kind: int = 1, children: tuple[bytes, ...] = ()) -> bytes:
    result = bytearray(struct.pack("<HHH", 0, value_length, kind) + (key + "\0").encode("utf-16le"))
    result.extend(b"\0" * (-len(result) % 4))
    result.extend(value)
    for child in children:
        result.extend(b"\0" * (-len(result) % 4))
        result.extend(child)
    struct.pack_into("<H", result, 0, len(result))
    return bytes(result)


def fixture_executable(build: int = 2, *, architecture: str = "x64", version=(1, 0, 0),
                       product_version=None, strings: dict[str, str] | None = None) -> bytes:
    """Small non-executable PE resource fixture with genuine version block trees."""
    numbers = (*version, build)
    product = product_version or numbers
    fixed = struct.pack("<13I", 0xFEEF04BD, 0x10000, numbers[0] << 16 | numbers[1],
                        numbers[2] << 16 | numbers[3], product[0] << 16 | product[1],
                        product[2] << 16 | product[3], 63, 0, 0x40004, 1, 0, 0, 0)
    children = ()
    if strings is not None:
        table = version_block("000004b0", children=tuple(
            version_block(key, (text + "\0").encode("utf-16le"), value_length=len(text) + 1)
            for key, text in strings.items()))
        children = (version_block("StringFileInfo", children=(table,)),)
    value = version_block("VS_VERSION_INFO", fixed, value_length=52, kind=0, children=children)
    resource_size = max(1024, 96 + len(value))
    data = bytearray(512 + resource_size)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\0\0"
    machine = {"x86": 0x14C, "x64": 0x8664, "arm64": 0xAA64}[architecture]
    optional_size, magic, directory_offset = (224, 0x10B, 96) if architecture == "x86" else (240, 0x20B, 112)
    struct.pack_into("<HH", data, 132, machine, 1)
    struct.pack_into("<H", data, 148, optional_size)
    struct.pack_into("<H", data, 152, magic)
    struct.pack_into("<II", data, 152 + directory_offset + 16, 4096, resource_size)
    section_offset = 152 + optional_size
    data[section_offset:section_offset + 8] = b".rsrc\0\0\0"
    struct.pack_into("<IIII", data, section_offset + 8, resource_size, 4096, resource_size, 512)
    for offset in (512, 536, 560):
        struct.pack_into("<HH", data, offset + 12, 0, 1)
    struct.pack_into("<II", data, 528, 16, 0x80000018)
    struct.pack_into("<II", data, 552, 1, 0x80000030)
    struct.pack_into("<II", data, 576, 1033, 72)
    struct.pack_into("<II", data, 584, 4096 + 96, len(value))
    data[608:608 + len(value)] = value
    return bytes(data)


class WindowsPackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "bundle"
        for relative in ("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat",
                         "data/flutter_assets/AssetManifest.bin", "client_updater/client_updater.ps1"):
            target = self.bundle / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(relative.encode())
        (self.bundle / "uten_imp.exe").write_bytes(fixture_executable())
        self.output = self.root / "release.zip"

    def tearDown(self):
        self.temporary.cleanup()

    def test_complete_package_excludes_trusted_running_updater(self):
        receipt = package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), receipt["sha256"])
        manifest = validate_package(self.output, build_number=2, architecture="x64")
        self.assertEqual(5, len(manifest["files"]))
        with zipfile.ZipFile(self.output) as archive:
            self.assertFalse(any("client_updater" in name for name in archive.namelist()))
            self.assertEqual(6, len(archive.namelist()))

    def test_forbids_path_traversal_ads_reserved_names_and_updater(self):
        for path in ("../uten_imp.exe", "/uten_imp.exe", "data/../x", "data\\x", "data/x:y",
                     "data/NUL.txt", "data/x. ", "client_updater/client_updater.ps1", "evil.exe"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                validate_release_path(path)

    def test_missing_runtime_and_unknown_root_file_are_rejected(self):
        (self.bundle / "data/app.so").unlink()
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")
        (self.bundle / "data/app.so").write_bytes(b"runtime")
        (self.bundle / "credentials.env").write_bytes(b"never ship")
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")

    def test_tamper_and_architecture_mismatch_are_rejected(self):
        package_release(self.bundle, self.output, build_number=2, architecture="x64")
        with self.assertRaises(ValueError):
            validate_package(self.output, build_number=2, architecture="arm64")
        with zipfile.ZipFile(self.output) as archive:
            records = [(entry.filename, archive.read(entry)) for entry in archive.infolist()]
        with zipfile.ZipFile(self.output, "w") as archive:
            for name, content in records:
                archive.writestr(name, b"corrupted" if name == "uten_imp.exe" else content)
        with self.assertRaises(ValueError):
            validate_package(self.output, build_number=2, architecture="x64")

    def test_case_duplicate_is_rejected(self):
        package_release(self.bundle, self.output, build_number=2, architecture="x64")
        with zipfile.ZipFile(self.output, "a") as archive:
            archive.writestr("DATA/app.so", b"duplicate")
        with self.assertRaises(ValueError):
            validate_package(self.output, build_number=2, architecture="x64")

    def test_manifest_does_not_list_itself_and_package_failure_preserves_previous_zip(self):
        self.output.write_bytes(b"existing release")
        (self.bundle / "data/app.so").unlink()
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertEqual(b"existing release", self.output.read_bytes())
        (self.bundle / "data/app.so").write_bytes(b"runtime")
        package_release(self.bundle, self.output, build_number=2, architecture="x64")
        with zipfile.ZipFile(self.output) as archive:
            manifest = json.loads(archive.read(MANIFEST_NAME))
            self.assertNotIn(MANIFEST_NAME, [record["path"] for record in manifest["files"]])

    def test_actual_executable_build_and_machine_must_match_metadata(self):
        self.assertEqual(("x64", 2), inspect_executable(self.bundle / "uten_imp.exe"))
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=3, architecture="x64")
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=2, architecture="arm64")
        (self.bundle / "uten_imp.exe").write_bytes(b"not a PE")
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")

    def test_installer_contains_the_hashed_fixed_updater(self):
        receipt = package_release(self.bundle, self.output, build_number=2, architecture="x64", kind="installer")
        self.assertEqual("windows_bundle", receipt["mode"])
        manifest = validate_package(self.output, build_number=2, architecture="x64", kind="installer")
        self.assertEqual("installer", manifest["packageKind"])
        self.assertEqual(6, len(manifest["files"]))
        with zipfile.ZipFile(self.output) as archive:
            updater = archive.read(UPDATER_PATH)
            expected = next(record for record in manifest["files"] if record["path"] == UPDATER_PATH)
            self.assertEqual({"path": UPDATER_PATH, "size": len(updater),
                              "sha256": hashlib.sha256(updater).hexdigest()}, expected)
            self.assertEqual((self.bundle / UPDATER_PATH).read_bytes(), updater)
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), receipt["sha256"])

    def test_installer_requires_a_nonempty_updater_without_replacing_prior_output(self):
        self.output.write_bytes(b"prior installer")
        updater = self.bundle / UPDATER_PATH
        updater.unlink()
        for payload in (None, b""):
            if payload is not None:
                updater.write_bytes(payload)
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                package_release(self.bundle, self.output, build_number=2, architecture="x64", kind="installer")
            self.assertEqual(b"prior installer", self.output.read_bytes())
        # Old callers can still produce an update from a bundle without an updater.
        updater.unlink()
        package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertNotIn("packageKind", validate_package(self.output, build_number=2, architecture="x64"))

    def test_installer_allowlist_permits_only_the_fixed_updater(self):
        validate_release_path(UPDATER_PATH, kind="installer")
        for path in ("client_updater/evil.ps1", "client_updater/../client_updater.ps1",
                     "client_updater/client_updater.ps1:alternate", "client_updater\\client_updater.ps1",
                     "client_updater/CLIENT_UPDATER.ps1", "setup.exe", "credentials.env"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                validate_release_path(path, kind="installer")
        (self.bundle / "client_updater/evil.ps1").write_text("must never ship")
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=2, architecture="x64", kind="installer")

    def test_installer_updater_tampering_is_rejected(self):
        package_release(self.bundle, self.output, build_number=2, architecture="x64", kind="installer")
        with zipfile.ZipFile(self.output) as archive:
            records = [(entry.filename, archive.read(entry)) for entry in archive.infolist()]
        with zipfile.ZipFile(self.output, "w") as archive:
            for name, content in records:
                archive.writestr(name, b"x" * len(content) if name == UPDATER_PATH else content)
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            validate_package(self.output, build_number=2, architecture="x64", kind="installer")

    def test_a_manifest_cannot_disguise_an_incomplete_update_as_an_installer(self):
        package_release(self.bundle, self.output, build_number=2, architecture="x64")
        with zipfile.ZipFile(self.output) as archive:
            records = [(entry.filename, archive.read(entry)) for entry in archive.infolist()]
        with zipfile.ZipFile(self.output, "w") as archive:
            for name, content in records:
                if name == MANIFEST_NAME:
                    manifest = json.loads(content)
                    manifest["packageKind"] = "installer"
                    content = json.dumps(manifest).encode()
                archive.writestr(name, content)
        with self.assertRaises(ValueError):
            validate_package(self.output, build_number=2, architecture="x64", kind="installer")

    def test_update_and_installer_packages_cannot_be_used_interchangeably(self):
        for actual, expected in (("installer", "update"), ("update", "installer")):
            with self.subTest(actual=actual):
                package_release(self.bundle, self.output, build_number=2, architecture="x64", kind=actual)
                with self.assertRaisesRegex(ValueError, "package kind"):
                    validate_package(self.output, build_number=2, architecture="x64", kind=expected)
        with self.assertRaisesRegex(ValueError, "package kind"):
            package_release(self.bundle, self.output, build_number=2, architecture="x64", kind="unknown")

    def test_default_update_manifest_and_receipt_remain_backward_compatible(self):
        receipt = package_release(self.bundle, self.output, build_number=2, architecture="x64")
        manifest = validate_package(self.output, build_number=2, architecture="x64")
        self.assertEqual("windows_archive", receipt["mode"])
        self.assertNotIn("packageKind", manifest)
        other = self.root / "explicit-update.zip"
        package_release(self.bundle, other, build_number=2, architecture="x64", kind="update")
        self.assertEqual(manifest, validate_package(other, build_number=2, architecture="x64", kind="update"))

    def test_installer_cli_generates_a_complete_bootstrap_archive(self):
        # Embedded distributions can expose their runtime directory here.
        executable = sys.executable if Path(sys.executable).is_file() else shutil.which("python")
        self.assertIsNotNone(executable, "A Python executable is required for the CLI regression")
        result = subprocess.run([executable, str(Path(__file__).with_name("package_windows.py")),
                                 "--bundle", str(self.bundle), "--output", str(self.output),
                                 "--build-number", "2", "--architecture", "x64", "--kind", "installer"],
                                capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("windows_bundle", json.loads(result.stdout)["mode"])
        self.assertEqual("installer", validate_package(self.output, build_number=2,
                                                       architecture="x64", kind="installer")["packageKind"])


if __name__ == "__main__":
    unittest.main()
