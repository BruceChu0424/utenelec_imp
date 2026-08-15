from __future__ import annotations

import hashlib
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SOURCE = Path(__file__).with_name("migration_authorization.py")
SPEC = importlib.util.spec_from_file_location(
    "migration_authorization_stable_module_load_under_test", SOURCE
)
assert SPEC is not None and SPEC.loader is not None
migration = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = migration
SPEC.loader.exec_module(migration)


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class MigrationStableModuleSourceContractTest(unittest.TestCase):
    def test_path_loader_execution_was_removed(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        self.assertNotIn("spec_from_file_location", source)
        self.assertNotIn(".loader.exec_module(", source)
        self.assertNotIn("module_from_spec(", source)
        self.assertIn("os.O_NOFOLLOW", source)
        self.assertIn("compile(\n            raw", source)
        self.assertIn("exec(code, module.__dict__, module.__dict__)", source)


@unittest.skipUnless(
    os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
    "real root-owned stable-fd module tests run on Linux as root",
)
class MigrationStableModuleLoadTest(unittest.TestCase):
    def fixture(self, directory: str, payload: bytes = b"VALUE = 'trusted'\n"):
        root = Path(directory) / "modules"
        root.mkdir(mode=0o700)
        path = root / "release_guard.py"
        path.write_bytes(payload)
        path.chmod(0o644)
        return path, payload

    def capture(self, path: Path, payload: bytes) -> bytes:
        with mock.patch.object(migration, "STABLE_RELEASE_GUARD", path), mock.patch.object(
            migration, "RELEASE_GUARD_SHA256", digest(payload)
        ):
            return migration._read_stable_bytes(
                path,
                mode=0o644,
                maximum_bytes=2 * 1024 * 1024,
            )

    def load(self, path: Path, payload: bytes):
        with mock.patch.object(migration, "STABLE_RELEASE_GUARD", path), mock.patch.object(
            migration, "RELEASE_GUARD_SHA256", digest(payload)
        ):
            return migration._load_release_guard()

    def test_exact_single_link_guard_is_captured_and_executed(self) -> None:
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, payload = self.fixture(directory)
            module = self.load(path, payload)
        self.assertEqual("trusted", module.VALUE)

    def test_current_real_guard_matches_pin_and_loads_from_captured_bytes(self) -> None:
        payload = SOURCE.with_name("release_guard.py").read_bytes()
        self.assertEqual(migration.RELEASE_GUARD_SHA256, digest(payload))
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory, payload)
            with mock.patch.object(migration, "STABLE_RELEASE_GUARD", path):
                module = migration._load_release_guard()
        self.assertTrue(callable(module.validate_manifest))

    def test_symlink_and_hardlink_guards_are_rejected(self) -> None:
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
                    migration.MigrationAuthorizationError
                ):
                    self.load(path, payload)

    def test_digest_mismatch_is_rejected_before_compile(self) -> None:
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory)
            with mock.patch.object(
                migration, "STABLE_RELEASE_GUARD", path
            ), mock.patch.object(
                migration, "RELEASE_GUARD_SHA256", "f" * 64
            ), mock.patch(
                "builtins.compile"
            ) as compile_mock, self.assertRaisesRegex(
                migration.MigrationAuthorizationError, "reviewed digest"
            ):
                migration._load_release_guard()
            compile_mock.assert_not_called()

    def test_group_writable_or_nonroot_guard_is_rejected(self) -> None:
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
                with self.assertRaises(migration.MigrationAuthorizationError):
                    self.load(path, payload)

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
                migration.os, "read", side_effect=read_then_replace
            ), self.assertRaisesRegex(
                migration.MigrationAuthorizationError, "changed during read"
            ):
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
                migration.os, "read", side_effect=read_then_mutate
            ), self.assertRaises(migration.MigrationAuthorizationError):
                self.capture(path, payload)
            self.assertTrue(mutated)

    def test_execution_uses_captured_bytes_after_path_replacement(self) -> None:
        trusted = b"VALUE = 'trusted'\n"
        replacement = b"VALUE = 'replacement'\n"
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            path, _payload = self.fixture(directory, trusted)
            real_compile = compile
            replaced = False

            def compile_after_replace(source, filename, mode, **kwargs):
                nonlocal replaced
                if not replaced:
                    replaced = True
                    incoming = path.with_name("incoming.py")
                    incoming.write_bytes(replacement)
                    incoming.chmod(0o644)
                    os.replace(incoming, path)
                return real_compile(source, filename, mode, **kwargs)

            with mock.patch.object(
                migration, "STABLE_RELEASE_GUARD", path
            ), mock.patch.object(
                migration, "RELEASE_GUARD_SHA256", digest(trusted)
            ), mock.patch(
                "builtins.compile", side_effect=compile_after_replace
            ):
                module = migration._load_release_guard()
            self.assertTrue(replaced)
        self.assertEqual("trusted", module.VALUE)


if __name__ == "__main__":
    unittest.main()
