#!/usr/bin/env python3
"""Read-only host stability monitor for the ERP and single-node website hosts.

This process never starts/stops a unit, mounts a filesystem, starts a SMART
self-test, renews a certificate, or changes time.  Site-specific identities and
thresholds come only from the reviewed root-owned policy.  Its normalized
report is recorded into the durable alert spool before the oneshot succeeds.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import ssl
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable


try:
    # Production execution is deliberately possible only through the reviewed
    # runtime launcher.  It captures every sibling through stable O_NOFOLLOW
    # descriptors, verifies the embedded digests, and preloads these exact
    # module objects before compiling this file from the captured bytes.
    common = sys.modules["uten_imp_monitoring_common"]
    alert_spool = sys.modules["uten_imp_monitoring_alert_spool"]
except KeyError as exc:  # pragma: no cover - launcher/contract tests exercise it.
    raise RuntimeError(
        "host monitor must be executed through monitor_runtime_launcher.py"
    ) from exc


DEFAULT_POLICY = Path("/etc/uten-imp-monitoring/host-policy.json")
DEFAULT_HARDWARE_AUTHORITY = Path(
    "/etc/uten-imp-monitoring/storage-hardware-authority.json"
)
ERP_STORAGE_AUTHORITY = Path("/etc/uten-imp/storage-authority.json")
DEFAULT_STATE = Path("/var/lib/uten-imp-monitoring")
DEFAULT_REPORT = DEFAULT_STATE / "host-latest.json"
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
MDSTAT = Path("/proc/mdstat")
SYS_BLOCK = Path("/sys/block")
SYS_DEV_BLOCK = Path("/sys/dev/block")
JOURNAL_DIRECTORY = Path("/var/log/journal")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MD_UUID = re.compile(r"^[0-9a-f]{8}(?::[0-9a-f]{8}){3}$")
HOSTNAME = re.compile(
    r"^(?=.{1,253}\.?$)(?:\*\.)?(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.?$"
)
UNIT_NAME = re.compile(r"^[A-Za-z0-9_.@:-]+\.(?:service|timer|mount)$")
ALLOWED_MOUNT_PATHS = {
    "/data",
    "/var/lib/uten-website",
    "/var/backups/uten-website",
}
ALLOWED_UNIT_FILE_STATES = {
    "enabled",
    "enabled-runtime",
    "linked",
    "linked-runtime",
    "static",
    "indirect",
    "disabled",
    "masked",
    "masked-runtime",
}
ALLOWED_ACTIVE_STATES = {
    "active",
    "inactive",
    "activating",
    "deactivating",
    "failed",
}
COMMAND = Callable[[list[str], int, Iterable[int]], Any]


class HostMonitorError(common.MonitoringError):
    """Host monitor policy or observation error."""


def _exact_dict(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise HostMonitorError(f"{label} schema differs")
    return value


def _integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < minimum
        or value > maximum
    ):
        raise HostMonitorError(f"{label} is outside the accepted range")
    return value


def _number(value: Any, label: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise HostMonitorError(f"{label} is not numeric")
    result = float(value)
    if not minimum <= result <= maximum:
        raise HostMonitorError(f"{label} is outside the accepted range")
    return result


def _validate_journald(value: Any) -> dict[str, Any]:
    result = _exact_dict(
        value,
        {
            "dropInPath",
            "dropInSha256",
            "maximumUseBytes",
            "minimumKeepFreeBytes",
            "maximumFileBytes",
            "maximumRetentionSeconds",
            "requireJournalFiles",
        },
        "journald policy",
    )
    if result["dropInPath"] != "/etc/systemd/journald.conf.d/60-uten-imp.conf":
        raise HostMonitorError("journald drop-in path is not fixed")
    if not isinstance(result["dropInSha256"], str) or not SHA256.fullmatch(
        result["dropInSha256"]
    ):
        raise HostMonitorError("journald drop-in digest is invalid")
    _integer(result["maximumUseBytes"], "journald maximum use", 64 * 1024**2, 64 * 1024**3)
    _integer(
        result["minimumKeepFreeBytes"],
        "journald minimum keep-free",
        256 * 1024**2,
        1024**4,
    )
    _integer(result["maximumFileBytes"], "journald maximum file", 8 * 1024**2, 4 * 1024**3)
    _integer(
        result["maximumRetentionSeconds"],
        "journald maximum retention",
        86400,
        366 * 86400,
    )
    if not isinstance(result["requireJournalFiles"], bool):
        raise HostMonitorError("journald requireJournalFiles is not boolean")
    return result


def _validate_ntp(value: Any) -> dict[str, Any]:
    result = _exact_dict(
        value,
        {
            "provider",
            "serviceUnit",
            "maximumAbsoluteOffsetMilliseconds",
            "maximumRootDistanceMilliseconds",
        },
        "NTP policy",
    )
    allowed = {
        "systemd-timesyncd": "systemd-timesyncd.service",
        "chrony": "chrony.service",
    }
    if result["provider"] not in allowed or result["serviceUnit"] != allowed[result["provider"]]:
        raise HostMonitorError("NTP provider and service unit differ")
    _number(
        result["maximumAbsoluteOffsetMilliseconds"],
        "maximum NTP offset",
        0.1,
        60_000,
    )
    _number(
        result["maximumRootDistanceMilliseconds"],
        "maximum NTP root distance",
        1,
        300_000,
    )
    return result


def _validate_hardware(value: Any) -> dict[str, Any]:
    result = _exact_dict(
        value, {"mode", "authorityPath", "authoritySha256"}, "hardware policy"
    )
    if result["mode"] not in {"local-md-smart", "local-lvm-nvme", "provider-managed"}:
        raise HostMonitorError("hardware mode is unsupported")
    if result["mode"] == "provider-managed":
        if result["authorityPath"] is not None or result["authoritySha256"] is not None:
            raise HostMonitorError("provider-managed hardware must not invent local authority")
        return result
    if result["authorityPath"] != str(DEFAULT_HARDWARE_AUTHORITY):
        raise HostMonitorError("local hardware authority path is not fixed")
    if not isinstance(result["authoritySha256"], str) or not SHA256.fullmatch(
        result["authoritySha256"]
    ):
        raise HostMonitorError("local hardware authority digest is invalid")
    return result


def validate_hardware_authority(value: Any) -> dict[str, Any]:
    authority_format = value.get("format") if isinstance(value, dict) else None
    expected_keys = (
        {"format", "erpStorageAuthorityPath", "erpStorageAuthoritySha256", "raid", "smart"}
        if authority_format == "uten-imp-monitor-storage-hardware-authority-v1"
        else {"format", "erpStorageAuthorityPath", "erpStorageAuthoritySha256", "smart"}
    )
    result = _exact_dict(
        value,
        expected_keys,
        "storage hardware authority",
    )
    if result["format"] not in {
        "uten-imp-monitor-storage-hardware-authority-v1",
        "uten-imp-monitor-storage-hardware-authority-v2",
    }:
        raise HostMonitorError("storage hardware authority format differs")
    if result["erpStorageAuthorityPath"] != str(ERP_STORAGE_AUTHORITY):
        raise HostMonitorError("ERP storage authority binding path differs")
    if not isinstance(result["erpStorageAuthoritySha256"], str) or not SHA256.fullmatch(
        result["erpStorageAuthoritySha256"]
    ):
        raise HostMonitorError("ERP storage authority binding digest is invalid")
    if result["format"].endswith("v1"):
        raid = _exact_dict(
            result["raid"],
            {
                "mdName",
                "expectedLevel",
                "expectedUuid",
                "filesystemUuid",
                "minimumDevices",
            },
            "RAID policy",
        )
        if not re.fullmatch(r"md\d+", str(raid["mdName"])):
            raise HostMonitorError("RAID name is not canonical")
        if raid["expectedLevel"] not in {"raid1", "raid5", "raid6", "raid10"}:
            raise HostMonitorError("RAID level is unsupported")
        if not isinstance(raid["expectedUuid"], str) or not MD_UUID.fullmatch(
            raid["expectedUuid"]
        ):
            raise HostMonitorError("RAID UUID is invalid")
        if not isinstance(raid["filesystemUuid"], str) or not re.fullmatch(
            r"[0-9a-f-]{8,64}", raid["filesystemUuid"]
        ):
            raise HostMonitorError("RAID filesystem UUID is invalid")
        _integer(raid["minimumDevices"], "minimum RAID devices", 2, 64)
    if not isinstance(result["smart"], list) or not 1 <= len(result["smart"]) <= 32:
        raise HostMonitorError("SMART device policy is empty or excessive")
    devices: set[str] = set()
    for index, item in enumerate(result["smart"]):
        smart = _exact_dict(
            item,
            {
                "device",
                "serialSha256",
                "maximumTemperatureC",
                "maximumReallocatedSectors",
                "maximumPendingSectors",
                "maximumOfflineUncorrectable",
                "maximumMediaErrors",
                "maximumSelfTestAgeHours",
            },
            f"SMART policy {index}",
        )
        device = smart["device"]
        if not isinstance(device, str) or not re.fullmatch(
            r"/dev/(?:sd[a-z]+|nvme\d+n\d+|disk/by-id/[A-Za-z0-9._:+-]+)", device
        ):
            raise HostMonitorError("SMART device path is unsupported")
        if device in devices:
            raise HostMonitorError("SMART device path is duplicated")
        devices.add(device)
        if not isinstance(smart["serialSha256"], str) or not SHA256.fullmatch(
            smart["serialSha256"]
        ):
            raise HostMonitorError("SMART serial digest is invalid")
        _integer(smart["maximumTemperatureC"], "SMART maximum temperature", 30, 100)
        for key in (
            "maximumReallocatedSectors",
            "maximumPendingSectors",
            "maximumOfflineUncorrectable",
            "maximumMediaErrors",
        ):
            _integer(smart[key], f"SMART {key}", 0, 10**12)
        _integer(smart["maximumSelfTestAgeHours"], "SMART self-test age", 1, 24 * 366)
    return result


def load_hardware_authority(hardware_policy: dict[str, Any]) -> dict[str, Any] | None:
    if hardware_policy["mode"] == "provider-managed":
        return None
    path = Path(hardware_policy["authorityPath"])
    raw, value = common.read_json_file(
        path,
        canonical=True,
        expected_mode=0o640,
        require_root=True,
    )
    if hashlib.sha256(raw).hexdigest() != hardware_policy["authoritySha256"]:
        raise HostMonitorError("storage hardware authority digest differs from policy")
    authority = validate_hardware_authority(value)
    erp_raw = common.read_regular(
        ERP_STORAGE_AUTHORITY,
        maximum=common.MAX_JSON_BYTES,
        expected_mode=0o640,
        require_root=True,
    )
    if hashlib.sha256(erp_raw).hexdigest() != authority["erpStorageAuthoritySha256"]:
        raise HostMonitorError(
            "storage hardware authority no longer binds the live ERP storage authority"
        )
    # Device members are never accepted from a CLI argument, environment
    # variable, glob, or /dev enumeration.  The hardware authority is also
    # generation-matched to the exact hash-bound ERP authority.
    erp_value = common.strict_json(erp_raw, canonical=False)
    if not isinstance(erp_value, dict):
        raise HostMonitorError("ERP storage authority is not an object")
    source = str(erp_value.get("dataSource", ""))
    if hardware_policy["mode"] == "local-md-smart":
        if authority["format"] != "uten-imp-monitor-storage-hardware-authority-v1":
            raise HostMonitorError("md monitor policy requires hardware authority v1")
        if Path(os.path.realpath(source)).name != authority["raid"]["mdName"]:
            raise HostMonitorError("hardware authority md name differs from ERP data source")
        if str(erp_value.get("dataUuid", "")).lower() != authority["raid"]["filesystemUuid"]:
            raise HostMonitorError("hardware authority filesystem UUID differs from ERP authority")
        return authority

    if (
        authority["format"] != "uten-imp-monitor-storage-hardware-authority-v2"
        or erp_value.get("schemaVersion") != 3
        or erp_value.get("topology") != "lvm-linear-nvme"
        or not re.fullmatch(r"/dev/mapper/[A-Za-z0-9_.+~-]+-[A-Za-z0-9_.+~-]+", source)
        or not isinstance(erp_value.get("lvm"), dict)
        or not isinstance(erp_value.get("nvme"), dict)
    ):
        raise HostMonitorError("LVM/NVMe monitor policy requires ERP authority v3")
    smart = authority["smart"]
    if (
        len(smart) != 1
        or smart[0]["device"] != erp_value["nvme"].get("namespaceById")
        or smart[0]["serialSha256"] != erp_value["nvme"].get("serialSha256")
    ):
        raise HostMonitorError("NVMe SMART policy differs from ERP storage authority")
    return {**authority, "erpStorageAuthority": erp_value}


def _validate_filesystems(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value or len(value) > len(ALLOWED_MOUNT_PATHS):
        raise HostMonitorError("filesystem policy list is empty or excessive")
    paths: set[str] = set()
    for item in value:
        filesystem = _exact_dict(
            item,
            {
                "path",
                "expectedSource",
                "expectedUuid",
                "expectedType",
                "requiredOptions",
                "minimumFreeBytes",
                "minimumFreePercent",
                "minimumFreeInodes",
                "minimumFreeInodePercent",
            },
            "filesystem policy",
        )
        path = filesystem["path"]
        if path not in ALLOWED_MOUNT_PATHS or path in paths:
            raise HostMonitorError("filesystem path is unsupported or duplicated")
        paths.add(path)
        if (
            not isinstance(filesystem["expectedSource"], str)
            or not filesystem["expectedSource"].startswith("/dev/")
            or any(character.isspace() for character in filesystem["expectedSource"])
        ):
            raise HostMonitorError("filesystem source is invalid")
        if not isinstance(filesystem["expectedUuid"], str) or not re.fullmatch(
            r"[0-9a-f-]{8,64}", filesystem["expectedUuid"]
        ):
            raise HostMonitorError("filesystem UUID is invalid")
        if filesystem["expectedType"] not in {"ext4", "xfs"}:
            raise HostMonitorError("filesystem type is unsupported")
        if filesystem["requiredOptions"] != ["rw", "nodev", "nosuid", "noexec"]:
            raise HostMonitorError("filesystem options are not the reviewed set")
        _integer(filesystem["minimumFreeBytes"], "minimum free bytes", 1024**3, 1024**5)
        _number(filesystem["minimumFreePercent"], "minimum free percent", 1, 50)
        _integer(filesystem["minimumFreeInodes"], "minimum free inodes", 10_000, 10**12)
        _number(
            filesystem["minimumFreeInodePercent"],
            "minimum free inode percent",
            1,
            50,
        )
    return value


def _validate_certificates(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not 1 <= len(value) <= 16:
        raise HostMonitorError("certificate policy list is empty or excessive")
    seen: set[str] = set()
    for item in value:
        certificate = _exact_dict(
            item,
            {
                "name",
                "path",
                "expectedDnsNames",
                "warningDays",
                "criticalDays",
                "renewal",
            },
            "certificate policy",
        )
        if not isinstance(certificate["name"], str) or not common.ISSUE_CODE.fullmatch(
            certificate["name"]
        ):
            raise HostMonitorError("certificate name is invalid")
        path = certificate["path"]
        if (
            not isinstance(path, str)
            or not path.startswith("/etc/")
            or path in seen
            or ".." in Path(path).parts
        ):
            raise HostMonitorError("certificate path is invalid or duplicated")
        seen.add(path)
        names = certificate["expectedDnsNames"]
        if (
            not isinstance(names, list)
            or not names
            or len(names) > 32
            or any(not isinstance(name, str) or not HOSTNAME.fullmatch(name) for name in names)
        ):
            raise HostMonitorError("certificate DNS name list is invalid")
        warning = _integer(certificate["warningDays"], "certificate warning days", 7, 120)
        critical = _integer(certificate["criticalDays"], "certificate critical days", 1, 60)
        if critical >= warning:
            raise HostMonitorError("certificate critical threshold must precede warning")
        renewal = _exact_dict(
            certificate["renewal"],
            {"timerUnit", "serviceUnit", "maximumLastSuccessAgeSeconds"},
            "certificate renewal policy",
        )
        for key, suffix in (("timerUnit", ".timer"), ("serviceUnit", ".service")):
            if not isinstance(renewal[key], str) or not UNIT_NAME.fullmatch(renewal[key]) or not renewal[key].endswith(suffix):
                raise HostMonitorError("certificate renewal unit is invalid")
        _integer(
            renewal["maximumLastSuccessAgeSeconds"],
            "certificate renewal success age",
            3600,
            366 * 86400,
        )
    return value


def _validate_units(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value or len(value) > 64:
        raise HostMonitorError("unit policy list is empty or excessive")
    names: set[str] = set()
    for item in value:
        unit = _exact_dict(
            item,
            {
                "name",
                "expectedEnabled",
                "expectedActive",
                "requireSuccessfulResult",
                "maximumNRestarts",
                "maximumLastSuccessAgeSeconds",
                "maximumLastTriggerAgeSeconds",
            },
            "unit policy",
        )
        name = unit["name"]
        if not isinstance(name, str) or not UNIT_NAME.fullmatch(name) or name in names:
            raise HostMonitorError("unit name is invalid or duplicated")
        names.add(name)
        enabled = unit["expectedEnabled"]
        active = unit["expectedActive"]
        if (
            not isinstance(enabled, list)
            or not enabled
            or any(item not in ALLOWED_UNIT_FILE_STATES for item in enabled)
            or not isinstance(active, list)
            or not active
            or any(item not in ALLOWED_ACTIVE_STATES for item in active)
        ):
            raise HostMonitorError("unit expected state list is invalid")
        if not isinstance(unit["requireSuccessfulResult"], bool):
            raise HostMonitorError("unit result policy is not boolean")
        _integer(unit["maximumNRestarts"], "unit maximum restart count", 0, 1_000_000)
        for key in ("maximumLastSuccessAgeSeconds", "maximumLastTriggerAgeSeconds"):
            if unit[key] is not None:
                _integer(unit[key], f"unit {key}", 60, 366 * 86400)
    return value


def _validate_postgres(value: Any) -> dict[str, Any]:
    result = _exact_dict(
        value,
        {"enabled", "socketDirectory", "port", "database", "timeoutSeconds"},
        "PostgreSQL probe policy",
    )
    if not isinstance(result["enabled"], bool):
        raise HostMonitorError("PostgreSQL probe enabled is not boolean")
    if result["socketDirectory"] != "/var/run/postgresql" or result["database"] != "uten_imp":
        raise HostMonitorError("PostgreSQL probe endpoint is not the fixed ERP endpoint")
    _integer(result["port"], "PostgreSQL port", 1, 65535)
    _integer(result["timeoutSeconds"], "PostgreSQL timeout", 1, 30)
    return result


def validate_policy(value: Any) -> dict[str, Any]:
    policy = _exact_dict(
        value,
        {
            "format",
            "journald",
            "ntp",
            "hardware",
            "filesystems",
            "certificates",
            "units",
            "postgres",
        },
        "host monitor policy",
    )
    if policy["format"] != "uten-imp-host-monitor-policy-v1":
        raise HostMonitorError("host monitor policy format differs")
    _validate_journald(policy["journald"])
    _validate_ntp(policy["ntp"])
    _validate_hardware(policy["hardware"])
    _validate_filesystems(policy["filesystems"])
    _validate_certificates(policy["certificates"])
    _validate_units(policy["units"])
    _validate_postgres(policy["postgres"])
    return policy


def load_policy(path: Path) -> tuple[bytes, dict[str, Any]]:
    raw, value = common.read_json_file(
        path,
        canonical=True,
        expected_mode=0o644,
        require_root=True,
    )
    return raw, validate_policy(value)


def _command(arguments: list[str], timeout: int = 15, accepted: Iterable[int] = (0,)) -> Any:
    return common.run_command(arguments, timeout=timeout, accepted=accepted)


def _parse_size(value: str) -> int:
    match = re.fullmatch(r"(\d+)([KMGTPE]?)", value.strip(), re.IGNORECASE)
    if match is None:
        raise HostMonitorError(f"unsupported systemd size: {value}")
    exponent = "KMGTPE".find(match.group(2).upper()) + 1 if match.group(2) else 0
    return int(match.group(1)) * 1024**exponent


def _parse_duration_seconds(value: str) -> float:
    units = {
        "us": 0.000001,
        "ms": 0.001,
        "s": 1,
        "min": 60,
        "h": 3600,
        "day": 86400,
        "week": 7 * 86400,
        "month": 30.44 * 86400,
        "year": 365.25 * 86400,
    }
    compact = value.replace(" ", "")
    position = 0
    total = 0.0
    for match in re.finditer(r"(\d+(?:\.\d+)?)(us|ms|s|min|h|day|week|month|year)", compact):
        if match.start() != position:
            raise HostMonitorError(f"unsupported systemd duration: {value}")
        total += float(match.group(1)) * units[match.group(2)]
        position = match.end()
    if position != len(compact) or total <= 0:
        raise HostMonitorError(f"unsupported systemd duration: {value}")
    return total


def _effective_journal_config(raw: str) -> dict[str, str]:
    section = ""
    values: dict[str, str] = {}
    for raw_line in raw.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section == "Journal" and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def inspect_journald(
    policy: dict[str, Any],
    run: COMMAND = _command,
    *,
    journal_directory: Path = JOURNAL_DIRECTORY,
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    issues: list[dict[str, str]] = []
    drop_in = Path(policy["dropInPath"])
    raw = common.read_regular(
        drop_in, maximum=64 * 1024, expected_mode=0o644, require_root=True
    )
    actual_sha = hashlib.sha256(raw).hexdigest()
    if actual_sha != policy["dropInSha256"]:
        issues.append(
            common.issue(
                "journald.drop-in-drift",
                "critical",
                "the reviewed journald capacity/persistence drop-in digest changed",
                "keep the journal intact and review the effective configuration before replacing it",
            )
        )
    result = run(
        ["/usr/bin/systemd-analyze", "cat-config", "systemd/journald.conf"], 15, (0,)
    )
    effective = _effective_journal_config(result.stdout)
    expected_text = {
        "Storage": "persistent",
        "Compress": "yes",
        "Seal": "yes",
    }
    for key, expected in expected_text.items():
        if effective.get(key, "").lower() != expected:
            issues.append(
                common.issue(
                    f"journald.effective-{key.lower()}",
                    "critical",
                    f"effective journald {key} is not {expected}",
                    "review all journald drop-ins and restore the approved effective setting",
                )
            )
    expected_sizes = {
        "SystemMaxUse": policy["maximumUseBytes"],
        "SystemKeepFree": policy["minimumKeepFreeBytes"],
        "SystemMaxFileSize": policy["maximumFileBytes"],
    }
    observed_sizes: dict[str, int | None] = {}
    for key, expected in expected_sizes.items():
        try:
            observed = _parse_size(effective[key])
        except (KeyError, HostMonitorError):
            observed = None
        observed_sizes[key] = observed
        if observed != expected:
            issues.append(
                common.issue(
                    f"journald.effective-{key.lower()}",
                    "critical",
                    f"effective journald {key} differs from the reviewed byte limit",
                    "restore the reviewed bounded journald configuration after capacity approval",
                )
            )
    try:
        retention = _parse_duration_seconds(effective["MaxRetentionSec"])
    except (KeyError, HostMonitorError):
        retention = None
    if retention is None or abs(retention - policy["maximumRetentionSeconds"]) > 1:
        issues.append(
            common.issue(
                "journald.effective-maxretentionsec",
                "critical",
                "effective journald retention differs from the reviewed limit",
                "review all journald drop-ins and restore the approved retention",
            )
        )

    allocated = 0
    regular_files = 0
    if journal_directory.is_symlink() or not journal_directory.is_dir():
        issues.append(
            common.issue(
                "journald.persistent-directory",
                "critical",
                "the persistent journal directory is absent or unsafe",
                "preserve current logs and commission /var/log/journal in an approved host change",
            )
        )
    else:
        for root, directories, files in os.walk(journal_directory, followlinks=False):
            if len(directories) + len(files) > 20_000:
                raise HostMonitorError("journal directory entry budget exceeded")
            root_path = Path(root)
            for directory in list(directories):
                candidate = root_path / directory
                if candidate.is_symlink():
                    issues.append(
                        common.issue(
                            "journald.directory-symlink",
                            "critical",
                            "a symlink exists inside the persistent journal tree",
                            "do not follow it; preserve evidence and investigate filesystem drift",
                        )
                    )
                    directories.remove(directory)
            for filename in files:
                candidate = root_path / filename
                info = candidate.lstat()
                if candidate.is_symlink() or not stat.S_ISREG(info.st_mode):
                    issues.append(
                        common.issue(
                            "journald.non-regular-object",
                            "critical",
                            "a non-regular object exists inside the persistent journal tree",
                            "preserve evidence and investigate the journal filesystem",
                        )
                    )
                    continue
                allocated += info.st_blocks * 512 if hasattr(info, "st_blocks") else info.st_size
                if filename.endswith((".journal", ".journal~")):
                    regular_files += 1
    if policy["requireJournalFiles"] and regular_files == 0:
        issues.append(
            common.issue(
                "journald.no-persistent-files",
                "critical",
                "no persistent journal file was observed",
                "verify systemd-journald flush and persistent storage without deleting current logs",
            )
        )
    if allocated > policy["maximumUseBytes"] + policy["maximumFileBytes"]:
        issues.append(
            common.issue(
                "journald.capacity-exceeded",
                "critical",
                "persistent journal allocation exceeds the configured limit plus one file",
                "investigate journald rotation and root filesystem capacity before vacuuming",
            )
        )
    evidence = {
        "dropInSha256": actual_sha,
        "allocatedBytes": allocated,
        "journalFiles": regular_files,
        "effective": {
            "storage": effective.get("Storage"),
            "compress": effective.get("Compress"),
            "seal": effective.get("Seal"),
            "systemMaxUseBytes": observed_sizes.get("SystemMaxUse"),
            "systemKeepFreeBytes": observed_sizes.get("SystemKeepFree"),
            "systemMaxFileBytes": observed_sizes.get("SystemMaxFileSize"),
            "maxRetentionSeconds": retention,
        },
    }
    return evidence, issues


def _parse_timesync_metric(text: str, label: str) -> float:
    match = re.search(
        rf"(?mi)^\s*{re.escape(label)}:\s*([+-]?\d+(?:\.\d+)?)\s*(us|ms|s)\b",
        text,
    )
    if match is None:
        raise HostMonitorError(f"timedatectl did not report {label}")
    multiplier = {"us": 0.001, "ms": 1.0, "s": 1000.0}[match.group(2)]
    return float(match.group(1)) * multiplier


def _systemctl_show(unit: str, run: COMMAND = _command) -> dict[str, str]:
    names = (
        "LoadState",
        "ActiveState",
        "SubState",
        "UnitFileState",
        "Result",
        "ExecMainStatus",
        "NRestarts",
        "ExecMainExitTimestampMonotonic",
        "LastTriggerUSecMonotonic",
    )
    result = run(
        [
            "/usr/bin/systemctl",
            "show",
            unit,
            "--property=" + ",".join(names),
            "--no-pager",
        ],
        10,
        (0,),
    )
    properties: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            properties[key] = value
    if set(properties) != set(names):
        raise HostMonitorError(f"systemctl properties are incomplete for {unit}")
    return properties


def inspect_ntp(
    policy: dict[str, Any], run: COMMAND = _command
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    issues: list[dict[str, str]] = []
    unit = _systemctl_show(policy["serviceUnit"], run)
    if unit["LoadState"] != "loaded" or unit["ActiveState"] != "active":
        issues.append(
            common.issue(
                "ntp.service-state",
                "critical",
                "the approved NTP synchronization service is not loaded and active",
                "restore the approved provider without setting the clock manually",
            )
        )
    offset_ms: float | None = None
    root_distance_ms: float | None = None
    synchronized = False
    if policy["provider"] == "systemd-timesyncd":
        sync = run(
            ["/usr/bin/timedatectl", "show", "--property=NTPSynchronized", "--value"],
            10,
            (0,),
        ).stdout.strip()
        synchronized = sync == "yes"
        status = run(["/usr/bin/timedatectl", "timesync-status", "--no-pager"], 10, (0,))
        offset_ms = _parse_timesync_metric(status.stdout, "Offset")
        root_distance_ms = abs(_parse_timesync_metric(status.stdout, "Root distance"))
    else:
        tracking = run(["/usr/bin/chronyc", "-j", "tracking"], 10, (0,))
        try:
            value = json.loads(tracking.stdout)
            offset_ms = abs(float(value["system_time"])) * 1000
            root_distance_ms = (
                abs(float(value["root_delay"])) / 2 + abs(float(value["root_dispersion"]))
            ) * 1000
            synchronized = str(value["leap_status"]).lower() == "normal"
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise HostMonitorError("chronyc tracking JSON is incomplete") from exc
    if not synchronized:
        issues.append(
            common.issue(
                "ntp.unsynchronized",
                "critical",
                "the system clock is not synchronized to the approved NTP provider",
                "keep ingress fail-closed and restore trusted time synchronization",
            )
        )
    if offset_ms is None or abs(offset_ms) > policy["maximumAbsoluteOffsetMilliseconds"]:
        issues.append(
            common.issue(
                "ntp.offset",
                "critical",
                "absolute NTP clock offset exceeds the reviewed threshold",
                "investigate the time source and virtualization/RTC state without forcing a production time jump",
            )
        )
    if root_distance_ms is None or root_distance_ms > policy["maximumRootDistanceMilliseconds"]:
        issues.append(
            common.issue(
                "ntp.root-distance",
                "critical",
                "NTP root distance exceeds the reviewed threshold",
                "investigate upstream NTP reachability and clock quality",
            )
        )
    return {
        "provider": policy["provider"],
        "synchronized": synchronized,
        "absoluteOffsetMilliseconds": abs(offset_ms) if offset_ms is not None else None,
        "rootDistanceMilliseconds": root_distance_ms,
    }, issues


def _read_ascii(path: Path, maximum: int = 4096) -> str:
    raw = common.read_regular(path, maximum=maximum, expected_mode=None, require_root=False)
    try:
        return raw.decode("ascii").strip()
    except UnicodeDecodeError as exc:
        raise HostMonitorError(f"kernel observation is not ASCII: {path}") from exc


def inspect_raid(
    policy: dict[str, Any], *, sys_block: Path = SYS_BLOCK, mdstat: Path = MDSTAT
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    issues: list[dict[str, str]] = []
    if policy["mode"] == "provider-managed":
        return {"mode": "provider-managed"}, [
            common.issue(
                "hardware.provider-health-unintegrated",
                "warning",
                "provider-managed disk health is not observable by this host-only probe",
                "bind provider disk/volume health and host-loss alerts to independently delivered evidence",
            )
        ]
    raid = policy["raid"]
    md_name = raid["mdName"]
    root = sys_block / md_name / "md"
    values = {
        key: _read_ascii(root / filename)
        for key, filename in {
            "uuid": "uuid",
            "level": "level",
            "raidDisks": "raid_disks",
            "degraded": "degraded",
            "syncAction": "sync_action",
            "arrayState": "array_state",
            "mismatchCount": "mismatch_cnt",
        }.items()
    }
    try:
        raid_disks = int(values["raidDisks"])
        degraded = int(values["degraded"])
        mismatch = int(values["mismatchCount"])
    except ValueError as exc:
        raise HostMonitorError("RAID sysfs counters are not integers") from exc
    if values["uuid"].lower() != raid["expectedUuid"]:
        issues.append(
            common.issue(
                "raid.identity",
                "critical",
                "the live md array UUID differs from approved authority",
                "stop write-heavy jobs and verify the array through the console",
            )
        )
    if values["level"] != raid["expectedLevel"] or raid_disks < raid["minimumDevices"]:
        issues.append(
            common.issue(
                "raid.shape",
                "critical",
                "the live md level or member count differs from policy",
                "preserve evidence and inspect array assembly before any restart or release",
            )
        )
    if degraded != 0 or values["syncAction"] != "idle" or values["arrayState"] not in {
        "active",
        "clean",
        "clean-idle",
    }:
        issues.append(
            common.issue(
                "raid.health",
                "critical",
                "the md array is degraded, busy, or not in an accepted state",
                "pause releases/backups and complete the storage incident first",
            )
        )
    if mismatch != 0:
        issues.append(
            common.issue(
                "raid.mismatch",
                "critical",
                "the md array reports nonzero mismatch sectors",
                "preserve the count and run an approved disk/array investigation before repair",
            )
        )
    text = _read_ascii(mdstat, maximum=256 * 1024)
    block_match = re.search(
        rf"(?ms)^{re.escape(md_name)}\s*:\s*active\b.*?(?=^md\d+\s*:|^unused devices:|\Z)",
        text,
    )
    if block_match is None:
        raise HostMonitorError("approved md array is absent from /proc/mdstat")
    block = block_match.group(0)
    state_match = re.search(r"\[([U_]+)\]", block)
    busy = re.search(r"(?:resync|recovery|reshape|check|repair)\s*=", block) is not None
    state = state_match.group(1) if state_match else ""
    if busy or not state or "_" in state or len(state) != raid_disks:
        issues.append(
            common.issue(
                "raid.mdstat",
                "critical",
                "/proc/mdstat does not prove an idle fully redundant array",
                "pause releases/backups and inspect the exact array state through the console",
            )
        )
    return {
        "mode": "local-md-smart",
        "mdName": md_name,
        "uuidSha256": hashlib.sha256(values["uuid"].encode("ascii")).hexdigest(),
        "level": values["level"],
        "raidDisks": raid_disks,
        "degraded": degraded,
        "syncAction": values["syncAction"],
        "arrayState": values["arrayState"],
        "mismatchCount": mismatch,
        "mdstatState": state,
    }, issues


def _block_rdev(path: Path, label: str) -> tuple[os.stat_result, str]:
    try:
        details = path.stat()
    except OSError as exc:
        raise HostMonitorError(f"{label} is unavailable") from exc
    if not stat.S_ISBLK(details.st_mode):
        raise HostMonitorError(f"{label} is not a block device")
    return details, f"{os.major(details.st_rdev)}:{os.minor(details.st_rdev)}"


def inspect_lvm_nvme(
    policy: dict[str, Any], *, sys_dev_block: Path = SYS_DEV_BLOCK
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    """Prove the v3 data LV still maps to its sole approved NVMe partition."""

    erp = policy.get("erpStorageAuthority")
    if not isinstance(erp, dict) or erp.get("schemaVersion") != 3:
        raise HostMonitorError("ERP LVM/NVMe authority was not supplied")
    lvm = erp["lvm"]
    nvme = erp["nvme"]
    data, data_rdev = _block_rdev(Path(erp["dataSource"]), "approved data LV")
    uuid_device, _ = _block_rdev(
        Path("/dev/disk/by-uuid") / erp["dataUuid"], "approved data filesystem UUID"
    )
    partition, partition_rdev = _block_rdev(
        Path(nvme["partitionById"]), "approved NVMe partition"
    )
    namespace, namespace_rdev = _block_rdev(
        Path(nvme["namespaceById"]), "approved NVMe namespace"
    )
    if data.st_rdev != uuid_device.st_rdev:
        raise HostMonitorError("data LV and filesystem UUID identify different devices")
    resolved_data = os.path.realpath(erp["dataSource"])
    resolved_partition = os.path.realpath(nvme["partitionById"])
    resolved_namespace = os.path.realpath(nvme["namespaceById"])
    match = re.fullmatch(r"/dev/(nvme\d+n\d+)p([1-9][0-9]*)", resolved_partition)
    if (
        not re.fullmatch(r"/dev/dm-\d+", resolved_data)
        or match is None
        or resolved_namespace != f"/dev/{match.group(1)}"
        or int(match.group(2)) != nvme["partitionNumber"]
    ):
        raise HostMonitorError("stable LVM/NVMe paths resolved outside approved topology")
    data_sysfs = sys_dev_block / data_rdev
    partition_sysfs = sys_dev_block / partition_rdev
    namespace_sysfs = sys_dev_block / namespace_rdev
    dm_uuid = _read_ascii(data_sysfs / "dm/uuid")
    try:
        lv_size = int(_read_ascii(data_sysfs / "size")) * 512
        partition_number = int(_read_ascii(partition_sysfs / "partition"))
        rotational = int(_read_ascii(namespace_sysfs / "queue/rotational"))
    except ValueError as exc:
        raise HostMonitorError("LVM/NVMe sysfs counters are malformed") from exc
    compact_vg = str(lvm["vgUuid"]).replace("-", "")
    compact_lv = str(lvm["lvUuid"]).replace("-", "")
    if (
        dm_uuid != lvm["dmUuid"]
        or dm_uuid != f"LVM-{compact_vg}{compact_lv}"
        or lv_size != lvm["lvSizeBytes"]
        or partition_number != nvme["partitionNumber"]
        or rotational != 0
    ):
        raise HostMonitorError("live LVM/NVMe identity differs from ERP authority")
    try:
        slaves = list((data_sysfs / "slaves").iterdir())
    except OSError as exc:
        raise HostMonitorError("data LV slave topology is unavailable") from exc
    if len(slaves) != 1 or _block_rdev(Path("/dev") / slaves[0].name, "data LV slave")[0].st_rdev != partition.st_rdev:
        raise HostMonitorError("data LV is not backed by the sole approved NVMe partition")
    return {
        "mode": "local-lvm-nvme",
        "dataRdev": data_rdev,
        "dmUuidSha256": hashlib.sha256(dm_uuid.encode("ascii")).hexdigest(),
        "lvSizeBytes": lv_size,
        "namespaceRdev": namespace_rdev,
        "partitionRdev": partition_rdev,
        "partitionNumber": partition_number,
        "rotational": False,
        "transport": "nvme",
    }, []


def _smart_attribute(value: dict[str, Any], attribute_id: int) -> int:
    table = value.get("ata_smart_attributes", {}).get("table", [])
    if not isinstance(table, list):
        return 0
    for item in table:
        if isinstance(item, dict) and item.get("id") == attribute_id:
            raw = item.get("raw", {}).get("value")
            if isinstance(raw, int) and not isinstance(raw, bool):
                return raw
    return 0


def _latest_self_test_age_hours(value: dict[str, Any]) -> tuple[int | None, bool | None]:
    powered = value.get("power_on_time", {}).get("hours")
    table = value.get("ata_smart_self_test_log", {}).get("standard", {}).get("table", [])
    if not isinstance(powered, int):
        return None, None
    if isinstance(table, list) and table:
        latest = table[0]
        lifetime = latest.get("lifetime_hours") if isinstance(latest, dict) else None
        passed = latest.get("status", {}).get("passed") if isinstance(latest, dict) else None
    else:
        nvme_table = value.get("nvme_self_test_log", {}).get("table", [])
        latest = nvme_table[0] if isinstance(nvme_table, list) and nvme_table else None
        lifetime = latest.get("power_on_hours") if isinstance(latest, dict) else None
        result = latest.get("self_test_result", {}).get("value") if isinstance(latest, dict) else None
        passed = result == 0 if isinstance(result, int) and not isinstance(result, bool) else None
    if not isinstance(lifetime, int):
        return None, None
    age = max(0, powered - lifetime)
    return age, passed if isinstance(passed, bool) else None


def inspect_smart_device(
    policy: dict[str, Any], run: COMMAND = _command
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    result = run(
        [
            "/usr/sbin/smartctl",
            "--json=c",
            "--health",
            "--attributes",
            "--log=error",
            "--log=selftest",
            policy["device"],
        ],
        30,
        tuple(range(0, 256)),
    )
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise HostMonitorError("smartctl did not return JSON") from exc
    if not isinstance(value, dict):
        raise HostMonitorError("smartctl JSON root is not an object")
    issues: list[dict[str, str]] = []
    exit_status = value.get("smartctl", {}).get("exit_status", result.returncode)
    if not isinstance(exit_status, int):
        raise HostMonitorError("smartctl exit status is missing")
    if exit_status != result.returncode:
        raise HostMonitorError("smartctl process and JSON exit statuses differ")
    if exit_status & 0b00111111:
        issues.append(
            common.issue(
                "smart.command-or-health",
                "critical",
                "SMART command, device access, health, or prefail threshold failed",
                "pause risky workloads and inspect the root-only SMART report and physical disk",
            )
        )
    elif exit_status & 0b11000000:
        issues.append(
            common.issue(
                "smart.error-or-selftest-log",
                "warning",
                "SMART reports an error-log or self-test-log condition",
                "review the complete SMART logs and trend before the next maintenance window",
            )
        )
    serial = value.get("serial_number")
    serial_match = isinstance(serial, str) and hashlib.sha256(serial.encode("utf-8")).hexdigest() == policy["serialSha256"]
    if not serial_match:
        issues.append(
            common.issue(
                "smart.device-identity",
                "critical",
                "SMART device serial digest differs from the approved disk",
                "verify device mapping and disk replacement authority through the console",
            )
        )
    passed = value.get("smart_status", {}).get("passed")
    if passed is not True:
        issues.append(
            common.issue(
                "smart.health",
                "critical",
                "SMART overall health is not passing",
                "treat the disk as a storage incident and prepare approved replacement/recovery",
            )
        )
    temperature = value.get("temperature", {}).get("current")
    if not isinstance(temperature, int):
        temperature = value.get("nvme_smart_health_information_log", {}).get("temperature")
    if not isinstance(temperature, int) or temperature > policy["maximumTemperatureC"]:
        issues.append(
            common.issue(
                "smart.temperature",
                "critical",
                "disk temperature is unavailable or above the reviewed maximum",
                "inspect cooling and disk health before write-heavy work",
            )
        )
    counters = {
        "reallocated": _smart_attribute(value, 5),
        "pending": _smart_attribute(value, 197),
        "offlineUncorrectable": _smart_attribute(value, 198),
        "mediaErrors": value.get("nvme_smart_health_information_log", {}).get("media_errors", 0),
    }
    if not isinstance(counters["mediaErrors"], int):
        counters["mediaErrors"] = 0
    limits = {
        "reallocated": policy["maximumReallocatedSectors"],
        "pending": policy["maximumPendingSectors"],
        "offlineUncorrectable": policy["maximumOfflineUncorrectable"],
        "mediaErrors": policy["maximumMediaErrors"],
    }
    for key, count in counters.items():
        if count > limits[key]:
            issues.append(
                common.issue(
                    f"smart.{key.lower()}",
                    "critical",
                    f"SMART {key} count exceeds the reviewed threshold",
                    "preserve SMART evidence and investigate disk replacement/recovery",
                )
            )
    self_test_age, self_test_passed = _latest_self_test_age_hours(value)
    if (
        self_test_age is None
        or self_test_age > policy["maximumSelfTestAgeHours"]
        or self_test_passed is not True
    ):
        issues.append(
            common.issue(
                "smart.selftest-freshness",
                "critical",
                "no recent passing SMART self-test is proved",
                "schedule and review a non-destructive SMART test under an approved hardware plan",
            )
        )
    evidence = {
        "device": policy["device"],
        "serialMatched": serial_match,
        "smartPassed": passed is True,
        "exitStatus": exit_status,
        "temperatureC": temperature,
        "counters": counters,
        "selfTestAgeHours": self_test_age,
        "selfTestPassed": self_test_passed,
    }
    return evidence, issues


def _findmnt(path: str, run: COMMAND = _command) -> dict[str, Any]:
    result = run(
        [
            "/usr/bin/findmnt",
            "--json",
            "--bytes",
            "--output",
            "SOURCE,TARGET,FSTYPE,OPTIONS,UUID",
            "--target",
            path,
        ],
        10,
        (0,),
    )
    try:
        value = json.loads(result.stdout)
        filesystems = value["filesystems"]
        if not isinstance(filesystems, list) or len(filesystems) != 1:
            raise ValueError("ambiguous mount")
        observed = filesystems[0]
        if not isinstance(observed, dict):
            raise ValueError("mount is not object")
        return observed
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise HostMonitorError(f"findmnt output is invalid for {path}") from exc


def inspect_filesystem(
    policy: dict[str, Any], run: COMMAND = _command
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    issues: list[dict[str, str]] = []
    path = Path(policy["path"])
    if path.is_symlink() or not path.is_dir() or not os.path.ismount(path):
        issues.append(
            common.issue(
                f"filesystem.{path.name or 'root'}-mount",
                "critical",
                f"{path} is not the exact mounted persistent filesystem",
                "keep services fail-closed and restore the approved mount through console evidence",
            )
        )
        return {"path": str(path), "mounted": False}, issues
    observed = _findmnt(str(path), run)
    source = observed.get("source")
    target = observed.get("target")
    filesystem = observed.get("fstype")
    uuid = str(observed.get("uuid", "")).lower()
    options = str(observed.get("options", "")).split(",")
    option_set = set(options)
    if (
        target != str(path)
        or source != policy["expectedSource"]
        or filesystem != policy["expectedType"]
        or uuid != policy["expectedUuid"]
    ):
        issues.append(
            common.issue(
                f"filesystem.{path.name}-identity",
                "critical",
                f"{path} source, UUID, type, or target differs from approved authority",
                "stop dependent services and verify the volume identity out of band",
            )
        )
    required = set(policy["requiredOptions"])
    conflicts = {"ro", "dev", "suid", "exec"}
    if not required.issubset(option_set) or option_set.intersection(conflicts):
        issues.append(
            common.issue(
                f"filesystem.{path.name}-options",
                "critical",
                f"{path} mount options do not preserve rw,nodev,nosuid,noexec",
                "close dependent entry points and restore the approved mount contract",
            )
        )
    capacity = os.statvfs(path)
    free_bytes = capacity.f_bavail * capacity.f_frsize
    total_bytes = capacity.f_blocks * capacity.f_frsize
    free_percent = free_bytes * 100 / total_bytes if total_bytes else 0.0
    free_inodes = capacity.f_favail
    total_inodes = capacity.f_files
    free_inode_percent = free_inodes * 100 / total_inodes if total_inodes else 0.0
    if free_bytes < policy["minimumFreeBytes"] or free_percent < policy["minimumFreePercent"]:
        issues.append(
            common.issue(
                f"filesystem.{path.name}-capacity",
                "critical",
                f"{path} free space is below the reviewed reserve",
                "pause releases/backups/uploads and execute the approved capacity response",
            )
        )
    if free_inodes < policy["minimumFreeInodes"] or free_inode_percent < policy["minimumFreeInodePercent"]:
        issues.append(
            common.issue(
                f"filesystem.{path.name}-inodes",
                "critical",
                f"{path} free inode reserve is below policy",
                "pause writers and investigate inode consumption without broad deletion",
            )
        )
    return {
        "path": str(path),
        "mounted": True,
        "source": source,
        "uuidSha256": hashlib.sha256(uuid.encode("ascii", errors="ignore")).hexdigest(),
        "type": filesystem,
        "requiredOptionsPresent": required.issubset(option_set),
        "freeBytes": free_bytes,
        "totalBytes": total_bytes,
        "freePercent": round(free_percent, 3),
        "freeInodes": free_inodes,
        "totalInodes": total_inodes,
        "freeInodePercent": round(free_inode_percent, 3),
    }, issues


def _dns_matches(pattern: str, hostname: str) -> bool:
    pattern = pattern.rstrip(".").lower()
    hostname = hostname.rstrip(".").lower()
    if pattern == hostname:
        return True
    if pattern.startswith("*."):
        suffix = pattern[1:]
        return hostname.endswith(suffix) and hostname.count(".") == pattern.count(".")
    return False


def _openssl_certificate(path: str, run: COMMAND = _command) -> dict[str, Any]:
    result = run(
        [
            "/usr/bin/openssl",
            "x509",
            "-in",
            path,
            "-noout",
            "-startdate",
            "-enddate",
            "-fingerprint",
            "-sha256",
            "-ext",
            "subjectAltName",
        ],
        15,
        (0,),
    )
    not_before = re.search(r"(?m)^notBefore=(.+)$", result.stdout)
    not_after = re.search(r"(?m)^notAfter=(.+)$", result.stdout)
    fingerprint = re.search(r"(?mi)^sha256 Fingerprint=([0-9A-F:]+)$", result.stdout)
    sans = sorted(set(re.findall(r"DNS:([^,\s]+)", result.stdout)))
    if not_before is None or not_after is None or fingerprint is None or not sans:
        raise HostMonitorError("openssl certificate metadata is incomplete")
    try:
        before_epoch = ssl.cert_time_to_seconds(not_before.group(1).strip())
        after_epoch = ssl.cert_time_to_seconds(not_after.group(1).strip())
    except (ValueError, OverflowError) as exc:
        raise HostMonitorError("certificate validity time is invalid") from exc
    digest = fingerprint.group(1).replace(":", "").lower()
    if not SHA256.fullmatch(digest):
        raise HostMonitorError("certificate SHA-256 fingerprint is invalid")
    return {
        "notBeforeEpoch": before_epoch,
        "notAfterEpoch": after_epoch,
        "fingerprintSha256": digest,
        "sans": sans,
    }


def _monotonic_age_seconds(value: str, uptime_seconds: float) -> float | None:
    try:
        microseconds = int(value or "0")
    except ValueError:
        return None
    if microseconds <= 0:
        return None
    return max(0.0, uptime_seconds - microseconds / 1_000_000)


def _uptime_seconds() -> float:
    try:
        return float(Path("/proc/uptime").read_text(encoding="ascii").split()[0])
    except (OSError, UnicodeDecodeError, ValueError, IndexError) as exc:
        if common.test_mode():
            return 100_000.0
        raise HostMonitorError("kernel monotonic uptime is unavailable") from exc


def inspect_certificate(
    policy: dict[str, Any], run: COMMAND = _command, *, now_epoch: float | None = None, uptime_seconds: float | None = None
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    issues: list[dict[str, str]] = []
    path = Path(policy["path"])
    common.read_regular(path, maximum=1024 * 1024, expected_mode=None, require_root=True)
    certificate = _openssl_certificate(str(path), run)
    current = now_epoch if now_epoch is not None else datetime.now(timezone.utc).timestamp()
    remaining_days = (certificate["notAfterEpoch"] - current) / 86400
    if certificate["notBeforeEpoch"] > current + 300:
        issues.append(
            common.issue(
                f"tls.{policy['name']}-not-yet-valid",
                "critical",
                "the configured TLS certificate is not yet valid",
                "keep ingress closed and verify trusted time and certificate issuance",
            )
        )
    if remaining_days <= policy["criticalDays"]:
        issues.append(
            common.issue(
                f"tls.{policy['name']}-expiry",
                "critical",
                "the configured TLS certificate is expired or inside the critical renewal window",
                "use the approved certificate process; do not replace files without Nginx validation and rollback",
            )
        )
    elif remaining_days <= policy["warningDays"]:
        issues.append(
            common.issue(
                f"tls.{policy['name']}-expiry",
                "warning",
                "the configured TLS certificate is inside the warning renewal window",
                "verify the existing approved renewal path and schedule a renewal drill",
            )
        )
    missing_names = [
        expected
        for expected in policy["expectedDnsNames"]
        if not any(_dns_matches(san, expected) for san in certificate["sans"])
    ]
    if missing_names:
        issues.append(
            common.issue(
                f"tls.{policy['name']}-san",
                "critical",
                "the configured certificate SANs do not cover every approved DNS name",
                "keep the affected virtual host closed and issue the correct certificate through the approved provider",
            )
        )
    renewal = policy["renewal"]
    timer = _systemctl_show(renewal["timerUnit"], run)
    service = _systemctl_show(renewal["serviceUnit"], run)
    if timer["LoadState"] != "loaded" or timer["UnitFileState"] not in {"enabled", "enabled-runtime"} or timer["ActiveState"] != "active":
        issues.append(
            common.issue(
                f"tls.{policy['name']}-renewal-timer",
                "critical",
                "the reviewed TLS renewal timer is not loaded, enabled, and active",
                "review the existing provider timer; this monitor will not install or start ACME tooling",
            )
        )
    uptime = uptime_seconds if uptime_seconds is not None else _uptime_seconds()
    success_age = _monotonic_age_seconds(service["ExecMainExitTimestampMonotonic"], uptime)
    if (
        service["LoadState"] != "loaded"
        or service["Result"] != "success"
        or service["ExecMainStatus"] != "0"
        or success_age is None
        or success_age > renewal["maximumLastSuccessAgeSeconds"]
    ):
        issues.append(
            common.issue(
                f"tls.{policy['name']}-renewal-result",
                "critical",
                "no recent successful execution of the reviewed TLS renewal service is proved",
                "inspect provider logs and run only the provider-approved non-destructive renewal validation",
            )
        )
    return {
        "name": policy["name"],
        "path": policy["path"],
        "fingerprintSha256": certificate["fingerprintSha256"],
        "sanSetSha256": hashlib.sha256("\n".join(certificate["sans"]).encode("utf-8")).hexdigest(),
        "remainingDays": round(remaining_days, 3),
        "renewalTimer": renewal["timerUnit"],
        "renewalService": renewal["serviceUnit"],
        "renewalSuccessAgeSeconds": round(success_age, 3) if success_age is not None else None,
    }, issues


def inspect_unit(
    policy: dict[str, Any], run: COMMAND = _command, *, uptime_seconds: float | None = None
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    properties = _systemctl_show(policy["name"], run)
    issues: list[dict[str, str]] = []
    code = re.sub(r"[^a-z0-9]+", "-", policy["name"].lower()).strip("-")
    if properties["LoadState"] != "loaded":
        issues.append(
            common.issue(
                f"unit.{code}-load",
                "critical",
                f"{policy['name']} is not loaded",
                "preserve unit evidence and restore the reviewed installed template",
            )
        )
    if properties["UnitFileState"] not in policy["expectedEnabled"]:
        issues.append(
            common.issue(
                f"unit.{code}-enablement",
                "critical",
                f"{policy['name']} boot enablement differs from the approved state",
                "review commissioning/maintenance evidence before changing enablement",
            )
        )
    if properties["ActiveState"] not in policy["expectedActive"]:
        issues.append(
            common.issue(
                f"unit.{code}-activity",
                "critical",
                f"{policy['name']} runtime state differs from the approved state",
                "inspect dependencies and persistent failure markers; do not bypass start gates",
            )
        )
    if policy["requireSuccessfulResult"] and (
        properties["Result"] != "success" or properties["ExecMainStatus"] != "0"
    ):
        issues.append(
            common.issue(
                f"unit.{code}-result",
                "critical",
                f"{policy['name']} does not have a successful terminal result",
                "inspect the persistent journal and recover through the unit-specific procedure",
            )
        )
    try:
        restarts = int(properties["NRestarts"] or "0")
    except ValueError:
        restarts = policy["maximumNRestarts"] + 1
    if restarts > policy["maximumNRestarts"]:
        issues.append(
            common.issue(
                f"unit.{code}-restarts",
                "critical",
                f"{policy['name']} restart count exceeds the reviewed threshold",
                "investigate the crash loop and StartLimit state instead of adding an unbounded restart loop",
            )
        )
    uptime = uptime_seconds if uptime_seconds is not None else _uptime_seconds()
    success_age = _monotonic_age_seconds(properties["ExecMainExitTimestampMonotonic"], uptime)
    trigger_age = _monotonic_age_seconds(properties["LastTriggerUSecMonotonic"], uptime)
    if policy["maximumLastSuccessAgeSeconds"] is not None and (
        success_age is None or success_age > policy["maximumLastSuccessAgeSeconds"]
    ):
        issues.append(
            common.issue(
                f"unit.{code}-success-age",
                "critical",
                f"{policy['name']} has no sufficiently recent successful run",
                "inspect the timer and job evidence before manually retrying the fixed oneshot",
            )
        )
    if policy["maximumLastTriggerAgeSeconds"] is not None and (
        trigger_age is None or trigger_age > policy["maximumLastTriggerAgeSeconds"]
    ):
        issues.append(
            common.issue(
                f"unit.{code}-trigger-age",
                "critical",
                f"{policy['name']} has not triggered within the reviewed interval",
                "inspect timer persistence/clock state and the job result before changing the schedule",
            )
        )
    return {
        "name": policy["name"],
        "loadState": properties["LoadState"],
        "activeState": properties["ActiveState"],
        "subState": properties["SubState"],
        "unitFileState": properties["UnitFileState"],
        "result": properties["Result"],
        "execMainStatus": properties["ExecMainStatus"],
        "nRestarts": restarts,
        "lastSuccessAgeSeconds": round(success_age, 3) if success_age is not None else None,
        "lastTriggerAgeSeconds": round(trigger_age, 3) if trigger_age is not None else None,
    }, issues


def inspect_postgres(
    policy: dict[str, Any], run: COMMAND = _command
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    if not policy["enabled"]:
        return {"enabled": False}, []
    result = run(
        [
            "/usr/bin/pg_isready",
            "-q",
            "-h",
            policy["socketDirectory"],
            "-p",
            str(policy["port"]),
            "-d",
            policy["database"],
            "-t",
            str(policy["timeoutSeconds"]),
        ],
        policy["timeoutSeconds"] + 2,
        (0, 1, 2, 3),
    )
    issues: list[dict[str, str]] = []
    if result.returncode != 0:
        issues.append(
            common.issue(
                "postgres.accepting-connections",
                "critical",
                "the fixed local PostgreSQL Unix socket is not accepting connections",
                "inspect storage, the exact PostgreSQL instance and recovery evidence; do not start another cluster",
            )
        )
    return {
        "enabled": True,
        "socketDirectory": policy["socketDirectory"],
        "port": policy["port"],
        "database": policy["database"],
        "accepting": result.returncode == 0,
    }, issues


def _safe_boot_id(path: Path = BOOT_ID) -> str:
    if common.test_mode() and not path.exists():
        return "test-boot"
    value = path.read_text(encoding="ascii").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
        raise HostMonitorError("kernel boot ID is invalid")
    return value


def collect_report(
    policy_raw: bytes,
    policy: dict[str, Any],
    *,
    hardware_authority: dict[str, Any] | None = None,
    now: datetime | None = None,
    run: COMMAND = _command,
) -> dict[str, Any]:
    observed = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    evidence: dict[str, Any] = {}
    issues: list[dict[str, str]] = []

    def section(name: str, action: Callable[[], tuple[Any, list[dict[str, str]]]]) -> None:
        try:
            value, found = action()
            evidence[name] = value
            issues.extend(found)
        except (HostMonitorError, common.MonitoringError, OSError, ValueError) as exc:
            evidence[name] = {"observation": "failed"}
            issues.append(
                common.issue(
                    f"monitor.{name}-observation",
                    "critical",
                    f"read-only {name} observation failed: {exc}",
                    "inspect the root-only monitor journal and restore the observation contract",
                )
            )

    section("journald", lambda: inspect_journald(policy["journald"], run))
    section("ntp", lambda: inspect_ntp(policy["ntp"], run))
    hardware = (
        policy["hardware"]
        if policy["hardware"]["mode"] == "provider-managed"
        else {"mode": policy["hardware"]["mode"], **(hardware_authority or {})}
    )
    if hardware["mode"] == "local-md-smart" and "raid" not in hardware:
        raise HostMonitorError("local hardware authority was not supplied")
    if hardware["mode"] == "local-lvm-nvme" and "erpStorageAuthority" not in hardware:
        raise HostMonitorError("local LVM/NVMe authority was not supplied")
    if hardware["mode"] == "local-lvm-nvme":
        section("storage", lambda: inspect_lvm_nvme(hardware))
    else:
        section("raid", lambda: inspect_raid(hardware))
    smart_evidence: list[dict[str, Any]] = []
    smart_issues: list[dict[str, str]] = []
    if hardware["mode"] in {"local-md-smart", "local-lvm-nvme"}:
        for item in hardware["smart"]:
            try:
                value, found = inspect_smart_device(item, run)
                smart_evidence.append(value)
                smart_issues.extend(found)
            except (HostMonitorError, common.MonitoringError, OSError, ValueError) as exc:
                smart_evidence.append({"device": item["device"], "observation": "failed"})
                smart_issues.append(
                    common.issue(
                        "monitor.smart-observation",
                        "critical",
                        f"read-only SMART observation failed: {exc}",
                        "inspect device access and smartmontools without broadening write permissions",
                    )
                )
    evidence["smart"] = smart_evidence
    issues.extend(smart_issues)
    filesystem_evidence: list[dict[str, Any]] = []
    for item in policy["filesystems"]:
        try:
            value, found = inspect_filesystem(item, run)
            filesystem_evidence.append(value)
            issues.extend(found)
        except (HostMonitorError, common.MonitoringError, OSError, ValueError) as exc:
            filesystem_evidence.append({"path": item["path"], "observation": "failed"})
            issues.append(
                common.issue(
                    "monitor.filesystem-observation",
                    "critical",
                    f"read-only filesystem observation failed: {exc}",
                    "inspect the exact mount and monitor policy before dependent writes",
                )
            )
    evidence["filesystems"] = filesystem_evidence
    certificate_evidence: list[dict[str, Any]] = []
    uptime = _uptime_seconds()
    for item in policy["certificates"]:
        try:
            value, found = inspect_certificate(
                item, run, now_epoch=observed.timestamp(), uptime_seconds=uptime
            )
            certificate_evidence.append(value)
            issues.extend(found)
        except (HostMonitorError, common.MonitoringError, OSError, ValueError) as exc:
            certificate_evidence.append({"name": item["name"], "observation": "failed"})
            issues.append(
                common.issue(
                    "monitor.tls-observation",
                    "critical",
                    f"read-only TLS/renewal observation failed: {exc}",
                    "inspect the configured certificate and existing renewal unit without installing another ACME client",
                )
            )
    evidence["certificates"] = certificate_evidence
    unit_evidence: list[dict[str, Any]] = []
    for item in policy["units"]:
        try:
            value, found = inspect_unit(item, run, uptime_seconds=uptime)
            unit_evidence.append(value)
            issues.extend(found)
        except (HostMonitorError, common.MonitoringError, OSError, ValueError) as exc:
            unit_evidence.append({"name": item["name"], "observation": "failed"})
            issues.append(
                common.issue(
                    "monitor.unit-observation",
                    "critical",
                    f"read-only systemd observation failed: {exc}",
                    "inspect D-Bus/systemd and preserve the unit journal before any change",
                )
            )
    evidence["units"] = unit_evidence
    section("postgres", lambda: inspect_postgres(policy["postgres"], run))
    unique: dict[str, dict[str, str]] = {}
    for item in issues:
        existing = unique.get(item["code"])
        if existing is None or (
            existing["severity"] == "warning" and item["severity"] == "critical"
        ):
            unique[item["code"]] = item
    sorted_issues = [unique[key] for key in sorted(unique)]
    return {
        "format": "uten-imp-host-monitor-report-v1",
        "source": "host",
        "observedAtUtc": common.utc_text(observed),
        "bootId": _safe_boot_id(),
        "policySha256": hashlib.sha256(policy_raw).hexdigest(),
        "status": "PASS" if not sorted_issues else "FAIL",
        "issues": sorted_issues,
        "evidence": evidence,
        "containsSecrets": False,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check",))
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    return parser


def _production_paths(args: argparse.Namespace) -> None:
    if common.test_mode():
        return
    if os.name != "posix" or os.geteuid() != 0:
        raise HostMonitorError("production host monitor requires root on POSIX")
    if args.policy != DEFAULT_POLICY or args.state != DEFAULT_STATE:
        raise HostMonitorError("production host monitor paths are fixed")


def main() -> int:
    args = build_parser().parse_args()
    try:
        _production_paths(args)
        common.assert_private_directory(args.state, create=True)
        policy_raw, policy = load_policy(args.policy)
        hardware_authority = load_hardware_authority(policy["hardware"])
        report = collect_report(
            policy_raw, policy, hardware_authority=hardware_authority
        )
        report_path = args.state / "host-latest.json"
        common.write_report(report_path, report)
        created, pending = alert_spool.record_report(
            report_path, "host", args.state
        )
        print(
            json.dumps(
                {
                    "status": report["status"],
                    "issues": len(report["issues"]),
                    "alertsCreated": created,
                    "alertsPending": pending,
                    "reportSha256": hashlib.sha256(common.canonical_json(report)).hexdigest(),
                },
                sort_keys=True,
            )
        )
        # An observed failure is a successful monitor run: its durable event is
        # drained independently.  Execution/contract failures still exit 1 and
        # trigger the unit-failure spool path.
        return 0
    except (HostMonitorError, common.MonitoringError, alert_spool.AlertError, OSError, ValueError) as exc:
        print(f"HOST_MONITOR_ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
