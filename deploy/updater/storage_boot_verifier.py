#!/usr/bin/env python3
"""Fail closed before PostgreSQL touches an uncommissioned /data filesystem."""

from __future__ import annotations

import json
import hashlib
import os
import re
import stat
import subprocess
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, NoReturn


STORAGE_AUTHORITY = Path("/etc/uten-imp/storage-authority.json")
DATA_MOUNT_TEXT = "/data"
POSTGRES_DATA_TEXT = "/data/postgresql/16/main"
DATA_MOUNT = Path(DATA_MOUNT_TEXT)
POSTGRES_DATA = Path(POSTGRES_DATA_TEXT)
POSTGRES_CONFIG_QUERY = Path("/usr/bin/pg_conftool")
MAX_AUTHORITY_BYTES = 16 * 1024
SYS_DEV_BLOCK = Path("/sys/dev/block")
BY_UUID_ROOT = Path("/dev/disk/by-uuid")
DATA_UUID_RE = re.compile(
    r"(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{16,64})"
)
MD_DATA_SOURCE_RE = re.compile(r"/dev/md(?:\d+|/[A-Za-z0-9_.-]+)")
LVM_DATA_SOURCE_RE = re.compile(
    r"/dev/mapper/[A-Za-z0-9_.+~-]+-[A-Za-z0-9_.+~-]+"
)
LVM_UUID_RE = re.compile(r"[A-Za-z0-9]{6}(?:-[A-Za-z0-9]{4}){5}-[A-Za-z0-9]{6}")
DM_UUID_RE = re.compile(r"LVM-[A-Za-z0-9]{64}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
APPROVAL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}")
NVME_BY_ID_RE = re.compile(r"/dev/disk/by-id/nvme-[A-Za-z0-9._:+-]+")
NVME_PARTITION_BY_ID_RE = re.compile(
    r"/dev/disk/by-id/nvme-[A-Za-z0-9._:+-]+-part[1-9][0-9]*"
)
CANONICAL_REQUIRED_OPTIONS = ["nodev", "noexec", "nosuid", "rw"]
V2_AUTHORITY_KEYS = {
    "dataFilesystem",
    "dataSource",
    "dataUuid",
    "minimumFreeBytes",
    "minimumFreeInodes",
    "mountPoint",
    "requiredOptions",
    "schemaVersion",
}
V3_AUTHORITY_KEYS = V2_AUTHORITY_KEYS | {
    "approvalReference",
    "commissioningEvidenceSha256",
    "lvm",
    "nvme",
    "topology",
}
V3_LVM_KEYS = {
    "dmUuid",
    "lvSizeBytes",
    "lvUuid",
    "pvCount",
    "pvUuid",
    "segmentType",
    "vgUuid",
}
V3_NVME_KEYS = {
    "namespaceById",
    "partitionById",
    "partitionNumber",
    "rotational",
    "serialSha256",
    "transport",
}


class StorageBootError(RuntimeError):
    """The commissioned storage identity or capacity cannot be proven."""


def fail(message: str) -> NoReturn:
    raise StorageBootError(message)


def _require_root_directory_chain(path: Path) -> None:
    current = path
    while True:
        try:
            details = current.lstat()
        except FileNotFoundError as exc:
            raise StorageBootError(f"trusted directory is missing: {current}") from exc
        if (
            not stat.S_ISDIR(details.st_mode)
            or current.is_symlink()
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_mode & 0o022
        ):
            fail(f"trusted directory chain is unsafe: {current}")
        if current == current.parent:
            return
        current = current.parent


def _read_authority() -> dict[str, Any]:
    _require_root_directory_chain(STORAGE_AUTHORITY.parent)
    try:
        details = STORAGE_AUTHORITY.lstat()
    except FileNotFoundError as exc:
        raise StorageBootError("persistent storage authority is missing") from exc
    if (
        not stat.S_ISREG(details.st_mode)
        or STORAGE_AUTHORITY.is_symlink()
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o640
        or details.st_nlink != 1
        or not 1 <= details.st_size <= MAX_AUTHORITY_BYTES
    ):
        fail("persistent storage authority file is unsafe")
    raw = STORAGE_AUTHORITY.read_bytes()
    if b"\0" in raw:
        fail("persistent storage authority contains NUL")

    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if key in result:
                fail("persistent storage authority contains a duplicate key")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda item: fail(
                f"persistent storage authority contains a non-finite value: {item}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StorageBootError("persistent storage authority is not strict JSON") from exc
    if not isinstance(value, dict):
        fail("persistent storage authority root must be an object")
    return value


def _integer(value: Any, label: str, minimum: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        fail(f"{label} is malformed")
    return value


def _exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        fail(f"{label} schema is unsupported")
    return value


def validate_authority(authority: dict[str, Any]) -> int:
    """Validate the complete authority and return its schema version.

    Schema v2 remains readable only so a reviewed rollback can reinstall the
    previous md authority and verifier set.  New commissioning emits v3.
    """

    version = authority.get("schemaVersion")
    if isinstance(version, bool) or version not in {2, 3}:
        fail("persistent storage authority schema is unsupported")
    _exact_object(
        authority,
        V2_AUTHORITY_KEYS if version == 2 else V3_AUTHORITY_KEYS,
        "persistent storage authority",
    )
    if authority.get("mountPoint") != DATA_MOUNT_TEXT:
        fail("persistent storage authority has an unexpected mount point")
    uuid = authority.get("dataUuid")
    if not isinstance(uuid, str) or not DATA_UUID_RE.fullmatch(uuid):
        fail("data filesystem UUID is malformed")
    if authority.get("dataFilesystem") not in {"ext4", "xfs"}:
        fail("persistent storage filesystem type is unsupported")
    if authority.get("requiredOptions") != CANONICAL_REQUIRED_OPTIONS:
        fail("persistent storage required-option policy is unsupported")
    _integer(authority.get("minimumFreeBytes"), "minimum free bytes", 2 * 1024**3)
    _integer(authority.get("minimumFreeInodes"), "minimum free inodes", 100_000)

    source = authority.get("dataSource")
    if version == 2:
        if not isinstance(source, str) or not MD_DATA_SOURCE_RE.fullmatch(source):
            fail("legacy persistent storage source is malformed")
        return version

    if authority.get("topology") != "lvm-linear-nvme":
        fail("persistent storage topology is unsupported")
    if not isinstance(source, str) or not LVM_DATA_SOURCE_RE.fullmatch(source):
        fail("persistent LVM storage source is malformed")
    approval = authority.get("approvalReference")
    evidence = authority.get("commissioningEvidenceSha256")
    if not isinstance(approval, str) or not APPROVAL_RE.fullmatch(approval):
        fail("persistent storage approval reference is malformed")
    if not isinstance(evidence, str) or not SHA256_RE.fullmatch(evidence):
        fail("persistent storage commissioning evidence digest is malformed")

    lvm = _exact_object(authority.get("lvm"), V3_LVM_KEYS, "persistent LVM authority")
    for key in ("lvUuid", "vgUuid", "pvUuid"):
        item = lvm.get(key)
        if not isinstance(item, str) or not LVM_UUID_RE.fullmatch(item):
            fail(f"persistent LVM {key} is malformed")
    dm_uuid = lvm.get("dmUuid")
    if not isinstance(dm_uuid, str) or not DM_UUID_RE.fullmatch(dm_uuid):
        fail("persistent LVM dmUuid is malformed")
    if lvm.get("segmentType") != "linear" or lvm.get("pvCount") != 1:
        fail("persistent LVM authority must describe one linear physical volume")
    _integer(lvm.get("lvSizeBytes"), "persistent LVM size", 200 * 1024**3)

    nvme = _exact_object(
        authority.get("nvme"), V3_NVME_KEYS, "persistent NVMe authority"
    )
    namespace = nvme.get("namespaceById")
    partition = nvme.get("partitionById")
    if not isinstance(namespace, str) or not NVME_BY_ID_RE.fullmatch(namespace):
        fail("persistent NVMe namespace by-id is malformed")
    if (
        not isinstance(partition, str)
        or not NVME_PARTITION_BY_ID_RE.fullmatch(partition)
        or partition == namespace
        or not partition.startswith(namespace + "-part")
    ):
        fail("persistent NVMe partition by-id is malformed")
    if nvme.get("transport") != "nvme" or nvme.get("rotational") is not False:
        fail("persistent storage parent is not approved non-rotating NVMe")
    _integer(nvme.get("partitionNumber"), "persistent NVMe partition number", 1)
    serial_digest = nvme.get("serialSha256")
    if not isinstance(serial_digest, str) or not SHA256_RE.fullmatch(serial_digest):
        fail("persistent NVMe serial digest is malformed")
    return version


def _run(arguments: list[str], label: str, *, timeout: int = 8) -> str:
    try:
        observed = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/sbin:/usr/bin:/sbin:/bin"},
            timeout=timeout,
            check=False,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise StorageBootError(f"{label} could not complete") from exc
    if observed.returncode != 0:
        fail(f"{label} returned failure")
    return observed.stdout.rstrip("\n")


def _strict_command_object(arguments: list[str], label: str) -> dict[str, Any]:
    try:
        value = json.loads(_run(arguments, label))
    except json.JSONDecodeError as exc:
        raise StorageBootError(f"{label} did not return JSON") from exc
    if not isinstance(value, dict):
        fail(f"{label} JSON root is malformed")
    return value


def _decimal_integer(value: Any, label: str) -> int:
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise StorageBootError(f"{label} is malformed") from exc
    if not parsed.is_finite() or parsed != parsed.to_integral_value() or parsed < 0:
        fail(f"{label} is malformed")
    return int(parsed)


def _block_details(path: Path, label: str) -> os.stat_result:
    try:
        details = path.stat()
    except OSError as exc:
        raise StorageBootError(f"{label} is unavailable") from exc
    if not stat.S_ISBLK(details.st_mode):
        fail(f"{label} is not a block device")
    return details


def _report_rows(value: dict[str, Any], section: str, label: str) -> list[dict[str, Any]]:
    reports = value.get("report")
    if not isinstance(reports, list) or len(reports) != 1:
        fail(f"{label} report is ambiguous")
    rows = reports[0].get(section) if isinstance(reports[0], dict) else None
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
        fail(f"{label} report is ambiguous")
    return rows


def _verify_lvm_nvme_identity(authority: dict[str, Any]) -> tuple[str, str]:
    source = Path(authority["dataSource"])
    uuid_path = BY_UUID_ROOT / authority["dataUuid"]
    source_details = _block_details(source, "commissioned LVM source")
    uuid_details = _block_details(uuid_path, "commissioned filesystem UUID link")
    if source_details.st_rdev != uuid_details.st_rdev:
        fail("commissioned LVM source and filesystem UUID identify different devices")
    resolved = os.path.realpath(source)
    if not re.fullmatch(r"/dev/dm-\d+", resolved):
        fail("commissioned LVM source does not resolve to one dm device")
    rdev = f"{os.major(source_details.st_rdev)}:{os.minor(source_details.st_rdev)}"
    dm_root = SYS_DEV_BLOCK / rdev / "dm"
    try:
        dm_uuid = (dm_root / "uuid").read_text(encoding="ascii").strip()
        sectors = int((SYS_DEV_BLOCK / rdev / "size").read_text(encoding="ascii").strip())
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise StorageBootError("live LVM sysfs identity is unavailable") from exc
    lvm = authority["lvm"]
    if dm_uuid != lvm["dmUuid"] or sectors * 512 != lvm["lvSizeBytes"]:
        fail("live LVM dm identity or size differs from authority")
    compact_vg = lvm["vgUuid"].replace("-", "")
    compact_lv = lvm["lvUuid"].replace("-", "")
    if dm_uuid != f"LVM-{compact_vg}{compact_lv}":
        fail("LVM dm UUID does not bind the approved VG and LV UUIDs")

    lv_value = _strict_command_object(
        [
            "/usr/sbin/lvs",
            "--readonly",
            "--reportformat",
            "json",
            "--units",
            "b",
            "--nosuffix",
            "--options",
            "lv_uuid,vg_uuid,lv_size,segtype,devices",
            str(source),
        ],
        "LVM logical-volume observation",
    )
    lv = _report_rows(lv_value, "lv", "LVM logical-volume observation")[0]
    device = str(lv.get("devices", "")).strip()
    device_match = re.fullmatch(r"([^,()]+)\([0-9]+\)", str(device))
    if (
        str(lv.get("lv_uuid", "")).strip() != lvm["lvUuid"]
        or str(lv.get("vg_uuid", "")).strip() != lvm["vgUuid"]
        or _decimal_integer(lv.get("lv_size"), "live LVM size") != lvm["lvSizeBytes"]
        or str(lv.get("segtype", "")).strip() != "linear"
        or device_match is None
    ):
        fail("live LVM logical-volume shape differs from authority")

    nvme = authority["nvme"]
    partition = Path(nvme["partitionById"])
    namespace = Path(nvme["namespaceById"])
    partition_details = _block_details(partition, "commissioned NVMe partition")
    namespace_details = _block_details(namespace, "commissioned NVMe namespace")
    resolved_partition = os.path.realpath(partition)
    resolved_namespace = os.path.realpath(namespace)
    partition_match = re.fullmatch(
        r"/dev/(nvme\d+n\d+)p([1-9][0-9]*)", resolved_partition
    )
    if (
        partition_match is None
        or resolved_namespace != f"/dev/{partition_match.group(1)}"
        or int(partition_match.group(2)) != nvme["partitionNumber"]
    ):
        fail("approved NVMe partition does not belong to the approved namespace")
    lvm_device_details = _block_details(
        Path(device_match.group(1)), "live LVM physical device"
    )
    if partition_details.st_rdev != lvm_device_details.st_rdev:
        fail("live LVM physical device differs from approved NVMe partition")

    pv_value = _strict_command_object(
        [
            "/usr/sbin/pvs",
            "--readonly",
            "--reportformat",
            "json",
            "--options",
            "pv_uuid,vg_uuid,pv_name",
            str(partition),
        ],
        "LVM physical-volume observation",
    )
    pv = _report_rows(pv_value, "pv", "LVM physical-volume observation")[0]
    if (
        str(pv.get("pv_uuid", "")).strip() != lvm["pvUuid"]
        or str(pv.get("vg_uuid", "")).strip() != lvm["vgUuid"]
        or _block_details(Path(str(pv.get("pv_name", "")).strip()), "reported LVM physical volume").st_rdev
        != partition_details.st_rdev
    ):
        fail("live LVM physical-volume identity differs from authority")

    block_value = _strict_command_object(
        [
            "/usr/bin/lsblk",
            "--json",
            "--bytes",
            "--nodeps",
            "--output",
            "PATH,TYPE,MAJ:MIN,SIZE,ROTA,TRAN",
            str(namespace),
        ],
        "NVMe block observation",
    )
    devices = block_value.get("blockdevices")
    if not isinstance(devices, list) or len(devices) != 1 or not isinstance(devices[0], dict):
        fail("NVMe block observation is ambiguous")
    block = devices[0]
    if (
        block.get("type") != "disk"
        or block.get("rota") not in {False, 0}
        or block.get("tran") != "nvme"
        or _block_details(Path(str(block.get("path"))), "reported NVMe namespace").st_rdev
        != namespace_details.st_rdev
        or _decimal_integer(block.get("size"), "live NVMe namespace size")
        < lvm["lvSizeBytes"]
    ):
        fail("live storage parent is not the approved NVMe namespace")
    partition_rdev = f"{os.major(partition_details.st_rdev)}:{os.minor(partition_details.st_rdev)}"
    try:
        partition_number = int(
            (SYS_DEV_BLOCK / partition_rdev / "partition")
            .read_text(encoding="ascii")
            .strip()
        )
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise StorageBootError("NVMe partition number is unavailable") from exc
    if partition_number != nvme["partitionNumber"]:
        fail("live NVMe partition number differs from authority")

    properties = _run(
        [
            "/usr/bin/udevadm",
            "info",
            "--query=property",
            f"--name={namespace}",
        ],
        "NVMe udev identity observation",
    ).splitlines()
    serials = [line.split("=", 1)[1] for line in properties if line.startswith("ID_SERIAL_SHORT=")]
    if len(serials) != 1 or hashlib.sha256(serials[0].encode("utf-8")).hexdigest() != nvme["serialSha256"]:
        fail("live NVMe serial identity differs from authority")
    return resolved, rdev


def _postgres_identity() -> Any:
    try:
        import pwd

        postgres = pwd.getpwnam("postgres")
    except (ImportError, KeyError) as exc:
        raise StorageBootError("PostgreSQL service identity is missing") from exc
    if postgres.pw_uid == 0:
        fail("PostgreSQL service identity must not be root")
    return postgres


def _verify_postgres_data_directory() -> None:
    try:
        observed = subprocess.run(
            [
                str(POSTGRES_CONFIG_QUERY),
                "16",
                "main",
                "show",
                "data_directory",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PATH": "/usr/bin:/bin"},
            timeout=5,
            check=False,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise StorageBootError(
            "PostgreSQL cluster data_directory could not be resolved"
        ) from exc
    if observed.returncode != 0:
        fail("PostgreSQL cluster data_directory could not be resolved")
    lines = observed.stdout.splitlines()
    if len(lines) != 1:
        fail("PostgreSQL cluster data_directory observation is ambiguous")
    setting = re.fullmatch(r"data_directory\s*=\s*'?([^']+?)'?\s*", lines[0])
    if setting is None or setting.group(1) != POSTGRES_DATA_TEXT:
        fail("PostgreSQL 16/main data_directory is outside commissioned /data")
    postgres = _postgres_identity()
    try:
        data_device = DATA_MOUNT.stat().st_dev
        for path in (
            DATA_MOUNT / "postgresql",
            DATA_MOUNT / "postgresql" / "16",
            POSTGRES_DATA,
        ):
            details = path.lstat()
            if (
                not stat.S_ISDIR(details.st_mode)
                or path.is_symlink()
                or details.st_uid != postgres.pw_uid
                or details.st_gid != postgres.pw_gid
                or details.st_mode & 0o022
                or details.st_dev != data_device
            ):
                fail(f"PostgreSQL data-directory chain is unsafe: {path}")
        if stat.S_IMODE(POSTGRES_DATA.lstat().st_mode) != 0o700:
            fail("PostgreSQL data directory must use mode 0700")
    except OSError as exc:
        raise StorageBootError(
            "PostgreSQL data-directory chain cannot be verified"
        ) from exc


def verify_storage_boot() -> None:
    if os.geteuid() != 0:
        fail("storage boot verification must run as root")
    authority = _read_authority()
    version = validate_authority(authority)
    expected_uuid = authority["dataUuid"]
    expected_fstype = authority["dataFilesystem"]
    expected_source = authority["dataSource"]
    required_options = authority["requiredOptions"]
    minimum_free_bytes = _integer(
        authority.get("minimumFreeBytes"), "minimum free bytes", 2 * 1024**3
    )
    minimum_free_inodes = _integer(
        authority.get("minimumFreeInodes"), "minimum free inodes", 100_000
    )
    lvm_identity: tuple[str, str] | None = None
    if version == 3:
        lvm_identity = _verify_lvm_nvme_identity(authority)
    fields_spec = (
        "TARGET,SOURCE,FSTYPE,OPTIONS,UUID"
        if version == 2
        else "TARGET,SOURCE,FSTYPE,OPTIONS,UUID,MAJ:MIN,FSROOT"
    )
    lines = _run(
        [
            "/usr/bin/findmnt",
            "--noheadings",
            "--raw",
            "--output",
            fields_spec,
            "--target",
            DATA_MOUNT_TEXT,
        ],
        "persistent storage observation",
        timeout=5,
    ).splitlines()
    if len(lines) != 1:
        fail("/data is absent or has an ambiguous mount")
    fields = lines[0].split()
    if len(fields) != (5 if version == 2 else 7):
        fail("/data mount observation is malformed")
    target, source, fstype, options, uuid = fields[:5]
    if (
        target != DATA_MOUNT_TEXT
        or fstype != expected_fstype
        or uuid.lower() != expected_uuid
    ):
        fail("/data source, UUID or filesystem differs from commissioned authority")
    if version == 2 and source != expected_source:
        fail("/data source, UUID or filesystem differs from commissioned authority")
    if version == 3:
        assert lvm_identity is not None
        _, expected_rdev = lvm_identity
        observed_rdev, fsroot = fields[5:]
        if fsroot != "/" or observed_rdev != expected_rdev:
            fail("/data is not the root of the commissioned LVM filesystem")
        source_details = _block_details(Path(source), "mounted /data source")
        authority_details = _block_details(
            Path(expected_source), "commissioned LVM source"
        )
        if source_details.st_rdev != authority_details.st_rdev:
            fail("mounted /data source differs from commissioned LVM identity")
    if not set(required_options).issubset(set(options.split(","))):
        fail("/data is not mounted with the commissioned fail-closed options")
    try:
        capacity = os.statvfs(DATA_MOUNT)
    except OSError as exc:
        raise StorageBootError("/data capacity cannot be observed") from exc
    free_bytes = capacity.f_bavail * capacity.f_frsize
    total_bytes = capacity.f_blocks * capacity.f_frsize
    if (
        total_bytes <= 0
        or free_bytes < minimum_free_bytes
        or free_bytes * 100 < total_bytes * 5
        or capacity.f_favail < minimum_free_inodes
    ):
        fail("/data free bytes, percentage or inode reserve is below boot policy")
    _verify_postgres_data_directory()


def main() -> int:
    if len(sys.argv) != 1:
        print("ERP_STORAGE_BOOT_NO_GO: arguments are forbidden", file=sys.stderr)
        return 2
    try:
        verify_storage_boot()
    except Exception as exc:
        print(f"ERP_STORAGE_BOOT_NO_GO: {exc}", file=sys.stderr)
        return 1
    print("ERP_STORAGE_BOOT_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
