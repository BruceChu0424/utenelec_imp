from __future__ import annotations

import hashlib
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SOURCE = Path(__file__).with_name("existing-test-host-internal-db-commissioner.py")
SPEC = importlib.util.spec_from_file_location(
    "db_commissioner_stable_module_load_under_test", SOURCE
)
assert SPEC is not None and SPEC.loader is not None
commissioner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = commissioner
SPEC.loader.exec_module(commissioner)


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class CommissionerStableModuleSourceContractTest(unittest.TestCase):
    def test_path_loader_execution_was_removed(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        self.assertNotIn(".loader.exec_module(", source)
        self.assertNotIn("module_from_spec(", source)
        self.assertIn("os.O_NOFOLLOW", source)
        self.assertIn("compile(payload", source)
        self.assertIn("exec(code, module.__dict__, module.__dict__)", source)


@unittest.skipUnless(
    os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
    "real root-owned stable-fd module tests run on Linux as root",
)
class CommissionerStableModuleLoadTest(unittest.TestCase):
    def fixture(self, directory: str, payload: bytes = b"VALUE = 'trusted'\n"):
        root = Path(directory) / "modules"
        root.mkdir(mode=0o700)
        path = root / "module.py"
        path.write_bytes(payload)
        path.chmod(0o644)
        return path, payload

    def capture(self, path: Path, payload: bytes) -> bytes:
        return commissioner.stable_root_module_bytes(
            path,
            digest(payload),
            "test module",
        )

    def test_exact_single_link_module_is_captured_and_executed(self) -> None:
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, payload = self.fixture(directory)
            captured = self.capture(path, payload)
            module = commissioner._execute_verified_module(
                captured, path, "captured_test_module"
            )
        self.assertEqual("trusted", module.VALUE)

    def test_symlink_and_hardlink_modules_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            root = Path(directory) / "modules"
            root.mkdir(mode=0o700)
            original = root / "original.py"
            payload = b"VALUE = 'trusted'\n"
            original.write_bytes(payload)
            original.chmod(0o644)
            symlink = root / "symlink.py"
            symlink.symlink_to(original.name)
            hardlink = root / "hardlink.py"
            os.link(original, hardlink)
            for path in (symlink, hardlink):
                with self.subTest(path=path), self.assertRaises(
                    commissioner.CommissioningError
                ):
                    self.capture(path, payload)

    def test_digest_mismatch_is_rejected_before_compile(self) -> None:
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory)
            with mock.patch("builtins.compile") as compile_mock, self.assertRaisesRegex(
                commissioner.CommissioningError, "SHA-256"
            ):
                commissioner.stable_root_module_bytes(
                    path,
                    "f" * 64,
                    "test module",
                )
            compile_mock.assert_not_called()

    def test_group_writable_or_nonroot_module_is_rejected(self) -> None:
        payload = b"VALUE = 'trusted'\n"
        for case in ("group-writable", "nonroot-owner"):
            with self.subTest(case=case), tempfile.TemporaryDirectory(
                dir="/root"
            ) as directory:
                path, _payload = self.fixture(directory, payload)
                if case == "group-writable":
                    path.chmod(0o664)
                else:
                    os.chown(path, 1, 0)
                with self.assertRaises(commissioner.CommissioningError):
                    self.capture(path, payload)

    def test_inode_replacement_during_read_is_rejected(self) -> None:
        payload = b"VALUE = 'trusted'\n#" + b"x" * (128 * 1024)
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory, payload)
            replacement = path.with_name("replacement.py")
            replacement.write_bytes(payload)
            replacement.chmod(0o644)
            real_read = os.read
            swapped = False

            def read_then_replace(descriptor: int, size: int) -> bytes:
                nonlocal swapped
                block = real_read(descriptor, size)
                if block and not swapped:
                    swapped = True
                    os.replace(replacement, path)
                return block

            with mock.patch.object(
                commissioner.os, "read", side_effect=read_then_replace
            ), self.assertRaisesRegex(commissioner.CommissioningError, "changed"):
                self.capture(path, payload)
            self.assertTrue(swapped)

    def test_same_inode_byte_mutation_during_read_is_rejected(self) -> None:
        payload = b"VALUE = 'trusted'\n#" + b"x" * (128 * 1024)
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory, payload)
            real_read = os.read
            mutated = False

            def read_then_mutate(descriptor: int, size: int) -> bytes:
                nonlocal mutated
                block = real_read(descriptor, size)
                if block and not mutated:
                    mutated = True
                    with path.open("r+b", buffering=0) as handle:
                        handle.seek(70 * 1024)
                        handle.write(b"tampered")
                return block

            with mock.patch.object(
                commissioner.os, "read", side_effect=read_then_mutate
            ), self.assertRaises(commissioner.CommissioningError):
                self.capture(path, payload)
            self.assertTrue(mutated)

    def test_execution_never_reopens_path_after_capture(self) -> None:
        trusted = b"VALUE = 'trusted'\n"
        replacement = b"VALUE = 'replacement'\n"
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory, trusted)
            captured = self.capture(path, trusted)
            path.write_bytes(replacement)
            path.chmod(0o644)
            module = commissioner._execute_verified_module(
                captured, path, "captured_after_replacement"
            )
        self.assertEqual("trusted", module.VALUE)

    def test_load_modules_binds_updater_nested_import_to_preverified_guard(self) -> None:
        guard_payload = b"VALUE = 'verified guard'\n"
        updater_payload = (
            "release_guard = _UTEN_PREVERIFIED_RELEASE_GUARD\n"
            "SEEN = release_guard.VALUE\n"
        ).encode("utf-8")
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            root = Path(directory) / "modules"
            root.mkdir(mode=0o700)
            guard_path = root / "release_guard.py"
            updater_path = root / "release_updater.py"
            guard_path.write_bytes(guard_payload)
            updater_path.write_bytes(updater_payload)
            guard_path.chmod(0o644)
            updater_path.chmod(0o644)
            contract = {
                "releaseUpdaterSha256": digest(updater_payload),
                "updaterReleaseGuardSha256": digest(guard_payload),
            }
            with mock.patch.object(
                commissioner, "UPDATER_MODULE", updater_path
            ), mock.patch.object(commissioner, "RELEASE_GUARD", guard_path):
                updater, guard = commissioner.load_modules(contract)
        self.assertEqual("verified guard", guard.VALUE)
        self.assertEqual("verified guard", updater.SEEN)
        self.assertIs(guard, updater.release_guard)

    def test_real_updater_source_reuses_the_captured_real_guard(self) -> None:
        updater_payload = (
            SOURCE.parents[1] / "updater" / "release_updater.py"
        ).read_bytes()
        guard_payload = (
            SOURCE.parents[1] / "updater" / "release_guard.py"
        ).read_bytes()
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            root = Path(directory) / "modules"
            root.mkdir(mode=0o700)
            updater_path = root / "release_updater.py"
            guard_path = root / "release_guard.py"
            updater_path.write_bytes(updater_payload)
            guard_path.write_bytes(guard_payload)
            updater_path.chmod(0o644)
            guard_path.chmod(0o644)
            contract = {
                "releaseUpdaterSha256": digest(updater_payload),
                "updaterReleaseGuardSha256": digest(guard_payload),
            }
            with mock.patch.object(
                commissioner, "UPDATER_MODULE", updater_path
            ), mock.patch.object(commissioner, "RELEASE_GUARD", guard_path):
                updater, guard = commissioner.load_modules(contract)
        self.assertIs(guard, updater.release_guard)
        self.assertTrue(callable(updater.snapshot_candidate))
        self.assertTrue(callable(guard.validate_manifest))

    def test_assess_uses_snapshot_candidate_verified_info_without_guard_reverify(self) -> None:
        class StateLock:
            def __init__(self, _path):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_arguments):
                return False

        version = "v2026.08.12-1"
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "snapshot"
            snapshot.mkdir()
            manifest = snapshot / "manifest.json"
            manifest.write_bytes(b"{}\n")
            info = {"version": version}
            updater = SimpleNamespace(
                DEFAULT_LOCK_FILE=Path("/fixed/operation.lock"),
                StateLock=StateLock,
                snapshot_candidate=mock.Mock(return_value=(snapshot, info)),
            )
            guard = SimpleNamespace(
                verify_candidate=mock.Mock(
                    side_effect=AssertionError("redundant guard verification ran")
                )
            )
            with mock.patch.object(
                commissioner.os, "geteuid", return_value=0
            ), mock.patch.object(
                commissioner,
                "bootstrap_runtime_contract",
                return_value=({}, "a" * 64),
            ), mock.patch.object(
                commissioner, "load_modules", return_value=(updater, guard)
            ), mock.patch.object(
                commissioner, "require_root_directory"
            ), mock.patch.object(
                commissioner, "require_entry_closed"
            ), mock.patch.object(
                commissioner,
                "runtime_contract",
                return_value=(
                    {"deploymentProfile": "internal-test-local-v1"},
                    "b" * 64,
                ),
            ), mock.patch.object(
                commissioner,
                "storage_receipt",
                return_value=(Path("/fixed/storage.json"), {}, "c" * 64),
            ), mock.patch.object(
                commissioner, "verify_live_storage", return_value={"mounted": True}
            ), mock.patch.object(
                commissioner, "verify_runtime_secret_binding"
            ), mock.patch.object(
                commissioner.os.path, "lexists", return_value=False
            ), mock.patch.object(
                commissioner, "pgdata_empty", return_value=True
            ), mock.patch.object(
                commissioner, "systemd_state", return_value="inactive"
            ), mock.patch.object(
                commissioner,
                "manifest_binding",
                return_value={"version": version},
            ):
                result = commissioner.assess(version)
        self.assertEqual("READY_FOR_EXPLICIT_APPLY", result["status"])
        self.assertEqual({"version": version}, result["candidate"])
        updater.snapshot_candidate.assert_called_once()
        guard.verify_candidate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
