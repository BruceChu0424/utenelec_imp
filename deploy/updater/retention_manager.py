#!/usr/bin/env python3
"""Root-controlled, fail-closed retention audit and pruning for signed releases.

This helper deliberately has no path override. Automatic timers remain disabled until
real-host quota, alert-delivery, power-loss, and recovery evidence is accepted.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import pwd
import grp
import re
import stat
import struct
import subprocess
import sys
import tempfile
import time
import types
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, NoReturn


_PREVERIFIED_UPDATER_GLOBAL = "_UTEN_PREVERIFIED_RELEASE_UPDATER"
_PREVERIFIED_UPDATER_PATH_GLOBAL = "_UTEN_PREVERIFIED_RELEASE_UPDATER_PATH"
_RUNTIME_TRUST_ATTESTOR_GLOBAL = "_UTEN_RETENTION_RUNTIME_TRUST_ATTESTOR"


def _validated_preverified_updater(module: Any, expected_path: Any) -> types.ModuleType:
    """Accept only the updater module injected by the pinned runtime launcher.

    This module deliberately has no source-path fallback.  Executing this file
    directly, importing a sibling through ``__file__``, or reopening an
    unpinned pathname would silently move the retention trust boundary.
    """

    if not isinstance(module, types.ModuleType):
        raise RuntimeError("retention requires a preverified release updater module")
    if not isinstance(expected_path, str) or not expected_path.startswith("/"):
        raise RuntimeError("retention updater trust path is not fixed and absolute")
    module_file = getattr(module, "__file__", None)
    if module_file != expected_path:
        raise RuntimeError("preverified release updater escaped its pinned path")
    required_callables = {
        "StateLock",
        "archive_root_evidence",
        "atomic_bytes",
        "atomic_json",
        "authorized_key_ids",
        "canonical_json_sha256",
        "cross_check_release",
        "fsync_directory",
        "read_root_evidence_bytes",
        "require_real_directory",
        "require_root_controlled_file",
        "require_root_owned_tree",
        "strict_json_object",
    }
    if any(not callable(getattr(module, name, None)) for name in required_callables):
        raise RuntimeError("preverified release updater API contract is incomplete")
    for name in (
        "BOOT_UNITS",
        "CHANNEL",
        "INTERRUPTED_CONTAINMENT_PLAN",
        "INTERRUPTED_CONTAINMENT_RECEIPT",
        "UPDATER_USER",
    ):
        if getattr(module, name, None) is None:
            raise RuntimeError("preverified release updater constant contract is incomplete")
    guard = getattr(module, "release_guard", None)
    if not isinstance(guard, types.ModuleType):
        raise RuntimeError("preverified release updater has no authenticated release guard")
    updater_error = getattr(module, "UpdaterError", None)
    if not isinstance(updater_error, type) or not issubclass(updater_error, Exception):
        raise RuntimeError("preverified release updater exception contract is incomplete")
    return module


release_updater = _validated_preverified_updater(
    globals().get(_PREVERIFIED_UPDATER_GLOBAL),
    globals().get(_PREVERIFIED_UPDATER_PATH_GLOBAL),
)
release_guard = release_updater.release_guard
_runtime_trust_attestor = globals().get(_RUNTIME_TRUST_ATTESTOR_GLOBAL)
if not callable(_runtime_trust_attestor):
    raise RuntimeError("retention requires a pinned runtime trust attestor")


def require_runtime_trust() -> None:
    """Re-prove fixed runtime bytes before any persistent write or alert."""

    result = _runtime_trust_attestor()
    if result is not None:
        raise RuntimeError("retention runtime trust attestor returned an invalid result")

POLICY_PATH = Path("/etc/uten-imp-release-retention/policy.json")
STATE_DIR = Path("/var/lib/uten-imp-updater")
CANDIDATES_DIR = STATE_DIR / "candidates"
HIGH_WATER_PATH = STATE_DIR / "high-water.json"
PENDING_PATH = STATE_DIR / "pending.json"
ROOT_STATE_DIR = Path("/var/lib/uten-imp-release")
RECEIPTS_DIR = ROOT_STATE_DIR / "retention-receipts"
ALERTS_DIR = ROOT_STATE_DIR / "retention-alerts"
VERIFY_DIR = ROOT_STATE_DIR / "retention-verify"
RETENTION_MARKER = ROOT_STATE_DIR / "retention-in-progress.json"
RECOVERY_EVIDENCE_DIR = ROOT_STATE_DIR / "recovery-evidence"
DATABASE_RECEIPTS_DIR = ROOT_STATE_DIR / "database-receipts"
INTERRUPTED_CONTAINMENT_PLAN = release_updater.INTERRUPTED_CONTAINMENT_PLAN
INTERRUPTED_CONTAINMENT_RECEIPT = release_updater.INTERRUPTED_CONTAINMENT_RECEIPT
STAGING_QUARANTINE = ROOT_STATE_DIR / "retention-quarantine" / "staging"
RELEASE_BASE = Path("/opt/uten-imp")
RELEASES_DIR = RELEASE_BASE / "releases"
INSTALLED_QUARANTINE = RELEASE_BASE / ".retention-quarantine"
ALLOWED_SIGNERS = Path("/etc/uten-imp-updater/release-allowed-signers")
LOCK_PATH = ROOT_STATE_DIR / "operation.lock"
ALERT_SINK = Path("/usr/local/libexec/uten-imp-retention/alert-sink")
UPDATER_SERVICE = "uten-imp-updater.service"
UPDATER_TIMER = "uten-imp-updater.timer"
RETENTION_TIMER = "uten-imp-retention.timer"
INTERNAL_TEST_DB_WORKER_REQUEST = Path(
    "/var/lib/uten-imp-internal-test-commissioning/worker-request.json"
)

BLOCKING_MARKERS = (
    ROOT_STATE_DIR / "activation-failed.json",
    ROOT_STATE_DIR / "activation-in-progress.json",
    ROOT_STATE_DIR / "boot-enablement-in-progress.json",
    ROOT_STATE_DIR / "recovery-in-progress.json",
    ROOT_STATE_DIR / "recovery-ingress-pending.json",
    ROOT_STATE_DIR / "recovery-ingress-authorization.json",
    ROOT_STATE_DIR / "recovery-ingress-finalizing.json",
    ROOT_STATE_DIR / "internal-test-onboarding-adoption.json",
    ROOT_STATE_DIR / "internal-test-activation-reauthorization.json",
    INTERNAL_TEST_DB_WORKER_REQUEST,
    RETENTION_MARKER,
)
REFERENCE_MARKERS = (
    ROOT_STATE_DIR / "active.json",
    ROOT_STATE_DIR / "legacy-current-retirement.json",
    *BLOCKING_MARKERS[:-1],
)

POLICY_KEYS = {
    "criticalFreePercent",
    "incomingTtlSeconds",
    "installedProjectHardBytes",
    "installedProjectId",
    "keepVerifiedCandidates",
    "keepVerifiedInstalled",
    "minimumAgeSeconds",
    "minimumFreeBytes",
    "minimumFreePercent",
    "schemaVersion",
    "stagingProjectHardBytes",
    "stagingProjectId",
    "warningFreePercent",
}
HIGH_WATER_KEYS = {"commitSha", "releaseSequence", "stagedAtUtc", "version"}
PENDING_KEYS = {
    "commitSha",
    "createdAtUtc",
    "releaseSequence",
    "schemaVersion",
    "version",
}
LEGACY_MARKER_KEYS = {
    "legacyCurrentLinkTarget",
    "legacyResolvedPath",
    "replacementCommitSha",
    "replacementVersion",
    "retirementRecordedAtUtc",
    "rollbackAllowed",
    "schemaVersion",
}
INCOMING_RE = re.compile(r"\.incoming-[A-Za-z0-9._-]{4,128}")
UNIT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@:-]{1,127}\.service")
UTC_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
ALERT_ID_RE = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}")
PROVIDER_MESSAGE_ID_RE = re.compile(r"[A-Za-z0-9._:@/-]{3,256}")
RECOVERY_TRANSACTION_RE = re.compile(r"[0-9a-f]{16}-[A-Za-z0-9_]{6,64}")
INTERRUPTED_RECOVERY_TRANSACTION_RE = re.compile(r"interrupted-([0-9a-f]{64})")
MAX_JSON_BYTES = 256 * 1024
MIN_KEEP_COUNT = 3
MINIMUM_POLICY_AGE = 24 * 60 * 60
MINIMUM_QUOTA_BYTES = 10 * 1024 * 1024 * 1024
MAX_PENDING_ALERTS = 1000
MAX_PENDING_ALERT_BYTES = 16 * 1024 * 1024
FS_IOC_FSGETXATTR = 0x801C581F
FS_XFLAG_PROJINHERIT = 0x00000200
Q_GETQUOTA = 0x800007
PRJQUOTA = 2
QIF_BLIMITS = 1 << 0
QUOTA_BLOCK_BYTES = 1024


class RetentionError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise RetentionError(message)


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=True, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def require_integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < minimum
        or value > maximum
    ):
        fail(f"{label} is outside its approved integer range")
    return value


def validate_policy(value: dict[str, Any]) -> dict[str, int]:
    if set(value) != POLICY_KEYS:
        fail("retention policy exact key set is invalid; path overrides are forbidden")
    require_integer(value["schemaVersion"], "policy schemaVersion", 1, 1)
    keep_candidates = require_integer(
        value["keepVerifiedCandidates"], "keepVerifiedCandidates", MIN_KEEP_COUNT, 100
    )
    keep_installed = require_integer(
        value["keepVerifiedInstalled"], "keepVerifiedInstalled", MIN_KEEP_COUNT, 100
    )
    minimum_age = require_integer(
        value["minimumAgeSeconds"], "minimumAgeSeconds", MINIMUM_POLICY_AGE, 365 * 86400
    )
    incoming_ttl = require_integer(
        value["incomingTtlSeconds"], "incomingTtlSeconds", MINIMUM_POLICY_AGE, 365 * 86400
    )
    minimum_free_bytes = require_integer(
        value["minimumFreeBytes"], "minimumFreeBytes", 2 * 1024**3, 10 * 1024**4
    )
    minimum_free_percent = require_integer(
        value["minimumFreePercent"], "minimumFreePercent", 1, 50
    )
    critical_free_percent = require_integer(
        value["criticalFreePercent"], "criticalFreePercent", 2, 70
    )
    warning_free_percent = require_integer(
        value["warningFreePercent"], "warningFreePercent", 3, 80
    )
    if not minimum_free_percent < critical_free_percent < warning_free_percent:
        fail("free-space thresholds must satisfy minimum < critical < warning")
    staging_project_id = require_integer(
        value["stagingProjectId"], "stagingProjectId", 1, 2**32 - 1
    )
    installed_project_id = require_integer(
        value["installedProjectId"], "installedProjectId", 1, 2**32 - 1
    )
    if staging_project_id == installed_project_id:
        fail("staging and installed release trees require distinct project quota IDs")
    staging_hard = require_integer(
        value["stagingProjectHardBytes"],
        "stagingProjectHardBytes",
        MINIMUM_QUOTA_BYTES,
        100 * 1024**4,
    )
    installed_hard = require_integer(
        value["installedProjectHardBytes"],
        "installedProjectHardBytes",
        MINIMUM_QUOTA_BYTES,
        100 * 1024**4,
    )
    if staging_hard % QUOTA_BLOCK_BYTES or installed_hard % QUOTA_BLOCK_BYTES:
        fail("project quota hard limits must be exact 1024-byte multiples")
    return {
        "criticalFreePercent": critical_free_percent,
        "incomingTtlSeconds": incoming_ttl,
        "installedProjectHardBytes": installed_hard,
        "installedProjectId": installed_project_id,
        "keepVerifiedCandidates": keep_candidates,
        "keepVerifiedInstalled": keep_installed,
        "minimumAgeSeconds": minimum_age,
        "minimumFreeBytes": minimum_free_bytes,
        "minimumFreePercent": minimum_free_percent,
        "schemaVersion": 1,
        "stagingProjectHardBytes": staging_hard,
        "stagingProjectId": staging_project_id,
        "warningFreePercent": warning_free_percent,
    }


def stable_read_file(
    path: Path,
    *,
    expected_uid: int,
    expected_gid: int | None,
    maximum_bytes: int = MAX_JSON_BYTES,
    exact_mode: int | None = None,
) -> bytes:
    if not path.is_absolute() or not hasattr(os, "O_NOFOLLOW"):
        fail("retention evidence requires absolute no-follow paths")
    flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise RetentionError(f"cannot safely open retention evidence: {path}") from exc
    try:
        before = os.fstat(descriptor)
        path_details = path.lstat()
        mode = stat.S_IMODE(before.st_mode)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != expected_uid
            or (expected_gid is not None and before.st_gid != expected_gid)
            or before.st_nlink != 1
            or before.st_mode & 0o022
            or (exact_mode is not None and mode != exact_mode)
            or (before.st_dev, before.st_ino) != (path_details.st_dev, path_details.st_ino)
            or before.st_size < 2
            or before.st_size > maximum_bytes
        ):
            fail(f"retention evidence owner/mode/type/link/size is unsafe: {path}")
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        after = os.fstat(descriptor)
        if (
            len(raw) != before.st_size
            or len(raw) > maximum_bytes
            or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        ):
            fail(f"retention evidence changed while being read: {path}")
        return raw
    finally:
        os.close(descriptor)


def strict_json(raw: bytes, label: str) -> dict[str, Any]:
    return release_updater.strict_json_object(raw, label)


def load_policy() -> tuple[dict[str, int], str]:
    release_updater.require_root_controlled_file(POLICY_PATH, secret=True)
    raw = stable_read_file(
        POLICY_PATH, expected_uid=0, expected_gid=0, exact_mode=0o600
    )
    return validate_policy(strict_json(raw, "retention policy")), hashlib.sha256(raw).hexdigest()


def require_fixed_directory(
    path: Path, *, owner_uid: int, owner_gid: int, exact_mode: int | None = None
) -> os.stat_result:
    release_updater.require_real_directory(path, owner_uid=owner_uid)
    details = path.lstat()
    if details.st_gid != owner_gid or details.st_mode & 0o022:
        fail(f"retention directory ownership/mode is unsafe: {path}")
    if exact_mode is not None and stat.S_IMODE(details.st_mode) != exact_mode:
        fail(f"retention directory must have exact mode {exact_mode:04o}: {path}")
    return details


def verify_open_directory(
    descriptor: int,
    path: Path,
    *,
    owner_uid: int,
    owner_gid: int,
    exact_mode: int | None = None,
) -> os.stat_result:
    opened = os.fstat(descriptor)
    path_details = path.lstat()
    mode = stat.S_IMODE(opened.st_mode)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or opened.st_uid != owner_uid
        or opened.st_gid != owner_gid
        or opened.st_mode & 0o022
        or (exact_mode is not None and mode != exact_mode)
        or (opened.st_dev, opened.st_ino) != (path_details.st_dev, path_details.st_ino)
    ):
        fail(f"opened retention directory is unsafe or changed: {path}")
    return opened


def write_new_json(directory: Path, filename: str, value: dict[str, Any]) -> Path:
    require_runtime_trust()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{2,191}\.json", filename):
        fail("retention receipt filename is not canonical")
    require_fixed_directory(directory, owner_uid=0, owner_gid=0, exact_mode=0o700)
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    directory_fd = os.open(directory, directory_flags)
    descriptor: int | None = None
    created = False
    try:
        encoded = (json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode(
            "utf-8"
        )
        descriptor = os.open(
            filename,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_NOFOLLOW
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=directory_fd,
        )
        created = True
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                fail("retention receipt write made no progress")
            view = view[written:]
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.fsync(directory_fd)
        created = False
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if created:
            try:
                os.unlink(filename, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            os.fsync(directory_fd)
        os.close(directory_fd)
    return directory / filename


def project_attributes_fd(descriptor: int) -> tuple[int, bool]:
    raw = bytearray(28)
    try:
        fcntl.ioctl(descriptor, FS_IOC_FSGETXATTR, raw, True)
    except OSError as exc:
        raise RetentionError("filesystem project attributes are unavailable") from exc
    xflags, _extsize, _nextents, project_id, _cowextsize, _padding = struct.unpack(
        "=IIIII8s", raw
    )
    return project_id, bool(xflags & FS_XFLAG_PROJINHERIT)


class IfDqblk(ctypes.Structure):
    _fields_ = [
        ("dqb_bhardlimit", ctypes.c_uint64),
        ("dqb_bsoftlimit", ctypes.c_uint64),
        ("dqb_curspace", ctypes.c_uint64),
        ("dqb_ihardlimit", ctypes.c_uint64),
        ("dqb_isoftlimit", ctypes.c_uint64),
        ("dqb_curinodes", ctypes.c_uint64),
        ("dqb_btime", ctypes.c_uint64),
        ("dqb_itime", ctypes.c_uint64),
        ("dqb_valid", ctypes.c_uint32),
    ]


def query_project_quota(source: str, project_id: int) -> dict[str, int]:
    if not source.startswith("/dev/"):
        fail("project quota source must be one fixed local block device")
    try:
        source_details = os.stat(source)
    except OSError as exc:
        raise RetentionError(f"cannot stat quota block device: {source}") from exc
    if not stat.S_ISBLK(source_details.st_mode):
        fail("project quota source is not a block device")
    command = (Q_GETQUOTA << 8) | PRJQUOTA
    value = IfDqblk()
    libc = ctypes.CDLL(None, use_errno=True)
    result = libc.quotactl(
        ctypes.c_int(command),
        ctypes.c_char_p(os.fsencode(source)),
        ctypes.c_int(project_id),
        ctypes.byref(value),
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise RetentionError(
            f"quotactl could not read project {project_id}: {os.strerror(error_number)}"
        )
    if not value.dqb_valid & QIF_BLIMITS:
        fail("quotactl did not return valid project block limits")
    return {
        "currentBytes": int(value.dqb_curspace),
        "hardBytes": int(value.dqb_bhardlimit) * QUOTA_BLOCK_BYTES,
        "softBytes": int(value.dqb_bsoftlimit) * QUOTA_BLOCK_BYTES,
    }


def find_mount(path: Path) -> dict[str, str]:
    completed = subprocess.run(
        [
            "/usr/bin/findmnt",
            "--json",
            "--bytes",
            "--output",
            "SOURCE,TARGET,FSTYPE,OPTIONS",
            "--target",
            str(path),
        ],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
    )
    if completed.returncode != 0:
        fail(f"findmnt could not identify the filesystem for {path}")
    try:
        payload = json.loads(completed.stdout)
        rows = payload["filesystems"]
        if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
            raise ValueError
        row = rows[0]
        result = {key: row[key] for key in ("source", "target", "fstype", "options")}
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise RetentionError("findmnt returned a non-canonical filesystem record") from exc
    if any(not isinstance(item, str) or not item for item in result.values()):
        fail("findmnt filesystem record contains an empty field")
    return result


def quota_observation(path: Path, project_id: int, expected_hard_bytes: int) -> dict[str, Any]:
    observation: dict[str, Any] = {
        "expectedHardBytes": expected_hard_bytes,
        "expectedProjectId": project_id,
        "path": str(path),
        "valid": False,
    }
    try:
        mount = find_mount(path)
        if mount["fstype"] not in {"xfs", "ext4"}:
            fail("retention requires xfs/ext4 project quota support")
        options = set(mount["options"].split(","))
        if not options.intersection({"prjquota", "pquota"}):
            fail("filesystem is not mounted with project quota enforcement")
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(path, flags)
        try:
            actual_project, inherited = project_attributes_fd(descriptor)
        finally:
            os.close(descriptor)
        if actual_project != project_id or not inherited:
            fail("retention root lacks the exact project ID/PROJINHERIT assignment")
        quota = query_project_quota(mount["source"], project_id)
        if quota["hardBytes"] != expected_hard_bytes or quota["hardBytes"] <= 0:
            fail("live project quota hard limit differs from root-owned policy")
        observation.update(
            {
                "currentBytes": quota["currentBytes"],
                "filesystemType": mount["fstype"],
                "hardBytes": quota["hardBytes"],
                "mountTarget": mount["target"],
                "projectId": actual_project,
                "projectInherit": inherited,
                "softBytes": quota["softBytes"],
                "source": mount["source"],
                "valid": True,
            }
        )
    except Exception as exc:
        observation["error"] = str(exc)
    return observation


def verify_signed_json_retention(
    content: Path, signature: Path, *, maximum_bytes: int
) -> dict[str, Any]:
    """Verify through a root-only signer file without writing into the retained tree."""
    value = release_guard.load_json(content, maximum_bytes)
    claimed_key_id = release_guard.require_string(
        value.get("signingKeyId"), "signed retention JSON signingKeyId", release_guard.KEY_ID_RE
    )
    entries = release_guard.allowed_signer_entries(
        ALLOWED_SIGNERS, release_guard.SIGNING_IDENTITY
    )
    selected = entries.get(claimed_key_id)
    if not selected:
        fail("retained signed metadata claims an unauthorized key ID")
    require_fixed_directory(VERIFY_DIR, owner_uid=0, owner_gid=0, exact_mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".selected-signer-", dir=VERIFY_DIR)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        encoded = (selected + "\n").encode("utf-8")
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written < 1:
                fail("temporary retention signer write made no progress")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        release_guard.verify_ssh_signature(
            content,
            signature,
            temporary,
            expected_key_id=None,
        )
        return value
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink()
        release_updater.fsync_directory(VERIFY_DIR)


def verify_candidate_retention(path: Path) -> dict[str, Any]:
    channel_path = path / "channel.json"
    channel = verify_signed_json_retention(
        channel_path,
        path / "channel.sig",
        maximum_bytes=release_guard.MAX_CHANNEL_BYTES,
    )
    channel_info = release_guard.validate_channel(channel, expected_channel=release_updater.CHANNEL)
    manifest_path = path / "manifest.json"
    if release_guard.sha256_file(manifest_path) != channel_info["manifestSha256"]:
        fail("retained candidate manifest digest differs from signed channel")
    manifest = verify_signed_json_retention(
        manifest_path,
        path / "manifest.sig",
        maximum_bytes=release_guard.MAX_MANIFEST_BYTES,
    )
    manifest_info = release_guard.validate_manifest(
        manifest,
        expected_version=channel_info["version"],
        expected_signing_key_id=channel_info["signingKeyId"],
    )
    release_updater.cross_check_release(channel_info, manifest_info)
    marker = release_guard.load_json(path / "STAGED.json", 64 * 1024)
    expected_marker = {
        "artifactSha256": manifest_info["artifactSha256"],
        "channelSha256": release_guard.sha256_file(channel_path),
        "commitSha": manifest_info["commitSha"],
        "manifestSha256": release_guard.sha256_file(manifest_path),
        "payloadVerified": True,
        "releaseSequence": manifest_info["releaseSequence"],
        "schemaVersion": 1,
        "version": manifest_info["version"],
    }
    if set(marker) != set(expected_marker) | {"stagedAtUtc"}:
        fail("retained candidate STAGED marker exact key set is invalid")
    for key, expected in expected_marker.items():
        if marker.get(key) != expected:
            fail(f"retained candidate STAGED marker disagrees on {key}")
    staged = marker.get("stagedAtUtc")
    if not isinstance(staged, str) or not UTC_RE.fullmatch(staged):
        fail("retained candidate staged timestamp is malformed")
    artifact = path / manifest_info["artifactFileName"]
    if (
        not artifact.is_file()
        or artifact.is_symlink()
        or artifact.stat().st_size != manifest_info["artifactSizeBytes"]
        or release_guard.sha256_file(artifact) != manifest_info["artifactSha256"]
    ):
        fail("retained candidate archive is unsafe or differs from signed metadata")
    release_guard.verify_payload(path / "payload" / manifest_info["version"], manifest_info)
    return manifest_info


def verify_installed_retention(path: Path) -> dict[str, Any]:
    evidence = path / ".release"
    manifest_path = evidence / "manifest.json"
    manifest = verify_signed_json_retention(
        manifest_path,
        evidence / "manifest.sig",
        maximum_bytes=release_guard.MAX_MANIFEST_BYTES,
    )
    info = release_guard.validate_manifest(manifest, expected_version=path.name)
    if info["signingKeyId"] not in release_updater.authorized_key_ids(ALLOWED_SIGNERS):
        fail("installed release signer is no longer authorized")
    release_guard.verify_payload(path, info)
    return info


def space_severity(free_bytes: int, total_bytes: int, policy: dict[str, int]) -> tuple[int, str]:
    free_percent = (free_bytes * 100) // total_bytes if total_bytes else 0
    severity = "ok"
    if free_bytes < policy["minimumFreeBytes"] or free_percent <= policy["minimumFreePercent"]:
        severity = "minimum"
    elif free_percent <= policy["criticalFreePercent"]:
        severity = "critical"
    elif free_percent <= policy["warningFreePercent"]:
        severity = "warning"
    return free_percent, severity


def capacity_observation(path: Path, policy: dict[str, int]) -> dict[str, Any]:
    usage = release_updater.shutil.disk_usage(path)
    free_percent, severity = space_severity(usage.free, usage.total, policy)
    return {
        "freeBytes": usage.free,
        "freePercent": free_percent,
        "minimumFreeBytes": policy["minimumFreeBytes"],
        "minimumFreePercent": policy["minimumFreePercent"],
        "path": str(path),
        "severity": severity,
        "totalBytes": usage.total,
    }


def add_quota_capacity(observation: dict[str, Any], policy: dict[str, int]) -> None:
    if not observation.get("valid"):
        return
    hard_bytes = observation["hardBytes"]
    free_bytes = max(0, hard_bytes - observation["currentBytes"])
    free_percent, severity = space_severity(free_bytes, hard_bytes, policy)
    observation.update(
        {
            "freeBytes": free_bytes,
            "freePercent": free_percent,
            "severity": severity,
        }
    )


def ensure_project_fd(descriptor: int, expected_project_id: int, *, directory: bool) -> None:
    project_id, inherited = project_attributes_fd(descriptor)
    if project_id != expected_project_id or (directory and not inherited):
        fail("retention tree contains an inode outside the enforced project quota")


def scan_tree_fd(
    descriptor: int,
    *,
    expected_dev: int,
    expected_uid: int,
    expected_gid: int,
    expected_project_id: int,
) -> dict[str, int]:
    root_details = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(root_details.st_mode)
        or root_details.st_dev != expected_dev
        or root_details.st_uid != expected_uid
        or root_details.st_gid != expected_gid
        or root_details.st_mode & 0o022
    ):
        fail("retention tree root owner/mode/device is unsafe")
    ensure_project_fd(descriptor, expected_project_id, directory=True)
    total_bytes = 0
    entries = 1
    maximum_mtime_ns = root_details.st_mtime_ns
    with os.scandir(descriptor) as iterator:
        for entry in iterator:
            if not entry.name or "/" in entry.name or entry.name in {".", ".."}:
                fail("retention tree contains an unsafe child name")
            details = entry.stat(follow_symlinks=False)
            if not stat.S_ISDIR(details.st_mode) and not stat.S_ISREG(details.st_mode):
                fail("retention tree contains a symlink or special file")
            if (
                details.st_dev != expected_dev
                or details.st_uid != expected_uid
                or details.st_gid != expected_gid
                or details.st_mode & 0o022
            ):
                fail("retention tree contains unsafe owner/mode/device metadata")
            entries += 1
            maximum_mtime_ns = max(maximum_mtime_ns, details.st_mtime_ns)
            if stat.S_ISDIR(details.st_mode):
                child_fd = os.open(
                    entry.name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=descriptor,
                )
                try:
                    opened = os.fstat(child_fd)
                    if (opened.st_dev, opened.st_ino) != (details.st_dev, details.st_ino):
                        fail("retention tree directory changed during validation")
                    nested = scan_tree_fd(
                        child_fd,
                        expected_dev=expected_dev,
                        expected_uid=expected_uid,
                        expected_gid=expected_gid,
                        expected_project_id=expected_project_id,
                    )
                    total_bytes += nested["bytes"]
                    entries += nested["entries"] - 1
                    maximum_mtime_ns = max(maximum_mtime_ns, nested["maximumMtimeNs"])
                finally:
                    os.close(child_fd)
            else:
                if details.st_nlink != 1:
                    fail("retention tree contains a multiply-linked regular file")
                child_fd = os.open(
                    entry.name,
                    os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=descriptor,
                )
                try:
                    opened = os.fstat(child_fd)
                    if (opened.st_dev, opened.st_ino, opened.st_size) != (
                        details.st_dev,
                        details.st_ino,
                        details.st_size,
                    ):
                        fail("retention tree file changed during validation")
                    ensure_project_fd(child_fd, expected_project_id, directory=False)
                finally:
                    os.close(child_fd)
                total_bytes += details.st_size
    return {
        "bytes": total_bytes,
        "entries": entries,
        "maximumMtimeNs": maximum_mtime_ns,
    }


def validate_tree_at(
    parent: Path,
    name: str,
    *,
    expected_uid: int,
    expected_gid: int,
    expected_project_id: int,
    expected_dev: int,
) -> tuple[int, dict[str, int], os.stat_result]:
    if not name or "/" in name or "\\" in name or name in {".", ".."}:
        fail("retention source name is not a direct child")
    parent_fd = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(before.st_mode) or before.st_dev != expected_dev:
            fail("retention source is not a same-device directory")
        source_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_fd,
        )
        opened = os.fstat(source_fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            os.close(source_fd)
            fail("retention source changed before validation")
        observation = scan_tree_fd(
            source_fd,
            expected_dev=expected_dev,
            expected_uid=expected_uid,
            expected_gid=expected_gid,
            expected_project_id=expected_project_id,
        )
        return source_fd, observation, before
    finally:
        os.close(parent_fd)


def inventory_release_directories(
    *,
    kind: str,
    parent: Path,
    expected_uid: int,
    expected_gid: int,
    expected_project_id: int,
    now_ns: int,
) -> tuple[list[dict[str, Any]], list[str]]:
    results: list[dict[str, Any]] = []
    alerts: list[str] = []
    parent_details = parent.lstat()
    expected_dev = parent_details.st_dev
    for entry in os.scandir(parent):
        record: dict[str, Any] = {
            "kind": kind,
            "name": entry.name,
            "path": str(parent / entry.name),
            "verified": False,
        }
        try:
            release_guard.version_sequence(entry.name)
            source_fd, tree, details = validate_tree_at(
                parent,
                entry.name,
                expected_uid=expected_uid,
                expected_gid=expected_gid,
                expected_project_id=expected_project_id,
                expected_dev=expected_dev,
            )
            os.close(source_fd)
            age_seconds = max(0, (now_ns - tree["maximumMtimeNs"]) // 1_000_000_000)
            path = parent / entry.name
            if kind == "candidate":
                info = verify_candidate_retention(path)
                manifest_sha = release_guard.sha256_file(path / "manifest.json")
            elif kind == "installed":
                release_updater.require_root_owned_tree(path)
                info = verify_installed_retention(path)
                manifest_sha = release_guard.sha256_file(path / ".release/manifest.json")
            else:
                fail("unknown retention inventory kind")
            if info["version"] != entry.name:
                fail("signed release version differs from its directory name")
            record.update(
                {
                    "ageSeconds": age_seconds,
                    "bytes": tree["bytes"],
                    "commitSha": info["commitSha"],
                    "device": details.st_dev,
                    "entries": tree["entries"],
                    "inode": details.st_ino,
                    "manifestSha256": manifest_sha,
                    "maximumMtimeNs": tree["maximumMtimeNs"],
                    "releaseSequence": info["releaseSequence"],
                    "verified": True,
                    "version": info["version"],
                }
            )
        except Exception as exc:
            record["error"] = str(exc)
            alerts.append(f"{kind} entry is unsafe or unverifiable: {entry.name}: {exc}")
        results.append(record)
    return results, alerts


def inventory_incoming(
    *,
    updater_uid: int,
    updater_gid: int,
    project_id: int,
    now_ns: int,
    ttl_seconds: int,
) -> tuple[list[dict[str, Any]], list[str]]:
    results: list[dict[str, Any]] = []
    alerts: list[str] = []
    expected_dev = STATE_DIR.lstat().st_dev
    known_names = {"candidates", HIGH_WATER_PATH.name, PENDING_PATH.name}
    for entry in os.scandir(STATE_DIR):
        if entry.name in known_names:
            continue
        if not INCOMING_RE.fullmatch(entry.name):
            alerts.append(f"unknown updater-state entry was not touched: {entry.name}")
            continue
        record: dict[str, Any] = {
            "kind": "incoming",
            "name": entry.name,
            "path": str(STATE_DIR / entry.name),
            "verified": False,
        }
        try:
            source_fd, tree, details = validate_tree_at(
                STATE_DIR,
                entry.name,
                expected_uid=updater_uid,
                expected_gid=updater_gid,
                expected_project_id=project_id,
                expected_dev=expected_dev,
            )
            os.close(source_fd)
            age_seconds = max(0, (now_ns - tree["maximumMtimeNs"]) // 1_000_000_000)
            record.update(
                {
                    "ageSeconds": age_seconds,
                    "bytes": tree["bytes"],
                    "device": details.st_dev,
                    "eligible": age_seconds >= ttl_seconds,
                    "entries": tree["entries"],
                    "inode": details.st_ino,
                    "maximumMtimeNs": tree["maximumMtimeNs"],
                    "verified": True,
                }
            )
        except Exception as exc:
            record["error"] = str(exc)
            alerts.append(f"incoming entry is unsafe and was not touched: {entry.name}: {exc}")
        results.append(record)
    return results, alerts


def observe_quarantine(
    *,
    path: Path,
    updater_uid: int,
    updater_gid: int,
    policy: dict[str, int],
) -> tuple[list[dict[str, Any]], list[str]]:
    observations: list[dict[str, Any]] = []
    blockers: list[str] = []
    expected_dev = path.lstat().st_dev
    for entry in os.scandir(path):
        record: dict[str, Any] = {"name": entry.name, "path": str(path / entry.name)}
        blockers.append(
            f"retention quarantine residue requires evidence-driven recovery: {path / entry.name}"
        )
        try:
            matched = re.fullmatch(
                rf"({ALERT_ID_RE.pattern})-(candidate|incoming|installed)-(.+)",
                entry.name,
            )
            if matched is None:
                fail("quarantine entry name is not a known retention transaction")
            kind = matched.group(2)
            source_name = matched.group(3)
            if kind in {"candidate", "installed"}:
                release_guard.version_sequence(source_name)
            elif not INCOMING_RE.fullmatch(source_name):
                fail("quarantined incoming directory name is not canonical")
            if kind == "installed":
                expected_uid = 0
                expected_gid = 0
                project_id = policy["installedProjectId"]
            else:
                expected_uid = updater_uid
                expected_gid = updater_gid
                project_id = policy["stagingProjectId"]
            descriptor, tree, details = validate_tree_at(
                path,
                entry.name,
                expected_uid=expected_uid,
                expected_gid=expected_gid,
                expected_project_id=project_id,
                expected_dev=expected_dev,
            )
            os.close(descriptor)
            record.update(
                {
                    "bytes": tree["bytes"],
                    "device": details.st_dev,
                    "entries": tree["entries"],
                    "kind": kind,
                    "sourceName": source_name,
                    "valid": True,
                }
            )
        except Exception as exc:
            record.update({"error": str(exc), "valid": False})
            blockers.append(f"retention quarantine evidence is unsafe: {entry.name}: {exc}")
        observations.append(record)
    return observations, blockers


def validate_high_water(value: dict[str, Any]) -> str:
    if set(value) != HIGH_WATER_KEYS:
        fail("high-water JSON exact key set is invalid")
    version = release_guard.require_string(value.get("version"), "high-water version")
    if release_guard.version_sequence(version) != value.get("releaseSequence"):
        fail("high-water version/sequence is inconsistent")
    release_guard.require_string(value.get("commitSha"), "high-water commit", release_guard.COMMIT_RE)
    staged = release_guard.require_string(value.get("stagedAtUtc"), "high-water staged time")
    if not UTC_RE.fullmatch(staged):
        fail("high-water staged time is malformed")
    return version


def validate_pending(value: dict[str, Any]) -> str:
    if set(value) != PENDING_KEYS:
        fail("pending JSON schema is unknown")
    if value.get("schemaVersion") != 1 or isinstance(value.get("schemaVersion"), bool):
        fail("pending JSON schema is unsupported")
    version = release_guard.require_string(value.get("version"), "pending version")
    if release_guard.version_sequence(version) != value.get("releaseSequence"):
        fail("pending version/sequence is inconsistent")
    release_guard.require_string(value.get("commitSha"), "pending commit", release_guard.COMMIT_RE)
    created = release_guard.require_string(value.get("createdAtUtc"), "pending time")
    if not UTC_RE.fullmatch(created):
        fail("pending time is malformed")
    return version


def validate_legacy_marker(value: dict[str, Any]) -> str:
    if set(value) != LEGACY_MARKER_KEYS:
        fail("legacy retirement marker schema is unknown")
    if value.get("schemaVersion") != 1 or isinstance(value.get("schemaVersion"), bool):
        fail("legacy retirement marker schema is unsupported")
    if value.get("rollbackAllowed") is not False:
        fail("legacy retirement marker rollback flag is unsafe")
    release_guard.require_string(
        value.get("replacementCommitSha"), "legacy replacement commit", release_guard.COMMIT_RE
    )
    version = release_guard.require_string(
        value.get("replacementVersion"), "legacy replacement version"
    )
    release_guard.version_sequence(version)
    for key in ("legacyCurrentLinkTarget", "legacyResolvedPath", "retirementRecordedAtUtc"):
        field = release_guard.require_string(value.get(key), f"legacy marker {key}")
        if key == "retirementRecordedAtUtc" and not UTC_RE.fullmatch(field):
            fail("legacy retirement timestamp is malformed")
    return version


def marker_references() -> tuple[set[str], list[str], list[str], dict[str, Any]]:
    protected: set[str] = set()
    blockers: list[str] = []
    alerts: list[str] = []
    observations: dict[str, Any] = {}
    validators = {
        str(ROOT_STATE_DIR / "active.json"): release_updater.validate_active_release_state,
        str(ROOT_STATE_DIR / "activation-failed.json"): release_updater.validate_activation_failure_marker,
        str(ROOT_STATE_DIR / "activation-in-progress.json"): release_updater.validate_activation_in_progress_marker,
        str(ROOT_STATE_DIR / "boot-enablement-in-progress.json"): release_updater.validate_boot_enablement_marker,
        str(ROOT_STATE_DIR / "recovery-in-progress.json"): release_updater.validate_recovery_in_progress_marker,
        str(ROOT_STATE_DIR / "legacy-current-retirement.json"): validate_legacy_marker,
    }
    version_fields = {
        "version",
        "failedVersion",
        "previousVersion",
        "targetVersion",
        "replacementVersion",
    }
    for path in REFERENCE_MARKERS:
        if not os.path.lexists(path):
            continue
        try:
            raw = release_updater.read_root_evidence_bytes(path)
            value = strict_json(raw, path.name)
            validators[str(path)](value)
            for key in version_fields:
                candidate = value.get(key)
                if isinstance(candidate, str):
                    release_guard.version_sequence(candidate)
                    protected.add(candidate)
            observations[path.name] = {
                "fields": value,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "valid": True,
            }
        except Exception as exc:
            observations[path.name] = {"error": str(exc), "valid": False}
            blockers.append(f"root marker is unknown or damaged: {path.name}: {exc}")
    for path in BLOCKING_MARKERS:
        if os.path.lexists(path):
            blockers.append(f"transaction/recovery marker forbids pruning: {path.name}")

    try:
        current = release_updater.current_release(RELEASE_BASE, RELEASES_DIR)
        if current is None:
            blockers.append("current release link is absent")
            observations["current"] = {"target": None, "valid": False}
        else:
            if current.parent != RELEASES_DIR.resolve():
                fail("current release must resolve to one direct installed-release child")
            release_guard.version_sequence(current.name)
            protected.add(current.name)
            observations["current"] = {"target": str(current), "valid": True}
    except Exception as exc:
        blockers.append(f"current release link is unsafe: {exc}")
        observations["current"] = {"error": str(exc), "valid": False}

    try:
        account = pwd.getpwnam(release_updater.UPDATER_USER)
        updater_gid = grp.getgrnam(release_updater.UPDATER_USER).gr_gid
        if os.path.lexists(HIGH_WATER_PATH):
            raw = stable_read_file(
                HIGH_WATER_PATH,
                expected_uid=account.pw_uid,
                expected_gid=updater_gid,
                maximum_bytes=64 * 1024,
            )
            value = strict_json(raw, "high-water")
            protected.add(validate_high_water(value))
            observations["highWater"] = {
                "fields": value,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "valid": True,
            }
        else:
            observations["highWater"] = {"present": False, "valid": True}
        if os.path.lexists(PENDING_PATH):
            raw = stable_read_file(
                PENDING_PATH,
                expected_uid=account.pw_uid,
                expected_gid=updater_gid,
                maximum_bytes=64 * 1024,
            )
            value = strict_json(raw, "pending")
            protected.add(validate_pending(value))
            observations["pending"] = {
                "fields": value,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "valid": True,
            }
        else:
            observations["pending"] = {"present": False, "valid": True}
    except Exception as exc:
        blockers.append(f"updater reference evidence is unknown or damaged: {exc}")
    return protected, blockers, alerts, observations


def validate_recovery_live_database_evidence(value: Any) -> None:
    if not isinstance(value, dict):
        fail("recovery receipt live database evidence is malformed")
    release_guard.exact_keys(
        value,
        {
            "databaseName",
            "dataDirectory",
            "flyway",
            "schemaName",
            "serverPort",
            "serverVersionNum",
            "systemdMainPid",
            "systemIdentifier",
            "timeline",
            "verifiedAtUtc",
            "verifierSha256",
        },
        "recovery receipt live database evidence",
    )
    if (
        value.get("databaseName") != "uten_imp"
        or value.get("dataDirectory") != "/data/postgresql/16/main"
        or value.get("schemaName") != "public"
        or value.get("serverPort") != 5432
    ):
        fail("recovery receipt live database endpoint is not canonical")
    release_updater.require_recovery_integer(
        value.get("serverVersionNum"),
        "recovery receipt PostgreSQL version",
        minimum=160000,
        maximum=169999,
    )
    release_updater.require_recovery_integer(
        value.get("systemdMainPid"), "recovery receipt PostgreSQL MainPID", minimum=2
    )
    system_identifier = release_guard.require_string(
        value.get("systemIdentifier"), "recovery receipt PostgreSQL system identifier"
    )
    if not release_updater.POSTGRES_SYSTEM_IDENTIFIER_RE.fullmatch(system_identifier):
        fail("recovery receipt PostgreSQL system identifier is malformed")
    release_updater.require_recovery_integer(
        value.get("timeline"),
        "recovery receipt PostgreSQL timeline",
        minimum=1,
        maximum=0xFFFFFFFF,
    )
    release_updater.require_recovery_timestamp(
        value.get("verifiedAtUtc"), "recovery receipt live database verification time"
    )
    if value.get("verifierSha256") != release_updater.DATABASE_RECOVERY_VERIFIER_SHA256:
        fail("recovery receipt database verifier digest is not the reviewed digest")
    flyway = value.get("flyway")
    if not isinstance(flyway, dict):
        fail("recovery receipt live Flyway evidence is malformed")
    release_guard.exact_keys(
        flyway,
        {
            "canonicalHistorySha256",
            "headVersion",
            "signedProjectionSha256",
            "successfulMigrationCount",
        },
        "recovery receipt live Flyway evidence",
    )
    for key in ("canonicalHistorySha256", "signedProjectionSha256"):
        release_guard.require_string(
            flyway.get(key), f"recovery receipt Flyway {key}", release_guard.SHA256_RE
        )
    release_updater.require_recovery_integer(
        flyway.get("headVersion"), "recovery receipt Flyway head", minimum=1
    )
    release_updater.require_recovery_integer(
        flyway.get("successfulMigrationCount"),
        "recovery receipt Flyway migration count",
        minimum=1,
    )


def validate_recovery_transaction_receipt(
    value: dict[str, Any],
    transaction: Path,
    *,
    timestamp_key: str,
    final: bool,
) -> tuple[str, Path]:
    release_guard.exact_keys(
        value,
        {
            "action",
            "approvalReference",
            timestamp_key,
            "databaseDetailPath",
            "databaseDetailSha256",
            "databaseReceiptPath",
            "databaseReceiptSha256",
            "desiredBootEnablement",
            "liveDatabaseEvidence",
            "manifestSha256",
            "markerSha256",
            "planSha256",
            "schemaVersion",
            "status",
            "targetVersion",
            "transactionDirectory",
        },
        "recovery transaction receipt",
    )
    release_updater.require_recovery_schema_version(value, "recovery transaction receipt")
    action = value.get("action")
    if action not in {"finish-activation", "restore-previous", "abandon-candidate"}:
        fail("recovery transaction receipt action is unsupported")
    expected_status = (
        "completed"
        if final
        else (
            "runtime-committed-pending-ingress"
            if action == "finish-activation"
            else "previous-runtime-committed-pending-ingress"
        )
    )
    if value.get("status") != expected_status:
        fail("recovery transaction receipt action/status is inconsistent")
    approval = release_guard.require_string(
        value.get("approvalReference"), "recovery transaction receipt approval"
    )
    if not release_updater.RECOVERY_APPROVAL_RE.fullmatch(approval):
        fail("recovery transaction receipt approval reference is malformed")
    release_updater.require_recovery_timestamp(
        value.get(timestamp_key), f"recovery transaction receipt {timestamp_key}"
    )
    for key in (
        "databaseDetailSha256",
        "databaseReceiptSha256",
        "manifestSha256",
        "markerSha256",
        "planSha256",
    ):
        release_guard.require_string(value.get(key), key, release_guard.SHA256_RE)
    release_updater.require_recovery_boot_map(
        value.get("desiredBootEnablement"), "recovery transaction receipt boot map"
    )
    validate_recovery_live_database_evidence(value.get("liveDatabaseEvidence"))
    target = release_guard.require_string(value.get("targetVersion"), "recovery target")
    release_guard.version_sequence(target)
    if value.get("transactionDirectory") != str(transaction):
        fail("recovery transaction receipt directory is not exact")
    database_path = Path(
        release_guard.require_string(
            value.get("databaseReceiptPath"), "recovery database receipt path"
        )
    )
    if (
        database_path.parent != DATABASE_RECEIPTS_DIR
        or not release_updater.RECOVERY_RECEIPT_NAME_RE.fullmatch(database_path.name)
    ):
        fail("recovery receipt database evidence escaped the fixed directory")
    detail_path = Path(
        release_guard.require_string(
            value.get("databaseDetailPath"), "recovery database detail path"
        )
    )
    if (
        detail_path.parent != release_updater.RECOVERY_DATABASE_DETAIL_DIR
        or not release_updater.RECOVERY_RECEIPT_NAME_RE.fullmatch(detail_path.name)
    ):
        fail("recovery receipt detailed evidence escaped the fixed directory")
    return target, database_path


def validate_recovery_receipt_retention(
    value: dict[str, Any], transaction: Path
) -> tuple[str, Path]:
    return validate_recovery_transaction_receipt(
        value, transaction, timestamp_key="completedAtUtc", final=True
    )


def validate_recovery_commit_retention(
    value: dict[str, Any], transaction: Path
) -> tuple[str, Path]:
    return validate_recovery_transaction_receipt(
        value, transaction, timestamp_key="committedAtUtc", final=False
    )


def validate_remain_contained_receipt(
    value: dict[str, Any], transaction: Path
) -> str:
    release_guard.exact_keys(
        value,
        {
            "action",
            "approvalReference",
            "completedAtUtc",
            "markerPath",
            "markerSha256",
            "planSha256",
            "schemaVersion",
            "status",
            "subjectVersion",
            "transactionDirectory",
        },
        "remain-contained receipt",
    )
    release_updater.require_recovery_schema_version(value, "remain-contained receipt")
    if (
        value.get("action") != "remain-contained"
        or value.get("status") != "contained-no-start-no-marker-clear"
        or value.get("markerPath") != str(ROOT_STATE_DIR / "activation-failed.json")
        or value.get("transactionDirectory") != str(transaction)
    ):
        fail("remain-contained receipt control fields are inconsistent")
    approval = release_guard.require_string(
        value.get("approvalReference"), "remain-contained approval reference"
    )
    if not release_updater.RECOVERY_APPROVAL_RE.fullmatch(approval):
        fail("remain-contained approval reference is malformed")
    release_updater.require_recovery_timestamp(
        value.get("completedAtUtc"), "remain-contained completion time"
    )
    for key in ("markerSha256", "planSha256"):
        release_guard.require_string(value.get(key), key, release_guard.SHA256_RE)
    subject = release_guard.require_string(
        value.get("subjectVersion"), "remain-contained subject version"
    )
    release_guard.version_sequence(subject)
    return subject


def validate_recovery_failure_evidence(value: dict[str, Any]) -> None:
    release_guard.exact_keys(
        value,
        {"error", "errorType", "failedAtUtc", "markerSha256", "schemaVersion"},
        "recovery failure evidence",
    )
    release_updater.require_recovery_schema_version(value, "recovery failure evidence")
    release_updater.require_recovery_timestamp(
        value.get("failedAtUtc"), "recovery failure time"
    )
    release_guard.require_string(
        value.get("markerSha256"), "recovery failure marker digest", release_guard.SHA256_RE
    )
    error_type = release_guard.require_string(
        value.get("errorType"), "recovery failure error type"
    )
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{1,127}", error_type):
        fail("recovery failure error type is malformed")
    error = release_guard.require_string(value.get("error"), "recovery failure error")
    if len(error) > 4096:
        fail("recovery failure error is unexpectedly large")


def recovery_references() -> tuple[set[str], list[str], dict[str, Any]]:
    protected: set[str] = set()
    blockers: list[str] = []
    observations: dict[str, Any] = {"databaseReceipts": [], "transactions": []}
    require_fixed_directory(
        RECOVERY_EVIDENCE_DIR, owner_uid=0, owner_gid=0, exact_mode=0o700
    )
    require_fixed_directory(
        DATABASE_RECEIPTS_DIR, owner_uid=0, owner_gid=0, exact_mode=0o700
    )

    for entry in os.scandir(DATABASE_RECEIPTS_DIR):
        record: dict[str, Any] = {"name": entry.name, "valid": False}
        try:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}\.json", entry.name):
                fail("database recovery receipt filename is not canonical")
            path = DATABASE_RECEIPTS_DIR / entry.name
            raw = stable_read_file(
                path,
                expected_uid=0,
                expected_gid=0,
                maximum_bytes=64 * 1024,
                exact_mode=0o600,
            )
            value = strict_json(raw, "database recovery receipt")
            release_updater.validate_database_recovery_receipt(value)
            version = value["targetVersion"]
            protected.add(version)
            record.update(
                {
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "targetVersion": version,
                    "valid": True,
                }
            )
        except Exception as exc:
            record["error"] = str(exc)
            blockers.append(f"database recovery receipt is unknown or damaged: {entry.name}: {exc}")
        observations["databaseReceipts"].append(record)

    standard_allowed_files = {
        "activation-failed.original.json",
        "boot-enablement.original.json",
        "boot-enablement.recovery.json",
        "recovery-failed.json",
        "recovery-in-progress.completed.json",
        "recovery-in-progress.failed.json",
        "recovery-commit.json",
        "recovery-receipt.json",
        "remain-contained-receipt.json",
    }
    standard_completed_files = {
        "activation-failed.original.json",
        "boot-enablement.recovery.json",
        "recovery-in-progress.completed.json",
        "recovery-commit.json",
        "recovery-receipt.json",
    }
    interrupted_allowed_files = {
        "activation-in-progress.original.json",
        "boot-enablement-in-progress.original.json",
        INTERRUPTED_CONTAINMENT_PLAN,
        INTERRUPTED_CONTAINMENT_RECEIPT,
        "recovery-in-progress.original.json",
        "start-authorization.interrupted.json",
        "start-authorization.precontainment.json",
    }
    evidence_device = RECOVERY_EVIDENCE_DIR.lstat().st_dev
    for entry in os.scandir(RECOVERY_EVIDENCE_DIR):
        transaction = RECOVERY_EVIDENCE_DIR / entry.name
        transaction_record: dict[str, Any] = {
            "files": [],
            "name": entry.name,
            "valid": False,
        }
        transaction_blocked = False
        referenced_database_paths: list[Path] = []
        seen_files: set[str] = set()
        parsed_values: dict[str, dict[str, Any]] = {}
        evidence_sha256: dict[str, str] = {}
        try:
            interrupted_match = INTERRUPTED_RECOVERY_TRANSACTION_RE.fullmatch(entry.name)
            standard_match = RECOVERY_TRANSACTION_RE.fullmatch(entry.name)
            if not interrupted_match and not standard_match:
                fail("recovery transaction directory name is not canonical")
            transaction_kind = "interrupted" if interrupted_match else "standard"
            allowed_files = (
                interrupted_allowed_files
                if transaction_kind == "interrupted"
                else standard_allowed_files
            )
            details = entry.stat(follow_symlinks=False)
            if (
                not stat.S_ISDIR(details.st_mode)
                or details.st_dev != evidence_device
                or details.st_uid != 0
                or details.st_gid != 0
                or stat.S_IMODE(details.st_mode) != 0o700
            ):
                fail("recovery transaction directory owner/mode/type/device is unsafe")
            for file_entry in os.scandir(transaction):
                file_record: dict[str, Any] = {"name": file_entry.name, "valid": False}
                try:
                    if file_entry.name not in allowed_files:
                        fail("recovery transaction contains an unknown evidence file")
                    seen_files.add(file_entry.name)
                    evidence_path = transaction / file_entry.name
                    raw = stable_read_file(
                        evidence_path,
                        expected_uid=0,
                        expected_gid=0,
                        maximum_bytes=MAX_JSON_BYTES,
                        exact_mode=0o600,
                    )
                    value = strict_json(raw, file_entry.name)
                    if transaction_kind == "interrupted":
                        if file_entry.name == "activation-in-progress.original.json":
                            release_updater.validate_activation_in_progress_marker(value)
                        elif file_entry.name == "boot-enablement-in-progress.original.json":
                            release_updater.validate_boot_enablement_marker(value)
                        elif file_entry.name == "recovery-in-progress.original.json":
                            release_updater.validate_recovery_in_progress_marker(value)
                        elif file_entry.name == INTERRUPTED_CONTAINMENT_PLAN:
                            release_updater.validate_interrupted_containment_plan(value)
                        elif file_entry.name == INTERRUPTED_CONTAINMENT_RECEIPT:
                            release_updater.validate_interrupted_containment_receipt(value)
                        elif file_entry.name.startswith("start-authorization."):
                            release_updater.validate_start_authorization(value)
                    else:
                        if file_entry.name == "activation-failed.original.json":
                            release_updater.validate_activation_failure_marker(value)
                        elif file_entry.name.startswith("boot-enablement."):
                            release_updater.validate_boot_enablement_marker(value)
                        elif file_entry.name.startswith("recovery-in-progress."):
                            release_updater.validate_recovery_in_progress_marker(value)
                        elif file_entry.name == "recovery-failed.json":
                            validate_recovery_failure_evidence(value)
                        elif file_entry.name == "recovery-commit.json":
                            target, database_path = validate_recovery_commit_retention(
                                value, transaction
                            )
                            protected.add(target)
                            referenced_database_paths.append(database_path)
                        elif file_entry.name == "recovery-receipt.json":
                            target, database_path = validate_recovery_receipt_retention(
                                value, transaction
                            )
                            protected.add(target)
                            referenced_database_paths.append(database_path)
                        elif file_entry.name == "remain-contained-receipt.json":
                            protected.add(
                                validate_remain_contained_receipt(value, transaction)
                            )
                    for key in (
                        "failedVersion",
                        "previousVersion",
                        "subjectVersion",
                        "targetVersion",
                        "version",
                    ):
                        candidate = value.get(key)
                        if isinstance(candidate, str):
                            release_guard.version_sequence(candidate)
                            protected.add(candidate)
                    parsed_values[file_entry.name] = value
                    evidence_sha256[file_entry.name] = hashlib.sha256(raw).hexdigest()
                    file_record.update(
                        {"sha256": evidence_sha256[file_entry.name], "valid": True}
                    )
                except Exception as exc:
                    file_record["error"] = str(exc)
                    transaction_blocked = True
                    blockers.append(
                        f"recovery transaction evidence is unknown or damaged: "
                        f"{entry.name}/{file_entry.name}: {exc}"
                    )
                transaction_record["files"].append(file_record)
            if transaction_kind == "interrupted":
                plan = parsed_values.get(INTERRUPTED_CONTAINMENT_PLAN)
                receipt = parsed_values.get(INTERRUPTED_CONTAINMENT_RECEIPT)
                interrupted_complete = plan is not None and receipt is not None
                if interrupted_complete:
                    plan_sha = interrupted_match.group(1)
                    archives = receipt["interruptedMarkerArchive"]
                    archive_names = {
                        f"{name}-in-progress.original.json" for name in archives
                    }
                    expected_files = {
                        INTERRUPTED_CONTAINMENT_PLAN,
                        INTERRUPTED_CONTAINMENT_RECEIPT,
                        *archive_names,
                    }
                    authorization = receipt["startAuthorizationArchive"]
                    if authorization is not None:
                        expected_files.add("start-authorization.interrupted.json")
                    if (
                        plan.get("planSha256") != plan_sha
                        or receipt.get("planSha256") != plan_sha
                        or seen_files != expected_files
                    ):
                        interrupted_complete = False
                    for name, archive in archives.items():
                        archive_name = f"{name}-in-progress.original.json"
                        if evidence_sha256.get(archive_name) != archive.get("sha256"):
                            interrupted_complete = False
                    basis_markers = plan.get("planBasis", {}).get("markers")
                    if not isinstance(basis_markers, dict) or set(basis_markers) != set(archives):
                        interrupted_complete = False
                    elif any(
                        basis_markers[name].get("sha256") != archives[name]["sha256"]
                        for name in archives
                    ):
                        interrupted_complete = False
                    if authorization is not None and evidence_sha256.get(
                        "start-authorization.interrupted.json"
                    ) != authorization.get("sha256"):
                        interrupted_complete = False
                if not interrupted_complete:
                    transaction_blocked = True
                    blockers.append(
                        "incomplete/failed interrupted recovery transaction forbids "
                        f"pruning: {entry.name}"
                    )
            elif "remain-contained-receipt.json" in seen_files:
                if seen_files != {"remain-contained-receipt.json"}:
                    transaction_blocked = True
                    blockers.append(
                        f"mixed remain-contained recovery transaction forbids pruning: {entry.name}"
                    )
            else:
                standard_complete = standard_completed_files.issubset(seen_files)
                commit = parsed_values.get("recovery-commit.json")
                receipt = parsed_values.get("recovery-receipt.json")
                if standard_complete and commit is not None and receipt is not None:
                    comparable_commit = dict(commit)
                    comparable_receipt = dict(receipt)
                    comparable_commit.pop("committedAtUtc", None)
                    comparable_receipt.pop("completedAtUtc", None)
                    comparable_commit["status"] = "completed"
                    if comparable_commit != comparable_receipt:
                        standard_complete = False
                if not standard_complete or "recovery-failed.json" in seen_files:
                    transaction_blocked = True
                    blockers.append(
                        f"incomplete/failed recovery transaction forbids pruning: {entry.name}"
                    )
            for database_path in referenced_database_paths:
                if not os.path.lexists(database_path):
                    transaction_blocked = True
                    blockers.append(
                        f"recovery transaction references missing database evidence: {database_path}"
                    )
            transaction_record["valid"] = not transaction_blocked
        except Exception as exc:
            transaction_record["error"] = str(exc)
            blockers.append(f"recovery transaction is unknown or damaged: {entry.name}: {exc}")
        observations["transactions"].append(transaction_record)
    return protected, blockers, observations


def updater_processes(updater_uid: int) -> list[int]:
    found: list[int] = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        status_path = Path("/proc") / name / "status"
        try:
            lines = status_path.read_text(encoding="ascii").splitlines()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise RetentionError(f"cannot inspect updater process ownership: {name}") from exc
        uid_line = next((line for line in lines if line.startswith("Uid:")), None)
        if uid_line is None:
            fail(f"process status has no Uid line: {name}")
        fields = uid_line.split()
        if len(fields) != 5 or any(not item.isdigit() for item in fields[1:]):
            fail(f"process Uid line is malformed: {name}")
        if int(fields[2]) == updater_uid:
            found.append(int(name))
    return sorted(found)


def select_deletions(
    *,
    candidates: list[dict[str, Any]],
    installed: list[dict[str, Any]],
    incoming: list[dict[str, Any]],
    protected_versions: set[str],
    active_version: str | None,
    policy: dict[str, int],
) -> tuple[list[dict[str, Any]], dict[str, Any], list[str]]:
    verified_candidates = sorted(
        (item for item in candidates if item.get("verified")),
        key=lambda item: item["releaseSequence"],
        reverse=True,
    )
    verified_installed = sorted(
        (item for item in installed if item.get("verified")),
        key=lambda item: item["releaseSequence"],
        reverse=True,
    )
    keep_candidates = {
        item["version"] for item in verified_candidates[: policy["keepVerifiedCandidates"]]
    }
    keep_installed = {
        item["version"] for item in verified_installed[: policy["keepVerifiedInstalled"]]
    }
    alerts: list[str] = []
    predecessor: str | None = None
    if active_version is not None:
        active_sequence = release_guard.version_sequence(active_version)
        predecessors = [
            item for item in verified_installed if item["releaseSequence"] < active_sequence
        ]
        if predecessors:
            predecessor = predecessors[0]["version"]
            protected_versions.add(predecessor)
        else:
            alerts.append("no verified installed predecessor exists; no installed release is prunable")
    eligible: list[dict[str, Any]] = []
    for item in verified_candidates:
        if (
            item["version"] not in protected_versions
            and item["version"] not in keep_candidates
            and item["ageSeconds"] >= policy["minimumAgeSeconds"]
        ):
            eligible.append(item)
    installed_pruning_allowed = predecessor is not None
    if installed_pruning_allowed:
        for item in verified_installed:
            if (
                item["version"] not in protected_versions
                and item["version"] not in keep_installed
                and item["ageSeconds"] >= policy["minimumAgeSeconds"]
            ):
                eligible.append(item)
    eligible.extend(item for item in incoming if item.get("verified") and item.get("eligible"))
    protection = {
        "fallbackPredecessor": predecessor,
        "newestVerifiedCandidates": sorted(keep_candidates),
        "newestVerifiedInstalled": sorted(keep_installed),
        "protectedVersions": sorted(protected_versions),
    }
    return eligible, protection, alerts


def timer_observations() -> tuple[dict[str, Any], list[str]]:
    observations: dict[str, Any] = {}
    blockers: list[str] = []
    for unit in (UPDATER_TIMER, RETENTION_TIMER):
        state = release_updater.systemd_property(unit, "UnitFileState")
        observations[unit] = {"unitFileState": state}
        if state not in {"disabled", "masked"}:
            blockers.append(f"timer must remain disabled during commissioning: {unit}={state}")
    return observations, blockers


def build_audit(policy: dict[str, int], policy_sha256: str) -> dict[str, Any]:
    release_updater.authorized_key_ids(ALLOWED_SIGNERS)
    account = pwd.getpwnam(release_updater.UPDATER_USER)
    updater_gid = grp.getgrnam(release_updater.UPDATER_USER).gr_gid
    require_fixed_directory(STATE_DIR, owner_uid=account.pw_uid, owner_gid=updater_gid)
    require_fixed_directory(CANDIDATES_DIR, owner_uid=account.pw_uid, owner_gid=updater_gid)
    require_fixed_directory(ROOT_STATE_DIR, owner_uid=0, owner_gid=updater_gid)
    require_fixed_directory(RECEIPTS_DIR, owner_uid=0, owner_gid=0, exact_mode=0o700)
    require_fixed_directory(ALERTS_DIR, owner_uid=0, owner_gid=0, exact_mode=0o700)
    require_fixed_directory(VERIFY_DIR, owner_uid=0, owner_gid=0, exact_mode=0o700)
    require_fixed_directory(STAGING_QUARANTINE, owner_uid=0, owner_gid=0, exact_mode=0o700)
    require_fixed_directory(RELEASE_BASE, owner_uid=0, owner_gid=0)
    require_fixed_directory(RELEASES_DIR, owner_uid=0, owner_gid=0)
    require_fixed_directory(INSTALLED_QUARANTINE, owner_uid=0, owner_gid=0, exact_mode=0o700)

    blockers: list[str] = []
    alerts: list[str] = []
    staging_quota = quota_observation(
        STATE_DIR, policy["stagingProjectId"], policy["stagingProjectHardBytes"]
    )
    installed_quota = quota_observation(
        RELEASES_DIR,
        policy["installedProjectId"],
        policy["installedProjectHardBytes"],
    )
    add_quota_capacity(staging_quota, policy)
    add_quota_capacity(installed_quota, policy)
    if not staging_quota["valid"]:
        blockers.append("staging project quota is not proven")
    if not installed_quota["valid"]:
        blockers.append("installed-release project quota is not proven")
    for label, value in (("staging", staging_quota), ("installed", installed_quota)):
        if value.get("severity") not in {None, "ok"}:
            alerts.append(f"{label} project quota headroom is {value['severity']}")
    if STATE_DIR.lstat().st_dev != STAGING_QUARANTINE.lstat().st_dev:
        blockers.append("staging quarantine is cross-device; atomic quarantine is impossible")
    if RELEASES_DIR.lstat().st_dev != INSTALLED_QUARANTINE.lstat().st_dev:
        blockers.append("installed quarantine is cross-device; atomic quarantine is impossible")

    staging_quarantine, staging_quarantine_blockers = observe_quarantine(
        path=STAGING_QUARANTINE,
        updater_uid=account.pw_uid,
        updater_gid=updater_gid,
        policy=policy,
    )
    installed_quarantine, installed_quarantine_blockers = observe_quarantine(
        path=INSTALLED_QUARANTINE,
        updater_uid=account.pw_uid,
        updater_gid=updater_gid,
        policy=policy,
    )
    blockers.extend(staging_quarantine_blockers + installed_quarantine_blockers)

    active_state = release_updater.systemd_property(UPDATER_SERVICE, "ActiveState")
    process_ids = updater_processes(account.pw_uid)
    process_observation = {
        "pids": process_ids,
        "serviceActiveState": active_state,
    }
    if active_state not in {"inactive", "failed"}:
        blockers.append("updater service state is active or indeterminate")
    if process_ids:
        blockers.append("one or more updater-UID processes are running")

    protected, marker_blockers, marker_alerts, references = marker_references()
    blockers.extend(marker_blockers)
    alerts.extend(marker_alerts)
    recovery_protected, recovery_blockers, recovery_observations = recovery_references()
    protected.update(recovery_protected)
    blockers.extend(recovery_blockers)
    references["recoveryEvidence"] = recovery_observations
    timers, timer_blockers = timer_observations()
    blockers.extend(timer_blockers)

    now_ns = time.time_ns()
    candidates, candidate_alerts = inventory_release_directories(
        kind="candidate",
        parent=CANDIDATES_DIR,
        expected_uid=account.pw_uid,
        expected_gid=updater_gid,
        expected_project_id=policy["stagingProjectId"],
        now_ns=now_ns,
    )
    installed, installed_alerts = inventory_release_directories(
        kind="installed",
        parent=RELEASES_DIR,
        expected_uid=0,
        expected_gid=0,
        expected_project_id=policy["installedProjectId"],
        now_ns=now_ns,
    )
    incoming, incoming_alerts = inventory_incoming(
        updater_uid=account.pw_uid,
        updater_gid=updater_gid,
        project_id=policy["stagingProjectId"],
        now_ns=now_ns,
        ttl_seconds=policy["incomingTtlSeconds"],
    )
    alerts.extend(candidate_alerts + installed_alerts + incoming_alerts)

    active_version: str | None = None
    active_observation = references.get("active.json")
    if isinstance(active_observation, dict) and active_observation.get("valid"):
        active_version = active_observation["fields"]["version"]
        protected.add(active_version)
    else:
        blockers.append("valid root-owned active release evidence is absent")

    deletions, protection, selection_alerts = select_deletions(
        candidates=candidates,
        installed=installed,
        incoming=incoming,
        protected_versions=protected,
        active_version=active_version,
        policy=policy,
    )
    alerts.extend(selection_alerts)
    capacity = {
        "installed": capacity_observation(RELEASES_DIR, policy),
        "staging": capacity_observation(STATE_DIR, policy),
    }
    for label, value in capacity.items():
        if value["severity"] != "ok":
            alerts.append(f"{label} capacity is {value['severity']}")

    plan = {
        "alerts": sorted(set(alerts)),
        "blockers": sorted(set(blockers)),
        "capacity": capacity,
        "deletions": [
            {
                key: item[key]
                for key in (
                    "ageSeconds",
                    "bytes",
                    "device",
                    "inode",
                    "kind",
                    "maximumMtimeNs",
                    "name",
                    "path",
                )
                if key in item
            }
            for item in deletions
        ],
        "inventory": {
            "candidates": candidates,
            "incoming": incoming,
            "installed": installed,
        },
        "policySha256": policy_sha256,
        "processes": process_observation,
        "protection": protection,
        "quota": {"installed": installed_quota, "staging": staging_quota},
        "quarantine": {
            "installed": installed_quarantine,
            "staging": staging_quarantine,
        },
        "references": references,
        "timers": timers,
    }
    plan["planSha256"] = canonical_sha256(plan)
    return plan


def delete_contents_fd(
    descriptor: int,
    *,
    expected_dev: int,
    expected_uid: int,
    expected_gid: int,
    expected_project_id: int,
) -> None:
    for entry in list(os.scandir(descriptor)):
        details = entry.stat(follow_symlinks=False)
        if (
            details.st_dev != expected_dev
            or details.st_uid != expected_uid
            or details.st_gid != expected_gid
            or details.st_mode & 0o022
        ):
            fail("quarantined tree changed owner/mode/device during cleanup")
        if stat.S_ISDIR(details.st_mode):
            child_fd = os.open(
                entry.name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child_fd)
                if (opened.st_dev, opened.st_ino) != (details.st_dev, details.st_ino):
                    fail("quarantined directory changed during cleanup")
                ensure_project_fd(child_fd, expected_project_id, directory=True)
                delete_contents_fd(
                    child_fd,
                    expected_dev=expected_dev,
                    expected_uid=expected_uid,
                    expected_gid=expected_gid,
                    expected_project_id=expected_project_id,
                )
                os.fsync(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(entry.name, dir_fd=descriptor)
        elif stat.S_ISREG(details.st_mode):
            if details.st_nlink != 1:
                fail("quarantined regular file acquired another hard link")
            child_fd = os.open(
                entry.name,
                os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child_fd)
                if (opened.st_dev, opened.st_ino) != (details.st_dev, details.st_ino):
                    fail("quarantined regular file changed during cleanup")
                ensure_project_fd(child_fd, expected_project_id, directory=False)
            finally:
                os.close(child_fd)
            os.unlink(entry.name, dir_fd=descriptor)
        else:
            fail("quarantined tree gained a symlink or special file")
    os.fsync(descriptor)


def quarantine_and_delete(
    item: dict[str, Any],
    *,
    updater_uid: int,
    updater_gid: int,
    policy: dict[str, int],
    transaction_id: str,
) -> dict[str, Any]:
    require_runtime_trust()
    kind = item["kind"]
    if kind in {"candidate", "incoming"}:
        source_parent = CANDIDATES_DIR if kind == "candidate" else STATE_DIR
        quarantine = STAGING_QUARANTINE
        expected_uid = updater_uid
        expected_gid = updater_gid
        project_id = policy["stagingProjectId"]
    elif kind == "installed":
        source_parent = RELEASES_DIR
        quarantine = INSTALLED_QUARANTINE
        expected_uid = 0
        expected_gid = 0
        project_id = policy["installedProjectId"]
    else:
        fail("retention deletion kind is unsupported")
    source_name = item["name"]
    source_fd, tree, details = validate_tree_at(
        source_parent,
        source_name,
        expected_uid=expected_uid,
        expected_gid=expected_gid,
        expected_project_id=project_id,
        expected_dev=item["device"],
    )
    if (
        details.st_ino != item["inode"]
        or tree["maximumMtimeNs"] != item["maximumMtimeNs"]
        or tree["bytes"] != item["bytes"]
    ):
        os.close(source_fd)
        fail("retention source changed after audit plan creation")
    source_parent_fd = os.open(
        source_parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    quarantine_fd = os.open(
        quarantine,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    destination_name = f"{transaction_id}-{kind}-{source_name}"
    if len(destination_name) > 240 or os.path.lexists(quarantine / destination_name):
        os.close(source_fd)
        os.close(source_parent_fd)
        os.close(quarantine_fd)
        fail("retention quarantine destination is unsafe or already exists")
    try:
        opened_source_parent = verify_open_directory(
            source_parent_fd,
            source_parent,
            owner_uid=expected_uid,
            owner_gid=expected_gid,
        )
        opened_quarantine = verify_open_directory(
            quarantine_fd,
            quarantine,
            owner_uid=0,
            owner_gid=0,
            exact_mode=0o700,
        )
        current_source = os.stat(
            source_name, dir_fd=source_parent_fd, follow_symlinks=False
        )
        if (current_source.st_dev, current_source.st_ino) != (
            details.st_dev,
            details.st_ino,
        ):
            fail("retention source parent or child changed before quarantine")
        if opened_source_parent.st_dev != opened_quarantine.st_dev:
            fail("retention quarantine unexpectedly crossed filesystems")
        require_runtime_trust()
        os.rename(
            source_name,
            destination_name,
            src_dir_fd=source_parent_fd,
            dst_dir_fd=quarantine_fd,
        )
        os.fsync(quarantine_fd)
        os.fsync(source_parent_fd)
        moved = os.stat(destination_name, dir_fd=quarantine_fd, follow_symlinks=False)
        opened = os.fstat(source_fd)
        if (moved.st_dev, moved.st_ino) != (opened.st_dev, opened.st_ino):
            fail("quarantine rename did not move the audited inode")
        require_runtime_trust()
        delete_contents_fd(
            source_fd,
            expected_dev=item["device"],
            expected_uid=expected_uid,
            expected_gid=expected_gid,
            expected_project_id=project_id,
        )
        os.close(source_fd)
        source_fd = -1
        os.rmdir(destination_name, dir_fd=quarantine_fd)
        os.fsync(quarantine_fd)
    finally:
        if source_fd >= 0:
            os.close(source_fd)
        os.close(source_parent_fd)
        os.close(quarantine_fd)
    return {
        "bytes": item["bytes"],
        "kind": kind,
        "name": source_name,
        "quarantineName": destination_name,
        "status": "deleted-after-durable-quarantine",
    }


def archive_retention_marker(transaction_id: str) -> Path:
    require_runtime_trust()
    raw = release_updater.read_root_evidence_bytes(RETENTION_MARKER)
    destination = RECEIPTS_DIR / f"{transaction_id}.transaction.json"
    expected_sha256 = hashlib.sha256(raw).hexdigest()
    try:
        release_updater.archive_root_evidence(
            RETENTION_MARKER, destination, expected_sha256
        )
    except Exception:
        # A destination-first durable rename may have succeeded before a later
        # fsync/re-read failed. Re-establish the fixed fail-closed marker before
        # returning an error so a subsequent prune cannot silently continue.
        if not os.path.lexists(RETENTION_MARKER):
            if os.path.lexists(destination):
                archived = release_updater.read_root_evidence_bytes(destination)
                if hashlib.sha256(archived).hexdigest() != expected_sha256:
                    fail("retention transaction evidence changed during failed archive")
                require_runtime_trust()
                os.replace(destination, RETENTION_MARKER)
                release_updater.fsync_directory(ROOT_STATE_DIR)
                release_updater.fsync_directory(RECEIPTS_DIR)
            else:
                require_runtime_trust()
                release_updater.atomic_bytes(RETENTION_MARKER, raw, mode=0o600)
        restored = release_updater.read_root_evidence_bytes(RETENTION_MARKER)
        if hashlib.sha256(restored).hexdigest() != expected_sha256:
            fail("retention in-progress marker could not be restored exactly")
        raise
    return destination


def receipt_name(operation: str, transaction_id: str) -> str:
    return f"{transaction_id}.{operation}.json"


def execute_audit(operation: str) -> tuple[dict[str, Any], int]:
    require_runtime_trust()
    if os.geteuid() != 0:
        fail("retention audit/prune must run explicitly as root")
    if operation not in {"audit", "prune"}:
        fail("retention operation is unsupported")
    policy, policy_sha = load_policy()
    transaction_id = f"{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex}"
    started = utc_now()
    with release_updater.StateLock(LOCK_PATH):
        try:
            plan = build_audit(policy, policy_sha)
        except Exception as audit_error:
            failure_receipt = {
                "completedAtUtc": utc_now(),
                "error": str(audit_error),
                "operation": operation,
                "policySha256": policy_sha,
                "schemaVersion": 1,
                "startedAtUtc": started,
                "status": "failed-closed",
                "transactionId": transaction_id,
            }
            try:
                path = write_new_json(
                    RECEIPTS_DIR,
                    f"{transaction_id}.{operation}-failed.json",
                    failure_receipt,
                )
            except Exception as receipt_error:
                raise RetentionError(
                    "retention audit failed and its durable failure receipt could not be written"
                ) from receipt_error
            failure_receipt["receiptPath"] = str(path)
            return failure_receipt, 1
        receipt: dict[str, Any] = {
            "actions": [],
            "completedAtUtc": utc_now(),
            "operation": operation,
            "plan": plan,
            "schemaVersion": 1,
            "startedAtUtc": started,
            "status": "audited",
            "transactionId": transaction_id,
        }
        if operation == "audit":
            if plan["blockers"] or plan["alerts"]:
                receipt["status"] = "NO-GO"
            path = write_new_json(RECEIPTS_DIR, receipt_name(operation, transaction_id), receipt)
            receipt["receiptPath"] = str(path)
            return receipt, 1 if receipt["status"] == "NO-GO" else 0

        if plan["blockers"]:
            receipt["status"] = "refused"
            path = write_new_json(RECEIPTS_DIR, receipt_name(operation, transaction_id), receipt)
            receipt["receiptPath"] = str(path)
            return receipt, 1

        require_runtime_trust()
        release_updater.atomic_json(
            RETENTION_MARKER,
            {
                "operation": "prune",
                "planSha256": plan["planSha256"],
                "policySha256": policy_sha,
                "schemaVersion": 1,
                "startedAtUtc": started,
                "transactionId": transaction_id,
            },
            mode=0o600,
        )
        release_updater.require_root_controlled_file(RETENTION_MARKER, secret=True)
        marker_raw = release_updater.read_root_evidence_bytes(RETENTION_MARKER)
        marker_sha256 = hashlib.sha256(marker_raw).hexdigest()
        account = pwd.getpwnam(release_updater.UPDATER_USER)
        updater_gid = grp.getgrnam(release_updater.UPDATER_USER).gr_gid
        try:
            for item in plan["deletions"]:
                receipt["actions"].append(
                    quarantine_and_delete(
                        item,
                        updater_uid=account.pw_uid,
                        updater_gid=updater_gid,
                        policy=policy,
                        transaction_id=transaction_id,
                    )
                )
            post_capacity = {
                "installed": capacity_observation(RELEASES_DIR, policy),
                "staging": capacity_observation(STATE_DIR, policy),
            }
            post_quota = {
                "installed": quota_observation(
                    RELEASES_DIR,
                    policy["installedProjectId"],
                    policy["installedProjectHardBytes"],
                ),
                "staging": quota_observation(
                    STATE_DIR,
                    policy["stagingProjectId"],
                    policy["stagingProjectHardBytes"],
                ),
            }
            add_quota_capacity(post_quota["installed"], policy)
            add_quota_capacity(post_quota["staging"], policy)
            if not all(item["valid"] for item in post_quota.values()):
                fail("project quota could not be re-proven after retention pruning")
            receipt["postPrune"] = {
                "capacity": post_capacity,
                "quota": post_quota,
            }
            receipt["completedAtUtc"] = utc_now()
            receipt["status"] = "actions-completed-awaiting-transaction-close"
            actions_path = write_new_json(
                RECEIPTS_DIR,
                receipt_name("prune-actions", transaction_id),
                receipt,
            )
            actions_sha256 = release_guard.sha256_file(actions_path)
            transaction_path = archive_retention_marker(transaction_id)
            receipt["actionEvidence"] = {
                "path": str(actions_path),
                "sha256": actions_sha256,
            }
            receipt["transactionEvidence"] = {
                "path": str(transaction_path),
                "sha256": marker_sha256,
            }
            receipt["status"] = "completed-with-alerts" if plan["alerts"] else "completed"
            path = write_new_json(
                RECEIPTS_DIR, receipt_name(operation, transaction_id), receipt
            )
            receipt["receiptPath"] = str(path)
            receipt["transactionEvidencePath"] = str(transaction_path)
            return receipt, 1 if plan["alerts"] else 0
        except Exception as exc:
            receipt["completedAtUtc"] = utc_now()
            receipt["error"] = str(exc)
            receipt["status"] = "failed-closed"
            if not os.path.lexists(RETENTION_MARKER):
                try:
                    require_runtime_trust()
                    release_updater.atomic_bytes(RETENTION_MARKER, marker_raw, mode=0o600)
                    restored = release_updater.read_root_evidence_bytes(RETENTION_MARKER)
                    if hashlib.sha256(restored).hexdigest() != marker_sha256:
                        fail("retention marker restoration digest is wrong")
                except Exception as restore_exc:
                    receipt["markerRestoreError"] = str(restore_exc)
            try:
                path = write_new_json(
                    RECEIPTS_DIR, f"{transaction_id}.prune-failed.json", receipt
                )
                receipt["receiptPath"] = str(path)
            except Exception:
                pass
            # The in-progress marker and any partially-cleared root-only quarantine
            # intentionally remain. A later prune must refuse until adjudicated.
            raise


def validate_alert_sink() -> None:
    release_updater.require_root_controlled_file(ALERT_SINK)
    details = ALERT_SINK.lstat()
    if details.st_nlink != 1 or not details.st_mode & 0o111:
        fail("fixed external retention alert sink is not single-link executable")


def validate_alert_event(value: dict[str, Any]) -> dict[str, Any]:
    expected = {
        "alertId",
        "containsSecrets",
        "createdAtUtc",
        "failedUnit",
        "latestReceiptDirectory",
        "requiredAction",
        "schemaVersion",
        "severity",
        "source",
        "summary",
    }
    if set(value) != expected:
        fail("retention alert event exact key set is invalid")
    alert_id = value.get("alertId")
    if not isinstance(alert_id, str) or not ALERT_ID_RE.fullmatch(alert_id):
        fail("retention alert ID is malformed")
    if value.get("schemaVersion") != 1 or isinstance(value.get("schemaVersion"), bool):
        fail("retention alert schema is unsupported")
    if value.get("severity") != "critical" or value.get("source") != "uten-imp-release-retention":
        fail("retention alert source/severity is invalid")
    unit = value.get("failedUnit")
    if unit != "uten-imp-retention.service":
        fail("retention alert unit is outside the fixed allowlist")
    timestamp = value.get("createdAtUtc")
    if not isinstance(timestamp, str) or not UTC_RE.fullmatch(timestamp):
        fail("retention alert timestamp is malformed")
    if value.get("containsSecrets") is not False:
        fail("retention alert must explicitly contain no secrets")
    if value.get("latestReceiptDirectory") != str(RECEIPTS_DIR):
        fail("retention alert receipt path is not fixed")
    for key in ("requiredAction", "summary"):
        text = value.get(key)
        if not isinstance(text, str) or not 1 <= len(text) <= 512:
            fail(f"retention alert {key} is malformed")
    return value


def validate_alert_receipt(value: dict[str, Any], event: dict[str, Any]) -> dict[str, Any]:
    expected = {
        "accepted",
        "alertId",
        "deliveredAtUtc",
        "providerMessageId",
        "schemaVersion",
    }
    if set(value) != expected:
        fail("external retention alert receipt exact key set is invalid")
    if (
        value.get("schemaVersion") != 1
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("accepted") is not True
        or value.get("alertId") != event["alertId"]
    ):
        fail("external retention alert receipt does not acknowledge this event")
    timestamp = value.get("deliveredAtUtc")
    if not isinstance(timestamp, str) or not UTC_RE.fullmatch(timestamp):
        fail("external retention alert receipt timestamp is malformed")
    provider_message_id = value.get("providerMessageId")
    if (
        not isinstance(provider_message_id, str)
        or not PROVIDER_MESSAGE_ID_RE.fullmatch(provider_message_id)
    ):
        fail("external retention alert provider message ID is malformed")
    return value


def read_alert_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    raw = stable_read_file(
        path,
        expected_uid=0,
        expected_gid=0,
        maximum_bytes=64 * 1024,
        exact_mode=0o600,
    )
    return strict_json(raw, label), raw


def alert_spool() -> list[Path]:
    pending: list[Path] = []
    pending_bytes = 0
    evidence: dict[str, dict[str, Path]] = {}
    for entry in os.scandir(ALERTS_DIR):
        if not entry.name.endswith(".json"):
            fail(f"unknown retention alert spool entry is present: {entry.name}")
        matched = re.fullmatch(
            rf"({ALERT_ID_RE.pattern})\.(pending|delivered|receipt)\.json", entry.name
        )
        if matched is None:
            fail(f"unknown or interrupted retention alert evidence is present: {entry.name}")
        details = entry.stat(follow_symlinks=False)
        if (
            not stat.S_ISREG(details.st_mode)
            or details.st_uid != 0
            or details.st_gid != 0
            or stat.S_IMODE(details.st_mode) != 0o600
            or details.st_nlink != 1
            or details.st_size < 2
            or details.st_size > 64 * 1024
        ):
            fail(f"retention alert evidence is unsafe: {entry.name}")
        alert_id = matched.group(1)
        kind = matched.group(2)
        evidence.setdefault(alert_id, {})[kind] = ALERTS_DIR / entry.name
        if kind == "pending":
            pending.append(evidence[alert_id][kind])
            pending_bytes += details.st_size
    if len(pending) > MAX_PENDING_ALERTS or pending_bytes > MAX_PENDING_ALERT_BYTES:
        fail("retention alert pending spool exceeds its fixed quota")
    for alert_id, records in evidence.items():
        if "pending" in records and "delivered" in records:
            fail(f"retention alert has both pending and delivered evidence: {alert_id}")
        event_path = records.get("pending") or records.get("delivered")
        if event_path is None:
            fail(f"retention alert receipt has no matching event evidence: {alert_id}")
        event_value, _event_raw = read_alert_json(event_path, "retention alert event")
        event = validate_alert_event(event_value)
        if event["alertId"] != alert_id:
            fail("retention alert evidence filename disagrees with its event ID")
        receipt_path = records.get("receipt")
        if "delivered" in records and receipt_path is None:
            fail(f"delivered retention alert has no provider receipt: {alert_id}")
        if receipt_path is not None:
            receipt_value, _receipt_raw = read_alert_json(
                receipt_path, "external retention alert receipt"
            )
            validate_alert_receipt(receipt_value, event)
    return sorted(pending)


def deliver_alert(pending: Path) -> bool:
    require_runtime_trust()
    event_value, event_raw = read_alert_json(pending, "pending retention alert")
    event = validate_alert_event(event_value)
    alert_id = event["alertId"]
    if pending.name != f"{alert_id}.pending.json":
        fail("pending retention alert filename disagrees with its event ID")
    receipt_path = ALERTS_DIR / f"{alert_id}.receipt.json"
    work_path = ALERTS_DIR / f"{alert_id}.receipt-work.json"
    delivered_path = ALERTS_DIR / f"{alert_id}.delivered.json"
    if os.path.lexists(delivered_path):
        fail("delivered retention alert evidence already exists while pending remains")
    if os.path.lexists(work_path):
        fail("interrupted external retention alert receipt work file exists")
    if os.path.lexists(receipt_path):
        receipt_value, _receipt_raw = read_alert_json(
            receipt_path, "external retention alert receipt"
        )
        validate_alert_receipt(receipt_value, event)
    else:
        validate_alert_sink()
        require_runtime_trust()
        completed = subprocess.run(
            [
                str(ALERT_SINK),
                "--event-file",
                str(pending),
                "--receipt-file",
                str(work_path),
            ],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
            env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
        )
        if completed.returncode != 0 or not os.path.lexists(work_path):
            return False
        work_value, _work_raw = read_alert_json(
            work_path, "external retention alert receipt"
        )
        validate_alert_receipt(work_value, event)
        require_runtime_trust()
        os.replace(work_path, receipt_path)
        release_updater.fsync_directory(ALERTS_DIR)
    current_raw = stable_read_file(
        pending,
        expected_uid=0,
        expected_gid=0,
        maximum_bytes=64 * 1024,
        exact_mode=0o600,
    )
    if current_raw != event_raw:
        fail("pending retention alert changed during external delivery")
    require_runtime_trust()
    os.replace(pending, delivered_path)
    release_updater.fsync_directory(ALERTS_DIR)
    return True


def dispatch_alert(unit: str) -> tuple[dict[str, Any], int]:
    require_runtime_trust()
    if os.geteuid() != 0:
        fail("retention alert dispatch must run as root")
    if not UNIT_RE.fullmatch(unit) or unit != "uten-imp-retention.service":
        fail("retention alert unit is outside the fixed allowlist")
    require_fixed_directory(ALERTS_DIR, owner_uid=0, owner_gid=0, exact_mode=0o700)
    with release_updater.StateLock(LOCK_PATH):
        pending_events = alert_spool()
        for existing in pending_events:
            if not deliver_alert(existing):
                return {"alertPath": str(existing), "status": "pending", "unit": unit}, 1
        if len(pending_events) >= MAX_PENDING_ALERTS:
            fail("retention alert pending-event quota is full")
        alert_id = f"{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex}"
        pending = write_new_json(
            ALERTS_DIR,
            f"{alert_id}.pending.json",
            {
                "alertId": alert_id,
                "containsSecrets": False,
                "createdAtUtc": utc_now(),
                "failedUnit": unit,
                "latestReceiptDirectory": str(RECEIPTS_DIR),
                "requiredAction": (
                    "keep both retention and staging timers disabled; inspect the latest "
                    "root-only receipt and remediate before an approved retry"
                ),
                "schemaVersion": 1,
                "severity": "critical",
                "source": "uten-imp-release-retention",
                "summary": "release retention prune failed or completed with NO-GO alerts",
            },
        )
        if not deliver_alert(pending):
            return {"alertPath": str(pending), "status": "pending", "unit": unit}, 1
        delivered = ALERTS_DIR / f"{alert_id}.delivered.json"
        return {"alertPath": str(delivered), "status": "delivered", "unit": unit}, 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Uten IMP fixed-path release retention manager")
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("audit")
    commands.add_parser("prune")
    alert = commands.add_parser("alert")
    alert.add_argument("--unit", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command in {"audit", "prune"}:
            result, status = execute_audit(args.command)
        elif args.command == "alert":
            result, status = dispatch_alert(args.unit)
        else:
            fail("unsupported retention command")
        print(json.dumps(result, ensure_ascii=True, indent=2, sort_keys=True))
        return status
    except (
        OSError,
        subprocess.SubprocessError,
        release_guard.ReleaseGuardError,
        release_updater.UpdaterError,
        RetentionError,
    ) as exc:
        print(
            json.dumps(
                {
                    "error": str(exc),
                    "kind": "uten-imp-retention-error",
                    "schemaVersion": 1,
                    "status": "failed-closed",
                },
                ensure_ascii=True,
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
