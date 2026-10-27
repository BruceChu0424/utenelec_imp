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
from unittest import mock

import package_windows as package_module

from package_windows import (MANIFEST_NAME, UPDATER_PATH, inspect_executable, inspect_pe_imports,
                             package_release, required_vc_runtime, validate_package, validate_release_path)


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
                       product_version=None, strings: dict[str, str] | None = None,
                       imports: tuple[str, ...] = (), delay_imports: tuple[str, ...] = ()) -> bytes:
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
    import_offset = (96 + len(value) + 15) & ~15
    import_data = bytearray()
    directories = {}
    for directory, names, width in ((1, imports, 20), (13, delay_imports, 32)):
        if not names:
            continue
        start = len(import_data)
        import_data.extend(b"\0" * ((len(names) + 1) * width))
        for index, name in enumerate(names):
            name_rva = 4096 + import_offset + len(import_data)
            import_data.extend(name.encode("ascii") + b"\0")
            import_data.extend(b"\0" * (-len(import_data) % 8))
            thunk_rva = 4096 + import_offset + len(import_data)
            import_data.extend(b"\0" * 8)
            if directory == 1:
                struct.pack_into("<IIIII", import_data, start + index * width,
                                 thunk_rva, 0, 0, name_rva, thunk_rva)
            else:
                struct.pack_into("<8I", import_data, start + index * width,
                                 1, name_rva, 0, thunk_rva, thunk_rva, 0, 0, 0)
        directories[directory] = (4096 + import_offset + start, (len(names) + 1) * width)
    resource_size = max(1024, import_offset + len(import_data))
    data = bytearray(512 + resource_size)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 60, 128)
    data[128:132] = b"PE\0\0"
    machine = {"x86": 0x14C, "x64": 0x8664, "arm64": 0xAA64}[architecture]
    optional_size, magic, directory_offset = (224, 0x10B, 96) if architecture == "x86" else (240, 0x20B, 112)
    struct.pack_into("<HH", data, 132, machine, 1)
    struct.pack_into("<H", data, 148, optional_size)
    struct.pack_into("<H", data, 152, magic)
    struct.pack_into("<I", data, 152 + 60, 512)
    struct.pack_into("<I", data, 152 + directory_offset - 4, 16)
    struct.pack_into("<I" if architecture == "x86" else "<Q", data,
                     152 + (28 if architecture == "x86" else 24),
                     0x400000 if architecture == "x86" else 0x140000000)
    struct.pack_into("<II", data, 152 + directory_offset + 16, 4096, resource_size)
    for directory, descriptor in directories.items():
        struct.pack_into("<II", data, 152 + directory_offset + directory * 8, *descriptor)
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
    data[512 + import_offset:512 + import_offset + len(import_data)] = import_data
    return bytes(data)


def runtime_fixtures(bundle: Path, *, architecture: str = "x64") -> None:
    """Native modules have real PE/import tables; no production check is mocked."""
    for name in ("flutter_windows.dll", *sorted(required_vc_runtime(architecture))):
        (bundle / name).write_bytes(fixture_executable(architecture=architecture,
                                                       imports=("KERNEL32.dll",)))


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
        runtime_fixtures(self.bundle)
        self.output = self.root / "release.zip"

    def tearDown(self):
        self.temporary.cleanup()

    def test_complete_package_excludes_trusted_running_updater(self):
        receipt = package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertEqual(hashlib.sha256(self.output.read_bytes()).hexdigest(), receipt["sha256"])
        manifest = validate_package(self.output, build_number=2, architecture="x64")
        self.assertEqual(8, len(manifest["files"]))
        with zipfile.ZipFile(self.output) as archive:
            self.assertFalse(any("client_updater" in name for name in archive.namelist()))
            self.assertEqual(9, len(archive.namelist()))

    def test_every_package_kind_requires_all_architecture_core_runtimes(self):
        for kind in ("update", "installer"):
            for name in required_vc_runtime("x64"):
                target = self.bundle / name
                content = target.read_bytes()
                target.unlink()
                self.output.write_bytes(b"previous approved output")
                try:
                    with self.subTest(kind=kind, missing=name), self.assertRaisesRegex(ValueError, "app-local Visual C"):
                        package_release(self.bundle, self.output, build_number=2, architecture="x64", kind=kind)
                    self.assertEqual(b"previous approved output", self.output.read_bytes())
                finally:
                    target.write_bytes(content)

    def test_windows_runtime_module_names_are_case_insensitive(self):
        (self.bundle / "msvcp140.dll").rename(self.bundle / "MSVCP140.DLL")
        (self.bundle / "flutter_windows.dll").rename(self.bundle / "FLUTTER_WINDOWS.DLL")
        (self.bundle / "uten_imp.exe").write_bytes(fixture_executable(imports=("msvcp140.dll", "flutter_windows.dll")))
        receipt = package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertEqual(5, receipt["runtimeValidation"]["peModuleCount"])
        self.assertEqual(2, receipt["runtimeValidation"]["packagedModuleEdges"])

    def test_core_runtime_hidden_under_data_cannot_satisfy_app_root_requirement(self):
        (self.bundle / "msvcp140.dll").rename(self.bundle / "data/msvcp140.dll")
        self.output.write_bytes(b"previous approved package")
        for kind in ("update", "installer"):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "app-local Visual C.*msvcp140.dll"):
                package_release(self.bundle, self.output, build_number=2, architecture="x64", kind=kind)
        self.assertEqual(b"previous approved package", self.output.read_bytes())

    def test_core_requirements_keep_supported_architecture_differences(self):
        for architecture in ("x86", "arm64"):
            (self.bundle / "vcruntime140_1.dll").unlink(missing_ok=True)
            runtime_fixtures(self.bundle, architecture=architecture)
            (self.bundle / "uten_imp.exe").write_bytes(fixture_executable(architecture=architecture))
            receipt = package_release(self.bundle, self.output, build_number=2, architecture=architecture)
            self.assertEqual(sorted(required_vc_runtime(architecture)), receipt["runtimeValidation"]["requiredVcRuntime"])
            validate_package(self.output, build_number=2, architecture=architecture)

    def test_normal_delay_and_nested_dependencies_are_closed_before_publication(self):
        (self.bundle / "uten_imp.exe").write_bytes(fixture_executable(
            imports=("codec.dll",), delay_imports=("optional.dll",)))
        self.output.write_bytes(b"previous package")
        with self.assertRaisesRegex(ValueError, "normal import.*codec.dll"):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")
        (self.bundle / "codec.dll").write_bytes(fixture_executable(imports=("codec_helper.dll",)))
        with self.assertRaisesRegex(ValueError, "codec.dll -> codec_helper.dll"):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")
        (self.bundle / "codec_helper.dll").write_bytes(fixture_executable(imports=("api-ms-win-crt-runtime-l1-1-0.dll",)))
        with self.assertRaisesRegex(ValueError, "delay import.*optional.dll"):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertEqual(b"previous package", self.output.read_bytes())
        (self.bundle / "optional.dll").write_bytes(fixture_executable())
        receipt = package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertEqual(1, receipt["runtimeValidation"]["delayImportEdges"])
        self.assertEqual(3, receipt["runtimeValidation"]["packagedModuleEdges"])

    def test_module_in_unsearched_subdirectory_does_not_satisfy_an_import(self):
        (self.bundle / "uten_imp.exe").write_bytes(fixture_executable(imports=("codec.dll",)))
        (self.bundle / "data/codec.dll").write_bytes(fixture_executable())
        with self.assertRaisesRegex(ValueError, "Unresolved non-OS"):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")
        (self.bundle / "uten_imp.exe").write_bytes(fixture_executable())
        (self.bundle / "data/codec.dll").write_bytes(fixture_executable(imports=("msvcp140.dll",)))
        package_release(self.bundle, self.output, build_number=2, architecture="x64")

    def test_all_native_modules_including_unreferenced_nested_dlls_require_target_machine(self):
        (self.bundle / "data/foreign.dll").write_bytes(fixture_executable(architecture="x86"))
        with self.assertRaisesRegex(ValueError, "architecture differs.*data/foreign.dll"):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")
        (self.bundle / "data/foreign.dll").write_bytes(b"not a PE DLL")
        with self.assertRaises(ValueError):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")

    def test_debug_runtimes_are_rejected_even_with_complete_release_crt(self):
        for name in ("msvcp140d.dll", "msvcp140d_atomic_wait.dll", "vcruntime140_1d.dll", "ucrtbased.dll"):
            with self.subTest(name=name):
                target = self.bundle / name
                target.write_bytes(fixture_executable())
                try:
                    with self.assertRaisesRegex(ValueError, "Debug runtime"):
                        package_release(self.bundle, self.output, build_number=2, architecture="x64")
                finally:
                    target.unlink()
        (self.bundle / "uten_imp.exe").write_bytes(fixture_executable(delay_imports=("vcruntime140d.dll",)))
        with self.assertRaisesRegex(ValueError, "Debug runtime import"):
            package_release(self.bundle, self.output, build_number=2, architecture="x64")

    def test_pe32_absolute_delay_import_names_and_malformed_tables(self):
        binary = bytearray(fixture_executable(architecture="x86", delay_imports=("missing.dll",)))
        directory = 152 + 96 + 13 * 8
        rva, _ = struct.unpack_from("<II", binary, directory)
        offset = 512 + rva - 4096
        name_rva = struct.unpack_from("<I", binary, offset + 4)[0]
        struct.pack_into("<II", binary, offset, 0, name_rva + 0x400000)
        candidate = self.root / "delay-x86.dll"
        candidate.write_bytes(binary)
        self.assertEqual([{"module": "missing.dll", "kind": "delay"}], inspect_pe_imports(candidate)["imports"])
        struct.pack_into("<II", binary, directory, 0xFFFFFF00, 64)
        candidate.write_bytes(binary)
        with self.assertRaises(ValueError):
            inspect_pe_imports(candidate)
        binary = bytearray(fixture_executable(imports=("kernel32.dll",)))
        rva, _ = struct.unpack_from("<II", binary, 152 + 112 + 8)
        struct.pack_into("<I", binary, 512 + rva - 4096 + 20, 1)
        candidate.write_bytes(binary)
        with self.assertRaisesRegex(ValueError, "no terminator"):
            inspect_pe_imports(candidate)

    def test_finished_archive_with_recomputed_hashes_still_requires_runtime_closure(self):
        package_release(self.bundle, self.output, build_number=2, architecture="x64")
        with zipfile.ZipFile(self.output) as archive:
            content = {item.filename: archive.read(item) for item in archive.infolist()}
        content["flutter_windows.dll"] = fixture_executable(delay_imports=("unavailable.dll",))
        manifest = json.loads(content[MANIFEST_NAME])
        for record in manifest["files"]:
            payload = content[record["path"]]
            record.update(size=len(payload), sha256=hashlib.sha256(payload).hexdigest())
        content[MANIFEST_NAME] = json.dumps(manifest).encode()
        with zipfile.ZipFile(self.output, "w") as archive:
            for name, payload in content.items():
                archive.writestr(name, payload)
        with self.assertRaisesRegex(ValueError, "delay import.*unavailable.dll"):
            validate_package(self.output, build_number=2, architecture="x64")

    def _unused_jni_fixture(self):
        (self.root / "pubspec.yaml").write_text("name: runtime_fixture\n", encoding="utf-8")
        (self.root / "lib").mkdir(exist_ok=True)
        (self.root / "lib/main.dart").write_text("void main() {}\n", encoding="utf-8")
        (self.bundle / "data/flutter_assets/NativeAssetsManifest.json").write_text(
            json.dumps({"format-version": [1, 0, 0], "native-assets": {}}), encoding="utf-8")
        (self.bundle / "dartjni.dll").write_bytes(fixture_executable(imports=("jvm.dll",)))

    def test_only_proven_unused_transitive_jni_is_omitted_without_modifying_input(self):
        self._unused_jni_fixture()
        before = (self.bundle / "dartjni.dll").read_bytes()
        receipt = package_release(self.bundle, self.output, build_number=2, architecture="x64")
        self.assertEqual(before, (self.bundle / "dartjni.dll").read_bytes())
        self.assertEqual("dartjni.dll", receipt["omittedUnusedNativeArtifacts"][0]["path"])
        with zipfile.ZipFile(self.output) as archive:
            self.assertNotIn("dartjni.dll", archive.namelist())

    def test_jni_without_each_source_assets_aot_or_import_proof_fails_closed(self):
        self._unused_jni_fixture()
        for blocker in ("source", "source-flutter", "native-assets", "aot-utf8", "aot-utf16", "pe-referrer", "no-source"):
            self._unused_jni_fixture()
            (self.bundle / "uten_imp.exe").write_bytes(fixture_executable())
            (self.bundle / "data/app.so").write_bytes(b"application snapshot")
            source_root = self.root
            if blocker.startswith("source"):
                package = "jni_flutter" if blocker == "source-flutter" else "jni"
                (self.root / "lib/main.dart").write_text(f"import 'package:{package}/jni.dart';", encoding="utf-8")
            elif blocker == "native-assets":
                (self.bundle / "data/flutter_assets/NativeAssetsManifest.json").write_text(
                    json.dumps({"native-assets": {"jni": "dartjni.dll"}}), encoding="utf-8")
            elif blocker.startswith("aot"):
                (self.bundle / "data/app.so").write_bytes("dartjni.dll".encode("utf-16le" if blocker.endswith("16") else "utf-8"))
            elif blocker == "pe-referrer":
                (self.bundle / "uten_imp.exe").write_bytes(fixture_executable(delay_imports=("dartjni.dll",)))
            else:
                source_root = self.root / "no-reviewed-source"
                source_root.mkdir(exist_ok=True)
            self.output.write_bytes(b"previous approved output")
            with self.subTest(blocker=blocker), self.assertRaisesRegex(ValueError, "jvm.dll"):
                package_release(self.bundle, self.output, build_number=2, architecture="x64", source_root=source_root)
            self.assertEqual(b"previous approved output", self.output.read_bytes())

    def test_jni_proof_cannot_outlive_the_aot_or_native_asset_snapshot(self):
        real_proof = package_module._unused_jni_proof
        for changed in ("data/app.so", "data/flutter_assets/NativeAssetsManifest.json"):
            self._unused_jni_fixture()
            (self.bundle / "data/app.so").write_bytes(b"approved application snapshot")

            def mutate_after_proof(*arguments, **options):
                result = real_proof(*arguments, **options)
                (self.bundle / changed).write_bytes(b"newer JNI build output")
                return result

            self.output.write_bytes(b"previous approved package")
            with self.subTest(changed=changed), mock.patch.object(package_module, "_unused_jni_proof", side_effect=mutate_after_proof):
                with self.assertRaisesRegex(ValueError, "JNI omission proof invalidated"):
                    package_release(self.bundle, self.output, build_number=2, architecture="x64")
            self.assertEqual(b"previous approved package", self.output.read_bytes())

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
        self.assertEqual(9, len(manifest["files"]))
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
