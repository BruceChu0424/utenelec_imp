#!/usr/bin/env python3
"""Fail-closed pgBackRest repo2 policy/evidence validator and candidate renderer.

This tool never installs an active configuration.  ``render-candidate`` only
creates a new, non-/etc file after an exact confirmation and never prints
credential values.  Activation remains a separately approved root change.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
RENDER_CONFIRMATION = "RENDER VERIFIED UTEN PGBACKREST REPO2 CANDIDATE"
PLACEHOLDER_MARKERS = ("REPLACE", "CHANGEME", "EXAMPLE", "__")
HEX_SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$")
SAFE_BUCKET = re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")
SAFE_ENDPOINT = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z]{2,63}$"
)
SAFE_REGION = re.compile(r"^[a-z0-9][a-z0-9-]{1,62}$")
SAFE_REPO_PATH = re.compile(r"^/[A-Za-z0-9][A-Za-z0-9._/-]{0,510}$")
SAFE_SECRET = re.compile(r"^[A-Za-z0-9+/=_.,:@%~-]{16,512}$")
UTC_TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
APPROVAL_REFERENCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{2,127}$")
REPO1_OVERRIDE_PATH = Path("/etc/systemd/system/uten-pgbackup.service")
# Field names in the already-reviewed approval schema retain "repo1Override" for
# compatibility, but the accepted bytes are now a full unit. systemd dependency
# lists cannot be cleared safely from a drop-in.
REPO1_OVERRIDE = b"""[Unit]
Description=Uten IMP PostgreSQL daily pgBackRest repo1 full backup
Documentation=file:/usr/local/share/doc/uten-imp-backup/README.zh-CN.md
After=postgresql@16-main.service
OnFailure=uten-pgbackup-alert@%n.service
StartLimitIntervalSec=3h
StartLimitBurst=8
StartLimitAction=none

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/activation-failed.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/activation-in-progress.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/boot-enablement-in-progress.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-in-progress.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-pending.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-authorization.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/recovery-ingress-finalizing.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-onboarding-adoption.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-release/internal-test-activation-reauthorization.json
ExecStartPre=+/usr/bin/test ! -e /var/lib/uten-imp-backup-commissioner/active-transaction.json
ExecStart=/usr/bin/python3 -I /usr/local/libexec/uten-imp-backup/locked_job.py repo1
Restart=on-failure
RestartPreventExitStatus=78 130 SIGHUP SIGINT SIGQUIT SIGILL SIGABRT SIGBUS SIGFPE SIGKILL SIGSEGV SIGPIPE SIGALRM SIGTERM SIGUSR1 SIGUSR2 SIGXCPU SIGXFSZ SIGVTALRM SIGPROF SIGIO SIGPWR SIGSYS
RestartSec=15m
CapabilityBoundingSet=CAP_SETUID CAP_SETGID
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/uten-imp-backup-transactions
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
TimeoutStartSec=12h
"""


class ContractError(ValueError):
    """Raised when a commissioning input violates the reviewed contract."""


@dataclass(frozen=True)
class Repo2Policy:
    stanza: str
    path: str
    bucket: str
    endpoint: str
    region: str
    uri_style: str
    retention_full: int
    retention_archive: int
    minimum_restore_points: int
    maximum_full_age_seconds: int
    maximum_archive_age_seconds: int
    minimum_immutable_days: int


def _require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ContractError(f"{label} keys differ: missing={missing}, extra={extra}")


def _load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ContractError(f"cannot read {label}: {exc}") from exc
    if len(raw) > 64 * 1024:
        raise ContractError(f"{label} exceeds 64 KiB")
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ContractError(f"{label} must not contain a UTF-8 BOM")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ContractError(f"{label} is not canonical UTF-8 JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be one JSON object")
    return value


def _parse_utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not UTC_TIMESTAMP.fullmatch(value):
        raise ContractError(f"{label} must use YYYY-MM-DDTHH:MM:SSZ")
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def _positive_int(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError(f"{label} must be an integer")
    if value < minimum or value > maximum:
        raise ContractError(f"{label} must be between {minimum} and {maximum}")
    return value


def parse_policy(value: dict[str, Any]) -> Repo2Policy:
    _require_exact_keys(value, {"schemaVersion", "stanza", "repo2", "health"}, "policy")
    if value["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError("unsupported policy schemaVersion")
    stanza = value["stanza"]
    if not isinstance(stanza, str) or not SAFE_NAME.fullmatch(stanza):
        raise ContractError("stanza is not a safe pgBackRest stanza name")
    if stanza != "uten-imp":
        raise ContractError("repo2 policy stanza must be the fixed uten-imp stanza")

    repo = value["repo2"]
    if not isinstance(repo, dict):
        raise ContractError("repo2 must be an object")
    _require_exact_keys(
        repo,
        {
            "type",
            "path",
            "s3Bucket",
            "s3Endpoint",
            "s3Region",
            "s3UriStyle",
            "storageVerifyTls",
            "cipherType",
            "retentionFullType",
            "retentionFull",
            "retentionArchiveType",
            "retentionArchive",
            "minimumImmutableDays",
        },
        "policy.repo2",
    )
    if repo["type"] != "s3":
        raise ContractError("only a separately accepted S3-compatible repo2 is supported")
    path = repo["path"]
    if (
        not isinstance(path, str)
        or not SAFE_REPO_PATH.fullmatch(path)
        or path == "/"
        or path.endswith("/")
        or "//" in path
        or ".." in path.split("/")
        or len(path) > 512
    ):
        raise ContractError("repo2.path must be a dedicated absolute object prefix")
    bucket = repo["s3Bucket"]
    if (
        not isinstance(bucket, str)
        or not SAFE_BUCKET.fullmatch(bucket)
        or ".." in bucket
        or any(marker in bucket.upper() for marker in PLACEHOLDER_MARKERS)
    ):
        raise ContractError("repo2.s3Bucket is not a safe bucket name")
    endpoint = repo["s3Endpoint"]
    if (
        not isinstance(endpoint, str)
        or not SAFE_ENDPOINT.fullmatch(endpoint)
        or any(marker in endpoint.upper() for marker in PLACEHOLDER_MARKERS)
    ):
        raise ContractError("repo2.s3Endpoint must be a TLS DNS name without scheme or path")
    region = repo["s3Region"]
    if (
        not isinstance(region, str)
        or not SAFE_REGION.fullmatch(region)
        or any(marker in region.upper() for marker in PLACEHOLDER_MARKERS)
    ):
        raise ContractError("repo2.s3Region is invalid")
    if repo["s3UriStyle"] not in {"host", "path"}:
        raise ContractError("repo2.s3UriStyle must be host or path")
    if repo["storageVerifyTls"] is not True:
        raise ContractError("repo2 TLS certificate verification must stay enabled")
    if repo["cipherType"] != "aes-256-cbc":
        raise ContractError("repo2 client-side encryption must be aes-256-cbc")
    if repo["retentionFullType"] != "count" or repo["retentionArchiveType"] != "full":
        raise ContractError("repo2 retention must be full-count based with full archive retention")
    retention_full = _positive_int(repo["retentionFull"], "repo2.retentionFull", 7, 365)
    retention_archive = _positive_int(
        repo["retentionArchive"], "repo2.retentionArchive", 7, 365
    )
    if retention_archive < retention_full:
        raise ContractError("repo2.retentionArchive cannot be less than retentionFull")
    immutable_days = _positive_int(
        repo["minimumImmutableDays"], "repo2.minimumImmutableDays", 7, 3650
    )

    health = value["health"]
    if not isinstance(health, dict):
        raise ContractError("health must be an object")
    _require_exact_keys(
        health,
        {
            "minimumSuccessfulFullRestorePoints",
            "maximumFullAgeSeconds",
            "maximumArchiveAgeSeconds",
        },
        "policy.health",
    )
    minimum_points = _positive_int(
        health["minimumSuccessfulFullRestorePoints"],
        "health.minimumSuccessfulFullRestorePoints",
        7,
        365,
    )
    if minimum_points > retention_full:
        raise ContractError("health restore-point minimum exceeds repo2 retention")
    maximum_full_age = _positive_int(
        health["maximumFullAgeSeconds"], "health.maximumFullAgeSeconds", 86400, 172800
    )
    maximum_archive_age = _positive_int(
        health["maximumArchiveAgeSeconds"],
        "health.maximumArchiveAgeSeconds",
        300,
        3600,
    )
    return Repo2Policy(
        stanza=stanza,
        path=path,
        bucket=bucket,
        endpoint=endpoint,
        region=region,
        uri_style=repo["s3UriStyle"],
        retention_full=retention_full,
        retention_archive=retention_archive,
        minimum_restore_points=minimum_points,
        maximum_full_age_seconds=maximum_full_age,
        maximum_archive_age_seconds=maximum_archive_age,
        minimum_immutable_days=immutable_days,
    )


def parse_secrets(value: dict[str, Any]) -> dict[str, str]:
    _require_exact_keys(
        value,
        {"schemaVersion", "s3AccessKeyId", "s3AccessKeySecret", "cipherPass"},
        "secrets",
    )
    if value["schemaVersion"] != SCHEMA_VERSION:
        raise ContractError("unsupported secrets schemaVersion")
    result: dict[str, str] = {}
    for key in ("s3AccessKeyId", "s3AccessKeySecret", "cipherPass"):
        item = value[key]
        if not isinstance(item, str) or not SAFE_SECRET.fullmatch(item):
            raise ContractError(f"{key} must be 16-512 safe non-whitespace characters")
        if any(marker in item.upper() for marker in PLACEHOLDER_MARKERS):
            raise ContractError(f"{key} still contains a placeholder marker")
        result[key] = item
    if len({result["s3AccessKeySecret"], result["cipherPass"]}) != 2:
        raise ContractError("repo2 access secret and cipher pass must be independent")
    return result


def validate_worm_evidence(
    value: dict[str, Any], policy: Repo2Policy, now: datetime | None = None
) -> None:
    _require_exact_keys(
        value,
        {
            "schemaVersion",
            "status",
            "provider",
            "bucket",
            "endpoint",
            "versioningEnabled",
            "immutabilityMode",
            "retentionDays",
            "credentialsIndependent",
            "failureDomainIndependent",
            "checkedAtUtc",
            "expiresAtUtc",
            "evidenceReference",
            "approvalReference",
            "reviewer",
        },
        "WORM evidence",
    )
    if value["schemaVersion"] != SCHEMA_VERSION or value["status"] != "VERIFIED":
        raise ContractError("WORM evidence is not a VERIFIED schemaVersion 1 receipt")
    for label in ("provider", "evidenceReference", "approvalReference", "reviewer"):
        item = value[label]
        if not isinstance(item, str) or len(item.strip()) < 3 or len(item) > 256:
            raise ContractError(f"WORM evidence {label} is missing or invalid")
        if any(marker in item.upper() for marker in PLACEHOLDER_MARKERS):
            raise ContractError(f"WORM evidence {label} still contains a placeholder")
    if value["bucket"] != policy.bucket or value["endpoint"] != policy.endpoint:
        raise ContractError("WORM evidence bucket/endpoint does not match repo2 policy")
    if value["versioningEnabled"] is not True:
        raise ContractError("provider versioning evidence is required")
    if value["immutabilityMode"] not in {"COMPLIANCE", "GOVERNANCE-LOCKED"}:
        raise ContractError("provider immutability must be compliance or independently locked governance")
    if value["credentialsIndependent"] is not True or value["failureDomainIndependent"] is not True:
        raise ContractError("repo2 credentials and failure domain must be independent")
    retention_days = _positive_int(value["retentionDays"], "WORM retentionDays", 1, 36500)
    if retention_days < policy.minimum_immutable_days:
        raise ContractError("WORM retentionDays is below the approved policy minimum")
    checked = _parse_utc(value["checkedAtUtc"], "WORM checkedAtUtc")
    expires = _parse_utc(value["expiresAtUtc"], "WORM expiresAtUtc")
    current = now or datetime.now(timezone.utc)
    if checked > current or expires <= checked or expires <= current:
        raise ContractError("WORM evidence validity window is not current")
    if (current - checked).total_seconds() > 31 * 86400:
        raise ContractError("WORM evidence is older than 31 days")


def validate_sha256(path: Path, expected: str) -> None:
    if not HEX_SHA256.fullmatch(expected):
        raise ContractError("expected WORM evidence SHA-256 must be 64 lowercase hex characters")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise ContractError("WORM evidence SHA-256 differs from the out-of-band approved digest")


def render_config(policy: Repo2Policy, secrets: dict[str, str]) -> bytes:
    lines = [
        "# Generated candidate. Activation requires a separately approved root change.",
        "# Secret-bearing: root:postgres 0640; never commit or attach to a ticket.",
        "[global]",
        "archive-async=y",
        "spool-path=/var/spool/pgbackrest",
        "repo2-type=s3",
        f"repo2-path={policy.path}",
        f"repo2-s3-bucket={policy.bucket}",
        f"repo2-s3-endpoint={policy.endpoint}",
        f"repo2-s3-region={policy.region}",
        f"repo2-s3-uri-style={policy.uri_style}",
        "repo2-storage-verify-tls=y",
        "repo2-s3-key-type=shared",
        f"repo2-s3-key={secrets['s3AccessKeyId']}",
        f"repo2-s3-key-secret={secrets['s3AccessKeySecret']}",
        "repo2-cipher-type=aes-256-cbc",
        f"repo2-cipher-pass={secrets['cipherPass']}",
        "repo2-retention-full-type=count",
        f"repo2-retention-full={policy.retention_full}",
        "repo2-retention-archive-type=full",
        f"repo2-retention-archive={policy.retention_archive}",
        "repo2-bundle=y",
        "",
    ]
    return "\n".join(lines).encode("utf-8")


def validate_active_config(raw: bytes, policy: Repo2Policy) -> None:
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ContractError("active repo2 config must not contain a UTF-8 BOM")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ContractError("active repo2 config is not UTF-8") from exc
    if "\r" in text or "\x00" in text or not text.endswith("\n"):
        raise ContractError("active repo2 config must use canonical LF text")
    section_seen = False
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line == "[global]" and not section_seen and not values:
            section_seen = True
            continue
        if not section_seen or "=" not in line:
            raise ContractError("active repo2 config has a non-canonical line or section")
        key, value = line.split("=", 1)
        if (
            not re.fullmatch(r"[a-z0-9-]+", key)
            or key in values
            or not value
            or value != value.strip()
        ):
            raise ContractError("active repo2 config key/value is invalid or duplicated")
        values[key] = value
    expected = {
        "archive-async": "y",
        "spool-path": "/var/spool/pgbackrest",
        "repo2-type": "s3",
        "repo2-path": policy.path,
        "repo2-s3-bucket": policy.bucket,
        "repo2-s3-endpoint": policy.endpoint,
        "repo2-s3-region": policy.region,
        "repo2-s3-uri-style": policy.uri_style,
        "repo2-storage-verify-tls": "y",
        "repo2-s3-key-type": "shared",
        "repo2-cipher-type": "aes-256-cbc",
        "repo2-retention-full-type": "count",
        "repo2-retention-full": str(policy.retention_full),
        "repo2-retention-archive-type": "full",
        "repo2-retention-archive": str(policy.retention_archive),
        "repo2-bundle": "y",
    }
    secret_keys = {"repo2-s3-key", "repo2-s3-key-secret", "repo2-cipher-pass"}
    if set(values) != set(expected) | secret_keys:
        raise ContractError("active repo2 config exact key set differs from the renderer")
    for key, expected_value in expected.items():
        if values[key] != expected_value:
            raise ContractError(f"active repo2 config {key} differs from policy")
    for key in secret_keys:
        value = values[key]
        if not SAFE_SECRET.fullmatch(value) or any(
            marker in value.upper() for marker in PLACEHOLDER_MARKERS
        ):
            raise ContractError(f"active repo2 config {key} is missing or a placeholder")
    if values["repo2-s3-key-secret"] == values["repo2-cipher-pass"]:
        raise ContractError("active repo2 access secret and cipher pass are not independent")


def _assert_secure_file(path: Path, owner_uid: int, group_gid: int, mode: int, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise ContractError(f"cannot stat {label}: {exc}") from exc
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ContractError(f"{label} must be one regular file with one hard link")
    if info.st_uid != owner_uid or info.st_gid != group_gid:
        raise ContractError(f"{label} owner/group differs from the reviewed contract")
    if stat.S_IMODE(info.st_mode) != mode:
        raise ContractError(f"{label} mode must be {mode:04o}")


def validate_strict_files(policy_path: Path, secrets_path: Path, evidence_path: Path) -> None:
    if os.name != "posix" or os.geteuid() != 0:
        raise ContractError("--strict-files requires root on a POSIX host")
    import grp

    try:
        postgres_gid = grp.getgrnam("postgres").gr_gid
    except KeyError as exc:
        raise ContractError("postgres group does not exist") from exc
    _assert_secure_file(policy_path, 0, 0, 0o600, "policy")
    _assert_secure_file(secrets_path, 0, postgres_gid, 0o640, "secrets")
    _assert_secure_file(evidence_path, 0, 0, 0o600, "WORM evidence")


def validate_active(
    policy_path: Path,
    config_path: Path,
    approval_path: Path,
    worm_evidence_path: Path,
    now: datetime | None = None,
    repo1_override_path: Path = REPO1_OVERRIDE_PATH,
) -> dict[str, Any]:
    if os.name != "posix":
        raise ContractError("active repo2 preflight requires POSIX")
    import grp

    try:
        postgres_gid = grp.getgrnam("postgres").gr_gid
    except KeyError as exc:
        raise ContractError("postgres group does not exist") from exc
    _assert_secure_file(policy_path, 0, postgres_gid, 0o640, "runtime policy")
    _assert_secure_file(config_path, 0, postgres_gid, 0o640, "active repo2 config")
    _assert_secure_file(approval_path, 0, postgres_gid, 0o640, "repo2 approval")
    _assert_secure_file(
        worm_evidence_path, 0, postgres_gid, 0o640, "active WORM evidence"
    )
    _assert_secure_file(
        repo1_override_path, 0, 0, 0o644, "repo1 explicit backup override"
    )
    if repo1_override_path.read_bytes() != REPO1_OVERRIDE:
        raise ContractError(
            "repo1 backup override differs from the reviewed explicit-repository contract"
        )
    policy_raw = policy_path.read_bytes()
    config_raw = config_path.read_bytes()
    worm_raw = worm_evidence_path.read_bytes()
    repo1_override_raw = repo1_override_path.read_bytes()
    if len(config_raw) > 64 * 1024:
        raise ContractError("active repo2 config exceeds 64 KiB")
    policy = parse_policy(_load_json(policy_path, "runtime policy"))
    approval = _load_json(approval_path, "repo2 approval")
    _require_exact_keys(
        approval,
        {
            "schemaVersion",
            "status",
            "approvalReference",
            "policySha256",
            "configSha256",
            "repo1OverrideSha256",
            "wormEvidenceSha256",
            "approvedAtUtc",
            "expiresAtUtc",
            "reviewer",
        },
        "repo2 approval",
    )
    if approval["schemaVersion"] != 1 or approval["status"] != "APPROVED":
        raise ContractError("repo2 approval is not APPROVED schemaVersion 1")
    reference = approval["approvalReference"]
    if not isinstance(reference, str) or not APPROVAL_REFERENCE.fullmatch(reference):
        raise ContractError("repo2 approval reference is not canonical")
    reviewer = approval["reviewer"]
    if not isinstance(reviewer, str) or len(reviewer.strip()) < 3 or len(reviewer) > 256:
        raise ContractError("repo2 approval reviewer is invalid")
    for key in (
        "policySha256",
        "configSha256",
        "repo1OverrideSha256",
        "wormEvidenceSha256",
    ):
        if not isinstance(approval[key], str) or not HEX_SHA256.fullmatch(approval[key]):
            raise ContractError(f"repo2 approval {key} is invalid")
    if hashlib.sha256(policy_raw).hexdigest() != approval["policySha256"]:
        raise ContractError("runtime policy differs from the approved digest")
    if hashlib.sha256(config_raw).hexdigest() != approval["configSha256"]:
        raise ContractError("active repo2 config differs from the approved digest")
    if (
        hashlib.sha256(repo1_override_raw).hexdigest()
        != approval["repo1OverrideSha256"]
    ):
        raise ContractError("repo1 backup override differs from the approved digest")
    validate_active_config(config_raw, policy)
    approved = _parse_utc(approval["approvedAtUtc"], "repo2 approvedAtUtc")
    expires = _parse_utc(approval["expiresAtUtc"], "repo2 expiresAtUtc")
    current = now or datetime.now(timezone.utc)
    if approved > current or expires <= approved or expires <= current:
        raise ContractError("repo2 approval validity window is not current")
    if (current - approved).total_seconds() > 31 * 86400:
        raise ContractError("repo2 approval is older than 31 days")
    if hashlib.sha256(worm_raw).hexdigest() != approval["wormEvidenceSha256"]:
        raise ContractError("active WORM evidence differs from the approved digest")
    worm_value = _load_json(worm_evidence_path, "active WORM evidence")
    validate_worm_evidence(worm_value, policy, now=current)
    if (
        worm_value["approvalReference"] != reference
        or worm_value["reviewer"] != reviewer
    ):
        raise ContractError("active WORM evidence approval/reviewer differs from enable approval")
    return {
        "schemaVersion": 1,
        "status": "ACTIVE_PREFLIGHT_PASS",
        "stanza": policy.stanza,
        "approvalReference": reference,
        "policySha256": approval["policySha256"],
        "configSha256": approval["configSha256"],
        "repo1OverrideSha256": approval["repo1OverrideSha256"],
        "wormEvidenceSha256": approval["wormEvidenceSha256"],
        "secretsIncluded": False,
    }


def _write_candidate(path: Path, payload: bytes) -> str:
    resolved_parent = path.parent.resolve(strict=True)
    resolved_path = resolved_parent / path.name
    if str(resolved_path).startswith("/etc/") or resolved_path == Path("/etc"):
        raise ContractError("render-candidate never writes under /etc; use a reviewed activation change")
    if path.exists() or path.is_symlink():
        raise ContractError("candidate output already exists; overwrite is forbidden")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(resolved_path, flags, 0o600)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            if written < 1:
                raise OSError("short candidate write")
            view = view[written:]
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        parent_fd = os.open(resolved_parent, os.O_RDONLY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    except OSError:
        # Windows cannot fsync a directory. Candidate rendering remains test-only
        # there; production activation is POSIX-only and separately reviewed.
        if os.name == "posix":
            raise
    return hashlib.sha256(payload).hexdigest()


def command(args: argparse.Namespace) -> int:
    if args.action == "validate-active":
        print(
            json.dumps(
                validate_active(
                    args.policy,
                    args.config,
                    args.approval,
                    args.worm_evidence,
                    repo1_override_path=args.repo1_override,
                ),
                sort_keys=True,
            )
        )
        return 0
    policy_value = _load_json(args.policy, "policy")
    secrets_value = _load_json(args.secrets, "secrets")
    evidence_value = _load_json(args.worm_evidence, "WORM evidence")
    policy = parse_policy(policy_value)
    secrets = parse_secrets(secrets_value)
    validate_sha256(args.worm_evidence, args.expected_worm_evidence_sha256)
    validate_worm_evidence(evidence_value, policy)
    if args.strict_files:
        validate_strict_files(args.policy, args.secrets, args.worm_evidence)
    if args.action == "validate":
        print(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "status": "VALIDATED_CANDIDATE_INPUTS_ONLY",
                    "stanza": policy.stanza,
                    "repo": 2,
                    "bucket": policy.bucket,
                    "endpoint": policy.endpoint,
                    "retentionFull": policy.retention_full,
                    "minimumSuccessfulFullRestorePoints": policy.minimum_restore_points,
                    "wormEvidenceSha256": args.expected_worm_evidence_sha256,
                    "productionChanged": False,
                    "remoteProviderContacted": False,
                },
                sort_keys=True,
            )
        )
        return 0
    if args.confirm != RENDER_CONFIRMATION:
        raise ContractError(f"--confirm must exactly equal: {RENDER_CONFIRMATION}")
    digest = _write_candidate(args.output, render_config(policy, secrets))
    print(
        json.dumps(
            {
                "schemaVersion": 1,
                "status": "CANDIDATE_RENDERED_NOT_INSTALLED",
                "output": str(args.output.resolve()),
                "sha256": digest,
                "productionChanged": False,
                "remoteProviderContacted": False,
            },
            sort_keys=True,
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("validate", "render-candidate"):
        item = sub.add_parser(name)
        item.add_argument("--policy", required=True, type=Path)
        item.add_argument("--secrets", required=True, type=Path)
        item.add_argument("--worm-evidence", required=True, type=Path)
        item.add_argument("--expected-worm-evidence-sha256", required=True)
        item.add_argument("--strict-files", action="store_true")
        if name == "render-candidate":
            item.add_argument("--output", required=True, type=Path)
            item.add_argument("--confirm", required=True)
    active = sub.add_parser("validate-active")
    active.add_argument(
        "--policy", type=Path, default=Path("/etc/uten-imp-backup/repo2-policy.json")
    )
    active.add_argument(
        "--config",
        type=Path,
        default=Path("/etc/pgbackrest/conf.d/20-uten-imp-repo2.conf"),
    )
    active.add_argument(
        "--approval",
        type=Path,
        default=Path("/etc/uten-imp-backup/repo2-enabled.approved"),
    )
    active.add_argument(
        "--worm-evidence",
        type=Path,
        default=Path("/etc/uten-imp-backup/worm-evidence.json"),
    )
    active.add_argument("--repo1-override", type=Path, default=REPO1_OVERRIDE_PATH)
    return parser


def main() -> int:
    try:
        return command(build_parser().parse_args())
    except (ContractError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
