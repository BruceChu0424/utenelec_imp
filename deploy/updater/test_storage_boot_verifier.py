from __future__ import annotations

import importlib.util
import json
import os
import stat
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("storage_boot_verifier.py")
SPEC = importlib.util.spec_from_file_location("uten_imp_storage_boot_under_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)


VG_UUID = "AAAAAA-bbbb-2222-3333-4444-5555-CCCCCC"
LV_UUID = "ABCDEF-abcd-1234-5678-9abc-def0-ABCDEF"
PV_UUID = "FEDCBA-abcd-1234-5678-9abc-def0-FEDCBA"
DM_UUID = "LVM-" + VG_UUID.replace("-", "") + LV_UUID.replace("-", "")


def authority_v3() -> dict[str, object]:
    return {
        "approvalReference": "CHG-2026-0812-NVME",
        "commissioningEvidenceSha256": "a" * 64,
        "dataFilesystem": "ext4",
        "dataSource": "/dev/mapper/ubuntu--vg-uten--data",
        "dataUuid": "11111111-2222-3333-4444-555555555555",
        "lvm": {
            "dmUuid": DM_UUID,
            "lvSizeBytes": 350 * 1024**3,
            "lvUuid": LV_UUID,
            "pvCount": 1,
            "pvUuid": PV_UUID,
            "segmentType": "linear",
            "vgUuid": VG_UUID,
        },
        "minimumFreeBytes": 2 * 1024**3,
        "minimumFreeInodes": 100_000,
        "mountPoint": "/data",
        "nvme": {
            "namespaceById": "/dev/disk/by-id/nvme-UTEN_NVME",
            "partitionById": "/dev/disk/by-id/nvme-UTEN_NVME-part3",
            "partitionNumber": 3,
            "rotational": False,
            "serialSha256": storage.hashlib.sha256(b"SERIAL").hexdigest(),
            "transport": "nvme",
        },
        "requiredOptions": ["nodev", "noexec", "nosuid", "rw"],
        "schemaVersion": 3,
        "topology": "lvm-linear-nvme",
    }


def block(major: int, minor: int) -> types.SimpleNamespace:
    return types.SimpleNamespace(
        st_mode=stat.S_IFBLK | 0o600,
        st_rdev=os.makedev(major, minor),
    )


class StorageAuthorityV3Tests(unittest.TestCase):
    def test_current_v3_and_legacy_v2_are_discriminated_exactly(self) -> None:
        self.assertEqual(storage.validate_authority(authority_v3()), 3)
        legacy = {
            key: value
            for key, value in authority_v3().items()
            if key in storage.V2_AUTHORITY_KEYS
        }
        legacy["dataSource"] = "/dev/md/uten-data"
        legacy["schemaVersion"] = 2
        self.assertEqual(storage.validate_authority(legacy), 2)

        for label, mutate in (
            ("wrong-topology", lambda value: value.__setitem__("topology", "raid")),
            ("striped", lambda value: value["lvm"].__setitem__("segmentType", "striped")),
            ("two-pv", lambda value: value["lvm"].__setitem__("pvCount", 2)),
            ("rotating", lambda value: value["nvme"].__setitem__("rotational", True)),
            ("sata", lambda value: value["nvme"].__setitem__("transport", "sata")),
            ("unstable-dm", lambda value: value.__setitem__("dataSource", "/dev/dm-1")),
            ("extra-key", lambda value: value.__setitem__("unreviewed", True)),
        ):
            with self.subTest(label=label):
                value = authority_v3()
                mutate(value)
                with self.assertRaises(storage.StorageBootError):
                    storage.validate_authority(value)

    def test_live_identity_binds_lv_vg_pv_parent_and_serial(self) -> None:
        authority = authority_v3()
        with tempfile.TemporaryDirectory() as temporary:
            sysfs = Path(temporary)
            (sysfs / "253:1/dm").mkdir(parents=True)
            (sysfs / "259:3").mkdir(parents=True)
            (sysfs / "253:1/dm/uuid").write_text(DM_UUID + "\n", encoding="ascii")
            sectors = 350 * 1024**3 // 512
            (sysfs / "253:1/size").write_text(f"{sectors}\n", encoding="ascii")
            (sysfs / "259:3/partition").write_text("3\n", encoding="ascii")

            def details(path: Path, _label: str):
                text = str(path)
                if text in {
                    authority["dataSource"],
                    f"/dev/disk/by-uuid/{authority['dataUuid']}",
                }:
                    return block(253, 1)
                if text in {
                    authority["nvme"]["partitionById"],
                    "/dev/nvme0n1p3",
                }:
                    return block(259, 3)
                if text in {authority["nvme"]["namespaceById"], "/dev/nvme0n1"}:
                    return block(259, 0)
                raise AssertionError(text)

            responses = {
                "lvs": {
                    "report": [{"lv": [{
                        "devices": "/dev/nvme0n1p3(0)",
                        "lv_size": str(350 * 1024**3),
                        "lv_uuid": LV_UUID,
                        "segtype": "linear",
                        "vg_uuid": VG_UUID,
                    }]}]
                },
                "pvs": {
                    "report": [{"pv": [{
                        "pv_name": "/dev/nvme0n1p3",
                        "pv_uuid": PV_UUID,
                        "vg_uuid": VG_UUID,
                    }]}]
                },
                "lsblk": {
                    "blockdevices": [{
                        "path": "/dev/nvme0n1",
                        "type": "disk",
                        "maj:min": "259:0",
                        "size": 512110190592,
                        "rota": False,
                        "tran": "nvme",
                    }]
                },
            }

            def run(arguments: list[str], _label: str, **_kwargs) -> str:
                name = Path(arguments[0]).name
                if name == "udevadm":
                    return "ID_SERIAL_SHORT=SERIAL"
                return json.dumps(responses[name])

            resolutions = {
                authority["dataSource"]: "/dev/dm-1",
                authority["nvme"]["partitionById"]: "/dev/nvme0n1p3",
                authority["nvme"]["namespaceById"]: "/dev/nvme0n1",
            }
            with mock.patch.object(storage, "SYS_DEV_BLOCK", sysfs), mock.patch.object(
                storage, "_block_details", side_effect=details
            ), mock.patch.object(
                storage.os.path,
                "realpath",
                side_effect=lambda value: resolutions.get(str(value), str(value)),
            ), mock.patch.object(storage, "_run", side_effect=run):
                self.assertEqual(storage._verify_lvm_nvme_identity(authority), ("/dev/dm-1", "253:1"))
                responses["pvs"]["report"][0]["pv"][0]["pv_uuid"] = "BADBAD-bbbb-2222-3333-4444-5555-BADBAD"
                with self.assertRaisesRegex(storage.StorageBootError, "physical-volume identity"):
                    storage._verify_lvm_nvme_identity(authority)


if __name__ == "__main__":
    unittest.main()
