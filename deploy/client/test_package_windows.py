import hashlib
import json
import struct
from pathlib import Path
import tempfile
import unittest
import zipfile

from package_windows import MANIFEST_NAME, inspect_executable, package_release, validate_package, validate_release_path


def fixture_executable(build: int = 2) -> bytes:
    """Small PE resource fixture with a genuine RT_VERSION directory tree."""
    data = bytearray(1536)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\0\0"
    struct.pack_into("<HH", data, 132, 0x8664, 1)
    struct.pack_into("<H", data, 148, 240)
    struct.pack_into("<H", data, 152, 0x20B)
    struct.pack_into("<II", data, 280, 4096, 1024)
    data[392:400] = b".rsrc\0\0\0"
    struct.pack_into("<IIII", data, 400, 1024, 4096, 1024, 512)
    for offset in (512, 536, 560):
        struct.pack_into("<HH", data, offset + 12, 0, 1)
    struct.pack_into("<II", data, 528, 16, 0x80000018)
    struct.pack_into("<II", data, 552, 1, 0x80000030)
    struct.pack_into("<II", data, 576, 1033, 72)
    struct.pack_into("<II", data, 584, 4096 + 96, 92)
    struct.pack_into("<HHH", data, 608, 92, 52, 0)
    key = "VS_VERSION_INFO\0".encode("utf-16le")
    data[614:614 + len(key)] = key
    struct.pack_into("<13I", data, 648, 0xFEEF04BD, 0x10000, 0x10000, build,
                     0x10000, build, 63, 0, 0x40004, 1, 0, 0, 0)
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


if __name__ == "__main__":
    unittest.main()
