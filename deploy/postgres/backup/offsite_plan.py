#!/usr/bin/env python3
"""Read-only receiver-pull contract and recovery-watermark planner.

No subprocess, socket, transfer, config installation, pruning or activation is
implemented here. Supplied receipts are evidence inputs, never live verification.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import os
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any


SCHEMA_VERSION = 1
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MACHINE_ID = re.compile(r"^[0-9a-f]{32}$")
ACCOUNT = re.compile(r"^[a-z][a-z0-9_-]{2,31}$")
WAL_NAME = re.compile(r"^[0-9A-F]{24}$")
HOST = re.compile(r"^(?=.{1,253}$)[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$")
SET_ID = re.compile(r"^\d{8}T\d{6}Z-[0-9a-f]{12}$")
PLACEHOLDERS = ("REPLACE", "CHANGEME", "EXAMPLE", "PLACEHOLDER", "__")
FORBIDDEN_ACCOUNTS = {"root", "postgres", "uten", "uten-imp", "nginx", "admin"}
MAX_DOCUMENT_BYTES = 4 * 1024 * 1024
MAX_HOST_PIN_BYTES = 64 * 1024


class ContractError(ValueError):
    pass


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=True).encode("ascii")).hexdigest()


def _keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ContractError(f"{label} must have exactly the documented keys")
    return value


def _integer(value: Any, label: str, low: int, high: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ContractError(f"{label} must be an integer in [{low}, {high}]")
    return value


def _text(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if (not isinstance(value, str) or not 1 <= len(value) <= 512 or
            value != value.strip() or any(ord(char) < 32 for char in value) or
            any(marker in value.upper() for marker in PLACEHOLDERS) or
            (pattern is not None and not pattern.fullmatch(value))):
        raise ContractError(f"{label} is invalid or contains a placeholder")
    return value


def _path(value: Any, label: str) -> str:
    value = _text(value, label)
    path = PurePosixPath(value)
    if (not value.startswith("/") or value == "/" or str(path) != value or
            any(part in {".", ".."} for part in value.split("/")) or
            not re.fullmatch(r"/[A-Za-z0-9._/-]+", value)):
        raise ContractError(f"{label} must be a dedicated canonical absolute Linux path")
    return value


def _utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value):
        raise ContractError(f"{label} must use YYYY-MM-DDTHH:MM:SSZ")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise ContractError(f"{label} is not a valid UTC date") from exc


def _read_document(path: Path) -> bytes:
    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_DOCUMENT_BYTES + 1)
    except OSError as exc:
        raise ContractError("cannot read input file") from exc
    if len(raw) > MAX_DOCUMENT_BYTES or raw.startswith(b"\xef\xbb\xbf"):
        raise ContractError("input is oversized or contains a UTF-8 BOM")
    return raw


def _parse_document(raw: bytes) -> dict[str, Any]:
    def unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ContractError("duplicate JSON keys are forbidden")
            result[key] = value
        return result

    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ContractError("non-finite JSON number")))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ContractError("cannot read valid UTF-8 JSON input") from exc
    if not isinstance(value, dict):
        raise ContractError("input must be a JSON object")
    return value


def _load(path: Path) -> dict[str, Any]:
    return _parse_document(_read_document(path))


def _read_checked_host_pin(path: Path, expected: os.stat_result) -> bytes:
    """Bind an already checked pin to one bounded, no-follow descriptor read."""
    def identity(info: os.stat_result) -> tuple[int, ...]:
        return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode,
                info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    if not hasattr(os, "O_NOFOLLOW"):
        raise ContractError("host pin validation requires no-follow descriptor support")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        actual = os.fstat(fd)
        if (not stat.S_ISREG(actual.st_mode) or actual.st_nlink != 1 or
                identity(actual) != identity(expected)):
            raise ContractError("knownHostsFile identity or permissions changed after inspection")
        if actual.st_size > MAX_HOST_PIN_BYTES:
            raise ContractError("knownHostsFile exceeds 64 KiB")
        raw = bytearray()
        while len(raw) <= MAX_HOST_PIN_BYTES:
            chunk = os.read(fd, MAX_HOST_PIN_BYTES + 1 - len(raw))
            if not chunk:
                break
            raw.extend(chunk)
        if len(raw) > MAX_HOST_PIN_BYTES:
            raise ContractError("knownHostsFile exceeds 64 KiB")
        if identity(os.fstat(fd)) != identity(actual):
            raise ContractError("knownHostsFile changed during bounded descriptor reading")
        return bytes(raw)
    finally:
        os.close(fd)


def validate_config(value: dict[str, Any]) -> list[str]:
    _keys(value, {"schemaVersion", "enabled", "direction", "source", "receiver", "ssh", "recovery",
                  "retention", "isolation"}, "config")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError("unsupported schemaVersion")
    if value["enabled"] is not False:
        raise ContractError("enabled must remain false: transport and activation are not implemented")
    if value["direction"] != "RECEIVER_PULL":
        raise ContractError("only independently initiated RECEIVER_PULL is permitted")
    source = _keys(value["source"], {"machineId", "host", "addresses", "systemIdentifier", "timeline",
                                    "postgresMajorVersion", "repositoryNumber", "repositoryRoot",
                                    "pairedBackupRoot", "attachmentRoot", "privateOriginalRoot"}, "source")
    receiver = _keys(value["receiver"], {"machineId", "addresses", "repositoryRoot", "receiveAccount",
                                        "retentionAccount"}, "receiver")
    ssh = _keys(value["ssh"], {"sourceReadAccount", "port", "identityFile", "knownHostsFile",
                              "hostKeySha256", "strictHostKeyChecking", "passwordAuthentication",
                              "agentForwarding", "portForwarding", "sourceCommand"}, "ssh")
    recovery = _keys(value["recovery"], {"rpoSeconds", "rtoSeconds", "publicationMaxSeconds",
                                        "pullIntervalSeconds", "transferMaxSeconds", "retryBudgetSeconds"}, "recovery")
    retention = _keys(value["retention"], {"pitrDays", "weeklyRestorePoints", "monthlyRestorePoints",
                                           "immutableDays", "cleanupAuthority", "referenceClosureRequired"}, "retention")
    isolation = _keys(value["isolation"], {"sourceCanDeleteReceiverHistory", "receiveAccountCanDeleteHistory",
                                           "sourceReadAccountCanMutateSource", "physicalFailureDomain",
                                           "siteFailureDomain", "immutabilityVerification"}, "isolation")
    blockers: list[str] = []

    def optional(value: Any, label: str, parser: Any) -> Any:
        if value is None:
            blockers.append(f"UNRESOLVED:{label}")
            return None
        return parser(value, label)

    for section_name, section in (("source", source), ("receiver", receiver)):
        optional(section["machineId"], f"{section_name}.machineId", lambda v, l: _text(v, l, MACHINE_ID))
        addresses = section["addresses"]
        if (not isinstance(addresses, list) or len(addresses) > 32 or
                any(not isinstance(address, str) for address in addresses) or len(set(addresses)) != len(addresses)):
            raise ContractError(f"{section_name}.addresses must be a unique IP list")
        if not addresses:
            blockers.append(f"UNRESOLVED:{section_name}.addresses")
        for address in addresses:
            try:
                ip = ipaddress.ip_address(address)
            except (ValueError, TypeError) as exc:
                raise ContractError(f"{section_name}.addresses must contain literal IPs") from exc
            if ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local:
                raise ContractError(f"{section_name}.addresses contains a non-server address")
    if source["machineId"] is not None and source["machineId"] == receiver["machineId"]:
        raise ContractError("source and receiver cannot be the same machine")
    if set(source["addresses"]) & set(receiver["addresses"]):
        raise ContractError("source and receiver addresses overlap")
    host = optional(source["host"], "source.host", lambda v, l: _text(v, l, HOST))
    if host is not None:
        if host.lower() in {"localhost", "localhost.localdomain"} or host.endswith((".invalid", ".example", ".test")):
            raise ContractError("source.host must be a real server endpoint")
        try:
            literal = ipaddress.ip_address(host)
        except ValueError:
            literal = None
        if literal is not None and str(literal) not in source["addresses"]:
            raise ContractError("literal source.host must appear in source.addresses")
    optional(source["systemIdentifier"], "source.systemIdentifier",
             lambda v, l: _text(v, l, re.compile(r"^[1-9][0-9]{9,19}$")))
    optional(source["timeline"], "source.timeline", lambda v, l: _integer(v, l, 1, 2**32 - 1))
    _integer(source["postgresMajorVersion"], "source.postgresMajorVersion", 16, 16)
    _integer(source["repositoryNumber"], "source.repositoryNumber", 1, 2)
    source_roots = [_path(source[key], f"source.{key}") for key in
                    ("repositoryRoot", "pairedBackupRoot", "attachmentRoot")]
    private_root = optional(source["privateOriginalRoot"], "source.privateOriginalRoot", _path)
    if private_root is not None:
        source_roots.append(private_root)
    target_root = optional(receiver["repositoryRoot"], "receiver.repositoryRoot", _path)
    if target_root is not None:
        target_path = PurePosixPath(target_root)
        for root in source_roots:
            source_path = PurePosixPath(root)
            if target_path == source_path or target_path in source_path.parents or source_path in target_path.parents:
                raise ContractError("source and receiver roots cannot overlap")
    accounts = [optional(section[key], f"{label}.{key}", lambda v, l: _text(v, l, ACCOUNT))
                for section, key, label in ((ssh, "sourceReadAccount", "ssh"),
                                           (receiver, "receiveAccount", "receiver"),
                                           (receiver, "retentionAccount", "receiver"))]
    defined_accounts = [item for item in accounts if item is not None]
    if len(set(defined_accounts)) != len(defined_accounts) or set(defined_accounts) & FORBIDDEN_ACCOUNTS:
        raise ContractError("source read, receive and retention accounts must be separate dedicated accounts")
    _integer(ssh["port"], "ssh.port", 1, 65535)
    for key in ("identityFile", "knownHostsFile"):
        optional(ssh[key], f"ssh.{key}", _path)
    if ssh["identityFile"] is not None and ssh["identityFile"] == ssh["knownHostsFile"]:
        raise ContractError("SSH identity and host pins require separate files")
    fingerprint = optional(ssh["hostKeySha256"], "ssh.hostKeySha256", _text)
    if fingerprint is not None:
        try:
            digest = base64.b64decode(fingerprint.removeprefix("SHA256:") + "=", validate=True)
        except ValueError as exc:
            raise ContractError("invalid pinned SSH host SHA256 fingerprint") from exc
        if not fingerprint.startswith("SHA256:") or len(digest) != 32:
            raise ContractError("invalid pinned SSH host SHA256 fingerprint")
    if ssh["strictHostKeyChecking"] is not True or any(ssh[key] is not False for key in
        ("passwordAuthentication", "agentForwarding", "portForwarding")):
        raise ContractError("strict host pinning and key-only SSH without forwarding are mandatory")
    if ssh["sourceCommand"] != "uten-offsite-source-read-v1":
        raise ContractError("sourceCommand must name the future restricted read protocol, never a shell")
    _integer(recovery["rpoSeconds"], "recovery.rpoSeconds", 60, 900)
    _integer(recovery["rtoSeconds"], "recovery.rtoSeconds", 60, 14400)
    for key in ("publicationMaxSeconds", "pullIntervalSeconds", "transferMaxSeconds", "retryBudgetSeconds"):
        _integer(recovery[key], f"recovery.{key}", 1, 900)
    if sum(recovery[key] for key in ("publicationMaxSeconds", "pullIntervalSeconds", "transferMaxSeconds",
                                     "retryBudgetSeconds")) > recovery["rpoSeconds"]:
        raise ContractError("publication + pull + transfer + retry budget exceeds RPO")
    _integer(retention["pitrDays"], "retention.pitrDays", 30, 365)
    _integer(retention["weeklyRestorePoints"], "retention.weeklyRestorePoints", 12, 104)
    _integer(retention["monthlyRestorePoints"], "retention.monthlyRestorePoints", 12, 120)
    _integer(retention["immutableDays"], "retention.immutableDays", retention["pitrDays"], 3650)
    if retention["cleanupAuthority"] != "RECEIVER_RETENTION_ACCOUNT" or retention["referenceClosureRequired"] is not True:
        raise ContractError("only receiver retention authority may prune closed restore-point graphs")
    if any(isolation[key] is not False for key in ("sourceCanDeleteReceiverHistory",
        "receiveAccountCanDeleteHistory", "sourceReadAccountCanMutateSource")):
        raise ContractError("source/receive credentials must not mutate protected history")
    for key in ("physicalFailureDomain", "siteFailureDomain", "immutabilityVerification"):
        if isolation[key] != "UNVERIFIED":
            raise ContractError(f"isolation.{key} is not proven by a configuration assertion")
        blockers.append(f"UNVERIFIED:isolation.{key}")
    return blockers


def _wal_index(name: str, timeline: int, segment_bytes: int) -> int:
    _text(name, "WAL segment name", WAL_NAME)
    if int(name[:8], 16) != timeline:
        raise ContractError("WAL timeline differs; timeline-history handling requires a separate reviewed protocol")
    segments_per_log = 2**32 // segment_bytes
    segment = int(name[16:], 16)
    if segment >= segments_per_log:
        raise ContractError("WAL segment ordinal exceeds the declared segment size")
    return int(name[8:16], 16) * segments_per_log + segment


def evaluate_receipt(config: dict[str, Any], receipt: dict[str, Any], now: datetime) -> dict[str, Any]:
    if any(blocker.startswith("UNRESOLVED:") for blocker in validate_config(config)):
        raise ContractError("receipt requires all connection identities and paths to be resolved")
    _keys(receipt, {"schemaVersion", "status", "configCanonicalSha256", "observedAtUtc", "sourceMachineId",
                   "receiverMachineId", "database", "originals", "paired", "durability"}, "receipt")
    if type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"] != 1 or receipt["status"] != "COMPLETED":
        raise ContractError("receipt is not a completed schemaVersion 1 receipt")
    if receipt["configCanonicalSha256"] != canonical_digest(config):
        raise ContractError("receipt does not bind this canonical configuration")
    for key, section in (("sourceMachineId", "source"), ("receiverMachineId", "receiver")):
        if receipt[key] != config[section]["machineId"]:
            raise ContractError("receipt machine identity differs from configuration")
    observed = _utc(receipt["observedAtUtc"], "receipt.observedAtUtc")
    if observed > now or (now - observed).total_seconds() > 900:
        raise ContractError("receiver receipt is future-dated or older than 15 minutes")
    database = _keys(receipt["database"], {"systemIdentifier", "timeline", "repositoryNumber", "baseBackupLabel",
        "baseBackupManifestSha256", "baseBackupStartedAtUtc", "baseBackupCompletedAtUtc", "baseBackupWalStart",
        "baseBackupWalStop", "walStart", "walStop",
        "walSegmentBytes", "walSegments", "walInventorySha256", "confirmedThroughUtc"}, "receipt.database")
    for key in ("systemIdentifier", "timeline", "repositoryNumber"):
        if type(database[key]) is not type(config["source"][key]) or database[key] != config["source"][key]:
            raise ContractError(f"receipt database {key} differs from source authority")
    _text(database["baseBackupLabel"], "baseBackupLabel", re.compile(r"^\d{8}-\d{6}F$"))
    _text(database["baseBackupManifestSha256"], "baseBackupManifestSha256", SHA256)
    segment_bytes = _integer(database["walSegmentBytes"], "walSegmentBytes", 1024**2, 1024**3)
    if segment_bytes & (segment_bytes - 1):
        raise ContractError("WAL segment bytes must be a supported power of two")
    timeline = database["timeline"]
    first = _wal_index(database["walStart"], timeline, segment_bytes)
    last = _wal_index(database["walStop"], timeline, segment_bytes)
    base_start = _wal_index(database["baseBackupWalStart"], timeline, segment_bytes)
    base_stop = _wal_index(database["baseBackupWalStop"], timeline, segment_bytes)
    if not first <= base_start <= base_stop <= last or last - first > 20000:
        raise ContractError("WAL range does not close the base backup or is oversized")
    segments = database["walSegments"]
    if not isinstance(segments, list) or len(segments) != last - first + 1:
        raise ContractError("continuous WAL coverage requires every segment, with no gaps")
    for offset, segment in enumerate(segments):
        _keys(segment, {"name", "sha256"}, "walSegments entry")
        _text(segment["sha256"], "WAL segment digest", SHA256)
        if _wal_index(segment["name"], timeline, segment_bytes) != first + offset:
            raise ContractError("WAL segments are duplicated, unordered or have a gap")
    if database["walInventorySha256"] != canonical_digest(segments):
        raise ContractError("WAL inventory digest differs from the complete segment list")
    db_watermark = _utc(database["confirmedThroughUtc"], "database.confirmedThroughUtc")
    base_started = _utc(database["baseBackupStartedAtUtc"], "baseBackupStartedAtUtc")
    base_completed = _utc(database["baseBackupCompletedAtUtc"], "baseBackupCompletedAtUtc")
    if not base_started <= base_completed <= db_watermark <= observed:
        raise ContractError("database recovery watermark precedes base backup or exceeds receipt observation")
    originals = _keys(receipt["originals"], {"mode", "scopes", "objectManifestSha256",
        "recoveryReferenceManifestSha256", "immutabilityReceiptSha256", "journalReceiptSha256",
        "referenceCoverageFromUtc", "confirmedThroughUtc"}, "receipt.originals")
    if originals["scopes"] != ["attachments", "private-originals"]:
        raise ContractError("all attachment and private-original scopes must be covered")
    if originals["mode"] not in {"PAIRED_SNAPSHOT", "CONTINUOUS_IMMUTABLE_JOURNAL"}:
        raise ContractError("unsupported originals protection mode")
    for key in ("objectManifestSha256", "recoveryReferenceManifestSha256", "immutabilityReceiptSha256"):
        _text(originals[key], f"originals.{key}", SHA256)
    if originals["mode"] == "CONTINUOUS_IMMUTABLE_JOURNAL":
        _text(originals["journalReceiptSha256"], "originals.journalReceiptSha256", SHA256)
    elif originals["journalReceiptSha256"] is not None:
        raise ContractError("paired snapshot cannot claim a continuous original journal")
    media_watermark = _utc(originals["confirmedThroughUtc"], "originals.confirmedThroughUtc")
    if _utc(originals["referenceCoverageFromUtc"], "originals.referenceCoverageFromUtc") > base_started:
        raise ContractError("original reference coverage starts after the selected base backup")
    paired = _keys(receipt["paired"], {"setId", "manifestSha256", "databaseSha256", "startedAtUtc", "completedAtUtc"}, "receipt.paired")
    _text(paired["setId"], "paired.setId", SET_ID)
    try:
        datetime.strptime(paired["setId"][:16], "%Y%m%dT%H%M%SZ")
    except ValueError as exc:
        raise ContractError("paired.setId contains an invalid date") from exc
    for key in ("manifestSha256", "databaseSha256"):
        _text(paired[key], f"paired.{key}", SHA256)
    paired_completed = _utc(paired["completedAtUtc"], "paired.completedAtUtc")
    paired_started = _utc(paired["startedAtUtc"], "paired.startedAtUtc")
    if not paired_started <= paired_completed <= observed or media_watermark > observed:
        raise ContractError("original or paired recovery watermark exceeds receipt observation")
    if originals["mode"] == "PAIRED_SNAPSHOT" and media_watermark > paired_started:
        raise ContractError("paired-only originals cannot advance beyond their paired database snapshot")
    durability = _keys(receipt["durability"], {"fsyncVerified", "immutableSnapshotId", "accessReviewSha256"}, "receipt.durability")
    if durability["fsyncVerified"] is not True:
        raise ContractError("receipt must confirm target durability before advertising a recovery watermark")
    _text(durability["immutableSnapshotId"], "durability.immutableSnapshotId")
    _text(durability["accessReviewSha256"], "durability.accessReviewSha256", SHA256)
    common = min(db_watermark, media_watermark)
    if common < base_completed:
        raise ContractError("selected base backup completed after the common recovery point")
    rpo_seconds = int((now - common).total_seconds())
    return {"evidenceKind": "SUPPLIED_RECEIPT_NOT_LIVE_VERIFICATION", "commonRecoveryWatermarkUtc":
            common.strftime("%Y-%m-%dT%H:%M:%SZ"), "databaseConfirmedThroughUtc": database["confirmedThroughUtc"],
            "originalsConfirmedThroughUtc": originals["confirmedThroughUtc"], "observedRpoSeconds": rpo_seconds,
            "rpoWithinTargetFromSuppliedReceipt": rpo_seconds <= config["recovery"]["rpoSeconds"],
            "rtoVerified": False, "liveReadinessVerified": False}


def validate_receiver_files(config: dict[str, Any], machine_id_path: Path = Path("/etc/machine-id")) -> dict[str, Any]:
    """Inspect permissions and a public host pin on the receiver; never read the private key."""
    if os.name != "posix":
        raise ContractError("receiver file validation requires Linux/POSIX, not the development Windows host")
    if any(blocker.startswith("UNRESOLVED:") for blocker in validate_config(config)):
        raise ContractError("receiver file validation requires a fully resolved configuration")
    try:
        machine_id = machine_id_path.read_text(encoding="ascii").strip()
    except OSError as exc:
        raise ContractError("cannot read receiver machine identity") from exc
    if machine_id != config["receiver"]["machineId"]:
        raise ContractError("file checks are not running on the configured receiver")
    import pwd
    uid = os.geteuid()
    try:
        receiving_user = pwd.getpwnam(config["receiver"]["receiveAccount"])
        receiving_uid = receiving_user.pw_uid
    except KeyError as exc:
        raise ContractError("dedicated receiver account does not exist") from exc
    if receiving_uid == 0:
        raise ContractError("dedicated receiver account cannot be a root UID alias")
    receiving_groups = set(os.getgrouplist(config["receiver"]["receiveAccount"], receiving_user.pw_gid))
    trusted_uids = {0, receiving_uid}
    if uid not in trusted_uids:
        raise ContractError("receiver checks must run as root or the dedicated receiver account")
    checked: list[str] = []
    checked_files: dict[str, os.stat_result] = {}
    for key in ("identityFile", "knownHostsFile"):
        path = Path(config["ssh"][key])
        try:
            info = path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != receiving_uid or
                    stat.S_IMODE(info.st_mode) not in {0o400, 0o600}):
                raise ContractError(f"ssh.{key} must be a private regular file owned by the dedicated receiver account")
            for parent in path.parents:
                parent_info = parent.lstat()
                if (not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid not in trusted_uids or
                        parent_info.st_mode & 0o022):
                    raise ContractError(f"ssh.{key} has a symlink or writable/untrusted parent")
                execute_bit = (0o100 if parent_info.st_uid == receiving_uid else
                               0o010 if parent_info.st_gid in receiving_groups else 0o001)
                if not parent_info.st_mode & execute_bit:
                    raise ContractError(f"ssh.{key} has a parent the receiver cannot traverse")
        except OSError as exc:
            raise ContractError(f"cannot inspect ssh.{key}") from exc
        checked.append(key)
        checked_files[key] = info
    ssh = config["ssh"]
    alias = config["source"]["host"] if ssh["port"] == 22 else f"[{config['source']['host']}]:{ssh['port']}"
    try:
        raw = _read_checked_host_pin(Path(ssh["knownHostsFile"]), checked_files["knownHostsFile"])
        lines = [line.split() for line in raw.decode("ascii").splitlines() if line and not line.startswith("#")]
        if len(lines) != 1 or len(lines[0]) != 3 or lines[0][0] != alias or lines[0][1] != "ssh-ed25519":
            raise ContractError("knownHostsFile must contain exactly the configured explicit ed25519 host pin")
        public_key = base64.b64decode(lines[0][2], validate=True)
        if len(public_key) != 51 or public_key[:19] != b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20":
            raise ContractError("knownHostsFile does not contain a valid ed25519 public key")
        actual = "SHA256:" + base64.b64encode(hashlib.sha256(public_key).digest()).decode("ascii").rstrip("=")
        if actual != ssh["hostKeySha256"]:
            raise ContractError("knownHostsFile differs from the independently obtained host fingerprint")
    except ContractError:
        raise
    except (OSError, UnicodeError, ValueError) as exc:
        raise ContractError("cannot inspect valid public host pin") from exc
    return {"status": "LOCAL_RECEIVER_FILES_CHECKED", "checked": checked, "privateKeyContentRead": False,
            "connectionTested": False}


def make_plan(config: dict[str, Any], receipt: dict[str, Any] | None = None,
              now: datetime | None = None) -> dict[str, Any]:
    blockers = validate_config(config)
    blockers += ["TRANSPORT_NOT_IMPLEMENTED", "SOURCE_RESTRICTED_READ_PROTOCOL_NOT_IMPLEMENTED",
                 "CONTINUOUS_ORIGINAL_PROTECTION_NOT_COMMISSIONED", "TARGET_RETENTION_NOT_COMMISSIONED",
                 "ISOLATED_FULL_BUSINESS_RESTORE_AND_RTO_NOT_VERIFIED"]
    result: dict[str, Any] = {"schemaVersion": 1, "status": "DISABLED_UNRESOLVED" if
        any(item.startswith("UNRESOLVED:") for item in blockers) else "CANDIDATE_NOT_CONNECTED",
        "enabled": False, "liveReadinessVerified": False, "configCanonicalSha256": canonical_digest(config),
        "writesPerformed": False, "connectionsAttempted": False, "blockers": blockers,
        "recoveryTarget": config["recovery"], "receiverRetentionProposal": config["retention"],
        "requiredRecoveryClosure": ["verified base backup and every required WAL segment + timeline history",
            "all immutable attachment/private-original versions referenced anywhere in retained recovery windows",
            "exact paired database dump + its same-set media manifest",
            "independently escrowed application/decryption keys and matching recovery software"],
        "cleanupRules": ["receiver retention account only; source and receive accounts cannot delete history",
            "do not mirror-delete or age-delete individual WAL/media objects",
            "retain base + required WAL + historical media reference closure for daily/weekly/monthly points",
            "preserve last verified restore point; failed/incomplete copies never advance common watermark"],
        "rpoBudgetSeconds": sum(config["recovery"][key] for key in
            ("publicationMaxSeconds", "pullIntervalSeconds", "transferMaxSeconds", "retryBudgetSeconds")),
        "rtoVerified": False}
    if receipt is not None:
        result["suppliedRecoveryEvidence"] = evaluate_receipt(config, receipt, now or datetime.now(timezone.utc))
    else:
        result["blockers"].append("NO_INDEPENDENT_RECEIVER_DURABILITY_RECEIPT")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "validate", "validate-receiver-files"))
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--receipt-sha256")
    args = parser.parse_args()
    try:
        config = _load(args.config)
        if args.command == "validate-receiver-files":
            if args.receipt or args.receipt_sha256:
                raise ContractError("receiver file validation does not accept a recovery receipt")
            result = validate_receiver_files(config)
        else:
            if bool(args.receipt) != bool(args.receipt_sha256):
                raise ContractError("receipt and independently obtained receipt-sha256 must be supplied together")
            receipt = None
            if args.receipt:
                _text(args.receipt_sha256, "receipt-sha256", SHA256)
                receipt_raw = _read_document(args.receipt)
                if hashlib.sha256(receipt_raw).hexdigest() != args.receipt_sha256:
                    raise ContractError("receipt SHA-256 differs from the supplied out-of-band digest")
                receipt = _parse_document(receipt_raw)
            result = make_plan(config, receipt)
        print(json.dumps(result, ensure_ascii=True, sort_keys=True, indent=2))
        return 0
    except (ContractError, OSError) as exc:
        # Do not echo rejected JSON values or arbitrary exception strings: they may contain credentials.
        print(json.dumps({"schemaVersion": 1, "status": "INVALID_INPUT", "liveReadinessVerified": False,
                          "connectionsAttempted": False, "writesPerformed": False,
                          "error": str(exc) if isinstance(exc, ContractError) else "cannot read input file"}))
        return 78


if __name__ == "__main__":
    sys.exit(main())
