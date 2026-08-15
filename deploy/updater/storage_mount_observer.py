#!/usr/bin/env python3
"""Fail-closed host observation for a late, commissioned /data mount.

The watchdog keeps ``PrivateDevices=true``.  It uses ``prepare-request`` to
bind one short-lived nonce to the root-controlled storage and systemd
contracts, starts the separately sandboxed observer service, and then uses
``verify-and-consume``.  Only the observer service runs ``observe``; that
branch never calls systemctl or mount.  Legacy authority v2 is restricted to
one commissioned md ``DeviceAllow=`` node.  Current authority v3 proves the
stable filesystem/LV/PV/NVMe chain using stat(2) and read-only sysfs metadata;
it never grants a drifting ``/dev/dm-N`` node to the observer.

All paths are fixed deliberately.  This tool has no path override interface.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NoReturn


AUTHORITY_PATH = Path("/etc/uten-imp/storage-authority.json")
FSTAB_PATH = Path("/etc/fstab")
OBSERVER_UNIT_PATH = Path("/etc/systemd/system/uten-imp-storage-observer.service")
HELPER_PATH = Path(
    "/usr/local/libexec/uten-imp-release/storage_mount_observer.py"
)
REQUEST_PATH = Path(
    "/run/uten-imp-watchdog/storage-observation-request.json"
)
RECEIPT_PATH = Path(
    "/run/uten-imp-storage-observer/storage-observation-receipt.json"
)
BOOT_ID_PATH = Path("/proc/sys/kernel/random/boot_id")
MDSTAT_PATH = Path("/proc/mdstat")
SYS_DEV_BLOCK = Path("/sys/dev/block")

REQUEST_TTL_NS = 30_000_000_000
MAX_JSON_BYTES = 64 * 1024
MAX_FSTAB_BYTES = 1024 * 1024
MAX_HELPER_BYTES = 1024 * 1024
REQUIRED_OPTIONS = {"rw", "nodev", "nosuid", "noexec"}
CANONICAL_OPTIONS = ["nodev", "noexec", "nosuid", "rw"]
V3_FSTAB_OPTIONS = REQUIRED_OPTIONS | {
    "nofail",
    "x-systemd.device-timeout=30s",
}
BOOT_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
)
SHA256_RE = re.compile(r"[0-9a-f]{64}")
NONCE_RE = re.compile(r"[0-9a-f]{64}")
UUID_RE = re.compile(
    r"(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{16,64})"
)
MD_AUTHORITY_SOURCE_RE = re.compile(r"/dev/md(?:\d+|/[A-Za-z0-9_.-]+)")
MD_RESOLVED_SOURCE_RE = re.compile(r"/dev/md\d+")
LVM_AUTHORITY_SOURCE_RE = re.compile(
    r"/dev/mapper/[A-Za-z0-9_.+~-]+-[A-Za-z0-9_.+~-]+"
)
DM_RESOLVED_SOURCE_RE = re.compile(r"/dev/dm-\d+")
NVME_NAMESPACE_RE = re.compile(r"/dev/disk/by-id/nvme-[A-Za-z0-9_.:+-]+")
NVME_PARTITION_RE = re.compile(
    r"/dev/disk/by-id/nvme-[A-Za-z0-9_.:+-]+-part([1-9][0-9]*)"
)
LVM_UUID_RE = re.compile(
    r"[A-Za-z0-9]{6}(?:-[A-Za-z0-9]{4}){5}-[A-Za-z0-9]{6}"
)
DM_UUID_RE = re.compile(r"LVM-[A-Za-z0-9]{64}")
APPROVAL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}")
RDEV_RE = re.compile(r"[1-9][0-9]*:[0-9]+")
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
SAFE_ENVIRONMENT = {
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
}


class ObservationError(RuntimeError):
    """A storage observation could not be proven safely."""


def fail(message: str) -> NoReturn:
    raise ObservationError(message)


def render_observer_unit(device: str | None = None) -> str:
    """Return the exact observer unit for one authority generation.

    A real md node selects the legacy v2 sandbox.  ``None`` selects the fixed
    v3 stat/sysfs-only sandbox and deliberately renders no ``DeviceAllow``.
    """
    if device is not None and not MD_RESOLVED_SOURCE_RE.fullmatch(device):
        fail("observer DeviceAllow target is not one resolved /dev/mdN node")
    device_allow = "" if device is None else f"DeviceAllow={device} r\n"
    return f"""[Unit]
Description=Uten IMP commissioned storage host observer
Documentation=man:systemd.service(5) man:systemd.resource-control(5)
StartLimitIntervalSec=2min
StartLimitBurst=4
StartLimitAction=none

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/bin/python3 -I /usr/local/libexec/uten-imp-release/storage_mount_observer.py observe
RuntimeDirectory=uten-imp-storage-observer
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=false
DevicePolicy=closed
{device_allow}PrivateNetwork=true
ProtectHome=true
ProtectSystem=strict
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX
IPAddressDeny=any
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
ReadOnlyPaths=/etc/uten-imp/storage-authority.json /etc/fstab /run/uten-imp-watchdog /usr/local/libexec/uten-imp-release/storage_mount_observer.py /dev/disk /dev/mapper /sys/dev/block
ReadWritePaths=/run/uten-imp-storage-observer
TimeoutStartSec=20s
"""


def _read_regular(
    path: Path,
    *,
    exact_mode: int | None,
    maximum: int,
) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if not hasattr(os, "O_NOFOLLOW"):
        fail("platform lacks no-follow file opens")
    flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ObservationError(f"trusted file is unavailable: {path}: {exc}") from exc
    try:
        details = os.fstat(descriptor)
        mode = stat.S_IMODE(details.st_mode)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or details.st_nlink != 1
            or mode & 0o022
            or (exact_mode is not None and mode != exact_mode)
            or details.st_size < 1
            or details.st_size > maximum
        ):
            fail(f"trusted file metadata is unsafe: {path}")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                fail(f"trusted file exceeds size policy: {path}")
        if total != details.st_size:
            fail(f"trusted file changed while it was read: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _strict_object(raw: bytes, description: str) -> dict[str, Any]:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in items:
            if key in value:
                fail(f"{description} contains a duplicate key")
            value[key] = item
        return value

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda item: fail(
                f"{description} contains a non-finite value: {item}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ObservationError(f"{description} is not strict JSON: {exc}") from exc
    if not isinstance(value, dict):
        fail(f"{description} root is not an object")
    return value


def _exact_keys(value: dict[str, Any], expected: set[str], description: str) -> None:
    if set(value) != expected:
        fail(f"{description} has an unsupported key set")


def _sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _boot_id() -> str:
    try:
        value = BOOT_ID_PATH.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise ObservationError("kernel boot ID is unavailable") from exc
    if not BOOT_ID_RE.fullmatch(value):
        fail("kernel boot ID is malformed")
    return value


def _boottime_ns() -> int:
    try:
        value = time.clock_gettime_ns(time.CLOCK_BOOTTIME)
    except (AttributeError, OSError) as exc:
        raise ObservationError("monotonic boot clock is unavailable") from exc
    if value < 0:
        fail("monotonic boot clock is invalid")
    return value


def _authority(raw: bytes) -> dict[str, Any]:
    value = _strict_object(raw, "storage authority")
    version = value.get("schemaVersion")
    if isinstance(version, bool) or version not in {2, 3}:
        fail("storage authority schema is unsupported")
    _exact_keys(
        value,
        V2_AUTHORITY_KEYS if version == 2 else V3_AUTHORITY_KEYS,
        "storage authority",
    )
    source = value.get("dataSource")
    uuid = value.get("dataUuid")
    filesystem = value.get("dataFilesystem")
    if not isinstance(uuid, str) or not UUID_RE.fullmatch(uuid):
        fail("storage authority UUID is malformed")
    if filesystem not in {"ext4", "xfs"} or value.get("mountPoint") != "/data":
        fail("storage authority filesystem or mount point is unsupported")
    if value.get("requiredOptions") != CANONICAL_OPTIONS:
        fail("storage authority mount options are unsupported")
    for key, minimum in (
        ("minimumFreeBytes", 2 * 1024**3),
        ("minimumFreeInodes", 100_000),
    ):
        number = value.get(key)
        if not isinstance(number, int) or isinstance(number, bool) or number < minimum:
            fail(f"storage authority {key} is below policy")
    if version == 2:
        if not isinstance(source, str) or not MD_AUTHORITY_SOURCE_RE.fullmatch(source):
            fail("legacy storage authority source is not a canonical md device")
        return value

    if value.get("topology") != "lvm-linear-nvme":
        fail("storage authority topology is unsupported")
    if not isinstance(source, str) or not LVM_AUTHORITY_SOURCE_RE.fullmatch(source):
        fail("storage authority source is not a stable mapper path")
    approval = value.get("approvalReference")
    evidence = value.get("commissioningEvidenceSha256")
    if not isinstance(approval, str) or not APPROVAL_RE.fullmatch(approval):
        fail("storage authority approval reference is malformed")
    if not isinstance(evidence, str) or not SHA256_RE.fullmatch(evidence):
        fail("storage authority commissioning evidence digest is malformed")
    lvm = value.get("lvm")
    if not isinstance(lvm, dict):
        fail("storage authority LVM object is malformed")
    _exact_keys(lvm, V3_LVM_KEYS, "storage authority LVM object")
    for key in ("lvUuid", "vgUuid", "pvUuid"):
        item = lvm.get(key)
        if not isinstance(item, str) or not LVM_UUID_RE.fullmatch(item):
            fail(f"storage authority LVM {key} is malformed")
    if (
        not isinstance(lvm.get("dmUuid"), str)
        or not DM_UUID_RE.fullmatch(lvm["dmUuid"])
        or lvm.get("segmentType") != "linear"
        or lvm.get("pvCount") != 1
        or isinstance(lvm.get("lvSizeBytes"), bool)
        or not isinstance(lvm.get("lvSizeBytes"), int)
        or lvm["lvSizeBytes"] < 200 * 1024**3
    ):
        fail("storage authority LVM identity is unsupported")
    nvme = value.get("nvme")
    if not isinstance(nvme, dict):
        fail("storage authority NVMe object is malformed")
    _exact_keys(nvme, V3_NVME_KEYS, "storage authority NVMe object")
    namespace = nvme.get("namespaceById")
    partition = nvme.get("partitionById")
    partition_number = nvme.get("partitionNumber")
    if (
        not isinstance(namespace, str)
        or not NVME_NAMESPACE_RE.fullmatch(namespace)
        or not isinstance(partition, str)
        or not NVME_PARTITION_RE.fullmatch(partition)
        or not partition.startswith(namespace + "-part")
        or isinstance(partition_number, bool)
        or not isinstance(partition_number, int)
        or partition_number < 1
        or nvme.get("transport") != "nvme"
        or nvme.get("rotational") is not False
        or not isinstance(nvme.get("serialSha256"), str)
        or not SHA256_RE.fullmatch(nvme["serialSha256"])
    ):
        fail("storage authority NVMe identity is unsupported")
    return value


def _command(*arguments: str, timeout: int = 5) -> str:
    try:
        result = subprocess.run(
            list(arguments),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=SAFE_ENVIRONMENT,
            timeout=timeout,
            check=False,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ObservationError(f"read-only command failed: {arguments[0]}") from exc
    if result.returncode != 0:
        fail(f"read-only command returned failure: {arguments[0]}")
    return result.stdout.rstrip("\n")


def _systemd_properties(unit: str, names: tuple[str, ...]) -> dict[str, str]:
    return {
        name: _command(
            "/usr/bin/systemctl", "show", f"--property={name}", "--value", unit
        )
        for name in names
    }


def _validate_fstab_and_data_unit(
    authority: dict[str, Any], fstab_raw: bytes
) -> None:
    try:
        text = fstab_raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ObservationError("/etc/fstab is not UTF-8") from exc
    entries: list[list[str]] = []
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) == 6 and fields[1] == "/data":
            entries.append(fields)
    if len(entries) != 1:
        fail("/etc/fstab must contain exactly one canonical six-field /data entry")
    source, _, filesystem, options, dump, pass_number = entries[0]
    if (
        filesystem != authority["dataFilesystem"]
        or dump not in {"0", "1"}
        or pass_number not in {"0", "1", "2"}
    ):
        fail("/etc/fstab /data filesystem or fsck fields differ from policy")
    option_list = options.split(",")
    option_set = set(option_list)
    # This is deliberately narrower than the mounted-filesystem verifier.
    # Before any mount exists, aliases such as defaults/nofail/auto and
    # x-systemd.* can change boot/dependency semantics, while opposite pairs
    # (rw,ro; nodev,dev; nosuid,suid; noexec,exec) are order-dependent.  Accept
    # only the four reviewed tokens, once each.
    expected_fstab_options = (
        REQUIRED_OPTIONS if authority["schemaVersion"] == 2 else V3_FSTAB_OPTIONS
    )
    if (
        len(option_list) != len(expected_fstab_options)
        or len(option_set) != len(option_list)
        or option_set != expected_fstab_options
    ):
        fail("/etc/fstab /data options are not the exact reviewed pre-mount set")
    uuid = authority["dataUuid"]
    allowed_sources = (
        {authority["dataSource"], f"UUID={uuid}", f"/dev/disk/by-uuid/{uuid}"}
        if authority["schemaVersion"] == 2
        else {f"UUID={uuid}"}
    )
    if source not in allowed_sources:
        fail("/etc/fstab /data source differs from storage authority")

    properties = _systemd_properties(
        "data.mount",
        (
            "LoadState",
            "SourcePath",
            "FragmentPath",
            "DropInPaths",
            "Where",
            "What",
            "Options",
        ),
    )
    if properties["LoadState"] != "loaded" or properties["SourcePath"] != "/etc/fstab":
        fail("data.mount is not a loaded /etc/fstab-generated unit")
    fragment = Path(properties["FragmentPath"])
    if not re.fullmatch(
        r"/run/systemd/generator(?:\.early|\.late)?/data[.]mount", str(fragment)
    ):
        fail("data.mount fragment is not from the systemd fstab generator")
    _read_regular(fragment, exact_mode=None, maximum=64 * 1024)
    if properties["DropInPaths"] or properties["Where"] != "/data":
        fail("data.mount has a drop-in or unexpected target")
    if properties["What"] not in allowed_sources:
        fail("loaded data.mount source differs from storage authority")
    unit_option_list = properties["Options"].split(",")
    unit_options = set(unit_option_list)
    if (
        len(unit_option_list) != len(REQUIRED_OPTIONS)
        or len(unit_options) != len(unit_option_list)
        or unit_options != REQUIRED_OPTIONS
    ):
        fail("loaded data.mount options differ from the exact pre-mount policy")


def _observer_device(unit_raw: bytes, authority: dict[str, Any]) -> str | None:
    try:
        text = unit_raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ObservationError("observer unit is not UTF-8") from exc
    devices = re.findall(r"(?m)^DeviceAllow=(\S+) r$", text)
    if authority["schemaVersion"] == 2:
        if (
            len(devices) != 1
            or not MD_RESOLVED_SOURCE_RE.fullmatch(devices[0])
            or text != render_observer_unit(devices[0])
        ):
            fail("legacy observer differs from the single-md-device sandbox")
        return devices[0]
    if devices or text != render_observer_unit(None):
        fail("v3 observer must use the fixed stat/sysfs-only sandbox")
    return None


def _validate_loaded_observer_unit() -> None:
    properties = _systemd_properties(
        "uten-imp-storage-observer.service",
        (
            "LoadState",
            "FragmentPath",
            "DropInPaths",
            "User",
            "UnitFileState",
            "DevicePolicy",
            "PrivateDevices",
            "PrivateNetwork",
            "ExecStart",
        ),
    )
    if (
        properties["LoadState"] != "loaded"
        or properties["FragmentPath"] != str(OBSERVER_UNIT_PATH)
        or properties["DropInPaths"]
        or properties["User"] not in {"", "root"}
        or properties["UnitFileState"] != "static"
        or properties["DevicePolicy"] != "closed"
        or properties["PrivateDevices"] != "no"
        or properties["PrivateNetwork"] != "yes"
        or str(HELPER_PATH) not in properties["ExecStart"]
        or " observe" not in properties["ExecStart"]
    ):
        fail("loaded observer service differs from the fixed no-drop-in device policy")


def _directory_descriptor(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    if not hasattr(os, "O_NOFOLLOW"):
        fail("platform lacks no-follow directory opens")
    flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise ObservationError(f"runtime evidence directory is unavailable: {path}") from exc
    details = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(details.st_mode)
        or details.st_uid != 0
        or details.st_gid != 0
        or stat.S_IMODE(details.st_mode) != 0o750
    ):
        os.close(descriptor)
        fail(f"runtime evidence directory metadata is unsafe: {path}")
    return descriptor


def _atomic_object(path: Path, value: dict[str, Any]) -> None:
    raw = (
        json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("ascii")
    if len(raw) > MAX_JSON_BYTES:
        fail("runtime evidence exceeds size policy")
    parent_fd = _directory_descriptor(path.parent)
    temporary = f".{path.name}.{secrets.token_hex(12)}"
    descriptor: int | None = None
    try:
        if os.path.lexists(path):
            _read_regular(path, exact_mode=0o600, maximum=MAX_JSON_BYTES)
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | os.O_NOFOLLOW
        )
        descriptor = os.open(temporary, flags, 0o600, dir_fd=parent_fd)
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(raw):
            written = os.write(descriptor, raw[offset:])
            if written <= 0:
                fail("runtime evidence write made no progress")
            offset += written
        os.fsync(descriptor)
        details = os.fstat(descriptor)
        if (
            details.st_uid != 0
            or details.st_gid != 0
            or details.st_nlink != 1
            or stat.S_IMODE(details.st_mode) != 0o600
        ):
            fail("prepared runtime evidence metadata is unsafe")
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    except OSError as exc:
        raise ObservationError(f"cannot publish runtime evidence: {path}") from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass
        finally:
            os.close(parent_fd)


def _unlink_evidence(path: Path) -> None:
    _read_regular(path, exact_mode=0o600, maximum=MAX_JSON_BYTES)
    parent_fd = _directory_descriptor(path.parent)
    try:
        os.unlink(path.name, dir_fd=parent_fd)
        os.fsync(parent_fd)
    except OSError as exc:
        raise ObservationError(f"cannot consume runtime evidence: {path}") from exc
    finally:
        os.close(parent_fd)


REQUEST_COMMON_KEYS = {
    "authoritySha256",
    "bootId",
    "dataFilesystem",
    "dataSource",
    "dataUuid",
    "expiresAtBoottimeNs",
    "fstabSha256",
    "helperSha256",
    "nonce",
    "observerUnitSha256",
    "requestedAtBoottimeNs",
    "schemaVersion",
}
V1_REQUEST_KEYS = REQUEST_COMMON_KEYS | {"deviceAllowPath"}
V2_REQUEST_KEYS = REQUEST_COMMON_KEYS | {"topology"}
V1_RECEIPT_KEYS = V1_REQUEST_KEYS | {
    "deviceRdev",
    "mdActiveDevices",
    "mdExpectedDevices",
    "mdLevel",
    "mdName",
    "mdState",
    "observedAtBoottimeNs",
    "resolvedDataSource",
    "status",
}
V2_RECEIPT_KEYS = V2_REQUEST_KEYS | {
    "dataDeviceRdev",
    "dmUuid",
    "lvSizeBytes",
    "namespaceRdev",
    "observedAtBoottimeNs",
    "partitionNumber",
    "partitionRdev",
    "resolvedDataSource",
    "resolvedNamespace",
    "resolvedPartition",
    "rotational",
    "status",
    "transport",
}


def _validate_request(value: dict[str, Any]) -> None:
    version = value.get("schemaVersion")
    if isinstance(version, bool) or version not in {1, 2}:
        fail("storage observation request schema is unsupported")
    _exact_keys(
        value,
        V1_REQUEST_KEYS if version == 1 else V2_REQUEST_KEYS,
        "storage observation request",
    )
    for key, expression in (
        ("nonce", NONCE_RE),
        ("bootId", BOOT_ID_RE),
        ("authoritySha256", SHA256_RE),
        ("fstabSha256", SHA256_RE),
        ("helperSha256", SHA256_RE),
        ("observerUnitSha256", SHA256_RE),
        ("dataUuid", UUID_RE),
    ):
        item = value.get(key)
        if not isinstance(item, str) or not expression.fullmatch(item):
            fail(f"storage observation request {key} is malformed")
    source = value.get("dataSource")
    if version == 1:
        if (
            not isinstance(source, str)
            or not MD_AUTHORITY_SOURCE_RE.fullmatch(source)
            or not isinstance(value.get("deviceAllowPath"), str)
            or not MD_RESOLVED_SOURCE_RE.fullmatch(value["deviceAllowPath"])
        ):
            fail("legacy storage observation device identity is malformed")
    elif (
        value.get("topology") != "lvm-linear-nvme"
        or not isinstance(source, str)
        or not LVM_AUTHORITY_SOURCE_RE.fullmatch(source)
    ):
        fail("v3 storage observation topology is malformed")
    if value.get("dataFilesystem") not in {"ext4", "xfs"}:
        fail("storage observation request filesystem is unsupported")
    requested = value.get("requestedAtBoottimeNs")
    expires = value.get("expiresAtBoottimeNs")
    if (
        not isinstance(requested, int)
        or isinstance(requested, bool)
        or not isinstance(expires, int)
        or isinstance(expires, bool)
        or requested < 0
        or expires - requested != REQUEST_TTL_NS
    ):
        fail("storage observation request time window is malformed")


def prepare_request() -> None:
    authority_raw = _read_regular(
        AUTHORITY_PATH, exact_mode=0o640, maximum=MAX_JSON_BYTES
    )
    authority = _authority(authority_raw)
    fstab_raw = _read_regular(FSTAB_PATH, exact_mode=None, maximum=MAX_FSTAB_BYTES)
    _validate_fstab_and_data_unit(authority, fstab_raw)
    helper_raw = _read_regular(HELPER_PATH, exact_mode=0o644, maximum=MAX_HELPER_BYTES)
    unit_raw = _read_regular(
        OBSERVER_UNIT_PATH, exact_mode=0o644, maximum=MAX_JSON_BYTES
    )
    device_allow = _observer_device(unit_raw, authority)
    _validate_loaded_observer_unit()

    if os.path.lexists(RECEIPT_PATH):
        _unlink_evidence(RECEIPT_PATH)
    requested = _boottime_ns()
    request: dict[str, Any] = {
        "authoritySha256": _sha256(authority_raw),
        "bootId": _boot_id(),
        "dataFilesystem": authority["dataFilesystem"],
        "dataSource": authority["dataSource"],
        "dataUuid": authority["dataUuid"],
        "expiresAtBoottimeNs": requested + REQUEST_TTL_NS,
        "fstabSha256": _sha256(fstab_raw),
        "helperSha256": _sha256(helper_raw),
        "nonce": secrets.token_hex(32),
        "observerUnitSha256": _sha256(unit_raw),
        "requestedAtBoottimeNs": requested,
        "schemaVersion": 1 if authority["schemaVersion"] == 2 else 2,
    }
    if authority["schemaVersion"] == 2:
        request["deviceAllowPath"] = device_allow
    else:
        request["topology"] = authority["topology"]
    _atomic_object(REQUEST_PATH, request)


def _current_contract() -> tuple[dict[str, Any], bytes, bytes, bytes, bytes]:
    authority_raw = _read_regular(
        AUTHORITY_PATH, exact_mode=0o640, maximum=MAX_JSON_BYTES
    )
    authority = _authority(authority_raw)
    fstab_raw = _read_regular(FSTAB_PATH, exact_mode=None, maximum=MAX_FSTAB_BYTES)
    helper_raw = _read_regular(HELPER_PATH, exact_mode=0o644, maximum=MAX_HELPER_BYTES)
    unit_raw = _read_regular(
        OBSERVER_UNIT_PATH, exact_mode=0o644, maximum=MAX_JSON_BYTES
    )
    _observer_device(unit_raw, authority)
    return authority, authority_raw, fstab_raw, helper_raw, unit_raw


def _request_and_contract() -> tuple[dict[str, Any], dict[str, Any]]:
    request = _strict_object(
        _read_regular(REQUEST_PATH, exact_mode=0o600, maximum=MAX_JSON_BYTES),
        "storage observation request",
    )
    _validate_request(request)
    authority, authority_raw, fstab_raw, helper_raw, unit_raw = _current_contract()
    if request["bootId"] != _boot_id():
        fail("storage observation request belongs to another boot")
    now = _boottime_ns()
    if now < request["requestedAtBoottimeNs"] or now > request["expiresAtBoottimeNs"]:
        fail("storage observation request is outside its short validity window")
    expected = {
        "authoritySha256": _sha256(authority_raw),
        "dataFilesystem": authority["dataFilesystem"],
        "dataSource": authority["dataSource"],
        "dataUuid": authority["dataUuid"],
        "fstabSha256": _sha256(fstab_raw),
        "helperSha256": _sha256(helper_raw),
        "observerUnitSha256": _sha256(unit_raw),
    }
    for key, item in expected.items():
        if request.get(key) != item:
            fail(f"storage observation request no longer matches {key}")
    device_allow = _observer_device(unit_raw, authority)
    expected_request_schema = 1 if authority["schemaVersion"] == 2 else 2
    if request["schemaVersion"] != expected_request_schema:
        fail("storage observation request no longer matches authority generation")
    if expected_request_schema == 1:
        if request["deviceAllowPath"] != device_allow:
            fail("storage observation request no longer matches DeviceAllow")
    elif request["topology"] != authority["topology"] or device_allow is not None:
        fail("storage observation request no longer matches v3 topology")
    return request, authority


def _block_stat(path: Path) -> os.stat_result:
    try:
        details = path.stat()
    except OSError as exc:
        raise ObservationError(f"approved data device is unavailable: {path}") from exc
    if not stat.S_ISBLK(details.st_mode):
        fail(f"approved data device is not a block device: {path}")
    return details


def _rdev_text(details: os.stat_result) -> str:
    return f"{os.major(details.st_rdev)}:{os.minor(details.st_rdev)}"


def _read_sysfs(path: Path, label: str) -> str:
    try:
        value = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise ObservationError(f"{label} is unavailable") from exc
    if not value:
        fail(f"{label} is empty")
    return value


def _observe_lvm_nvme(
    request: dict[str, Any], authority: dict[str, Any]
) -> dict[str, Any]:
    resolved_data = os.path.realpath(authority["dataSource"])
    resolved_partition = os.path.realpath(authority["nvme"]["partitionById"])
    resolved_namespace = os.path.realpath(authority["nvme"]["namespaceById"])
    partition_match = re.fullmatch(r"/dev/(nvme\d+n\d+)p([1-9][0-9]*)", resolved_partition)
    if (
        not DM_RESOLVED_SOURCE_RE.fullmatch(resolved_data)
        or not re.fullmatch(r"/dev/nvme\d+n\d+", resolved_namespace)
        or partition_match is None
        or f"/dev/{partition_match.group(1)}" != resolved_namespace
        or int(partition_match.group(2)) != authority["nvme"]["partitionNumber"]
    ):
        fail("stable LVM/NVMe paths do not resolve to the approved topology")

    data_stats = [
        _block_stat(Path(authority["dataSource"])),
        _block_stat(Path(resolved_data)),
        _block_stat(Path("/dev/disk/by-uuid") / authority["dataUuid"]),
    ]
    if len({item.st_rdev for item in data_stats}) != 1:
        fail("mapper, dm node and filesystem UUID identify different devices")
    partition_stats = [
        _block_stat(Path(authority["nvme"]["partitionById"])),
        _block_stat(Path(resolved_partition)),
    ]
    namespace_stats = [
        _block_stat(Path(authority["nvme"]["namespaceById"])),
        _block_stat(Path(resolved_namespace)),
    ]
    if len({item.st_rdev for item in partition_stats}) != 1 or len(
        {item.st_rdev for item in namespace_stats}
    ) != 1:
        fail("stable NVMe by-id paths changed identity")

    data_sysfs = SYS_DEV_BLOCK / _rdev_text(data_stats[0])
    partition_sysfs = SYS_DEV_BLOCK / _rdev_text(partition_stats[0])
    namespace_sysfs = SYS_DEV_BLOCK / _rdev_text(namespace_stats[0])
    dm_uuid = _read_sysfs(data_sysfs / "dm/uuid", "device-mapper UUID")
    if dm_uuid != authority["lvm"]["dmUuid"]:
        fail("device-mapper UUID differs from storage authority")
    lv_size = int(_read_sysfs(data_sysfs / "size", "logical-volume size")) * 512
    if lv_size != authority["lvm"]["lvSizeBytes"]:
        fail("logical-volume size differs from storage authority")
    slaves_root = data_sysfs / "slaves"
    try:
        slaves = list(slaves_root.iterdir())
    except OSError as exc:
        raise ObservationError("logical-volume slave topology is unavailable") from exc
    if len(slaves) != 1 or _block_stat(Path("/dev") / slaves[0].name).st_rdev != partition_stats[0].st_rdev:
        fail("logical volume is not backed by the sole approved NVMe partition")
    partition_number = int(
        _read_sysfs(partition_sysfs / "partition", "NVMe partition number")
    )
    rotational = int(
        _read_sysfs(namespace_sysfs / "queue/rotational", "NVMe rotational flag")
    )
    if partition_number != authority["nvme"]["partitionNumber"] or rotational != 0:
        fail("NVMe partition metadata differs from storage authority")

    observed = _boottime_ns()
    if observed > request["expiresAtBoottimeNs"]:
        fail("storage observation expired before evidence publication")
    receipt = dict(request)
    receipt.update(
        {
            "dataDeviceRdev": _rdev_text(data_stats[0]),
            "dmUuid": dm_uuid,
            "lvSizeBytes": lv_size,
            "namespaceRdev": _rdev_text(namespace_stats[0]),
            "observedAtBoottimeNs": observed,
            "partitionNumber": partition_number,
            "partitionRdev": _rdev_text(partition_stats[0]),
            "resolvedDataSource": resolved_data,
            "resolvedNamespace": resolved_namespace,
            "resolvedPartition": resolved_partition,
            "rotational": False,
            "status": "eligible-for-data-mount",
            "transport": "nvme",
        }
    )
    return receipt


def _md_health(md_name: str) -> tuple[str, int, int, str]:
    try:
        text = MDSTAT_PATH.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as exc:
        raise ObservationError("/proc/mdstat is unavailable") from exc
    blocks = {
        match.group(1): match.group(0)
        for match in re.finditer(
            r"(?ms)^(md\d+)\s*:\s*active\b.*?(?=^md\d+\s*:|^unused devices:|\Z)",
            text,
        )
    }
    block = blocks.get(md_name)
    if block is None or re.search(
        r"(?:resync|recovery|reshape|check|repair)\s*=", block
    ):
        fail("approved md array is absent or busy")
    level = re.search(r"^md\d+\s*:\s*active\s+(raid(?:1|5|6|10))\b", block)
    counts = re.search(r"\[(\d+)/(\d+)\]", block)
    state_match = re.search(r"\[([U_]+)\]", block)
    if level is None or counts is None or state_match is None:
        fail("approved md array health is incomplete")
    expected = int(counts.group(1))
    active = int(counts.group(2))
    state_value = state_match.group(1)
    if (
        expected < 2
        or expected != active
        or "_" in state_value
        or len(state_value) != expected
    ):
        fail("approved md array is degraded or lacks complete redundancy")
    return level.group(1), active, expected, state_value


def observe() -> None:
    request, authority = _request_and_contract()
    if os.path.lexists(RECEIPT_PATH):
        prior = _strict_object(
            _read_regular(RECEIPT_PATH, exact_mode=0o600, maximum=MAX_JSON_BYTES),
            "prior storage observation receipt",
        )
        if prior.get("nonce") == request["nonce"]:
            fail("storage observation request was already used")

    if request["schemaVersion"] == 2:
        _atomic_object(RECEIPT_PATH, _observe_lvm_nvme(request, authority))
        return

    resolved = os.path.realpath(authority["dataSource"])
    if (
        not MD_RESOLVED_SOURCE_RE.fullmatch(resolved)
        or resolved != request["deviceAllowPath"]
    ):
        fail("approved md source does not resolve to the sole DeviceAllow node")
    uuid_path = Path("/dev/disk/by-uuid") / authority["dataUuid"]
    device_stats = [
        _block_stat(Path(authority["dataSource"])),
        _block_stat(Path(resolved)),
        _block_stat(uuid_path),
    ]
    if len({details.st_rdev for details in device_stats}) != 1:
        fail("authority, resolved md node and UUID link identify different devices")
    rdev = _rdev_text(device_stats[0])
    lsblk = _command(
        "/usr/bin/lsblk",
        "--nodeps",
        "--noheadings",
        "--raw",
        "--output",
        "TYPE,MAJ:MIN,UUID,FSTYPE",
        resolved,
    ).split()
    if (
        len(lsblk) != 4
        or not re.fullmatch(r"raid(?:1|5|6|10)", lsblk[0])
        or lsblk[1] != rdev
        or lsblk[2].lower() != authority["dataUuid"]
        or lsblk[3] != authority["dataFilesystem"]
    ):
        fail("lsblk cannot prove the approved read-only md device identity")
    md_name = Path(resolved).name
    level, active, expected, md_state = _md_health(md_name)
    if level != lsblk[0]:
        fail("lsblk and /proc/mdstat disagree on RAID level")
    observed = _boottime_ns()
    if observed > request["expiresAtBoottimeNs"]:
        fail("storage observation expired before evidence publication")
    receipt = dict(request)
    receipt.update(
        {
            "deviceRdev": rdev,
            "mdActiveDevices": active,
            "mdExpectedDevices": expected,
            "mdLevel": level,
            "mdName": md_name,
            "mdState": md_state,
            "observedAtBoottimeNs": observed,
            "resolvedDataSource": resolved,
            "status": "eligible-for-data-mount",
        }
    )
    _atomic_object(RECEIPT_PATH, receipt)


def _validate_receipt(
    value: dict[str, Any], request: dict[str, Any], authority: dict[str, Any]
) -> None:
    request_keys = V1_REQUEST_KEYS if request["schemaVersion"] == 1 else V2_REQUEST_KEYS
    receipt_keys = V1_RECEIPT_KEYS if request["schemaVersion"] == 1 else V2_RECEIPT_KEYS
    _exact_keys(value, receipt_keys, "storage observation receipt")
    for key in request_keys:
        if value.get(key) != request.get(key):
            fail(f"storage observation receipt does not bind request field {key}")
    if value.get("status") != "eligible-for-data-mount":
        fail("storage observation receipt is not an eligibility proof")
    observed = value.get("observedAtBoottimeNs")
    if (
        not isinstance(observed, int)
        or isinstance(observed, bool)
        or observed < request["requestedAtBoottimeNs"]
        or observed > request["expiresAtBoottimeNs"]
    ):
        fail("storage observation receipt freshness is invalid")
    if request["schemaVersion"] == 2:
        for key in ("dataDeviceRdev", "namespaceRdev", "partitionRdev"):
            item = value.get(key)
            if not isinstance(item, str) or not RDEV_RE.fullmatch(item):
                fail(f"v3 storage observation receipt {key} is malformed")
        if (
            not isinstance(value.get("resolvedDataSource"), str)
            or not DM_RESOLVED_SOURCE_RE.fullmatch(value["resolvedDataSource"])
            or not isinstance(value.get("resolvedPartition"), str)
            or not re.fullmatch(r"/dev/nvme\d+n\d+p[1-9][0-9]*", value["resolvedPartition"])
            or not isinstance(value.get("resolvedNamespace"), str)
            or not re.fullmatch(r"/dev/nvme\d+n\d+", value["resolvedNamespace"])
        ):
            fail("v3 storage observation receipt resolved identity is malformed")
        if (
            not isinstance(value.get("dmUuid"), str)
            or not DM_UUID_RE.fullmatch(value["dmUuid"])
            or isinstance(value.get("lvSizeBytes"), bool)
            or not isinstance(value.get("lvSizeBytes"), int)
            or value["lvSizeBytes"] < 200 * 1024**3
            or isinstance(value.get("partitionNumber"), bool)
            or not isinstance(value.get("partitionNumber"), int)
            or value["partitionNumber"] < 1
            or value.get("rotational") is not False
            or value.get("transport") != "nvme"
            or value.get("dmUuid") != authority["lvm"]["dmUuid"]
            or value.get("lvSizeBytes") != authority["lvm"]["lvSizeBytes"]
            or value.get("partitionNumber") != authority["nvme"]["partitionNumber"]
        ):
            fail("v3 storage observation receipt topology is malformed")
        return

    if value.get("resolvedDataSource") != request["deviceAllowPath"]:
        fail("storage observation receipt escaped the sole DeviceAllow node")
    for key, expression in (
        ("deviceRdev", RDEV_RE),
        ("mdName", re.compile(r"md\d+")),
        ("mdLevel", re.compile(r"raid(?:1|5|6|10)")),
        ("mdState", re.compile(r"U{2,}")),
    ):
        item = value.get(key)
        if not isinstance(item, str) or not expression.fullmatch(item):
            fail(f"storage observation receipt {key} is malformed")
    if value["mdName"] != Path(value["resolvedDataSource"]).name:
        fail("storage observation receipt md name differs from the resolved source")
    active = value.get("mdActiveDevices")
    expected = value.get("mdExpectedDevices")
    if (
        not isinstance(active, int)
        or isinstance(active, bool)
        or not isinstance(expected, int)
        or isinstance(expected, bool)
        or active < 2
        or active != expected
        or len(value["mdState"]) != expected
    ):
        fail("storage observation receipt health or freshness is invalid")


def verify_and_consume() -> None:
    request, authority = _request_and_contract()
    receipt = _strict_object(
        _read_regular(RECEIPT_PATH, exact_mode=0o600, maximum=MAX_JSON_BYTES),
        "storage observation receipt",
    )
    _validate_receipt(receipt, request, authority)
    if _boottime_ns() > request["expiresAtBoottimeNs"]:
        fail("storage observation receipt expired before consumption")
    # Delete the receipt first.  A crash then leaves only a request that cannot
    # authorize a mount; the next watchdog run replaces it with a fresh nonce.
    _unlink_evidence(RECEIPT_PATH)
    _unlink_evidence(REQUEST_PATH)


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    try:
        if arguments == ["prepare-request"]:
            prepare_request()
        elif arguments == ["observe"]:
            observe()
        elif arguments == ["verify-and-consume"]:
            verify_and_consume()
        else:
            fail(
                "usage: storage_mount_observer.py "
                "{prepare-request|observe|verify-and-consume}"
            )
    except Exception as exc:
        print(f"STORAGE_MOUNT_OBSERVATION_NO_GO: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
