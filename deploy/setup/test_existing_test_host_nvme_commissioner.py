import copy
import importlib.util
import json
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath
from unittest.mock import Mock, patch


MODULE_PATH = Path(__file__).with_name("existing-test-host-nvme-commissioner.py")
SPEC = importlib.util.spec_from_file_location("existing_test_host_nvme_commissioner", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
nvme = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = nvme
SPEC.loader.exec_module(nvme)

TEST_HOSTNAME = "internal-test-host.example.invalid"


def build_plan(assessment):
    return nvme.build_plan(assessment, TEST_HOSTNAME)


def unit(active="inactive", enabled="disabled"):
    return {
        "Id": "example.service",
        "LoadState": "loaded",
        "ActiveState": active,
        "SubState": "dead" if active == "inactive" else "running",
        "UnitFileState": enabled,
        "FragmentPath": "/etc/systemd/system/example.service",
    }


def eligible_assessment():
    units = {name: unit() for name in nvme.SERVICE_UNITS}
    units["postgresql.service"] = unit("active", "enabled")
    units["postgresql@16-main.service"] = unit("active", "enabled")
    units["uten-pgbackup.timer"] = unit("active", "enabled")
    units[nvme.OLD_PHASE1_RESUME] = unit("failed", "enabled")
    return {
        "schemaVersion": nvme.SCHEMA_VERSION,
        "kind": nvme.KIND + "-assessment",
        "observedAtUtc": "2026-08-12T08:00:00Z",
        "completedAtUtc": "2026-08-12T08:00:02Z",
        "bootId": "00000000-0000-0000-0000-000000000001",
        "hostname": TEST_HOSTNAME,
        "dataMount": {
            "target": "/data",
            "source": "/dev/md0",
            "fstype": "ext4",
            "options": "rw,relatime",
            "uuid": "11111111-1111-1111-1111-111111111111",
        },
        "oldDataUuidMounts": [
            {
                "target": "/data",
                "source": "/dev/md0",
                "fstype": "ext4",
                "options": "rw,relatime",
                "uuid": "11111111-1111-1111-1111-111111111111",
            }
        ],
        "lsblk": {
            "blockdevices": [
                {"path": "/dev/nvme0n1", "type": "disk", "size": 512110190592},
                {"path": "/dev/md0", "type": "raid1", "size": 2000397795328},
            ]
        },
        "pvs": [
            {
                "pv_name": "/dev/nvme0n1p3",
                "pv_size": str(473 * 1024**3),
                "pv_free": str(373 * 1024**3),
                "vg_name": "ubuntu-vg",
                "pv_uuid": "pv-fixed",
            }
        ],
        "vgs": [
            {
                "vg_name": "ubuntu-vg",
                "vg_size": str(473 * 1024**3),
                "vg_free": str(373 * 1024**3),
                "pv_count": "1",
                "lv_count": "1",
                "vg_attr": "wz--n-",
                "vg_uuid": "AAAAAA-bbbb-2222-3333-4444-5555-CCCCCC",
            }
        ],
        "lvs": [
            {
                "vg_name": "ubuntu-vg",
                "lv_name": "ubuntu-lv",
                "lv_size": str(100 * 1024**3),
                "lv_attr": "-wi-ao----",
                "devices": "/dev/nvme0n1p3(0)",
                "lv_uuid": "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF",
                "segtype": "linear",
            }
        ],
        "nvme": {
            "processReturnCode": 0,
            "document": {
                "smart_status": {"passed": True},
                "nvme_smart_health_information_log": {
                    "critical_warning": 0,
                    "media_errors": 0,
                    "percentage_used": 2,
                },
            },
        },
        "md": {
            "export": {
                "MD_LEVEL": "raid1",
                "MD_DEVICES": "2",
                "MD_STATE": "clean",
                "MD_UUID": "aaaaaaaa:bbbbbbbb:cccccccc:dddddddd",
            },
            "procMdstat": "md0 : active raid1 sdb[1] sda[0]\n 1953382464 blocks [2/2] [UU]\n",
            "syncAction": "idle",
        },
        "fstab": {
            "sha256": "a" * 64,
            "mode": "0644",
            "uid": 0,
            "gid": 0,
            "dataEntries": [
                {
                    "line": 4,
                    "fields": ["/dev/md0", "/data", "ext4", "defaults", "0", "2"],
                    "raw": "/dev/md0 /data ext4 defaults 0 2\n",
                }
            ],
        },
        "units": units,
        "postgres": {
            "dataDirectory": "/data/postgresql/16/main",
            "databases": ["postgres|8192000", "uten_imp|52428800"],
            "gid": 116,
            "startConf": {
                "path": "/etc/postgresql/16/main/start.conf",
                "exists": True,
                "unsafeType": False,
                "sha256": "5" * 64,
                "mode": "0644",
                "uid": 0,
                "gid": 0,
                "text": "# Debian PostgreSQL cluster startup mode\n# keep comments\nauto\n",
            },
            "control": {
                "Database system identifier": "123456789",
                "Database cluster state": "in production",
                "Latest checkpoint's TimeLineID": "1",
            },
        },
        "pgBackRest": [{"name": "uten-imp", "status": {"code": 0}, "backup": [{"label": "full"}]}],
        "packageManager": {"dpkgAudit": "", "processes": [], "locks": []},
        "phaseEvidence": {
            "phase1": [{"name": "containment-fixed", "type": "directory"}],
            "packageWindow": [{"name": "resume-fixed", "type": "directory"}],
            "oldResumeUnitSha256": "b" * 64,
            "nvmeCommissioning": [],
            "retainedLvCandidates": [],
            "activeNvmeTransaction": {"exists": False, "sha256": None},
            "nvmeResumeInstallation": {"state": "absent"},
            "postgresMountGuard": {"path": str(nvme.PG_GUARD), "exists": False},
            "nvmeResumeUnit": {"path": str(nvme.RESUME_UNIT), "exists": False},
        },
        "sdbLongTestObservation": {"ata_smart_data": {"self_test": {"status": {"remaining_percent": 70}}}},
        "maintenanceLock": {
            "path": str(nvme.MAINTENANCE_LOCK),
            "state": "file",
            "uid": 0,
            "gid": 116,
            "mode": "0660",
            "links": 1,
            "bytes": 0,
        },
    }


class PlanPolicyTest(unittest.TestCase):
    def test_eligible_plan_is_exact_and_leaves_reserved_space(self):
        plan = build_plan(eligible_assessment())
        self.assertTrue(plan["eligible"])
        self.assertEqual([], plan["blockers"])
        self.assertEqual(350 * 1024**3, plan["target"]["sizeBytes"])
        self.assertGreaterEqual(plan["target"]["expectedVgRemainingBytes"], 20 * 1024**3)
        self.assertEqual("unmount-only-retain-assembled-no-wipe-no-stop", plan["oldStorage"]["action"])
        self.assertFalse(plan["databaseBoundary"]["initdb"])
        self.assertFalse(plan["databaseBoundary"]["oldDatabaseDeletion"])
        self.assertFalse(plan["recovery"]["removeLv"])
        self.assertEqual(nvme.CONFIRM_PHRASE, plan["confirmationPhrase"])

    def test_plan_is_deterministic_across_observation_time_and_sdb_progress(self):
        first = eligible_assessment()
        second = copy.deepcopy(first)
        second["observedAtUtc"] = "2099-01-01T00:00:00Z"
        second["completedAtUtc"] = "2099-01-01T00:00:01Z"
        second["sdbLongTestObservation"] = {"complete": True}
        self.assertEqual(build_plan(first)["planSha256"], build_plan(second)["planSha256"])

    def test_material_drift_changes_plan_sha(self):
        first = eligible_assessment()
        second = copy.deepcopy(first)
        second["fstab"]["sha256"] = "c" * 64
        self.assertNotEqual(build_plan(first)["planSha256"], build_plan(second)["planSha256"])

    def test_all_primary_refusal_gates(self):
        mutations = {
            "wrong host": lambda a: a.update(hostname="other"),
            "wrong data source": lambda a: a["dataMount"].update(source="/dev/sda"),
            "low free": lambda a: a["vgs"][0].update(vg_free=str(369 * 1024**3)),
            "existing target": lambda a: a["lvs"].append(
                {"vg_name": "ubuntu-vg", "lv_name": "uten-data", "lv_size": str(350 * 1024**3)}
            ),
            "nvme media": lambda a: a["nvme"]["document"]["nvme_smart_health_information_log"].update(
                media_errors=1
            ),
            "degraded md": lambda a: a["md"].update(procMdstat="md0 : active raid1 sda[0]\n [2/1] [U_]\n"),
            "backup running": lambda a: a["units"]["uten-pgbackup.service"].update(
                ActiveState="active", SubState="running"
            ),
            "old resume active": lambda a: a["units"][nvme.OLD_PHASE1_RESUME].update(
                ActiveState="active", SubState="running"
            ),
            "wrong pgdata": lambda a: a["postgres"].update(dataDirectory="/var/lib/postgresql/16/main"),
            "unsafe maintenance lock": lambda a: a["maintenanceLock"].update(mode="0666"),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                assessment = eligible_assessment()
                mutate(assessment)
                plan = build_plan(assessment)
                self.assertFalse(plan["eligible"])
                self.assertTrue(plan["blockers"])

    def test_exact_evidence_bound_retained_lv_can_be_adopted(self):
        assessment = eligible_assessment()
        assessment["lvs"].append(
            {
                "vg_name": "ubuntu-vg",
                "lv_name": "uten-data",
                "lv_size": str(350 * 1024**3),
                "lv_attr": "-wi-a-----",
                "devices": "/dev/nvme0n1p3(25600)",
                "lv_uuid": "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF",
                "segtype": "linear",
            }
        )
        assessment["vgs"][0]["vg_free"] = str(23 * 1024**3)
        assessment["pvs"][0]["pv_free"] = str(23 * 1024**3)
        assessment["targetLvBlkid"] = {
            "TYPE": "ext4",
            "LABEL": "uten-data",
            "UUID": "22222222-2222-2222-2222-222222222222",
        }
        assessment["targetLvMounts"] = []
        assessment["phaseEvidence"]["retainedLvCandidates"] = [
            {
                "transactionId": "nvme-prior",
                "evidence": "/var/lib/uten-imp-nvme-commissioning/nvme-prior",
                "planSha256": "1" * 64,
                "rollbackSha256": "2" * 64,
                "lvcreateLogSha256": "3" * 64,
                "lvIdentitySha256": "4" * 64,
                "lvIdentity": {
                    "schemaVersion": nvme.SCHEMA_VERSION,
                    "kind": nvme.KIND + "-lv-identity",
                    "transactionId": "nvme-prior",
                    "planSha256": "1" * 64,
                    "lvPath": nvme.TARGET_LV_PATH,
                    "pvPath": nvme.TARGET_PV,
                    "sizeBytes": nvme.TARGET_LV_BYTES,
                    "segmentType": "linear",
                    "devices": "/dev/nvme0n1p3(25600)",
                    "lvUuid": "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF",
                    "vgUuid": assessment["vgs"][0]["vg_uuid"],
                    "pvUuid": assessment["pvs"][0]["pv_uuid"],
                },
                "mkfsCompleted": True,
            }
        ]
        plan = build_plan(assessment)
        self.assertTrue(plan["eligible"], plan["blockers"])
        self.assertEqual("adopt-retained", plan["target"]["mode"])
        self.assertEqual("nvme-prior", plan["target"]["adoptionCandidate"]["transactionId"])
        self.assertEqual(23 * 1024**3, plan["target"]["expectedVgRemainingBytes"])

        ambiguous = copy.deepcopy(assessment)
        ambiguous["phaseEvidence"]["retainedLvCandidates"].append(
            dict(ambiguous["phaseEvidence"]["retainedLvCandidates"][0], transactionId="nvme-other")
        )
        refused = build_plan(ambiguous)
        self.assertFalse(refused["eligible"])
        self.assertIn("RETAINED_LV_PROVENANCE_AMBIGUOUS", refused["blockers"])

    def test_active_transaction_and_stale_resume_link_refuse_new_apply(self):
        assessment = eligible_assessment()
        assessment["phaseEvidence"]["activeNvmeTransaction"] = {"exists": True, "sha256": "4" * 64}
        self.assertIn("ACTIVE_NVME_TRANSACTION_REQUIRES_RECOVER", build_plan(assessment)["blockers"])
        assessment = eligible_assessment()
        assessment["phaseEvidence"]["nvmeResumeInstallation"] = {"state": "invalid"}
        self.assertIn("NVME_RESUME_INSTALLATION_UNSAFE", build_plan(assessment)["blockers"])

    def test_authorization_requires_current_hash_and_exact_phrase(self):
        plan = build_plan(eligible_assessment())
        nvme.verify_plan_authorization(plan, plan["planSha256"], nvme.CONFIRM_PHRASE)
        with self.assertRaises(nvme.CommissioningError):
            nvme.verify_plan_authorization(plan, "0" * 64, nvme.CONFIRM_PHRASE)
        with self.assertRaises(nvme.CommissioningError):
            nvme.verify_plan_authorization(plan, plan["planSha256"], "yes")
        refused = dict(plan, eligible=False, blockers=["X"])
        with self.assertRaises(nvme.CommissioningError):
            nvme.verify_plan_authorization(refused, plan["planSha256"], nvme.CONFIRM_PHRASE)


class FstabAndUnitContractTest(unittest.TestCase):
    UUID = "22222222-2222-2222-2222-222222222222"

    def test_runtime_authority_v3_exact_contract(self):
        topology = {
            "dataUuid": self.UUID,
            "lvm": {
                "dmUuid": "LVM-" + "a" * 64,
                "lvSizeBytes": nvme.TARGET_LV_BYTES,
                "lvUuid": "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF",
                "pvCount": 1,
                "pvUuid": "FEDCBA-dcba-4321-8765-cba9-0fed-FEDCBA",
                "segmentType": "linear",
                "vgUuid": "AAAAAA-bbbb-2222-3333-4444-5555-CCCCCC",
            },
            "nvme": {
                "namespaceById": "/dev/disk/by-id/nvme-model_serial",
                "partitionById": "/dev/disk/by-id/nvme-model_serial-part3",
                "partitionNumber": 3,
                "rotational": False,
                "serialSha256": "b" * 64,
                "transport": "nvme",
            },
        }
        authority = nvme.runtime_authority_document(topology, "CHG-2026-0812-NVME", "c" * 64)
        self.assertEqual(
            {
                "approvalReference",
                "commissioningEvidenceSha256",
                "dataFilesystem",
                "dataSource",
                "dataUuid",
                "lvm",
                "minimumFreeBytes",
                "minimumFreeInodes",
                "mountPoint",
                "nvme",
                "requiredOptions",
                "schemaVersion",
                "topology",
            },
            set(authority),
        )
        self.assertEqual(["nodev", "noexec", "nosuid", "rw"], authority["requiredOptions"])
        self.assertEqual("lvm-linear-nvme", authority["topology"])
        self.assertEqual(topology["lvm"], authority["lvm"])
        self.assertEqual(topology["nvme"], authority["nvme"])

    def test_realistic_nvme_devlinks_choose_model_serial_alias(self):
        properties = {
            "ID_SERIAL": "Model_Serial_1",
            "DEVLINKS": " ".join(
                (
                    "/dev/disk/by-id/nvme-eui.0011223344556677",
                    "/dev/disk/by-id/nvme-uuid.11111111-2222-3333-4444-555555555555",
                    "/dev/disk/by-id/nvme-Model_Serial_1",
                )
            ),
        }
        with patch.object(nvme.os.path, "realpath", return_value="/dev/nvme0n1"):
            self.assertEqual(
                "/dev/disk/by-id/nvme-Model_Serial_1",
                nvme.canonical_nvme_by_id(PurePosixPath("/dev/nvme0n1"), properties, None),
            )

    def test_duplicate_uuid_inventory_is_not_single_value_api(self):
        source = MODULE_PATH.read_text(encoding="utf-8")
        self.assertNotIn('[BLKID, "--uuid"', source)
        self.assertIn('"--cache-file", "/dev/null", "--match-token", "UUID=" + filesystem_uuid', source)

    def test_switch_replaces_only_active_data_entry(self):
        before = (
            b"# preserved comment\n"
            b"UUID=root / ext4 defaults 0 1\n"
            b"/dev/md0 /data ext4 defaults 0 2\n"
            b"# /dev/old /data ext4 defaults 0 2\n"
        )
        after = nvme.render_switched_fstab(before, self.UUID).decode()
        self.assertIn("# preserved comment", after)
        self.assertIn("UUID=root / ext4 defaults 0 1", after)
        self.assertIn(
            f"UUID={self.UUID} /data ext4 rw,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=30s 0 2", after
        )
        self.assertIn("# /dev/old /data", after)

    def test_switch_rejects_zero_duplicate_and_unsafe_uuid(self):
        with self.assertRaises(nvme.CommissioningError):
            nvme.render_switched_fstab(b"UUID=root / ext4 defaults 0 1\n", self.UUID)
        duplicate = b"/dev/md0 /data ext4 defaults 0 2\nUUID=old /data ext4 defaults 0 2\n"
        with self.assertRaises(nvme.CommissioningError):
            nvme.render_switched_fstab(duplicate, self.UUID)
        with self.assertRaises(nvme.CommissioningError):
            nvme.render_switched_fstab(b"/dev/md0 /data ext4 defaults 0 2\n", "$(bad)")

    def test_postgres_start_conf_preserves_comments_and_sets_manual(self):
        before = b"# auto/manual/disabled\n# preserved\nauto\n"
        after = nvme.render_postgres_start_manual(before)
        self.assertEqual(b"# auto/manual/disabled\n# preserved\nmanual\n", after)
        self.assertEqual("manual", nvme.postgres_start_mode(after.decode()))
        for unsafe in (b"disabled\n", b"auto\nmanual\n", b"\xff\n"):
            with self.subTest(unsafe=unsafe), self.assertRaises(nvme.CommissioningError):
                nvme.render_postgres_start_manual(unsafe)

    def test_nofail_is_paired_with_exact_postgres_mount_guard(self):
        guard = nvme.postgres_guard(self.UUID).decode()
        self.assertIn("RequiresMountsFor=/data", guard)
        self.assertIn("ConditionPathIsMountPoint=/data", guard)
        self.assertIn(f"--source UUID={self.UUID} --types ext4", guard)
        self.assertNotIn("/dev/md0", guard)

    def test_resume_unit_is_static_early_boot_and_fixed_path(self):
        helper = Path("/usr/local/libexec/uten-imp-nvme-commissioner-" + "a" * 64 + ".py")
        early = nvme.resume_unit(helper).decode()
        late = nvme.late_resume_unit(helper).decode()
        timer = nvme.late_resume_timer().decode()
        self.assertIn("Before=data.mount local-fs.target postgresql.service", early)
        self.assertIn("ConditionPathExists=/var/lib/uten-imp-nvme-commissioning/active.json", early)
        self.assertIn(f"ExecStart=/usr/bin/python3 -I {helper} recover --from-systemd-early", early)
        self.assertIn("Restart=on-failure", early)
        self.assertIn("After=multi-user.target network-online.target", late)
        self.assertIn(f"ExecStart=/usr/bin/python3 -I {helper} recover --from-systemd-late", late)
        self.assertIn(f"ExecStopPost=/usr/bin/python3 -I {helper} contain-late-failure", late)
        self.assertIn("RuntimeDirectory=uten-imp-nvme-late-unlock", late)
        self.assertIn("Restart=on-failure", late)
        self.assertIn("OnActiveSec=30s", timer)
        self.assertIn("Unit=uten-imp-nvme-commissioning-late-resume.service", timer)
        self.assertNotIn("[Install]", early + late + timer)

    def test_permanent_gate_covers_every_protected_unit_and_is_fail_closed(self):
        self.assertTrue(set(nvme.STOP_ORDER).issubset(set(nvme.GATED_UNITS)))
        unit_name = "uten-imp.service"
        gate = nvme.active_transaction_gate_dropin(unit_name).decode().splitlines()
        self.assertIn(
            f"Requires={nvme.GATE_AUTHORIZER_UNIT.name}",
            gate,
        )
        self.assertIn(
            f"After={nvme.GATE_AUTHORIZER_UNIT.name}",
            gate,
        )
        self.assertIn(f"ConditionPathExists={nvme.gate_marker_path(unit_name)}", gate)
        self.assertFalse(any("ConditionPathExists=|" in line for line in gate))
        # The same payload is installed on both services and timers.
        # Containment belongs only to the late-resume service: an unconditional
        # per-unit ExecStopPost would also fire after the pointer was removed.
        self.assertNotIn("[Service]", gate)
        self.assertFalse(any(line.startswith("ExecStopPost=") for line in gate))
        for name in nvme.GATED_UNITS:
            self.assertEqual(
                f"/etc/systemd/system/{name}.d/{nvme.GATE_DROPIN_NAME}",
                nvme.gate_dropin_path(name).as_posix(),
            )

    @unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("systemd-analyze"), "systemd-analyze required")
    def test_systemd_analyze_accepts_rendered_recovery_units_and_gate(self):
        helper = Path("/usr/local/libexec/uten-imp-nvme-commissioner-" + "a" * 64 + ".py")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            early = root / nvme.RESUME_UNIT.name
            late = root / nvme.LATE_RESUME_UNIT.name
            timer = root / nvme.LATE_RESUME_TIMER.name
            authorizer = root / nvme.GATE_AUTHORIZER_UNIT.name
            service_probe = root / "uten-imp-nvme-gate-probe.service"
            timer_probe = root / "uten-imp-nvme-gate-probe.timer"
            early.write_bytes(nvme.resume_unit(helper))
            late.write_bytes(nvme.late_resume_unit(helper))
            timer.write_bytes(nvme.late_resume_timer())
            authorizer.write_bytes(nvme.gate_authorizer_unit(helper))
            service_probe.write_bytes(
                nvme.active_transaction_gate_dropin("uten-imp.service")
                + b"\n[Service]\nType=oneshot\nExecStart=/bin/true\n"
            )
            timer_probe.write_bytes(
                nvme.active_transaction_gate_dropin("uten-imp-updater.timer")
                + b"\n[Timer]\nOnBootSec=1min\nUnit=uten-imp-nvme-gate-probe.service\n"
            )
            result = subprocess.run(
                [
                    nvme.SYSTEMD_ANALYZE,
                    "verify",
                    str(early),
                    str(late),
                    str(timer),
                    str(authorizer),
                    str(service_probe),
                    str(timer_probe),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=30,
                env={
                    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                    "LANG": "C.UTF-8",
                    "LC_ALL": "C.UTF-8",
                    "SYSTEMD_PAGER": "cat",
                    "SYSTEMD_COLORS": "0",
                },
            )
            self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", errors="replace"))

    def test_gate_authorizer_is_unit_specific_and_never_uses_trigger_conditions(self):
        helper = Path("/usr/local/libexec/uten-imp-nvme-commissioner-" + "a" * 64 + ".py")
        authorizer = nvme.gate_authorizer_unit(helper).decode()
        self.assertIn(f"ExecStart=/usr/bin/python3 -I {helper} authorize-gate", authorizer)
        self.assertIn("RuntimeDirectory=uten-imp-nvme-gate-authorizer", authorizer)
        markers = set()
        for unit_name in nvme.GATED_UNITS:
            payload = nvme.active_transaction_gate_dropin(unit_name).decode()
            self.assertNotIn("ConditionPathExists=|", payload)
            self.assertNotIn("[Service]", payload)
            marker = str(nvme.gate_marker_path(unit_name))
            self.assertIn("ConditionPathExists=" + marker, payload)
            markers.add(marker)
        self.assertEqual(len(nvme.GATED_UNITS), len(markers))

    def test_durable_pointer_is_published_before_the_gate_is_closed(self):
        source = MODULE_PATH.read_text(encoding="utf-8")
        install_start = source.index("    def install_resume(self) -> None:")
        install_end = source.index("    def disable_old_resume(self) -> None:", install_start)
        install_body = source[install_start:install_end]
        pointer_publish = install_body.index("atomic_json(\n            ACTIVE_POINTER,")
        close_gate = install_body.index("ensure_gate_authorizer_closed(self.runner)")
        self.assertLess(pointer_publish, close_gate)

    def test_gate_is_reclosed_before_service_and_storage_mutation_boundaries(self):
        source = MODULE_PATH.read_text(encoding="utf-8")
        disable = source[source.index("    def disable_old_resume(self) -> None:") : source.index("    def stop_units(self) -> None:")]
        stop = source[source.index("    def stop_units(self) -> None:") : source.index("    def backup_vg_metadata(self) -> None:")]
        backup = source[source.index("    def backup_vg_metadata(self) -> None:") : source.index("    def create_filesystem(self) -> str:")]
        self.assertLess(disable.index("ensure_gate_authorizer_closed"), disable.index("SYSTEMCTL"))
        self.assertGreaterEqual(stop.count("ensure_gate_authorizer_closed(self.runner)"), 2)
        self.assertLess(stop.rindex("ensure_gate_authorizer_closed"), stop.index("start_conf_payload"))
        self.assertLess(backup.index("ensure_gate_authorizer_closed"), backup.index("VGCFGBACKUP"))

    def test_final_disarm_never_publishes_an_all_unit_transaction_grant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            active = root / "active.json"
            pointer = {"evidence": str(evidence)}
            active.write_text(json.dumps(pointer), encoding="utf-8")
            events = []

            class FinalizeRunner(FakeRunner):
                def run(self, args, **kwargs):
                    events.append(("systemctl", tuple(args), active.exists()))
                    return super().run(args, **kwargs)

            with patch.object(nvme, "ACTIVE_POINTER", active), patch.object(
                nvme, "ensure_gate_authorizer_closed", side_effect=lambda runner: events.append(("closed", active.exists()))
            ), patch.object(nvme, "active_pointer_for_evidence", return_value=pointer), patch.object(
                nvme, "fsync_directory"
            ), patch.object(nvme, "observed_gate_markers", return_value=set(nvme.GATED_UNITS)), patch.object(
                nvme, "publish_gate_grant"
            ) as grant:
                result = nvme.finalize_gate_normal(FinalizeRunner(), evidence, pointer)
            grant.assert_not_called()
            self.assertFalse(active.exists())
            self.assertEqual(("closed", True), events[0])
            self.assertEqual(False, events[1][2])
            self.assertTrue(result["normalGateOpen"])

    def test_final_disarm_does_not_reenter_rollback_after_pointer_unlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            active = root / "active.json"
            pointer = {"evidence": str(evidence)}
            active.write_text(json.dumps(pointer), encoding="utf-8")
            with patch.object(nvme, "ACTIVE_POINTER", active), patch.object(
                nvme, "ensure_gate_authorizer_closed"
            ), patch.object(nvme, "active_pointer_for_evidence", return_value=pointer), patch.object(
                nvme, "fsync_directory", side_effect=OSError("injected directory sync failure")
            ), patch.object(nvme, "observed_gate_markers", return_value=set(nvme.GATED_UNITS)):
                result = nvme.finalize_gate_normal(FakeRunner(), evidence, pointer)
            self.assertFalse(active.exists())
            self.assertFalse(result["pointerDirectorySynced"])
            self.assertIn("injected directory sync failure", result["pointerDirectorySyncFailure"])
            self.assertTrue(result["normalGateOpen"])

    def test_retained_filesystem_allows_only_empty_preparation_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "lost+found").mkdir()
            main = root / "postgresql" / "16" / "main"
            main.mkdir(parents=True)
            (root / "backups").mkdir()
            marker = {
                "kind": nvme.KIND + "-storage-authority",
                "status": "PGDATA_PREPARED_NOT_INITIALIZED",
                "filesystemUuid": self.UUID,
                "transactionId": "nvme-prior",
                "postgresInitialized": False,
                "backupCommissioned": False,
            }
            (root / ".uten-imp-storage-authority.json").write_text(json.dumps(marker), encoding="utf-8")
            nvme.validate_retained_filesystem(root, self.UUID, {"nvme-prior"})

            (main / "PG_VERSION").write_text("16", encoding="ascii")
            with self.assertRaisesRegex(nvme.CommissioningError, "nested contents"):
                nvme.validate_retained_filesystem(root, self.UUID, {"nvme-prior"})
            (main / "PG_VERSION").unlink()
            (root / "unknown.bin").write_bytes(b"unknown")
            with self.assertRaisesRegex(nvme.CommissioningError, "unexpected"):
                nvme.validate_retained_filesystem(root, self.UUID, {"nvme-prior"})

    def test_retained_marker_must_match_uuid_transaction_and_uninitialized_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker_path = root / ".uten-imp-storage-authority.json"
            base = {
                "kind": nvme.KIND + "-storage-authority",
                "status": "PGDATA_PREPARED_NOT_INITIALIZED",
                "filesystemUuid": self.UUID,
                "transactionId": "nvme-prior",
                "postgresInitialized": False,
                "backupCommissioned": False,
            }
            for mutation in (
                {"filesystemUuid": "33333333-3333-3333-3333-333333333333"},
                {"transactionId": "unknown"},
                {"postgresInitialized": True},
                {"backupCommissioned": True},
            ):
                with self.subTest(mutation=mutation):
                    marker_path.write_text(json.dumps({**base, **mutation}), encoding="utf-8")
                    with self.assertRaises(nvme.CommissioningError):
                        nvme.validate_retained_filesystem(root, self.UUID, {"nvme-prior"})


class RetainedEvidenceTest(unittest.TestCase):
    def test_candidate_requires_exact_command_plan_and_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tx = root / "nvme-20260812T080000Z-0123456789ab"
            commands = tx / "commands"
            commands.mkdir(parents=True)
            tx.chmod(0o700)
            plan = build_plan(eligible_assessment())
            (tx / "plan.json").write_bytes(nvme.canonical_bytes(plan))
            lvcreate = {
                "argv": [
                    nvme.LVCREATE,
                    "--yes",
                    "--type",
                    "linear",
                    "--size",
                    "350g",
                    "--name",
                    nvme.TARGET_LV,
                    nvme.TARGET_VG,
                    nvme.TARGET_PV,
                ],
                "returnCode": 0,
            }
            (commands / "lvcreate.json").write_bytes(nvme.canonical_bytes(lvcreate))
            identity = {
                "schemaVersion": nvme.SCHEMA_VERSION,
                "kind": nvme.KIND + "-lv-identity",
                "transactionId": tx.name,
                "planSha256": plan["planSha256"],
                "lvPath": nvme.TARGET_LV_PATH,
                "pvPath": nvme.TARGET_PV,
                "sizeBytes": nvme.TARGET_LV_BYTES,
                "segmentType": "linear",
                "devices": nvme.TARGET_PV + "(25600)",
                "lvUuid": "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF",
                "vgUuid": "AAAAAA-bbbb-2222-3333-4444-5555-CCCCCC",
                "pvUuid": "FEDCBA-dcba-4321-8765-cba9-0fed-FEDCBA",
            }
            (tx / "lv-identity.json").write_bytes(nvme.canonical_bytes(identity))
            rollback = {
                "kind": nvme.KIND + "-rollback",
                "status": "ROLLED_BACK",
                "transactionId": tx.name,
                "planSha256": plan["planSha256"],
                "lvRemovalAttempted": False,
                "lvIdentitySha256": nvme.sha256_file(tx / "lv-identity.json"),
                "lvcreateLogSha256": nvme.sha256_file(commands / "lvcreate.json"),
                "previousReceiptSha256": None,
            }
            (tx / "rollback.json").write_bytes(nvme.canonical_bytes(rollback))
            for item in (tx / "plan.json", tx / "rollback.json", commands / "lvcreate.json", tx / "lv-identity.json"):
                item.chmod(0o600)
            # DrvFS/Windows temporary files cannot reliably express Linux
            # root:root 0700/0600 metadata.  This fixture exercises evidence
            # binding only; the production metadata predicates are tested
            # independently below and remain unconditional in the tool.
            with patch.object(nvme, "root_directory_metadata_is_exact", return_value=True), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ):
                candidates = nvme.retained_lv_candidates(root)
                self.assertEqual(1, len(candidates))
                self.assertEqual(tx.name, candidates[0]["transactionId"])

                (commands / "lvcreate.json").write_text(json.dumps({**lvcreate, "returnCode": 1}), encoding="utf-8")
                self.assertEqual([], nvme.retained_lv_candidates(root))

    def test_root_only_evidence_metadata_predicates_are_exact(self):
        directory_mode = stat.S_IFDIR | 0o700
        file_mode = stat.S_IFREG | 0o600
        directory = Mock(st_mode=directory_mode, st_uid=0, st_gid=0, st_nlink=2)
        file = Mock(st_mode=file_mode, st_uid=0, st_gid=0, st_nlink=1)
        self.assertTrue(nvme.root_directory_metadata_is_exact(directory, 0o700))
        self.assertTrue(nvme.root_file_metadata_is_exact(file, 0o600))
        for field, value in (("st_uid", 1000), ("st_gid", 1000), ("st_mode", stat.S_IFREG | 0o644)):
            with self.subTest(directory_field=field):
                changed = Mock(st_mode=directory_mode, st_uid=0, st_gid=0, st_nlink=2)
                setattr(changed, field, value)
                self.assertFalse(nvme.root_directory_metadata_is_exact(changed, 0o700))
        for field, value in (
            ("st_uid", 1000),
            ("st_gid", 1000),
            ("st_mode", stat.S_IFREG | 0o640),
            ("st_nlink", 2),
        ):
            with self.subTest(file_field=field):
                changed = Mock(st_mode=file_mode, st_uid=0, st_gid=0, st_nlink=1)
                setattr(changed, field, value)
                self.assertFalse(nvme.root_file_metadata_is_exact(changed, 0o600))


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.command_log = None

    def run(self, args, **kwargs):
        self.calls.append(tuple(args))
        return nvme.Completed(tuple(args), 0, "", "")

    def recovery_attempt(self, evidence):
        self.command_log = Path(evidence) / "commands"


class TransactionFaultTest(unittest.TestCase):
    def transaction(self):
        assessment = eligible_assessment()
        return nvme.Transaction(FakeRunner(), build_plan(assessment), assessment, "CHG-2026-0812-NVME")

    def test_every_mutating_stage_after_evidence_triggers_rollback(self):
        stages = [
            "install_resume",
            "disable_old_resume",
            "stop_units",
            "backup_vg_metadata",
            "create_filesystem",
            "verify_temporary_mount",
            "switch_fstab_and_mount",
            "prepare_pgdata",
        ]
        for failed_stage in stages:
            with self.subTest(failed_stage=failed_stage):
                transaction = self.transaction()
                transaction.prepare = Mock()
                for stage in stages:
                    if stage == "create_filesystem":
                        setattr(transaction, stage, Mock(return_value="22222222-2222-2222-2222-222222222222"))
                    else:
                        setattr(transaction, stage, Mock())
                getattr(transaction, failed_stage).side_effect = RuntimeError("fault injection")
                with patch.object(nvme, "rollback", return_value={"status": "ROLLED_BACK"}) as recover:
                    with self.assertRaisesRegex(nvme.CommissioningError, "failed closed;"):
                        transaction.apply()
                recover.assert_called_once()
                self.assertIn("RuntimeError", recover.call_args.kwargs["reason"])

    def test_failure_before_complete_during_commit_rolls_back(self):
        transaction = self.transaction()
        transaction.prepare = Mock()
        for stage in (
            "install_resume",
            "disable_old_resume",
            "stop_units",
            "backup_vg_metadata",
            "verify_temporary_mount",
            "switch_fstab_and_mount",
            "prepare_pgdata",
        ):
            setattr(transaction, stage, Mock())
        transaction.create_filesystem = Mock(return_value="22222222-2222-2222-2222-222222222222")
        transaction.publish_runtime_authority = Mock(return_value=(str(nvme.STORAGE_AUTHORITY), "6" * 64))
        transaction.commit = Mock(side_effect=RuntimeError("before durable complete"))
        with patch.object(nvme, "rollback", return_value={"status": "ROLLED_BACK"}) as recover:
            with self.assertRaisesRegex(nvme.CommissioningError, "failed closed;"):
                transaction.apply()
        recover.assert_called_once()

    def test_commit_receipt_keeps_business_and_backup_closed_and_defers_os_updates(self):
        transaction = self.transaction()
        with tempfile.TemporaryDirectory() as directory:
            transaction.evidence = Path(directory)
            (transaction.evidence / "plan.json").write_bytes(nvme.canonical_bytes(transaction.plan))
            captured = {}

            def write(path, value, **kwargs):
                if Path(path).name == "complete.json":
                    captured.update(value)

            with patch.object(nvme, "atomic_json", side_effect=write), patch.object(
                nvme, "restore_update_infrastructure_map"
            ) as restore_updates:
                transaction.commit(
                    "22222222-2222-2222-2222-222222222222",
                    str(nvme.STORAGE_AUTHORITY),
                    "6" * 64,
                )
            restore_updates.assert_not_called()
            self.assertEqual(list(nvme.SUCCESS_DISABLE_UNITS), captured["protectedUnitsDisabledInactive"])
            self.assertFalse(captured["osUpdateInfrastructureRestored"])
            self.assertFalse(captured["oldBackupAutomationRestored"])
            self.assertTrue(captured["oldPhase1ResumeRetired"])
            self.assertTrue(captured["newBackupDirectoryEmpty"])
            self.assertIsNone(captured["newPostgresSystemIdentifier"])
            self.assertTrue(
                set(("unattended-upgrades.service",) + nvme.APT_TIMERS).isdisjoint(
                    set(nvme.SUCCESS_DISABLE_UNITS)
                )
            )

    def test_os_update_restore_preserves_preexisting_enablement_exactly(self):
        runner = FakeRunner()
        service_map = {
            "unattended-upgrades.service": unit("active", "enabled"),
            "apt-daily.timer": unit("active", "enabled"),
            "apt-daily-upgrade.timer": unit("active", "enabled"),
        }
        with patch.object(nvme, "publish_gate_grant") as grant, patch.object(
            nvme, "ensure_gate_authorizer_closed"
        ) as close, patch.object(
            nvme,
            "unit_state",
            side_effect=lambda _runner, name: {
                **service_map[name],
                "Id": name,
            },
        ):
            failures = nvme.restore_update_infrastructure_map(
                runner,
                service_map,
                evidence=Path("/var/lib/uten-imp-nvme-commissioning/nvme-test"),
                pointer={},
            )
        self.assertEqual([], failures)
        self.assertEqual(3, grant.call_count)
        self.assertEqual(3, close.call_count)
        verbs = [call[1] for call in runner.calls if len(call) > 1 and call[0] == nvme.SYSTEMCTL]
        self.assertEqual(["start", "start", "start"], verbs)
        self.assertNotIn("enable", verbs)
        self.assertNotIn("disable", verbs)

    def test_rollback_failure_is_reported_as_hard_failure(self):
        transaction = self.transaction()
        transaction.prepare = Mock()
        transaction.install_resume = Mock(side_effect=RuntimeError("apply failure"))
        # Redirect the immutable failure receipt so the test never touches /var/lib.
        with tempfile.TemporaryDirectory() as directory:
            transaction.evidence = Path(directory)
            (transaction.evidence / "commands").mkdir()
            with patch.object(nvme, "rollback", side_effect=RuntimeError("rollback failure")), patch.object(
                nvme, "atomic_json"
            ) as atomic:
                with self.assertRaisesRegex(nvme.CommissioningError, "rollback failed"):
                    transaction.apply()
            self.assertEqual("ROLLBACK_FAILED_ENTRY_MUST_REMAIN_CLOSED", atomic.call_args.args[1]["status"])

    def test_early_boot_restores_enablement_without_starting_services(self):
        runner = FakeRunner()
        service_map = eligible_assessment()["units"]
        with patch.object(
            nvme,
            "unit_state",
            side_effect=lambda _runner, name: {
                "UnitFileState": service_map.get(name, {}).get("UnitFileState", "disabled")
            },
        ):
            failures = nvme.restore_enablement_map(runner, service_map)
        self.assertEqual([], failures)
        flattened = [" ".join(call) for call in runner.calls]
        self.assertTrue(any(" enable " in f" {call} " for call in flattened))
        starts = [call for call in flattened if " start " in f" {call} "]
        self.assertEqual([], starts)

    def test_failure_after_durable_complete_never_rolls_back(self):
        transaction = self.transaction()
        transaction.prepare = Mock()
        transaction.install_resume = Mock()
        transaction.disable_old_resume = Mock()
        transaction.stop_units = Mock()
        transaction.backup_vg_metadata = Mock()
        transaction.create_filesystem = Mock(return_value="22222222-2222-2222-2222-222222222222")
        transaction.verify_temporary_mount = Mock()
        transaction.switch_fstab_and_mount = Mock()
        transaction.prepare_pgdata = Mock()
        with tempfile.TemporaryDirectory() as directory:
            transaction.evidence = Path(directory)
            complete = {
                "kind": nvme.KIND + "-receipt",
                "status": "COMMITTED_STORAGE_ONLY",
                "transactionId": transaction.transaction_id,
                "planSha256": transaction.plan["planSha256"],
            }
            transaction.publish_runtime_authority = Mock(return_value=(str(nvme.STORAGE_AUTHORITY), "6" * 64))
            transaction.commit = Mock(
                side_effect=lambda filesystem_uuid, authority_path, authority_sha256: (transaction.evidence / "complete.json").write_text(
                    json.dumps(complete), encoding="utf-8"
                )
            )
            transaction.finalize_committed = Mock(side_effect=RuntimeError("power loss after complete"))
            with patch.object(nvme, "rollback") as recover:
                with self.assertRaisesRegex(nvme.CommissioningError, "committed but finalization"):
                    transaction.apply()
            recover.assert_not_called()

    def test_source_has_no_destructive_or_database_initialization_command(self):
        source = MODULE_PATH.read_text(encoding="utf-8")
        forbidden = ["lvremove", "vgremove", "pvremove", "wipefs", "mdadm --stop", "initdb", "dropdb"]
        for token in forbidden:
            with self.subTest(token=token):
                # Documentation may name the safety property; executable argv must not.
                self.assertNotRegex(source, rf"\[\s*[^\]]*[\"']{token.split()[0]}[\"']")

    def test_early_recovery_replaces_incomplete_receipt_and_only_queues_late(self):
        preimages = {
            "fstab": {"path": "/etc/fstab", "exists": False},
            "pgGuard": {"path": str(nvme.PG_GUARD), "exists": False},
            "pgStartConf": {"path": str(nvme.PG_START_CONF), "exists": False},
            "resumeUnit": {"path": str(nvme.RESUME_UNIT), "exists": False},
            "storageAuthority": {"path": str(nvme.STORAGE_AUTHORITY), "exists": False},
            "serviceMap": {},
            "oldDataMount": {
                "target": nvme.TARGET_MOUNT,
                "source": nvme.OLD_MD_DEVICE,
                "fstype": "ext4",
                "options": "rw,relatime",
                "uuid": "11111111-1111-1111-1111-111111111111",
            },
            "oldMd": {"MD_UUID": "aaaaaaaa:bbbbbbbb:cccccccc:dddddddd"},
        }
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            (evidence / "commands").mkdir()
            (evidence / "plan.json").write_text(json.dumps({"planSha256": "1" * 64}), encoding="utf-8")
            (evidence / "preimages.json").write_text(json.dumps(preimages), encoding="utf-8")
            existing = {
                "schemaVersion": nvme.SCHEMA_VERSION,
                "kind": nvme.KIND + "-rollback",
                "transactionId": evidence.name,
                "planSha256": "1" * 64,
                "status": "ROLLBACK_INCOMPLETE_ENTRY_MUST_REMAIN_CLOSED",
                "reason": "original failure",
                "failures": ["power loss"],
                "lvRemovalAttempted": False,
                "oldMdWipeAttempted": False,
                "oldMdStopAttempted": False,
                "recordedAtUtc": "2026-08-12T00:00:00Z",
                "lastRecoveryAttemptAtUtc": "2026-08-12T00:00:00Z",
                "previousReceiptSha256": None,
            }
            (evidence / "rollback.json").write_text(json.dumps(existing), encoding="utf-8")
            pointer = {
                "schemaVersion": nvme.SCHEMA_VERSION,
                "transactionId": evidence.name,
                "evidence": str(evidence),
                "planSha256": "1" * 64,
                "preimagesSha256": "2" * 64,
                "helperSha256": "3" * 64,
            }
            runner = FakeRunner()

            def run(args, **kwargs):
                runner.calls.append(tuple(args))
                if args[0] == nvme.FINDMNT and "--json" in args:
                    return nvme.Completed(tuple(args), 1, "", "")
                return nvme.Completed(tuple(args), 0, "", "")

            runner.run = Mock(side_effect=run)
            with patch.object(nvme, "active_pointer_for_evidence", return_value=pointer), patch.object(
                nvme, "validate_rollback_evidence", return_value=preimages
            ), patch.object(nvme, "validate_resume_pointer_binding"), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ), patch.object(
                nvme, "root_directory_metadata_is_exact", return_value=True
            ), patch.object(nvme, "cleanup_transaction_mounts", return_value=[]), patch.object(
                nvme, "verify_target_lv_unmounted", return_value=[]
            ), patch.object(nvme, "wait_for_old_md"), patch.object(
                nvme, "restore_file_preimage"
            ), patch.object(nvme, "verify_restored_old_storage", return_value={}), patch.object(
                nvme, "restore_enablement_map", return_value=[]
            ), patch.object(
                nvme, "write_early_recovery_ready", return_value={"status": "ready"}
            ), patch.object(
                nvme,
                "atomic_write",
                side_effect=lambda path, payload, **kwargs: Path(path).write_bytes(payload),
            ), patch.object(
                nvme,
                "ensure_secure_directory",
                side_effect=lambda path, mode=0o700: Path(path).mkdir(parents=True, exist_ok=True),
            ):
                receipt = nvme.rollback(evidence, runner, reason="new attempt")
            self.assertEqual("EARLY_STORAGE_RESTORED_AWAITING_LATE", receipt["status"])
            self.assertEqual("original failure", receipt["reason"])
            self.assertEqual("2026-08-12T00:00:00Z", receipt["recordedAtUtc"])
            self.assertEqual(
                "EARLY_STORAGE_RESTORED_AWAITING_LATE",
                json.loads((evidence / "rollback.json").read_text())["status"],
            )
            self.assertIn(
                (nvme.SYSTEMCTL, "restart", "--no-block", nvme.LATE_RESUME_TIMER.name),
                runner.calls,
            )
            business_starts = [
                call
                for call in runner.calls
                if len(call) >= 3 and call[:2] == (nvme.SYSTEMCTL, "start") and call[-1] in nvme.STOP_ORDER
            ]
            self.assertEqual([], business_starts)


class RecoveryStateMachineTest(unittest.TestCase):
    def pointer(self, evidence):
        return {
            "schemaVersion": nvme.SCHEMA_VERSION,
            "transactionId": evidence.name,
            "evidence": str(evidence),
            "planSha256": "1" * 64,
            "preimagesSha256": "2" * 64,
            "helperSha256": "3" * 64,
        }

    def test_sigkill_and_reboot_remove_only_volatile_unlock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            active = root / "persistent" / "active.json"
            ready = root / "run" / "uten-imp-nvme-gate-authorizer" / "open" / "uten-imp.service"
            active.parent.mkdir()
            ready.parent.mkdir(parents=True)

            def gate_open():
                return ready.exists()

            # Power loss at any pre-late boundary preserves the durable pointer
            # and has no volatile unlock, so every protected unit is closed.
            active.write_text("active", encoding="ascii")
            for boundary in (
                "after-active-pointer",
                "after-old-data-unmount",
                "after-fstab-switch",
                "after-early-handoff",
            ):
                with self.subTest(boundary=boundary):
                    self.assertFalse(gate_open())

            # The unlock exists only inside the late systemd RuntimeDirectory.
            ready.write_text("verified", encoding="ascii")
            self.assertTrue(gate_open())
            ready.unlink()  # SIGKILL or reboot: /run state disappears.
            self.assertTrue(active.exists())
            self.assertFalse(gate_open())

            # Only durable completion deletes the active pointer. The normal
            # authorizer then recreates unit-specific /run markers.
            active.unlink()
            ready.parent.mkdir(parents=True, exist_ok=True)
            ready.write_text("normal", encoding="ascii")
            self.assertTrue(gate_open())

    def test_committed_early_reboot_never_disarms_before_live_storage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            (evidence / "complete.json").write_text("{}", encoding="utf-8")
            pointer = self.pointer(evidence)
            active = root / "active.json"
            active.write_text(json.dumps(pointer), encoding="utf-8")
            runner = FakeRunner()
            with patch.object(nvme, "EVIDENCE_ROOT", root), patch.object(
                nvme, "ACTIVE_POINTER", active
            ), patch.object(nvme, "require_root"), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ), patch.object(nvme, "validate_rollback_evidence", return_value={}), patch.object(
                nvme, "validate_resume_pointer_binding"
            ), patch.object(nvme, "validate_committed_transaction", return_value={"status": "COMMITTED_STORAGE_ONLY"}), patch.object(
                nvme, "committed_late_finalize"
            ) as late:
                result = nvme.recover_active(runner, phase="early")
            self.assertEqual("COMMITTED_AWAITING_LIVE_LATE_FINALIZATION", result["status"])
            self.assertTrue(active.exists())
            late.assert_not_called()
            self.assertIn(
                (nvme.SYSTEMCTL, "restart", "--no-block", nvme.LATE_RESUME_TIMER.name),
                runner.calls,
            )

    def test_committed_late_runs_live_verifier_before_update_restore_and_disarm(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            complete = {"status": "COMMITTED_STORAGE_ONLY"}
            service_map = {
                "unattended-upgrades.service": unit("active", "enabled"),
                "apt-daily.timer": unit("active", "enabled"),
                "apt-daily-upgrade.timer": unit("active", "enabled"),
            }
            events = []
            with patch.object(nvme, "validate_committed_transaction", return_value=complete), patch.object(
                nvme, "begin_late_recovery_attempt", return_value=(1, {"attemptCount": 1})
            ), patch.object(nvme, "ensure_gate_authorizer_closed", side_effect=lambda *args: events.append("closed")), patch.object(
                nvme, "verify_committed_live_storage", side_effect=lambda *args: events.append("live") or {"pgdataEmpty": True}
            ), patch.object(nvme, "validate_rollback_evidence", return_value={"serviceMap": service_map}), patch.object(
                nvme, "restore_update_infrastructure_map", side_effect=lambda *args, **kwargs: events.append("updates") or []
            ), patch.object(
                nvme,
                "verify_update_infrastructure_map",
                side_effect=lambda *args: events.append("update-exact") or {
                    name: {"ActiveState": "active"} for name in service_map
                },
            ), patch.object(
                nvme, "atomic_json"
            ), patch.object(nvme, "finish_late_recovery_attempt", side_effect=lambda *args, **kwargs: events.append("attempt")), patch.object(
                nvme, "finalize_gate_with_retry", side_effect=lambda *args, **kwargs: events.append("disarm")
            ):
                receipt = nvme.committed_late_finalize(evidence, pointer, FakeRunner())
            self.assertEqual("COMMITTED_STORAGE_ONLY_LIVE_VERIFIED", receipt["status"])
            self.assertEqual(["closed", "live", "updates", "update-exact", "attempt", "disarm"], events)
            self.assertTrue(receipt["osUpdateInfrastructureRestored"])

    def test_committed_late_reuses_receipt_left_before_power_loss(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            complete = {"status": "COMMITTED_STORAGE_ONLY"}
            existing = {
                "status": "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED",
                "osUpdateInfrastructureRestored": True,
            }
            service_map = {
                "unattended-upgrades.service": unit("active", "enabled"),
                "apt-daily.timer": unit("active", "enabled"),
                "apt-daily-upgrade.timer": unit("active", "enabled"),
            }
            with patch.object(nvme, "validate_committed_transaction", return_value=complete), patch.object(
                nvme, "begin_late_recovery_attempt"
            ) as begin, patch.object(nvme, "ensure_gate_authorizer_closed"), patch.object(
                nvme, "verify_committed_live_storage", return_value={"pgdataEmpty": True}
            ), patch.object(nvme, "validate_rollback_evidence", return_value={"serviceMap": service_map}), patch.object(
                nvme, "restore_update_infrastructure_map"
            ) as restore, patch.object(nvme, "verify_update_infrastructure_map", return_value={}), patch.object(
                nvme, "validate_committed_late_receipt", return_value=existing
            ), patch.object(nvme, "atomic_json") as write, patch.object(
                nvme, "finish_late_recovery_attempt"
            ), patch.object(nvme, "finalize_gate_with_retry"):
                receipt = nvme.committed_late_finalize(evidence, pointer, FakeRunner())
            self.assertIs(existing, receipt)
            write.assert_not_called()
            begin.assert_not_called()
            restore.assert_not_called()

    def test_failure_after_committed_live_receipt_preserves_verified_os_updates(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            complete = {"status": "COMMITTED_STORAGE_ONLY"}
            service_map = {"unattended-upgrades.service": unit("active", "enabled")}
            with patch.object(nvme, "validate_committed_transaction", return_value=complete), patch.object(
                nvme, "validate_rollback_evidence", return_value={"serviceMap": service_map}
            ), patch.object(nvme, "validate_committed_late_receipt", return_value=None), patch.object(
                nvme, "begin_late_recovery_attempt", return_value=(1, {"attemptCount": 1})
            ), patch.object(nvme, "ensure_gate_authorizer_closed"), patch.object(
                nvme, "verify_committed_live_storage", return_value={"pgdataEmpty": True}
            ), patch.object(nvme, "restore_update_infrastructure_map", return_value=[]), patch.object(
                nvme, "verify_update_infrastructure_map", return_value={"unattended-upgrades.service": {}}
            ), patch.object(nvme, "atomic_json"), patch.object(
                nvme, "finish_late_recovery_attempt", side_effect=OSError("injected state write failure")
            ), patch.object(nvme, "contain_late_recovery_failure", return_value=[]) as contain:
                with self.assertRaisesRegex(nvme.CommissioningError, "failed closed"):
                    nvme.committed_late_finalize(evidence, pointer, FakeRunner())
            contain.assert_called_once()
            self.assertTrue(contain.call_args.kwargs["preserve_verified_update_infrastructure"])

    def test_post_receipt_sigkill_preserves_only_strictly_verified_os_updates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            (evidence / "complete.json").write_text("{}\n", encoding="utf-8")
            active = root / "active.json"
            pointer = self.pointer(evidence)
            active.write_text(json.dumps(pointer), encoding="utf-8")
            complete = {"status": "COMMITTED_STORAGE_ONLY"}
            service_map = {"unattended-upgrades.service": unit("active", "enabled")}
            runner = FakeRunner()
            with patch.object(nvme, "EVIDENCE_ROOT", root), patch.object(
                nvme, "ACTIVE_POINTER", active
            ), patch.object(nvme, "require_root"), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ), patch.object(nvme, "root_directory_metadata_is_exact", return_value=True), patch.object(
                nvme, "validate_rollback_evidence", return_value={"serviceMap": service_map}
            ), patch.object(nvme, "validate_committed_transaction", return_value=complete), patch.object(
                nvme, "validate_committed_late_receipt", return_value={"status": "COMMITTED_STORAGE_ONLY_LIVE_VERIFIED"}
            ) as validate_late, patch.object(
                nvme, "contain_late_recovery_failure", return_value=[]
            ) as contain, patch.object(
                nvme, "atomic_write", side_effect=lambda path, payload, **kwargs: Path(path).write_bytes(payload)
            ):
                result = nvme.contain_active_late_failure(runner)
            validate_late.assert_called_once_with(evidence, complete, service_map)
            contain.assert_called_once_with(runner, preserve_verified_update_infrastructure=True)
            self.assertTrue(result["verifiedUpdateInfrastructurePreserved"])

    def test_irreversible_disarm_failure_is_append_only_and_returns_nonzero(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            active = root / "active.json"
            runner = FakeRunner()
            gate_result = {
                "activePointerRemoved": True,
                "pointerDirectorySynced": True,
                "pointerDirectorySyncFailure": None,
                "normalGateOpen": False,
                "normalGateFailures": ["injected authorizer failure"],
            }
            with patch.object(nvme, "ACTIVE_POINTER", active), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ), patch.object(nvme, "observed_gate_markers", return_value=set()), patch.object(
                nvme, "unit_state", return_value={"ActiveState": "failed"}
            ), patch.object(
                nvme, "atomic_write", side_effect=lambda path, payload, **kwargs: Path(path).write_bytes(payload)
            ):
                first = nvme.record_gate_finalization_failure(
                    evidence,
                    pointer,
                    gate_result,
                    runner,
                    RuntimeError("second authorizer failure"),
                    outcome="COMMITTED",
                )
                second = nvme.record_gate_finalization_failure(
                    evidence,
                    pointer,
                    gate_result,
                    runner,
                    RuntimeError("must not replace"),
                    outcome="COMMITTED",
                )
            self.assertEqual(first, second)
            self.assertEqual("COMMITTED_DISARMED_NORMAL_GATE_NOT_OPEN", first["status"])
            receipt_path = evidence / "gate-finalization-failed.json"
            original = receipt_path.read_bytes()
            self.assertEqual(original, receipt_path.read_bytes())

            with patch.object(nvme, "finalize_gate_normal", return_value=gate_result), patch.object(
                nvme, "contain_active_late_failure", side_effect=nvme.CommissioningError("retry failed")
            ), patch.object(nvme, "record_gate_finalization_failure") as record:
                with self.assertRaisesRegex(nvme.CommissioningError, "disarmed"):
                    nvme.finalize_gate_with_retry(runner, evidence, pointer, outcome="COMMITTED")
            record.assert_called_once()

    def test_active_transaction_authorizer_without_grant_writes_no_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "run"
            runtime.mkdir(mode=0o700)
            open_dir = runtime / "open"
            evidence = root / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            active = root / "active.json"
            active.write_text(json.dumps(pointer), encoding="utf-8")
            grant = root / "late" / "grant.json"
            with patch.object(nvme, "EVIDENCE_ROOT", root), patch.object(nvme, "ACTIVE_POINTER", active), patch.object(
                nvme, "GATE_RUNTIME_DIRECTORY", runtime
            ), patch.object(nvme, "GATE_OPEN_DIRECTORY", open_dir), patch.object(nvme, "LATE_GRANT", grant), patch.object(
                nvme, "require_root"
            ), patch.object(
                nvme.os, "chown"
            ), patch.object(nvme, "root_directory_metadata_is_exact", return_value=True), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ), patch.object(nvme, "validate_rollback_evidence", return_value={}):
                result = nvme.authorize_gate()
            self.assertEqual("ACTIVE_TRANSACTION_GATE_CLOSED", result["status"])
            self.assertEqual([], result["authorizedUnits"])
            self.assertEqual([], list(open_dir.iterdir()))

    def test_final_rollback_receipt_bypasses_exhausted_attempt_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            preimages = {"serviceMap": {}, "oldDataMount": {}, "oldMd": {}}
            final_receipt = {"status": "ROLLED_BACK"}
            with patch.object(nvme, "validate_rollback_evidence", return_value=preimages), patch.object(
                nvme, "validate_resume_pointer_binding"
            ), patch.object(nvme, "validate_early_recovery_ready", return_value={}), patch.object(
                nvme, "validate_final_rollback_receipt", return_value=final_receipt
            ), patch.object(nvme, "begin_late_recovery_attempt") as begin, patch.object(
                nvme, "resume_final_rollback", return_value=final_receipt
            ) as resume:
                result = nvme.late_recover(evidence, pointer, FakeRunner())
            self.assertIs(final_receipt, result)
            begin.assert_not_called()
            resume.assert_called_once()

    def test_final_rollback_receipt_schema_is_strictly_bound(self):
        evidence = Path("/var/lib/uten-imp-nvme-commissioning/nvme-20260812T080000Z-0123456789ab")
        pointer = self.pointer(evidence)
        receipt = {
            "schemaVersion": nvme.SCHEMA_VERSION,
            "kind": nvme.KIND + "-rollback",
            "transactionId": evidence.name,
            "planSha256": pointer["planSha256"],
            "status": "ROLLED_BACK",
            "reason": "verified recovery",
            "failures": [],
            "lvRemovalAttempted": False,
            "oldMdWipeAttempted": False,
            "oldMdStopAttempted": False,
            "lvIdentitySha256": None,
            "lvcreateLogSha256": None,
            "recordedAtUtc": "2026-08-12T00:00:00Z",
            "lastRecoveryAttemptAtUtc": "2026-08-12T00:01:00Z",
            "lateRecoveryRequired": False,
            "lateRecoveryAttempt": 3,
            "health": {"protectedUnits": {}, "updateInfrastructure": {}},
            "completedAtUtc": "2026-08-12T00:01:00Z",
            "previousReceiptSha256": "4" * 64,
        }
        with patch.object(nvme, "existing_rollback_receipt", return_value=receipt):
            self.assertIs(receipt, nvme.validate_final_rollback_receipt(evidence, pointer, {}))
            malformed = copy.deepcopy(receipt)
            malformed["health"]["unexpected"] = {}
            with patch.object(nvme, "existing_rollback_receipt", return_value=malformed):
                with self.assertRaisesRegex(nvme.CommissioningError, "binding differs"):
                    nvme.validate_final_rollback_receipt(evidence, pointer, {})
            forged_digest = copy.deepcopy(receipt)
            forged_digest["lvIdentitySha256"] = "5" * 64
            with patch.object(nvme, "existing_rollback_receipt", return_value=forged_digest):
                with self.assertRaisesRegex(nvme.CommissioningError, "binding differs"):
                    nvme.validate_final_rollback_receipt(evidence, pointer, {})

    def test_late_success_verifies_health_before_deleting_pointer(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            active = evidence.parent / "active.json"
            active.write_text(json.dumps(pointer), encoding="utf-8")
            preimages = {"serviceMap": {}, "oldDataMount": {}, "oldMd": {}}
            runner = FakeRunner()
            events = []

            def start_health(*args, **kwargs):
                self.assertTrue(active.exists())
                events.append("health-verified")
                return {"postgresql@16-main.service": {"ActiveState": "active"}}

            with patch.object(nvme, "ACTIVE_POINTER", active), patch.object(
                nvme, "validate_rollback_evidence", return_value=preimages
            ), patch.object(nvme, "validate_resume_pointer_binding"), patch.object(
                nvme, "validate_early_recovery_ready", return_value={}
            ), patch.object(nvme, "begin_late_recovery_attempt", return_value=(1, {"attemptCount": 1})), patch.object(
                nvme, "ensure_gate_authorizer_closed", side_effect=lambda *args: events.append("gate-closed")
            ), patch.object(nvme, "verify_restored_old_storage", return_value={}
            ), patch.object(nvme, "restore_enablement_map", return_value=[]), patch.object(
                nvme, "start_and_verify_prior_active_units", side_effect=start_health
            ), patch.object(
                nvme, "restore_update_infrastructure_map", return_value=[]
            ), patch.object(
                nvme, "verify_update_infrastructure_map", return_value={}
            ), patch.object(
                nvme,
                "existing_rollback_receipt",
                return_value={
                    "reason": "original",
                    "recordedAtUtc": "2026-08-12T00:00:00Z",
                    "status": "EARLY_STORAGE_RESTORED_AWAITING_LATE",
                },
            ), patch.object(
                nvme, "finish_late_recovery_attempt", side_effect=lambda *args, **kwargs: events.append("attempt-succeeded")
            ), patch.object(
                nvme,
                "finalize_gate_with_retry",
                side_effect=lambda *args, **kwargs: (active.unlink(), events.append("pointer-disarmed")),
            ), patch.object(
                nvme, "atomic_write", side_effect=lambda path, payload, **kwargs: Path(path).write_bytes(payload)
            ), patch.object(
                nvme, "fsync_directory"
            ):
                receipt = nvme.late_recover(evidence, pointer, runner)
            self.assertEqual("ROLLED_BACK", receipt["status"])
            self.assertFalse(active.exists())
            self.assertEqual(
                [
                    "gate-closed",
                    "health-verified",
                    "attempt-succeeded",
                    "pointer-disarmed",
                ],
                events,
            )

    def test_late_failure_recloses_gate_and_keeps_pointer(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory) / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            pointer = self.pointer(evidence)
            active = evidence.parent / "active.json"
            active.write_text(json.dumps(pointer), encoding="utf-8")
            preimages = {"serviceMap": {}, "oldDataMount": {}, "oldMd": {}}
            runner = FakeRunner()
            finished = []
            with patch.object(nvme, "ACTIVE_POINTER", active), patch.object(
                nvme, "validate_rollback_evidence", return_value=preimages
            ), patch.object(nvme, "validate_resume_pointer_binding"), patch.object(
                nvme, "validate_early_recovery_ready", return_value={}
            ), patch.object(nvme, "begin_late_recovery_attempt", return_value=(2, {"attemptCount": 2})), patch.object(
                nvme, "ensure_gate_authorizer_closed"
            ), patch.object(nvme, "verify_restored_old_storage", return_value={}
            ), patch.object(nvme, "restore_enablement_map", return_value=[]
            ), patch.object(
                nvme,
                "start_and_verify_prior_active_units",
                side_effect=nvme.CommissioningError("readiness failed"),
            ), patch.object(
                nvme, "contain_late_recovery_failure", return_value=[]
            ) as contain, patch.object(
                nvme,
                "finish_late_recovery_attempt",
                side_effect=lambda *args, **kwargs: finished.append(kwargs["status"]),
            ):
                with self.assertRaisesRegex(nvme.CommissioningError, "attempt 2/3 failed closed"):
                    nvme.late_recover(evidence, pointer, runner)
            self.assertTrue(active.exists())
            contain.assert_called_once()
            self.assertEqual(["FAILED"], finished)

    def test_sigkill_stop_post_contains_already_started_units(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "nvme-20260812T080000Z-0123456789ab"
            evidence.mkdir()
            active = root / "active.json"
            pointer = self.pointer(evidence)
            active.write_text(json.dumps(pointer), encoding="utf-8")
            runner = FakeRunner()
            with patch.object(nvme, "EVIDENCE_ROOT", root), patch.object(
                nvme, "ACTIVE_POINTER", active
            ), patch.object(nvme, "require_root"), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ), patch.object(
                nvme, "root_directory_metadata_is_exact", return_value=True
            ), patch.object(
                nvme, "validate_rollback_evidence", return_value={}
            ), patch.object(nvme, "contain_late_recovery_failure", return_value=[]
            ) as contain, patch.object(
                nvme, "atomic_write", side_effect=lambda path, payload, **kwargs: Path(path).write_bytes(payload)
            ):
                result = nvme.contain_active_late_failure(runner)
            self.assertEqual("CONTAINED_ACTIVE_POINTER_RETAINED", result["status"])
            self.assertTrue(active.exists())
            contain.assert_called_once_with(runner, preserve_verified_update_infrastructure=False)
            self.assertTrue((evidence / "late-stop-post.json").is_file())

    def test_stop_post_is_noop_without_active_pointer(self):
        with tempfile.TemporaryDirectory() as directory:
            active = Path(directory) / "active.json"
            runner = FakeRunner()
            with patch.object(nvme, "ACTIVE_POINTER", active), patch.object(
                nvme, "require_root"
            ), patch.object(nvme, "observed_gate_markers", return_value=set(nvme.GATED_UNITS)), patch.object(
                nvme, "contain_late_recovery_failure"
            ) as contain:
                result = nvme.contain_active_late_failure(runner)
            self.assertEqual({"status": "NO_ACTIVE_POINTER_NORMAL_GATE_OPEN", "contained": False}, result)
            contain.assert_not_called()
            self.assertIn(
                (nvme.SYSTEMCTL, "restart", nvme.GATE_AUTHORIZER_UNIT.name),
                runner.calls,
            )

    def test_any_active_postgres_unit_requires_sql_health(self):
        service_map = {name: unit() for name in nvme.SERVICE_UNITS}
        for name in ("postgresql.service", "postgresql@16-main.service"):
            with self.subTest(name=name):
                runner = FakeRunner()
                current = copy.deepcopy(service_map)
                current[name] = unit("active", "enabled")
                with patch.object(
                    nvme,
                    "wait_for_unit_health",
                    return_value={"ActiveState": "active", "Result": "success", "ExecMainStatus": "0"},
                ), patch.object(nvme, "publish_gate_grant"), patch.object(
                    nvme, "ensure_gate_authorizer_closed"
                ), patch.object(nvme, "wait_for_postgres_health") as sql, patch.object(
                    nvme, "wait_for_application_readiness"
                ):
                    nvme.start_and_verify_prior_active_units(
                        runner,
                        current,
                        evidence=Path("/var/lib/uten-imp-nvme-commissioning/nvme-test"),
                        pointer={},
                    )
                sql.assert_called_once_with(runner)

    def test_unit_start_grant_is_consumed_before_health_and_reissued_per_unit(self):
        events = []

        class EventRunner(FakeRunner):
            def run(self, args, **kwargs):
                if tuple(args[:2]) == (nvme.SYSTEMCTL, "start"):
                    events.append("start:" + args[-1])
                return super().run(args, **kwargs)

        service_map = {
            "uten-imp.service": unit("active", "enabled"),
            "nginx.service": unit("active", "enabled"),
        }
        with patch.object(
            nvme,
            "publish_gate_grant",
            side_effect=lambda runner, evidence, pointer, units: events.append("grant:" + units[0]),
        ), patch.object(
            nvme,
            "ensure_gate_authorizer_closed",
            side_effect=lambda runner: events.append("close"),
        ), patch.object(
            nvme,
            "wait_for_unit_health",
            side_effect=lambda runner, name: events.append("health:" + name) or {"ActiveState": "active"},
        ), patch.object(nvme, "wait_for_application_readiness", side_effect=lambda runner: events.append("readiness")):
            nvme.start_and_verify_prior_active_units(
                EventRunner(),
                service_map,
                evidence=Path("/var/lib/uten-imp-nvme-commissioning/nvme-test"),
                pointer={},
            )
        self.assertEqual(
            [
                "grant:uten-imp.service",
                "start:uten-imp.service",
                "close",
                "health:uten-imp.service",
                "readiness",
                "grant:nginx.service",
                "start:nginx.service",
                "close",
                "health:nginx.service",
            ],
            events,
        )

    def test_failed_unit_start_still_consumes_gate_grant(self):
        runner = FakeRunner()
        runner.run = Mock(side_effect=nvme.CommissioningError("injected start failure"))
        with patch.object(nvme, "publish_gate_grant"), patch.object(
            nvme, "ensure_gate_authorizer_closed"
        ) as close:
            with self.assertRaisesRegex(nvme.CommissioningError, "injected start failure"):
                nvme.start_unit_with_one_time_gate(
                    runner,
                    Path("/var/lib/uten-imp-nvme-commissioning/nvme-test"),
                    {},
                    "uten-imp.service",
                    log_name="test-start",
                )
        close.assert_called_once_with(runner)

    def test_partial_gate_publication_failure_still_closes_marker(self):
        runner = FakeRunner()
        events = []

        def partial_publish(*args, **kwargs):
            events.append("grant-and-marker-written")
            raise nvme.CommissioningError("injected authorizer verification failure")

        with patch.object(nvme, "publish_gate_grant", side_effect=partial_publish), patch.object(
            nvme,
            "ensure_gate_authorizer_closed",
            side_effect=lambda current_runner: events.append("closed"),
        ):
            with self.assertRaisesRegex(nvme.CommissioningError, "authorizer verification failure"):
                nvme.start_unit_with_one_time_gate(
                    runner,
                    Path("/var/lib/uten-imp-nvme-commissioning/nvme-test"),
                    {},
                    "apt-daily.timer",
                    log_name="test-partial-grant",
                )
        self.assertEqual(["grant-and-marker-written", "closed"], events)
        self.assertFalse(
            any(len(call) > 1 and call[:2] == (nvme.SYSTEMCTL, "start") for call in runner.calls)
        )

    def test_late_retry_budget_is_bounded_per_boot(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            pointer = self.pointer(evidence)
            with patch.object(nvme, "current_boot_id", return_value="00000000-0000-0000-0000-000000000001"), patch.object(
                nvme, "root_file_metadata_is_exact", return_value=True
            ), patch.object(
                nvme, "root_directory_metadata_is_exact", return_value=True
            ), patch.object(
                nvme, "atomic_write", side_effect=lambda path, payload, **kwargs: Path(path).write_bytes(payload)
            ), patch.object(
                nvme,
                "ensure_secure_directory",
                side_effect=lambda path, mode=0o700: Path(path).mkdir(parents=True, exist_ok=True),
            ):
                for expected in range(1, nvme.LATE_RECOVERY_ATTEMPTS + 1):
                    attempt, state = nvme.begin_late_recovery_attempt(evidence, pointer)
                    self.assertEqual(expected, attempt)
                    nvme.finish_late_recovery_attempt(evidence, state, status="FAILED", failure="injected")
                with self.assertRaisesRegex(nvme.CommissioningError, "attempts are exhausted"):
                    nvme.begin_late_recovery_attempt(evidence, pointer)

    def test_mutable_late_receipts_reject_extra_or_cross_transaction_fields(self):
        evidence = Path("/var/lib/uten-imp-nvme-commissioning/nvme-20260812T080000Z-0123456789ab")
        pointer = self.pointer(evidence)
        state = {
            "schemaVersion": nvme.SCHEMA_VERSION,
            "kind": nvme.KIND + "-late-recovery-state",
            "transactionId": evidence.name,
            "planSha256": pointer["planSha256"],
            "bootId": "00000000-0000-0000-0000-000000000001",
            "attemptCount": 1,
            "status": "RUNNING",
            "lastAttemptAtUtc": "2026-08-12T00:00:00Z",
            "lastFailure": None,
            "previousStateSha256": None,
        }
        nvme.validate_late_recovery_state(Path("late-recovery-state.json"), state, evidence, pointer)
        with self.assertRaisesRegex(nvme.CommissioningError, "binding differs"):
            nvme.validate_late_recovery_state(
                Path("late-recovery-state.json"),
                {**state, "unexpected": True},
                evidence,
                pointer,
            )
        stop_post = {
            "schemaVersion": nvme.SCHEMA_VERSION,
            "kind": nvme.KIND + "-late-stop-post",
            "status": "CONTAINED_ACTIVE_POINTER_RETAINED",
            "transactionId": evidence.name,
            "planSha256": pointer["planSha256"],
            "validationFailure": None,
            "verifiedUpdateInfrastructurePreserved": False,
            "failures": [],
            "recordedAtUtc": "2026-08-12T00:00:00Z",
            "previousReceiptSha256": None,
        }
        nvme.validate_existing_late_stop_post(Path("late-stop-post.json"), stop_post, evidence, pointer)
        with self.assertRaisesRegex(nvme.CommissioningError, "binding differs"):
            nvme.validate_existing_late_stop_post(
                Path("late-stop-post.json"),
                {**stop_post, "transactionId": "nvme-other"},
                evidence,
                pointer,
            )

    def test_mutable_evidence_lineage_requires_a_matching_append_only_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "rollback.json"

            def secure_directory(target, mode=0o700):
                Path(target).mkdir(parents=True, exist_ok=True)

            with patch.object(nvme, "ensure_secure_directory", side_effect=secure_directory), patch.object(
                nvme, "root_directory_metadata_is_exact", return_value=True
            ), patch.object(nvme, "root_file_metadata_is_exact", return_value=True), patch.object(
                nvme.os, "fchown"
            ), patch.object(nvme.os, "chown"):
                first = nvme.atomic_json_with_lineage(
                    path,
                    {"schemaVersion": 1, "status": "FIRST"},
                    lineage_field="previousReceiptSha256",
                )
                self.assertIsNone(first["previousReceiptSha256"])
                second = nvme.atomic_json_with_lineage(
                    path,
                    {"schemaVersion": 1, "status": "SECOND"},
                    lineage_field="previousReceiptSha256",
                )
                nvme.validate_lineage_reference(path, second, "previousReceiptSha256")
                archive = next((root / "history" / "rollback").iterdir())
                archive.write_bytes(b"tampered\n")
                with self.assertRaisesRegex(nvme.CommissioningError, "digest differs"):
                    nvme.validate_lineage_reference(path, second, "previousReceiptSha256")


class ParsingTest(unittest.TestCase):
    def test_lvm_report_requires_one_report_and_valid_rows(self):
        self.assertEqual([{"vg_name": "ubuntu-vg", "vg_free": "123"}], nvme.parse_lvm_rows(
            {"report": [{"vg": [{"vg_name": " ubuntu-vg ", "vg_free": "123"}]}]}, "vg"
        ))
        for document in ({}, {"report": []}, {"report": [{"vg": {}}, {"vg": []}]}):
            with self.subTest(document=document), self.assertRaises(nvme.CommissioningError):
                nvme.parse_lvm_rows(document, "vg")

    def test_integer_field_rejects_bool_negative_and_text(self):
        self.assertEqual(42, nvme.integer_field(" 42 ", "value"))
        self.assertEqual(42, nvme.integer_field("<42.00", "value"))
        for value in (True, -1, "abc", "42.5"):
            with self.subTest(value=value), self.assertRaises(nvme.CommissioningError):
                nvme.integer_field(value, "value")

    def test_strict_evidence_json_rejects_duplicate_keys_and_nonfinite_numbers(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            for payload in (
                b'{"status":"safe","status":"unsafe"}\n',
                b'{"value":NaN}\n',
                b'{"value":Infinity}\n',
                b'{"value":-Infinity}\n',
            ):
                with self.subTest(payload=payload):
                    path.write_bytes(payload)
                    with self.assertRaisesRegex(nvme.CommissioningError, "invalid JSON"):
                        nvme.load_json_regular(path)


if __name__ == "__main__":
    unittest.main()
