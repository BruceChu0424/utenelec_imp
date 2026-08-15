from __future__ import annotations

import ast
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).with_name("storage_mount_observer.py")
SPEC = importlib.util.spec_from_file_location(
    "uten_imp_storage_mount_observer_under_test", MODULE_PATH
)
assert SPEC is not None and SPEC.loader is not None
observer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observer)

REPO = Path(__file__).resolve().parents[2]
UNIT_TEMPLATE = (
    REPO / "deploy/systemd/uten-imp-storage-observer.service.example"
)
WATCHDOG_UNIT = REPO / "deploy/systemd/uten-imp-watchdog.service.example"


def authority() -> dict[str, object]:
    return {
        "dataFilesystem": "ext4",
        "dataSource": "/dev/md/uten-data",
        "dataUuid": "12345678-1234-1234-1234-123456789abc",
        "minimumFreeBytes": 2 * 1024**3,
        "minimumFreeInodes": 100_000,
        "mountPoint": "/data",
        "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],
        "schemaVersion": 2,
    }


def request() -> dict[str, object]:
    return {
        "authoritySha256": "a" * 64,
        "bootId": "12345678-1234-1234-1234-123456789abc",
        "dataFilesystem": "ext4",
        "dataSource": "/dev/md/uten-data",
        "dataUuid": "12345678-1234-1234-1234-123456789abc",
        "deviceAllowPath": "/dev/md127",
        "expiresAtBoottimeNs": 31_000_000_000,
        "fstabSha256": "b" * 64,
        "helperSha256": "c" * 64,
        "nonce": "d" * 64,
        "observerUnitSha256": "e" * 64,
        "requestedAtBoottimeNs": 1_000_000_000,
        "schemaVersion": 1,
    }


def authority_v3() -> dict[str, object]:
    return {
        "approvalReference": "CHG-2026-0812-NVME",
        "commissioningEvidenceSha256": "9" * 64,
        "dataFilesystem": "ext4",
        "dataSource": "/dev/mapper/ubuntu--vg-uten--data",
        "dataUuid": "12345678-1234-1234-1234-123456789abc",
        "lvm": {
            "dmUuid": "LVM-" + "A" * 64,
            "lvSizeBytes": 350 * 1024**3,
            "lvUuid": "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF",
            "pvCount": 1,
            "pvUuid": "FEDCBA-abcd-1234-5678-9abc-def0-FEDCBA",
            "segmentType": "linear",
            "vgUuid": "AAAAAA-bbbb-2222-3333-4444-5555-CCCCCC",
        },
        "minimumFreeBytes": 2 * 1024**3,
        "minimumFreeInodes": 100_000,
        "mountPoint": "/data",
        "nvme": {
            "namespaceById": "/dev/disk/by-id/nvme-UTEN_NVME",
            "partitionById": "/dev/disk/by-id/nvme-UTEN_NVME-part3",
            "partitionNumber": 3,
            "rotational": False,
            "serialSha256": "8" * 64,
            "transport": "nvme",
        },
        "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],
        "schemaVersion": 3,
        "topology": "lvm-linear-nvme",
    }


def request_v3() -> dict[str, object]:
    value = request()
    value.pop("deviceAllowPath")
    value.update(
        {
            "dataSource": authority_v3()["dataSource"],
            "schemaVersion": 2,
            "topology": "lvm-linear-nvme",
        }
    )
    return value


def receipt_v3() -> dict[str, object]:
    value = request_v3()
    value.update(
        {
            "dataDeviceRdev": "253:1",
            "dmUuid": authority_v3()["lvm"]["dmUuid"],
            "lvSizeBytes": 350 * 1024**3,
            "namespaceRdev": "259:0",
            "observedAtBoottimeNs": 2_000_000_000,
            "partitionNumber": 3,
            "partitionRdev": "259:3",
            "resolvedDataSource": "/dev/dm-1",
            "resolvedNamespace": "/dev/nvme0n1",
            "resolvedPartition": "/dev/nvme0n1p3",
            "rotational": False,
            "status": "eligible-for-data-mount",
            "transport": "nvme",
        }
    )
    return value


def receipt() -> dict[str, object]:
    value = request()
    value.update(
        {
            "deviceRdev": "9:127",
            "mdActiveDevices": 2,
            "mdExpectedDevices": 2,
            "mdLevel": "raid1",
            "mdName": "md127",
            "mdState": "UU",
            "observedAtBoottimeNs": 2_000_000_000,
            "resolvedDataSource": "/dev/md127",
            "status": "eligible-for-data-mount",
        }
    )
    return value


class StorageObserverStaticContractTest(unittest.TestCase):
    def test_template_is_exact_v3_no_device_render(self) -> None:
        template = UNIT_TEMPLATE.read_text(encoding="utf-8")
        self.assertEqual(template, observer.render_observer_unit(None))
        self.assertNotIn("DeviceAllow=", template)
        rendered = observer.render_observer_unit("/dev/md127")
        self.assertEqual(rendered.count("DeviceAllow="), 1)
        self.assertIn("DeviceAllow=/dev/md127 r", rendered)
        self.assertIn("DevicePolicy=closed", rendered)
        self.assertIn("PrivateDevices=false", rendered)
        self.assertIn("PrivateNetwork=true", rendered)
        self.assertIn("RestrictAddressFamilies=AF_UNIX", rendered)
        self.assertIn("ProtectSystem=strict", rendered)
        self.assertNotIn("[Install]", rendered)

    def test_watchdog_keeps_private_devices_and_only_receipt_runtime_write(self) -> None:
        unit = WATCHDOG_UNIT.read_text(encoding="utf-8")
        self.assertIn("PrivateDevices=true", unit)
        self.assertIn("-/run/uten-imp-storage-observer", unit)
        self.assertNotIn("DeviceAllow=", unit)

    def test_observe_call_graph_has_no_systemctl_or_mount(self) -> None:
        tree = ast.parse(MODULE_PATH.read_text(encoding="utf-8"))
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        inspected = {
            "observe",
            "_request_and_contract",
            "_current_contract",
            "_block_stat",
            "_md_health",
            "_atomic_object",
        }
        text = "\n".join(ast.unparse(functions[name]) for name in sorted(inspected))
        self.assertNotIn("systemctl", text)
        self.assertNotIn("/usr/bin/mount", text)
        self.assertNotIn("subprocess.run", ast.unparse(functions["observe"]))

    def test_cli_has_no_path_override(self) -> None:
        source = MODULE_PATH.read_text(encoding="utf-8")
        self.assertNotIn("argparse", source)
        self.assertNotIn("--authority", source)
        self.assertNotIn("--request", source)
        self.assertEqual(observer.main(["--request", "/tmp/forged"]), 1)


class StorageObserverEvidenceTest(unittest.TestCase):
    def test_loaded_observer_must_be_static_networkless_and_device_closed(self) -> None:
        properties = {
            "LoadState": "loaded",
            "FragmentPath": str(observer.OBSERVER_UNIT_PATH),
            "DropInPaths": "",
            "User": "root",
            "UnitFileState": "static",
            "DevicePolicy": "closed",
            "PrivateDevices": "no",
            "PrivateNetwork": "yes",
            "ExecStart": f"/usr/bin/python3 -I {observer.HELPER_PATH} observe",
        }
        with mock.patch.object(
            observer, "_systemd_properties", return_value=properties
        ):
            observer._validate_loaded_observer_unit()
            for key, unsafe in (
                ("DropInPaths", "/etc/systemd/system/rogue.conf"),
                ("UnitFileState", "enabled"),
                ("DevicePolicy", "auto"),
                ("PrivateDevices", "yes"),
                ("PrivateNetwork", "no"),
                ("ExecStart", "/bin/sh -c true"),
            ):
                with self.subTest(key=key):
                    safe = properties[key]
                    properties[key] = unsafe
                    with self.assertRaises(observer.ObservationError):
                        observer._validate_loaded_observer_unit()
                    properties[key] = safe

    def test_pre_mount_fstab_and_loaded_options_are_exact_not_subset(self) -> None:
        properties = {
            "LoadState": "loaded",
            "SourcePath": "/etc/fstab",
            "FragmentPath": "/run/systemd/generator/data.mount",
            "DropInPaths": "",
            "Where": "/data",
            "What": "UUID=12345678-1234-1234-1234-123456789abc",
            "Options": "rw,nodev,nosuid,noexec",
        }
        valid = (
            b"UUID=12345678-1234-1234-1234-123456789abc /data ext4 "
            b"rw,nodev,nosuid,noexec 0 2\n"
        )
        with mock.patch.object(
            observer, "_systemd_properties", return_value=properties
        ), mock.patch.object(observer, "_read_regular", return_value=b"unit"):
            observer._validate_fstab_and_data_unit(authority(), valid)
            for unsafe in (
                "rw,nodev,nosuid,noexec,dev",
                "rw,nodev,nosuid,noexec,nofail",
                "rw,nodev,nosuid,noexec,x-systemd.automount",
                "rw,rw,nodev,nosuid,noexec",
                "rw,nodev,nosuid,noexec,ro",
            ):
                with self.subTest(fstab_options=unsafe), self.assertRaisesRegex(
                    observer.ObservationError, "exact reviewed pre-mount set"
                ):
                    observer._validate_fstab_and_data_unit(
                        authority(), valid.replace(b"rw,nodev,nosuid,noexec", unsafe.encode())
                    )
            properties["Options"] = "rw,nodev,nosuid,noexec,nofail"
            with self.assertRaisesRegex(
                observer.ObservationError, "exact pre-mount policy"
            ):
                observer._validate_fstab_and_data_unit(authority(), valid)

    def test_request_requires_exact_ttl_and_contract_fields(self) -> None:
        observer._validate_request(request())
        for label, mutate in (
            (
                "long-ttl",
                lambda value: value.__setitem__(
                    "expiresAtBoottimeNs", value["expiresAtBoottimeNs"] + 1
                ),
            ),
            ("extra-key", lambda value: value.__setitem__("path", "/tmp")),
            ("non-md", lambda value: value.__setitem__("deviceAllowPath", "/dev/sda")),
        ):
            with self.subTest(label=label):
                value = request()
                mutate(value)
                with self.assertRaises(observer.ObservationError):
                    observer._validate_request(value)

    def test_receipt_binds_nonce_boot_contract_and_full_md_health(self) -> None:
        observer._validate_receipt(receipt(), request(), authority())
        for label, key, replacement in (
            ("nonce-replay", "nonce", "f" * 64),
            ("other-boot", "bootId", "ffffffff-ffff-ffff-ffff-ffffffffffff"),
            ("wrong-helper", "helperSha256", "f" * 64),
            ("degraded-count", "mdActiveDevices", 1),
            ("degraded-state", "mdState", "U_"),
            ("other-device", "resolvedDataSource", "/dev/md126"),
        ):
            with self.subTest(label=label):
                value = receipt()
                value[key] = replacement
                with self.assertRaises(observer.ObservationError):
                    observer._validate_receipt(value, request(), authority())

    def test_v3_request_and_receipt_bind_stable_topology_without_dm_device_allow(self) -> None:
        observer._authority((json.dumps(authority_v3()) + "\n").encode())
        observer._validate_request(request_v3())
        observer._validate_receipt(receipt_v3(), request_v3(), authority_v3())
        self.assertNotIn("DeviceAllow=", observer.render_observer_unit(None))
        for key, replacement in (
            ("dmUuid", "LVM-" + "B" * 64),
            ("lvSizeBytes", 349 * 1024**3),
            ("partitionNumber", 2),
            ("rotational", True),
            ("transport", "sata"),
        ):
            with self.subTest(key=key):
                value = receipt_v3()
                value[key] = replacement
                with self.assertRaises(observer.ObservationError):
                    observer._validate_receipt(value, request_v3(), authority_v3())

    def test_v3_observation_uses_stable_paths_and_namespace_rotational_flag(self) -> None:
        data = SimpleNamespace(st_mode=stat.S_IFBLK | 0o600, st_rdev=os.makedev(253, 1))
        partition = SimpleNamespace(st_mode=stat.S_IFBLK | 0o600, st_rdev=os.makedev(259, 3))
        namespace = SimpleNamespace(st_mode=stat.S_IFBLK | 0o600, st_rdev=os.makedev(259, 0))
        auth = authority_v3()
        with tempfile.TemporaryDirectory() as temporary:
            sysfs = Path(temporary)
            (sysfs / "253:1/dm").mkdir(parents=True)
            (sysfs / "253:1/slaves/nvme0n1p3").mkdir(parents=True)
            (sysfs / "259:3").mkdir(parents=True)
            (sysfs / "259:0/queue").mkdir(parents=True)
            (sysfs / "253:1/dm/uuid").write_text(auth["lvm"]["dmUuid"] + "\n", encoding="ascii")
            (sysfs / "253:1/size").write_text(str(350 * 1024**3 // 512), encoding="ascii")
            (sysfs / "259:3/partition").write_text("3\n", encoding="ascii")
            (sysfs / "259:0/queue/rotational").write_text("0\n", encoding="ascii")

            def block_stat(path: Path):
                text = str(path)
                if text in {auth["dataSource"], "/dev/dm-1", f"/dev/disk/by-uuid/{auth['dataUuid']}"}:
                    return data
                if text in {auth["nvme"]["partitionById"], "/dev/nvme0n1p3"}:
                    return partition
                if text in {auth["nvme"]["namespaceById"], "/dev/nvme0n1"}:
                    return namespace
                raise AssertionError(text)

            resolutions = {
                auth["dataSource"]: "/dev/dm-1",
                auth["nvme"]["partitionById"]: "/dev/nvme0n1p3",
                auth["nvme"]["namespaceById"]: "/dev/nvme0n1",
            }
            with mock.patch.object(observer, "SYS_DEV_BLOCK", sysfs), mock.patch.object(
                observer, "_block_stat", side_effect=block_stat
            ), mock.patch.object(
                observer.os.path,
                "realpath",
                side_effect=lambda value: resolutions.get(str(value), str(value)),
            ), mock.patch.object(observer, "_boottime_ns", return_value=2_000_000_000):
                value = observer._observe_lvm_nvme(request_v3(), auth)
        self.assertEqual(value["dataDeviceRdev"], "253:1")
        self.assertEqual(value["partitionRdev"], "259:3")
        self.assertEqual(value["namespaceRdev"], "259:0")
        self.assertFalse(value["rotational"])

    def test_verify_consumes_receipt_before_request(self) -> None:
        unlinked: list[Path] = []
        with mock.patch.object(
            observer, "_request_and_contract", return_value=(request(), authority())
        ), mock.patch.object(
            observer, "_read_regular", return_value=b"{}"
        ), mock.patch.object(
            observer, "_strict_object", return_value=receipt()
        ), mock.patch.object(
            observer, "_boottime_ns", return_value=3_000_000_000
        ), mock.patch.object(
            observer, "_unlink_evidence", side_effect=unlinked.append
        ):
            observer.verify_and_consume()
        self.assertEqual(unlinked, [observer.RECEIPT_PATH, observer.REQUEST_PATH])

    def test_expired_receipt_never_consumes_evidence(self) -> None:
        with mock.patch.object(
            observer, "_request_and_contract", return_value=(request(), authority())
        ), mock.patch.object(
            observer, "_read_regular", return_value=b"{}"
        ), mock.patch.object(
            observer, "_strict_object", return_value=receipt()
        ), mock.patch.object(
            observer,
            "_boottime_ns",
            return_value=int(request()["expiresAtBoottimeNs"]) + 1,
        ), mock.patch.object(observer, "_unlink_evidence") as unlink:
            with self.assertRaises(observer.ObservationError):
                observer.verify_and_consume()
        unlink.assert_not_called()

    def test_observer_rejects_replayed_nonce_before_device_observation(self) -> None:
        with mock.patch.object(
            observer, "_request_and_contract", return_value=(request(), authority())
        ), mock.patch.object(os.path, "lexists", return_value=True), mock.patch.object(
            observer, "_read_regular", return_value=b"{}"
        ), mock.patch.object(
            observer, "_strict_object", return_value={"nonce": request()["nonce"]}
        ), mock.patch.object(observer, "_block_stat") as block_stat, mock.patch.object(
            observer, "_atomic_object"
        ) as publish:
            with self.assertRaisesRegex(observer.ObservationError, "already used"):
                observer.observe()
        block_stat.assert_not_called()
        publish.assert_not_called()

    def test_observer_publishes_bound_exact_device_receipt(self) -> None:
        block = SimpleNamespace(st_mode=stat.S_IFBLK | 0o600, st_rdev=os.makedev(9, 127))
        published: list[tuple[Path, dict[str, object]]] = []
        with mock.patch.object(
            observer, "_request_and_contract", return_value=(request(), authority())
        ), mock.patch.object(os.path, "lexists", return_value=False), mock.patch.object(
            os.path, "realpath", return_value="/dev/md127"
        ), mock.patch.object(
            observer, "_block_stat", return_value=block
        ) as block_stat, mock.patch.object(
            observer,
            "_command",
            return_value="raid1 9:127 12345678-1234-1234-1234-123456789abc ext4",
        ), mock.patch.object(
            observer, "_md_health", return_value=("raid1", 2, 2, "UU")
        ), mock.patch.object(
            observer, "_boottime_ns", return_value=2_000_000_000
        ), mock.patch.object(
            observer, "_atomic_object", side_effect=lambda path, value: published.append((path, value))
        ):
            observer.observe()
        self.assertEqual(block_stat.call_count, 3)
        self.assertEqual(len(published), 1)
        path, value = published[0]
        self.assertEqual(path, observer.RECEIPT_PATH)
        self.assertEqual(value["nonce"], request()["nonce"])
        self.assertEqual(value["helperSha256"], request()["helperSha256"])
        self.assertEqual(value["deviceRdev"], "9:127")
        self.assertEqual(value["status"], "eligible-for-data-mount")

    def test_wrong_resolved_device_fails_before_any_block_open(self) -> None:
        with mock.patch.object(
            observer, "_request_and_contract", return_value=(request(), authority())
        ), mock.patch.object(os.path, "lexists", return_value=False), mock.patch.object(
            os.path, "realpath", return_value="/dev/md126"
        ), mock.patch.object(observer, "_block_stat") as block_stat, mock.patch.object(
            observer, "_atomic_object"
        ) as publish:
            with self.assertRaisesRegex(observer.ObservationError, "DeviceAllow"):
                observer.observe()
        block_stat.assert_not_called()
        publish.assert_not_called()

    def test_boot_change_invalidates_power_loss_residue(self) -> None:
        value = request()
        with mock.patch.object(
            observer, "_read_regular", return_value=b"{}"
        ), mock.patch.object(
            observer, "_strict_object", return_value=value
        ), mock.patch.object(
            observer,
            "_current_contract",
            return_value=(authority(), b"a", b"b", b"c", b"d"),
        ), mock.patch.object(
            observer, "_boot_id", return_value="ffffffff-ffff-ffff-ffff-ffffffffffff"
        ):
            with self.assertRaisesRegex(observer.ObservationError, "another boot"):
                observer._request_and_contract()


class MdstatContractTest(unittest.TestCase):
    def test_mdstat_requires_idle_full_redundancy(self) -> None:
        healthy = """Personalities : [raid1]\nmd127 : active raid1 sda1[0] sdb1[1]\n      100 blocks super 1.2 [2/2] [UU]\n\nunused devices: <none>\n"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "mdstat"
            path.write_text(healthy, encoding="ascii")
            with mock.patch.object(observer, "MDSTAT_PATH", path):
                self.assertEqual(
                    observer._md_health("md127"), ("raid1", 2, 2, "UU")
                )
                path.write_text(healthy.replace("[UU]", "[U_]"), encoding="ascii")
                with self.assertRaisesRegex(observer.ObservationError, "degraded"):
                    observer._md_health("md127")
                path.write_text(
                    healthy.replace("[UU]", "[UU]\n      [=>...] recovery = 1.0%"),
                    encoding="ascii",
                )
                with self.assertRaisesRegex(observer.ObservationError, "busy"):
                    observer._md_health("md127")


if __name__ == "__main__":
    unittest.main()
