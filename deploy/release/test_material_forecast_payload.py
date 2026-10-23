"""Offline component fixtures and fail-closed release-boundary regressions.

Fixture wheels are explicitly synthetic, generated in temporary directories and
never used as evidence that real StatsForecast inference works.
"""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[1]
spec = importlib.util.spec_from_file_location("material_forecast_payload", HERE / "material_forecast_payload.py")
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)
VERSION = "v2.5.3"
COMMIT = "a" * 40


def fixture_wheel(name, version="0.0.0", python="py3", abi="none", system="any"):
    """An inert protocol fixture, not a substitute for any PyPI distribution."""
    distribution = name.replace("-", "_")
    filename = f"{distribution}-{version}-{python}-{abi}-{system}.whl"
    info = f"{distribution}-{version}.dist-info/"
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(distribution + "/__init__.py", "# SYNTHETIC RELEASE FIXTURE; NO INFERENCE CODE\n")
        archive.writestr(info + "METADATA", f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n\nSynthetic test fixture.\n")
        archive.writestr(info + "WHEEL", "Wheel-Version: 1.0\nGenerator: synthetic-release-fixture\n"
                         f"Root-Is-Purelib: {'true' if system == 'any' else 'false'}\nTag: {python}-{abi}-{system}\n")
        archive.writestr(info + "RECORD", "")
    return filename, output.getvalue()


def build_fixture_payload(root, version=VERSION, commit=COMMIT, target="linux-x86_64"):
    """Make a small offline payload accepted by the actual production verifier.

    root is the destination component directory, e.g. build/material-forecast.
    There is no bypass flag: fixture source pins and each wheel SHA agree, just
    as for a real signed component. Version 0.0.0 identifies inert test wheels.
    """
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    if any(root.iterdir()):
        raise ValueError("fixture destination must be empty")
    for path in payload.SOURCE_FILES:
        destination = root / payload.payload_path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((REPOSITORY / path).read_bytes() if path in {
            payload.CATALOG_PATH, "services/material_forecast/prepare_runtime.py", "services/material_forecast/prepare_runtime.ps1"}
                                else b"# SYNTHETIC RELEASE FIXTURE; NOT A PRODUCTION WORKER\n")
    (root / "forecast_worker/__init__.py").write_text('__version__ = "2.0.0"\n', encoding="ascii")
    (root / "verify_payload.py").write_bytes((HERE / "material_forecast_payload.py").read_bytes())
    (root / "wheelhouse").mkdir()
    lock_lines = []
    for name in sorted(payload.LOCK_PACKAGES):
        filename, content = fixture_wheel(name)
        digest = hashlib.sha256(content).hexdigest()
        marker = " ; sys_platform == 'win32'" if name == "colorama" else ""
        lock_lines.append(f"{name}==0.0.0{marker} --hash=sha256:{digest}\n")
        if name != "colorama" or target == "windows-x86_64":
            (root / "wheelhouse" / filename).write_bytes(content)
    lock = root / "requirements.txt"
    lock.write_text("".join(lock_lines), encoding="utf-8", newline="\n")
    (root / "requirements.in").write_text(
        "statsforecast==0.0.0\nnumpy==0.0.0\npandas==0.0.0\n", encoding="ascii", newline="\n")
    _, selected = payload.parse_lock(lock, target)
    wheels = [payload.inspect_wheel(path, selected, target) for path in (root / "wheelhouse").iterdir()]
    (root / "runtime-requirements.txt").write_bytes(payload.runtime_requirements(wheels))
    payload.write_manifest(root, version, commit, version[1:] + "+1", wheels, target)
    payload.verify(root, version, commit, target)
    return root


class MaterialForecastPayloadTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = build_fixture_payload(Path(self.temporary.name) / "component")

    def manifest(self):
        return json.loads((self.root / "release.json").read_text(encoding="ascii"))

    def write_manifest(self, value):
        (self.root / "release.json").write_text(json.dumps(value), encoding="ascii")

    def rehash_record(self, relative):
        manifest = self.manifest()
        path = self.root / relative
        for record in manifest["files"]:
            if record["path"] == relative:
                record.update(size=path.stat().st_size, sha256=payload.sha256(path))
        self.write_manifest(manifest)

    def reject(self):
        with self.assertRaises(payload.PayloadError):
            payload.verify(self.root, VERSION, COMMIT)

    def test_complete_offline_fixture_passes_the_standalone_production_cli_twice(self):
        for _ in range(2):
            result = subprocess.run([sys.executable, str(self.root / "verify_payload.py"), "--payload", str(self.root),
                                     "--version", VERSION, "--commit", COMMIT], capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(26, json.loads(result.stdout)["wheels"])

    def test_wrong_commit_or_version_is_rejected(self):
        for version, commit in [("v2.5.4", COMMIT), (VERSION, "b" * 40), ("2.5.3", COMMIT), (VERSION, "main")]:
            with self.subTest(version=version, commit=commit), self.assertRaises(payload.PayloadError):
                payload.verify(self.root, version, commit)

    def test_flat_native_windows_and_linux_have_one_authority_and_distinct_closures(self):
        windows = build_fixture_payload(Path(self.temporary.name) / "windows", target="windows-x86_64")
        self.assertEqual(27, payload.verify(windows, VERSION, COMMIT, "windows-x86_64")["wheels"])
        self.assertTrue((windows / "worker.py").is_file())
        self.assertTrue((windows / "prepare_runtime.py").is_file())
        self.assertTrue((windows / "forecast_worker/locking.py").is_file())
        self.assertFalse((windows / "source").exists())
        self.assertFalse((windows / "runtime-manifest.json").exists())
        with self.assertRaisesRegex(payload.PayloadError, "target identity"):
            payload.verify(windows, VERSION, COMMIT)
        _, selected = payload.parse_lock(windows / "requirements.txt", "windows-x86_64")
        filename, content = fixture_wheel("numpy", python="cp312", abi="cp312", system="win_amd64")
        wheel = Path(self.temporary.name) / filename
        wheel.write_bytes(content)
        selected["numpy"]["hashes"].add(payload.sha256(wheel))
        self.assertEqual("numpy", payload.inspect_wheel(wheel, selected, "windows-x86_64")["package"])
        with self.assertRaisesRegex(payload.PayloadError, "target x86_64"):
            payload.inspect_wheel(wheel, selected)

    def test_marker_cannot_hide_any_package_other_than_colorama(self):
        lock = self.root / "requirements.txt"
        original = lock.read_text()
        for value in [original.replace("numpy==0.0.0", "numpy==0.0.0 ; sys_platform == 'win32'"),
                      original.replace(" ; sys_platform == 'win32'", "")]:
            lock.write_text(value)
            with self.assertRaisesRegex(payload.PayloadError, "platform dependency marker"):
                payload.parse_lock(lock)

    def test_duplicate_manifest_fields_and_records_are_rejected(self):
        original = (self.root / "release.json").read_text(encoding="ascii")
        (self.root / "release.json").write_text(original.replace('"schemaVersion": 1', '"schemaVersion":1,"schemaVersion":1'), encoding="ascii")
        self.reject()
        (self.root / "release.json").write_text(original, encoding="ascii")
        manifest = self.manifest()
        manifest["files"].append(manifest["files"][0])
        self.write_manifest(manifest)
        self.reject()

    def test_wrong_target_or_application_identity_is_rejected(self):
        original = self.manifest()
        for field, value in [("target", {**payload.TARGET, "architecture": "aarch64"}),
                             ("applicationVersion", "2.5.4+1"), ("schemaVersion", True), ("schemaVersion", 2)]:
            with self.subTest(field=field):
                self.write_manifest({**original, field: value})
                self.reject()

    def test_missing_extra_changed_and_unlisted_empty_directory_fail_closed(self):
        source = self.root / "worker.py"
        original = source.read_bytes()
        source.write_bytes(original + b"changed")
        self.reject()
        source.write_bytes(original)
        extra = self.root / ".env"
        extra.write_text("synthetic fixture", encoding="ascii")
        self.reject()
        extra.unlink()
        empty = self.root / "cache"
        empty.mkdir()
        self.reject()
        empty.rmdir()
        source.unlink()
        self.reject()

    def test_manifest_cannot_authorize_a_new_source_path_or_catalog(self):
        extra = "tests/test_worker.py"
        path = self.root / extra
        path.parent.mkdir()
        path.write_text("# synthetic test\n", encoding="ascii")
        manifest = self.manifest()
        manifest["files"].append({"path": extra, "size": path.stat().st_size, "sha256": payload.sha256(path)})
        self.write_manifest(manifest)
        self.reject()
        path.unlink()
        path.parent.rmdir()
        manifest["files"].pop()
        self.write_manifest(manifest)
        catalog = self.root / payload.payload_path(payload.CATALOG_PATH)
        catalog.write_text("[]", encoding="ascii")
        self.rehash_record(payload.payload_path(payload.CATALOG_PATH))
        self.reject()

    def test_changed_or_missing_wheel_and_runtime_lock_are_rejected(self):
        wheel = next((self.root / "wheelhouse").iterdir())
        content = wheel.read_bytes()
        wheel.write_bytes(content + b"changed")
        self.reject()
        wheel.write_bytes(content)
        lock = self.root / "runtime-requirements.txt"
        lock.write_bytes(lock.read_bytes().replace(b"--hash=sha256:", b"--hash=sha512:", 1))
        self.rehash_record("runtime-requirements.txt")
        self.reject()

    def test_unreviewed_platform_and_renamed_wheel_metadata_are_rejected(self):
        lock = self.root / "requirements.txt"
        _, selected = payload.parse_lock(lock)
        for python, abi, system in [("cp313", "cp313", "manylinux_2_28_x86_64"),
                                    ("cp312", "cp312", "win_amd64"),
                                    ("cp312", "cp312", "manylinux_2_40_x86_64")]:
            filename, data = fixture_wheel("numpy", python=python, abi=abi, system=system)
            path = Path(self.temporary.name) / filename
            path.write_bytes(data)
            selected["numpy"]["hashes"].add(hashlib.sha256(data).hexdigest())
            with self.subTest(system=system), self.assertRaises(payload.PayloadError):
                payload.inspect_wheel(path, selected)
        filename, data = fixture_wheel("numpy", python="cp312", abi="cp312", system="win_amd64")
        path = Path(self.temporary.name) / filename.replace("win_amd64", "manylinux_2_28_x86_64")
        path.write_bytes(data)
        selected["numpy"]["hashes"].add(hashlib.sha256(data).hexdigest())
        with self.assertRaisesRegex(payload.PayloadError, "ABI metadata"):
            payload.inspect_wheel(path, selected)

    def test_symlink_file_or_directory_is_rejected(self):
        outside = Path(self.temporary.name) / "outside"
        outside.write_text("synthetic fixture", encoding="ascii")
        link = self.root / "linked"
        try:
            link.symlink_to(outside)
        except OSError:
            self.skipTest("host does not permit symlink creation; Linux CI exercises it")
        self.reject()
        link.unlink()
        link.symlink_to(outside.parent, target_is_directory=True)
        self.reject()

    def test_hardlink_is_rejected(self):
        path = self.root / "linked"
        os.link(self.root / "verify_payload.py", path)
        self.reject()

    @unittest.skipUnless(os.name == "nt", "Windows junction boundary")
    def test_windows_junction_is_rejected_without_following_its_target(self):
        outside = Path(self.temporary.name) / "outside-directory"
        outside.mkdir()
        sentinel = outside / "preserve.txt"
        sentinel.write_text("outside content")
        link = self.root / "junction"
        result = subprocess.run([os.environ["COMSPEC"], "/d", "/c", "mklink", "/J", str(link), str(outside)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        try:
            self.assertTrue(link.is_junction())
            self.reject()
            self.assertEqual(sentinel.read_text(), "outside content")
        finally:
            # Remove the owned junction itself; never recursively visit its target.
            os.rmdir(link)

    def test_direct_dependency_pin_or_extra_marker_cannot_escape_the_lock(self):
        lock = self.root / "requirements.txt"
        original = lock.read_text(encoding="ascii")
        for value in [original.replace("numpy==0.0.0", "numpy>=0.0.0"),
                      original.replace("sys_platform == 'win32'", "sys_platform != 'win32'"),
                      original + "unreviewed==1.0 --hash=sha256:" + "a" * 64 + "\n"]:
            lock.write_text(value, encoding="ascii")
            with self.assertRaises(payload.PayloadError):
                payload.parse_lock(lock)

    def test_direct_pin_change_is_rejected_even_with_a_rehashed_manifest(self):
        path = self.root / "requirements.in"
        path.write_text("statsforecast==0.0.1\nnumpy==0.0.0\npandas==0.0.0\n", encoding="ascii")
        self.rehash_record("requirements.in")
        self.reject()

    def test_manifest_path_escape_and_malformed_json_are_rejected(self):
        manifest = self.manifest()
        manifest["files"][0]["path"] = "../outside"
        self.write_manifest(manifest)
        self.reject()
        (self.root / "release.json").write_bytes(b'{"schemaVersion":')
        self.reject()

    def test_updater_forbids_double_dot_substrings_even_inside_one_filename(self):
        for value in ["x..y", "source/x..y.py", "../outside", "source//worker.py"]:
            with self.subTest(path=value), self.assertRaises(payload.PayloadError):
                payload.safe_relative(value)

    def test_wheel_source_hash_cannot_be_replaced_by_only_rehashing_the_component(self):
        wheel = next((self.root / "wheelhouse").iterdir())
        wheel.write_bytes(wheel.read_bytes() + b"synthetic tamper")
        self.rehash_record(wheel.relative_to(self.root).as_posix())
        with self.assertRaisesRegex(payload.PayloadError, "complete source lock"):
            payload.verify(self.root, VERSION, COMMIT)

    def test_wheel_archive_traversal_and_duplicate_members_are_rejected(self):
        _, selected = payload.parse_lock(self.root / "requirements.txt")
        for member in ["../../escape", "C:/outside", "numpy/./hidden"]:
            filename, raw = fixture_wheel("numpy")
            path = Path(self.temporary.name) / filename
            path.write_bytes(raw)
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr(member, "synthetic fixture")
            selected["numpy"]["hashes"].add(payload.sha256(path))
            with self.subTest(member=member), self.assertRaisesRegex(payload.PayloadError, "unsafe wheel"):
                payload.inspect_wheel(path, selected)
        filename, raw = fixture_wheel("numpy")
        path = Path(self.temporary.name) / filename
        path.write_bytes(raw)
        with zipfile.ZipFile(path, "a") as archive, self.assertWarns(UserWarning):
            archive.writestr("numpy-0.0.0.dist-info/WHEEL", "synthetic duplicate")
        selected["numpy"]["hashes"].add(payload.sha256(path))
        with self.assertRaisesRegex(payload.PayloadError, "duplicate"):
            payload.inspect_wheel(path, selected)


class CheckoutIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "--quiet")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Synthetic release fixture")
        self.git("config", "core.autocrlf", "false")
        (self.root / "pubspec.yaml").write_text("version: 2.5.3+1\n", encoding="ascii")
        (self.root / "tracked.txt").write_text("original\n", encoding="ascii", newline="\n")
        (self.root / ".gitignore").write_text("build/\n", encoding="ascii")
        self.git("add", "pubspec.yaml", "tracked.txt", ".gitignore")
        self.git("commit", "--quiet", "-m", "Synthetic test fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], stderr=subprocess.PIPE).decode()

    def test_only_exact_clean_checkout_identity_is_accepted(self):
        self.assertEqual("2.5.3+1", payload.require_checkout(self.root, VERSION, self.commit))
        for version, commit in [("v2.5.4", self.commit), (VERSION, "b" * 40)]:
            with self.subTest(version=version, commit=commit), self.assertRaises(payload.PayloadError):
                payload.require_checkout(self.root, version, commit)
        (self.root / "tracked.txt").write_text("modified\n", encoding="ascii")
        with self.assertRaisesRegex(payload.PayloadError, "dirty"):
            payload.require_checkout(self.root, VERSION, self.commit)

    def test_untracked_source_cannot_enter_a_release_build(self):
        (self.root / "untracked.txt").write_text("synthetic\n", encoding="ascii")
        with self.assertRaisesRegex(payload.PayloadError, "dirty"):
            payload.require_checkout(self.root, VERSION, self.commit)

    def test_source_is_read_from_the_commit_blob_not_a_modified_working_file(self):
        (self.root / "tracked.txt").write_text("modified\n", encoding="ascii")
        self.assertEqual(b"original\n", payload.git_source(self.root, self.commit, "tracked.txt"))
        with self.assertRaises(payload.PayloadError):
            payload.git_source(self.root, self.commit, "missing.txt")

    def prepare_build_fixture(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.component = build_fixture_payload(Path(directory.name) / "component")
        for path in payload.SOURCE_FILES:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.component / payload.payload_path(path), target)
        target = self.root / payload.SCRIPT_PATH
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / "material_forecast_payload.py", target)
        target = self.root / payload.FACADE_PATH
        shutil.copyfile(REPOSITORY / payload.FACADE_PATH, target)
        service = self.root / "services/material_forecast"
        all_pins, _ = payload.parse_lock(service / "requirements.txt")
        (service / "requirements.runtime.txt").write_text("".join(f"{name}=={item['version']}\n" for name, item in sorted(all_pins.items())), encoding="ascii")
        (service / "runtime-locks").mkdir()
        for selected_target in payload.TARGETS:
            _, selected = payload.parse_lock(service / "requirements.txt", selected_target)
            (service / "runtime-locks" / (selected_target + ".lock")).write_text("".join(
                f"{name}=={item['version']} --hash=sha256:{sorted(item['hashes'])[0]}\n" for name, item in sorted(selected.items())), encoding="ascii")
        self.git("add", "--", *payload.SOURCE_FILES, *payload.DERIVED_FILES, payload.SCRIPT_PATH, payload.FACADE_PATH)
        self.git("commit", "--quiet", "-m", "Synthetic runtime build fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()

    def test_builder_uses_exact_git_blobs_and_complete_hashed_binary_download(self):
        self.prepare_build_fixture()
        original_run = subprocess.run
        pip_calls = []

        def run(command, **kwargs):
            if "pip" not in command:
                return original_run(command, **kwargs)
            pip_calls.append(command)
            destination = Path(command[command.index("--dest") + 1])
            for wheel in (self.component / "wheelhouse").iterdir():
                shutil.copyfile(wheel, destination / wheel.name)
            return subprocess.CompletedProcess(command, 0)

        output = self.root / "build/material-forecast"
        with patch.object(payload, "require_build_host"), patch.object(payload.subprocess, "run", side_effect=run):
            result = payload.build(self.root, output, VERSION, self.commit)
        self.assertTrue(result["verified"])
        self.assertEqual(1, len(pip_calls))
        for argument in ["--isolated", "--require-hashes", "--only-binary=:all:", "--index-url"]:
            self.assertIn(argument, pip_calls[0])
        # Release builds keep the full download log for the release audit trail.
        self.assertNotIn("-q", pip_calls[0])
        self.assertEqual(payload.git_source(self.root, self.commit, payload.CATALOG_PATH),
                         (output / payload.payload_path(payload.CATALOG_PATH)).read_bytes())

    def test_checkout_drift_during_download_prevents_publication(self):
        self.prepare_build_fixture()
        original_run = subprocess.run

        def run(command, **kwargs):
            if "pip" not in command:
                return original_run(command, **kwargs)
            destination = Path(command[command.index("--dest") + 1])
            for wheel in (self.component / "wheelhouse").iterdir():
                shutil.copyfile(wheel, destination / wheel.name)
            (self.root / "tracked.txt").write_text("concurrent source change\n", encoding="ascii")
            return subprocess.CompletedProcess(command, 0)

        output = self.root / "build/material-forecast"
        with patch.object(payload, "require_build_host"), patch.object(payload.subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(payload.PayloadError, "dirty"):
                payload.build(self.root, output, VERSION, self.commit)
        self.assertFalse(output.exists())

    def test_output_cannot_escape_the_build_directory_or_replace_an_existing_component(self):
        self.prepare_build_fixture()
        output = self.root / "build/material-forecast"
        output.mkdir(parents=True)
        for target in [output, self.root / "build/../escaped"]:
            with self.subTest(target=target), patch.object(payload, "require_build_host"):
                with self.assertRaisesRegex(payload.PayloadError, "output"):
                    payload.build(self.root, target, VERSION, self.commit)

    def test_new_runtime_module_requires_an_explicit_source_allowlist_review(self):
        self.prepare_build_fixture()
        relative = "services/material_forecast/forecast_worker/unreviewed.py"
        (self.root / relative).write_text("# synthetic new module\n", encoding="ascii")
        self.git("add", "--", relative)
        self.git("commit", "--quiet", "-m", "Synthetic new runtime source")
        self.commit = self.git("rev-parse", "HEAD").strip()
        with patch.object(payload, "require_build_host"), self.assertRaisesRegex(payload.PayloadError, "source allowlist"):
            payload.build(self.root, self.root / "build/material-forecast", VERSION, self.commit)

    def test_development_allows_unrelated_dirty_but_rejects_every_runtime_authority_change(self):
        self.prepare_build_fixture()
        before = payload.source_identity(self.root, VERSION, self.commit, "linux-x86_64", True)
        (self.root / "tracked.txt").write_text("unrelated developer change\n")
        (self.root / "unrelated-note.txt").write_text("developer draft\n")
        self.assertEqual(before, payload.source_identity(self.root, VERSION, self.commit, "linux-x86_64", True))
        for relative in (*payload.SOURCE_FILES, *payload.DERIVED_FILES, payload.SCRIPT_PATH,
                         payload.FACADE_PATH):
            path = self.root / relative
            original = path.read_bytes()
            path.write_bytes(original + b"\n# uncommitted runtime change\n")
            try:
                with self.subTest(path=relative), self.assertRaisesRegex(payload.PayloadError, "runtime source differs"):
                    payload.source_identity(self.root, VERSION, self.commit, "linux-x86_64", True)
            finally:
                path.write_bytes(original)
        extra = self.root / "services/material_forecast/forecast_worker/untracked.py"
        extra.write_text("# cannot enter a development runtime\n")
        with self.assertRaisesRegex(payload.PayloadError, "source allowlist"):
            payload.source_identity(self.root, VERSION, self.commit, "linux-x86_64", True)

    def test_development_ignores_flutter_manifest_edits_but_keeps_committed_version(self):
        self.prepare_build_fixture()
        before = payload.source_identity(self.root, VERSION, self.commit, "linux-x86_64", True)
        committed_version = payload.require_checkout(self.root, VERSION, self.commit, True)
        manifest = self.root / "pubspec.yaml"
        original = manifest.read_bytes()
        for working in (original + b"\ndependency_overrides:\n  flutter_only: any\n",
                        b"version: 99.0.0+9900\n", b"incomplete Flutter edit\n"):
            manifest.write_bytes(working)
            with self.subTest(working=working):
                self.assertEqual(before, payload.source_identity(self.root, VERSION, self.commit, "linux-x86_64", True))
                self.assertEqual(committed_version, payload.require_checkout(self.root, VERSION, self.commit, True))
                with self.assertRaisesRegex(payload.PayloadError, "dirty"):
                    payload.require_checkout(self.root, VERSION, self.commit)
        with self.assertRaisesRegex(payload.PayloadError, "application version mismatch"):
            payload.require_checkout(self.root, "v99.0.0", self.commit, True)

    def test_compatibility_exports_cannot_create_a_second_dependency_authority(self):
        self.prepare_build_fixture()
        service = self.root / "services/material_forecast"
        payload.validate_derived(service)
        for path, replacement in [(service / "requirements.runtime.txt", "numpy==9.9.9"),
                                  (service / "runtime-locks/linux-x86_64.lock", "numpy==9.9.9")]:
            original = path.read_text()
            path.write_text(original.replace("numpy==0.0.0", replacement))
            with self.subTest(path=path), self.assertRaises(payload.PayloadError):
                payload.validate_derived(service)
            path.write_text(original)
        linux = service / "runtime-locks/linux-x86_64.lock"
        linux.write_text(linux.read_text() + "colorama==0.0.0 --hash=sha256:" + "a" * 64 + "\n")
        with self.assertRaisesRegex(payload.PayloadError, "differs from authority"):
            payload.validate_derived(service)

    def test_autocrlf_fresh_checkout_preserves_exact_runtime_bytes_and_rejects_dirty_lock(self):
        self.prepare_build_fixture()
        shutil.copyfile(REPOSITORY / ".gitattributes", self.root / ".gitattributes")
        self.git("add", "--", ".gitattributes")
        self.git("add", "--renormalize", "--", *payload.SOURCE_FILES, *payload.DERIVED_FILES,
                 payload.SCRIPT_PATH, payload.FACADE_PATH, "pubspec.yaml")
        self.git("commit", "--quiet", "-m", "Explicit LF runtime checkout contract")
        commit = self.git("rev-parse", "HEAD").strip()
        with tempfile.TemporaryDirectory() as temporary:
            clone = Path(temporary) / "checkout"
            subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", "--config", "core.autocrlf=true",
                            str(self.root), str(clone)], check=True, capture_output=True)
            self.assertFalse(subprocess.check_output(["git", "-C", str(clone), "status", "--porcelain"]))
            payload.source_identity(clone, VERSION, commit, "windows-x86_64", True)
            for relative in (*payload.SOURCE_FILES, *payload.DERIVED_FILES, payload.SCRIPT_PATH,
                             payload.FACADE_PATH, "pubspec.yaml"):
                self.assertEqual((clone / relative).read_bytes(), payload.git_source(clone, commit, relative))
            lock = clone / "services/material_forecast/requirements.txt"
            original = lock.read_bytes()
            lock.write_bytes(original.replace(b"numpy==0.0.0", b"numpy==9.9.9"))
            with self.assertRaisesRegex(payload.PayloadError, "runtime source differs"):
                payload.source_identity(clone, VERSION, commit, "windows-x86_64", True)
            lock.write_bytes(original.replace(b"\n", b"\r\n"))
            with self.assertRaisesRegex(payload.PayloadError, "runtime source differs"):
                payload.source_identity(clone, VERSION, commit, "windows-x86_64", True)

    def test_development_cache_revalidates_every_hit_and_keys_all_source_identity(self):
        self.prepare_build_fixture()
        facade_spec = importlib.util.spec_from_file_location("fixture_builder", REPOSITORY / payload.FACADE_PATH)
        facade = importlib.util.module_from_spec(facade_spec)
        facade_spec.loader.exec_module(facade)
        facade.strict = payload
        original_run = subprocess.run
        pip_calls = []

        def run(command, **kwargs):
            if "pip" not in command:
                return original_run(command, **kwargs)
            pip_calls.append(command)
            (self.root / "pubspec.yaml").write_text("version: 97.0.0+9700\n")
            destination = Path(command[command.index("--dest") + 1])
            for wheel in (self.component / "wheelhouse").iterdir():
                shutil.copyfile(wheel, destination / wheel.name)
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as cache_dir, patch.object(payload, "require_build_host"), \
                patch.object(payload.subprocess, "run", side_effect=run):
            cache = Path(cache_dir)
            (self.root / "tracked.txt").write_text("unrelated dirty draft\n")
            (self.root / "pubspec.yaml").write_text("version: 98.0.0+9800\n")
            first = facade.development_payload(cache, "linux-x86_64", repo=self.root)
            self.assertEqual(1, len(pip_calls))
            # Development downloads stream into the backend console and stay quiet.
            self.assertIn("-q", pip_calls[0])
            second = facade.development_payload(cache, "linux-x86_64", repo=self.root)
            self.assertEqual(first, second)
            self.assertEqual(1, len(pip_calls))
            old_directory = Path(first["payload"])
            # Flutter WIP cannot invalidate a verified Python payload or change
            # its committed release/application version, even during a build.
            (self.root / "pubspec.yaml").write_text("version: 99.0.0+9900\n")
            self.assertEqual(first, facade.development_payload(cache, "linux-x86_64", repo=self.root))
            self.assertEqual(VERSION, json.loads((old_directory / "release.json").read_text())["version"])
            self.assertEqual(1, len(pip_calls))
            worker = old_directory / "worker.py"
            original = worker.read_bytes()
            worker.write_bytes(original + b"tamper")
            with self.assertRaisesRegex(payload.PayloadError, "have changed"):
                facade.development_payload(cache, "linux-x86_64", repo=self.root)
            manifest_path = old_directory / "release.json"
            manifest_original = manifest_path.read_bytes()
            manifest = json.loads(manifest_original)
            for item in manifest["files"]:
                if item["path"] == "worker.py":
                    item.update(size=worker.stat().st_size, sha256=payload.sha256(worker))
            manifest_path.write_text(json.dumps(manifest))
            # Developer caches lack the outer release signature: an attacker
            # rehashing its manifest must still never replace reviewed Git code.
            with self.assertRaisesRegex(payload.PayloadError, "payload source differs"):
                facade.development_payload(cache, "linux-x86_64", repo=self.root)
            self.assertEqual(1, len(pip_calls))
            worker.write_bytes(original)
            manifest_path.write_bytes(manifest_original)
            verifier = old_directory / "verify_payload.py"
            verifier_original = verifier.read_bytes()
            verifier.write_bytes(verifier_original + b"\n# rehashed verifier replacement\n")
            manifest = json.loads(manifest_original)
            for item in manifest["files"]:
                if item["path"] == "verify_payload.py":
                    item.update(size=verifier.stat().st_size, sha256=payload.sha256(verifier))
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(payload.PayloadError, "payload verifier differs"):
                facade.development_payload(cache, "linux-x86_64", repo=self.root)
            verifier.write_bytes(verifier_original)
            manifest_path.write_bytes(manifest_original)
            source = self.root / "services/material_forecast/worker.py"
            source.write_bytes(source.read_bytes() + b"\n# reviewed next worker\n")
            with self.assertRaisesRegex(payload.PayloadError, "runtime source differs"):
                facade.development_payload(cache, "linux-x86_64", repo=self.root)
            self.assertEqual(1, len(pip_calls))
            self.git("add", "--", "services/material_forecast/worker.py")
            self.git("commit", "--quiet", "-m", "Reviewed new synthetic worker")
            third = facade.development_payload(cache, "linux-x86_64", repo=self.root)
            self.assertNotEqual(first["sourceIdentity"], third["sourceIdentity"])
            self.assertNotEqual(first["payload"], third["payload"])
            self.assertEqual(2, len(pip_calls))
            self.assertEqual(original, worker.read_bytes())


if __name__ == "__main__":
    unittest.main()
