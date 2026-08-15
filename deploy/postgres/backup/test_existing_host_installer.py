from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


HERE = Path(__file__).resolve().parent


def load_module():
    name = "uten_existing_host_backup_installer_tested"
    spec = importlib.util.spec_from_file_location(name, HERE / "existing_host_installer.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


installer = load_module()


class NoopLock:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None


def inactive_unit(unit: str, *, installed: bool) -> dict[str, str]:
    is_timer = unit in installer.TIMER_UNITS
    fragment = str(Path("/etc/systemd/system") / unit) if installed else ""
    return {
        "LoadState": "loaded" if installed else "not-found",
        "ActiveState": "inactive",
        "SubState": "dead",
        "UnitFileState": "disabled" if is_timer else ("static" if installed else "not-found"),
        "FragmentPath": fragment,
        "DropInPaths": "",
        "Requires": "",
        "Requisite": "",
        "Wants": "",
        "BindsTo": "",
        "Upholds": "",
        "RequiresMountsFor": "",
        "After": (
            installer.POSTGRES_INSTANCE_UNIT
            if unit
            in {
                "uten-pgbackup.service",
                "uten-pgbackup-repo2.service",
                "uten-pgbackup-health.service",
            }
            else ""
        ),
        "User": "root" if unit in installer.EXECSTART_NEEDLES else "",
        "Group": "root" if unit in installer.EXECSTART_NEEDLES else "",
        "ExecStart": installer.EXECSTART_NEEDLES.get(unit, ""),
        "Restart": (
            "on-failure"
            if unit in {"uten-pgbackup.service", "uten-pgbackup-repo2.service"}
            else "no"
        ),
    }


class AssetAndStaticContractTest(unittest.TestCase):
    def test_asset_inventory_is_complete_and_does_not_install_configuration(self):
        self.assertEqual(
            {
                "locked-job",
                "repo2-runtime",
                "health-runtime",
                "alert-runtime",
                "acceptance-runtime",
                "commissioner-runtime",
                "internal-test-first-backup-producer",
                "internal-test-first-backup-commissioner",
                "repo1-service",
                "repo1-timer",
                "repo2-service",
                "repo2-timer",
                "health-service",
                "health-timer",
                "alert-service",
                "alert-drain-service",
                "alert-drain-timer",
            },
            {asset.name for asset in installer.ASSETS},
        )
        targets = [str(asset.target) for asset in installer.ASSETS]
        self.assertEqual(len(targets), len(set(targets)))
        self.assertEqual(
            installer.SYSTEMD_SOURCE / "uten-pgbackup.timer.example",
            next(asset.source for asset in installer.ASSETS if asset.name == "repo1-timer"),
        )
        for target in targets:
            self.assertFalse(target.startswith("/etc/pgbackrest"))
            self.assertFalse(target.startswith("/etc/uten-imp-backup"))

    def test_installer_has_no_unit_start_stop_enable_or_disable_command(self):
        source = (HERE / "existing_host_installer.py").read_text(encoding="utf-8")
        forbidden = r'"/usr/bin/systemctl"\s*,\s*"(?:start|stop|restart|enable|disable|mask|unmask)"'
        self.assertIsNone(re.search(forbidden, source))
        self.assertIn('["/usr/bin/systemctl", "daemon-reload"]', source)
        self.assertNotIn("os.link(", source)
        self.assertIn("renameat2(RENAME_NOREPLACE)", source)

    def test_shared_repo1_timer_is_persistent_but_not_installed_enabled(self):
        timer = (installer.SYSTEMD_SOURCE / "uten-pgbackup.timer.example").read_text(
            encoding="utf-8"
        )
        self.assertIn("Persistent=true", timer)
        self.assertIn("Unit=uten-pgbackup.service", timer)
        self.assertNotIn("systemctl enable", timer)

    def test_reviewed_source_stable_fd_capture_rejects_path_replacement(self):
        source = mock.MagicMock()
        source.resolve.return_value = source
        source.parent = Path("/reviewed")
        before = SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600,
            st_uid=0,
            st_gid=0,
            st_nlink=1,
            st_size=1,
            st_dev=1,
            st_ino=2,
        )
        replaced = SimpleNamespace(**{**before.__dict__, "st_ino": 3})
        source.lstat.side_effect = (before, replaced)
        asset = installer.Asset("stable", source, Path("/fixed/target"), 0o755)
        with mock.patch.object(
            installer, "_require_root_parent_chain"
        ), mock.patch.object(installer.os, "open", return_value=9), mock.patch.object(
            installer.os, "fstat", side_effect=(before, before)
        ), mock.patch.object(installer.os, "read", side_effect=(b"x", b"")), mock.patch.object(
            installer.os, "close"
        ):
            with self.assertRaisesRegex(installer.InstallerError, "path changed"):
                installer._safe_source_bytes(asset)

    def test_asset_rollback_is_blocked_after_first_backup_plan_or_evidence_exists(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            transactions = state / "transactions"
            receipts = state / "receipts"
            transactions.mkdir()
            receipts.mkdir()
            (state / "commission-plan.json").write_text("{}", encoding="utf-8")
            with mock.patch.object(
                installer,
                "INTERNAL_TEST_FIRST_BACKUP_COMMISSIONER_DIR",
                state,
            ), mock.patch.object(
                installer,
                "INTERNAL_TEST_FIRST_BACKUP_TRANSACTIONS_DIR",
                transactions,
            ), mock.patch.object(
                installer,
                "INTERNAL_TEST_FIRST_BACKUP_RECEIPTS_DIR",
                receipts,
            ), mock.patch.object(installer, "_require_safe_directory"):
                with self.assertRaisesRegex(
                    installer.InstallerError, "blocks asset rollback"
                ):
                    installer._require_first_backup_commissioning_never_started()


class ReadOnlyAssessmentContractTest(unittest.TestCase):
    def test_fixed_command_timeout_is_bounded_and_fail_closed(self):
        with mock.patch.object(
            installer.subprocess,
            "run",
            side_effect=installer.subprocess.TimeoutExpired("systemctl", 60),
        ) as invoked:
            with self.assertRaisesRegex(installer.InstallerError, "timed out"):
                installer._run_read_only(["/usr/bin/systemctl", "show", "fixed.service"])
        self.assertEqual(installer.COMMAND_TIMEOUT_SECONDS, invoked.call_args.kwargs["timeout"])

    def test_assess_has_zero_filesystem_mutation_and_only_read_only_systemctl_calls(self):
        commands: list[tuple[str, ...]] = []

        def runner(command):
            command = tuple(command)
            commands.append(command)
            if command[:2] == ("/usr/bin/systemctl", "show"):
                unit = command[2]
                values = inactive_unit(unit, installed=False)
                if unit == "uten-pgbackup.service":
                    values["ExecStart"] = "/bin/false --password=SECRET_SENTINEL"
                return SimpleNamespace(
                    returncode=1,
                    stdout="".join(f"{key}={values[key]}\n" for key in installer.UNIT_PROPERTIES),
                    stderr="",
                )
            if command[:2] in {
                ("/usr/bin/systemctl", "list-units"),
                ("/usr/bin/systemctl", "list-jobs"),
            }:
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if command[0] == "/usr/bin/findmnt":
                return SimpleNamespace(
                    returncode=0,
                    stdout=json.dumps(
                        {
                            "filesystems": [
                                {
                                    "target": "/data",
                                    "source": "//SECRET_SENTINEL@storage/private",
                                    "fstype": "cifs",
                                    "options": "rw,credentials=/SECRET_SENTINEL/credentials",
                                    "uuid": "SECRET_SENTINEL-uuid",
                                }
                            ]
                        }
                    ),
                    stderr="",
                )
            if command[0] == "/usr/bin/ss":
                return SimpleNamespace(
                    returncode=0,
                    stdout="LISTEN 0 244 127.0.0.1:5432 0.0.0.0:*\n",
                    stderr="",
                )
            raise AssertionError(f"unexpected command: {command}")

        fail_write = mock.Mock(side_effect=AssertionError("assess attempted a write"))
        identity = installer.Identity(1234, 1235)
        with mock.patch.object(installer, "_require_root"), mock.patch.object(
            installer, "_identity", return_value=identity
        ), mock.patch.object(installer, "_require_no_installer_transaction"), mock.patch.object(
            installer, "_source_observations", return_value=[]
        ), mock.patch.object(
            installer, "_file_observation", return_value={"state": "absent"}
        ), mock.patch.object(
            installer, "_maintenance_lock_observation", return_value={"state": "absent"}
        ), mock.patch.object(
            installer, "_directory_observation", return_value={"state": "absent"}
        ), mock.patch.object(
            installer, "_dropin_observation", return_value=[]
        ), mock.patch.object(
            installer, "_machine_id_digest", return_value="a" * 64
        ), mock.patch.object(
            installer, "_ensure_state_layout", fail_write
        ), mock.patch.object(
            installer, "InstallerLock", fail_write
        ), mock.patch.object(
            installer, "_atomic_directory", fail_write
        ), mock.patch.object(
            installer, "_atomic_write", fail_write
        ), mock.patch.object(
            installer.os, "open", fail_write
        ), mock.patch.object(
            installer.os, "mkdir", fail_write
        ), mock.patch.object(
            installer.os, "rename", fail_write
        ), mock.patch.object(
            installer.os, "replace", fail_write
        ), mock.patch.object(
            installer.os, "link", fail_write
        ), mock.patch.object(
            installer.os, "unlink", fail_write
        ):
            envelope, digest = installer.assess(identity=identity, assets=(), runner=runner)

        self.assertEqual(digest, envelope["assessmentSha256"])
        self.assertEqual(
            digest,
            hashlib.sha256(installer.canonical_bytes(envelope["assessment"])).hexdigest(),
        )
        serialized = json.dumps(envelope, sort_keys=True)
        self.assertNotIn("SECRET_SENTINEL", serialized)
        observed = envelope["assessment"]["systemd"]["units"]["uten-pgbackup.service"]
        self.assertNotIn("ExecStart", observed)
        self.assertEqual(
            hashlib.sha256(b"/bin/false --password=SECRET_SENTINEL").hexdigest(),
            observed["ExecStartSha256"],
        )
        storage = envelope["assessment"]["storage"]
        self.assertEqual(
            {
                "mounted",
                "target",
                "fstype",
                "sourceSha256",
                "optionsPresent",
                "optionCount",
                "uuidSha256",
            },
            set(storage),
        )
        self.assertTrue(storage["optionsPresent"])
        self.assertEqual(2, storage["optionCount"])
        self.assertFalse(
            envelope["assessment"]["postgres"]["listenerObservation"][
                "connectionProbePerformed"
            ]
        )
        fail_write.assert_not_called()
        for command in commands:
            if command[0] == "/usr/bin/systemctl":
                self.assertIn(command[1], {"show", "list-units", "list-jobs"})
            self.assertNotEqual("/usr/bin/pg_isready", command[0])

    def test_even_inactive_alert_instance_is_not_quiescent(self):
        units = {
            unit: inactive_unit(unit, installed=False) for unit in installer.MANAGED_UNITS
        }
        with self.assertRaisesRegex(installer.InstallerError, "must be absent"):
            installer._require_quiescent(
                units,
                [
                    {
                        "unit": "uten-pgbackup-alert@old.service",
                        "load": "loaded",
                        "active": "inactive",
                        "sub": "dead",
                    }
                ],
                [],
                installed=False,
            )

    def test_record_plan_reassesses_and_publishes_inside_one_installer_lock(self):
        held = {"value": False}
        events: list[str] = []
        identity = installer.Identity(1234, 1235)
        assessment = {"postgresIdentity": {"uid": 1234, "gid": 1235}}
        assessment_sha = installer.sha256_bytes(installer.canonical_bytes(assessment))

        class TrackingLock:
            def __enter__(self):
                if held["value"]:
                    raise AssertionError("record-plan attempted a nested/concurrent test lock")
                held["value"] = True
                events.append("lock-enter")
                return self

            def __exit__(self, *_):
                events.append("lock-exit")
                held["value"] = False

        def identify():
            self.assertTrue(held["value"])
            events.append("identity")
            return identity

        def reassess(*_args, **_kwargs):
            self.assertTrue(held["value"])
            events.append("assessment")
            return assessment

        def publish(*_args, **_kwargs):
            self.assertTrue(held["value"])
            events.append("publish")

        with mock.patch.object(installer, "_require_root"), mock.patch.object(
            installer, "InstallerLock", TrackingLock
        ), mock.patch.object(installer, "_identity", side_effect=identify), mock.patch.object(
            installer, "build_assessment", side_effect=reassess
        ), mock.patch.object(installer, "_archive_existing_plan", side_effect=lambda: events.append("archive")), mock.patch.object(
            installer, "_atomic_write", side_effect=publish
        ), mock.patch.object(installer, "_require_no_installer_transaction"):
            _, plan_sha = installer.record_plan(
                expected_assessment_sha256=assessment_sha,
                confirmation=installer.RECORD_CONFIRMATION,
            )

        self.assertRegex(plan_sha, r"^[0-9a-f]{64}$")
        self.assertEqual(
            ["lock-enter", "identity", "assessment", "archive", "publish", "lock-exit"],
            events,
        )


class LoadedSystemdContractTest(unittest.TestCase):
    def setUp(self):
        self.units = {unit: inactive_unit(unit, installed=True) for unit in installer.MANAGED_UNITS}
        self.payloads = {
            str(asset.target): f"payload:{asset.name}".encode("utf-8")
            for asset in installer.ASSETS
        }

    def validate(self):
        def observe_unit(unit, _runner, **_kwargs):
            return dict(self.units[unit])

        def observe_file(path, **_kwargs):
            raw = self.payloads[str(path)]
            return {
                "state": "file",
                "sha256": hashlib.sha256(raw).hexdigest(),
                "uid": 0,
                "gid": 0,
                "mode": next(asset.mode for asset in installer.ASSETS if asset.target == path),
            }

        with mock.patch.object(installer, "_unit_observation", side_effect=observe_unit), mock.patch.object(
            installer, "_alert_instances", return_value=[]
        ), mock.patch.object(installer, "_systemd_jobs", return_value=[]), mock.patch.object(
            installer, "_file_observation", side_effect=observe_file
        ), mock.patch.object(
            installer,
            "_safe_source_bytes",
            side_effect=lambda asset: self.payloads[str(asset.target)],
        ):
            return installer._validate_loaded_contract(
                assets=installer.ASSETS, runner=mock.Mock()
            )

    def test_loaded_contract_proves_exact_fragments_empty_dropins_and_disabled_timers(self):
        result = self.validate()
        self.assertEqual(set(installer.MANAGED_UNITS), set(result["units"]))
        for timer in installer.TIMER_UNITS:
            self.assertEqual("disabled", result["units"][timer]["UnitFileState"])
            self.assertEqual("inactive", result["units"][timer]["ActiveState"])
        for unit in installer.MANAGED_UNITS:
            self.assertEqual(
                str(Path("/etc/systemd/system") / unit),
                result["units"][unit]["FragmentPath"],
            )
            self.assertEqual("", result["units"][unit]["DropInPaths"])

    def test_loaded_contract_rejects_dropin_enablement_and_reverse_pg_or_mount_dependency(self):
        mutations = (
            ("uten-pgbackup.service", "DropInPaths", "/etc/systemd/system/uten-pgbackup.service.d/x.conf"),
            ("uten-pgbackup.timer", "UnitFileState", "enabled"),
            ("uten-pgbackup-repo2.service", "Requires", installer.POSTGRES_INSTANCE_UNIT),
            ("uten-pgbackup.service", "Requires", installer.POSTGRES_META_UNIT),
            ("uten-pgbackup-health.service", "RequiresMountsFor", "/data"),
            ("uten-pgbackup.timer", "Wants", installer.POSTGRES_INSTANCE_UNIT),
            ("uten-pgbackup-alert-drain.timer", "BindsTo", "data.mount"),
            ("uten-pgbackup-alert@.service", "Upholds", installer.POSTGRES_META_UNIT),
        )
        for unit, key, value in mutations:
            with self.subTest(unit=unit, key=key):
                original = self.units[unit][key]
                self.units[unit][key] = value
                try:
                    with self.assertRaises(installer.InstallerError):
                        self.validate()
                finally:
                    self.units[unit][key] = original


class TransactionPhaseContractTest(unittest.TestCase):
    def test_rollback_power_loss_between_unlinks_keeps_active_replay_evidence(self):
        receipt = {
            "schemaVersion": installer.SCHEMA_VERSION,
            "kind": installer.ROLLBACK_KIND,
        }
        raw = installer.canonical_bytes(receipt)
        removed: list[Path] = []

        def injected_power_loss(phase):
            if phase == "uncommissioned-receipt-retired":
                raise RuntimeError("simulated-power-loss")

        with mock.patch.object(
            installer, "_load_root_json", return_value=(receipt, raw)
        ), mock.patch.object(
            installer,
            "_durable_unlink",
            side_effect=lambda path: removed.append(Path(path)),
        ):
            with self.assertRaisesRegex(RuntimeError, "simulated-power-loss"):
                installer._retire_rollback_source_evidence(
                    rollback_receipt_path=Path("/fixed/rollback-receipt.json"),
                    expected_rollback_receipt_sha256=hashlib.sha256(raw).hexdigest(),
                    fault_hook=injected_power_loss,
                )

        self.assertEqual([installer.UNCOMMISSIONED_RECEIPT_PATH], removed)
        self.assertNotIn(installer.ACTIVE_TRANSACTION_PATH, removed)

    def test_best_effort_evidence_digest_never_masks_primary_diagnostics(self):
        with mock.patch.object(installer.os.path, "lexists", return_value=True), mock.patch.object(
            installer, "_load_root_json", side_effect=RuntimeError("secondary-read-failure")
        ):
            result = installer._best_effort_evidence_sha256(
                installer.ACTIVE_TRANSACTION_PATH, "active transaction"
            )
        self.assertEqual("unreadable-RuntimeError", result)

    def test_transaction_inventory_rejects_any_path_not_bound_to_fixed_plan(self):
        identity = installer.Identity(1234, 1235)
        asset = installer.Asset(
            "test-runtime",
            Path("/reviewed/test-runtime.py"),
            Path("/usr/local/libexec/uten-imp-backup/test-runtime.py"),
            0o755,
        )
        source_sha = "1" * 64
        directories = {
            path: {
                "desired": {"uid": uid, "gid": gid, "mode": mode},
                "observed": {"state": "absent"},
            }
            for path, (uid, gid, mode) in installer._expected_directory_specs(identity).items()
        }
        assessment = {
            "postgresIdentity": {"uid": 1234, "gid": 1235},
            "sources": [
                {
                    "name": asset.name,
                    "source": str(asset.source),
                    "sourceSha256": source_sha,
                    "target": str(asset.target),
                    "targetMode": asset.mode,
                }
            ],
            "targets": {
                str(asset.target): {"state": "absent"},
                str(installer.MAINTENANCE_LOCK): {"state": "absent"},
            },
            "directories": directories,
            "dropins": {unit: [] for unit in installer.MANAGED_UNITS},
            "systemd": {"units": {}, "alertInstances": [], "jobs": []},
        }
        plan_sha = "2" * 64
        transaction = installer._transaction_path(plan_sha)
        record = {
            "schemaVersion": 1,
            "kind": installer.TRANSACTION_KIND,
            "planSha256": plan_sha,
            "transactionPath": str(transaction),
            "phase": "prepared",
            "files": [
                {
                    "path": str(asset.target),
                    "original": {"state": "absent"},
                    "preimage": None,
                    "mutation": {
                        "state": "file",
                        "sha256": source_sha,
                        "uid": 0,
                        "gid": 0,
                        "mode": 0o755,
                    },
                },
                {
                    "path": str(installer.MAINTENANCE_LOCK),
                    "original": {"state": "absent"},
                    "preimage": None,
                    "mutation": {
                        "state": "file",
                        "sha256": hashlib.sha256(b"").hexdigest(),
                        "uid": 0,
                        "gid": 1235,
                        "mode": 0o660,
                    },
                },
            ],
            "directories": directories,
            "createdDirectories": sorted(directories),
            "originalSystemd": assessment["systemd"],
        }
        installer._validate_transaction_inventory(
            record,
            plan_assessment=assessment,
            assets=(asset,),
            identity=identity,
        )
        record["files"][0]["path"] = "/etc/shadow"
        with self.assertRaisesRegex(installer.InstallerError, "differs from plan"):
            installer._validate_transaction_inventory(
                record,
                plan_assessment=assessment,
                assets=(asset,),
                identity=identity,
            )

    def test_restore_persists_reload_and_loaded_verification_phases(self):
        phases: list[str] = []
        record = {
            "files": [
                {
                    "path": "/fixed",
                    "original": {"state": "absent"},
                    "mutation": {"state": "absent"},
                },
                {
                    "path": str(installer.MAINTENANCE_LOCK),
                    "original": {"state": "absent"},
                    "mutation": {"state": "file"},
                },
            ],
            "createdDirectories": [],
            "originalSystemd": {"units": {}, "alertInstances": [], "jobs": []},
            "planSha256": "a" * 64,
        }
        restored: list[str] = []

        def update(_transaction, value):
            phases.append(value["phase"])

        with mock.patch.object(installer, "_update_transaction", side_effect=update), mock.patch.object(
            installer,
            "_restore_file_record",
            side_effect=lambda value: restored.append(value["path"]),
        ), mock.patch.object(installer, "_remove_created_directories"), mock.patch.object(
            installer, "_daemon_reload"
        ), mock.patch.object(installer, "_verify_original_systemd"):
            result = installer._restore_transaction(
                Path("/transaction"), record, installer.Identity(1234, 1235), mock.Mock()
            )

        self.assertEqual(
            [
                "rollback-files-pending",
                "rollback-daemon-reload-pending",
                "rollback-daemon-reloaded",
                "rollback-loaded-verified",
                "rollback-maintenance-lock-pending",
                "rolled-back",
            ],
            phases,
        )
        self.assertEqual(["/fixed", str(installer.MAINTENANCE_LOCK)], restored)
        self.assertEqual("rolled-back", result["phase"])

    def test_successful_apply_commits_only_after_loaded_contract_and_uncommissioned_receipt(self):
        assessment = {
            "postgresIdentity": {"uid": 1234, "gid": 1235},
            "systemd": {"units": {}, "alertInstances": [], "jobs": []},
        }
        plan = {"assessment": assessment}
        record = {
            "phase": "prepared",
            "files": [
                {
                    "path": str(installer.MAINTENANCE_LOCK),
                    "original": {"state": "absent"},
                    "mutation": {"state": "file"},
                }
            ],
            "createdDirectories": [],
            "originalSystemd": assessment["systemd"],
        }
        phases: list[str] = []
        receipt_store: dict[str, object] = {}
        unlinks: list[Path] = []

        def load(path, *_args, **_kwargs):
            if Path(path) == installer.PLAN_PATH:
                return plan, b"plan\n"
            if Path(path) == installer.UNCOMMISSIONED_RECEIPT_PATH:
                raw = receipt_store["raw"]
                return receipt_store["value"], raw
            raise AssertionError(f"unexpected evidence load: {path}")

        def write(path, payload, **_metadata):
            if Path(path) == installer.UNCOMMISSIONED_RECEIPT_PATH:
                receipt_store["raw"] = payload
                receipt_store["value"] = json.loads(payload)

        patches = (
            mock.patch.object(installer, "_require_root"),
            mock.patch.object(installer, "_assert_fixed_plan_argument"),
            mock.patch.object(installer, "InstallerLock", NoopLock),
            mock.patch.object(installer, "_require_no_installer_transaction"),
            mock.patch.object(installer, "_load_root_json", side_effect=load),
            mock.patch.object(installer, "_validate_plan", return_value=assessment),
            mock.patch.object(installer, "_identity", return_value=installer.Identity(1234, 1235)),
            mock.patch.object(installer, "build_assessment", return_value=assessment),
            mock.patch.object(installer, "_asset_payloads", return_value={}),
            mock.patch.object(installer, "_prepare_transaction", return_value=(Path("/transaction"), record)),
            mock.patch.object(installer, "_create_planned_directories", return_value=[]),
            mock.patch.object(installer, "_install_maintenance_lock"),
            mock.patch.object(installer, "DatabaseMaintenanceLock", lambda _identity: NoopLock()),
            mock.patch.object(
                installer,
                "_update_transaction",
                side_effect=lambda _transaction, value: phases.append(value["phase"]),
            ),
            mock.patch.object(installer, "_daemon_reload"),
            mock.patch.object(installer, "_systemd_verify"),
            mock.patch.object(
                installer,
                "_validate_loaded_contract",
                return_value={"units": {}, "alertInstances": [], "jobs": []},
            ),
            mock.patch.object(
                installer,
                "_maintenance_lock_observation",
                return_value={"state": "file", "mode": 0o660},
            ),
            mock.patch.object(installer, "_atomic_write", side_effect=write),
            mock.patch.object(
                installer,
                "_durable_unlink",
                side_effect=lambda path: unlinks.append(Path(path)),
            ),
        )
        for patcher in patches:
            patcher.start()
        try:
            receipt, digest = installer.apply_plan(
                plan_path=installer.PLAN_PATH,
                expected_plan_sha256="e" * 64,
                confirmation=installer.APPLY_CONFIRMATION,
                assets=(),
                runner=mock.Mock(),
            )
        finally:
            for patcher in reversed(patches):
                patcher.stop()

        self.assertEqual(
            [
                "directories-ready",
                "maintenance-lock-held",
                "files-installed",
                "daemon-reload-pending",
                "daemon-reloaded",
                "loaded-verification-pending",
                "loaded-verified",
                "receipt-written",
                "committed-uncommissioned",
            ],
            phases,
        )
        self.assertFalse(receipt["commissioned"])
        self.assertEqual(
            hashlib.sha256(receipt_store["raw"]).hexdigest(),
            digest,
        )
        self.assertEqual([installer.ACTIVE_TRANSACTION_PATH], unlinks)

    def test_preparation_closure_writes_root_only_receipt_before_removing_active_evidence(self):
        plan_sha = "b" * 64
        transaction = installer._transaction_path(plan_sha)
        active = {
            "schemaVersion": 1,
            "kind": installer.TRANSACTION_KIND,
            "planSha256": plan_sha,
            "transactionPath": str(transaction),
            "phase": "preparing-preimages",
            "originalSystemd": {"units": {}},
        }
        events: list[tuple[str, object]] = []

        def lexists(path):
            return Path(path) in {installer.ACTIVE_TRANSACTION_PATH, transaction}

        def write(path, payload, **metadata):
            events.append(("write", Path(path)))
            self.assertEqual(0, metadata["uid"])
            self.assertEqual(0, metadata["gid"])
            self.assertEqual(0o600, metadata["mode"])
            if Path(path).parent == installer.ROLLBACK_RECEIPTS_DIR:
                receipt = json.loads(payload)
                self.assertEqual(installer.PREPARATION_CLOSED_KIND, receipt["kind"])
                self.assertFalse(receipt["managedTargetsChanged"])

        def unlink(path):
            events.append(("unlink", Path(path)))

        with mock.patch.object(installer.os.path, "lexists", side_effect=lexists), mock.patch.object(
            installer, "_load_transaction", return_value=(active, installer.canonical_bytes(active))
        ), mock.patch.object(installer, "_require_safe_directory"), mock.patch.object(
            installer, "_atomic_write", side_effect=write
        ), mock.patch.object(installer, "_durable_unlink", side_effect=unlink):
            result = installer._close_preparation_failure(
                plan_sha256=plan_sha,
                original_systemd={"units": {}},
                failure=RuntimeError("failure text must not enter receipt"),
            )

        self.assertIsNotNone(result)
        self.assertEqual(("unlink", installer.ACTIVE_TRANSACTION_PATH), events[-1])
        self.assertGreaterEqual(len([event for event in events if event[0] == "write"]), 2)

    def _apply_failure(self, *, hook_phase: str, rollback_fails: bool = False):
        assessment = {
            "postgresIdentity": {"uid": 1234, "gid": 1235},
            "systemd": {"units": {}, "alertInstances": [], "jobs": []},
        }
        plan = {"assessment": assessment}
        record = {
            "phase": "prepared",
            "files": [
                {
                    "path": str(installer.MAINTENANCE_LOCK),
                    "original": {"state": "absent"},
                    "mutation": {"state": "file"},
                }
            ],
            "createdDirectories": [],
            "originalSystemd": assessment["systemd"],
        }
        phases: list[str] = []

        def update(_transaction, value):
            phases.append(value["phase"])

        def hook(phase):
            if phase == hook_phase:
                raise RuntimeError(f"primary-{phase}")

        restore = mock.Mock(
            side_effect=RuntimeError("rollback-cleanup-failed") if rollback_fails else None
        )
        patches = (
            mock.patch.object(installer, "_require_root"),
            mock.patch.object(installer, "_assert_fixed_plan_argument"),
            mock.patch.object(installer, "InstallerLock", NoopLock),
            mock.patch.object(installer, "_require_no_installer_transaction"),
            mock.patch.object(installer, "_load_root_json", return_value=(plan, b"plan\n")),
            mock.patch.object(installer, "_validate_plan", return_value=assessment),
            mock.patch.object(installer, "_identity", return_value=installer.Identity(1234, 1235)),
            mock.patch.object(installer, "build_assessment", return_value=assessment),
            mock.patch.object(installer, "_asset_payloads", return_value={}),
            mock.patch.object(installer, "_prepare_transaction", return_value=(Path("/transaction"), record)),
            mock.patch.object(installer, "_create_planned_directories", return_value=[]),
            mock.patch.object(installer, "_install_maintenance_lock"),
            mock.patch.object(installer, "DatabaseMaintenanceLock", lambda _identity: NoopLock()),
            mock.patch.object(installer, "_update_transaction", side_effect=update),
            mock.patch.object(installer, "_daemon_reload"),
            mock.patch.object(installer, "_systemd_verify"),
            mock.patch.object(installer, "_validate_loaded_contract", return_value={"units": {}}),
            mock.patch.object(installer, "_maintenance_lock_observation", return_value={"state": "file"}),
            mock.patch.object(installer, "_atomic_write"),
            mock.patch.object(installer, "_restore_transaction", restore),
            mock.patch.object(installer, "_durable_unlink"),
            mock.patch.object(installer.os.path, "lexists", return_value=False),
        )
        for patcher in patches:
            patcher.start()
        try:
            with self.assertRaises(installer.InstallerError) as raised:
                installer.apply_plan(
                    plan_path=installer.PLAN_PATH,
                    expected_plan_sha256="c" * 64,
                    confirmation=installer.APPLY_CONFIRMATION,
                    assets=(),
                    runner=mock.Mock(),
                    fault_hook=hook,
                )
        finally:
            for patcher in reversed(patches):
                patcher.stop()
        return str(raised.exception), phases, restore

    def test_each_durable_apply_boundary_automatically_rolls_back_and_keeps_primary_error(self):
        for phase in (
            "prepared",
            "directories-ready",
            "maintenance-lock-held",
            "files-installed",
            "daemon-reload-pending",
            "daemon-reloaded",
            "loaded-verification-pending",
            "loaded-verified",
            "receipt-written",
        ):
            with self.subTest(phase=phase):
                message, phases, restore = self._apply_failure(hook_phase=phase)
                self.assertIn(f"primary-{phase}", message)
                restore.assert_called_once()
                if phase in phases:
                    self.assertLessEqual(phases.index(phase), len(phases) - 1)

    def test_rollback_cleanup_failure_never_masks_primary_failure(self):
        message, _, restore = self._apply_failure(
            hook_phase="daemon-reloaded", rollback_fails=True
        )
        restore.assert_called_once()
        self.assertIn("primary-daemon-reloaded", message)
        self.assertIn("rollback-cleanup-failed", message)
        self.assertLess(message.index("primary-daemon-reloaded"), message.index("rollback-cleanup-failed"))

    def test_prepare_failure_closure_error_reports_both_failures(self):
        assessment = {
            "postgresIdentity": {"uid": 1234, "gid": 1235},
            "systemd": {"units": {}, "alertInstances": [], "jobs": []},
        }
        plan = {"assessment": assessment}
        patches = (
            mock.patch.object(installer, "_require_root"),
            mock.patch.object(installer, "_assert_fixed_plan_argument"),
            mock.patch.object(installer, "InstallerLock", NoopLock),
            mock.patch.object(installer, "_require_no_installer_transaction"),
            mock.patch.object(installer, "_load_root_json", return_value=(plan, b"plan\n")),
            mock.patch.object(installer, "_validate_plan", return_value=assessment),
            mock.patch.object(installer, "_identity", return_value=installer.Identity(1234, 1235)),
            mock.patch.object(installer, "build_assessment", return_value=assessment),
            mock.patch.object(installer, "_asset_payloads", return_value={}),
            mock.patch.object(installer, "_prepare_transaction", side_effect=RuntimeError("preimage-primary")),
            mock.patch.object(installer, "_close_preparation_failure", side_effect=RuntimeError("closure-secondary")),
            mock.patch.object(installer.os.path, "lexists", return_value=False),
        )
        for patcher in patches:
            patcher.start()
        try:
            with self.assertRaises(installer.InstallerError) as raised:
                installer.apply_plan(
                    plan_path=installer.PLAN_PATH,
                    expected_plan_sha256="d" * 64,
                    confirmation=installer.APPLY_CONFIRMATION,
                    assets=(),
                    runner=mock.Mock(),
                )
        finally:
            for patcher in reversed(patches):
                patcher.stop()
        message = str(raised.exception)
        self.assertIn("preimage-primary", message)
        self.assertIn("closure-secondary", message)


@unittest.skipUnless(
    os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
    "requires disposable POSIX root filesystem",
)
class PosixAtomicFilesystemContractTest(unittest.TestCase):
    def test_atomic_publish_is_single_link_root_only_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            parent.chmod(0o700)
            target = parent / "evidence.json"
            installer._atomic_write(
                target, b"one\n", uid=0, gid=0, mode=0o600, replace=False
            )
            details = target.lstat()
            self.assertEqual(1, details.st_nlink)
            self.assertEqual(0o600, stat.S_IMODE(details.st_mode))
            self.assertEqual(b"one\n", target.read_bytes())
            with self.assertRaisesRegex(installer.InstallerError, "overwrite evidence"):
                installer._atomic_write(
                    target, b"two\n", uid=0, gid=0, mode=0o600, replace=False
                )

    def test_symlink_managed_target_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real = root / "real"
            link = root / "link"
            real.write_bytes(b"x")
            link.symlink_to(real)
            with self.assertRaises(installer.InstallerError):
                installer._file_observation(link, allow_missing=False)


if __name__ == "__main__":
    unittest.main()
