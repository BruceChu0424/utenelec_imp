from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
LAUNCHER_PATH = HERE / "launch-existing-host-installer.py"
SPEC = importlib.util.spec_from_file_location("existing_host_installer_launcher", LAUNCHER_PATH)
assert SPEC is not None and SPEC.loader is not None
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)

INSTALLER_SPEC = importlib.util.spec_from_file_location(
    "existing_host_installer_for_launcher_contract",
    HERE / "existing_host_installer.py",
)
assert INSTALLER_SPEC is not None and INSTALLER_SPEC.loader is not None
installer = importlib.util.module_from_spec(INSTALLER_SPEC)
sys.modules[INSTALLER_SPEC.name] = installer
INSTALLER_SPEC.loader.exec_module(installer)


class NoopLock:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None


class ExistingHostInstallerLauncherTests(unittest.TestCase):
    def _read_temp(
        self,
        payload: bytes,
        *,
        expected_sha256: str | None = None,
        chain_side_effect: list[tuple[tuple[str, tuple[int, ...]], ...]] | None = None,
        extra_link: bool = False,
    ):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "existing_host_installer.py"
            path.write_bytes(payload)
            path.chmod(0o400)
            linked = Path(directory) / "second-link.py"
            if extra_link:
                os.link(path, linked)
            digest = expected_sha256 or hashlib.sha256(payload).hexdigest()
            chain = ((str(path.parent), (1, 2, stat.S_IFDIR | 0o755, 0, 0, 1, 0, 1, 1)),)
            chain_patch = (
                mock.patch.object(launcher, "_root_parent_chain", side_effect=chain_side_effect)
                if chain_side_effect is not None
                else mock.patch.object(launcher, "_root_parent_chain", return_value=chain)
            )
            metadata_patch = (
                contextlib.nullcontext()
                if extra_link
                else mock.patch.object(launcher, "_safe_regular_file", return_value=True)
            )
            with (
                mock.patch.object(launcher, "INSTALLED_INSTALLER", path),
                mock.patch.object(launcher, "REVIEWED_INSTALLER_SHA256", digest),
                chain_patch,
                metadata_patch,
            ):
                return launcher.read_verified_installer()

    def test_embeds_frozen_installer_digest_and_fixed_bundle_path(self) -> None:
        self.assertEqual(
            launcher.REVIEWED_INSTALLER_SHA256,
            "512b7c7132c2016d1557723b90bef520349b5cbd7875af296d6d0554b9ade727",
        )
        self.assertEqual(
            hashlib.sha256((HERE / "existing_host_installer.py").read_bytes()).hexdigest(),
            launcher.REVIEWED_INSTALLER_SHA256,
        )
        self.assertEqual(
            launcher.INSTALLED_INSTALLER,
            Path(
                "/usr/local/share/uten-imp-backup-installer-source/"
                "deploy/postgres/backup/existing_host_installer.py"
            ),
        )

    def test_source_bundle_allowlist_exactly_matches_installer_assets(self) -> None:
        repository_root = HERE.parents[2]
        expected_assets = {
            str(asset.source.relative_to(repository_root)).replace("\\", "/")
            for asset in installer.ASSETS
        }
        actual = set(launcher.SOURCE_BUNDLE_RELATIVE_FILES)
        self.assertEqual(18, len(actual))
        self.assertEqual(
            expected_assets,
            actual - {"deploy/postgres/backup/existing_host_installer.py"},
        )
        for relative in actual:
            self.assertTrue((repository_root / relative).is_file(), relative)

    def test_source_bundle_inventory_rejects_extra_and_missing_objects(self) -> None:
        relative_files = (
            "deploy/postgres/backup/existing_host_installer.py",
            "deploy/systemd/fixed.service.example",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            for relative in relative_files:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("reviewed\n", encoding="utf-8")
            installed = root / relative_files[0]
            patches = (
                mock.patch.object(launcher, "SOURCE_BUNDLE_ROOT", root),
                mock.patch.object(
                    launcher, "SOURCE_BUNDLE_RELATIVE_FILES", relative_files
                ),
                mock.patch.object(launcher, "INSTALLED_INSTALLER", installed),
                mock.patch.object(launcher, "_root_parent_chain", return_value=()),
                mock.patch.object(launcher, "_safe_bundle_directory", return_value=True),
                mock.patch.object(launcher, "_safe_regular_file", return_value=True),
            )
            for patcher in patches:
                patcher.start()
            try:
                self.assertTrue(launcher.validate_source_bundle_inventory())
                unexpected = root / "unexpected.txt"
                unexpected.write_text("not approved\n", encoding="utf-8")
                with self.assertRaisesRegex(
                    launcher.LauncherError, "missing or unexpected"
                ):
                    launcher.validate_source_bundle_inventory()
                unexpected.unlink()
                installed.unlink()
                with self.assertRaisesRegex(
                    launcher.LauncherError, "missing or unexpected"
                ):
                    launcher.validate_source_bundle_inventory()
            finally:
                for patcher in reversed(patches):
                    patcher.stop()

    def test_rejects_wrong_embedded_digest(self) -> None:
        with self.assertRaisesRegex(launcher.LauncherError, "embedded independently reviewed"):
            self._read_temp(b"print('reviewed')\n", expected_sha256="0" * 64)

    @unittest.skipUnless(hasattr(os, "O_NOFOLLOW"), "requires POSIX O_NOFOLLOW")
    def test_rejects_symlink_installer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.py"
            target.write_text("print('no')\n", encoding="utf-8")
            path = Path(directory) / "existing_host_installer.py"
            path.symlink_to(target)
            with (
                mock.patch.object(launcher, "INSTALLED_INSTALLER", path),
                mock.patch.object(
                    launcher,
                    "REVIEWED_INSTALLER_SHA256",
                    hashlib.sha256(target.read_bytes()).hexdigest(),
                ),
                mock.patch.object(launcher, "_root_parent_chain", return_value=()),
            ):
                with self.assertRaisesRegex(launcher.LauncherError, "cannot open"):
                    launcher.read_verified_installer()

    def test_rejects_hardlinked_installer(self) -> None:
        with self.assertRaisesRegex(launcher.LauncherError, "one immutable"):
            self._read_temp(b"print('no')\n", extra_link=True)

    def test_rejects_parent_chain_drift(self) -> None:
        before = (("/fixed", (1, 2, stat.S_IFDIR | 0o500, 0, 0, 1, 0, 1, 1)),)
        after = (("/fixed", (1, 3, stat.S_IFDIR | 0o500, 0, 0, 1, 0, 2, 2)),)
        with self.assertRaisesRegex(launcher.LauncherError, "changed while hashing"):
            self._read_temp(b"print('no')\n", chain_side_effect=[before, after])

    def test_rejects_descriptor_metadata_drift(self) -> None:
        payload = b"print('no')\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "existing_host_installer.py"
            path.write_bytes(payload)
            path.chmod(0o400)
            opened = path.stat()
            changed_values = list(opened)
            changed_values[stat.ST_MTIME] = opened.st_mtime + 1
            changed = os.stat_result(changed_values)
            with (
                mock.patch.object(launcher, "INSTALLED_INSTALLER", path),
                mock.patch.object(
                    launcher,
                    "REVIEWED_INSTALLER_SHA256",
                    hashlib.sha256(payload).hexdigest(),
                ),
                mock.patch.object(launcher, "_root_parent_chain", return_value=()),
                mock.patch.object(launcher, "_safe_regular_file", return_value=True),
                mock.patch.object(launcher.os, "fstat", side_effect=[opened, changed]),
            ):
                with self.assertRaisesRegex(launcher.LauncherError, "changed while hashing"):
                    launcher.read_verified_installer()

    def test_executes_captured_bytes_after_source_path_changes(self) -> None:
        original = b"print('CAPTURED_BYTES_ONLY')\n"
        verified = launcher.VerifiedInstaller(
            payload=original,
            sha256=hashlib.sha256(original).hexdigest(),
            device=1,
            inode=2,
            size=len(original),
        )
        with tempfile.TemporaryDirectory() as directory:
            replacement = Path(directory) / "replacement.py"
            replacement.write_text("raise RuntimeError('PATH_EXECUTED')\n", encoding="utf-8")
            output = io.StringIO()
            with (
                mock.patch.object(launcher, "INSTALLED_INSTALLER", replacement),
                contextlib.redirect_stdout(output),
            ):
                launcher.execute_verified_installer(verified, ["assess"])
        self.assertEqual(output.getvalue(), "CAPTURED_BYTES_ONLY\n")

    def test_sanitizes_argv_environment_cwd_and_restores_process_state(self) -> None:
        payload = (
            b"import json, os, sys\n"
            b"print(json.dumps({'argv': sys.argv, 'env': dict(os.environ), "
            b"'cwd': os.getcwd()}, sort_keys=True))\n"
        )
        verified = launcher.VerifiedInstaller(
            payload=payload,
            sha256=hashlib.sha256(payload).hexdigest(),
            device=1,
            inode=2,
            size=len(payload),
        )
        previous_argv = list(sys.argv)
        previous_environment = dict(os.environ)
        previous_directory = os.getcwd()
        output = io.StringIO()
        with mock.patch.dict(os.environ, {"PYTHONPATH": "/untrusted", "TOKEN": "secret"}):
            expected_restored_environment = dict(os.environ)
            with contextlib.redirect_stdout(output):
                launcher.execute_verified_installer(
                    verified, ["record-plan", "--confirm", "approved phrase"]
                )
            self.assertEqual(dict(os.environ), expected_restored_environment)
        import json
        observed = json.loads(output.getvalue())
        self.assertEqual(
            observed["argv"],
            [
                str(launcher.INSTALLED_INSTALLER),
                "record-plan",
                "--confirm",
                "approved phrase",
            ],
        )
        self.assertEqual(observed["env"], launcher.SANITIZED_ENVIRONMENT)
        self.assertEqual(observed["cwd"], "/")
        self.assertEqual(sys.argv, previous_argv)
        self.assertEqual(os.getcwd(), previous_directory)
        self.assertEqual(previous_environment, dict(os.environ))

    def test_plan_bound_asset_digest_drift_fails_before_transaction_or_write(self) -> None:
        asset = installer.Asset(
            "locked-job",
            Path("/reviewed/deploy/postgres/backup/locked_job.py"),
            Path("/usr/local/libexec/uten-imp-backup/locked_job.py"),
            0o755,
        )
        approved = {
            "postgresIdentity": {"uid": 1234, "gid": 1235},
            "sources": [
                {
                    "name": asset.name,
                    "source": str(asset.source),
                    "sha256": "a" * 64,
                    "target": str(asset.target),
                    "targetMode": asset.mode,
                }
            ],
            "systemd": {"units": {}, "alertInstances": [], "jobs": []},
        }
        drifted = {
            **approved,
            "sources": [{**approved["sources"][0], "sha256": "b" * 64}],
        }
        capture = mock.Mock(side_effect=AssertionError("asset capture reached after drift"))
        transaction = mock.Mock(side_effect=AssertionError("transaction write reached after drift"))
        write = mock.Mock(side_effect=AssertionError("persistent write reached after drift"))
        patches = (
            mock.patch.object(installer, "_require_root"),
            mock.patch.object(installer, "_assert_fixed_plan_argument"),
            mock.patch.object(installer, "InstallerLock", NoopLock),
            mock.patch.object(installer, "_require_no_installer_transaction"),
            mock.patch.object(installer, "_load_root_json", return_value=({}, b"plan\n")),
            mock.patch.object(installer, "_validate_plan", return_value=approved),
            mock.patch.object(
                installer,
                "_identity",
                return_value=installer.Identity(postgres_uid=1234, postgres_gid=1235),
            ),
            mock.patch.object(installer, "build_assessment", return_value=drifted),
            mock.patch.object(installer, "_asset_payloads", capture),
            mock.patch.object(installer, "_prepare_transaction", transaction),
            mock.patch.object(installer, "_atomic_write", write),
        )
        for patcher in patches:
            patcher.start()
        try:
            with self.assertRaisesRegex(
                installer.InstallerError, "host/source assessment changed"
            ):
                installer.apply_plan(
                    plan_path=installer.PLAN_PATH,
                    expected_plan_sha256="c" * 64,
                    confirmation=installer.APPLY_CONFIRMATION,
                    assets=(asset,),
                    runner=mock.Mock(),
                )
        finally:
            for patcher in reversed(patches):
                patcher.stop()
        capture.assert_not_called()
        transaction.assert_not_called()
        write.assert_not_called()

    def test_requires_leading_boundary_and_rejects_control_characters(self) -> None:
        for arguments in ([], ["assess"], ["--"], ["--", "assess\n"]):
            with self.subTest(arguments=arguments):
                with self.assertRaises(launcher.LauncherError):
                    launcher.parse_installer_arguments(arguments)
        self.assertEqual(
            launcher.parse_installer_arguments(["--", "assess"]), ["assess"]
        )

    def test_source_has_no_path_execution_or_installer_import_escape(self) -> None:
        source = LAUNCHER_PATH.read_text(encoding="utf-8")
        for forbidden in (
            "runpy",
            "importlib",
            "subprocess",
            "os.exec",
            "execfile",
            "SourceFileLoader",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)
        self.assertIn("compile(\n            verified.payload", source)
        self.assertIn("exec(code, namespace, namespace)", source)


if __name__ == "__main__":
    unittest.main()
