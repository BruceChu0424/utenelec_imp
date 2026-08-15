import ast
import contextlib
import hashlib
import importlib.util
import inspect
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch


SETUP_DIR = Path(__file__).parent
PREPARER_PATH = SETUP_DIR / "prepare-existing-test-host-internal-runtime.py"
BUILDER_PATH = SETUP_DIR / "build-internal-test-reviewed-host-manifest.py"
SPEC = importlib.util.spec_from_file_location(
    "prepare_existing_test_host_backup_bundle", PREPARER_PATH
)
assert SPEC is not None and SPEC.loader is not None
preparer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = preparer
SPEC.loader.exec_module(preparer)
BUILDER_SPEC = importlib.util.spec_from_file_location(
    "build_internal_test_reviewed_host_backup_bundle", BUILDER_PATH
)
assert BUILDER_SPEC is not None and BUILDER_SPEC.loader is not None
builder = importlib.util.module_from_spec(BUILDER_SPEC)
sys.modules[BUILDER_SPEC.name] = builder
BUILDER_SPEC.loader.exec_module(builder)


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def source_payloads() -> dict[str, bytes]:
    return {
        key: preparer.SOURCES[key].read_bytes()
        for key in preparer.BACKUP_INSTALLER_SOURCE_KEYS
    }


class FrozenSourceContractTest(unittest.TestCase):
    def test_sources_targets_and_launcher_allowlist_are_exact(self):
        payloads = source_payloads()
        contract = preparer.validate_backup_installer_source_payloads(payloads)
        launcher = preparer._backup_installer_launcher_contract(
            payloads[preparer.BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY]
        )
        expected_relative = tuple(
            preparer.BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.values()
        )

        self.assertEqual(18, len(expected_relative))
        self.assertEqual(expected_relative, launcher["sourceBundleRelativeFiles"])
        self.assertEqual(
            preparer.REVIEWED_BACKUP_INSTALLER_LAUNCHER_SHA256,
            contract["launcherSha256"],
        )
        self.assertEqual(
            sha256(payloads[preparer.BACKUP_INSTALLER_INSTALLER_SOURCE_KEY]),
            launcher["reviewedInstallerSha256"],
        )
        self.assertEqual(
            preparer.BACKUP_INSTALLER_SOURCE_KEYS,
            frozenset(preparer.SOURCES) & preparer.BACKUP_INSTALLER_SOURCE_KEYS,
        )
        self.assertEqual(
            preparer.BACKUP_INSTALLER_SOURCE_KEYS,
            frozenset(preparer.TARGETS) & preparer.BACKUP_INSTALLER_SOURCE_KEYS,
        )
        self.assertEqual(
            Path("/usr/local/sbin/uten-imp-existing-backup-installer"),
            preparer.TARGETS[preparer.BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY],
        )
        for key, relative in preparer.BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items():
            self.assertEqual(
                preparer.BACKUP_INSTALLER_BUNDLE_ROOT / relative,
                preparer.TARGETS[key],
            )

    def test_source_drift_and_launcher_contract_drift_are_rejected(self):
        payloads = source_payloads()
        changed_installer = dict(payloads)
        changed_installer[preparer.BACKUP_INSTALLER_INSTALLER_SOURCE_KEY] += b"\n# drift\n"
        with self.assertRaisesRegex(preparer.PreparationError, "contract differs"):
            preparer.validate_backup_installer_source_payloads(changed_installer)

        changed_launcher = dict(payloads)
        launcher_key = preparer.BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY
        changed_launcher[launcher_key] += b"\n# drift\n"
        with self.assertRaisesRegex(preparer.PreparationError, "frozen reviewed"):
            preparer.validate_backup_installer_source_payloads(changed_launcher)

    def test_publication_is_after_mutation_authority_and_has_no_dispatch(self):
        source = PREPARER_PATH.read_text(encoding="utf-8")
        self.assertLess(
            source.index("    authorize_host_mutation("),
            source.index("    install_trusted_installer_assets("),
        )
        function_source = inspect.getsource(preparer.install_trusted_installer_assets)
        tree = ast.parse(function_source)
        called_names = {
            node.func.id
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }
        self.assertNotIn("run", called_names)
        self.assertNotIn("exec", called_names)
        self.assertNotIn("compile", called_names)
        self.assertNotIn("subprocess", function_source)
        self.assertNotIn("systemctl", function_source)

    def test_manifest_builder_binds_captured_bytes_and_bundle_preimage(self):
        function_source = textwrap.dedent(inspect.getsource(builder.build))
        tree = ast.parse(function_source)
        called_attributes = {
            node.func.attr
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
        }
        self.assertIn("validate_trusted_installer_source_payloads", called_attributes)
        self.assertIn("trusted_installer_target_preimages", called_attributes)
        self.assertIn("payload, digest = stable_root_source", function_source)
        self.assertIn(
            "TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS", function_source
        )
        self.assertLess(
            function_source.index("payload, digest = stable_root_source"),
            function_source.index("validate_trusted_installer_source_payloads"),
        )


@unittest.skipUnless(
    os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
    "exact root-owned bundle contracts run on Linux as root",
)
class RootOwnedPublicationTest(unittest.TestCase):
    @contextlib.contextmanager
    def target_layout(self, directory: str):
        root = Path(directory)
        local = root / "usr/local"
        share = local / "share"
        sbin = local / "sbin"
        share.mkdir(parents=True, mode=0o755)
        sbin.mkdir(mode=0o755)
        for path in (root / "usr", local, share, sbin):
            path.chmod(0o755)
        bundle = share / "uten-imp-backup-installer-source"
        launcher = sbin / "uten-imp-existing-backup-installer"
        targets = {
            key: bundle / relative
            for key, relative in preparer.BACKUP_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
        }
        with patch.object(
            preparer, "BACKUP_INSTALLER_BUNDLE_ROOT", bundle
        ), patch.object(
            preparer, "BACKUP_INSTALLER_LAUNCHER_TARGET", launcher
        ), patch.object(
            preparer, "BACKUP_INSTALLER_BUNDLE_TARGETS", targets
        ):
            yield bundle, launcher, targets

    @staticmethod
    def absent_reviewed() -> dict[str, object]:
        preimages: dict[str, str | None] = {
            key: None for key in preparer.BACKUP_INSTALLER_SOURCE_KEYS
        }
        preimages[preparer.BACKUP_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY] = None
        return {"targetPreimageSha256": preimages}

    @staticmethod
    def reviewed_from_live() -> dict[str, object]:
        state = preparer.backup_installer_bundle_state(require_complete=False)
        preimages = {
            preparer.BACKUP_INSTALLER_LAUNCHER_SOURCE_KEY: (
                preparer.backup_installer_launcher_preimage_digest()
            ),
            **state["fileSha256"],
            preparer.BACKUP_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY: state[
                "inventorySha256"
            ],
        }
        return {"targetPreimageSha256": preimages}

    def test_atomic_install_is_inert_exact_and_resume_is_idempotent(self):
        payloads = source_payloads()
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            with self.target_layout(directory) as (bundle, launcher, targets):
                reviewed = self.absent_reviewed()
                with patch.object(preparer, "run") as run:
                    first = preparer.install_backup_installer_assets(
                        reviewed, payloads, resume_authorized=False
                    )
                    second = preparer.install_backup_installer_assets(
                        reviewed, payloads, resume_authorized=True
                    )
                run.assert_not_called()

                self.assertEqual(first, second)
                self.assertEqual(0o500, stat.S_IMODE(launcher.lstat().st_mode))
                self.assertEqual(1, launcher.lstat().st_nlink)
                for relative in preparer._backup_installer_expected_directories():
                    path = bundle if relative == Path(".") else bundle / relative
                    self.assertEqual(0o500, stat.S_IMODE(path.lstat().st_mode))
                for key, target in targets.items():
                    details = target.lstat()
                    self.assertEqual(0o400, stat.S_IMODE(details.st_mode))
                    self.assertEqual(1, details.st_nlink)
                    self.assertEqual(payloads[key], target.read_bytes())
                preparer.validate_backup_installer_live_contract(payloads)

    def test_unknown_preimage_extra_missing_and_mode_drift_are_rejected(self):
        payloads = source_payloads()
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            with self.target_layout(directory) as (bundle, launcher, targets):
                preparer.install_backup_installer_assets(
                    self.absent_reviewed(), payloads, resume_authorized=False
                )
                reviewed = self.reviewed_from_live()
                victim_key = preparer.BACKUP_INSTALLER_INSTALLER_SOURCE_KEY
                victim = targets[victim_key]

                launcher.chmod(0o700)
                with self.assertRaises(preparer.PreparationError):
                    preparer.backup_installer_launcher_preimage_digest()
                launcher.chmod(0o500)
                bundle.chmod(0o700)
                with self.assertRaises(preparer.PreparationError):
                    preparer.backup_installer_bundle_state(require_complete=True)
                bundle.chmod(0o500)

                victim.chmod(0o600)
                victim.write_bytes(b"unknown preimage\n")
                victim.chmod(0o400)
                with self.assertRaisesRegex(
                    preparer.PreparationError, "preimage|unknown live bytes"
                ):
                    preparer.validate_backup_installer_target_preimage(
                        reviewed, payloads, resume_authorized=True
                    )

                victim.chmod(0o600)
                victim.write_bytes(payloads[victim_key])
                victim.chmod(0o400)
                extra = bundle / "unexpected"
                extra.write_bytes(b"extra\n")
                extra.chmod(0o400)
                with self.assertRaisesRegex(preparer.PreparationError, "unexpected"):
                    preparer.backup_installer_bundle_state(require_complete=True)
                extra.unlink()

                victim.unlink()
                with self.assertRaisesRegex(preparer.PreparationError, "missing"):
                    preparer.backup_installer_bundle_state(require_complete=True)
                victim.write_bytes(payloads[victim_key])
                victim.chmod(0o440)
                with self.assertRaises(preparer.PreparationError):
                    preparer.backup_installer_bundle_state(require_complete=True)

    def test_snapshot_digest_drift_is_rejected_before_publication(self):
        payloads = source_payloads()
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            root = Path(directory)
            snapshots: dict[str, Path] = {}
            hashes: dict[str, str] = {}
            for key, payload in payloads.items():
                path = root / key
                path.write_bytes(payload)
                path.chmod(0o600)
                snapshots[key] = path
                hashes[key] = sha256(payload)
            changed_key = preparer.BACKUP_INSTALLER_INSTALLER_SOURCE_KEY
            snapshots[changed_key].write_bytes(b"source snapshot drift\n")
            snapshots[changed_key].chmod(0o600)
            with self.assertRaisesRegex(preparer.PreparationError, "digest differs"):
                preparer.capture_backup_installer_snapshot_payloads(
                    snapshots, {"sourceSha256": hashes}
                )


if __name__ == "__main__":
    unittest.main()
