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
    "prepare_existing_test_host_reviewed_installer_bundles", PREPARER_PATH
)
assert SPEC is not None and SPEC.loader is not None
preparer = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = preparer
SPEC.loader.exec_module(preparer)
BUILDER_SPEC = importlib.util.spec_from_file_location(
    "build_internal_test_reviewed_installer_bundles", BUILDER_PATH
)
assert BUILDER_SPEC is not None and BUILDER_SPEC.loader is not None
builder = importlib.util.module_from_spec(BUILDER_SPEC)
sys.modules[BUILDER_SPEC.name] = builder
BUILDER_SPEC.loader.exec_module(builder)


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def payloads(keys: frozenset[str]) -> dict[str, bytes]:
    return {key: preparer.SOURCES[key].read_bytes() for key in keys}


class FrozenBundleContractTest(unittest.TestCase):
    def test_monitoring_launcher_binds_exact_fifteen_file_inventory(self) -> None:
        captured = payloads(preparer.MONITORING_INSTALLER_SOURCE_KEYS)
        result = preparer.validate_monitoring_installer_source_payloads(captured)
        contract = preparer._monitoring_installer_launcher_contract(
            captured[preparer.MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY]
        )
        relative = tuple(
            preparer.MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.values()
        )
        self.assertEqual(15, len(relative))
        self.assertEqual(relative, contract["sourceBundleRelativeFiles"])
        self.assertEqual(
            preparer.REVIEWED_MONITORING_INSTALLER_LAUNCHER_SHA256,
            result["launcherSha256"],
        )
        self.assertEqual(
            {
                path: sha256(captured[key])
                for key, path in preparer.MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.items()
            },
            contract["reviewedSourceSha256"],
        )
        self.assertEqual(
            Path("/usr/local/sbin/uten-imp-existing-monitoring-installer"),
            preparer.TARGETS[preparer.MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY],
        )

    def test_retention_launcher_binds_final_updater_manager_guard_and_ten_files(self) -> None:
        captured = payloads(preparer.RETENTION_INSTALLER_SOURCE_KEYS)
        result = preparer.validate_retention_installer_source_payloads(captured)
        contract = preparer._retention_installer_launcher_contract(
            captured[preparer.RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY]
        )
        runtime = preparer._retention_runtime_launcher_contract(
            captured[preparer.RETENTION_INSTALLER_RUNTIME_LAUNCHER_SOURCE_KEY]
        )
        relative = tuple(
            preparer.RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY.values()
        )
        self.assertEqual(10, len(relative))
        self.assertEqual(relative, contract["sourceBundleRelativeFiles"])
        self.assertEqual(
            sha256(captured[preparer.RETENTION_INSTALLER_UPDATER_SOURCE_KEY]),
            runtime["updaterSha256"],
        )
        self.assertEqual(
            sha256(captured[preparer.RETENTION_INSTALLER_MANAGER_SOURCE_KEY]),
            runtime["managerSha256"],
        )
        self.assertEqual(
            preparer.REVIEWED_RETENTION_INSTALLER_LAUNCHER_SHA256,
            result["launcherSha256"],
        )
        self.assertEqual(
            Path("/usr/local/sbin/uten-imp-release-retention-installer"),
            preparer.TARGETS[preparer.RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY],
        )

    def test_missing_extra_embedded_digest_and_runtime_pin_drift_are_rejected(self) -> None:
        monitoring = payloads(preparer.MONITORING_INSTALLER_SOURCE_KEYS)
        missing = dict(monitoring)
        missing.pop(preparer.MONITORING_INSTALLER_INSTALLER_SOURCE_KEY)
        with self.assertRaisesRegex(preparer.PreparationError, "inventory differs"):
            preparer.validate_monitoring_installer_source_payloads(missing)
        changed = dict(monitoring)
        changed["monitoringCommonSha256"] += b"\n# drift\n"
        with self.assertRaisesRegex(preparer.PreparationError, "contract differs"):
            preparer.validate_monitoring_installer_source_payloads(changed)

        retention = payloads(preparer.RETENTION_INSTALLER_SOURCE_KEYS)
        stale_updater = dict(retention)
        stale_updater[preparer.RETENTION_INSTALLER_UPDATER_SOURCE_KEY] += b"\n# drift\n"
        with self.assertRaisesRegex(preparer.PreparationError, "contract differs"):
            preparer.validate_retention_installer_source_payloads(stale_updater)
        stale_launcher = dict(retention)
        stale_launcher[preparer.RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY] += b"\n# drift\n"
        with self.assertRaisesRegex(preparer.PreparationError, "frozen reviewed"):
            preparer.validate_retention_installer_source_payloads(stale_launcher)

    def test_builder_binds_all_captured_bytes_and_all_three_preimage_inventories(self) -> None:
        function_source = textwrap.dedent(inspect.getsource(builder.build))
        self.assertIn("validate_trusted_installer_source_payloads", function_source)
        self.assertIn("trusted_installer_target_preimages", function_source)
        self.assertIn("TRUSTED_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEYS", function_source)
        self.assertLess(
            function_source.index("payload, digest = stable_root_source"),
            function_source.index("validate_trusted_installer_source_payloads"),
        )
        self.assertEqual(
            preparer.TRUSTED_INSTALLER_SOURCE_KEYS,
            frozenset(preparer.SOURCES) & preparer.TRUSTED_INSTALLER_SOURCE_KEYS,
        )
        self.assertEqual(
            preparer.TRUSTED_INSTALLER_SOURCE_KEYS,
            frozenset(preparer.TARGETS) & preparer.TRUSTED_INSTALLER_SOURCE_KEYS,
        )

    def test_mutation_authority_precedes_inert_publication_and_launcher_is_last(self) -> None:
        source = PREPARER_PATH.read_text(encoding="utf-8")
        self.assertLess(
            source.index("    authorize_host_mutation("),
            source.index("    install_trusted_installer_assets("),
        )
        function_source = textwrap.dedent(
            inspect.getsource(preparer._install_trusted_installer_bundle)
        )
        tree = ast.parse(function_source)
        called = {
            node.func.id
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }
        self.assertNotIn("run", called)
        self.assertNotIn("exec", called)
        self.assertNotIn("compile", called)
        self.assertNotIn("subprocess", function_source)
        self.assertNotIn("systemctl", function_source)
        self.assertLess(
            function_source.index("for key in relative_by_source_key"),
            function_source.index("payloads[launcher_source_key]"),
        )

    def test_snapshot_drift_is_rejected_before_any_publication(self) -> None:
        captured = payloads(preparer.TRUSTED_INSTALLER_SOURCE_KEYS)

        def read_snapshot(path: Path, *, mode: int | None = None) -> bytes:
            self.assertEqual(0o600, mode)
            return path.read_bytes()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshots: dict[str, Path] = {}
            reviewed = {"sourceSha256": {}}
            for key, raw in captured.items():
                path = root / key
                path.write_bytes(raw)
                path.chmod(0o600)
                snapshots[key] = path
                reviewed["sourceSha256"][key] = sha256(raw)
            changed = preparer.RETENTION_INSTALLER_RUNTIME_LAUNCHER_SOURCE_KEY
            snapshots[changed].write_bytes(b"snapshot drift\n")
            snapshots[changed].chmod(0o600)
            with patch.object(
                preparer, "stable_root_bytes", side_effect=read_snapshot
            ):
                with self.assertRaisesRegex(
                    preparer.PreparationError, "digest differs"
                ):
                    preparer.capture_trusted_installer_snapshot_payloads(
                        snapshots, reviewed
                    )


@unittest.skipUnless(
    os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
    "exact root-owned bundle contracts run on Linux as root",
)
class RootOwnedBundlePublicationTest(unittest.TestCase):
    @contextlib.contextmanager
    def layout(self, directory: str, basename: str, launcher_name: str, relative):
        root = Path(directory)
        local = root / "usr/local"
        share = local / "share"
        sbin = local / "sbin"
        share.mkdir(parents=True, mode=0o755)
        sbin.mkdir(mode=0o755)
        for path in (root / "usr", local, share, sbin):
            path.chmod(0o755)
        bundle = share / basename
        launcher = sbin / launcher_name
        targets = {key: bundle / value for key, value in relative.items()}
        yield bundle, launcher, targets

    @staticmethod
    def reviewed(keys: frozenset[str], inventory_key: str) -> dict[str, object]:
        preimages: dict[str, str | None] = {key: None for key in keys}
        preimages[inventory_key] = None
        return {"targetPreimageSha256": preimages}

    def exercise_bundle(
        self,
        *,
        label: str,
        launcher_key: str,
        bundle_keys: frozenset[str],
        source_keys: frozenset[str],
        inventory_key: str,
        relative: dict[str, str],
        basename: str,
        launcher_name: str,
        validator,
    ) -> None:
        captured = payloads(source_keys)
        with tempfile.TemporaryDirectory(dir="/root") as directory:
            with self.layout(directory, basename, launcher_name, relative) as (
                bundle,
                launcher,
                targets,
            ):
                reviewed = self.reviewed(source_keys, inventory_key)
                with patch.object(preparer, "run") as run, patch.object(
                    preparer,
                    "_publish_trusted_installer_payload",
                    wraps=preparer._publish_trusted_installer_payload,
                ) as publish:
                    first = preparer._install_trusted_installer_bundle(
                        reviewed,
                        captured,
                        label=label,
                        launcher_source_key=launcher_key,
                        launcher_target=launcher,
                        bundle_root=bundle,
                        relative_by_source_key=relative,
                        bundle_targets=targets,
                        source_keys=source_keys,
                        bundle_source_keys=bundle_keys,
                        validator=validator,
                        resume_authorized=False,
                    )
                    second = preparer._install_trusted_installer_bundle(
                        reviewed,
                        captured,
                        label=label,
                        launcher_source_key=launcher_key,
                        launcher_target=launcher,
                        bundle_root=bundle,
                        relative_by_source_key=relative,
                        bundle_targets=targets,
                        source_keys=source_keys,
                        bundle_source_keys=bundle_keys,
                        validator=validator,
                        resume_authorized=True,
                    )
                run.assert_not_called()
                self.assertEqual(first, second)
                self.assertEqual(launcher, publish.call_args_list[-1].args[1])
                self.assertEqual(0o500, stat.S_IMODE(launcher.lstat().st_mode))
                self.assertEqual(1, launcher.lstat().st_nlink)
                for target in targets.values():
                    self.assertEqual(0o400, stat.S_IMODE(target.lstat().st_mode))
                    self.assertEqual(1, target.lstat().st_nlink)

                state = preparer._trusted_bundle_state(
                    label=label,
                    bundle_root=bundle,
                    relative_by_source_key=relative,
                    bundle_source_keys=bundle_keys,
                    require_complete=True,
                )
                live_reviewed = {
                    "targetPreimageSha256": {
                        launcher_key: sha256(launcher.read_bytes()),
                        **state["fileSha256"],
                        inventory_key: state["inventorySha256"],
                    }
                }
                victim_key = next(iter(bundle_keys))
                victim = targets[victim_key]
                victim.chmod(0o600)
                victim.write_bytes(b"unknown live bytes\n")
                victim.chmod(0o400)
                with self.assertRaisesRegex(preparer.PreparationError, "unknown live bytes"):
                    preparer._validate_trusted_bundle_target_preimage(
                        live_reviewed,
                        captured,
                        label=label,
                        launcher_source_key=launcher_key,
                        inventory_preimage_key=inventory_key,
                        bundle_root=bundle,
                        launcher_target=launcher,
                        relative_by_source_key=relative,
                        bundle_source_keys=bundle_keys,
                        source_keys=source_keys,
                        resume_authorized=True,
                    )

                victim.chmod(0o600)
                victim.write_bytes(captured[victim_key])
                victim.chmod(0o400)
                extra = bundle / "unexpected"
                extra.write_bytes(b"extra\n")
                extra.chmod(0o400)
                with self.assertRaisesRegex(preparer.PreparationError, "unexpected"):
                    preparer._trusted_bundle_state(
                        label=label,
                        bundle_root=bundle,
                        relative_by_source_key=relative,
                        bundle_source_keys=bundle_keys,
                        require_complete=True,
                    )
                extra.unlink()
                victim.unlink()
                with self.assertRaisesRegex(preparer.PreparationError, "missing"):
                    preparer._trusted_bundle_state(
                        label=label,
                        bundle_root=bundle,
                        relative_by_source_key=relative,
                        bundle_source_keys=bundle_keys,
                        require_complete=True,
                    )

    def test_monitoring_bundle_is_exact_inert_and_resumable(self) -> None:
        self.exercise_bundle(
            label="monitoring installer",
            launcher_key=preparer.MONITORING_INSTALLER_LAUNCHER_SOURCE_KEY,
            bundle_keys=preparer.MONITORING_INSTALLER_BUNDLE_SOURCE_KEYS,
            source_keys=preparer.MONITORING_INSTALLER_SOURCE_KEYS,
            inventory_key=preparer.MONITORING_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY,
            relative=preparer.MONITORING_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
            basename="uten-imp-monitoring-installer-source",
            launcher_name="uten-imp-existing-monitoring-installer",
            validator=preparer.validate_monitoring_installer_source_payloads,
        )

    def test_retention_bundle_is_exact_inert_and_resumable(self) -> None:
        self.exercise_bundle(
            label="retention installer",
            launcher_key=preparer.RETENTION_INSTALLER_LAUNCHER_SOURCE_KEY,
            bundle_keys=preparer.RETENTION_INSTALLER_BUNDLE_SOURCE_KEYS,
            source_keys=preparer.RETENTION_INSTALLER_SOURCE_KEYS,
            inventory_key=preparer.RETENTION_INSTALLER_BUNDLE_INVENTORY_PREIMAGE_KEY,
            relative=preparer.RETENTION_INSTALLER_BUNDLE_RELATIVE_BY_SOURCE_KEY,
            basename="uten-imp-release-retention-installer-source",
            launcher_name="uten-imp-release-retention-installer",
            validator=preparer.validate_retention_installer_source_payloads,
        )


if __name__ == "__main__":
    unittest.main()
